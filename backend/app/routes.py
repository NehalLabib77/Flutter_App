"""All REST endpoints live in this single Blueprint.

Mounted at ``/api/v1``. Every response uses the envelope
``{success, data, message?, error_code?}``.
"""

from __future__ import annotations

import json
import logging
import os
import re
from functools import wraps
from pathlib import Path

from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import (
    create_access_token,
    create_refresh_token,
    get_jwt,
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
    UserInteraction,
    UserPreference,
    UserInterest,
)
from .auth_otp import get_auth_otp_store
from .extensions import db
from . import firebase_client
from .recommendation_profile import (
    INTERACTION_WEIGHTS,
    get_recent_interactions,
    get_user_preferences,
    normalize_preferences,
    preferences_are_empty,
    record_interaction,
    upsert_user_preferences,
)

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


def int_body(data: dict, name: str, default: int, max_value: int | None = None) -> int:
    raw = data.get(name, default)
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = default
    value = max(1, value)
    if max_value is not None:
        value = min(value, max_value)
    return value


def _preferences_from_args() -> dict:
    return normalize_preferences({
        "subjects": request.args.get("subjects", ""),
        "skills": request.args.get("skills", ""),
        "level": request.args.get("level", ""),
        "course_type": request.args.get("course_type", ""),
        "certificate_type": request.args.get("certificate_type", ""),
        "price_preference": request.args.get("price_preference", ""),
        "provider": request.args.get("provider", ""),
        "organization": request.args.get("organization", ""),
    })


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


def verified_user_required(view_function):
    """Require a valid EduCompass JWT issued after email verification.

    The login endpoint is the verification boundary: it checks Firebase's
    ``email_verified`` flag before issuing either an access token or a
    refresh token. Re-checking Firebase on every favourites,
    recommendation, progress, enrollment, and payment request made valid
    logged-in sessions fail whenever Firebase Admin is temporarily slow,
    unavailable, or returning stale user data.

    A valid signed JWT therefore represents a verified EduCompass session.
    New tokens carry ``email_verified=True`` explicitly. Legacy tokens that
    predate the claim remain accepted because they could only have been
    issued by the same verified-only login route. A token that explicitly
    carries ``email_verified=False`` is rejected.
    """

    @wraps(view_function)
    def wrapped_view(*args, **kwargs):
        user = current_user()
        if user is None:
            return json_error(
                "Account not found.",
                status=404,
                code="USER_NOT_FOUND",
            )

        claims = get_jwt()
        if claims.get("email_verified") is False:
            return json_error(
                "This session was created before email verification.",
                status=403,
                code="EMAIL_NOT_VERIFIED",
            )

        return view_function(*args, **kwargs)

    return wrapped_view


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
    # The SQL row is a thin mirror — Firebase Auth is the source of
    # truth. If a SQL row exists for this email but the Firebase user
    # is gone (e.g. someone deleted it directly in the Firebase
    # console), drop the orphan so re-registration can succeed.
    # Otherwise surface the usual "already registered" 409.
    if User.query.filter_by(email=email).first():
        if firebase_client.is_configured():
            fb_user = firebase_client.get_auth_user_by_email(email)
            if fb_user is None:
                log.warning(
                    "Stale SQL user for %s (no Firebase record) — "
                    "deleting orphan before re-registration.", email,
                )
                User.query.filter_by(email=email).delete()
                db.session.commit()
            else:
                return json_error("Email already registered.",
                                  status=409, code="EMAIL_TAKEN")
        else:
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

    # 4. Send the verification email. Best-effort — if this fails the
    #    user can request a fresh link from the login screen. We don't
    #    roll the registration back because the account itself was
    #    created successfully in Firebase.
    try:
        firebase_client.send_verification_email(email)
    except firebase_client.EmailVerificationError as exc:
        log.warning(
            "Could not send verification email to %s: %s", email, exc.message,
        )

    return json_ok(user.to_dict(), message="Account created.", status=201)


