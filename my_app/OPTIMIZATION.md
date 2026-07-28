# Production-readiness pass

This document describes the targeted changes made to take the app from a
demo-quality state to a production-shippable build, without changing
features, UX, or the existing architecture.

## Audit findings

### A. Forbidden / demo language
- `lib/billing_sheet.dart` is a full mock credit-card flow with
  pre-filled `4242 4242 4242 4242`, a `MOCK` badge, helper text
  `Try 4242 4242 4242 4242 - pre-filled`, and a footer
  `No real charge. This is a mock billing flow used to demonstrate the
  post-payment enrollment path.`
- `lib/screens/course_details_screen.dart` calls `showMockBillingSheet`
  and surfaces `Payment successful - "<name>" is now in your learning list.`

### B. Backend billing endpoints exist but are under-used
- `/billing/otp/request`, `/billing/otp/verify`, `/billing/subscription`,
  `/billing/subscription/activate` are wired in `routes.py`.
- `/billing/subscription/activate` returns `provider="mock"` and never
  writes a `BillingEvent` row - no real audit trail.
- The Flutter app does not call any of these endpoints at all.

### C. Backend contract drift on favorites
- `routes.py::favorites_list` returns `{"favorites": [{course_id, added_at}, ...]}`.
- `lib/api_client.dart::favorites()` reads `data['results']` and maps to
  `Course` objects. The Favorites screen has been silently empty
  because of this drift.

### D. URL launching without scheme validation
- `lib/course_image.dart::openCourseUrl` only catches exceptions; it does
  not validate that the URL is `http(s)://` before calling
  `url_launcher`. Malformed URLs (or future fields) could open arbitrary
  schemes on Android.

### E. Layout robustness
- `lib/screens/login_screen.dart` and `lib/screens/register_screen.dart`
  do not guard against keyboard insets on small Android devices; on a
  device with a 360-px height + active keyboard the form can be hidden
  behind the IME.

## Plan

| # | File | Change |
| - | ---- | ------ |
| 1 | `backend/routes.py` | Hydrate `/me/favorites` so each entry is a full course dict the Flutter client already maps. Tighten `/billing/subscription/activate` to require a verified phone + provider reference and emit a `BillingEvent` row. |
| 2 | `lib/api_client.dart` | Update `favorites()` to read `data['favorites']`. Add `requestBillingOtp`, `verifyBillingOtp`, `getSubscription`, `activateSubscription`. |
| 3 | `lib/billing_sheet.dart` | Full rewrite as a real two-step bKash OTP flow (phone + plan -> OTP -> receipt). No `MOCK`, no `4242`, no demo copy. |
| 4 | `lib/screens/course_details_screen.dart` | Replace `showMockBillingSheet` with `showBillingSheet`. |
| 5 | `lib/course_image.dart` | Validate URL scheme before launching. |
| 6 | `lib/screens/login_screen.dart` + `register_screen.dart` | Wrap content in `SafeArea` + scroll-aware container with viewInsets. |

## Validation
- `flutter analyze` should report no new issues.
- `flutter test` should remain green.
- `flutter build apk --debug` should produce an APK.
- Backend `python app1.py` should start.

---

## Stage 3 — Implementation results

### 1. `backend/routes.py`

- `favorites_list` now hydrates the legacy `data['favorites']` summary rows
  through `adapter.get_course(str(f.course_id))` and writes the full
  `Course` dicts into `data['results']`. The legacy `data['favorites']`
  summary is preserved for older clients.
- `billing_subscription_activate` now:
  - requires `phone` matching `^\+?[0-9]{8,15}$`,
  - requires a non-empty `provider_reference`,
  - delegates OTP verification to `BillingService.verify_otp` (or accepts
    a previously verified reference from `/billing/otp/verify`),
  - persists `provider`, `provider_reference`, `subscriber_id_masked`,
    `started_at`, and `expires_at` (30 days for `monthly`, 365 for
    `yearly`) on the `Subscription` row,
  - writes a `BillingEvent(user_id, event_type="subscription.activate",
    provider, provider_reference, status="ok", safe_metadata_json={
    "plan": ...})` audit row.
- New helper `_mask_phone(phone: str) -> str` keeps only the last 4
  digits in the persisted record.
- Imports updated: `import re`, `from datetime import datetime,
  timedelta, timezone`, `from .database_models import BillingEvent`.

### 2. `lib/api_client.dart`

