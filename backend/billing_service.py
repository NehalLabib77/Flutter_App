"""Phone-number-based billing providers.

MockBillingProvider keeps OTPs in memory and is used in development.
BdAppsBillingProvider wraps a real HTTP API and is selected when
BILLING_PROVIDER=bdapps.
"""

from __future__ import annotations

import os
import re
import threading
import time
from dataclasses import dataclass
from typing import Protocol


@dataclass
class OtpRequestResult:
    reference: str
    mode: str = "sms"
    hint: str = ""


@dataclass
class OtpVerifyResult:
    success: bool
    reference: str = ""
    failure_reason: str = ""


class BillingProvider(Protocol):
    name: str

    def request_otp(self, phone_number: str) -> OtpRequestResult: ...

    def verify_otp(self, phone_number: str, code: str) -> OtpVerifyResult: ...


class MockBillingProvider:
    """In-memory OTP provider for local development."""

    name = "mock"

    _RESEND_COOLDOWN_SECONDS = 30.0
    _MAX_ATTEMPTS = 5

    def __init__(self, ttl_seconds: int = 300) -> None:
        self._ttl_seconds = ttl_seconds
        self._lock = threading.Lock()
        self._pending: dict[str, dict] = {}

    def request_otp(self, phone_number: str) -> OtpRequestResult:
        now = time.time()
        with self._lock:
            entry = self._pending.get(phone_number)
            if entry and now - entry["last_sent"] < self._RESEND_COOLDOWN_SECONDS:
                wait = int(self._RESEND_COOLDOWN_SECONDS
                           - (now - entry["last_sent"]))
                return OtpRequestResult(
                    reference=entry["reference"],
                    hint=f"Wait {wait}s before requesting a new code.",
                )

            code = f"{int(now) % 1000000:06d}"
            reference = f"mock-{int(now * 1000)}"
            self._pending[phone_number] = {
                "code": code,
                "reference": reference,
                "expires_at": now + self._ttl_seconds,
                "attempts": 0,
                "last_sent": now,
            }
        print(f"[billing:mock] OTP for {phone_number}: {code}")
        return OtpRequestResult(
            reference=reference,
            hint="Dev only — code is logged server-side.",
        )

    def verify_otp(self, phone_number: str, code: str) -> OtpVerifyResult:
        now = time.time()
        with self._lock:
            entry = self._pending.get(phone_number)
            if not entry:
                return OtpVerifyResult(False, failure_reason="no_pending_otp")
            if now > entry["expires_at"]:
                self._pending.pop(phone_number, None)
                return OtpVerifyResult(False, failure_reason="expired")

            entry["attempts"] += 1
            if entry["attempts"] > self._MAX_ATTEMPTS:
                self._pending.pop(phone_number, None)
                return OtpVerifyResult(False, failure_reason="too_many_attempts")

            if entry["code"] != code:
                return OtpVerifyResult(False, reference=entry["reference"])

            reference = entry["reference"]
            self._pending.pop(phone_number, None)
            return OtpVerifyResult(True, reference=reference)


class BdAppsBillingProvider:
    """HTTP wrapper for the real bdapps OTP API."""

    name = "bdapps"

    _PHONE_RE = re.compile(r"^\+?[0-9]{8,15}$")

    def __init__(self, base_url: str, api_key: str, client_id: str,
                 otp_path: str, verify_path: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._client_id = client_id
        self._otp_path = otp_path
        self._verify_path = verify_path

    @staticmethod
    def _normalise_phone(phone_number: str) -> str:
        cleaned = phone_number.strip().replace(" ", "")
        if not BdAppsBillingProvider._PHONE_RE.match(cleaned):
            raise ValueError("Invalid phone number format")
        return cleaned

    def _post(self, path: str, payload: dict) -> dict:
        import requests

        headers = {"Authorization": f"Bearer {self._api_key}",
                   "X-Client-Id": self._client_id}
        response = requests.post(
            f"{self._base_url}{path}",
            json=payload,
            headers=headers,
            timeout=15,
        )
        response.raise_for_status()
        return response.json()

    def request_otp(self, phone_number: str) -> OtpRequestResult:
        phone = self._normalise_phone(phone_number)
        data = self._post(self._otp_path, {"phone": phone})
        return OtpRequestResult(
            reference=data.get("reference", ""),
            mode=data.get("mode", "sms"),
            hint=data.get("hint", ""),
        )

    def verify_otp(self, phone_number: str, code: str) -> OtpVerifyResult:
        phone = self._normalise_phone(phone_number)
        try:
            data = self._post(self._verify_path,
                               {"phone": phone, "code": code})
        except Exception:
            return OtpVerifyResult(False, failure_reason="provider_error")
        return OtpVerifyResult(
            success=bool(data.get("success")),
            reference=data.get("reference", ""),
            failure_reason=data.get("failure_reason", ""),
        )


_PROVIDER_CACHE: dict[str, BillingProvider] = {}


def get_billing_provider(config) -> BillingProvider:
    """Build a billing provider from a Flask app or a plain Config object."""

    def _value(key: str, default: str = "") -> str:
        if hasattr(config, key):
            return getattr(config, key)
        try:
            return config.get(key, default)
        except AttributeError:
            return default

    name = _value("BILLING_PROVIDER", "mock")
    if name in _PROVIDER_CACHE:
        return _PROVIDER_CACHE[name]

    if name == "bdapps":
        provider = BdAppsBillingProvider(
            base_url=_value("BDAPPS_BASE_URL", "https://api.example.com"),
            api_key=_value("BDAPPS_API_KEY", ""),
            client_id=_value("BDAPPS_CLIENT_ID", ""),
            otp_path=_value("BDAPPS_OTP_PATH", "/otp"),
            verify_path=_value("BDAPPS_VERIFY_PATH", "/otp/verify"),
        )
    else:
        provider = MockBillingProvider(
            ttl_seconds=int(_value("BILLING_OTP_TTL_SECONDS", "300")),
        )

    _PROVIDER_CACHE[name] = provider
    return provider


def reset_provider_cache() -> None:
    _PROVIDER_CACHE.clear()


__all__ = [
    "BillingProvider",
    "MockBillingProvider",
    "BdAppsBillingProvider",
    "OtpRequestResult",
    "OtpVerifyResult",
    "get_billing_provider",
    "reset_provider_cache",
]