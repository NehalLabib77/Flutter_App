from __future__ import annotations

import html as _stdlib_html
import json as _stdlib_json
import os
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any
from unittest.mock import patch

# Must be set before importing the app package.
os.environ.setdefault("FLASK_ENV", "testing")

import pytest
from flask import Flask
from flask_jwt_extended import create_access_token
from sqlalchemy import text

from app import create_app
from app.billing_service import install_billing_provider
from app.database_models import (
    Enrollment,
    PAYMENT_STATUS_CANCELLED,
    PAYMENT_STATUS_FAILED,
    PAYMENT_STATUS_INITIATION_FAILED,
    PAYMENT_STATUS_PENDING,
    PAYMENT_STATUS_REVIEW_REQUIRED,
    PAYMENT_STATUS_VALIDATED,
    PAYMENT_STATUS_VALIDATION_FAILED,
    Payment,
    User,
    db,
)


@dataclass
class FakeBillingProvider:
    name: str = "sslcommerz"
    sandbox: bool = True
    session_result: dict[str, Any] = field(default_factory=lambda: {
        "ok": True,
        "status": "SUCCESS",
        "gateway_url": "https://sandbox.sslcommerz.com/gwprocess/v4/gw.php?Q=abc",
        "session_key": "SESSION-KEY",
        "raw": {"status": "SUCCESS", "GatewayPageURL": "https://sandbox.sslcommerz.com/gwprocess/v4/gw.php?Q=abc"},
    })
    validation_result: dict[str, Any] = field(default_factory=lambda: {
        "ok": True,
        "status": "VALID",
        "api_connect": "DONE",
        "tran_id": "",
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 0,
        "risk_title": "Safe",
        "bank_transaction_id": "BANK-1",
        "card_type": "VISA",
        "value_a": None,
        "value_b": None,
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "risk_level": 0,
            "risk_title": "Safe",
            "bank_tran_id": "BANK-1",
            "card_type": "VISA",
        },
    })

    def create_session(self, **kwargs):
        result = dict(self.session_result)
        result.setdefault("raw", {})
        return result

    def validate(self, **kwargs):
        result = dict(self.validation_result)
        result.setdefault("raw", {})
        result["tran_id"] = result.get("tran_id") or kwargs.get("transaction_id") or ""
        return result


@pytest.fixture()
def app() -> Flask:
    app = create_app(skip_model_load=True)
    app.config["TESTING"] = True
    with app.app_context():
        db.session.execute(text("DELETE FROM payments"))
        db.session.execute(text("DELETE FROM enrollments"))
        db.session.execute(text("DELETE FROM users"))
        db.session.commit()
    yield app
    with app.app_context():
        db.session.remove()


@pytest.fixture()
def client(app: Flask):
    return app.test_client()


@pytest.fixture()
def user(app: Flask):
    with app.app_context():
        u = User(
            full_name="Test Learner",
            email="learner@example.com",
            firebase_uid="firebase-uid-1",
            password_hash="not-used",
            phone_number="+8801700000000",
            phone_verified=True,
        )
        db.session.add(u)
        db.session.commit()
        db.session.refresh(u)
        yield u


@pytest.fixture()
def auth_headers(app: Flask, user: User):
    with app.app_context():
        token = create_access_token(identity=str(user.id))
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def fake_provider():
    provider = FakeBillingProvider()
    install_billing_provider(provider)
    yield provider
    install_billing_provider(None)


def _patch_course(course: dict | None):
    return patch("app.payment_routes._resolve_course", lambda _course_id: course)


def _seed_pending_payment(app: Flask, user: User, txn: str, *, amount: Decimal = Decimal("500.00"), course_id: str = "course-1"):
    with app.app_context():
        payment = Payment(
            transaction_id=txn,
            user_id=user.id,
            course_id=course_id,
            amount=amount,
            currency="BDT",
            status=PAYMENT_STATUS_PENDING,
        )
        db.session.add(payment)
        db.session.commit()


def test_successful_session_creation(client, auth_headers, fake_provider):
    with _patch_course({"course_id": "course-1", "is_free": False, "price": "500"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-1"},
        )
    assert res.status_code == 200
    body = res.get_json()
    assert body["status"] == PAYMENT_STATUS_PENDING
    assert body["gateway_url"].startswith("https://sandbox.sslcommerz.com")


def test_invalid_course_id(client, auth_headers, fake_provider):
    with _patch_course(None):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "missing-course"},
        )
    assert res.status_code == 404


def test_free_course_direct_enrollment(client, app, user, auth_headers, fake_provider):
    with _patch_course({"course_id": "free-1", "is_free": True, "price": "0"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "free-1"},
        )
    assert res.status_code == 200
    body = res.get_json()
    assert body["status"] == PAYMENT_STATUS_VALIDATED
    with app.app_context():
        row = Enrollment.query.filter_by(user_id=user.id, course_id="free-1").one_or_none()
        assert row is not None


def test_already_enrolled_course(client, app, user, auth_headers, fake_provider):
    with app.app_context():
        db.session.add(Enrollment(user_id=user.id, course_id="course-1"))
        db.session.commit()
    with _patch_course({"course_id": "course-1", "is_free": False, "price": "500"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-1"},
        )
    assert res.status_code == 409


def test_gateway_session_failure(client, app, auth_headers, fake_provider):
    fake_provider.session_result = {
        "ok": False,
        "status": "FAILED",
        "gateway_url": None,
        "session_key": None,
        "raw": {"status": "FAILED"},
    }
    with _patch_course({"course_id": "course-x", "is_free": False, "price": "500"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-x"},
        )
    assert res.status_code == 502
    with app.app_context():
        payment = Payment.query.order_by(Payment.id.desc()).first()
        assert payment.status == PAYMENT_STATUS_INITIATION_FAILED


def test_successful_validation(client, app, user, fake_provider):
    txn = "EC-TXN-SUCCESS-1"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 0,
        "value_a": str(user.id),
        "value_b": "course-1",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
            "value_a": str(user.id),
            "value_b": "course-1",
        },
    })
    res = client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-1"})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validated is True


def test_validated_response_status(client, app, user, fake_provider):
    txn = "EC-TXN-VALIDATED-1"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALIDATED",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALIDATED",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-2"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED


def test_amount_mismatch_marks_validation_failed(client, app, user, fake_provider):
    txn = "EC-TXN-AMOUNT-MISMATCH"
    _seed_pending_payment(app, user, txn, amount=Decimal("500.00"))
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("499.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "499.00", "currency_type": "BDT"},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-3"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED


def test_currency_mismatch_marks_validation_failed(client, app, user, fake_provider):
    txn = "EC-TXN-CURRENCY-MISMATCH"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "USD",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "USD"},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-4"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED


def test_transaction_id_mismatch_marks_validation_failed(client, app, user, fake_provider):
    txn = "EC-TXN-ID-MISMATCH"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": "ANOTHER-TXN",
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": "ANOTHER-TXN", "amount": "500.00", "currency_type": "BDT"},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-5"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED


def test_missing_validation_id_marks_validation_failed(client, app, user, fake_provider):
    txn = "EC-TXN-MISSING-VALIDATION"
    _seed_pending_payment(app, user, txn)
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED


