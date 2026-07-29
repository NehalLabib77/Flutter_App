"""In-memory phone-OTP store used by the auth (login + register) flow.

Mirrors the shape of :mod:`backend.app.billing_service` (the bKash OTP path)
but is keyed to a single phone number and a single purpose (`"login"` or
`"register"`). It is intentionally simple: a dict protected by a lock, codes
that expire after ``ttl_seconds``, and a fixed-length numeric code.

The store logs the generated code to the server console so the dev-mode mock
can be exercised end-to-end without any external SMS provider. A real Twilio /
bdapps / Firebase integration can replace this module without touching the
REST surface.
"""

from __future__ import annotations

import logging
import re
import threading
import time
from dataclasses import dataclass
from typing import Literal


log = logging.getLogger(__name__)

AuthPurpose = Literal["login", "register"]

# E.164-ish — at least 8 digits, optional leading `+`. Mirrors the billing
# validator so the same phone field is accepted in both screens.
_PHONE_RE = re.compile(r"^\+?[0-9]{8,15}$")


def _normalise_phone(phone: str) -> str:
    cleaned = re.sub(r"\s+", "", (phone or "").strip())
    if not _PHONE_RE.match(cleaned):
        raise ValueError(
            "Enter a valid phone number (8–15 digits, optional leading +).")
    return cleaned


@dataclass
class OtpEntry:
    code: str
    reference: str
    purpose: str
    expires_at: float
    attempts: int = 0
    last_sent: float = 0.0


@dataclass
class RequestResult:
    reference: str
    hint: str = ""


@dataclass
class VerifyResult:
    success: bool
    reference: str = ""
    failure_reason: str = ""


class AuthOtpStore:
    """Thread-safe in-memory OTP store for the auth flow."""

    _RESEND_COOLDOWN_SECONDS = 30.0
    _MAX_ATTEMPTS = 5

    def __init__(self, ttl_seconds: int = 300) -> None:
        self._ttl = ttl_seconds
        self._lock = threading.Lock()
        self._pending: dict[tuple[str, str], OtpEntry] = {}

    # --- public API ---------------------------------------------------------

    def request(self, phone: str, purpose: AuthPurpose) -> RequestResult:
        phone = _normalise_phone(phone)
        if purpose not in ("login", "register"):
            raise ValueError("Unknown OTP purpose.")
        now = time.time()
        with self._lock:
            key = (phone, purpose)
            entry = self._pending.get(key)
            if entry and now - entry.last_sent < self._RESEND_COOLDOWN_SECONDS:
                wait = int(self._RESEND_COOLDOWN_SECONDS -
                           (now - entry.last_sent))
                return RequestResult(
                    reference=entry.reference,
                    hint=f"Wait {wait}s before requesting a new code.",
                )

            code = f"{int(now) % 1000000:06d}"
            reference = f"auth-{purpose}-{int(now * 1000)}"
            self._pending[key] = OtpEntry(
                code=code,
                reference=reference,
                purpose=purpose,
                expires_at=now + self._ttl,
                last_sent=now,
            )
        log.warning("[auth:otp] code for %s/%s: %s (reference=%s)",
                    purpose, phone, code, reference)
        print(f"[auth:otp] {purpose} code for {phone}: {code}")
        return RequestResult(
            reference=reference,
            hint="Dev only — code is printed in the server console.",
        )

    def verify(self, phone: str, code: str,
               purpose: AuthPurpose) -> VerifyResult:
        phone = _normalise_phone(phone)
        if purpose not in ("login", "register"):
            return VerifyResult(False, failure_reason="bad_purpose")
        clean_code = (code or "").strip()
        if not re.fullmatch(r"[0-9]{4,8}", clean_code):
            return VerifyResult(False, failure_reason="malformed_code")

        now = time.time()
        with self._lock:
            entry = self._pending.pop((phone, purpose), None)
            if entry is None:
                return VerifyResult(False, failure_reason="no_pending_otp")
            if now > entry.expires_at:
                return VerifyResult(False, failure_reason="expired")
            entry.attempts += 1
            if entry.attempts > self._MAX_ATTEMPTS:
                return VerifyResult(False, failure_reason="too_many_attempts")
            if entry.code != clean_code:
                # Re-insert so the user can retry without waiting for cooldown.
                self._pending[(phone, purpose)] = entry
                return VerifyResult(False, failure_reason="code_mismatch")
            return VerifyResult(True, reference=entry.reference)

    def peek_reference(self, phone: str, purpose: AuthPurpose) -> str:
        """Return the active reference for (phone, purpose) without consuming it.

        Used by /auth/login + /auth/register so the client only needs to
        remember the phone + code, not the opaque reference returned at
        request-time.
        """
        phone = _normalise_phone(phone)
        with self._lock:
            entry = self._pending.get((phone, purpose))
            return entry.reference if entry else ""


_STORE: AuthOtpStore | None = None


def get_auth_otp_store() -> AuthOtpStore:
    """Singleton accessor — built lazily so test config can override TTL."""
    global _STORE
    if _STORE is None:
        _STORE = AuthOtpStore()
    return _STORE


def reset_auth_otp_store() -> None:
    """Drop the singleton. Used by tests."""
    global _STORE
    _STORE = None


__all__ = [
    "AuthOtpStore",
    "AuthPurpose",
    "RequestResult",
    "VerifyResult",
    "get_auth_otp_store",
    "reset_auth_otp_store",
]
