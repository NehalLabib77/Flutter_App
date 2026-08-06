# Backend verified-session fix

The backend still verifies the Firebase email during `/api/v1/auth/login`.
After successful login, the signed EduCompass JWT is authoritative for protected
features. This prevents intermittent `EMAIL_NOT_VERIFIED` responses caused by
per-request Firebase Admin rechecks.

Modified files:

- `backend/app/routes.py`
- `backend/tests/test_verified_session.py`
- `backend/README.md`

New tokens carry `email_verified: true`; legacy valid tokens remain compatible.
