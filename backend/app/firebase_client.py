"""Firebase Admin SDK + Firestore client for the EduCompass backend.

Firebase Auth is the source of truth for user identity. SQLAlchemy still
holds a thin mirror row (so existing favourites / progress / history
endpoints keep working with the same JWT identity), keyed by the
Firebase ``uid``.

Authentication is wired up via one of:

* ``GOOGLE_APPLICATION_CREDENTIALS`` — path to a service-account JSON file
* ``FIREBASE_SERVICE_ACCOUNT_JSON``  — inline JSON (handy for Render /
  Cloud Run / Docker secrets)

Password verification happens through the public Identity Toolkit REST
endpoint (``identitytoolkit.googleapis.com/v1/accounts:signInWithPassword``)
because the Admin SDK does not expose a password-verification method.
The web API key is read from ``FIREBASE_WEB_API_KEY``.

All helpers are no-ops (returning ``None`` / ``False``) when Firebase is
not configured — that lets the rest of the app still boot in
environments without credentials, useful for unit tests.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import requests

log = logging.getLogger(__name__)

# Lazy globals — we don't touch Firebase at import time so importing this
# module never raises if the SDK isn't installed yet.
_firebase_app = None
_auth_client = None
_firestore_client = None


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _service_account_info() -> dict[str, Any] | None:
    """Return parsed service-account credentials, or ``None`` if unset."""

    inline = os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON")
    if inline:
        try:
            return json.loads(inline)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                "FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON."
            ) from exc

    creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if creds_path and os.path.exists(creds_path):
        with open(creds_path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    return None


def is_configured() -> bool:
    """True when the backend can talk to Firebase."""

    return _service_account_info() is not None


def configuration_hint() -> str:
    """Human-readable hint about what's missing for Firebase auth.

    Returned alongside the ``AUTH_BACKEND_UNAVAILABLE`` 503 so the
    developer doesn't have to dig through logs to figure out which
    env var is unset (or points to a fake path).
    """

    parts: list[str] = []
    if _service_account_info() is None:
        if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            parts.append(
                "GOOGLE_APPLICATION_CREDENTIALS is set but the file "
                f"does not exist: {os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')!r}"
            )
        else:
            parts.append(
                "Set GOOGLE_APPLICATION_CREDENTIALS to a service-account "
                "JSON file path, or FIREBASE_SERVICE_ACCOUNT_JSON to the "
                "inline JSON contents."
            )
    if not os.environ.get("FIREBASE_WEB_API_KEY"):
        parts.append(
            "Set FIREBASE_WEB_API_KEY (Firebase Console → Project "
            "settings → General → Web API Key) — required for /auth/login."
        )
    return " ".join(parts) if parts else "Firebase is configured."


def _ensure_initialised() -> bool:
    """Initialise the Admin SDK on first use. Idempotent.

    Returns ``True`` when Firebase is configured and ready, ``False``
    otherwise (so callers can short-circuit cleanly during local dev).
    """

    global _firebase_app, _auth_client, _firestore_client
    if _firebase_app is not None:
        return True

    try:
        import firebase_admin
        from firebase_admin import auth as fb_auth
        from firebase_admin import firestore as fb_firestore
    except ImportError:
        log.warning(
            "firebase-admin is not installed — Firebase auth is disabled."
        )
        return False

    creds_info = _service_account_info()
    if creds_info is None:
        log.warning(
            "Firebase credentials missing — set GOOGLE_APPLICATION_CREDENTIALS "
            "or FIREBASE_SERVICE_ACCOUNT_JSON. Firebase auth is disabled."
        )
        return False

    try:
        from firebase_admin import credentials
        cred = credentials.Certificate(creds_info)
        _firebase_app = firebase_admin.initialize_app(cred)
    except ValueError:
        # Already initialised (e.g. Flask reloader spawned a second
        # process). Reuse the default app.
        _firebase_app = firebase_admin.get_app()

    _auth_client = fb_auth
    _firestore_client = fb_firestore.client()
    log.info("Firebase Admin SDK initialised for project %s.",
             creds_info.get("project_id"))
    return True


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

def auth_client():
    """Return the Firebase ``auth`` client, or ``None`` if unavailable."""

    if not _ensure_initialised():
        return None
    return _auth_client


def firestore_client():
    """Return the Firestore client, or ``None`` if unavailable."""

    if not _ensure_initialised():
        return None
    return _firestore_client


def create_auth_user(email: str, password: str, display_name: str) -> str:
    """Create a Firebase Auth user. Returns the ``uid``.

    Raises ``firebase_admin.auth.EmailAlreadyExistsError``,
    ``firebase_admin.auth.InvalidPasswordError``,
    ``firebase_admin.auth.InvalidEmailError`` on the usual validation
    failures — the routes layer maps these to HTTP error codes.
    """

    auth = auth_client()
    if auth is None:  # pragma: no cover — guarded by routes
        raise RuntimeError("Firebase auth is not configured.")
    user = auth.create_user(
        email=email,
        password=password,
        display_name=display_name,
        email_verified=False,
    )
    return user.uid


def get_auth_user_by_email(email: str):
    """Return the Firebase user record for ``email`` or ``None``."""

    auth = auth_client()
    if auth is None:
        return None
    try:
        return auth.get_user_by_email(email)
    except auth.UserNotFoundError:
        return None


def upsert_user_profile(uid: str, *, email: str,
                        full_name: str, extra: dict | None = None) -> None:
    """Create/update the Firestore profile document at ``users/{uid}``."""

    db = firestore_client()
    if db is None:
        return
    from firebase_admin import firestore as fb_firestore
    doc = {
        "uid": uid,
        "email": email,
        "full_name": full_name,
        "updated_at": firestore_ServerTimestamp(),
    }
    if extra:
        doc.update(extra)
    db.collection("users").document(uid).set(doc, merge=True)


def firestore_ServerTimestamp() -> Any:
    """Return a Firestore server-timestamp sentinel."""

    from firebase_admin import firestore as fb_firestore
    return fb_firestore.SERVER_TIMESTAMP


# ---------------------------------------------------------------------------
# Password verification (REST)
# ---------------------------------------------------------------------------

class PasswordVerificationError(Exception):
    """Raised when Firebase rejects the email/password pair."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code  # "INVALID_CREDENTIALS" / "TOO_MANY_ATTEMPTS" / "USER_DISABLED"
        self.message = message


