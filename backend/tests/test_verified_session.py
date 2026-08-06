"""Regression tests for verified-session authorization.

A valid EduCompass JWT is created only after Firebase email verification.
Protected routes must therefore trust that signed session instead of calling
Firebase Admin again on every request. This keeps favourites and personalised
recommendations available during temporary Firebase Admin outages.
"""

from __future__ import annotations

import os

os.environ.setdefault("FLASK_ENV", "testing")

import pytest
from flask import Flask
from flask_jwt_extended import create_access_token
from sqlalchemy import text

from app import create_app
from app.database_models import User, db


class _FakeRecommendationAdapter:
    def recommend_personalized(
        self,
        *,
        interests,
        favorites_ids,
        history_ids,
        limit,
    ):
        return []


@pytest.fixture()
def app() -> Flask:
    app = create_app(skip_model_load=True)
    app.config["TESTING"] = True
    app.extensions["educompass_model"] = _FakeRecommendationAdapter()

    with app.app_context():
        db.session.execute(text("DELETE FROM favorites"))
        db.session.execute(text("DELETE FROM users"))
        db.session.commit()

    yield app

    with app.app_context():
        db.session.remove()


@pytest.fixture()
def client(app: Flask):
    return app.test_client()


@pytest.fixture()
def user_id(app: Flask) -> int:
    with app.app_context():
        user = User(
            full_name="Verified Learner",
            email="verified@example.com",
            firebase_uid="firebase-verified-user",
            password_hash="not-used",
        )
        db.session.add(user)
        db.session.commit()
        return int(user.id)


def _headers(app: Flask, user_id: int, **claims) -> dict[str, str]:
    with app.app_context():
        token = create_access_token(
            identity=str(user_id),
            additional_claims=claims or None,
        )
    return {"Authorization": f"Bearer {token}"}


def test_legacy_valid_jwt_does_not_recheck_firebase(
    client,
    app: Flask,
    user_id: int,
    monkeypatch,
):
    def _must_not_be_called(_uid: str) -> bool:
        raise AssertionError("Firebase verification was rechecked")

    monkeypatch.setattr(
        "app.firebase_client.is_email_verified",
        _must_not_be_called,
    )

    response = client.post(
        "/api/v1/me/favorites",
        headers=_headers(app, user_id),
        json={"course_id": "course-1"},
    )

    assert response.status_code == 201
    assert response.get_json()["success"] is True


def test_verified_claim_allows_personalized_recommendations(
    client,
    app: Flask,
    user_id: int,
):
    response = client.post(
        "/api/v1/recommendations/personalized",
        headers=_headers(
            app,
            user_id,
            email_verified=True,
            firebase_uid="firebase-verified-user",
        ),
        json={"top_n": 10},
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["success"] is True
    assert body["data"]["recommendations"] == []


def test_explicit_unverified_claim_is_rejected(
    client,
    app: Flask,
    user_id: int,
):
    response = client.post(
        "/api/v1/me/favorites",
        headers=_headers(app, user_id, email_verified=False),
        json={"course_id": "course-2"},
    )

    assert response.status_code == 403
    body = response.get_json()
    assert body["success"] is False
    assert body["error_code"] == "EMAIL_NOT_VERIFIED"
