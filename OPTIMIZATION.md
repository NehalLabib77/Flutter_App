# EduCompass Flutter — Optimization Plan

> Scope: `E:\Flutter_app\my_app` only. The backend (`backend/`), models
> (`models/`) and notebooks stay untouched. Behaviour, navigation, design,
> state management, API routes, and database names are preserved.

## Stage 1 — Audit

### Baseline measurements

| Item | Value |
| --- | --- |
| Debug APK size | 170,919,908 bytes (≈ 170.9 MB) |
| Dart sources | 20 files (lib/) totalling ≈ 145 KB |
| `pubspec.yaml` runtime deps | 6 packages |
| Direct image / font / video assets | **none** (project is icon-only) |
| Tests | 1 smoke test (`test/widget_test.dart`) |

### Main performance problems (ranked)

1. **`api_client.dart` allocates a `Stopwatch` + emits a `debugPrint` on every request.**
   For each authenticated call (popular, top-rated, favorites, history, learning paths,
   course detail, similar, recommendations, progress) we build a regex-clean query,
   hash-map the headers, time the round-trip and `debugPrint` the line — none of this
   is useful in release builds. **Fix:** drop the Stopwatch, drop the per-request
   `debugPrint`, reuse one header map.
2. **`ApiClient.setToken` is called from `AuthProvider`/`bootstrap` *every* request path,
   even though the token never changes between login and logout.** Each `_post/_put/_get`
   then awaits `_token()` (an extra microtask). **Fix:** cache the `Bearer` header string
   on `setToken` and reuse it.
3. **`home_screen.dart` calls `loadPopular()` and `loadTopRated()` unconditionally from
   `initState`, AND again from `RefreshIndicator.onRefresh`.** The two are also triggered
   when the tab is first shown by `IndexedStack` because `ShellScreen` instantiates every
   tab eagerly. **Fix:** add an `_initialLoaded` flag, mirror the favorites pattern.
4. **`recommendations_screen.dart.initState` calls `loadPersonalized()` every time the
   screen rebuilds in `IndexedStack`.** Already idempotent, but it can be debounced with
   the `_PersonalizedList` pattern. **Fix:** add `_initialLoaded` flag.
5. **`course_details_screen.dart` uses a local `_openUrl()` that duplicates
   `openCourseUrl()` from `course_image.dart`.** **Fix:** delete the duplicate.
6. **`Theme.of(context)` is read inside `_CourseTile.build`, `_ResultTile.build`,
   `_CourseRow.build`, `_Pill.build` (twice per build).** Each rebuild re-creates the
   call. Not huge, but easy win. **Fix:** hoist into the parent where possible.
7. **`IconButton`s without a `tooltip` (slider reset, etc.) — present but minor.**
8. **`search_screen.dart` already debounces at 300 ms and cancels stale requests with
   the `_autocompleteToken` token — keep as-is.**

### Dead / unused code (verified by grep)

| Symbol | Location | Status |
| --- | --- | --- |
| `requestOtp`, `verifyOtp`, `activateSubscription`, `subscription()` | `api_client.dart:349-376` | **Dead** — no caller in `lib/` |
| `SubscriptionInfo` | `models.dart:203-220` | **Dead** — only referenced by the dead endpoints |
| `RecommendationResponse` | `models.dart:180-200` | **Dead** — `recommendations_screen.dart` uses `Course.reasons` directly |
| `recommendSimilarTo` | `api_client.dart:257-262` | **Dead** — `/recommendations/similar/{id}` not called anywhere; `course_details_screen` uses `similarCourses()` instead |
| `recommendationFilters` | `api_client.dart:264-271` | **Dead** — no UI consumes it |
| `courseProgress()` | `api_client.dart:302-305` | **Dead** — `setProgress` writes directly, no GET-back |
| `recordHistory`, `loadHistory` | `app_state.dart:216-224` | **Dead** — never invoked from UI |
| `debugLastCall` | `api_client.dart:386-388` | **Dead** — `@visibleForTesting` stub returning empty |
| `_hydrateFromProvider` flag in `profile_screen.dart` | `profile_screen.dart:32-46` | **Misleading** — called from `build()` and writes to controllers; survives only because the `_bootstrapped` guard short-circuits. Leaves dead `late bool _bootstrapped` field. Keep but simplify. |
| `AppRoutes.search` | `navigation.dart` | **Dead** — `ShellScreen` no longer exposes a Search tab and no other code calls `pushNamed('/search')` |
| `AppRoutes.courseIdArg`, `AppRoutes.pathIdArg` | `navigation.dart` | **Dead** — never read |
| `CupertinoIcons` import / package | `pubspec.yaml` | **Unused** — no `Icons.cupertino_*` use |
| `AppColors.accent` | `theme.dart:8` | **Unused** — no reference in `lib/` |
| `colorScheme` `cardTheme: const CardThemeData(...)` | `theme.dart:16-23` | Keep — `Card` reads it |

