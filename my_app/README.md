# Course Compass — AI-Powered Course Recommendation App

A Flutter mobile client for an AI-powered course recommendation system. The app
talks to a Flask REST backend, lets users register/log in, browse courses, get
personalised AI recommendations, save favourites, mark courses as complete, and
follow curated learning paths.

## Tech stack

- Flutter 3.10+ (Material 3)
- `provider` for state management (ChangeNotifier providers)
- `http` for REST calls with JWT bearer auth
- `flutter_secure_storage` for the JWT token
- `shared_preferences` for theme, onboarding flag, recent searches
- `cached_network_image` for course thumbnails
- `url_launcher` for "Open course" deep-link

## Project structure

```
lib/
  main.dart                 – entry point, wires all providers
  app.dart                  – MaterialApp + theme + MainShell (bottom nav)
  config/
    api_config.dart         – API base URL + endpoint paths (overridable via --dart-define)
    app_colors.dart         – brand palette
    app_routes.dart         – route name constants
    app_theme.dart          – Material 3 light + dark themes
  utils/
    constants.dart          – page sizes, debounce, level/price enums
    error_handler.dart      – ApiException + ErrorHandler.fromError
    validators.dart         – email/password/name validators
  models/
    course.dart             – Course entity + tolerant fromJson
    learning_path.dart      – LearningPath + LearningPathStep
    recommendation_response.dart – /recommend wrapper
    user.dart               – AppUser with initials
  services/
    api_service.dart        – HTTP client wrapper (JWT, timeout, errors)
    auth_service.dart       – register / login / profile
    course_service.dart     – list/get courses + subjects/providers
    favorite_service.dart   – favorites + history endpoints
    recommendation_service.dart – /recommend, /learning-paths
    storage_service.dart    – token, theme, onboarding, recent searches
  providers/
    auth_provider.dart
    course_provider.dart
    favorite_provider.dart
    history_provider.dart
    recommendation_provider.dart
  widgets/
    loading_widget.dart, empty_state_widget.dart, error_state_widget.dart
    rating_badge.dart, skill_chip.dart, custom_search_bar.dart
    course_card.dart, recommendation_card.dart, filter_bottom_sheet.dart
  screens/
    splash/                 – onboarding gate
    onboarding/             – 3-page intro
    auth/                   – login + register
    home/                   – greeting + recommendations + subjects + browse
    search/                 – debounced search + recent searches + filters
    recommendations/        – "For you" (personalised) + "By goal"
    course_details/         – hero image + meta + skills + favorite + open
    favorites/              – grid of saved courses
    learning_paths/         – list + step-by-step detail timeline
    profile/                – avatar + stats + interests + theme + sign out
```

## Prerequisites

1. Flutter 3.10+ installed (https://docs.flutter.dev/get-started/install).
2. An Android emulator (or physical device) for local development. iOS works
   too — only the base URL differs (see below).
3. The companion Flask backend running on your machine.

## Install

```bash
cd my_app
flutter pub get
```

## Run

### Android emulator (default)
The app defaults to `http://10.0.2.2:5000`, which is the Android emulator's
loopback to the host machine.

```bash
# 1. Start the Flask backend (in another terminal) on port 5000.
# 2. Start an Android emulator or device:
flutter devices
# 3. Run the app:
flutter run
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

## Backend API endpoints used

| Method | Path                                | Purpose                              |
|--------|-------------------------------------|--------------------------------------|
| POST   | `/auth/register`                    | Register a new user                  |
| POST   | `/auth/login`                       | Log in, returns JWT                  |
| GET    | `/auth/profile`                     | Get the current user                 |
| PUT    | `/auth/profile`                     | Update name / interests              |
| GET    | `/courses`                          | List courses (filters: subject, …)   |
| GET    | `/courses/{id}`                     | Get a single course                  |
| GET    | `/subjects`                         | List all subjects                    |
| GET    | `/providers`                        | List all providers                   |
| GET    | `/recommend?course=...`             | Recommend courses by course name     |
| POST   | `/recommend-by-goal`                | Recommend courses by learning goal   |
| GET    | `/recommend/personalized`           | Personalised picks (interests)       |
| GET    | `/learning-paths`                   | List curated learning paths          |
| GET    | `/favorites`                        | List favourite courses               |
| POST   | `/favorites/{course_id}`            | Add a favourite                      |
| DELETE | `/favorites/{course_id}`            | Remove a favourite                   |
| GET    | `/history`                          | List recently viewed courses         |
| POST   | `/history/{course_id}`              | Record a course view                 |

## Configuration

The base URL is read from `--dart-define=API_BASE_URL=...` with a sensible
default (`http://10.0.2.2:5000`) for the Android emulator. See
`lib/config/api_config.dart`.

The bearer token is stored in `flutter_secure_storage`. Theme mode, the
onboarding flag, and recent searches are stored in `shared_preferences`.

## Smoke test

1. Launch the app — splash → onboarding (3 pages) → login.
2. Tap "Create an account" — register with name/email/password + interests.
3. Browse home: personalised picks, subjects, and "Browse courses".
4. Open any course → tap the heart (favourite) and "Open course" to launch the
   browser.
5. Use Search to debounce-type a query; try the filter sheet.
6. Open For-you tab → describe a goal → tap Recommend.
7. Open Paths → tap a path → step-by-step timeline.
8. Open Profile → switch theme → edit interests → sign out (returns to login).

## Notes

- The app is offline-friendly: errors from the API surface as in-screen error
  states with retry.
- Models use tolerant factory constructors — backend field names can vary
  (`title`/`name`, `image`/`image_url`, `reviews_count`/`reviews`, …) without
  breaking the UI.
- All long-running async calls that touch `BuildContext` are guarded with
  `mounted` checks before they navigate or display snack bars.
