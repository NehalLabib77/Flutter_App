# EduCompass verified-session fix

## Problem

An already logged-in learner could receive `EMAIL_NOT_VERIFIED` while loading
personalised recommendations or saving favourites. The backend was querying
Firebase Admin again on every protected request. A temporary Firebase failure or
stale verification response therefore blocked a valid EduCompass JWT session.

## Flutter changes

- `lib/screens/auth_wrapper.dart`
  - A valid persisted EduCompass JWT now takes precedence over a stale local
    Firebase `emailVerified` value.
  - The verification screen remains active for newly registered users who do
    not yet have an EduCompass JWT.
- `lib/screens/recommendations_screen.dart`
  - Personalised recommendations are requested only for signed-in users.
  - Guest goal search remains available.
- `lib/app_state.dart`
  - Added reliable favourites error state and clearer authenticated-session
    error handling.
- `lib/screens/favorites_screen.dart`
  - Added retry/error UI and clean API error messages.
- `lib/screens/course_details_screen.dart`
  - Favourite failures show the user-facing message instead of the raw
    exception object.
- `lib/api_client.dart`
  - Older backends returning `EMAIL_NOT_VERIFIED` to an authenticated client
    now produce a session message rather than asking the learner to verify the
    same email again.

## Backend changes

- Login still checks Firebase `email_verified` before issuing any JWT.
- New access and refresh tokens include `email_verified: true`.
- Protected routes trust the signed EduCompass JWT instead of re-querying
  Firebase on every favourites, recommendation, progress, enrollment, or
  payment request.
- Legacy valid tokens without the new claim remain accepted.
- A token explicitly containing `email_verified: false` remains rejected.
- Added `tests/test_verified_session.py` regression coverage.

## Deployment

The backend must be redeployed for the functional fix. Replacing only `lib/`
changes the message but cannot stop an older server from rejecting the request.
After deployment, existing valid JWTs remain compatible. A sign-out/sign-in is
recommended only if a device still holds an invalid or expired session.