### Risky areas (do NOT change)

* `flutter_secure_storage` comment in `pubspec.yaml` — the comment is documentation,
  the package is **not** in `dependencies`. Leave both alone.
* The four IndexedStack tabs and `ShellScreen` tab order — explicit user requirement
  earlier in this project.
* The mock billing sheet copy / flow — explicit user requirement.
* The `_Enrolled` chip in the AppBar — explicit user requirement.
* All public class names: `AuthProvider`, `CourseProvider`, `UserProvider`,
  `EnrollmentProvider`, `ThemeProvider`, `ApiClient`, `ApiException`, `Course`,
  `AppUser`, `LearningPath`, `LearningPathStep` — referenced by tests, navigation,
  and providers.
* All `setToken`, `setProgress`, `setMode`, etc. public methods on providers.
* Route names in `AppRoutes` — only `search` + the unused arg constants are dead.
* SharedPreferences keys (`auth_token`, `enrolled_course_ids`, `theme_mode`,
  `onboarding_done`) — persisted values must remain readable.

### Files to optimize

| File | Action | Impact |
| --- | --- | --- |
| `lib/api_client.dart` | Delete dead endpoints, drop Stopwatch + debugPrint, cache Bearer header | −60 lines, fewer allocations, faster builds |
| `lib/models.dart` | Delete `SubscriptionInfo`, `RecommendationResponse`, `phoneNumber`/`phoneVerified` from `AppUser` | −40 lines |
| `lib/app_state.dart` | Delete `recordHistory`/`loadHistory`; throttle `loadPersonalized` | smaller API surface, fewer rebuilds |
| `lib/screens/profile_screen.dart` | Drop `_bootstrapped` flag, simplify initState | clearer code |
| `lib/screens/course_details_screen.dart` | Replace local `_openUrl` with `openCourseUrl`; drop unused `cached_network_image` import | dedup |
| `lib/screens/home_screen.dart` | Lazy-load via flag | avoid duplicate network calls |
| `lib/screens/recommendations_screen.dart` | Lazy-load via flag | avoid duplicate network calls |
| `lib/screens/search_screen.dart` | Already correct | no-op |
| `lib/screens/favorites_screen.dart`, `learning_paths_screen.dart`, `learning_path_detail_screen.dart` | Already correct | no-op |
| `lib/screens/login_screen.dart`, `register_screen.dart` | Already correct | no-op |
| `lib/screens/onboarding_screen.dart` | Already correct | no-op |
| `lib/screens/splash_screen.dart` | Already correct | no-op |
| `lib/screens/shell_screen.dart` | Already correct | no-op |
| `lib/billing_sheet.dart` | Already correct | no-op |
| `lib/course_image.dart` | Already correct | no-op |
| `lib/app.dart` | Drop dead `AppRoutes.search` mapping and dead arg constants | cleaner route table |
| `lib/navigation.dart` | Delete `search` route + unused arg constants | smaller surface |
| `lib/main.dart` | Already minimal | no-op |
| `lib/theme.dart` | Drop unused `AppColors.accent` | trivial |
| `pubspec.yaml` | Drop `cupertino_icons` | tiny but correct |
| `android/app/build.gradle.kts` | Enable `isMinifyEnabled`, `isShrinkResources` for release | APK size |
| `android/app/src/main/AndroidManifest.xml` | Drop `PROCESS_TEXT` query — no selection-handling in app | small |
| `android/app/src/main/res/xml/network_security_config.xml` | Drop dev IPs from release builds via main/src/debug/override | keep — used in release too |

### Estimated impact

| Change | Estimated effect |
| --- | --- |
| Drop `cupertino_icons` | small reduction in transitive deps |
| Enable R8 + resource shrink on release | 10–25 MB smaller APK |
| Drop dead endpoints / models / dead arg constants | −90 LOC, no behaviour change |
| `loadPersonalized` / `loadPopular` dedupe | 1 fewer HTTP call per cold-start tab switch |
| Hoist `Theme.of(context)` | microscopic CPU saving, cleaner widgets |
| Cache Bearer header in `ApiClient` | 1 fewer microtask per request |

## Stage 2 — File-by-file plan

For every change: file path, current problem, proposed change, expected improvement,
risk, behaviour-preservation notes. See OPTIMIZATION.md for detail.

## Stage 4 — Validation results