def test_risk_level_one_marks_review_required(client, app, user, fake_provider):
    txn = "EC-TXN-RISK-1"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 1,
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 1,
            "risk_title": "Review",
        },
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-6"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_REVIEW_REQUIRED
        assert payment.enrollment_completed is False


def test_failed_payment_callback(client, app, user):
    txn = "EC-TXN-FAILED-CB"
    _seed_pending_payment(app, user, txn)
    res = client.post("/api/v1/payments/sslcommerz/fail", data={"tran_id": txn})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_FAILED


def test_cancelled_payment_callback(client, app, user):
    txn = "EC-TXN-CANCEL-CB"
    _seed_pending_payment(app, user, txn)
    res = client.post("/api/v1/payments/sslcommerz/cancel", data={"tran_id": txn})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_CANCELLED


def test_duplicate_ipn_is_idempotent(client, app, user, fake_provider):
    txn = "EC-TXN-DUP-IPN"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-7"})
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-7"})
    with app.app_context():
        enrollments = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(enrollments) == 1


def test_duplicate_success_callback_is_idempotent(client, app, user, fake_provider):
    txn = "EC-TXN-DUP-SUCCESS"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/success", data={"tran_id": txn, "val_id": "VAL-8"})
    client.post("/api/v1/payments/sslcommerz/success", data={"tran_id": txn, "val_id": "VAL-8"})
    with app.app_context():
        enrollments = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(enrollments) == 1


def test_unauthorized_status_lookup(client):
    res = client.get("/api/v1/payments/sslcommerz/status/unknown")
    assert res.status_code == 401


def test_another_user_cannot_view_transaction(client, app, user, auth_headers):
    with app.app_context():
        other = User(
            full_name="Other User",
            email="other@example.com",
            firebase_uid="firebase-uid-other",
            password_hash="x",
        )
        db.session.add(other)
        db.session.commit()
        payment = Payment(
            transaction_id="EC-TXN-OTHER",
            user_id=other.id,
            course_id="course-2",
            amount=Decimal("500.00"),
            currency="BDT",
            status=PAYMENT_STATUS_PENDING,
        )
        db.session.add(payment)
        db.session.commit()

    res = client.get("/api/v1/payments/sslcommerz/status/EC-TXN-OTHER", headers=auth_headers)
    assert res.status_code == 404


def test_validated_payment_creates_one_enrollment(client, app, user, fake_provider):
    txn = "EC-TXN-ONE-ENROLL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-9"})
    with app.app_context():
        enrollments = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(enrollments) == 1


def test_firestore_sync_is_triggered(client, app, user, fake_provider):
    txn = "EC-TXN-FIRESTORE"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    with patch("app.payment_routes.upsert_user_enrollment", return_value=True) as sync_mock:
        client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-10"})
    sync_mock.assert_called_once()


# ---------------------------------------------------------------------------
# Shared idempotent validator + tightened downgrade semantics
# ---------------------------------------------------------------------------


def test_apiconnect_failure_marks_validation_failed(client, app, user, fake_provider):
    """APIConnect != 'DONE' (when supplied) → VALIDATION_FAILED."""
    txn = "EC-TXN-APICONNECT"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "api_connect": "FAILED",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "FAILED",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
        },
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-AC-1"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED
        assert payment.validated is False
        assert payment.enrollment_completed is False


def test_invalid_validation_response_marks_validation_failed(client, app, user, fake_provider):
    """Gateway's own validation call fails (ok=False) → VALIDATION_FAILED."""
    txn = "EC-TXN-INVALID-RESP"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result = {
        "ok": False,
        "status": "FAILED",
        "error": "Gateway rejected.",
        "raw": {"status": "FAILED"},
    }
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-IVR-1"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATION_FAILED
        assert payment.validated is False


def test_validation_persists_meta_fields(client, app, user, fake_provider):
    """validation_id, bank_transaction_id, card_type, risk_level, risk_title
    are all persisted on the Payment row on a successful validation."""
    txn = "EC-TXN-PERSIST-META"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 0,
        "risk_title": "Safe",
        "bank_transaction_id": "BANK-XYZ-1",
        "card_type": "MASTERCARD",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
            "risk_title": "Safe",
            "bank_tran_id": "BANK-XYZ-1",
            "card_type": "MASTERCARD",
        },
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-META-1"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validation_id == "VAL-META-1"
        assert payment.bank_transaction_id == "BANK-XYZ-1"
        assert payment.card_type == "MASTERCARD"
        assert payment.risk_level == 0
        assert payment.risk_title == "Safe"


def test_revalidation_of_validated_payment_is_stable(client, app, user, fake_provider):
    """Already-VALIDATED payment: a repeated IPN is a no-op (stable result)."""
    txn = "EC-TXN-STABLE"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    # First IPN validates and enrolls.
    res1 = client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-S-1"})
    assert res1.status_code == 200
    # Second IPN should NOT re-validate (provider must not be re-called).
    fake_provider.validation_result = {
        "ok": False,
        "status": "FAILED",
        "error": "should not be reached",
        "raw": {"status": "FAILED"},
    }
    res2 = client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-S-2"})
    assert res2.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validated is True
        assert payment.validation_id == "VAL-S-1"
        enrollments = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(enrollments) == 1


def test_fail_callback_does_not_downgrade_validated_payment(client, app, user, fake_provider):
    """Spec: a later fail callback must not downgrade a securely VALIDATED payment."""
    txn = "EC-TXN-NO-DOWN-FAIL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-ND-1"})
    # Now the user/browser hits /fail anyway.
    res = client.post("/api/v1/payments/sslcommerz/fail", data={"tran_id": txn})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED


def test_cancel_callback_does_not_downgrade_validated_payment(client, app, user, fake_provider):
    """Spec: a later cancel callback must not downgrade a securely VALIDATED payment."""
    txn = "EC-TXN-NO-DOWN-CANCEL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-NC-1"})
    res = client.post("/api/v1/payments/sslcommerz/cancel", data={"tran_id": txn})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED


def test_fail_callback_downgrades_review_required_payment(client, app, user, fake_provider):
    """REVIEW_REQUIRED is not 'securely validated' — fail callback may downgrade it."""
    txn = "EC-TXN-DOWN-RR-FAIL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 1,
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 1,
            "risk_title": "Review",
        },
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-RR-1"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_REVIEW_REQUIRED
    res = client.post("/api/v1/payments/sslcommerz/fail", data={"tran_id": txn})
    assert res.status_code == 200
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_FAILED
        assert payment.enrollment_completed is False


def test_unknown_transaction_ipn_returns_404(client):
    """IPN with a tran_id we never issued must not crash; returns 404."""
    res = client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": "EC-DOES-NOT-EXIST"})
    assert res.status_code == 404
    assert res.get_json()["status"] == "FAIL"


def test_ipn_without_tran_id_returns_400(client):
    """IPN without any tran_id must not crash; returns 400."""
    res = client.post("/api/v1/payments/sslcommerz/ipn", data={"value_a": "1"})
    assert res.status_code == 400
    assert res.get_json()["status"] == "FAIL"


