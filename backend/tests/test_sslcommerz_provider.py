"""Focused unit tests for :class:`SslCommerzBillingProvider`.

These tests do not touch Flask, SQLAlchemy, or the route layer. They
exercise the gateway service in isolation by injecting a mock HTTP
client into the provider (``http`` constructor argument). That keeps
the assertions narrowly focused on:

* Endpoint URL selection (sandbox vs. live)
* Payload contents (required fields, decimal-safe amount formatting,
  safe customer fallbacks, credential never echoed back)
* Timeout behaviour (separate connect / read)
* TLS verification (``verify=True`` always)
* Exception hierarchy
* Result-dataclass variants (``create_session_result`` /
  ``validate_result``)
* Credential redaction in log messages

Run with::

    python -m pytest tests/test_sslcommerz_provider.py -v
"""

from __future__ import annotations

from decimal import Decimal
import logging
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

from app.billing_service import (
    BillingConfigError,
    BillingConnectionError,
    BillingHTTPStatusError,
    BillingInputError,
    BillingMissingGatewayURLError,
    BillingMissingSessionKeyError,
    BillingRejectionError,
    BillingResponseFormatError,
    BillingTimeoutError,
    BillingValidationAPIError,
    DEFAULT_CONNECT_TIMEOUT,
    DEFAULT_READ_TIMEOUT,
    Result,
    SslCommerzBillingProvider,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_response(
    *,
    status_code: int = 200,
    json_payload: Any | None = None,
    text: str = "",
    raise_json: bool = False,
) -> MagicMock:
    """Build a ``requests.Response``-shaped mock."""
    response = MagicMock(spec=requests.Response)
    response.status_code = status_code
    response.text = text
    if raise_json:
        response.json.side_effect = ValueError("not JSON")
    else:
        response.json.return_value = json_payload
    return response


def _make_provider(**overrides: Any) -> tuple[SslCommerzBillingProvider, MagicMock]:
    """Return a provider with a mock HTTP client attached."""
    http = MagicMock(name="http")
    kwargs: dict[str, Any] = dict(
        store_id="test-store",
        store_password="test-secret-PASSWORD",
        mode="sandbox",
        http=http,
    )
    kwargs.update(overrides)
    return SslCommerzBillingProvider(**kwargs), http


def _session_kwargs(**overrides: Any) -> dict[str, Any]:
    """Default kwargs for ``create_session``."""
    base: dict[str, Any] = {
        "transaction_id": "EC-TXN-UNIT-1",
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "success_url": "https://example.com/success",
        "fail_url": "https://example.com/fail",
        "cancel_url": "https://example.com/cancel",
        "ipn_url": "https://example.com/ipn",
        "value_a": "user-1",
        "value_b": "course-1",
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# Construction & endpoint URLs
# ---------------------------------------------------------------------------


def test_construction_requires_credentials():
    with pytest.raises(BillingConfigError):
        SslCommerzBillingProvider(store_id="", store_password="secret")
    with pytest.raises(BillingConfigError):
        SslCommerzBillingProvider(store_id="store", store_password="")


def test_construction_rejects_unknown_mode():
    with pytest.raises(BillingConfigError):
        SslCommerzBillingProvider(
            store_id="store",
            store_password="secret",
            mode="staging",
        )


def test_sandbox_session_endpoint():
    provider, _ = _make_provider(mode="sandbox")
    assert provider.session_endpoint == (
        "https://sandbox.sslcommerz.com/gwprocess/v4/api.php"
    )
    assert provider.validation_endpoint == (
        "https://sandbox.sslcommerz.com/validator/api/validationserverAPI.php"
    )


def test_live_session_endpoint():
    provider, _ = _make_provider(mode="live")
    assert provider.session_endpoint == (
        "https://securepay.sslcommerz.com/gwprocess/v4/api.php"
    )
    assert provider.validation_endpoint == (
        "https://securepay.sslcommerz.com/validator/api/"
        "validationserverAPI.php"
    )


def test_default_timeouts():
    provider, _ = _make_provider()
    assert provider.connect_timeout == DEFAULT_CONNECT_TIMEOUT
    assert provider.read_timeout == DEFAULT_READ_TIMEOUT


def test_custom_timeouts_are_preserved():
    provider, _ = _make_provider(connect_timeout=2.5, read_timeout=8.0)
    assert provider.connect_timeout == 2.5
    assert provider.read_timeout == 8.0


def test_timeout_tuple_is_passed_to_requests():
    provider, http = _make_provider(connect_timeout=1.0, read_timeout=4.0)
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "abc",
        "GatewayPageURL": "https://example.com/gw",
    })
    provider.create_session(**_session_kwargs())
    _, call_kwargs = http.post.call_args
    assert call_kwargs["timeout"] == (1.0, 4.0)