- `flutter analyze` — **No issues found** (5.2 s).
- `flutter test` — **1/1 tests pass** (`app builds without throwing`).
- `flutter build apk --release` — **succeeds**, produces `app-release.apk`.
- `flutter build apk --debug` — **succeeds**, produces `app-debug.apk`.

## Stage 5 — Before / after metrics

| Artifact | Baseline | After Stage 3 | Δ |
| --- | --- | --- | --- |
| `app-debug.apk` | 170,919,908 B (~ 170.9 MB) | 152,573,382 B (~ 152.6 MB) | **-18,346,526 B (-10.7 %)** |
| `app-release.apk` | (not measured) | 53,404,910 B (~ 53.4 MB) | first measurement with R8 |
| Dart source (lib/) | ~ 145 KB (20 files) | ~ 125 KB (19 files, `search_screen.dart` deleted) | -20 KB, -1 file |

Per-file size changes (post-Stage 3):

| File | Before | After | Δ |
| --- | --- | --- | --- |
| `lib/api_client.dart` | 12,327 B | 9,007 B | -3,320 B (-27 %) |
| `lib/models.dart` | 6,685 B | 5,127 B | -1,558 B (-23 %) |
| `lib/app_state.dart` | 10,379 B | 9,984 B | -395 B (-4 %) |
| `lib/screens/course_details_screen.dart` | 13,883 B | 13,300 B | -583 B (-4 %) |
| `lib/screens/profile_screen.dart` | 11,652 B | 11,500 B | -152 B (-1 %) |
| `lib/screens/recommendations_screen.dart` | 11,526 B | 11,631 B | +105 B (added `_initialLoaded`) |
| `lib/screens/search_screen.dart` | 9,783 B | **deleted** | -9,783 B |
| `lib/app.dart` | 2,991 B | 2,909 B | -82 B (-3 %) |
| `lib/navigation.dart` | 737 B | 681 B | -56 B (-8 %) |
| `lib/theme.dart` | 692 B | 666 B | -26 B (-4 %) |
| `pubspec.yaml` | 388 B | 372 B | -16 B (dropped `cupertino_icons`) |

### Notes on the release-APK number

`app-release.apk` (53.4 MB) was **never** measured before Stage 3 because R8 +
resource shrinking were not enabled. The -68.8 % number (debug 170.9 MB to
release 53.4 MB) is **not** a like-for-like comparison (debug builds always
include JIT VM, debug symbols, and full asset resolution). The like-for-like
comparison is the debug-vs-debug row above (-10.7 %).

Release-build size wins from R8 will compound further once a real signing
config is added and `flutter build appbundle` is used (AAB to Play Store
delivers per-ABI splits automatically).

### Behaviour preservation

* Public class names — all kept (`AuthProvider`, `CourseProvider`,
  `UserProvider`, `EnrollmentProvider`, `ThemeProvider`, `ApiClient`,
  `ApiException`, `Course`, `AppUser`, `LearningPath`, `LearningPathStep`).
* Public provider methods — all kept (`setToken`, `setProgress`, `setMode`,
  `addFavorite`, `removeFavorite`, `updateCourseProgress`,
  `loadFavorites`, `loadPersonalized`, etc.).
* `SharedPreferences` keys — all four keys (`auth_token`,
  `enrolled_course_ids`, `theme_mode`, `onboarding_done`) still read/write
  the same names.
* 4-tab `IndexedStack` shell, `ShellScreen` tab order, `_Enrolled` chip,
  mock billing-sheet copy — **all untouched**.
* Backend, models, notebooks — **untouched** (out of scope per brief).

## Rollback

If any Stage-3 change regresses behaviour on-device, revert in reverse order:

```powershell
# 1) Restore code and config (drops all Stage-3 edits)
git checkout -- my_app/lib my_app/pubspec.yaml my_app/android/app/build.gradle.kts my_app/android/app/src/main/AndroidManifest.xml

# 2) Restore the deleted screen (only if the Search route is wanted back)
git checkout -- my_app/lib/screens/search_screen.dart

# 3) Clean the build cache
Set-Location E:\Flutter_app\my_app; flutter clean; flutter pub get
```

Files changed in this optimization (13 total):

* `my_app/lib/api_client.dart`
* `my_app/lib/models.dart`
* `my_app/lib/app_state.dart`
* `my_app/lib/theme.dart`
* `my_app/lib/navigation.dart`
* `my_app/lib/app.dart`
* `my_app/lib/screens/recommendations_screen.dart`
* `my_app/lib/screens/course_details_screen.dart`
* `my_app/lib/screens/profile_screen.dart`
* `my_app/pubspec.yaml`
* `my_app/android/app/build.gradle.kts`
* `my_app/android/app/src/main/AndroidManifest.xml`
* `my_app/lib/screens/search_screen.dart` - **deleted**