def verify_password(email: str, password: str) -> str:
    """Verify ``email``/``password`` against Firebase Auth.

    Returns the ``uid`` on success. Raises
    :class:`PasswordVerificationError` on any failure so the routes
    layer can surface a clean 401.
    """

    api_key = os.environ.get("FIREBASE_WEB_API_KEY")
    if not api_key:
        raise PasswordVerificationError(
            "SERVER_MISCONFIGURED",
            "Server is missing FIREBASE_WEB_API_KEY.",
        )

    url = (
        "https://identitytoolkit.googleapis.com/v1/"
        f"accounts:signInWithPassword?key={api_key}"
    )
    payload = {"email": email, "password": password, "returnSecureToken": True}
    try:
        resp = requests.post(url, json=payload, timeout=10)
    except requests.RequestException as exc:
        raise PasswordVerificationError(
            "NETWORK_ERROR",
            f"Could not reach Firebase: {exc}",
        ) from exc

    data = resp.json() if resp.content else {}
    if resp.ok and "localId" in data:
        return data["localId"]

    # The error envelope: { "error": { "code": 400, "message": "...", "errors": [...] } }
    err = data.get("error", {}) or {}
    msg = (err.get("message") or "Authentication failed.").strip()

    # Firebase returns INVALID_PASSWORD / EMAIL_NOT_FOUND / USER_DISABLED
    # — collapse them to a single user-visible message so we don't leak
    # which half of the pair is wrong.
    if "INVALID_PASSWORD" in msg or "EMAIL_NOT_FOUND" in msg:
        raise PasswordVerificationError(
            "INVALID_CREDENTIALS", "Invalid email or password."
        )
    if "USER_DISABLED" in msg:
        raise PasswordVerificationError(
            "USER_DISABLED", "This account has been disabled."
        )
    if "TOO_MANY_ATTEMPTS" in msg:
        raise PasswordVerificationError(
            "TOO_MANY_ATTEMPTS",
            "Too many failed attempts. Try again later.",
        )
    raise PasswordVerificationError("AUTH_ERROR", msg)


__all__ = [
    "is_configured",
    "configuration_hint",
    "auth_client",
    "firestore_client",
    "create_auth_user",
    "get_auth_user_by_email",
    "upsert_user_profile",
    "verify_password",
    "PasswordVerificationError",
]