@bp.delete("/auth/account")
@jwt_required()
def delete_account():
    """Permanently delete the caller's account.

    Removes the user from Firebase Auth (source of truth) and the SQL
    mirror row in one transaction so the two stores can't drift out
    of sync — which is the bug that left users stuck unable to
    re-register after a manual Firebase deletion.

    Returns ``204`` on success. Cascade on the SQL relationships
    cleans up favourites / history / progress / enrollments.
    """

    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")

    uid = user.firebase_uid

    # 1. Delete from Firebase Auth first. If this fails we abort
    #    before touching SQL so we don't end up with the inverse
    #    drift (SQL gone, Firebase user still alive).
    auth = firebase_client.auth_client()
    if auth is not None and uid:
        try:
            auth.delete_user(uid)
        except Exception as exc:  # noqa: BLE001
            try:
                from firebase_admin import auth as fb_auth
                # UserNotFoundError is fine — the SQL row may have
                # outlived a manual Firebase deletion, which is
                # exactly when this endpoint is most useful.
                if not isinstance(exc, fb_auth.UserNotFoundError):
                    log.exception(
                        "Firebase delete_user failed for uid=%s", uid,
                    )
                    return json_error(
                        "Could not delete account from authentication "
                        "provider.",
                        status=502, code="AUTH_PROVIDER_ERROR",
                    )
            except ImportError:
                log.exception(
                    "Firebase delete_user failed for uid=%s", uid,
                )
                return json_error(
                    "Could not delete account from authentication provider.",
                    status=502, code="AUTH_PROVIDER_ERROR",
                )

    # 2. Delete the SQL mirror row. Cascade on the relationships
    #    in ``database_models.User`` cleans up favourites,
    #    history, progress, enrollments, etc.
    db.session.delete(user)
    db.session.commit()

    # 3. Best-effort Firestore profile cleanup. Failures here are
    #    logged but not surfaced — the user's identity is already
    #    gone from Firebase Auth, which is what matters.
    if uid:
        try:
            db_fs = firebase_client.firestore_client()
            if db_fs is not None:
                db_fs.collection("users").document(uid).delete()
        except Exception:  # noqa: BLE001
            log.exception("Firestore profile delete failed for uid=%s", uid)

    log.info("Account deleted: uid=%s email=%s", uid, user.email)
    return json_ok(None, message="Account deleted.", status=200)


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

    # 3. Email verification gate. We refuse to issue a JWT until the
    #    user has confirmed the address. Protected endpoints then trust
    #    that signed verified session instead of re-querying Firebase on
    #    every request.
    if not firebase_client.is_email_verified(uid):
        # Best-effort: also send a fresh verification link so the user
        # doesn't have to dig out the original email. We swallow the
        # error — they can always click "Resend" on the client.
        try:
            firebase_client.send_verification_email(email)
        except firebase_client.EmailVerificationError:
            log.warning("Could not resend verification email to %s", email)
        return json_error(
            "Verify your email before signing in. "
            "A fresh verification link has been sent.",
            status=403, code="EMAIL_NOT_VERIFIED",
        )

    verified_claims = {
        "email_verified": True,
        "firebase_uid": uid,
    }
    return json_ok({
        "user": user.to_dict(),
        "access_token": create_access_token(
            identity=str(user.id),
            additional_claims=verified_claims,
        ),
        "refresh_token": create_refresh_token(
            identity=str(user.id),
            additional_claims=verified_claims,
        ),
    })


@bp.post("/auth/send-verification")
def send_verification():
    """Resend the email-verification link.

    Body: ``{"email": "...", "password": "..."}``

    The caller proves control of the account by re-supplying the
    password. We don't issue a session here — just trigger Firebase's
    ``sendOobCode`` and return success.

    Always returns ``200 OK`` when the credentials are valid so the
    client can't probe for which addresses are registered (parity with
    the rest of the auth surface).
    """

    data = body()
    email = (data.get("email") or "").strip().casefold()
    password = data.get("password") or ""

    if not email or not password:
        return json_error(
            "Email and password are required.",
            code="MISSING_CREDENTIALS",
        )

    if not firebase_client.is_configured():
        hint = firebase_client.configuration_hint()
        return json_error(
            f"Authentication backend is not configured. {hint}",
            status=503, code="AUTH_BACKEND_UNAVAILABLE",
        )

    # Verify the password first so we don't let unauthenticated callers
    # spam emails at arbitrary addresses.
    try:
        uid = firebase_client.verify_password(email=email, password=password)
    except firebase_client.PasswordVerificationError as exc:
        # Collapse the outcome to "we sent (or tried to send) the
        # email" so the endpoint can't be used as a credential oracle.
        log.info("send-verification: password rejected for %s (%s)",
                 email, exc.code)
        return json_ok(None, message=(
            "If that account exists, a verification link has been "
            "sent to its inbox."
        ))

    if firebase_client.is_email_verified(uid):
        return json_ok(None, message=(
            "This email is already verified."
        ), code="ALREADY_VERIFIED")

    try:
        firebase_client.send_verification_email(email)
    except firebase_client.EmailVerificationError as exc:
        log.warning("send-verification failed for %s: %s", email, exc.message)
        return json_error(
            exc.message,
            status=429 if exc.code == "TOO_MANY_ATTEMPTS" else 502,
            code=exc.code,
        )

    return json_ok(None, message=(
        "Verification email sent. Check your inbox (and spam folder)."
    ))