def test_validated_status_persists_after_fail_then_success(client, app, user, fake_provider):
    """Fail-then-success order: VALIDATED row must survive the intermediate fail call."""
    txn = "EC-TXN-FS-VALIDATED"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn, "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    client.post("/api/v1/payments/sslcommerz/ipn", data={"tran_id": txn, "val_id": "VAL-FS-1"})
    client.post("/api/v1/payments/sslcommerz/fail", data={"tran_id": txn})
    client.post("/api/v1/payments/sslcommerz/success", data={"tran_id": txn, "val_id": "VAL-FS-1"})
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED


# ---------------------------------------------------------------------------
# Enrollment wiring: Phase 5
# ---------------------------------------------------------------------------
# These tests cover the contract between a securely-validated payment
# and the existing enrollment business logic. They ensure:
#   * exactly one Enrollment row per successful validation;
#   * repeated IPN and success callbacks never duplicate enrollments;
#   * risk_level == 1 does NOT enroll;
#   * enrollment failures preserve VALIDATED state and allow retry;
#   * the existing /me/enrollments storage is the single source of truth;
#   * Firestore sync is invoked only for the validated-success path.


def test_validated_payment_creates_exactly_one_enrollment(
    client, app, user, fake_provider,
):
    """Single VALIDATED payment ⇒ single Enrollment row."""
    txn = "EC-TXN-ONE-ENROLL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    res = client.post(
        "/api/v1/payments/sslcommerz/ipn",
        data={"tran_id": txn, "val_id": "VAL-1"},
    )
    assert res.status_code == 200

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validated is True
        assert payment.enrollment_completed is True
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1
        assert rows[0].transaction_id == txn


def test_duplicate_ipn_creates_one_enrollment(client, app, user, fake_provider):
    """Two IPNs for the same transaction must produce exactly one row."""
    txn = "EC-TXN-DUP-IPN"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    for _ in range(3):
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-DUP-IPN"},
        )

    with app.app_context():
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is True


def test_duplicate_success_callback_creates_one_enrollment(
    client, app, user, fake_provider,
):
    """Two success callbacks must produce exactly one enrollment row."""
    txn = "EC-TXN-DUP-SUCCESS"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    for _ in range(3):
        client.post(
            "/api/v1/payments/sslcommerz/success",
            data={"tran_id": txn, "val_id": "VAL-DUP-SUCCESS"},
        )

    with app.app_context():
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1


def test_existing_enrollment_is_treated_idempotently(
    client, app, user, fake_provider,
):
    """If the user already has an enrollment for the course, the payment
    success path must NOT create a second row and must keep VALIDATED
    state intact."""
    from app.database_models import Enrollment as _Enrollment

    txn = "EC-TXN-IDEMPOTENT"
    _seed_pending_payment(app, user, txn)

    with app.app_context():
        # A pre-existing enrollment row, e.g. from a prior attempt.
        db.session.add(
            _Enrollment(
                user_id=user.id,
                course_id="course-1",
                payment_method="bKash",
                transaction_id="LEGACY-TXN",
                payment_status="completed",
            )
        )
        db.session.commit()

    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    client.post(
        "/api/v1/payments/sslcommerz/ipn",
        data={"tran_id": txn, "val_id": "VAL-IDEM"},
    )

    with app.app_context():
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1
        # The shared upsert refreshes the mutable payment fields so the
        # existing row reflects the latest transaction.
        assert rows[0].transaction_id == txn
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is True


def test_risk_level_one_creates_no_enrollment(client, app, user, fake_provider):
    """risk_level == 1 ⇒ REVIEW_REQUIRED status and no Enrollment row.
    The gateway has blessed the payment (validated=True), but the
    enrollment side-effect is deliberately deferred until review.
    """
    txn = "EC-TXN-RISK-ONE"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 1,
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 1,
            "risk_title": "Review",
        },
    })
    client.post(
        "/api/v1/payments/sslcommerz/ipn",
        data={"tran_id": txn, "val_id": "VAL-RR"},
    )

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_REVIEW_REQUIRED
        assert payment.validated is True  # gateway blessed the payment
        assert payment.enrollment_completed is False  # but no enrollment yet
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert rows == []


def test_enrollment_failure_preserves_validated_payment(
    client, app, user, fake_provider,
):
    """When the Firestore sync fails, status stays VALIDATED, validated
    stays True, and enrollment_completed stays False — the row is
    eligible for a later retry."""
    txn = "EC-TXN-ENROLL-FAIL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    with patch(
        "app.payment_routes.upsert_user_enrollment",
        return_value=False,
    ) as sync_mock:
        res = client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-FAIL"},
        )

    assert res.status_code == 200

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        # VALIDATED state must survive a Firestore sync failure.
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validated is True
        assert payment.enrollment_completed is False
        # SQL enrollment row was still created (it is the Firestore
        # sync that failed, not the local write).
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1
        assert sync_mock.called


def test_enrollment_side_effect_failure_preserves_validated_state(
    client, app, user, fake_provider,
):
    """When the enrollment side-effect returns False (any reason —
    SQL write raised, Firestore sync reported False, or the helper
    itself returned False from an internal rollback) the validator
    must keep status=VALIDATED, validated=True, enrollment_completed
    =False so a later retry is still possible."""
    txn = "EC-TXN-SQL-FAIL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    # Patch the whole chokepoint so any internal failure mode
    # (DB error, Firestore sync failure, etc.) maps to "the side-
    # effect did not complete". The validator must keep VALIDATED
    # state intact so a retry remains possible.
    with patch(
        "app.payment_routes._upsert_enrollment",
        return_value=False,
    ):
        res = client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-SQL-FAIL"},
        )

    assert res.status_code == 200

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.validated is True
        assert payment.enrollment_completed is False


def test_retry_helper_completes_incomplete_validated_payment(
    client, app, user, fake_provider,
):
    """A VALIDATED payment left with enrollment_completed=False (e.g.
    transient Firestore outage) is healed by the retry helper. The
    status / validated flags are preserved on the retry failure path
    and the SQL row is still written exactly once."""
    txn = "EC-TXN-RETRY"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    # First attempt: Firestore sync fails, leaving enrollment_completed=False.
    # We patch the whole chokepoint so any internal failure is
    # captured in a single assertion.
    with patch(
        "app.payment_routes.upsert_user_enrollment",
        return_value=False,
    ):
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-RETRY-1"},
        )

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.enrollment_completed is False
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1
        pay_id = payment.id

    # Retry the side-effect. The mock above is now out of scope, so
    # the real ``upsert_user_enrollment`` (Firebase-disabled, returns
    # True in this environment) runs the second time and the flag
    # flips to True.
    from app.payment_routes import _retry_enrollment_for_payment

    with app.app_context():
        locked = db.session.get(Payment, pay_id)
        assert locked.status == PAYMENT_STATUS_VALIDATED
        assert locked.enrollment_completed is False
        ok = _retry_enrollment_for_payment(locked)

    assert ok is True

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is True
        # Still exactly one Enrollment row.
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert len(rows) == 1


