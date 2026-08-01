# Plan: Add backend "drop enrollment" endpoint and wire it through Flutter

## Goal

Let a signed-in user **unenroll** (drop) a course from inside the app
without losing local state in unrelated screens. Today:

- `lib/services/enrollment_service.dart` only *writes* to Firestore
  (`saveEnrollment`). There is no `deleteEnrollment`.
- `lib/app_state.dart::EnrollmentProvider` only *writes* to the
  local SharedPreferences-backed set and *merges* Firestore IDs on
  login.
- `lib/screens/my_courses_screen.dart` shows the list but has no
  affordance to remove an entry.
- `backend/app/routes.py` has no enrollment endpoint at all
  (favourites, progress, history exist — but enrollments are
  Firestore-only).

So we will add a backend endpoint, a Flutter wrapper, and a UI
control to drop an enrollment.

## Design choices

- **Mirror the existing favourites endpoints.** `/me/favorites`
  already exposes the same shape of CRUD (`GET list`, `POST add`,
  `DELETE remove`). Adding `/me/enrollments/*` next to it keeps the
  API surface uniform and the JWT plumbing identical.
- **Two sources of truth — keep them in sync.** Dropping locally is
  not enough: on the user's *next* device the Firestore doc would
  resurrect the enrollment. The screen must:
  1. call `DELETE /api/v1/me/enrollments/{course_id}`, and
  2. call `EnrollmentService().deleteEnrollment(courseId)` so the
     `users/{uid}/enrollments/{courseId}` doc is removed too.
- **Local + remote merge is already wired.** `EnrollmentProvider`
  listens to `EnrollmentService.myEnrolledCourseIds()` and merges new
  ids. If we drop the Firestore doc, the stream will emit the new
  (smaller) list and the merge logic will *also* remove the id from
  the local set — so explicit `provider.unenroll(id)` after the
  Firestore delete is technically redundant, but we still call it
  so the screen never flashes "Enrolled" between the two awaits.
- **Gate behind login.** The endpoint requires `@jwt_required()` and
  the UI calls `requireLogin(...)` just like the existing
  `Enroll` button — keeps the UX consistent.

## Files touched

### Backend

1. `backend/app/database_models.py`
   - Add a new `Enrollment` SQLAlchemy model mirroring the Firestore
     schema:
     ```python
     class Enrollment(db.Model):
         __tablename__ = "enrollments"
         id          = Column(Integer, primary_key=True)
         user_id     = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                              nullable=False, index=True)
         course_id   = Column(String(64), nullable=False, index=True)
         payment_method    = Column(String(32), nullable=False, default="")
         transaction_id    = Column(String(64), nullable=False, default="")
         payment_status    = Column(String(32), nullable=False, default="completed")
         enrolled_at = Column(DateTime, nullable=False, default=_utcnow)

         __table_args__ = (
             UniqueConstraint("user_id", "course_id", name="uq_user_enrollment"),
         )
     ```
   - Add `enrollments = relationship("Enrollment", backref="user",
     cascade="all, delete-orphan")` on `User`.
   - Add `"Enrollment"` to `__all__`.

2. `backend/app/routes.py`
   - Import `Enrollment` from `database_models`.
   - Add three endpoints (same envelope as the existing
     `/me/favorites/*` trio):
     - `GET /me/enrollments` → list the signed-in user's enrollments
       (JSON list of `{course_id, payment_method, transaction_id,
       payment_status, enrolled_at}`).
     - `POST /me/enrollments` → upsert one row. Body:
       `{course_id, payment_method, transaction_id, payment_status?}`.
       Idempotent (`UniqueConstraint`).
     - `DELETE /me/enrollments/<course_id>` → delete the row, return
       `json_ok(message="Removed.")`.
   - All three use `@jwt_required()` + `current_user()` and reuse
     the existing `json_ok` / `json_error` helpers.

3. `backend/app/migrations.py`
   - Confirm `apply_lightweight_migrations(db)` is a no-op for a new
     table; it only patches existing schemas. If it isn't already,
     add a tiny migration block that does
     `CREATE TABLE IF NOT EXISTS enrollments (...)` so an old SQLite
     file gets the new table without a full reset.

4. `backend/tests/test_imports.py` (and `test_api.py` if applicable)
   - Add a smoke test that boots `create_app(skip_model_load=True)`
     in a SQLite-in-memory context and issues a
     `DELETE /api/v1/me/enrollments/<id>` round-trip (register →
     enroll → drop). Confirms 204/200 envelope and the row vanishes.

