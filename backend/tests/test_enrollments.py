"""Hermetic tests for the ``/me/enrollments`` endpoints.

Covers the three new routes:

* ``GET    /api/v1/me/enrollments``
* ``POST   /api/v1/me/enrollments``
* ``DELETE /api/v1/me/enrollments/<course_id>``

The Flask app is built with ``create_app(skip_model_load=True)`` so the
TF-IDF bundle is never loaded; ``FLASK_ENV=testing`` switches the SQL
store to an in-memory SQLite database. We bypass Firebase entirely by
inserting a ``User`` row directly through SQLAlchemy and minting a JWT
with ``create_access_token(identity=str(user.id))`` — exactly what the
``current_user()`` helper expects to see in ``get_jwt_identity()``.
"""

from __future__ import annotations

import os

# Must be set before the app is imported so ``get_config`` picks it up.
os.environ.setdefault("FLASK_ENV", "testing")

import pytest
from flask import Flask
from flask_jwt_extended import create_access_token

from app import create_app
from app.database_models import Enrollment, User, db
from sqlalchemy import text


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def app() -> Flask:
    """A fresh app per test, with in-memory SQLite + empty tables."""

    app = create_app(skip_model_load=True)
    app.config["TESTING"] = True

    with app.app_context():
        # ``create_app`` already ran ``db.create_all`` (TestingConfig),
        # but a previous test may have left rows behind if the SQLite
        # URL was reused. Wipe user-scoped rows to keep tests isolated.
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
    """Insert a User row directly and return the SQLAlchemy instance."""

    with app.app_context():
        u = User(
            full_name="Test Learner",
            email="learner@example.com",
            firebase_uid="firebase-test-uid",
            password_hash="not-used-in-tests",
            phone_number="+8801700000000",
            phone_verified=True,
        )
        db.session.add(u)
        db.session.commit()
        # Detach so callers can read ``u.id`` outside the app context.
        db.session.refresh(u)
        yield u


@pytest.fixture()
def auth_headers(app: Flask, user: User):
    """Authorization headers for the seeded user."""

    with app.app_context():
        token = create_access_token(identity=str(user.id))
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Auth gating
# ---------------------------------------------------------------------------


def test_list_requires_jwt(client):
    res = client.get("/api/v1/me/enrollments")
    assert res.status_code == 401


def test_add_requires_jwt(client):
    res = client.post(
        "/api/v1/me/enrollments",
        json={"course_id": "course-1"},
    )
    assert res.status_code == 401


def test_remove_requires_jwt(client):
    res = client.delete("/api/v1/me/enrollments/course-1")
    assert res.status_code == 401


# ---------------------------------------------------------------------------
# Empty list
# ---------------------------------------------------------------------------


def test_list_empty(client, auth_headers):
    body = client.get(
        "/api/v1/me/enrollments", headers=auth_headers
    ).get_json()
    assert body["success"] is True
    assert body["data"]["enrollments"] == []


# ---------------------------------------------------------------------------
# Add (upsert)
# ---------------------------------------------------------------------------


def test_add_creates_row(client, auth_headers, app, user):
    res = client.post(
        "/api/v1/me/enrollments",
        headers=auth_headers,
        json={
            "course_id": "course-1",
            "payment_method": "bKash",
            "transaction_id": "TXN-001",
            "payment_status": "completed",
        },
    )
    assert res.status_code == 201
    body = res.get_json()
    assert body["success"] is True
    assert body["data"]["course_id"] == "course-1"
    assert body["data"]["payment_method"] == "bKash"
    assert body["data"]["transaction_id"] == "TXN-001"
    assert body["data"]["payment_status"] == "completed"
    assert body["data"]["enrolled_at"]  # ISO timestamp populated

    with app.app_context():
        rows = Enrollment.query.filter_by(user_id=user.id).all()
        assert len(rows) == 1
        assert rows[0].course_id == "course-1"