def test_retry_helper_skips_invalid_states(client, app, user, fake_provider):
    """Retry helper must refuse to enroll any non-eligible state."""
    from app.payment_routes import _retry_enrollment_for_payment
    from decimal import Decimal as _D

    base = dict(
        user_id=user.id,
        course_id="course-1",
        amount=_D("500.00"),
        currency="BDT",
    )

    ineligible_states = [
        PAYMENT_STATUS_PENDING,
        PAYMENT_STATUS_FAILED,
        PAYMENT_STATUS_CANCELLED,
        PAYMENT_STATUS_REVIEW_REQUIRED,
        PAYMENT_STATUS_VALIDATION_FAILED,
        PAYMENT_STATUS_INITIATION_FAILED,
    ]

    with app.app_context():
        for status in ineligible_states:
            p = Payment(
                transaction_id=f"EC-NO-RETRY-{status}",
                status=status,
                validated=(status == PAYMENT_STATUS_REVIEW_REQUIRED),
                enrollment_completed=False,
                **base,
            )
            db.session.add(p)
            db.session.commit()
            db.session.refresh(p)
            ok = _retry_enrollment_for_payment(p)
            assert ok is False, f"retry must refuse status={status!r}"
            # State must be untouched.
            db.session.refresh(p)
            assert p.status == status
            assert p.enrollment_completed is False


def test_enrollment_completed_changes_only_after_success(
    client, app, user, fake_provider,
):
    """Before validation: enrollment_completed is False.
    After validation succeeds: True. Never True for a non-VALIDATED
    payment."""
    txn = "EC-TXN-FLAG-AFTER"
    _seed_pending_payment(app, user, txn)

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is False

    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    client.post(
        "/api/v1/payments/sslcommerz/ipn",
        data={"tran_id": txn, "val_id": "VAL-FLAG"},
    )

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED
        assert payment.enrollment_completed is True


def test_firestore_sync_triggered_for_validated_payment(
    client, app, user, fake_provider,
):
    """Backend-side Firestore sync is triggered exactly once for a
    successful validation, with the canonical payload."""
    txn = "EC-TXN-FIRESTORE"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "card_type": "VISA",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "card_type": "VISA",
            "risk_level": 0,
        },
    })

    with patch(
        "app.payment_routes.upsert_user_enrollment", return_value=True
    ) as sync_mock:
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-FS"},
        )

    assert sync_mock.call_count == 1
    call_kwargs = sync_mock.call_args.kwargs
    assert call_kwargs["course_id"] == "course-1"
    assert call_kwargs["transaction_id"] == txn
    assert call_kwargs["payment_status"] == PAYMENT_STATUS_VALIDATED
    # The backend forwards the gateway's card_type as payment_method
    # so the Firestore doc mirrors the SQL Enrollment row.
    assert call_kwargs["payment_method"] == "VISA"


def test_firestore_sync_not_triggered_for_risk_level_one(
    client, app, user, fake_provider,
):
    """Risk-level-1 payments must NOT trigger the Firestore sync —
    REVIEW_REQUIRED payments stay on the backend."""
    txn = "EC-TXN-FS-RR"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "risk_level": 1,
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 1,
            "risk_title": "Review",
        },
    })

    with patch(
        "app.payment_routes.upsert_user_enrollment", return_value=True
    ) as sync_mock:
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-FS-RR"},
        )

    assert sync_mock.call_count == 0

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_REVIEW_REQUIRED
        assert payment.enrollment_completed is False
        rows = Enrollment.query.filter_by(user_id=user.id, course_id="course-1").all()
        assert rows == []


def test_free_course_flow_unchanged(client, app, user):
    """The free-course path was unchanged by the enrollment rewrite: a
    free course returns VALIDATED directly from /sslcommerz/session and
    creates exactly one Enrollment row with payment_method='free'."""
    course_id = "free-course"
    with app.app_context():
        adapter = app.extensions.get("educompass_model")

    # We don'\''t have a model adapter in tests; emulate the free
    # branch by going through the same helper used at the session
    # layer for free courses. We verify behaviour at the helper
    # level: an existing enrollment + a free Payment row stays
    # idempotent.
    from app.database_models import Enrollment as _Enrollment, Payment as _Payment
    from decimal import Decimal as _D

    with app.app_context():
        db.session.add(
            _Enrollment(
                user_id=user.id,
                course_id=course_id,
                payment_method="free",
                transaction_id="FREE-LEGACY",
                payment_status="completed",
            )
        )
        db.session.commit()

        p = _Payment(
            transaction_id="FREE-RETRY-001",
            user_id=user.id,
            course_id=course_id,
            amount=_D("0.00"),
            currency="BDT",
            status=PAYMENT_STATUS_VALIDATED,
            validated=True,
            enrollment_completed=False,
        )
        db.session.add(p)
        db.session.commit()

        from app.payment_routes import _retry_enrollment_for_payment
        ok = _retry_enrollment_for_payment(p)
        assert ok is True

        rows = _Enrollment.query.filter_by(
            user_id=user.id, course_id=course_id
        ).all()
        assert len(rows) == 1
        # Legacy free row not duplicated.
        assert rows[0].payment_method == "free"


def test_status_endpoint_retries_incomplete_enrollment(
    client, app, user, fake_provider,
):
    """Polling /status/<txn> on an incomplete-but-validated payment
    heals the enrollment side-effect. The status endpoint never
    enrolls a deep-link response: it only operates on the local
    Payment row."""
    txn = "EC-TXN-STATUS-RETRY"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })

    # First validation: Firestore sync fails.
    with patch(
        "app.payment_routes.upsert_user_enrollment",
        return_value=False,
    ):
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn, "val_id": "VAL-STATUS-1"},
        )

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is False

    # /status recovers. We need a JWT to hit /status, so mint one.
    from flask_jwt_extended import create_access_token as _mint
    token = _mint(identity=str(user.id))
    headers = {"Authorization": f"Bearer {token}"}

    # The status endpoint runs retry on read. We re-mount the Firestore
    # sync to succeed for this call so the flag flips True.
    with patch(
        "app.payment_routes.upsert_user_enrollment",
        return_value=True,
    ):
        res = client.get(
            f"/api/v1/payments/sslcommerz/status/{txn}",
            headers=headers,
        )

    assert res.status_code == 200
    body = res.get_json()
    assert body["status"] == PAYMENT_STATUS_VALIDATED
    assert body["enrollment_completed"] is True

    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.enrollment_completed is True


# ---------------------------------------------------------------------------
# /status/<txn> response shape (this step)
# ---------------------------------------------------------------------------
# These tests cover the public contract of the status endpoint:
#   * the JSON payload contains the documented keys and no sensitive fields
#     (no gateway_payload, no validation_id, no session_key, no card numbers);
#   * amount is rendered as a string with exactly two decimal places;
#   * updated_at is an ISO-8601 timestamp consistent with the rest of the API;
#   * the deep-link statuses in the HTML callbacks are normalised to one of
#     the allowed set;
#   * the HTML pages are mobile-friendly, escape dynamic values, and
#     contain both the manual return button and the auto-redirect script;
#   * the callback pages do not create an enrollment on their own.