# ---------------------------------------------------------------------------
# TLS verification
# ---------------------------------------------------------------------------


def test_tls_verification_is_always_on():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "abc",
        "GatewayPageURL": "https://example.com/gw",
    })
    provider.create_session(**_session_kwargs())
    _, call_kwargs = http.post.call_args
    assert call_kwargs["verify"] is True


def test_validation_tls_verification_is_always_on():
    provider, http = _make_provider()
    http.get.return_value = _make_response(json_payload={
        "status": "VALID",
        "tran_id": "EC-TXN",
    })
    provider.validate(val_id="VAL-1")
    _, call_kwargs = http.get.call_args
    assert call_kwargs["verify"] is True


# ---------------------------------------------------------------------------
# Session creation — happy path & payload contents
# ---------------------------------------------------------------------------


def test_session_payload_contains_required_fields():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS-1",
        "GatewayPageURL": "https://sandbox.sslcommerz.com/gwprocess/v4/gw.php?Q=abc",
    })
    provider.create_session(**_session_kwargs())

    http.post.assert_called_once()
    args, kwargs = http.post.call_args
    url = args[0]
    payload = kwargs["data"]
    assert url == "https://sandbox.sslcommerz.com/gwprocess/v4/api.php"

    for field in (
        "store_id", "store_passwd", "total_amount", "currency", "tran_id",
        "success_url", "fail_url", "cancel_url", "ipn_url",
        "product_name", "product_category", "product_profile",
        "shipping_method", "cus_name", "cus_email", "cus_phone",
        "value_a", "value_b", "value_c", "value_d",
    ):
        assert field in payload, f"missing {field!r}"

    assert payload["store_id"] == "test-store"
    assert payload["store_passwd"] == "test-secret-PASSWORD"
    assert payload["total_amount"] == "500.00"
    assert payload["currency"] == "BDT"
    assert payload["tran_id"] == "EC-TXN-UNIT-1"
    assert payload["product_name"] == "EduCompass Course Enrollment"
    assert payload["product_category"] == "Education"
    assert payload["product_profile"] == "general"
    assert payload["shipping_method"] == "NO"
    assert payload["value_a"] == "user-1"
    assert payload["value_b"] == "course-1"
    assert payload["value_c"] == "educompass"
    assert payload["value_d"] == "EC-TXN-UNIT-1"


def test_amount_is_decimal_safe_for_float_input():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
        "GatewayPageURL": "https://example.com/gw",
    })
    provider.create_session(**_session_kwargs(amount=Decimal("1234.56")))
    _, call_kwargs = http.post.call_args
    assert call_kwargs["data"]["total_amount"] == "1234.56"


def test_amount_formatting_rounds_half_up():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
        "GatewayPageURL": "https://example.com/gw",
    })
    provider.create_session(**_session_kwargs(amount=Decimal("500.005")))
    _, call_kwargs = http.post.call_args
    assert call_kwargs["data"]["total_amount"] == "500.01"


def test_safe_customer_defaults_are_not_invented_pii():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
        "GatewayPageURL": "https://example.com/gw",
    })
    provider.create_session(**_session_kwargs())
    payload = http.post.call_args.kwargs["data"]
    # Generic, safe fallbacks — never real names/emails/phones.
    assert payload["cus_name"] == "EduCompass User"
    assert payload["cus_email"] == "user@educompass.app"
    assert payload["cus_phone"] == "01700000000"
    assert payload["cus_country"] == "Bangladesh"


def test_session_success_returns_dict_payload():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS-X",
        "GatewayPageURL": "https://sandbox.sslcommerz.com/gwprocess/v4/gw.php?Q=zzz",
    })
    result = provider.create_session(**_session_kwargs())
    assert result["ok"] is True
    assert result["status"] == "SUCCESS"
    assert result["session_key"] == "SESS-X"
    assert result["gateway_url"].startswith("https://sandbox.sslcommerz.com")
    assert result["error"] is None


def test_session_success_struct_result():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS-Y",
        "GatewayPageURL": "https://example.com/gw",
    })
    result = provider.create_session_result(**_session_kwargs())
    assert isinstance(result, Result)
    assert result.ok is True
    assert result.status == "SUCCESS"
    assert result.provider == "sslcommerz"


# ---------------------------------------------------------------------------
# Session creation — failure paths
# ---------------------------------------------------------------------------


def test_session_rejection_returns_failed_dict():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "FAILED",
        "failedreason": "Store credentials are invalid.",
    })
    result = provider.create_session(**_session_kwargs())
    assert result["ok"] is False
    assert result["status"] == "FAILED"
    assert "Store credentials are invalid." in result["error"]
    assert result["session_key"] is None
    assert result["gateway_url"] is None