def test_add_is_idempotent(client, auth_headers, app, user):
    """Re-POSTing the same course updates fields, never duplicates."""

    client.post(
        "/api/v1/me/enrollments",
        headers=auth_headers,
        json={"course_id": "course-2", "transaction_id": "TXN-A"},
    )
    client.post(
        "/api/v1/me/enrollments",
        headers=auth_headers,
        json={
            "course_id": "course-2",
            "transaction_id": "TXN-B",
            "payment_method": "Nagad",
        },
    )

    with app.app_context():
        rows = Enrollment.query.filter_by(user_id=user.id).all()
        assert len(rows) == 1
        assert rows[0].transaction_id == "TXN-B"
        assert rows[0].payment_method == "Nagad"


def test_add_defaults_payment_status(client, auth_headers, app, user):
    """When the client omits payment_status, the row defaults to 'completed'."""

    client.post(
        "/api/v1/me/enrollments",
        headers=auth_headers,
        json={"course_id": "course-free", "payment_method": "free"},
    )

    with app.app_context():
        row = Enrollment.query.filter_by(
            user_id=user.id, course_id="course-free"
        ).one()
        assert row.payment_status == "completed"


def test_add_rejects_missing_course_id(client, auth_headers):
    res = client.post(
        "/api/v1/me/enrollments",
        headers=auth_headers,
        json={"payment_method": "bKash"},
    )
    body = res.get_json()
    assert res.status_code == 400
    assert body["success"] is False
    assert body["error_code"] == "MISSING_COURSE"


# ---------------------------------------------------------------------------
# List (with rows)
# ---------------------------------------------------------------------------


def test_list_returns_rows_newest_first(client, auth_headers, app, user):
    with app.app_context():
        db.session.add(Enrollment(user_id=user.id, course_id="c-old"))
        db.session.add(Enrollment(user_id=user.id, course_id="c-new"))
        db.session.commit()

    body = client.get(
        "/api/v1/me/enrollments", headers=auth_headers
    ).get_json()
    assert body["success"] is True
    rows = body["data"]["enrollments"]
    assert [r["course_id"] for r in rows] == ["c-new", "c-old"]


# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------


def test_remove_deletes_row(client, auth_headers, app, user):
    with app.app_context():
        db.session.add(Enrollment(user_id=user.id, course_id="c-drop"))
        db.session.commit()

    res = client.delete(
        "/api/v1/me/enrollments/c-drop", headers=auth_headers
    )
    body = res.get_json()
    assert res.status_code == 200
    assert body["success"] is True

    listing = client.get(
        "/api/v1/me/enrollments", headers=auth_headers
    ).get_json()
    assert listing["data"]["enrollments"] == []

    with app.app_context():
        assert Enrollment.query.filter_by(
            user_id=user.id, course_id="c-drop"
        ).one_or_none() is None


def test_remove_missing_is_idempotent(client, auth_headers):
    """Deleting a course the user never enrolled in still 200s."""

    res = client.delete(
        "/api/v1/me/enrollments/never-enrolled", headers=auth_headers
    )
    body = res.get_json()
    assert res.status_code == 200
    assert body["success"] is True


def test_remove_only_affects_caller(app, user, client):
    """One user's drop must not touch another user's row."""

    with app.app_context():
        other = User(
            full_name="Other",
            email="other@example.com",
            password_hash="x",
        )
        db.session.add(other)
        db.session.commit()
        other_id = other.id

        db.session.add(Enrollment(user_id=user.id, course_id="shared"))
        db.session.add(Enrollment(user_id=other_id, course_id="shared"))
        db.session.commit()

        own_token = create_access_token(identity=str(user.id))

    res = client.delete(
        "/api/v1/me/enrollments/shared",
        headers={"Authorization": f"Bearer {own_token}"},
    )
    assert res.status_code == 200

    with app.app_context():
        # Caller's row gone, other user's row untouched.
        assert Enrollment.query.filter_by(
            user_id=user.id, course_id="shared"
        ).one_or_none() is None
        assert Enrollment.query.filter_by(
            user_id=other_id, course_id="shared"
        ).one_or_none() is not None