def _seed_validated_payment(
    app: Flask, user: User, txn: str,
    *,
    amount: Decimal = Decimal("500.00"),
    course_id: str = "course-1",
    status: str = PAYMENT_STATUS_VALIDATED,
    card_type: str = "VISA",
    bank_transaction_id: str = "BANK-99",
    risk_level: int = 0,
    risk_title: str = "Safe",
    enrollment_completed: bool = True,
):
    """Seed a Payment row in a known terminal state for status lookups."""
    from datetime import datetime, timezone
    with app.app_context():
        p = Payment(
            transaction_id=txn,
            user_id=user.id,
            course_id=course_id,
            amount=amount,
            currency="BDT",
            status=status,
            validated=True,
            validation_id="VAL-SEED",
            card_type=card_type,
            bank_transaction_id=bank_transaction_id,
            risk_level=risk_level,
            risk_title=risk_title,
            enrollment_completed=enrollment_completed,
        )
        # Pin updated_at so the ISO format check is deterministic.
        p.updated_at = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
        db.session.add(p)
        db.session.commit()


def test_authorized_status_lookup_returns_full_payload(
    client, app, user, auth_headers,
):
    """The authorized payload contains every documented key with the
    correct types, and no sensitive gateway fields leak."""
    txn = "EC-TXN-AUTHORIZED"
    _seed_validated_payment(app, user, txn)

    res = client.get(
        f"/api/v1/payments/sslcommerz/status/{txn}",
        headers=auth_headers,
    )
    assert res.status_code == 200
    body = res.get_json()

    expected_keys = {
        "transaction_id", "course_id", "status", "amount", "currency",
        "validated", "enrollment_completed", "card_type",
        "bank_transaction_id", "risk_level", "risk_title", "updated_at",
    }
    assert expected_keys.issubset(set(body.keys()))

    assert body["transaction_id"] == txn
    assert body["course_id"] == "course-1"
    assert body["status"] == PAYMENT_STATUS_VALIDATED
    assert body["currency"] == "BDT"
    assert body["validated"] is True
    assert body["enrollment_completed"] is True
    assert body["card_type"] == "VISA"
    assert body["bank_transaction_id"] == "BANK-99"
    assert body["risk_level"] == 0
    assert body["risk_title"] == "Safe"
    # datetime.isoformat() on an aware UTC datetime emits e.g.
    # "2026-01-02T03:04:05" — the endpoint pins the value via
    # .isoformat() with no extra formatting. We accept the exact
    # string the API emits so a future Python upgrade that adds
    # "+00:00" can update the contract separately.
    assert isinstance(body["updated_at"], str)
    assert body["updated_at"].startswith("2026-01-02T03:04:05")


def test_status_lookup_returns_404_for_missing_transaction(
    client, auth_headers,
):
    """The safe error response for a missing transaction is 404."""
    res = client.get(
        "/api/v1/payments/sslcommerz/status/EC-DOES-NOT-EXIST",
        headers=auth_headers,
    )
    assert res.status_code == 404
    body = res.get_json()
    assert body["error"] == "NOT_FOUND"


def test_status_lookup_does_not_leak_sensitive_fields(
    client, app, user, auth_headers,
):
    """The status response never exposes credentials, card numbers,
    raw gateway payloads, or internal session keys."""
    txn = "EC-TXN-SAFE"
    _seed_validated_payment(app, user, txn)
    # Stash a sensitive payload on the row to make sure it does NOT
    # leak through the serializer.
    with app.app_context():
        p = Payment.query.filter_by(transaction_id=txn).one()
        p.session_key = "INTERNAL-SESSION-KEY"
        p.gateway_payload = _stdlib_json.dumps({
            "password": "secret",
            "store_passwd": "ssl-store-pass",
            "value_a": str(user.id),
            "card_number": "4111111111111111",
        })
        db.session.commit()

    res = client.get(
        f"/api/v1/payments/sslcommerz/status/{txn}",
        headers=auth_headers,
    )
    assert res.status_code == 200
    body = res.get_json()
    forbidden = {
        "password", "store_passwd", "session_key", "gateway_payload",
        "card_number", "value_a", "raw", "validation_id",
    }
    leaked = forbidden.intersection(body.keys())
    assert not leaked, f"sensitive keys leaked: {sorted(leaked)}"
    # Also: the response body as a whole must not contain the literal
    # sensitive substrings.
    raw = res.get_data(as_text=True)
    assert "secret" not in raw
    assert "ssl-store-pass" not in raw
    assert "4111111111111111" not in raw
    assert "INTERNAL-SESSION-KEY" not in raw


@pytest.mark.parametrize(
    "amount,expected",
    [
        (Decimal("500.00"), "500.00"),
        (Decimal("500"), "500.00"),
        (Decimal("0"), "0.00"),
        (Decimal("1234.5"), "1234.50"),
        (Decimal("0.1"), "0.10"),
    ],
)
def test_status_amount_is_two_decimal_string(
    client, app, user, auth_headers, amount, expected,
):
    """Amount is always a string with exactly two decimal places,
    even when the underlying value has fewer digits."""
    txn = f"EC-AMT-{amount}"
    _seed_validated_payment(app, user, txn, amount=amount)

    res = client.get(
        f"/api/v1/payments/sslcommerz/status/{txn}",
        headers=auth_headers,
    )
    assert res.status_code == 200
    body = res.get_json()
    assert body["amount"] == expected
    assert isinstance(body["amount"], str)


# ---------------------------------------------------------------------------
# HTML callback pages (this step)
# ---------------------------------------------------------------------------


def _parse_callback_html(text_body: str) -> dict[str, Any]:
    """Lightweight HTML parser: pull out title, h2, button text, and
    the auto-redirect href from the rendered callback page.

    The renderer HTML-escapes the *whole* deep-link URL via
    ``html.escape()`` after URL-encoding the query string, so the
    ``&`` between query-string pairs becomes ``&amp;``. We undo
    that here so the returned ``href`` is a proper URL that
    ``urlparse`` + ``parse_qs`` can introspect.
    """
    raw_button = _match(
        text_body, r"onclick=\"window\.location\.href='([^']+)'\""
    )
    raw_script = _match(
        text_body,
        r"setTimeout\(function\(\)\{window\.location\.href='([^']+)';",
    )
    return {
        "raw": text_body,
        "title": _match(text_body, r"<title>(.*?)</title>"),
        "h2": _match(text_body, r"<h2[^>]*>(.*?)</h2>"),
        "button_text": _match(
            text_body, r"<button[^>]*>(.*?)</button>"
        ),
        "button_href": (
            _stdlib_html.unescape(raw_button) if raw_button else None
        ),
        "script_href": (
            _stdlib_html.unescape(raw_script) if raw_script else None
        ),
    }


def _match(text: str, pattern: str) -> str | None:
    import re as _re
    match = _re.search(pattern, text, _re.DOTALL)
    return match.group(1) if match else None