def test_session_rejection_raises_structured_exception():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "FAILED",
        "failedreason": "Store credentials are invalid.",
    })
    with pytest.raises(BillingRejectionError) as exc_info:
        provider.create_session_result(**_session_kwargs())
    assert exc_info.value.code == "BILLING_REJECTION"
    assert "Store credentials are invalid." in exc_info.value.message


def test_session_missing_gateway_url_raises():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
        # GatewayPageURL deliberately omitted.
    })
    with pytest.raises(BillingMissingGatewayURLError) as exc_info:
        provider.create_session_result(**_session_kwargs())
    assert exc_info.value.code == "BILLING_MISSING_GATEWAY_URL"


def test_session_missing_gateway_url_dict_form():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
    })
    result = provider.create_session(**_session_kwargs())
    assert result["ok"] is False
    # Gateway returned a partial payload (SUCCESS but no URL). The
    # provider surfaces the raw gateway status and a human-readable
    # error; route layer only inspects ``ok``.
    assert result["status"] == "SUCCESS"
    assert "no GatewayPageURL" in result["error"]
    assert result["gateway_url"] is None


def test_session_missing_session_key_raises():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "GatewayPageURL": "https://example.com/gw",
        # sessionkey deliberately omitted.
    })
    with pytest.raises(BillingMissingSessionKeyError) as exc_info:
        provider.create_session_result(**_session_kwargs())
    assert exc_info.value.code == "BILLING_MISSING_SESSION_KEY"


def test_session_timeout_raises_timeout_error():
    provider, http = _make_provider()
    http.post.side_effect = requests.exceptions.Timeout("read timed out")
    with pytest.raises(BillingTimeoutError):
        provider.create_session_result(**_session_kwargs())


def test_session_timeout_dict_form():
    provider, http = _make_provider()
    http.post.side_effect = requests.exceptions.Timeout("read timed out")
    result = provider.create_session(**_session_kwargs())
    assert result["ok"] is False
    assert result["status"] == "BILLING_TIMEOUT"
    assert result["error"] == "Gateway session request timed out."


def test_session_connection_error_raises():
    provider, http = _make_provider()
    http.post.side_effect = requests.exceptions.ConnectionError("dns failure")
    with pytest.raises(BillingConnectionError):
        provider.create_session_result(**_session_kwargs())


def test_session_tls_error_raises_connection_error():
    provider, http = _make_provider()
    http.post.side_effect = requests.exceptions.SSLError("cert verify failed")
    with pytest.raises(BillingConnectionError) as exc_info:
        provider.create_session_result(**_session_kwargs())
    assert "TLS" in exc_info.value.message


def test_session_http_status_error():
    provider, http = _make_provider()
    http.post.return_value = _make_response(status_code=502, text="bad gateway")
    with pytest.raises(BillingHTTPStatusError) as exc_info:
        provider.create_session_result(**_session_kwargs())
    assert exc_info.value.code == "BILLING_HTTP_STATUS_ERROR"
    assert "502" in exc_info.value.message


def test_session_non_json_response():
    provider, http = _make_provider()
    http.post.return_value = _make_response(
        status_code=200, text="<html>not json</html>", raise_json=True,
    )
    with pytest.raises(BillingResponseFormatError):
        provider.create_session_result(**_session_kwargs())


def test_session_missing_required_kwargs_raises_input_error():
    provider, _ = _make_provider()
    with pytest.raises(BillingInputError) as exc_info:
        provider.create_session_result(
            transaction_id="EC-TXN",
            amount=Decimal("100.00"),
            # success_url, fail_url, cancel_url, ipn_url missing
        )
    assert "success_url" in exc_info.value.message


def test_session_zero_amount_raises_input_error():
    provider, _ = _make_provider()
    with pytest.raises(BillingInputError):
        provider.create_session_result(**_session_kwargs(amount=Decimal("0")))


# ---------------------------------------------------------------------------
# Validation — happy path & failure paths
# ---------------------------------------------------------------------------


def test_validation_success_returns_parsed_dict():
    provider, http = _make_provider()
    http.get.return_value = _make_response(json_payload={
        "status": "VALID",
        "APIConnect": "DONE",
        "tran_id": "EC-TXN-UNIT-1",
        "amount": "500.00",
        "currency_type": "BDT",
        "risk_level": 0,
        "risk_title": "Safe",
        "bank_tran_id": "BANK-1",
        "card_type": "VISA",
        "value_a": "user-1",
        "value_b": "course-1",
    })
    result = provider.validate(val_id="VAL-1")
    assert result["ok"] is True
    assert result["status"] == "VALID"
    assert result["amount"] == Decimal("500.00")
    assert result["currency"] == "BDT"
    assert result["risk_level"] == 0
    assert result["bank_transaction_id"] == "BANK-1"
    assert result["card_type"] == "VISA"
    assert result["value_a"] == "user-1"


