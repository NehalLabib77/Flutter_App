"""SSLCOMMERZ payment routes for EduCompass."""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
import html
import json
import logging
import re
import time
import uuid
from urllib.parse import urlencode

from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Query

from .billing_service import FreeBillingProvider, get_billing_provider
from .database_models import (
    Enrollment,
    PAYMENT_STATUS_CANCELLED,
    PAYMENT_STATUS_FAILED,
    PAYMENT_STATUS_INITIATED,
    PAYMENT_STATUS_INITIATION_FAILED,
    PAYMENT_STATUS_PENDING,
    PAYMENT_STATUS_REVIEW_REQUIRED,
    PAYMENT_STATUS_VALID,
    PAYMENT_STATUS_VALIDATED,
    PAYMENT_STATUS_VALIDATION_FAILED,
    Payment,
    User,
    db,
)
from .firebase_client import upsert_user_enrollment


log = logging.getLogger(__name__)

payment_bp = Blueprint("payments", __name__, url_prefix="/api/v1/payments")

_VALID_GATEWAY_STATUSES = {PAYMENT_STATUS_VALID, PAYMENT_STATUS_VALIDATED}
_TERMINAL_STATUSES = {
    PAYMENT_STATUS_VALIDATED,
    PAYMENT_STATUS_REVIEW_REQUIRED,
    PAYMENT_STATUS_FAILED,
    PAYMENT_STATUS_CANCELLED,
    PAYMENT_STATUS_INITIATION_FAILED,
    PAYMENT_STATUS_VALIDATION_FAILED,
}

# Statuses that mean the payment is *securely* done and may not be
# downgraded by a later fail / cancel callback.
_SECURE_LOCKED_STATUSES = {PAYMENT_STATUS_VALIDATED}

# Validation result keys the gateway returns. Centralised so we don't
# typo a key in two places.
_GATEWAY_TRAN_ID = "tran_id"
_GATEWAY_AMOUNT = "amount"
_GATEWAY_CURRENCY = "currency"
_GATEWAY_CURRENCY_TYPE = "currency_type"
_GATEWAY_API_CONNECT = "APIConnect"
_GATEWAY_RISK_LEVEL = "risk_level"
_GATEWAY_RISK_TITLE = "risk_title"
_GATEWAY_BANK_TRAN_ID = "bank_tran_id"
_GATEWAY_CARD_TYPE = "card_type"
_GATEWAY_VALUE_A = "value_a"
_GATEWAY_VALUE_B = "value_b"
_GATEWAY_STATUS = "status"

_MIN_SSLC_AMOUNT = Decimal("10.00")
_MAX_SSLC_AMOUNT = Decimal("500000.00")

# Only these non-sensitive gateway fields may be retained for support.
_SAFE_GATEWAY_PAYLOAD_KEYS = {
    "status", "failedreason", "tran_id", "val_id", "amount",
    "currency", "currency_type", "APIConnect", "bank_tran_id",
    "card_type", "risk_level", "risk_title", "value_a", "value_b",
    "value_c", "value_d",
}


def _to_decimal(value: object) -> Decimal | None:
    try:
        return Decimal(str(value)).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError, TypeError):
        return None


def _lock_for_update(query: Query) -> Query:
    """Attach ``SELECT ... FOR UPDATE`` when the dialect supports it.

    PostgreSQL / MySQL gain a real row lock; SQLite (used in tests and
    local dev) silently downgrades to a plain SELECT because
    ``with_for_update`` is a no-op there. Either way the call is safe
    to make and keeps the existing SQLite-compatible tests intact.
    """
    try:
        dialect = query.session.bind.dialect.name if query.session.bind else ""
    except Exception:  # noqa: BLE001 - defensive: never let locking fail the request
        dialect = ""
    if dialect in {"postgresql", "mysql", "mariadb"}:
        return query.with_for_update()
    return query


def _json_error(message: str, *, status: int, code: str):
    return jsonify({"error": code, "message": message}), status


def _current_user() -> User | None:
    identity = get_jwt_identity()
    if identity is None:
        return None
    try:
        user_id = int(identity)
    except (TypeError, ValueError):
        return None
    return User.query.get(user_id)


def _transaction_id(user_id: int, course_id: str) -> str:
    """Generate a unique SSLCOMMERZ-compatible transaction id.

    SSLCOMMERZ limits ``tran_id`` to 30 characters. User/course ownership is
    stored in the Payment row and value_a/value_b; it is not encoded into the
    externally visible id.
    """
    stamp = int(time.time() * 1000)
    return f"EC{stamp}{uuid.uuid4().hex[:10]}"[:30].upper()