### Flutter

5. `lib/api_client.dart`
   - Add three methods to `ApiClient`:
     ```dart
     Future<List<String>> enrollments() async { ... }            // returns ids
     Future<void> addEnrollment({
       required String courseId,
       required String paymentMethod,
       required String transactionId,
       String paymentStatus = 'completed',
     });
     Future<void> removeEnrollment(String courseId);
     ```
   - `_decode` already returns `Map<String, dynamic>`, so the list
     call should unwrap `data['enrollments']` and project `course_id`
     the same way `favorites()` does.

6. `lib/services/enrollment_service.dart`
   - Add `Future<void> deleteEnrollment(String courseId)` that calls
     `users/{uid}/enrollments/{courseId}.delete()`. Same lazy-resolve
     pattern as `saveEnrollment` (so it still works before
     `Firebase.initializeApp()` in the constructor).

7. `lib/app_state.dart`
   - Add `Future<void> drop(String courseId)` on
     `EnrollmentProvider` that:
     1. Calls `EnrollmentService().deleteEnrollment(courseId)`
        (Firestore). Non-fatal on failure (logged in catch).
     2. Calls `_api.removeEnrollment(courseId)` (Flask).
        Non-fatal on failure (logged in catch).
     3. Calls existing `unenroll(courseId)` so the local prefs flag
        and `notifyListeners()` happen exactly once at the end.
   - Keep `enroll()` mostly unchanged — but also push to Flask so
     the SQL row stays in sync. (Today it only writes to Firestore
     and prefs; adding `await _api.addEnrollment(...)` makes the
     `GET /me/enrollments` endpoint useful on a fresh install.)

8. `lib/screens/my_courses_screen.dart`
   - Wrap each `_CourseTile` with `Dismissible` (or a long-press
     action sheet) so a swipe-right confirms removal.
   - On confirm: `await provider.drop(id)`, then
     `ScaffoldMessenger.showSnackBar('Removed from My Courses')`.
   - Gate with `requireLogin(...)` only if the user isn't already
     signed in — the screen is already login-only via the bottom
     nav, so a quick `context.read<AuthProvider>().isLoggedIn` check
     is enough.

9. `lib/screens/course_details_screen.dart`
   - For consistency, also wire an "Unenroll" action on the
     details screen (only visible when `isEnrolled`). Same flow as
     the list — `provider.drop(c.id)` then a SnackBar.

## Edge cases handled

- **Firestore not configured.** `EnrollmentService.deleteEnrollment`
  throws a `FirebaseException(..., code: 'no-app')` — we catch it in
  `EnrollmentProvider.drop` and still proceed to the Flask call so
  the SQL row is removed even if the client never initialised
  Firebase (e.g. someone running the build against a stub backend).
- **Network down.** Both Firestore and Flask calls are wrapped in
  try/catch; the user still sees the course disappear locally and
  gets a "Could not sync removal — try again later" snack on
  failure so they know the next device may still show it.
- **Re-enrolling.** The unique constraint on
  `(user_id, course_id)` makes the POST idempotent, and Firestore's
  `set()` overwrites — both paths converge.
- **Logout race.** `_EnrollmentRemoteSync` already cancels the
  remote subscription on logout. `drop()` doesn't touch that
  subscription, so it's safe to call from a screen that's about to
  be unmounted.

## Verification

1. `cd backend && python -m pytest -q` — new and existing tests pass.
2. Run the app: `cd my_app && flutter run`.
3. Manual flow:
   - Sign in → enroll in a free course via the course details
     screen → verify it appears in "My Courses".
   - Swipe it out (or use the details-screen action) → verify the
     row disappears and the bottom-nav badge updates.
   - Restart the app cold → verify the course does *not* reappear
     (proves the Firestore delete landed).
   - Sign in on a second device with the same account → confirm
     the course is gone there too (proves the SQL delete landed).

## Out of scope (explicitly)

- No new payment methods, no real bKash/SSLCommerz wiring.
- No change to the existing `EnrollmentProvider.refreshFromRemote`
  merge logic.
- No Firestore rules change — `users/{uid}/enrollments/{courseId}`
  is already covered by the existing per-user read/write rule in
  `firestore.rules` (the doc is inside `users/{uid}/...`).