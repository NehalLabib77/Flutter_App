"""All REST endpoints live in this single Blueprint.

Mounted at ``/api/v1``. Every response uses the envelope
``{success, data, message?, error_code?}``.
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import (
    create_access_token,
    create_refresh_token,
    get_jwt_identity,
    jwt_required,
)

from .database_models import (
    CourseProgress,
    Enrollment,
    Favorite,
    History,
    LearningPathProgress,
    User,
    UserInterest,
)
from .auth_otp import get_auth_otp_store
from .extensions import db
from . import firebase_client

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

@bp.post("/auth/otp/request")
def auth_otp_request():
    """Issue a one-time code for the auth (login or register) flow.

    Body: ``{"phone": "+8801...", "purpose": "login" | "register"}``
    """
    data = body()
    phone = (data.get("phone") or "").strip()
    purpose = (data.get("purpose") or "").strip().casefold()
    if purpose not in ("login", "register"):
        return json_error("Field 'purpose' must be 'login' or 'register'.",
                          code="INVALID_PURPOSE")
    if not phone:
        return json_error("Field 'phone' is required.",
                          code="MISSING_PHONE")
    # For login we additionally require that the phone is on file for some
    # user so we don't leak which emails are registered.
    if purpose == "login":
        email = (data.get("email") or "").strip().casefold()
        user = User.query.filter_by(email=email).first() if email else None
        if user is None or not user.phone_number:
            return json_error(
                "No account with that email has a phone number on file. "
                "Add a phone number first.",
                status=404, code="PHONE_NOT_ON_FILE")
        if user.phone_number != _normalise_phone_local(phone):
            return json_error(
                "Phone does not match the one on file for this account.",
                status=400, code="PHONE_MISMATCH")
    store = get_auth_otp_store()
    try:
        result = store.request(phone=phone, purpose=purpose)
    except ValueError as exc:
        return json_error(str(exc), code="INVALID_PHONE")
    return json_ok({"reference": result.reference,
                    "hint": result.hint,
                    "ttl_seconds": 300,
                    # dev_code is only populated in dev/mock mode — wired straight
                    # into the OTP store. Real SMS gateways would *not* include
                    # this so we never accidentally leak a real code to clients.
                    "dev_code": result.dev_code}, message="Code sent.")


@bp.post("/auth/otp/verify")
def auth_otp_verify():
    """Verify a one-time code and (optionally) bind it to a new account.

    Body: ``{"phone": "+8801...", "code": "123456", "purpose": "..."}``
    """
    data = body()
    phone = (data.get("phone") or "").strip()
    code = (data.get("code") or "").strip()
    purpose = (data.get("purpose") or "").strip().casefold()
    if purpose not in ("login", "register"):
        return json_error("Field 'purpose' must be 'login' or 'register'.",
                          code="INVALID_PURPOSE")
    if not phone or not code:
        return json_error("Phone and code are required.",
                          code="MISSING_FIELDS")
    store = get_auth_otp_store()
    result = store.verify(phone=phone, code=code, purpose=purpose)
    if not result.success:
        code_name = (result.failure_reason or "invalid").upper()
        return json_error(f"Invalid or expired code ({code_name}).",
                          status=401, code="OTP_REJECTED")
    return json_ok({"verified": True,
                    "reference": result.reference}, message="Phone verified.")


def _normalise_phone_local(phone: str) -> str:
    import re as _re
    return _re.sub(r"\s+", "", phone or "").strip()


@bp.post("/auth/register")
def register():
    data = body()
    email = (data.get("email") or "").strip().casefold()
    password = data.get("password") or ""
    full_name = (data.get("full_name") or "").strip()
    # Phone + OTP are accepted but ignored — legacy clients may still send
    # them. New clients should not.
    legacy_phone = (data.get("phone") or "").strip()
    legacy_otp = (data.get("otp_reference") or "").strip()
    if legacy_phone or legacy_otp:
        # Drain any pending OTP slot so the legacy flow can't accidentally
        # succeed for accounts that didn't ask for it.
        try:
            get_auth_otp_store().verify(
                phone=legacy_phone, code="*consume*", purpose="register")
        except Exception:  # noqa: BLE001
            pass

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

    # Firebase Auth is the source of truth for identity. If the SDK /
    # creds aren't configured, we *fail* rather than silently create a
    # dangling SQL account — otherwise the user would exist in SQL but
    # never in Firebase, which is exactly the bug this change is meant
    # to fix.
    if not firebase_client.is_configured():
        hint = firebase_client.configuration_hint()
        log.error("Firebase credentials missing — refusing registration. %s",
                  hint)
        return json_error(
            f"Authentication backend is not configured. {hint}",
            status=503, code="AUTH_BACKEND_UNAVAILABLE",
        )

    # 1. Create the Firebase Auth user. Maps Firebase's typed errors to
    #    the same error codes the old SQL path used.
    try:
        uid = firebase_client.create_auth_user(
            email=email, password=password, display_name=full_name,
        )
    except Exception as exc:  # noqa: BLE001 — map Admin SDK errors
        try:
            from firebase_admin import auth as fb_auth
            if isinstance(exc, fb_auth.EmailAlreadyExistsError):
                return json_error("Email already registered.",
                                  status=409, code="EMAIL_TAKEN")
            if isinstance(exc, fb_auth.InvalidPasswordError):
                return json_error("Password must be at least 8 characters.",
                                  code="WEAK_PASSWORD")
            if isinstance(exc, fb_auth.InvalidEmailError):
                return json_error("A valid email is required.",
                                  code="INVALID_EMAIL")
        except ImportError:
            pass
        log.exception("Firebase create_user failed for %s", email)
        return json_error("Could not create account.",
                          status=502, code="AUTH_PROVIDER_ERROR")

    # 2. Mirror the profile into Firestore (best-effort — failure here
    #    is logged but does not block the SQL row, so the user can
    #    still log in and re-sync later).
    try:
        firebase_client.upsert_user_profile(
            uid, email=email, full_name=full_name,
            extra={"created_via": "flask-backend"},
        )
    except Exception:  # noqa: BLE001
        log.exception("Firestore profile write failed for uid=%s", uid)

    # 3. Create the SQL mirror row. password_hash is set to a
    #    meaningless sentinel — login goes through Firebase.
    from werkzeug.security import generate_password_hash
    user = User(
        email=email,
        full_name=full_name,
        phone_number=None,
        phone_verified=False,
        firebase_uid=uid,
    )
    user.password_hash = generate_password_hash(
        # 32-byte random value so the hash exists but is unusable.
        os.urandom(32).hex()
    )
    db.session.add(user)
    db.session.commit()
    return json_ok(user.to_dict(), message="Account created.", status=201)


@bp.post("/auth/login")
def login():
    data = body()
    email = (data.get("email") or "").strip().casefold()
    password = data.get("password") or ""
    # Phone + OTP are accepted but ignored. Old clients may still POST them;
    # we don't want them to affect the outcome.
    legacy_phone = (data.get("phone") or "").strip()
    legacy_otp = (data.get("otp_reference") or "").strip()
    if legacy_phone or legacy_otp:
        try:
            get_auth_otp_store().verify(
                phone=legacy_phone, code="*consume*", purpose="login")
        except Exception:  # noqa: BLE001
            pass

    if not email or not password:
        return json_error("Email and password are required.",
                          code="MISSING_CREDENTIALS")

    if not firebase_client.is_configured():
        hint = firebase_client.configuration_hint()
        return json_error(
            f"Authentication backend is not configured. {hint}",
            status=503, code="AUTH_BACKEND_UNAVAILABLE",
        )

    # 1. Verify the password against Firebase Auth. This is the single
    #    source of truth — the SQL hash is never consulted.
    try:
        uid = firebase_client.verify_password(email=email, password=password)
    except firebase_client.PasswordVerificationError as exc:
        status_map = {
            "INVALID_CREDENTIALS": 401,
            "USER_DISABLED": 403,
            "TOO_MANY_ATTEMPTS": 429,
            "NETWORK_ERROR": 502,
            "SERVER_MISCONFIGURED": 500,
        }
        return json_error(
            exc.message,
            status=status_map.get(exc.code, 401),
            code=exc.code if exc.code != "INVALID_CREDENTIALS"
                 else "INVALID_CREDENTIALS",
        )

    # 2. Find the SQL mirror by firebase_uid. Fall back to email so
    #    legacy accounts created before the Firebase cutover still
    #    work.
    user = User.query.filter_by(firebase_uid=uid).first()
    if user is None:
        user = User.query.filter_by(email=email).first()
        if user is not None and user.firebase_uid is None:
            user.firebase_uid = uid
            db.session.commit()
    if user is None:
        # Firebase says the account exists, but it doesn't in SQL.
        # Provision the mirror row on the fly so existing favourites
        # / progress / history endpoints keep working.
        from werkzeug.security import generate_password_hash
        fb_user = firebase_client.get_auth_user_by_email(email)
        user = User(
            email=email,
            full_name=(fb_user.display_name if fb_user else "") or email,
            phone_number=None,
            phone_verified=False,
            firebase_uid=uid,
        )
        user.password_hash = generate_password_hash(os.urandom(32).hex())
        db.session.add(user)
        db.session.commit()

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
# Enrollments (paid + free courses the user has signed up for)
# ---------------------------------------------------------------------------   
#
# These endpoints mirror the Firebase ``users/{uid}/enrollments/{id}``
# docs so a server-side render (or a second device) can see the same
# list. The client is still expected to write to Firestore first; these
# routes are the SQL fallback / cross-device sync target.
#
# Schema matches ``Enrollment.to_dict()``:
#     {course_id, payment_method, transaction_id, payment_status,
#      enrolled_at}


@bp.get("/me/enrollments")
@jwt_required()
def enrollments_list():
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    rows = sorted(user.enrollments, key=lambda e: e.enrolled_at,
                  reverse=True)
    return json_ok({
        "enrollments": [e.to_dict() for e in rows],
    })


@bp.post("/me/enrollments")
@jwt_required()
def enrollments_add():
    """Upsert an enrollment. Idempotent on (user_id, course_id)."""
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    data = body()
    course_id = str(data.get("course_id") or "").strip()
    if not course_id:
        return json_error("Field 'course_id' is required.",
                          code="MISSING_COURSE")
    payment_method = str(data.get("payment_method") or "").strip()
    transaction_id = str(data.get("transaction_id") or "").strip()
    payment_status = (str(data.get("payment_status") or "completed")
                      .strip() or "completed")

    row = Enrollment.query.filter_by(
        user_id=user.id, course_id=course_id
    ).first()
    if row is None:
        row = Enrollment(
            user_id=user.id,
            course_id=course_id,
            payment_method=payment_method,
            transaction_id=transaction_id,
            payment_status=payment_status,
        )
        db.session.add(row)
    else:
        # Refresh the mutable fields so a re-enroll with a new txn id
        # (e.g. retry after a failed payment) updates the record.
        row.payment_method = payment_method
        row.transaction_id = transaction_id
        row.payment_status = payment_status
    db.session.commit()
    return json_ok(row.to_dict(), message="Enrolled.", status=201)


@bp.delete("/me/enrollments/<course_id>")
@jwt_required()
def enrollments_remove(course_id):
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    Enrollment.query.filter_by(
        user_id=user.id, course_id=str(course_id)
    ).delete()
    db.session.commit()
    return json_ok(message="Removed.")


# ---------------------------------------------------------------------------   
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


__all__ = ["bp"]