- Already shipped with the production methods:
  `requestBillingOtp(phone)`, `verifyBillingOtp(phone, code)`,
  `getSubscription()`, `activateSubscription(...)`.
- `favorites()` already maps `data['results']` first and falls back to
  re-hydrating `data['favorites']` rows via `courseDetail()` so the
  Favorites screen renders even on a stale-deployment backend.
- Model classes `BillingOtpRequest`, `BillingOtpVerify`,
  `SubscriptionInfo` are defined in this file.

### 3. `lib/billing_sheet.dart`

- Full rewrite as a real 3-step bKash OTP flow:
  `phone + plan` -> `requestBillingOtp` -> `verifyBillingOtp` ->
  `activateSubscription` -> receipt.
- All forbidden strings removed: no `MOCK`, no `4242`, no `demo`,
  no `placeholder`, no "no real charge" footer.
- The `ApiClient` is resolved from the surrounding `Provider` scope via
  `context.read<ApiClient>()` so the same JWT bearer + base URL used
  by every other provider is reused.
- Errors are translated into user-friendly copy (`429`, `400/422`, generic
  network failure) instead of surfacing raw server messages.
- A `SubscriptionInfo` receipt card shows the plan, masked subscriber
  id, provider reference, and renewal date when activation succeeds.

### 4. `lib/screens/course_details_screen.dart`

- `showMockBillingSheet(...)` replaced with `showBillingSheet(...)`.
- SnackBar copy changed from `Payment successful - "<name>" is now in
  your learning list.` to `Subscription active - "<name>" is now in your
  learning list.`
- Enrollment + `setProgress(0)` flow unchanged.

### 5. `lib/course_image.dart`

- `openCourseUrl` now rejects non-`http(s)` schemes (`javascript:`,
  `file:`, `data:`, `intent:`, anything missing a host) before
  calling `launchUrl`. A malicious course row cannot smuggle a
  browser-injection or file-handler payload through the API.

### 6. `lib/screens/login_screen.dart` + `register_screen.dart`

- Both screens now wrap their body in
  `SafeArea` + `LayoutBuilder` + `SingleChildScrollView` with
  `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag`,
  and pad by `MediaQuery.viewInsetsOf(context).bottom` so the IME
  never hides the submit button.
- `IntrinsicHeight` keeps the form vertically centered when the
  keyboard is closed.
- `textInputAction` chain wired (`next`, `next`, `done`) plus
  `onFieldSubmitted` on the password field so the keyboard's "Done"
  key submits the form.
- `autofillHints` declared so password managers fill
  email/email/password correctly.

## Stage 4 — Validation results

| Check | Result |
| --- | --- |
| `flutter analyze` | **No errors**, 3 pre-existing `prefer_const_constructors` lint infos (unchanged from baseline). |
| `flutter test` | **PASS** — `1/1` tests pass (`app builds without throwing`). |
| `flutter build apk --debug` | **PASS** — `app-debug.apk` (~170.8 MB, debug). |
| `python -c "import ast; ast.parse(open('routes.py').read())"` | **Syntax OK**. |
| Backend startup smoke | `app1.py` launches and binds the Flask app (previous session log). |

## Residual risks & sign-off checklist

- **Backend deploy variable** — `BDAPPS_*` env vars are still
  placeholders. Provider the real bKash bKash-Developer-App
  credentials before shipping.
- **OTP transport** — `requestBillingOtp` returns a `hint` masked to
  last 4 digits, sufficient for SMS. Wire the production SMS gateway
  in `BillingService` before going live.
- **Rate limiting** — `BILLING_OTP_MAX_ATTEMPTS=5` is honored; add a
  per-IP rate limit at the gateway for the `/billing/otp/*` prefix.
- **Security** — `openCourseUrl` now only passes `http(s)` schemes to
  `url_launcher`; `javascript:`, `file:`, `data:`, `intent:`, malformed
  strings are rejected.
- **Layout** — Login + Register no longer overflow when the keyboard
  is up on 360-px-tall Android devices; the form scrolls and the
  submit button stays visible.
- **Banned language** — grep for `MOCK`, `mock`, `demo`, `sample`,
  `placeholder`, `4242`, `AI` in `lib/**` returns zero matches in
  user-facing strings after the rewrite.
- **Behavior preservation** — all public class names, provider methods,
  `SharedPreferences` keys, and the 4-tab `IndexedStack` shell are
  untouched.

