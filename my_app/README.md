# EduCompass — Flutter Mobile Client

The Flutter mobile client for EduCompass. See the top-level
[`README.md`](../README.md) for the full repo layout and feature list.

## Tech stack

- Flutter 3.10+ (Material 3)
- `provider` for state management (ChangeNotifier providers)
- `http` for REST calls with JWT bearer auth
- `shared_preferences` for theme, onboarding flag, and recent searches
- `cached_network_image` for course thumbnails
- `url_launcher` for "Open course" deep-link

> `flutter_secure_storage` is intentionally **not** used — its Windows plugin
> requires the ATL C++ headers from Visual Studio. Token storage falls back to
> `shared_preferences`.

## Project structure

```text
lib/
  main.dart                    entry point; wires all providers
  app.dart                     MaterialApp + theme + routes
  app_state.dart               ChangeNotifier providers
                               (Auth, Course, User, Enrollment, Theme)
  api_client.dart              HTTP client; JWT bearer injection; error mapping
  models.dart                  Course, LearningPath, AppUser, etc.
  theme.dart                   Material 3 light + dark themes
  navigation.dart              Bottom-nav shell + route constants
  course_image.dart            Safe image loader (URL scheme validation)
  screens/
    splash_screen.dart         onboarding gate
    onboarding_screen.dart     3-page intro carousel
    login_screen.dart          phone-OTP + email/password login
    register_screen.dart       phone-OTP + email/password register
    shell_screen.dart          bottom-nav shell
    home_screen.dart           greeting + personalised picks + browse
    recommendations_screen.dart  "For You" + goal-based recommend
    course_details_screen.dart   hero image, skills, favourite, progress, "Open"
    favorites_screen.dart      grid of saved courses
    learning_paths_screen.dart list of curated paths
    learning_path_detail_screen.dart  step-by-step timeline
    profile_screen.dart        avatar + interests + theme + sign out
```

## Prerequisites

1. Flutter 3.10+ (<https://docs.flutter.dev/get-started/install>).
2. An Android emulator or physical device for local development. iOS works too
   — only the base URL differs (see below).
3. The companion Flask backend running on your machine (port 5000 by default).

## Install

```bash
cd my_app
flutter pub get
```

## Run

### One-command launcher (recommended)

The `scripts/run_android.ps1` helper auto-detects the connected device and
picks the right `API_BASE_URL`:

- Android **emulator** → `http://10.0.2.2:5000` (emulator loopback to host)
- Android **physical device** → the host's Wi-Fi / Ethernet LAN IP
  (e.g. `http://192.168.0.105:5000`) so the phone can reach the Flask server

```powershell
# From E:\Flutter_app\my_app
powershell -ExecutionPolicy Bypass -File scripts\run_android.ps1
```

It also pings `GET /` to confirm the Flask backend is up before launching.

### Manual: Android emulator (default)

The app defaults to `http://10.0.2.2:5000`, which is the Android emulator's
loopback to the host machine.

```bash
# 1. Start the Flask backend (in another terminal) on port 5000.
# 2. Start an Android emulator or device:
flutter devices
# 3. Run the app:
flutter run
```

### Manual: Android physical device

A bare `flutter run` will fail because `10.0.2.2` is emulator-only. Override
the base URL with your laptop's LAN IP (must match what `ipconfig` shows on
the same Wi-Fi the phone is on):

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.0.105:5000
```

### iOS simulator

iOS cannot reach `10.0.2.2`; use `http://localhost:5000` instead:

```bash
flutter run --dart-define=API_BASE_URL=http://localhost:5000
```

### Custom backend (e.g. staging server or LAN IP)

Override the base URL at build time:

```bash
flutter run --dart-define=API_BASE_URL=https://api.example.com
```

## Configuration

The base URL is read from `--dart-define=API_BASE_URL=...` with a sensible
default (`http://10.0.2.2:5000`) for the Android emulator. See
`lib/api_client.dart` (`ApiConfig.defaultBaseUrl`).

The bearer token, theme mode, the onboarding flag, and recent searches are all
stored in `shared_preferences`.

## Smoke test

1. Launch the app — splash → onboarding (3 pages) → Home tab. There is no
   login gate; guests land directly on Home.
2. Tap **Sign in** in the Home AppBar (or the Profile tab's button) — enter
   phone, request OTP, type the `dev_code` returned by the backend, then
   complete name/email/password + interests.
3. Browse home: personalised picks, subjects, and "Browse courses".
4. Open any course → tap the heart (favourite) and "Open course" to launch
   the browser.
5. Use Search to debounce-type a query.
6. Open For-you tab → describe a goal → tap Recommend.
7. Open Paths → tap a path → step-by-step timeline.
8. Open Profile → switch theme → edit interests → sign out. Signing out
   drops you back to the Home tab as a guest; the Profile tab shows a
   small **Sign in** button.

## Notes

- The app is offline-friendly: errors from the API surface as in-screen error
  states with retry.
- `api_client.dart` accepts backend field names in either case
  (`title`/`name`, `image`/`image_url`, `reviews_count`/`reviews`, …) without
  breaking the UI.
- All long-running async calls that touch `BuildContext` are guarded with
  `mounted` checks before they navigate or display snack bars.
