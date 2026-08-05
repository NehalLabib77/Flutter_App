"""Billing provider abstraction and SSLCOMMERZ integration.

This module is the **only** place that talks to the SSLCOMMERZ HTTP API.
It is intentionally framework-agnostic — no Flask, no SQLAlchemy, no
Flutter, no enrollment creation. The route layer (``payment_routes.py``)
is responsible for translating these results into HTTP responses and
database rows.

Design goals
------------
* Sandbox and live endpoints via ``mode="sandbox" | "live"``.
* Strict TLS — ``verify=True`` is set explicitly on every request.
* Bounded latency — separate connect / read timeouts.
* Decimal-safe money — amounts never travel as ``float``.
* Credential hygiene — the store password is never logged, never
  returned to callers, and is stripped from any log message that
  mentions an exception.
* Testability — the HTTP layer (``requests``) is referenced via the
  module-level ``http`` attribute so tests can swap in a mock.
* Predictable failure modes — every recoverable gateway problem
  surfaces as a ``BillingError`` subclass or a structured ``Result``,
  never as an uncaught exception leaking a stack trace to a caller.

Failure surface
---------------
The two public methods (``create_session`` and ``validate``) return
dicts so the existing ``payment_routes.py`` integration keeps working.
Internally they raise ``BillingError`` subclasses that callers may
catch for finer-grained handling. The dict's ``status`` / ``error``
fields mirror the exception type for log-friendly diagnostics.

The exception hierarchy is::

    BillingError                     # base
    ├── BillingConfigError           # missing store_id / password / mode
    ├── BillingInputError            # missing required kwargs
    ├── BillingTimeoutError          # connect/read timeout
    ├── BillingConnectionError       # DNS / TLS / TCP failure
    ├── BillingHTTPStatusError       # 4xx / 5xx from the gateway
    ├── BillingResponseFormatError   # non-JSON or malformed body
    ├── BillingRejectionError        # gateway returned status FAILED
    ├── BillingMissingGatewayURLError
    ├── BillingMissingSessionKeyError
    └── BillingValidationAPIError    # validation API returned non-VALID
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import logging
import os
from typing import Any, Mapping, Protocol
from urllib.parse import urlencode

import requests


log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Constants & defaults
# ---------------------------------------------------------------------------

#: Two-decimal money quantisation used everywhere a currency value crosses
#: the wire or hits the database. We never round-trip floats.
_MONEY_QUANT = Decimal("0.01")

#: Connect timeout (seconds). Short by design — SSLCOMMERZ replies fast
#: or fails fast. Five seconds is well above the gateway's typical
#: connect time but short enough to surface network issues quickly.
DEFAULT_CONNECT_TIMEOUT = 5.0

#: Read timeout (seconds). A full session-creation round-trip including
#: bank handshakes is normally under three seconds; twelve is generous.
DEFAULT_READ_TIMEOUT = 12.0

#: Minimum read timeout we will accept from configuration.
_MIN_READ_TIMEOUT = 3

#: Maximum payload size we are willing to log (chars). Anything larger
#: is truncated with an ellipsis so a misbehaving gateway can't fill
#: our logs.
_LOG_PREVIEW_LIMIT = 512


def _to_decimal(value: Any) -> Decimal | None:
    """Parse a money value into ``Decimal`` rounded to two decimals.

    Accepts ``Decimal``, ``int``, ``str`` of digits, and floats whose
    string round-trip is exact. Returns ``None`` on garbage input so
    callers can decide how to fail without raising.
    """
    if value is None:
        return None
    try:
        return Decimal(str(value)).quantize(_MONEY_QUANT, rounding=ROUND_HALF_UP)
    except (InvalidOperation, ValueError, TypeError):
        return None


def _format_amount(value: Any) -> str:
    """Render a money value as a fixed two-decimal string.

    Used for ``total_amount`` on the wire. Falls back to ``"0.00"`` if
    the value cannot be parsed — the gateway requires *something* in
    this field, and zero is the safest default (the route layer must
    never let an unparseable amount reach here in the first place).
    """
    parsed = _to_decimal(value)
    if parsed is None:
        return "0.00"
    return format(parsed, "f")


def _redact(text: str) -> str:
    """Strip ``store_passwd=...`` (and friends) from log messages.

    We don't want to ship a fully-featured secret scrubber — the goal
    is just to ensure the *one* secret we hold never lands in a log.
    """
    if not text:
        return text
    needle = "store_passwd="
    idx = text.find(needle)
    while idx != -1:
        end = text.find("&", idx)
        if end == -1:
            end = len(text)
        text = text[:idx] + "store_passwd=***" + text[end:]
        idx = text.find(needle, idx + len("store_passwd=***"))
    return text


# ---------------------------------------------------------------------------
# Result objects (additive — no behavioural change to existing dict callers)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Result:
    """Structured success/failure for one gateway call.

    Useful when callers want to branch on outcome without having to
    inspect dict keys. The dict-returning methods below populate both
    this object (returned by ``create_session_struct`` / friends) and a
    backwards-compatible dict.
    """

    ok: bool
    status: str
    provider: str
    error: str | None = None
    raw: Mapping[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Exception hierarchy
# ---------------------------------------------------------------------------


class BillingError(Exception):
    """Base class for every gateway-layer failure.

    The ``code`` attribute is a short, log-friendly identifier suitable
    for metrics or response payloads. The ``message`` is safe to surface
    to the route layer (never includes credentials).
    """

    code: str = "BILLING_ERROR"

    def __init__(self, message: str, *, raw: Mapping[str, Any] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.raw: dict[str, Any] = dict(raw or {})

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": False,
            "status": self.code,
            "error": self.message,
            "raw": self.raw,
        }


class BillingConfigError(BillingError):
    """Store credentials are missing or unusable."""

    code = "BILLING_CONFIG_ERROR"


class BillingInputError(BillingError):
    """A required kwarg was missing or wrong-typed."""

    code = "BILLING_INPUT_ERROR"


class BillingTimeoutError(BillingError):
    """The gateway did not respond within the configured read/connect window."""

    code = "BILLING_TIMEOUT"


class BillingConnectionError(BillingError):
    """DNS, TCP, TLS, or other low-level transport failure."""

    code = "BILLING_CONNECTION_ERROR"


class BillingHTTPStatusError(BillingError):
    """The gateway returned a 4xx / 5xx response."""

    code = "BILLING_HTTP_STATUS_ERROR"


class BillingResponseFormatError(BillingError):
    """The response body was not valid JSON / could not be decoded."""

    code = "BILLING_RESPONSE_FORMAT_ERROR"


class BillingRejectionError(BillingError):
    """The gateway explicitly rejected the session."""

    code = "BILLING_REJECTION"


class BillingMissingGatewayURLError(BillingError):
    """Gateway accepted the request but returned no ``GatewayPageURL``."""

    code = "BILLING_MISSING_GATEWAY_URL"


class BillingMissingSessionKeyError(BillingError):
    """Gateway accepted the request but returned no ``sessionkey``."""

    code = "BILLING_MISSING_SESSION_KEY"


class BillingValidationAPIError(BillingError):
    """Validation endpoint did not return ``VALID`` / ``VALIDATED``."""

    code = "BILLING_VALIDATION_API_ERROR"


# ---------------------------------------------------------------------------
# Provider abstraction
# ---------------------------------------------------------------------------


class BillingProvider(Protocol):
    """Minimal interface every concrete provider must implement."""

    name: str

    def create_session(self, **kwargs) -> dict:
        ...

    def validate(self, **kwargs) -> dict:
        ...


class FreeBillingProvider:
    """No-op provider used in dev and tests when no gateway is configured."""

    name = "free"
    sandbox = True

    def create_session(self, **kwargs) -> dict:
        return {
            "ok": False,
            "status": "SKIPPED",
            "provider": self.name,
            "error": "No billing provider configured.",
            "raw": {},
        }

    def validate(self, **kwargs) -> dict:
        return {
            "ok": False,
            "status": "SKIPPED",
            "provider": self.name,
            "error": "No billing provider configured.",
            "raw": {},
        }


# ---------------------------------------------------------------------------
# SSLCOMMERZ provider
# ---------------------------------------------------------------------------


class SslCommerzBillingProvider:
    """SSLCOMMERZ provider for sandbox / live hosted checkout.

    The class is **stateless beyond its config** — every call is its
    own HTTP transaction. That keeps it safe to use from a worker pool
    and easy to mock.

    Timeouts
    --------
    ``connect_timeout`` defaults to ``DEFAULT_CONNECT_TIMEOUT`` seconds
    and ``read_timeout`` to ``DEFAULT_READ_TIMEOUT``. ``requests``
    accepts a ``(connect, read)`` tuple so we pass them through as-is.

    TLS
    ---
    ``verify=True`` is set explicitly on every request. The provider
    refuses to start if a caller ever tries to relax this — there is
    no public knob for ``verify=False``.
    """

    name = "sslcommerz"

    def __init__(
        self,
        *,
        store_id: str,
        store_password: str,
        mode: str = "sandbox",
        connect_timeout: float | int = DEFAULT_CONNECT_TIMEOUT,
        read_timeout: float | int = DEFAULT_READ_TIMEOUT,
        http: Any | None = None,
    ) -> None:
        if not store_id or not store_password:
            raise BillingConfigError(
                "SslCommerzBillingProvider requires both store_id and "
                "store_password."
            )
        self.store_id = store_id.strip()
        self.store_password = store_password
        self.mode = (mode or "sandbox").strip().lower()
        if self.mode not in {"sandbox", "live"}:
            raise BillingConfigError(
                f"Unsupported payment mode {mode!r}; expected 'sandbox' or 'live'."
            )
        self.sandbox = self.mode != "live"
        self.connect_timeout = max(1.0, float(connect_timeout or DEFAULT_CONNECT_TIMEOUT))
        self.read_timeout = max(
            float(_MIN_READ_TIMEOUT),
            float(read_timeout or DEFAULT_READ_TIMEOUT),
        )
        # Allow tests to swap in a mock. Defaults to the real ``requests``.
        self.http = http if http is not None else requests

    # ----- Endpoints ---------------------------------------------------

    @property
    def session_endpoint(self) -> str:
        if self.sandbox:
            return "https://sandbox.sslcommerz.com/gwprocess/v4/api.php"
        return "https://securepay.sslcommerz.com/gwprocess/v4/api.php"

    @property
    def validation_endpoint(self) -> str:
        if self.sandbox:
            return (
                "https://sandbox.sslcommerz.com/validator/api/"
                "validationserverAPI.php"
            )
        return (
            "https://securepay.sslcommerz.com/validator/api/"
            "validationserverAPI.php"
        )

    @property
    def _timeout_tuple(self) -> tuple[float, float]:
        return (self.connect_timeout, self.read_timeout)

    # ----- Session creation ------------------------------------------

    def _build_session_payload(self, **kwargs: Any) -> dict[str, str]:
        required = ("transaction_id", "success_url", "fail_url", "cancel_url", "ipn_url")
        missing = [k for k in required if not kwargs.get(k)]
        if missing:
            raise BillingInputError(
                "create_session is missing required arguments: "
                + ", ".join(sorted(missing))
            )

        amount = kwargs["amount"]
        amount_str = _format_amount(amount)
        if amount_str == "0.00":
            raise BillingInputError(
                "create_session received an unparseable or zero amount."
            )

        payload: dict[str, str] = {
            "store_id": self.store_id,
            "store_passwd": self.store_password,
            "total_amount": amount_str,
            "currency": (kwargs.get("currency") or "BDT").strip().upper(),
            "tran_id": str(kwargs["transaction_id"]),
            "success_url": kwargs["success_url"],
            "fail_url": kwargs["fail_url"],
            "cancel_url": kwargs["cancel_url"],
            "ipn_url": kwargs["ipn_url"],
            "shipping_method": "NO",
            "product_name": "EduCompass Course Enrollment",
            "product_category": "Education",
            "product_profile": "general",
            "num_of_item": "1",
            "value_a": str(kwargs.get("value_a") or ""),
            "value_b": str(kwargs.get("value_b") or ""),
            "value_c": str(kwargs.get("value_c") or "educompass"),
            "value_d": str(kwargs.get("value_d") or kwargs["transaction_id"]),
        }

        customer = kwargs.get("customer") or {}
        # Safe defaults — SSLCOMMERZ requires *some* value here, but we
        # never invent trusted PII (no real names, emails, or phone
        # numbers). The user-id / course-id are kept in ``value_a`` /
        # ``value_b`` as DB-controlled references — the route layer
        # passes them in.
        payload.update({
            "cus_name": str(customer.get("name") or "EduCompass User"),
            "cus_email": str(customer.get("email") or "user@educompass.app"),
            "cus_add1": str(customer.get("address") or "N/A"),
            "cus_city": str(customer.get("city") or "Dhaka"),
            "cus_postcode": str(customer.get("postcode") or "1200"),
            "cus_country": str(customer.get("country") or "Bangladesh"),
            "cus_phone": str(customer.get("phone") or "01700000000"),
        })
        return payload

    def _post_session(self, payload: Mapping[str, str]) -> dict[str, Any]:
        """POST to the session endpoint with strict TLS and bounded timeouts."""
        try:
            response = self.http.post(
                self.session_endpoint,
                data=payload,
                timeout=self._timeout_tuple,
                verify=True,
            )
        except requests.exceptions.Timeout as exc:
            log.warning(
                "sslcommerz session request timed out after connect=%s read=%s: %s",
                self.connect_timeout, self.read_timeout, _redact(str(exc)),
            )
            raise BillingTimeoutError(
                "Gateway session request timed out.", raw=payload
            ) from exc
        except requests.exceptions.SSLError as exc:
            log.warning(
                "sslcommerz session TLS error: %s", _redact(str(exc))
            )
            raise BillingConnectionError(
                "Gateway session TLS verification failed.", raw=payload
            ) from exc
        except requests.exceptions.ConnectionError as exc:
            log.warning(
                "sslcommerz session connection error: %s", _redact(str(exc))
            )
            raise BillingConnectionError(
                "Gateway session connection failed.", raw=payload
            ) from exc
        except requests.RequestException as exc:
            log.warning(
                "sslcommerz session request failed: %s", _redact(str(exc))
            )
            raise BillingConnectionError(
                "Gateway session request failed.", raw=payload
            ) from exc

        if not (200 <= response.status_code < 300):
            preview = _redact(response.text or "")[:_LOG_PREVIEW_LIMIT]
            log.warning(
                "sslcommerz session returned HTTP %s: %s",
                response.status_code, preview,
            )
            raise BillingHTTPStatusError(
                f"Gateway session returned HTTP {response.status_code}.",
                raw={"status_code": response.status_code},
            )

        try:
            return response.json()
        except ValueError as exc:
            preview = _redact(response.text or "")[:_LOG_PREVIEW_LIMIT]
            log.warning(
                "sslcommerz session returned non-JSON: %s", preview
            )
            raise BillingResponseFormatError(
                "Gateway returned a non-JSON session response.",
                raw={"status_code": response.status_code},
            ) from exc

    def _session_to_result(self, raw: Mapping[str, Any]) -> Result:
        status = str(raw.get("status") or "").upper()
        session_key = raw.get("sessionkey") or raw.get("sessionKey")
        gateway_url = raw.get("GatewayPageURL") or raw.get("gateway_url")

        if status not in {"SUCCESS", "VALID"}:
            raise BillingRejectionError(
                str(raw.get("failedreason") or "Gateway rejected session."),
                raw=dict(raw),
            )
        if not gateway_url:
            raise BillingMissingGatewayURLError(
                "Gateway accepted session but returned no GatewayPageURL.",
                raw=dict(raw),
            )
        if not session_key:
            raise BillingMissingSessionKeyError(
                "Gateway accepted session but returned no sessionkey.",
                raw=dict(raw),
            )
        return Result(
            ok=True,
            status=status,
            provider=self.name,
            error=None,
            raw=dict(raw),
        )

    # ----- Validation --------------------------------------------------

    def _validate_http(self, val_id: str) -> dict[str, Any]:
        params = {
            "val_id": str(val_id),
            "store_id": self.store_id,
            "store_passwd": self.store_password,
            "v": "1",
            "format": "json",
        }
        try:
            response = self.http.get(
                self.validation_endpoint,
                params=params,
                timeout=self._timeout_tuple,
                verify=True,
            )
        except requests.exceptions.Timeout as exc:
            log.warning(
                "sslcommerz validation request timed out: %s",
                _redact(str(exc)),
            )
            raise BillingTimeoutError(
                "Gateway validation request timed out."
            ) from exc
        except requests.exceptions.SSLError as exc:
            log.warning(
                "sslcommerz validation TLS error: %s", _redact(str(exc))
            )
            raise BillingConnectionError(
                "Gateway validation TLS verification failed."
            ) from exc
        except requests.exceptions.ConnectionError as exc:
            log.warning(
                "sslcommerz validation connection error: %s",
                _redact(str(exc)),
            )
            raise BillingConnectionError(
                "Gateway validation connection failed."
            ) from exc
        except requests.RequestException as exc:
            log.warning(
                "sslcommerz validation request failed: %s",
                _redact(str(exc)),
            )
            raise BillingConnectionError(
                "Gateway validation request failed."
            ) from exc

        if not (200 <= response.status_code < 300):
            preview = _redact(response.text or "")[:_LOG_PREVIEW_LIMIT]
            log.warning(
                "sslcommerz validation returned HTTP %s: %s",
                response.status_code, preview,
            )
            raise BillingHTTPStatusError(
                f"Gateway validation returned HTTP {response.status_code}.",
                raw={"status_code": response.status_code},
            )

        try:
            return response.json()
        except ValueError as exc:
            preview = _redact(response.text or "")[:_LOG_PREVIEW_LIMIT]
            log.warning(
                "sslcommerz validation returned non-JSON: %s", preview
            )
            raise BillingResponseFormatError(
                "Gateway validation returned a non-JSON response.",
                raw={"status_code": response.status_code},
            ) from exc

    # ----- Public dict-returning methods -------------------------------
    #
    # These keep the legacy ``BillingProvider`` Protocol contract for
    # ``payment_routes.py``. Internally they catch the exception
    # hierarchy and convert to the same dict shape callers already
    # understand.

    def create_session(self, **kwargs) -> dict:
        try:
            payload = self._build_session_payload(**kwargs)
            raw = self._post_session(payload)
            result = self._session_to_result(raw)
        except BillingError as exc:
            # Preserve the gateway's raw status string when it was
            # returned (``FAILED`` etc.) so log forensics stay useful;
            # fall back to the exception code when there is nothing
            # else to surface.
            raw_status = ""
            if isinstance(getattr(exc, "raw", None), Mapping):
                raw_status = str(exc.raw.get("status") or "")
            return {
                "ok": False,
                "status": raw_status or exc.code,
                "provider": self.name,
                "session_key": None,
                "gateway_url": None,
                "raw": exc.raw,
                "error": exc.message,
            }
        return {
            "ok": True,
            "status": result.status,
            "provider": self.name,
            "session_key": raw.get("sessionkey") or raw.get("sessionKey"),
            "gateway_url": raw.get("GatewayPageURL") or raw.get("gateway_url"),
            "raw": result.raw,
            "error": None,
        }

    def validate(self, **kwargs) -> dict:
        val_id = kwargs.get("val_id")
        if not val_id:
            return {
                "ok": False,
                "status": "ERROR",
                "provider": self.name,
                "error": "Missing validation id.",
                "raw": {},
            }

        try:
            raw = self._validate_http(val_id)
        except BillingError as exc:
            return {**exc.to_dict(), "provider": self.name}

        status = str(raw.get("status") or "").upper()
        api_connect = str(raw.get("APIConnect") or "").upper() or None
        if status not in {"VALID", "VALIDATED"}:
            return {
                "ok": False,
                "status": status or "FAILED",
                "provider": self.name,
                "error": "Gateway validation did not return a successful status.",
                "raw": raw,
                "api_connect": api_connect,
            }
        return {
            "ok": True,
            "status": status,
            "provider": self.name,
            "error": None,
            "raw": raw,
            "api_connect": api_connect,
            "tran_id": str(raw.get("tran_id") or ""),
            "amount": _to_decimal(raw.get("amount")),
            "currency": str(
                raw.get("currency")
                or raw.get("currency_type")
                or ""
            ).upper(),
            "risk_level": raw.get("risk_level"),
            "risk_title": raw.get("risk_title"),
            "bank_transaction_id": raw.get("bank_tran_id"),
            "card_type": raw.get("card_type"),
            "value_a": raw.get("value_a"),
            "value_b": raw.get("value_b"),
            "value_c": raw.get("value_c"),
            "value_d": raw.get("value_d"),
        }

    # ----- Structured-result variants ---------------------------------
    #
    # Optional, additive entry points for callers that want a typed
    # outcome instead of a dict. ``create_session`` / ``validate``
    # above remain the canonical methods.

    def create_session_result(self, **kwargs) -> Result:
        """Like :meth:`create_session` but raises on failure and returns a
        :class:`Result` on success."""
        payload = self._build_session_payload(**kwargs)
        raw = self._post_session(payload)
        return self._session_to_result(raw)

    def validate_result(self, **kwargs) -> Result:
        """Like :meth:`validate` but raises on failure and returns a
        :class:`Result` on success."""
        val_id = kwargs.get("val_id")
        if not val_id:
            raise BillingInputError("validate requires a non-empty 'val_id'.")
        raw = self._validate_http(val_id)
        status = str(raw.get("status") or "").upper()
        if status not in {"VALID", "VALIDATED"}:
            raise BillingValidationAPIError(
                "Gateway validation did not return a successful status.",
                raw=dict(raw),
            )
        return Result(
            ok=True, status=status, provider=self.name, error=None, raw=dict(raw),
        )


# ---------------------------------------------------------------------------
# Provider selection
# ---------------------------------------------------------------------------


_PROVIDER_OVERRIDE: BillingProvider | None = None
BILLING_PROVIDER_NAME = "free"


def get_billing_provider() -> BillingProvider:
    """Return the active billing provider based on env / configuration.

    Reads ``PAYMENT_MODE``, ``SSLC_STORE_ID``, ``SSLC_STORE_PASSWORD``,
    and ``PAYMENT_HTTP_TIMEOUT_SECONDS``. When both credentials are
    present, an :class:`SslCommerzBillingProvider` is constructed;
    otherwise the no-op :class:`FreeBillingProvider` is returned.
    """
    global BILLING_PROVIDER_NAME
    if _PROVIDER_OVERRIDE is not None:
        BILLING_PROVIDER_NAME = _PROVIDER_OVERRIDE.name
        return _PROVIDER_OVERRIDE

    mode = (os.environ.get("PAYMENT_MODE") or "sandbox").strip().lower()
    store_id = (os.environ.get("SSLC_STORE_ID") or "").strip()
    store_password = os.environ.get("SSLC_STORE_PASSWORD") or ""
    timeout = int(os.environ.get("PAYMENT_HTTP_TIMEOUT_SECONDS") or str(int(DEFAULT_READ_TIMEOUT)))

    if store_id and store_password:
        provider = SslCommerzBillingProvider(
            store_id=store_id,
            store_password=store_password,
            mode=mode,
            read_timeout=timeout,
        )
        BILLING_PROVIDER_NAME = provider.name
        return provider

    BILLING_PROVIDER_NAME = "free"
    return FreeBillingProvider()


def install_billing_provider(provider: BillingProvider | None) -> None:
    """Set a process-local provider override (used in tests)."""
    global _PROVIDER_OVERRIDE, BILLING_PROVIDER_NAME
    _PROVIDER_OVERRIDE = provider
    BILLING_PROVIDER_NAME = (provider.name if provider is not None else "free")


__all__ = [
    # Provider abstraction
    "BillingProvider",
    "FreeBillingProvider",
    "SslCommerzBillingProvider",
    "get_billing_provider",
    "install_billing_provider",
    "BILLING_PROVIDER_NAME",
    # Result types
    "Result",
    # Exceptions
    "BillingError",
    "BillingConfigError",
    "BillingInputError",
    "BillingTimeoutError",
    "BillingConnectionError",
    "BillingHTTPStatusError",
    "BillingResponseFormatError",
    "BillingRejectionError",
    "BillingMissingGatewayURLError",
    "BillingMissingSessionKeyError",
    "BillingValidationAPIError",
    # Defaults
    "DEFAULT_CONNECT_TIMEOUT",
    "DEFAULT_READ_TIMEOUT",
]