def _callback_urls() -> tuple[str, str, str, str]:
    base = (current_app.config.get("PUBLIC_BASE_URL") or "").strip().rstrip("/")
    if not base:
        base = request.host_url.rstrip("/")
    if current_app.config.get("PAYMENT_MODE", "sandbox").lower() != "sandbox" and not base.startswith("https://"):
        raise RuntimeError("PUBLIC_BASE_URL must be an HTTPS URL in live mode.")
    return (
        f"{base}/api/v1/payments/sslcommerz/success",
        f"{base}/api/v1/payments/sslcommerz/fail",
        f"{base}/api/v1/payments/sslcommerz/cancel",
        f"{base}/api/v1/payments/sslcommerz/ipn",
    )


def _deep_link_status(status: str) -> str:
    normalized = (status or "").upper()
    if normalized in {
        PAYMENT_STATUS_VALIDATED,
        PAYMENT_STATUS_REVIEW_REQUIRED,
        PAYMENT_STATUS_FAILED,
        PAYMENT_STATUS_CANCELLED,
        PAYMENT_STATUS_VALIDATION_FAILED,
    }:
        return normalized
    return PAYMENT_STATUS_PENDING


def _render_callback_html(transaction_id: str, status: str, message: str):
    app_return = (
        (current_app.config.get("APP_RETURN_URI") or "educompass://payment/return")
        .strip()
    )
    final_status = _deep_link_status(status)
    deep_link = f"{app_return}?{urlencode({'transaction_id': transaction_id, 'status': final_status})}"
    safe_message = html.escape(message)
    safe_title = html.escape(final_status.replace("_", " ").title())
    safe_transaction = html.escape(transaction_id or "Unavailable")
    safe_link = html.escape(deep_link, quote=True)
    javascript_link = json.dumps(deep_link)
    success = final_status == PAYMENT_STATUS_VALIDATED
    accent = "#16a36a" if success else "#c46a17"
    icon = "✓" if success else "!"
    content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>EduCompass Payment {safe_title}</title>
  <style>
    *{{box-sizing:border-box}} body{{margin:0;background:#f4f7fb;color:#132238;font-family:Inter,Segoe UI,Arial,sans-serif}}
    main{{min-height:100vh;display:grid;place-items:center;padding:24px}}
    section{{width:min(100%,430px);background:#fff;border:1px solid #dbe5f1;border-radius:24px;padding:30px;box-shadow:0 18px 45px rgba(24,55,96,.12);text-align:center}}
    .icon{{width:68px;height:68px;margin:0 auto 18px;border-radius:50%;display:grid;place-items:center;background:{accent}18;border:2px solid {accent};color:{accent};font-size:36px;font-weight:800}}
    h1{{margin:0 0 10px;font-size:26px}} p{{margin:0;color:#5d6c80;line-height:1.55}}
    dl{{margin:24px 0;text-align:left;display:grid;grid-template-columns:92px 1fr;gap:10px}} dt{{color:#6b7a90}} dd{{margin:0;overflow-wrap:anywhere;font-weight:650}}
    a{{display:block;background:#1f4f8c;color:#fff;text-decoration:none;padding:14px 18px;border-radius:14px;font-weight:750}}
    small{{display:block;margin-top:14px;color:#7a8798}}
  </style>
</head>
<body><main><section>
  <div class="icon">{icon}</div><h1>{safe_title}</h1><p>{safe_message}</p>
  <dl><dt>Status</dt><dd>{safe_title}</dd><dt>Reference</dt><dd>{safe_transaction}</dd></dl>
  <a href="{safe_link}">Return to EduCompass</a>
  <small>The app will open automatically.</small>
</section></main>
<script>setTimeout(function(){{window.location.href={javascript_link};}},900);</script>
</body></html>"""
    return content, 200, {"Content-Type": "text/html; charset=utf-8"}


def _request_payload() -> dict[str, str]:
    payload: dict[str, str] = {}
    if request.form:
        payload.update({k: str(v) for k, v in request.form.items()})
    if request.is_json:
        body = request.get_json(silent=True) or {}
        if isinstance(body, dict):
            payload.update({k: str(v) for k, v in body.items()})
    if request.args:
        payload.update({k: str(v) for k, v in request.args.items()})
    return payload


def _resolve_course(course_id: str) -> dict | None:
    adapter = current_app.extensions.get("educompass_model")
    if adapter is None:
        return None
    try:
        row = adapter.get_course(course_id)
    except Exception:  # noqa: BLE001
        return None
    return row if isinstance(row, dict) else None


def _sandbox_default_price() -> Decimal | None:
    if current_app.config.get("PAYMENT_MODE", "sandbox").lower() != "sandbox":
        return None
    raw = (current_app.config.get("SANDBOX_DEFAULT_COURSE_PRICE_BDT") or "").strip()
    if not raw:
        return None
    amount = _to_decimal(raw)
    if amount is None or amount < _MIN_SSLC_AMOUNT or amount > _MAX_SSLC_AMOUNT:
        log.warning("Ignoring invalid SANDBOX_DEFAULT_COURSE_PRICE_BDT configuration.")
        return None
    return amount


def _price_or_sandbox_fallback(reason: str) -> tuple[Decimal | None, bool, str | None]:
    fallback = _sandbox_default_price()
    if fallback is not None:
        log.info("Using sandbox default course price because source price is %s.", reason)
        return fallback, False, "sandbox_default"
    return None, False, reason


def _resolve_course_price(course: dict) -> tuple[Decimal | None, bool, str | None]:
    is_free = bool(course.get("is_free") is True)
    if is_free:
        return Decimal("0.00"), True, None

    raw_price = course.get("price")
    if raw_price is None:
        return _price_or_sandbox_fallback("missing")

    if isinstance(raw_price, (int, float, Decimal)):
        amount = _to_decimal(raw_price)
        if amount is None:
            return None, False, "invalid"
        if amount < Decimal("0.00"):
            return None, False, "negative"
        if amount == Decimal("0.00"):
            return Decimal("0.00"), True, None
        return amount, False, None

    text = str(raw_price).strip()
    if not text:
        return _price_or_sandbox_fallback("missing")
    # Only honour the "free" keyword when ``is_free`` is explicitly set
    # on the course record. Otherwise a stray string like "free-for-you"
    # would silently downgrade the price to zero and bypass the
    # gateway — see ``test_invalid_price_string_rejected``.
    if is_free and "free" in text.lower():
        return Decimal("0.00"), True, None
    match = re.search(r"-?\d+(?:[.,]\d{1,2})?", text)
    if match is None:
        return _price_or_sandbox_fallback("unsupported")
    amount = _to_decimal(match.group(0).replace(",", "."))
    if amount is None:
        return None, False, "invalid"
    if amount < Decimal("0.00"):
        return None, False, "negative"
    if amount == Decimal("0.00"):
        return Decimal("0.00"), True, None
    return amount, False, None


def _upsert_enrollment(payment: Payment) -> bool:
    """Reuse the existing enrollment storage for a securely validated payment.

    Implementation mirrors ``POST /api/v1/me/enrollments`` exactly so there
    is a single source of truth for the user-course enrollment row. The
    ``UniqueConstraint(user_id, course_id)`` enforces idempotency at the
    DB layer — repeated calls cannot create a second ``Enrollment`` row.

    Returns ``True`` only after both the SQL row and the Firestore
    enrollment document (``users/{uid}/enrollments/{course_id}``) are
    written successfully. SQL failures short-circuit before the
    Firestore write so a Firestore outage does not leave a "successful"
    partial state on the client.
    """
    user = User.query.get(payment.user_id)
    if user is None:
        log.warning(
            "Validated payment references missing user: transaction_id=%s user_id=%s",
            payment.transaction_id,
            payment.user_id,
        )
        return False

    payment_method = payment.card_type or "sslcommerz"
    payment_status = PAYMENT_STATUS_VALIDATED

    try:
        enrollment = Enrollment.query.filter_by(
            user_id=payment.user_id,
            course_id=payment.course_id,
        ).first()
        if enrollment is None:
            enrollment = Enrollment(
                user_id=payment.user_id,
                course_id=payment.course_id,
                payment_method=payment_method,
                transaction_id=payment.transaction_id,
                payment_status=payment_status,
            )
            db.session.add(enrollment)
        else:
            # Idempotent refresh: keep the original enrolled_at by leaving
            # it untouched, but always update the mutable payment fields so
            # a retry against a new transaction id reflects the latest
            # one. ``payment_method`` on an existing row is preserved so a
            # pre-existing free-course row (``payment_method='free'``) is
            # not clobbered by a paid retry that arrives later.
            enrollment.transaction_id = payment.transaction_id
            enrollment.payment_status = payment_status
            if not enrollment.payment_method:
                enrollment.payment_method = payment_method
        db.session.flush()
    except SQLAlchemyError:
        log.exception(
            "Enrollment SQL upsert failed for transaction_id=%s user_id=%s course_id=%s",
            payment.transaction_id, payment.user_id, payment.course_id,
        )
        db.session.rollback()
        return False

    if not user.firebase_uid:
        # No Firebase uid means the user has no Firestore mirror yet.
        # The SQL row is sufficient — callers should treat this as
        # success. (matches the rest of the codebase.)
        return True

    try:
        ok = upsert_user_enrollment(
            user.firebase_uid,
            course_id=payment.course_id,
            payment_method=payment_method,
            transaction_id=payment.transaction_id,
            payment_status=payment_status,
        )
    except Exception:  # noqa: BLE001 — never let Firestore kill the SQL path
        log.exception(
            "Firestore enrollment sync raised for transaction_id=%s user_id=%s",
            payment.transaction_id, payment.user_id,
        )
        return False

    if not ok:
        log.warning(
            "Firestore enrollment sync reported failure for transaction_id=%s user_id=%s",
            payment.transaction_id, payment.user_id,
        )
        return False

    return True


def _retry_enrollment_for_payment(payment: Payment) -> bool:
    """Retry the enrollment side-effect for a validated payment that
    was confirmed by the gateway but whose local enrollment failed
    (transient Firestore outage, prior process crash, etc.).

    Contract
    --------
    * Only acts when the payment is ``VALIDATED`` with risk_level != 1
      and ``enrollment_completed`` is False. Any other state is left
      untouched — never enrolls a ``REVIEW_REQUIRED``, ``FAILED``,
      ``CANCELLED``, ``PENDING`` or ``VALIDATION_FAILED`` payment.
    * Idempotent: re-running on an already-enrolled payment is a no-op.
    * Does not change ``status`` or ``validated`` — both stay True on
      success *and* on failure, so a later retry is still possible.
    * Returns True iff the SQL row exists *and* the Firestore sync
      reported success. The caller flips ``enrollment_completed``
      only on a True return so the flag stays a faithful mirror of
      the side-effect.
    """
    if payment is None:
        return False
    if payment.status != PAYMENT_STATUS_VALIDATED:
        return False
    if not payment.validated:
        return False
    if payment.risk_level == 1:
        # REVIEW_REQUIRED is by design not enrolled yet — see
        # ``_validate_payment``.
        return False
    if payment.enrollment_completed:
        return False

    ok = _upsert_enrollment(payment)
    payment.enrollment_completed = bool(ok)
    try:
        db.session.commit()
    except SQLAlchemyError:
        log.exception(
            "Failed to commit enrollment retry for transaction_id=%s user_id=%s",
            payment.transaction_id, payment.user_id,
        )
        db.session.rollback()
        return False
    if not ok:
        # State preservation: status, validated, and the explicit
        # enrollment_completed=False remain in place so a later
        # /status poll (or admin action) can retry.
        log.warning(
            "Enrollment retry did not complete for transaction_id=%s user_id=%s course_id=%s",
            payment.transaction_id, payment.user_id, payment.course_id,
        )
    return ok


def _mark_validation_failed(payment: Payment, reason: str) -> None:
    payment.status = PAYMENT_STATUS_VALIDATION_FAILED
    payment.validated = False
    payment.enrollment_completed = False
    payment.risk_title = reason[:255]


def _store_gateway_payload(payment: Payment, payload: dict) -> None:
    """Store only allow-listed, non-sensitive gateway metadata.

    Customer fields, credentials, card numbers and raw request bodies are never
    persisted. The structured Payment columns remain the source of truth.
    """
    safe = {
        key: payload.get(key)
        for key in _SAFE_GATEWAY_PAYLOAD_KEYS
        if key in payload and payload.get(key) not in {None, ""}
    }
    try:
        payment.gateway_payload = json.dumps(safe, default=str)
    except (ValueError, TypeError):
        payment.gateway_payload = "{}"


def _persist_gateway_meta(payment: Payment, raw: dict) -> None:
    """Persist validation metadata fields on the Payment row.

    Called on both success and failure paths so the row carries the
    gateway's response even when validation ultimately fails — useful
    for support / fraud review.
    """
    if not raw:
        return
    if raw.get(_GATEWAY_BANK_TRAN_ID) or raw.get("bank_transaction_id"):
        payment.bank_transaction_id = str(
            raw.get(_GATEWAY_BANK_TRAN_ID) or raw.get("bank_transaction_id") or ""
        ) or None
    if raw.get(_GATEWAY_CARD_TYPE):
        payment.card_type = str(raw.get(_GATEWAY_CARD_TYPE) or "") or payment.card_type
    if raw.get(_GATEWAY_RISK_TITLE):
        payment.risk_title = str(raw.get(_GATEWAY_RISK_TITLE) or "") or None
    risk_level = raw.get(_GATEWAY_RISK_LEVEL)
    if risk_level is not None:
        try:
            payment.risk_level = int(risk_level)
        except (ValueError, TypeError):
            payment.risk_level = None


def _validate_payment(payment: Payment, payload: dict[str, str]) -> Payment:
    """Shared idempotent validator used by IPN and the success callback.

    Contract
    --------
    * ``payment`` is the local record selected by ``tran_id``. The
      gateway's POST is **never** trusted as the source of truth for
      amount / currency / user / course — those fields live on the
      Payment row.
    * Acquires a row-level lock when the SQLAlchemy dialect supports
      it so two simultaneous callbacks cannot race.
    * If the payment is already ``VALIDATED`` the function is a no-op:
      repeated validation calls return a stable result.
    * Persists ``validation_id``, ``bank_transaction_id``, ``card_type``,
      ``risk_level``, ``risk_title`` on every successful / failed
      attempt.
    * Delegates the actual enrollment side-effect to the
      :func:`_upsert_enrollment` hook (kept as a single chokepoint so
      the next step can swap it out cleanly).
    """
    # Re-load the row under a lock so concurrent IPN/success callbacks
    # don't clobber each other. No-op on SQLite.
    locked = _lock_for_update(
        Payment.query.filter_by(transaction_id=payment.transaction_id)
    ).first()
    if locked is not None:
        payment = locked

    # Stable re-validation: already-validated payments do nothing.
    if payment.status == PAYMENT_STATUS_VALIDATED and payment.validated:
        return payment

    val_id = (payload.get("val_id") or "").strip()
    if not val_id:
        # Spec: missing validation ID is a validation failure, not
        # success. We deliberately do NOT silently keep a PENDING
        # status — the gateway must produce a val_id before we accept
        # the payment as paid.
        _mark_validation_failed(payment, "Missing validation id.")
        _store_gateway_payload(payment, {})
        return payment

    provider = get_billing_provider()
    validation = provider.validate(val_id=val_id)
    raw = validation.get("raw") or {}
    _store_gateway_payload(payment, raw)
    _persist_gateway_meta(payment, raw)

    if not validation.get("ok"):
        _mark_validation_failed(payment, "Gateway validation request failed.")
        return payment

    status = str(validation.get("status") or "").upper()
    api_connect = validation.get("api_connect")
    tran_id = str(validation.get("tran_id") or "")
    amount = validation.get("amount")
    currency = str(validation.get("currency") or "").upper()

    if status not in _VALID_GATEWAY_STATUSES:
        _mark_validation_failed(payment, "Gateway status is not VALID/VALIDATED.")
        return payment

    if api_connect and str(api_connect).upper() != "DONE":
        _mark_validation_failed(payment, "Gateway APIConnect is not DONE.")
        return payment

    if tran_id != payment.transaction_id:
        _mark_validation_failed(payment, "Transaction ID mismatch.")
        return payment

    if amount is None or amount != _to_decimal(payment.amount):
        _mark_validation_failed(payment, "Amount mismatch.")
        return payment

    if currency != "BDT":
        _mark_validation_failed(payment, "Currency mismatch.")
        return payment

    raw_value_a = raw.get(_GATEWAY_VALUE_A)
    if raw_value_a is not None and str(raw_value_a) != str(payment.user_id):
        _mark_validation_failed(payment, "User reference mismatch.")
        return payment

    raw_value_b = raw.get(_GATEWAY_VALUE_B)
    if raw_value_b is not None and str(raw_value_b) != str(payment.course_id):
        _mark_validation_failed(payment, "Course reference mismatch.")
        return payment

    # All gateway-side checks passed. Persist validation_id and decide
    # the final status based on risk_level.
    payment.validation_id = val_id
    payment.validated = True

    if payment.risk_level == 1:
        # Risk-level-1 payments are VALIDATED but require human review
        # — do NOT enroll yet. The next-step hook can flip them to
        # VALIDATED after review.
        payment.status = PAYMENT_STATUS_REVIEW_REQUIRED
        payment.enrollment_completed = False
        return payment

    payment.status = PAYMENT_STATUS_VALIDATED

    # Run the enrollment side-effect through the shared chokepoint so
    # there is exactly one place that creates / refreshes an enrollment
    # row and syncs Firestore. On failure we deliberately keep the
    # payment in ``VALIDATED`` state — the gateway has blessed the
    # payment; the local enrollment side-effect can be retried later
    # via ``_retry_enrollment_for_payment``.
    payment.enrollment_completed = _upsert_enrollment(payment)
    return payment


def _normalize_existing_status(payment: Payment) -> str:
    """Normalize and self-heal a known payment row.

    Called from ``/status/<txn>`` (and only there). For a ``VALIDATED``
    payment that somehow lost its enrollment side-effect — e.g. the
    Firestore write failed and the row was committed without
    ``enrollment_completed=True``, or a process crashed mid-flight —
    we re-run the retry helper. The retry helper itself is idempotent
    and short-circuits on any non-eligible state, so it is safe to
    call here.
    """
    status = (payment.status or "").upper()
    if status in _TERMINAL_STATUSES:
        if status == PAYMENT_STATUS_VALIDATED and not payment.enrollment_completed:
            _retry_enrollment_for_payment(payment)
            db.session.commit()
        return status
    return status


@payment_bp.post("/sslcommerz/session")
@jwt_required()
def create_sslcommerz_session():
    user = _current_user()
    if user is None:
        return _json_error("JWT is required.", status=401, code="UNAUTHORIZED")

    body = request.get_json(silent=True) or {}
    if not isinstance(body, dict):
        return _json_error("Request body must be a JSON object.", status=400, code="BAD_REQUEST")

    course_id = str(body.get("course_id") or "").strip()
    if not course_id:
        return _json_error("course_id is required.", status=400, code="MISSING_COURSE_ID")

    course = _resolve_course(course_id)
    if not course:
        return _json_error("Course not found.", status=404, code="COURSE_NOT_FOUND")

    amount, is_free, reason = _resolve_course_price(course)
    if amount is None:
        msg = "Unsupported course price."
        if reason == "missing":
            msg = "Course price is missing."
        elif reason == "negative":
            msg = "Course price cannot be negative."
        elif reason == "invalid":
            msg = "Course price is invalid."
        return _json_error(msg, status=400, code="INVALID_COURSE_PRICE")

    existing_enrollment = Enrollment.query.filter_by(
        user_id=user.id,
        course_id=course_id,
    ).first()
    if existing_enrollment is not None:
        return _json_error(
            "Already enrolled in this course.",
            status=409,
            code="ALREADY_ENROLLED",
        )

    if is_free:
        transaction_id = _transaction_id(user.id, course_id)
        payment = Payment(
            transaction_id=transaction_id,
            user_id=user.id,
            course_id=course_id,
            amount=Decimal("0.00"),
            currency="BDT",
            status=PAYMENT_STATUS_VALIDATED,
            validated=True,
            enrollment_completed=False,
        )
        db.session.add(payment)
        payment.enrollment_completed = _upsert_enrollment(payment)
        db.session.commit()
        return jsonify({
            "transaction_id": transaction_id,
            "gateway_url": None,
            "status": PAYMENT_STATUS_VALIDATED,
            "mode": (current_app.config.get("PAYMENT_MODE") or "sandbox").lower(),
            "course_id": course_id,
            "amount": "0.00",
            "currency": "BDT",
            "enrollment_completed": bool(payment.enrollment_completed),
        }), 200

    if amount <= Decimal("0.00"):
        return _json_error(
            "Paid course amount must be greater than zero.",
            status=400,
            code="INVALID_COURSE_PRICE",
        )

    if amount < _MIN_SSLC_AMOUNT or amount > _MAX_SSLC_AMOUNT:
        return _json_error(
            "SSLCOMMERZ course price must be between BDT 10.00 and BDT 500,000.00.",
            status=400,
            code="UNSUPPORTED_PAYMENT_AMOUNT",
        )

    provider = get_billing_provider()
    if isinstance(provider, FreeBillingProvider):
        return _json_error(
            "Payment provider is not configured on this server.",
            status=503,
            code="PAYMENT_PROVIDER_UNAVAILABLE",
        )

    existing_payment = (
        Payment.query.filter_by(user_id=user.id, course_id=course_id)
        .order_by(Payment.created_at.desc())
        .first()
    )
    existing_amount = (
        _to_decimal(existing_payment.amount) if existing_payment is not None else None
    )
    if (
        existing_payment is not None
        and existing_payment.status == PAYMENT_STATUS_PENDING
        and existing_payment.gateway_url
        and existing_amount == amount
        and _MIN_SSLC_AMOUNT <= existing_amount <= _MAX_SSLC_AMOUNT
    ):
        return jsonify({
            "transaction_id": existing_payment.transaction_id,
            "gateway_url": existing_payment.gateway_url,
            "status": PAYMENT_STATUS_PENDING,
            "mode": (current_app.config.get("PAYMENT_MODE") or "sandbox").lower(),
            "course_id": existing_payment.course_id,
            "amount": f"{existing_amount:.2f}",
            "currency": existing_payment.currency or "BDT",
        }), 200
    if (
        existing_payment is not None
        and existing_payment.status in {PAYMENT_STATUS_INITIATED, PAYMENT_STATUS_PENDING}
    ):
        # A stale/invalid pending row must not be reused after the server-side
        # course price changes or a previous session failed to get a URL.
        existing_payment.status = PAYMENT_STATUS_INITIATION_FAILED
        db.session.commit()

    transaction_id = _transaction_id(user.id, course_id)
    payment = Payment(
        transaction_id=transaction_id,
        user_id=user.id,
        course_id=course_id,
        amount=amount,
        currency="BDT",
        status=PAYMENT_STATUS_INITIATED,
    )
    db.session.add(payment)
    db.session.commit()

    try:
        success_url, fail_url, cancel_url, ipn_url = _callback_urls()
        session = provider.create_session(
            user_id=user.id,
            course_id=course_id,
            course_name=str(course.get("course_name") or course_id),
            amount=str(amount),
            currency="BDT",
            transaction_id=transaction_id,
            success_url=success_url,
            fail_url=fail_url,
            cancel_url=cancel_url,
            ipn_url=ipn_url,
            customer={
                "name": user.full_name,
                "email": user.email,
                "phone": user.phone_number or "01700000000",
            },
            value_a=str(user.id),
            value_b=str(course_id),
            value_c="educompass",
            value_d=transaction_id,
        )
    except Exception:  # noqa: BLE001 -- return a safe gateway error
        log.exception("SSLCOMMERZ session creation raised for transaction_id=%s", transaction_id)
        payment.status = PAYMENT_STATUS_INITIATION_FAILED
        db.session.commit()
        return _json_error(
            "Could not initiate payment session.",
            status=502,
            code="GATEWAY_SESSION_FAILED",
        )

    _store_gateway_payload(payment, session.get("raw") or {})
    if not session.get("ok"):
        payment.status = PAYMENT_STATUS_INITIATION_FAILED
        db.session.commit()
        return _json_error(
            "Could not initiate payment session.",
            status=502,
            code="GATEWAY_SESSION_FAILED",
        )

    payment.session_key = str(session.get("session_key") or "") or None
    payment.gateway_url = str(session.get("gateway_url") or "") or None
    payment.status = PAYMENT_STATUS_PENDING
    db.session.commit()

    return jsonify({
        "transaction_id": transaction_id,
        "gateway_url": payment.gateway_url,
        "status": PAYMENT_STATUS_PENDING,
        "mode": (current_app.config.get("PAYMENT_MODE") or "sandbox").lower(),
        "course_id": course_id,
        "amount": f"{amount:.2f}",
        "currency": "BDT",
    }), 200


@payment_bp.route("/sslcommerz/ipn", methods=["POST"])
def sslcommerz_ipn():
    """Public IPN — no JWT, no enrollment side-effect on its own.

    The gateway POST is **not** trusted as proof of payment. We look
    up the local Payment by ``tran_id`` and call the shared
    :func:`_validate_payment` which performs its own Order Validation
    API call against the gateway. Repeated IPNs are safe: the shared
    validator is idempotent.
    """
    payload = _request_payload()
    transaction_id = (payload.get("tran_id") or "").strip()
    if not transaction_id:
        return jsonify({"status": "FAIL", "message": "missing tran_id"}), 400

    payment = Payment.query.filter_by(transaction_id=transaction_id).first()
    if payment is None:
        return jsonify({"status": "FAIL", "message": "unknown transaction"}), 404

    payment = _validate_payment(payment, payload)
    db.session.commit()

    if payment.status in {PAYMENT_STATUS_VALIDATED, PAYMENT_STATUS_REVIEW_REQUIRED}:
        return jsonify({"status": "OK"}), 200
    return jsonify({"status": "FAIL"}), 200


@payment_bp.route("/sslcommerz/success", methods=["GET", "POST"])
def sslcommerz_success():
    """User-return URL.

    We *do not* trust the callback as proof — we still call the
    shared validator, which re-checks the gateway before marking the
    Payment VALIDATED. If validation has already completed (IPN arrived
    first), the shared validator short-circuits.
    """
    payload = _request_payload()
    transaction_id = (payload.get("tran_id") or "").strip()
    if not transaction_id:
        return _render_callback_html("", PAYMENT_STATUS_VALIDATION_FAILED, "Missing transaction id.")

    payment = Payment.query.filter_by(transaction_id=transaction_id).first()
    if payment is None:
        return _render_callback_html(transaction_id, PAYMENT_STATUS_VALIDATION_FAILED, "Unknown transaction.")

    if payment.status not in _TERMINAL_STATUSES:
        payment = _validate_payment(payment, payload)
        db.session.commit()

    final_status = _deep_link_status(payment.status)
    return _render_callback_html(transaction_id, final_status, "Payment processing complete. Returning to app.")


@payment_bp.route("/sslcommerz/fail", methods=["GET", "POST"])
def sslcommerz_fail():
    """User-return URL for failed payments.

    Only marks the Payment ``FAILED`` if it is not already *securely
    VALIDATED*. ``REVIEW_REQUIRED`` is allowed to downgrade because
    the gateway has not yet blessed the payment — review can happen
    later. The IPN flow handles the case where a fail callback arrives
    after a successful validation.
    """
    payload = _request_payload()
    transaction_id = (payload.get("tran_id") or "").strip()
    payment = Payment.query.filter_by(transaction_id=transaction_id).first() if transaction_id else None
    final_status = PAYMENT_STATUS_FAILED
    if payment is not None:
        if payment.status not in _SECURE_LOCKED_STATUSES:
            payment.status = PAYMENT_STATUS_FAILED
            payment.enrollment_completed = False
            _store_gateway_payload(payment, payload)
            db.session.commit()
        final_status = payment.status
    return _render_callback_html(transaction_id, final_status, "Payment failed. You can retry from EduCompass.")


@payment_bp.route("/sslcommerz/cancel", methods=["GET", "POST"])
def sslcommerz_cancel():
    """User-return URL for cancelled payments.

    Symmetric with :func:`sslcommerz_fail` — never downgrades a
    securely VALIDATED payment, but does downgrade ``REVIEW_REQUIRED``
    and any non-terminal state.
    """
    payload = _request_payload()
    transaction_id = (payload.get("tran_id") or "").strip()
    payment = Payment.query.filter_by(transaction_id=transaction_id).first() if transaction_id else None
    final_status = PAYMENT_STATUS_CANCELLED
    if payment is not None:
        if payment.status not in _SECURE_LOCKED_STATUSES:
            payment.status = PAYMENT_STATUS_CANCELLED
            payment.enrollment_completed = False
            _store_gateway_payload(payment, payload)
            db.session.commit()
        final_status = payment.status
    return _render_callback_html(transaction_id, final_status, "Payment cancelled. Returning to EduCompass.")


@payment_bp.get("/sslcommerz/status/<transaction_id>")
@jwt_required()
def sslcommerz_status(transaction_id: str):
    user = _current_user()
    if user is None:
        return _json_error("JWT is required.", status=401, code="UNAUTHORIZED")

    payment = Payment.query.filter_by(transaction_id=transaction_id).first()
    if payment is None:
        return _json_error("Transaction not found.", status=404, code="NOT_FOUND")
    if payment.user_id != user.id:
        return _json_error("Transaction not found.", status=404, code="NOT_FOUND")

    _normalize_existing_status(payment)
    db.session.commit()

    amount = _to_decimal(payment.amount) or Decimal("0.00")
    return jsonify({
        "transaction_id": payment.transaction_id,
        "course_id": payment.course_id,
        "status": payment.status,
        "amount": f"{amount:.2f}",
        "currency": payment.currency,
        "validated": bool(payment.validated),
        "enrollment_completed": bool(payment.enrollment_completed),
        "payment_method": payment.card_type or "SSLCOMMERZ",
        "card_type": payment.card_type,
        "bank_transaction_id": payment.bank_transaction_id,
        "risk_level": payment.risk_level,
        "risk_title": payment.risk_title,
        "updated_at": payment.updated_at.isoformat() if payment.updated_at else None,
    }), 200


@payment_bp.get("/status/<transaction_id>")
@jwt_required()
def sslcommerz_status_legacy(transaction_id: str):
    return sslcommerz_status(transaction_id)


@payment_bp.get("/provider")
def payment_provider_info():
    provider = get_billing_provider()
    mode = (current_app.config.get("PAYMENT_MODE") or "sandbox").lower()
    return jsonify({
        "provider": provider.name,
        "sandbox": bool(getattr(provider, "sandbox", mode != "live")),
        "mode": mode,
        "app_return_uri": current_app.config.get("APP_RETURN_URI") or "educompass://payment/return",
    }), 200


__all__ = ["payment_bp"]
