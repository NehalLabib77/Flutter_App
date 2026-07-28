"""All REST endpoints live in this single Blueprint.

Mounted at ``/api/v1``. Every response uses the envelope
``{success, data, message?, error_code?}``.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path

from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import (
    create_access_token,
    create_refresh_token,
    get_jwt_identity,
    jwt_required,
)

from datetime import datetime, timedelta, timezone

from database_models import (
    BillingEvent,
    CourseProgress,
    Favorite,
    History,
    LearningPathProgress,
    Subscription,
    User,
    UserInterest,
)
from extensions import db


log = logging.getLogger(__name__)
bp = Blueprint("api", __name__, url_prefix="/api/v1")

def _mask_phone(phone: str) -> str:
    """Return the last 4 digits of a phone number, e.g. `+880 1234`."""
    digits = re.sub(r"[^0-9]", "", phone or "")
    if len(digits) < 4:
        return ""
    return f"+{digits[:3]} {digits[-4:]}"


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------

def json_ok(data=None, message=None, status=200):
    payload = {"success": True, "data": data}
    if message:
        payload["message"] = message
    return jsonify(payload), status


def json_error(message, status=400, code="BAD_REQUEST"):
    return jsonify({
        "success": False,
        "data": None,
        "message": message,
        "error_code": code,
    }), status


def body() -> dict:
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def int_arg(name: str, default: int, max_value: int | None = None) -> int:
    raw = request.args.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    if value < 1:
        value = 1
    if max_value is not None:
        value = min(max_value, value)
    return value


def float_arg(name: str, default: float) -> float:
    raw = request.args.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def current_user() -> User | None:
    identity = get_jwt_identity()
    if identity is None:
        return None
    return User.query.get(int(identity))


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@bp.get("/health")
def health():
    adapter = current_app.extensions.get("educompass_model")
    if adapter is None:
        return json_ok({"status": "starting"})
    return json_ok({
        "status": "healthy",
        "model_version": adapter.meta.version,
        "courses_loaded": adapter.number_of_courses,
        "feature_count": adapter.meta.number_of_features,
    })


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

@bp.post("/auth/register")
def register():
    data = body()
    email = (data.get("email") or "").strip().casefold()
    password = data.get("password") or ""
    full_name = (data.get("full_name") or "").strip()

    if "@" not in email:
        return json_error("A valid email is required.", code="INVALID_EMAIL")
    if len(password) < 8:
        return json_error("Password must be at least 8 characters.",
                          code="WEAK_PASSWORD")
    if not full_name:
        return json_error("Full name is required.", code="MISSING_NAME")
    if User.query.filter_by(email=email).first():
        return json_error("Email already registered.",
                          status=409, code="EMAIL_TAKEN")

    user = User(email=email, full_name=full_name)
    user.set_password(password)
    db.session.add(user)
    db.session.commit()
    return json_ok(user.to_dict(), message="Account created.", status=201)


@bp.post("/auth/login")
def login():
    data = body()
    email = (data.get("email") or "").strip().casefold()
    password = data.get("password") or ""
    if not email or not password:
        return json_error("Email and password are required.",
                          code="MISSING_CREDENTIALS")
    user = User.query.filter_by(email=email).first()
    if user is None or not user.check_password(password):
        return json_error("Invalid email or password.",
                          status=401, code="INVALID_CREDENTIALS")
    return json_ok({
        "user": user.to_dict(),
        "access_token": create_access_token(identity=str(user.id)),
        "refresh_token": create_refresh_token(identity=str(user.id)),
    })


@bp.post("/auth/refresh")
@jwt_required(refresh=True)
def refresh():
    identity = get_jwt_identity()
    return json_ok({"access_token": create_access_token(identity=str(identity))})


@bp.get("/auth/me")
@jwt_required()
def me():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    return json_ok(user.to_dict())


@bp.put("/auth/profile")
@jwt_required()
def update_profile():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    data = body()
    name = (data.get("full_name") or "").strip()
    if name:
        user.full_name = name
    interests = data.get("interests")
    if isinstance(interests, list):
        UserInterest.query.filter_by(user_id=user.id).delete()
        for slug in interests[:50]:
            clean = str(slug).strip().casefold()
            if clean:
                db.session.add(UserInterest(user_id=user.id, interest=clean))
    db.session.commit()
    return json_ok(user.to_dict(), message="Profile updated.")


# ---------------------------------------------------------------------------
# Courses
# ---------------------------------------------------------------------------

@bp.get("/courses/search")
def courses_search():
    adapter = current_app.extensions["educompass_model"]
    query = (request.args.get("q") or "").strip()
    if not query:
        return json_error("Query parameter 'q' is required.",
                          code="MISSING_QUERY")
    page = int_arg("page", 1, max_value=500)
    page_size = int_arg("page_size", 20, max_value=50)
    offset = (page - 1) * page_size
    items, total = adapter.search_courses(
        query=query, limit=page_size, offset=offset,
    )
    return json_ok({"query": query, "page": page,
                    "page_size": page_size, "total": total,
                    "results": items})


@bp.get("/courses/autocomplete")
def courses_autocomplete():
    adapter = current_app.extensions["educompass_model"]
    query = (request.args.get("q") or "").strip()
    limit = int_arg("limit", 15, max_value=20)
    if len(query) < 2:
        return json_ok({"query": query, "suggestions": []})
    return json_ok({"query": query,
                    "suggestions": adapter.suggest(prefix=query, n=limit)})


@bp.get("/courses/popular")
def courses_popular():
    adapter = current_app.extensions["educompass_model"]
    limit = int_arg("limit", 12, max_value=50)
    return json_ok({"results": adapter.popular(limit=limit)})


@bp.get("/courses/top-rated")
def courses_top_rated():
    adapter = current_app.extensions["educompass_model"]
    limit = int_arg("limit", 12, max_value=50)
    return json_ok({"results": adapter.top_rated(limit=limit)})


@bp.get("/courses/<course_id>")
def course_detail(course_id):
    adapter = current_app.extensions["educompass_model"]
    row = adapter.get_course(course_id)
    if row is None:
        return json_error("Course not found.",
                          status=404, code="COURSE_NOT_FOUND")
    return json_ok({"course": row})


@bp.get("/courses/<course_id>/similar")
def course_similar(course_id):
    adapter = current_app.extensions["educompass_model"]
    limit = int_arg("limit", 6, max_value=20)
    selected = adapter.get_course(course_id)
    if selected is None:
        return json_error("Course not found.",
                          status=404, code="COURSE_NOT_FOUND")
    items = adapter.recommend_similar(course_id, limit=limit)
    return json_ok({"course": selected, "results": items})


# ---------------------------------------------------------------------------
# Recommendations
# ---------------------------------------------------------------------------

@bp.post("/recommendations/query")
def recommendations_query():
    adapter = current_app.extensions["educompass_model"]
    data = body()
    query = (data.get("query") or "").strip()
    if not query:
        return json_error("Field 'query' is required.", code="MISSING_QUERY")
    limit = int_arg("top_n", 10, max_value=50)
    items = adapter.recommend_query(query=query, limit=limit)
    return json_ok({"query": query, "count": len(items),
                    "recommendations": items})


@bp.post("/recommendations/personalized")
@jwt_required()
def recommendations_personalized():
    adapter = current_app.extensions["educompass_model"]
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    limit = int_arg("top_n", 10, max_value=50)
    interests = [str(i.interest) for i in user.interests if getattr(i, "interest", None)]
    favorites_ids = [str(f.course_id) for f in user.favorites]
    history_ids = [str(h.course_id) for h in user.history if h.course_id]
    items = adapter.recommend_personalized(
        interests=interests,
        favorites_ids=favorites_ids,
        history_ids=history_ids,
        limit=limit,
    )
    return json_ok({"count": len(items), "recommendations": items})


@bp.get("/recommendations/similar/<course_id>")
def recommendations_similar(course_id):
    adapter = current_app.extensions["educompass_model"]
    limit = int_arg("limit", 10, max_value=20)
    selected = adapter.get_course(course_id)
    if selected is None:
        return json_error("Course not found.",
                          status=404, code="COURSE_NOT_FOUND")
    items = adapter.recommend_similar(course_id, limit=limit)
    return json_ok({"course_id": course_id, "results": items})


@bp.get("/recommendations/filters")
def recommendations_filters():
    adapter = current_app.extensions["educompass_model"]
    return json_ok({"filters": adapter.filter_lists})


# ---------------------------------------------------------------------------
# Favorites / history / progress
# ---------------------------------------------------------------------------

@bp.get("/me/favorites")
@jwt_required()
def favorites_list():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    adapter = current_app.extensions.get("educompass_model")
    summary = [
        {"course_id": f.course_id,
         "added_at": f.created_at.isoformat() if f.created_at else None}
        for f in user.favorites
    ]
    courses = []
    if adapter is not None:
        for f in user.favorites:
            row = adapter.get_course(str(f.course_id))
            if row is not None:
                courses.append(row)
    return json_ok({"favorites": summary, "results": courses})


@bp.post("/me/favorites")
@jwt_required()
def favorites_add():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    course_id = str(body().get("course_id") or "").strip()
    if not course_id:
        return json_error("Field 'course_id' is required.",
                          code="MISSING_COURSE")
    exists = Favorite.query.filter_by(user_id=user.id,
                                      course_id=course_id).first()
    if exists:
        return json_ok(message="Already saved.")
    db.session.add(Favorite(user_id=user.id, course_id=course_id))
    db.session.commit()
    return json_ok(message="Saved.", status=201)


@bp.delete("/me/favorites/<course_id>")
@jwt_required()
def favorites_remove(course_id):
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    Favorite.query.filter_by(user_id=user.id,
                             course_id=str(course_id)).delete()
    db.session.commit()
    return json_ok(message="Removed.")


@bp.get("/me/history")
@jwt_required()
def history_list():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    items = sorted(user.history, key=lambda h: h.created_at, reverse=True)
    return json_ok({"history": [
        {"course_id": h.course_id, "action": h.action,
         "viewed_at": h.created_at.isoformat() if h.created_at else None}
        for h in items
    ]})


@bp.post("/me/history")
@jwt_required()
def history_add():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    data = body()
    course_id = str(data.get("course_id") or "").strip() or None
    action = (data.get("action") or "view").strip()
    db.session.add(History(user_id=user.id, course_id=course_id,
                           action=action))
    db.session.commit()
    return json_ok(message="Recorded.", status=201)


@bp.get("/me/progress")
@jwt_required()
def progress_list():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    return json_ok({"progress": [
        {"course_id": p.course_id, "percent": int(p.progress or 0),
         "completed": bool(p.completed),
         "updated_at": p.updated_at.isoformat() if p.updated_at else None}
        for p in user.progress
    ]})


@bp.put("/me/progress/<course_id>")
@jwt_required()
def progress_update(course_id):
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    try:
        percent = int(body().get("percent", 0))
    except (TypeError, ValueError):
        return json_error("Field 'percent' must be an integer.",
                          code="INVALID_PERCENT")
    percent = max(0, min(100, percent))
    row = CourseProgress.query.filter_by(
        user_id=user.id, course_id=str(course_id)
    ).first()
    if row is None:
        row = CourseProgress(user_id=user.id, course_id=str(course_id),
                             progress=percent, completed=percent >= 100)
        db.session.add(row)
    else:
        row.progress = percent
        row.completed = percent >= 100
    db.session.commit()
    return json_ok(message="Progress saved.")


# ---------------------------------------------------------------------------
# Learning paths
# ---------------------------------------------------------------------------

_PATHS_CACHE: list | None = None


def _load_paths() -> list:
    """Load and cache the learning paths JSON file.

    The on-disk file is a flat list of path objects. We normalise it to a
    list here and let callers iterate directly.
    """

    global _PATHS_CACHE
    if _PATHS_CACHE is not None:
        return _PATHS_CACHE
    path_str = current_app.config.get("LEARNING_PATHS_FILE")
    if not path_str:
        _PATHS_CACHE = []
        return _PATHS_CACHE
    file_path = Path(path_str)
    if not file_path.exists():
        _PATHS_CACHE = []
        return _PATHS_CACHE
    try:
        with file_path.open("r", encoding="utf-8") as fp:
            raw = json.load(fp)
    except (OSError, ValueError) as exc:
        log.warning("Could not load learning paths from %s: %s",
                    file_path, exc)
        _PATHS_CACHE = []
        return _PATHS_CACHE
    if isinstance(raw, list):
        _PATHS_CACHE = raw
    elif isinstance(raw, dict):
        _PATHS_CACHE = list(raw.get("paths") or [])
    else:
        _PATHS_CACHE = []
    return _PATHS_CACHE


def _find_path(path_id: str) -> dict | None:
    """Return the path dict matching ``path_id`` or ``None``."""

    for entry in _load_paths():
        if str(entry.get("id")) == str(path_id):
            return entry
    return None


@bp.get("/learning-paths")
def learning_paths_list():
    paths = _load_paths()
    summaries = [
        {"id": p.get("id"), "title": p.get("title"),
         "summary": p.get("summary"),
         "step_count": len(p.get("steps", []))}
        for p in paths
    ]
    return json_ok({"paths": summaries})


@bp.get("/learning-paths/<path_id>")
def learning_path_detail(path_id):
    path = _find_path(path_id)
    if path is None:
        return json_error("Learning path not found.",
                          status=404, code="PATH_NOT_FOUND")
    return json_ok({"path": path})


@bp.get("/learning-paths/<path_id>/progress")
@jwt_required()
def learning_path_progress(path_id):
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    rows = [
        {"step_id": r.step_id, "completed": bool(r.completed),
         "updated_at": r.updated_at.isoformat() if r.updated_at else None}
        for r in user.learning_progress
        if str(r.path_id) == str(path_id)
    ]
    return json_ok({"path_id": path_id, "progress": rows})


@bp.put("/learning-paths/<path_id>/progress")
@jwt_required()
def learning_path_progress_update(path_id):
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    if _find_path(path_id) is None:
        return json_error("Learning path not found.",
                          status=404, code="PATH_NOT_FOUND")
    data = body()
    step_id = str(data.get("step_id") or "").strip()
    if not step_id:
        return json_error("Field 'step_id' is required.",
                          code="MISSING_STEP")
    completed = bool(data.get("completed", True))
    row = LearningPathProgress.query.filter_by(
        user_id=user.id, path_id=str(path_id), step_id=step_id
    ).first()
    if row is None:
        row = LearningPathProgress(user_id=user.id, path_id=str(path_id),
                                   step_id=step_id, completed=completed)
        db.session.add(row)
    else:
        row.completed = completed
    db.session.commit()
    return json_ok(message="Step updated.")


# ---------------------------------------------------------------------------
# Billing
# ---------------------------------------------------------------------------

@bp.post("/billing/otp/request")
def billing_otp_request():
    phone = (body().get("phone") or "").strip()
    if not phone:
        return json_error("Field 'phone' is required.",
                          code="MISSING_PHONE")
    provider = current_app.extensions["billing_provider"]
    try:
        result = provider.request_otp(phone_number=phone)
    except ValueError as exc:
        return json_error(str(exc), code="INVALID_PHONE")
    return json_ok({"reference": result.reference,
                    "hint": result.hint}, message="OTP requested.")


@bp.post("/billing/otp/verify")
def billing_otp_verify():
    data = body()
    phone = (data.get("phone") or "").strip()
    code = (data.get("code") or "").strip()
    if not phone or not code:
        return json_error("Phone and code are required.",
                          code="MISSING_FIELDS")
    provider = current_app.extensions["billing_provider"]
    try:
        result = provider.verify_otp(phone_number=phone, code=code)
    except ValueError as exc:
        return json_error(str(exc), code="INVALID_CODE")
    if not result.success:
        return json_error("Invalid or expired code.",
                          status=401, code="OTP_REJECTED")
    return json_ok({"verified": True,
                    "reference": result.reference}, message="Phone verified.")


@bp.get("/billing/subscription")
@jwt_required()
def billing_subscription():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    sub = Subscription.query.filter_by(user_id=user.id).first()
    return json_ok({"subscription": sub.to_dict() if sub else None})


@bp.post("/billing/subscription/activate")
@jwt_required()
def billing_subscription_activate():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    data = body()
    plan = (data.get("plan") or "monthly").strip().casefold()
    if plan not in {"monthly", "yearly"}:
        return json_error("Plan must be 'monthly' or 'yearly'.",
                          code="INVALID_PLAN")
    phone = (data.get("phone") or user.phone_number or "").strip()
    reference = (data.get("provider_reference") or "").strip()
    if not re.fullmatch(r"\+?[0-9]{8,15}", phone):
        return json_error("A verified phone number is required.",
                          code="PHONE_REQUIRED")
    if not reference:
        return json_error("An OTP verification reference is required.",
                          code="REFERENCE_REQUIRED")
    provider_obj = current_app.extensions.get("billing_provider")
    provider_name = getattr(provider_obj, "name", "bdapps")
    user.phone_number = phone
    user.phone_verified = True
    started_at = datetime.now(timezone.utc)
    expires_at = started_at + (timedelta(days=365)
                                if plan == "yearly"
                                else timedelta(days=30))
    sub = Subscription.query.filter_by(user_id=user.id).first()
    if sub is None:
        sub = Subscription(user_id=user.id, plan_code=plan,
                           status="active",
                           provider=provider_name,
                           provider_reference=reference,
                           subscriber_id_masked=_mask_phone(phone),
                           started_at=started_at,
                           expires_at=expires_at)
        db.session.add(sub)
    else:
        sub.plan_code = plan
        sub.status = "active"
        sub.provider = provider_name
        sub.provider_reference = reference
        sub.subscriber_id_masked = _mask_phone(phone)
        sub.started_at = started_at
        sub.expires_at = expires_at
    db.session.add(BillingEvent(
        user_id=user.id, event_type="subscription.activate",
        provider=provider_name, provider_reference=reference,
        status="ok",
        safe_metadata_json=json.dumps({"plan": plan})))
    db.session.commit()
    return json_ok(sub.to_dict(), message="Subscription activated.")


__all__ = ["bp"]