@bp.post("/auth/refresh")
@jwt_required(refresh=True)
def refresh():
    identity = get_jwt_identity()
    claims = get_jwt()
    if claims.get("email_verified") is False:
        return json_error(
            "This session was created before email verification.",
            status=403,
            code="EMAIL_NOT_VERIFIED",
        )

    additional_claims = {"email_verified": True}
    firebase_uid = claims.get("firebase_uid")
    if firebase_uid:
        additional_claims["firebase_uid"] = firebase_uid

    return json_ok({
        "access_token": create_access_token(
            identity=str(identity),
            additional_claims=additional_claims,
        ),
    })


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
# Learning preferences / behavioral interactions
# ---------------------------------------------------------------------------

@bp.get("/preferences/options")
def preference_options():
    """Public options used by first-launch preference onboarding."""
    adapter = current_app.extensions["educompass_model"]
    filters = adapter.filter_lists
    # The catalogue can contain many fine-grained subjects. Return the most
    # useful values first while still exposing the backend-derived lists.
    return json_ok({
        "subjects": filters.get("subjects", []),
        "levels": filters.get("levels", []),
        "course_types": filters.get("course_types", []),
        "certificates": filters.get("certificates", []),
        "price_preferences": ["Any", "Free", "Paid"],
        "provider": "EduCompass",
        "organization": "EduCompass",
    })


@bp.get("/me/preferences")
@jwt_required()
@verified_user_required
def preferences_get():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    configured = (
        UserPreference.query.filter_by(user_id=user.id).first() is not None
    )
    return json_ok({
        "preferences": get_user_preferences(user.id),
        "configured": configured,
    })


@bp.put("/me/preferences")
@jwt_required()
@verified_user_required
def preferences_update():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    data = body()
    prefs = normalize_preferences(data.get("preferences", data))
    prefs = upsert_user_preferences(user.id, prefs, commit=True)
    # Mirror subject/skill choices into the legacy interests table so old
    # recommendation/profile code continues to see useful interests.
    interests = list(dict.fromkeys(prefs["subjects"] + prefs["skills"]))[:50]
    UserInterest.query.filter_by(user_id=user.id).delete()
    for interest in interests:
        db.session.add(UserInterest(user_id=user.id, interest=interest.casefold()))
    db.session.commit()
    return json_ok({"preferences": prefs}, message="Preferences saved.")


@bp.get("/interactions")
@jwt_required()
@verified_user_required
def interactions_list():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    limit = int_arg("limit", 100, max_value=500)
    return json_ok({"interactions": get_recent_interactions(user.id, limit=limit)})


@bp.post("/interactions")
@jwt_required()
@verified_user_required
def interactions_add():
    user = current_user()
    if user is None:
        return json_error("Account not found.", status=404, code="USER_NOT_FOUND")
    data = body()
    course_id = str(data.get("course_id") or "").strip()
    kind = str(data.get("interaction_type") or "").strip().casefold()
    if not course_id:
        return json_error("Field 'course_id' is required.", code="MISSING_COURSE")
    if kind not in INTERACTION_WEIGHTS:
        return json_error(
            "Unsupported interaction_type.",
            code="INVALID_INTERACTION",
        )
    adapter = current_app.extensions.get("educompass_model")
    if adapter is not None and adapter.get_course(course_id) is None:
        return json_error("Course not found.", status=404, code="COURSE_NOT_FOUND")
    record_interaction(user.id, course_id, kind, commit=True)
    return json_ok(
        {"course_id": course_id, "interaction_type": kind,
         "weight": INTERACTION_WEIGHTS[kind]},
        message="Interaction recorded.",
        status=201,
    )


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
    preferences = _preferences_from_args()
    return json_ok({"results": adapter.popular(limit=limit, preferences=preferences)})