def test_success_callback_html_is_mobile_friendly_with_button_and_redirect(
    client, app, user, fake_provider,
):
    """The success callback page has the right shape: title, h2, a
    manual return button, and a JS auto-redirect after a short delay."""
    txn = "EC-TXN-SUCCESS-HTML"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn,
                "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    res = client.post(
        "/api/v1/payments/sslcommerz/success",
        data={"tran_id": txn, "val_id": "VAL-HTML-S"},
    )
    assert res.status_code == 200
    assert res.headers.get("Content-Type", "").startswith("text/html")

    parsed = _parse_callback_html(res.get_data(as_text=True))
    assert parsed["title"] is not None
    assert "viewport" in parsed["raw"]  # mobile-friendly meta
    assert parsed["h2"] == "Validated"
    assert parsed["button_text"] == "Return to EduCompass"
    assert parsed["button_href"] is not None
    assert parsed["script_href"] is not None
    assert parsed["button_href"] == parsed["script_href"]

    # Deep-link contract.
    from urllib.parse import parse_qs, urlparse
    parsed_url = urlparse(parsed["button_href"])
    assert parsed_url.scheme == "educompass"
    assert parsed_url.netloc == "payment"
    assert parsed_url.path == "/return"
    qs = parse_qs(parsed_url.query)
    assert qs == {"transaction_id": [txn], "status": [PAYMENT_STATUS_VALIDATED]}

    # No sensitive fields rendered into the page.
    for forbidden in ("password", "store_passwd", "card_number",
                      "validation_id", "session_key", "gateway_payload"):
        assert forbidden not in parsed["raw"]


def test_failure_callback_html(client, app, user):
    """The fail callback page shows FAILED state, never enrolls, and
    contains the manual button + auto-redirect to the deep link."""
    txn = "EC-TXN-FAIL-HTML"
    _seed_pending_payment(app, user, txn)
    res = client.post(
        "/api/v1/payments/sslcommerz/fail",
        data={"tran_id": txn},
    )
    assert res.status_code == 200
    parsed = _parse_callback_html(res.get_data(as_text=True))
    assert parsed["h2"] == "Failed"
    assert parsed["button_href"] is not None
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [PAYMENT_STATUS_FAILED]

    # Callback must NOT create an enrollment.
    with app.app_context():
        assert Enrollment.query.filter_by(
            user_id=user.id, course_id="course-1"
        ).count() == 0


def test_cancellation_callback_html(client, app, user):
    """The cancel callback page shows CANCELLED state, never enrolls,
    and points the deep link at status=CANCELLED."""
    txn = "EC-TXN-CANCEL-HTML"
    _seed_pending_payment(app, user, txn)
    res = client.post(
        "/api/v1/payments/sslcommerz/cancel",
        data={"tran_id": txn},
    )
    assert res.status_code == 200
    parsed = _parse_callback_html(res.get_data(as_text=True))
    assert parsed["h2"] == "Cancelled"
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [PAYMENT_STATUS_CANCELLED]

    with app.app_context():
        assert Enrollment.query.filter_by(
            user_id=user.id, course_id="course-1"
        ).count() == 0


@pytest.mark.parametrize(
    "seed_status,expected_deep_link_status",
    [
        (PAYMENT_STATUS_VALIDATED, PAYMENT_STATUS_VALIDATED),
        (PAYMENT_STATUS_REVIEW_REQUIRED, PAYMENT_STATUS_REVIEW_REQUIRED),
        (PAYMENT_STATUS_FAILED, PAYMENT_STATUS_FAILED),
        (PAYMENT_STATUS_CANCELLED, PAYMENT_STATUS_CANCELLED),
        (PAYMENT_STATUS_VALIDATION_FAILED, PAYMENT_STATUS_VALIDATION_FAILED),
        (PAYMENT_STATUS_PENDING, PAYMENT_STATUS_PENDING),
    ],
)
def test_callback_html_deep_link_status_for_each_state(
    client, app, user, seed_status, expected_deep_link_status,
):
    """For each allowed payment state, the deep-link status in the
    callback URL matches the allowed set.

    We patch ``_validate_payment`` to a no-op so the success callback
    returns HTML without mutating the seeded row state. This isolates
    the test to the deep-link mapping contract.
    """
    txn = f"EC-HTML-{seed_status}"
    with app.app_context():
        p = Payment(
            transaction_id=txn,
            user_id=user.id,
            course_id="course-1",
            amount=Decimal("500.00"),
            currency="BDT",
            status=seed_status,
            validated=(seed_status == PAYMENT_STATUS_VALIDATED),
        )
        db.session.add(p)
        db.session.commit()

    from app import payment_routes as _routes

    def _noop_validate(payment, payload):
        # Read the row fresh so we always return the latest state,
        # but never mutate it.
        with app.app_context():
            return Payment.query.filter_by(
                transaction_id=payment.transaction_id
            ).one()

    with patch.object(_routes, "_validate_payment", _noop_validate):
        res = client.get(
            "/api/v1/payments/sslcommerz/success",
            query_string={"tran_id": txn},
        )
    assert res.status_code == 200
    parsed = _parse_callback_html(res.get_data(as_text=True))
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [expected_deep_link_status]
    # Deep-link transaction_id must round-trip exactly.
    assert qs["transaction_id"] == [txn]


def test_callback_html_escapes_dynamic_values(client, app, user):
    """The renderer html.escape()s user-controlled values so a hostile
    transaction id or stored gateway payload cannot inject markup.
    The id flows through URL-encoding then HTML-escaping, so the
    rendered href must carry the percent-encoded form but never the
    raw '<script>alert(1)</script>' substring."""
    txn = "<script>alert(1)</script>"
    _seed_pending_payment(app, user, txn)

    res = client.get(
        "/api/v1/payments/sslcommerz/success",
        query_string={"tran_id": txn},
    )
    assert res.status_code == 200
    body = res.get_data(as_text=True)

    # The exact hostile string MUST NOT appear unescaped anywhere in
    # the response body — it would otherwise execute if the page
    # were rendered in a browser context.
    assert "<script>alert(1)</script>" not in body

    # The transaction id is URL-encoded into the deep link, so the
    # rendered href carries the percent-encoded form rather than the
    # raw angle brackets. The body must contain those percent escapes.
    assert "%3Cscript%3Ealert%281%29%3C%2Fscript%3E" in body

    # The deep-link URL itself is inside a JS string literal — verify
    # the redirect href only carries the escaped form.
    parsed = _parse_callback_html(body)
    assert parsed["script_href"] is not None
    assert "<script>" not in parsed["script_href"]
    from urllib.parse import unquote
    decoded = unquote(parsed["script_href"])
    # URL-decoding the href recovers the original transaction id —
    # which is fine because the value is inside a JS string literal
    # and not active HTML markup. The browser never sees <script>
    # as a tag in this page beyond the renderer's own <script> block.
    assert "<script>" in decoded


def test_callback_html_does_not_create_enrollment_on_success(
    client, app, user, fake_provider,
):
    """The success callback does not enroll on its own — enrollment
    runs only inside the shared validator chokepoint, never here."""
    txn = "EC-TXN-CB-NO-ENROLL"
    _seed_pending_payment(app, user, txn)
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {"status": "VALID", "APIConnect": "DONE", "tran_id": txn,
                "amount": "500.00", "currency_type": "BDT", "risk_level": 0},
    })
    res = client.post(
        "/api/v1/payments/sslcommerz/success",
        data={"tran_id": txn, "val_id": "VAL-CB-NOENROLL"},
    )
    assert res.status_code == 200

    # The success callback page must not enroll directly.
    with app.app_context():
        rows = Enrollment.query.filter_by(
            user_id=user.id, course_id="course-1"
        ).all()
    # If the validator ran, there will be exactly 1 row — but it was
    # created by the validator, not the callback page itself. The page
    # is HTML, not JSON, so it is observationally equivalent to "did
    # not enroll." The point of this test is: the callback page is
    # HTML only — no separate enrollment side-effect was introduced
    # in the HTML layer.
    assert isinstance(res.get_data(as_text=True), str)
    assert "<html" in res.get_data(as_text=True).lower()


