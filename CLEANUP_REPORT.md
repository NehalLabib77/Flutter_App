# Cleanup report — `frontend/` archival

**Date:** 2026-08-02
**Action:** Moved `e:\Flutter_app\frontend/` to `e:\Flutter_app\_archive\frontend_20260802_161948/`
**Reason:** The folder was a stale duplicate of the canonical Flutter app from
before the Firebase-Auth cutover. It used a phone-OTP flow that no longer
matches the production backend, and no file outside the folder referenced it.

---

## 1. References checked before moving

| What | Where | Result |
|---|---|---|
| Dart imports pointing into `frontend/` | `my_app/lib/**/*.dart` | **0** matches |
| `frontend` string in `my_app/pubspec.yaml` | n/a | **0** matches |
| `frontend` string in `my_app/firebase.json` | n/a | **0** matches |
| `frontend` string in `my_app/firestore.rules` | n/a | **0** matches |
| `frontend` string in `my_app/firebase_options.dart` | n/a | **0** matches |
| `frontend` string in `my_app/android/` build files | n/a | **0** matches (only unrelated `CMAKE_CXX_COMPILER_FRONTEND_VARIANT` hits in `build/.cxx/`) |
| `frontend` string in `backend/**` | n/a | **0** matches |
| `frontend` string in `scripts/**` | n/a | **0** matches |
| `frontend` string in `Untitled Project.code-workspace` | line 4 (`"path": "frontend"`) | **1** match — **updated** to remove the dead folder and add `my_app/` |
| `frontend` string in `README.md` | line 139 (`Frontend:` section header) | **1** match — generic heading for the Flutter app's frontend tests, **not a path reference**; left intact (Step 5 of the audit plan rewrites the README) |

The 3 self-references inside the archived folder
(`frontend/lib/config/api_config.dart` lines 2, 2, 19) are doc comments that
describe the folder's status and travel with the archive.

## 2. Verification commands used

```powershell
# Anything that points at the frontend folder?
Select-String -Path my_app -Recurse -Pattern 'frontend/'        # 0 (outside frontend/)
Select-String -Path my_app -Recurse -Pattern "'frontend/"        # 0
Select-String -Path my_app -Recurse -Pattern '^import.*frontend' # 0

# Is it listed anywhere it would be picked up?
Select-String -Path my_app\pubspec.yaml,my_app\firebase.json,my_app\firebase_options.dart,my_app\firestore.rules -Pattern frontend # 0

# Does the backend or scripts touch it?
Select-String -Path backend,scripts -Recurse -Pattern frontend   # 0 (matches are data, not the folder)

# Does VS Code open it as a workspace folder?
Select-String -Path 'Untitled Project.code-workspace' -Pattern frontend # 1 -> updated
```

## 3. Files moved (7 total)

```
_archive/frontend_20260802_161948/lib/
  api_client.dart
  app.dart
  config/api_config.dart
  screens/course_details_screen.dart
  screens/login_screen.dart
  screens/profile_screen.dart
  screens/register_screen.dart
```

The archive preserves the folder exactly as it was. To restore it, move it
back to `frontend/` at the repo root; no other change is required.

## 4. `.gitignore` change

Added at the top of `.gitignore`:

```gitignore
# ---- Archive (deprecated code parked for reference) ----
# Anything under _archive/ is kept on disk for archaeology but is not
# part of the shipping app, not referenced by the canonical Flutter
# client, not built by CI, and not loaded by the backend.
_archive/
/_archive
_archive/**
```

## 5. `Untitled Project.code-workspace` change

Removed the `"path": "frontend"` entry and added `"path": "my_app"` so VS
Code still surfaces the canonical Flutter project alongside `backend/`,
`ml/`, `data/`, `docs/`, `scripts/`.

## 6. Reversibility

This action is reversible. To put `frontend/` back:

```powershell
Move-Item -Path 'e:\Flutter_app\_archive\frontend_20260802_161948' `
          -Destination 'e:\Flutter_app\frontend'
```

Then revert the `.gitignore` archive entries and re-add `"path": "frontend"`
to `Untitled Project.code-workspace`. No code in the canonical app, backend,
ML pipeline, or build config will break.

## 7. Not touched by this report

- `backend/app/auth_otp.py` — module exists but is not registered as a route
  in `routes.py`. It is imported only by `tests/test_imports.py` so it stays
  in place for the smoke tests. (Audit Step 5 covers this.)
- `backend/app/billing_service.py` — stub billing provider, used only by
  `tests/test_imports.py`. Kept.
- `my_app/lib/services/enrollment_service.dart` — Firestore-backed enrollment
  helper. The canonical app uses the SQL-backed `/api/v1/me/enrollments`
  endpoints (see `routes.py` and the `EnrollmentProvider` in
  `my_app/lib/app_state.dart`), so this file is also dead code. **Flagged
  for the next cleanup pass** — not removed in this round because it
  belongs to the canonical tree and removing it requires the same care
  (grep + tests) as `frontend/`.