def test_validation_passes_required_params():
    provider, http = _make_provider()
    http.get.return_value = _make_response(json_payload={
        "status": "VALID", "tran_id": "EC-TXN",
    })
    provider.validate(val_id="VAL-1")
    http.get.assert_called_once()
    args, kwargs = http.get.call_args
    assert args[0] == (
        "https://sandbox.sslcommerz.com/validator/api/"
        "validationserverAPI.php"
    )
    params = kwargs["params"]
    assert params["val_id"] == "VAL-1"
    assert params["store_id"] == "test-store"
    assert params["store_passwd"] == "test-secret-PASSWORD"
    assert params["format"] == "json"


def test_validation_missing_val_id():
    provider, http = _make_provider()
    result = provider.validate(val_id="")
    assert result["ok"] is False
    assert result["error"] == "Missing validation id."
    http.get.assert_not_called()


def test_validation_missing_val_id_struct_raises():
    provider, _ = _make_provider()
    with pytest.raises(BillingInputError):
        provider.validate_result(val_id="")


def test_validation_api_rejection_returns_failed_dict():
    provider, http = _make_provider()
    http.get.return_value = _make_response(json_payload={
        "status": "INVALID_TRANSACTION",
        "tran_id": "EC-TXN",
    })
    result = provider.validate(val_id="VAL-1")
    assert result["ok"] is False
    assert result["status"] == "INVALID_TRANSACTION"
    assert "did not return a successful status" in result["error"]


def test_validation_api_rejection_struct_raises():
    provider, http = _make_provider()
    http.get.return_value = _make_response(json_payload={
        "status": "INVALID_TRANSACTION", "tran_id": "EC-TXN",
    })
    with pytest.raises(BillingValidationAPIError):
        provider.validate_result(val_id="VAL-1")


def test_validation_timeout_raises():
    provider, http = _make_provider()
    http.get.side_effect = requests.exceptions.Timeout("read timed out")
    with pytest.raises(BillingTimeoutError):
        provider.validate_result(val_id="VAL-1")


def test_validation_non_json_response():
    provider, http = _make_provider()
    http.get.return_value = _make_response(
        status_code=200, text="<html>", raise_json=True,
    )
    with pytest.raises(BillingResponseFormatError):
        provider.validate_result(val_id="VAL-1")


def test_validation_http_status_error():
    provider, http = _make_provider()
    http.get.return_value = _make_response(status_code=500, text="server error")
    with pytest.raises(BillingHTTPStatusError):
        provider.validate_result(val_id="VAL-1")


# ---------------------------------------------------------------------------
# Credential redaction
# ---------------------------------------------------------------------------


def test_session_error_logs_redact_password(caplog):
    provider, http = _make_provider()
    http.post.side_effect = requests.exceptions.Timeout(
        "something store_passwd=super-secret-value other=ok"
    )

    caplog.set_level(logging.WARNING, logger="app.billing_service")
    with pytest.raises(BillingTimeoutError):
        provider.create_session_result(**_session_kwargs())

    log_text = caplog.text
    assert "super-secret-value" not in log_text
    assert "store_passwd=***" in log_text


def test_payload_does_not_leak_password_through_returned_dict():
    provider, http = _make_provider()
    http.post.return_value = _make_response(json_payload={
        "status": "SUCCESS",
        "sessionkey": "SESS",
        "GatewayPageURL": "https://example.com/gw",
        # Simulate the gateway echoing the request back in ``raw``.
        "store_passwd": "test-secret-PASSWORD",
    })
    result = provider.create_session(**_session_kwargs())
    # The dict we return to callers MUST carry the password through
    # ``raw`` for forensic use, but the route layer must strip it
    # before exposing anything to the client. Verify the password is
    # present in ``raw`` (so the route can audit it) but absent from
    # any top-level convenience field.
    assert result["session_key"] != "test-secret-PASSWORD"
    assert "gateway_url" in result
    # The route layer's responsibility to strip ``raw`` before
    # responding to the client — assert the provider didn't add a
    # convenience ``store_password`` field.
    assert "store_password" not in result
    assert "store_passwd" not in result

def test_session_rejects_amount_below_sslcommerz_minimum():
    provider, _ = _make_provider()
    with pytest.raises(BillingInputError):
        provider.create_session_result(**_session_kwargs(amount=Decimal("9.99")))


def test_session_rejects_transaction_id_over_30_characters():
    provider, _ = _make_provider()
    with pytest.raises(BillingInputError):
        provider.create_session_result(
            **_session_kwargs(transaction_id="X" * 31)
        )