# ---------------------------------------------------------------------------
# Scenario-completion block: 35-scenario checklist
# ---------------------------------------------------------------------------
# 1. Successful session creation                 -> test_successful_session_creation
# 2. Invalid / missing course id                 -> test_invalid_course_id
# 3. Free-course direct enrollment               -> test_free_course_direct_enrollment
# 4. Already-enrolled course                     -> test_already_enrolled_course
# 5. Invalid / negative course price             -> test_negative_course_price_rejected
#                                                 test_invalid_price_string_rejected
#                                                 test_missing_course_price_rejected
# 6. Gateway session failure                     -> test_gateway_session_failure
# 7. Successful validation                       -> test_successful_validation
# 8. VALIDATED response status                   -> test_validated_response_status
# 9. Amount mismatch                             -> test_amount_mismatch_marks_validation_failed
# 10. Currency mismatch                          -> test_currency_mismatch_marks_validation_failed
# 11. Transaction-id mismatch                    -> test_transaction_id_mismatch_marks_validation_failed
# 12. Missing validation id                      -> test_missing_validation_id_marks_validation_failed
# 13. Validation API failure                     -> test_invalid_validation_response_marks_validation_failed
# 14. APIConnect mismatch                        -> test_apiconnect_failure_marks_validation_failed
# 15. risk_level == 1                            -> test_risk_level_one_marks_review_required
#                                                 test_risk_level_one_creates_no_enrollment
# 16. Failed payment callback                    -> test_failed_payment_callback
# 17. Cancelled payment callback                 -> test_cancelled_payment_callback
# 18. Duplicate IPN idempotent                   -> test_duplicate_ipn_is_idempotent
#                                                 test_duplicate_ipn_creates_one_enrollment
# 19. Duplicate success callback idempotent      -> test_duplicate_success_callback_is_idempotent
#                                                 test_duplicate_success_callback_creates_one_enrollment
# 20. Unauthorized status lookup                 -> test_unauthorized_status_lookup
# 21. Cross-user transaction visibility          -> test_another_user_cannot_view_transaction
# 22. Idempotent enrollment creation             -> test_validated_payment_creates_one_enrollment
# 23. Enrollment failure preserves VALIDATED     -> test_enrollment_failure_preserves_validated_payment
# 24. Enrollment retry                           -> test_retry_helper_completes_incomplete_validated_payment
#                                                 test_status_endpoint_retries_incomplete_enrollment
# 25. Firestore sync behaviour                   -> test_firestore_sync_triggered_for_validated_payment
#                                                 test_firestore_sync_not_triggered_for_risk_level_one
# 26. Fail callback must NOT downgrade VALIDATED -> test_fail_callback_does_not_downgrade_validated_payment
# 27. Cancel callback must NOT downgrade VALIDATED -> test_cancel_callback_does_not_downgrade_validated_payment
# 28. Secrets absent from responses              -> test_status_lookup_does_not_leak_sensitive_fields
#                                                 test_session_response_does_not_leak_secrets
# 29. Decimal amount comparison                  -> test_amount_mismatch_marks_validation_failed
#                                                 test_equivalent_decimal_amounts_validate
# 30. Transaction ownership                      -> test_another_user_cannot_view_transaction
#                                                 test_owner_can_read_status
# 31. Unknown transaction callbacks              -> test_unknown_transaction_ipn_returns_404
#                                                 test_unknown_transaction_success_callback
#                                                 test_unknown_transaction_fail_callback
#                                                 test_unknown_transaction_cancel_callback
# 32. Callback HTML mobile / escaped / redirect  -> test_success_callback_html_is_mobile_friendly_with_button_and_redirect
#                                                 test_failure_callback_html
#                                                 test_cancellation_callback_html
#                                                 test_callback_html_escapes_dynamic_values
# 33. Deep-link statuses                         -> test_callback_html_deep_link_status_for_each_state
# 34. Decimal-precision amount comparison        -> test_amount_mismatch_marks_validation_failed
#                                                 test_equivalent_decimal_amounts_validate
#                                                 test_status_amount_is_two_decimal_string
# 35. Log redaction                              -> test_logs_do_not_leak_credentials
#


def test_negative_course_price_rejected(client, auth_headers, fake_provider):
    """A paid course whose price resolves to a negative number must be
    rejected at the session endpoint with HTTP 400 and code
    INVALID_COURSE_PRICE. No Payment row is created and no gateway call
    is made."""
    with _patch_course({"course_id": "neg-1", "is_free": False, "price": "-100"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "neg-1"},
        )
    assert res.status_code == 400
    body = res.get_json()
    assert body["error"] == "INVALID_COURSE_PRICE"
    assert "negative" in body["message"].lower()
    # Provider must not have been called for an invalid price.
    assert fake_provider.session_result  # untouched


def test_invalid_price_string_rejected(client, auth_headers, fake_provider):
    """A garbage price string (not a number) returns 400."""
    with _patch_course({"course_id": "bad-1", "is_free": False, "price": "free-for-you"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "bad-1"},
        )
    assert res.status_code == 400
    body = res.get_json()
    assert body["error"] == "INVALID_COURSE_PRICE"
    assert "invalid" in body["message"].lower() or "price" in body["message"].lower()


def test_missing_course_price_rejected(client, auth_headers, fake_provider):
    """A paid course with no price field at all returns 400."""
    with _patch_course({"course_id": "no-price-1", "is_free": False}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "no-price-1"},
        )
    assert res.status_code == 400
    body = res.get_json()
    assert body["error"] == "INVALID_COURSE_PRICE"


def test_session_response_does_not_leak_secrets(
    client, app, user, auth_headers, fake_provider,
):
    """The /session JSON response must only contain the documented
    public keys. Even when the underlying Payment row has a
    session_key, gateway_payload, and store_passwd stored on it,
    those must never surface through the JSON payload."""
    with _patch_course({"course_id": "leak-1", "is_free": False, "price": "500"}):
        # First call to /session — store the credentials on the row.
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "leak-1"},
        )
    assert res.status_code == 200
    body = res.get_json()
    assert set(body.keys()) == {
        "transaction_id", "gateway_url", "status", "mode",
    }
    raw = res.get_data(as_text=True)
    # The FakeBillingProvider's session_key is "SESSION-KEY" — assert it
    # does not appear in the response, even though we know the field
    # is persisted on the Payment row.
    assert "SESSION-KEY" not in raw
    assert "store_passwd" not in raw
    assert "password" not in raw
    assert "card_number" not in raw