@bp.get("/courses/top-rated")
def courses_top_rated():
    adapter = current_app.extensions["educompass_model"]
    limit = int_arg("limit", 12, max_value=50)
    preferences = _preferences_from_args()
    return json_ok({"results": adapter.top_rated(limit=limit, preferences=preferences)})


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
    limit = int_body(data, "top_n", 10, max_value=50)
    preferences = normalize_preferences(data.get("preferences", {}))
    if preferences_are_empty(preferences):
        items = adapter.recommend_query(query=query, limit=limit)
    else:
        from .hybrid_ranker import rank_courses
        items = rank_courses(
            adapter,
            preferences=preferences,
            query_text=query,
            limit=limit,
            mode="goal",
        )
    return json_ok({
        "query": query,
        "count": len(items),
        "preferences": preferences,
        "recommendations": items,
    })


@bp.post("/recommendations/preferences")
def recommendations_preferences():
    """Public cold-start recommendations from first-launch preferences."""
    adapter = current_app.extensions["educompass_model"]
    data = body()
    preferences = normalize_preferences(data.get("preferences", data))
    limit = int_body(data, "top_n", 10, max_value=50)
    items = adapter.recommend_preferences(preferences, limit=limit)
    return json_ok({
        "count": len(items),
        "preferences": preferences,
        "recommendations": items,
    })


@bp.post("/recommendations/personalized")
@jwt_required()
@verified_user_required
def recommendations_personalized():
    adapter = current_app.extensions["educompass_model"]
    user = current_user()
    if user is None:
        return json_error("Account not found.",
                          status=404, code="USER_NOT_FOUND")
    data = body()
    limit = int_body(data, "top_n", 10, max_value=50)
    incoming = normalize_preferences(data.get("preferences", {}))
    if not preferences_are_empty(incoming):
        preferences = upsert_user_preferences(user.id, incoming, commit=True)
    else:
        preferences = get_user_preferences(user.id)

    interests = [str(i.interest) for i in user.interests if getattr(i, "interest", None)]
    favorites_ids = [str(f.course_id) for f in user.favorites]
    history_ids = [str(h.course_id) for h in user.history if h.course_id]
    enrolled_ids = [str(e.course_id) for e in user.enrollments]
    interactions = get_recent_interactions(user.id, limit=300)
    items = adapter.recommend_personalized(
        interests=interests,
        favorites_ids=favorites_ids,
        history_ids=history_ids,
        interactions=interactions,
        preferences=preferences,
        enrolled_ids=enrolled_ids,
        limit=limit,
    )
    return json_ok({
        "count": len(items),
        "preferences": preferences,
        "recommendations": items,
    })


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
@verified_user_required
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
@verified_user_required
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
    record_interaction(user.id, course_id, "favorite", commit=False)
    db.session.commit()
    return json_ok(message="Saved.", status=201)


@bp.delete("/me/favorites/<course_id>")
@jwt_required()
@verified_user_required
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
@verified_user_required
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
@verified_user_required
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
    if course_id:
        signal = action if action in INTERACTION_WEIGHTS else "view"
        record_interaction(user.id, course_id, signal, commit=False)
    db.session.commit()
    return json_ok(message="Recorded.", status=201)


@bp.get("/me/progress")
@jwt_required()
@verified_user_required
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
@verified_user_required
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
    was_completed = bool(row.completed) if row is not None else False
    if row is None:
        row = CourseProgress(user_id=user.id, course_id=str(course_id),
                             progress=percent, completed=percent >= 100)
        db.session.add(row)
    else:
        row.progress = percent
        row.completed = percent >= 100
    if percent >= 100 and not was_completed:
        record_interaction(user.id, str(course_id), "complete", commit=False)
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
@verified_user_required
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
@verified_user_required
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
    created = row is None
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
    if created:
        record_interaction(user.id, course_id, "enroll", commit=False)
    db.session.commit()
    return json_ok(row.to_dict(), message="Enrolled.", status=201)


@bp.delete("/me/enrollments/<course_id>")
@jwt_required()
@verified_user_required
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
@verified_user_required
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
@verified_user_required
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