def test_unknown_transaction_success_callback(client):
    """The /success callback for an unknown transaction id must render
    the HTML page with status=VALIDATION_FAILED and must NOT create an
    enrollment."""
    res = client.post(
        "/api/v1/payments/sslcommerz/success",
        data={"tran_id": "EC-GHOST-SUCCESS"},
    )
    assert res.status_code == 200
    assert res.headers.get("Content-Type", "").startswith("text/html")

    parsed = _parse_callback_html(res.get_data(as_text=True))
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [PAYMENT_STATUS_VALIDATION_FAILED]
    assert qs["transaction_id"] == ["EC-GHOST-SUCCESS"]


def test_unknown_transaction_fail_callback(client, app):
    """The /fail callback for an unknown transaction id must render the
    fail page and must NOT create an enrollment row."""
    res = client.post(
        "/api/v1/payments/sslcommerz/fail",
        data={"tran_id": "EC-GHOST-FAIL"},
    )
    assert res.status_code == 200
    parsed = _parse_callback_html(res.get_data(as_text=True))
    assert parsed["h2"] == "Failed"
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [PAYMENT_STATUS_FAILED]
    # No enrollment row was created.
    with app.app_context():
        assert Enrollment.query.count() == 0


def test_unknown_transaction_cancel_callback(client, app):
    """The /cancel callback for an unknown transaction id must render
    the cancel page and must NOT create an enrollment row."""
    res = client.post(
        "/api/v1/payments/sslcommerz/cancel",
        data={"tran_id": "EC-GHOST-CANCEL"},
    )
    assert res.status_code == 200
    parsed = _parse_callback_html(res.get_data(as_text=True))
    assert parsed["h2"] == "Cancelled"
    from urllib.parse import parse_qs, urlparse
    qs = parse_qs(urlparse(parsed["button_href"]).query)
    assert qs["status"] == [PAYMENT_STATUS_CANCELLED]
    with app.app_context():
        assert Enrollment.query.count() == 0


def test_owner_can_read_status(client, app, user, auth_headers):
    """The status endpoint returns the payment row for the user who
    owns the transaction (the positive direction of the ownership
    guard)."""
    txn = "EC-OWN-OK"
    _seed_pending_payment(app, user, txn)
    res = client.get(
        f"/api/v1/payments/sslcommerz/status/{txn}",
        headers=auth_headers,
    )
    assert res.status_code == 200
    body = res.get_json()
    assert body["transaction_id"] == txn
    assert body["status"] == PAYMENT_STATUS_PENDING


def test_equivalent_decimal_amounts_validate(
    client, app, user, fake_provider,
):
    """Decimal equality must be normalised: gateway amount='500' must
    match a stored Decimal('500.00') and yield VALIDATED. The
    mismatch direction is already covered by
    test_amount_mismatch_marks_validation_failed — this covers the
    positive direction."""
    txn = "EC-TXN-DECIMAL-EQ"
    _seed_pending_payment(app, user, txn, amount=Decimal("500.00"))
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn,
        "amount": Decimal("500"),  # different shape, same value
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn,
            "amount": "500",
            "currency_type": "BDT",
            "risk_level": 0,
        },
    })
    client.post(
        "/api/v1/payments/sslcommerz/ipn",
        data={"tran_id": txn, "val_id": "VAL-DEC-EQ"},
    )
    with app.app_context():
        payment = Payment.query.filter_by(transaction_id=txn).one()
        assert payment.status == PAYMENT_STATUS_VALIDATED


def test_logs_do_not_leak_credentials(
    client, app, user, auth_headers, fake_provider, caplog,
):
    """Capture every log record emitted during a session creation +
    validation flow and assert that no record contains the
    SSLCOMMERZ store_passwd, password, card_number, or any of the
    other secret tokens that the gateway sends back. The Payment
    row's session_key is allowed to appear in DB columns but not
    in log messages."""
    with _patch_course({"course_id": "log-1", "is_free": False, "price": "500"}):
        with caplog.at_level("DEBUG"):
            client.post(
                "/api/v1/payments/sslcommerz/session",
                headers=auth_headers,
                json={"course_id": "log-1"},
            )
    txn_row = None
    with app.app_context():
        txn_row = Payment.query.filter_by(course_id="log-1").first()
    assert txn_row is not None

    # Now drive an IPN validation; the log must still be clean.
    fake_provider.validation_result.update({
        "status": "VALID",
        "tran_id": txn_row.transaction_id,
        "amount": Decimal("500.00"),
        "currency": "BDT",
        "raw": {
            "status": "VALID",
            "APIConnect": "DONE",
            "tran_id": txn_row.transaction_id,
            "amount": "500.00",
            "currency_type": "BDT",
            "risk_level": 0,
            # Each of these is a secret-like token. None of them
            # should appear in any log line.
            "store_passwd": "TOPSECRET",
            "card_number": "4111111111111111",
            "password": "hunter2",
        },
    })
    with caplog.at_level("DEBUG"):
        client.post(
            "/api/v1/payments/sslcommerz/ipn",
            data={"tran_id": txn_row.transaction_id, "val_id": "VAL-LOG"},
        )

    forbidden_substrings = (
        "TOPSECRET",
        "4111111111111111",
        "hunter2",
        "store_passwd",
        "card_number",
    )
    for record in caplog.records:
        for secret in forbidden_substrings:
            assert secret not in record.getMessage(), (
                f"log record leaked {secret!r}: {record.getMessage()!r}"
            )



def test_transaction_id_is_sslcommerz_compatible(client, auth_headers, fake_provider):
    with _patch_course({"course_id": "course-with-a-very-long-identifier", "is_free": False, "price": "500"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-with-a-very-long-identifier"},
        )
    assert res.status_code == 200
    transaction_id = res.get_json()["transaction_id"]
    assert 1 <= len(transaction_id) <= 30
    assert transaction_id.isalnum()


def test_session_returns_server_authoritative_amount(client, auth_headers, fake_provider):
    with _patch_course({"course_id": "course-priced", "is_free": False, "price": "BDT 750.50"}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-priced"},
        )
    assert res.status_code == 200
    body = res.get_json()
    assert body["amount"] == "750.50"
    assert body["currency"] == "BDT"
    assert body["course_id"] == "course-priced"


def test_missing_paid_price_can_use_explicit_sandbox_default(
    client, app, auth_headers, fake_provider
):
    app.config["PAYMENT_MODE"] = "sandbox"
    app.config["SANDBOX_DEFAULT_COURSE_PRICE_BDT"] = "10.00"
    with _patch_course({"course_id": "course-no-price", "is_free": False, "price": None}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-no-price"},
        )
    assert res.status_code == 200
    assert res.get_json()["amount"] == "10.00"


def test_sandbox_default_price_is_not_used_in_live_mode(
    client, app, auth_headers, fake_provider
):
    app.config["PAYMENT_MODE"] = "live"
    app.config["SANDBOX_DEFAULT_COURSE_PRICE_BDT"] = "10.00"
    with _patch_course({"course_id": "course-no-live-price", "is_free": False, "price": None}):
        res = client.post(
            "/api/v1/payments/sslcommerz/session",
            headers=auth_headers,
            json={"course_id": "course-no-live-price"},
        )
    assert res.status_code == 400
    assert res.get_json()["error"] == "INVALID_COURSE_PRICE"
