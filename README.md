# EduCompass — AI-Powered Course Recommendation System

EduCompass is a full-stack learning platform that turns 24,000+ online courses from
providers like Coursera and edX into a personalised recommendation feed.
It pairs a **Flask + scikit-learn** REST backend (TF-IDF + cosine similarity over
course titles, descriptions, skills, and subjects) with a **Flutter** mobile app
that lets users register, search, get AI recommendations by goal or interests,
follow curated learning paths, save favourites, and track progress.

## Features

### Mobile app (Flutter, Android & iOS)
- Email/password registration and JWT login (auto-login after signup).
- Onboarding carousel (3 screens), light + dark theme, persistent preferences.
- Home feed with personalised picks, popular courses, and subject browse.
- Debounced search with filters (level, language, price, rating) and recent
  searches.
- "For You" recommendations driven by the user's interests and learning goal.
- Course details with hero image, skills, rating, provider, and "Open course"
  deep-link to the browser.
- Favourites, recently-viewed history, and per-course progress tracking.
- Curated **learning paths** with step-by-step timeline.
- In-app mock billing (OTP flow) — fully runnable without external services.

### Backend (Flask 3 + scikit-learn)
- TF-IDF + cosine similarity over 24,646 courses, 50,000 vocab tokens.
- Field-weighted scoring using `course_name`, `description`, `skills`,
  `subject` (weights configured in `models/v2/model_config.json`).
- 30+ REST endpoints covering auth, courses, recommendations, learning paths,
  favourites, history, progress, billing, and notifications.
- SQLite persistence via SQLAlchemy (no external DB needed).
- JWT access + refresh tokens, CORS, request logging, health endpoint.

## Tech stack

| Layer    | Technology |
|----------|------------|
| Mobile   | Flutter 3.10+, Material 3, `provider`, `http`, `flutter_secure_storage`, `shared_preferences`, `cached_network_image`, `url_launcher` |
| Backend  | Python 3.11+, Flask 3, Flask-SQLAlchemy, Flask-JWT-Extended, Flask-CORS, scikit-learn, pandas, NumPy, joblib |
| Data     | SQLite (auto-created), TF-IDF joblib bundle in `models/v2/` |
| ML       | TF-IDF vectorizer + sparse cosine-similarity matrix; per-field vectorizers |

## Project layout

```
E:\Flutter_app\
├── backend/                 # Flask REST API
│   ├── app1.py              # entry point (create_app + run)
│   ├── config.py            # env-driven config (JWT, DB, billing, paths)
│   ├── database_models.py   # SQLAlchemy models (users, favourites, etc.)
│   ├── routes.py            # 30+ blueprint endpoints
│   ├── model_loader.py      # TF-IDF bundle loader + adapter
│   ├── model_service.py     # re-exports
│   ├── billing_service.py   # mock OTP billing
│   ├── extensions.py        # SQLAlchemy/JWT singleton instances
│   ├── data/learning_paths.json   # curated paths
│   ├── static/, templates/  # minimal landing page assets
│   ├── tests/, test_api.py  # pytest suite
│   ├── requirements.txt
│   └── .env.example
├── my_app/                  # Flutter mobile client
│   ├── lib/
│   │   ├── main.dart        # entry point, provider wiring
│   │   ├── app.dart         # MaterialApp + MainShell
│   │   ├── api_client.dart  # HTTP wrapper (JWT, error envelope)
│   │   ├── app_state.dart   # AuthProvider, FavoritesProvider, etc.
│   │   ├── config/          # api_config, app_colors, app_routes, app_theme
│   │   ├── models/          # Course, LearningPath, RecommendationResponse, AppUser
│   │   ├── services/        # api, auth, course, favorite, recommendation, storage
│   │   ├── providers/       # ChangeNotifier providers
│   │   ├── screens/         # splash, onboarding, auth, home, search,
│   │   │                    # recommendations, course_details, favorites,
│   │   │                    # learning_paths, profile
│   │   ├── widgets/         # shared UI atoms
│   │   └── utils/           # validators, error_handler, constants
│   ├── android/, ios/, web/, windows/, macos/, linux/
│   └── pubspec.yaml
├── models/
│   ├── courses.joblib
│   ├── tfidf_vectorizer.joblib
│   ├── tfidf_matrix.joblib
│   ├── model_metadata.json
│   ├── evaluation/          # offline eval artefacts
│   └── v2/                  # production bundle (per-field vectorizers)
├── dataset/                 # raw + processed CSVs/JSONs
├── notebooks/               # EDA, modelling, experimentation
├── instance/                # auto-created at runtime (educompass.db)
└── requirements.txt
```

## Prerequisites

1. **Python 3.11+** with pip.
2. **Flutter 3.10+** — install from <https://docs.flutter.dev/get-started/install>.
3. **Android Studio / SDK** (for Android) or Xcode (for iOS).
4. A physical phone or emulator (the app was tested on an Infinix X665E,
   Android 12, API 31).
5. The trained TF-IDF bundle already committed under `models/v2/` —
   nothing else to train.

## Run the backend (step by step)

```powershell
# 1. Open a terminal in the project root
cd E:\Flutter_app

# 2. Create and activate a virtual env (one-time)
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# 3. Install backend dependencies
pip install -r backend\requirements.txt

# 4. (Optional) customise config
copy backend\.env.example backend\.env
notepad backend\.env

# 5. Start the API on 0.0.0.0:5000 (auto-creates the SQLite DB and loads
#    the TF-IDF bundle on first request)
$env:FLASK_ENV = "production"
python backend\app1.py
```

You should see:

```
* Serving Flask app 'app1'
* Running on http://127.0.0.1:5000
* Running on http://192.168.x.x:5000   <-- this is the LAN address phones use
```

Smoke-test it:

```powershell
curl http://127.0.0.1:5000/api/v1/health
# -> {"data":{"courses_loaded":24646,"feature_count":50000,"model_version":"v2","status":"healthy"},"success":true}
```

## Run the Flutter app

```powershell
# 1. Get packages
cd E:\Flutter_app\my_app
flutter pub get

# 2a. Android emulator — default API base is http://10.0.2.2:5000
flutter run

# 2b. iOS simulator
flutter run --dart-define=API_BASE_URL=http://localhost:5000

# 2c. Physical Android phone on the same Wi-Fi network as the backend
#     (replace the IP with your host's LAN address, see backend startup log)
flutter run -d <device-id> --dart-define=API_BASE_URL=http://192.168.0.102:5000
```

Useful Flutter commands:

```powershell
flutter devices                                 # list connected phones/emulators
flutter run -d <device-id>                      # target one device
flutter run --dart-define=API_BASE_URL=...       # point at any backend
```

## End-to-end smoke test

1. Launch the app → splash → 3-page onboarding → login.
2. Tap **Create an account** and register (name + email + password).
3. Browse the home feed — personalised picks, popular courses, subjects.
4. Open any course → tap the heart (favourite) and **Open course** to launch
   the browser.
5. Search with debounce; open the filter sheet for level/price/rating.
6. **For You** → describe a learning goal → tap **Recommend**.
7. **Paths** → tap a curated path → step-by-step timeline.
8. **Profile** → switch theme → edit interests → sign out (returns to login).

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Phone cannot reach `http://192.168.x.x:5000` | Make sure both devices are on the same Wi-Fi, and that Windows Firewall allows inbound TCP 5000 (`New-NetFirewallRule -DisplayName "Flask 5000" -Direction Inbound -LocalPort 5000 -Protocol TCP -Action Allow`). |
| `bind: address already in use` when starting the backend | `Stop-Process -Name python -Force` then restart. |
| `RenderFlex overflowed` warnings in the Flutter log | Cosmetic only — layout fits on real phones. |
| Stale "no models available" output from a hung terminal | The async terminal buffer is stale; check `Get-Process python` or read `$env:TEMP\backend.out` directly. |
| `Server didn't return a token` after registration | Already patched in `my_app/lib/app_state.dart` — `AuthProvider.register()` chains a `/auth/login` after `/auth/register` automatically. Hot-reload (`r`) or restart the app. |

## Configuration cheat-sheet

| Variable (backend)        | Default                                       | Purpose |
|---------------------------|-----------------------------------------------|---------|
| `FLASK_ENV`               | `production`                                  | Disables Werkzeug reloader for stable Flask. |
| `SECRET_KEY`              | `educompass-dev-secret`                       | Flask session signing. |
| `JWT_SECRET_KEY`          | falls back to `SECRET_KEY`                    | JWT signing. |
| `DATABASE_URL`            | `sqlite:///educompass.db`                     | SQLAlchemy URI. Override for Postgres/MySQL. |
| `MODEL_DIR`               | `models`                                      | Bundle directory (loads `v2/` automatically). |
| `LEARNING_PATHS_FILE`     | `<backend>/data/learning_paths.json`          | Curated paths source. |
| `BILLING_PROVIDER`        | `mock`                                        | `mock` for dev, `bdapps` for production OTP. |
| `CORS_ORIGINS`            | `*`                                           | Comma-separated allow-list. |
| `AUTO_CREATE_DB`          | `true`                                        | Auto-runs `db.create_all()` on startup. |

| `--dart-define` (Flutter) | Default              | Purpose |
|---------------------------|----------------------|---------|
| `API_BASE_URL`            | `http://10.0.2.2:5000` | Base URL for `api_client.dart`. Override for iOS sim or LAN. |

## Sample API payloads

All endpoints live under `/api/v1/`. Every successful response is wrapped in
`{"success": true, "data": {...}}`. The examples below use `127.0.0.1:5000`.

### Health

```bash
curl http://127.0.0.1:5000/api/v1/health
```

```json
{
  "success": true,
  "data": {
    "status": "healthy",
    "model_version": "v2",
    "courses_loaded": 24646,
    "feature_count": 50000
  }
}
```

### Popular courses

```bash
curl 'http://127.0.0.1:5000/api/v1/courses/popular?limit=1'
```

```json
{
  "success": true,
  "data": {
    "results": [
      {
        "id": "16393",
        "name": "Machine Learning",
        "provider": "Coursera",
        "level": "Mixed",
        "rating": 4.9,
        "reviews_count": 25,
        "students_enrolled": 3600000,
        "image_url": "https://d3njjcbhbojbot.cloudfront.net/.../ml/large-icon.png",
        "url": "https://www.coursera.org/learn/machine-learning",
        "skills": [
          "Logistic Regression",
          "Artificial Neural Network",
          "Machine Learning (ML) Algorithms",
          "Machine Learning"
        ]
      }
    ]
  }
}
```

### Free-text search

```bash
curl 'http://127.0.0.1:5000/api/v1/courses/search?q=python&page_size=1'
```

```json
{
  "success": true,
  "data": {
    "results": [
      {
        "id": "22402",
        "name": "Learn Python for Data Science & Machine Learning from A-Z",
        "provider": "Udemy",
        "level": "All Levels",
        "rating": 4.4,
        "reviews_count": 1626,
        "students_enrolled": 112421,
        "image_url": "",
        "url": "",
        "skills": []
      }
    ]
  }
}
```

### Goal-based recommendations

```bash
curl -X POST http://127.0.0.1:5000/api/v1/recommendations/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"learn python for data science","top_n":2}'
```

> Note the envelope key: this endpoint returns `data.recommendations`, not
> `data.results`.

```json
{
  "success": true,
  "data": {
    "query": "learn python for data science",
    "count": 10,
    "recommendations": [
      {
        "id": "22402",
        "name": "Learn Python for Data Science & Machine Learning from A-Z",
        "provider": "Udemy",
        "rating": 4.4,
        "final_score": 0.83,
        "skills": []
      },
      {
        "id": "20287",
        "name": "Python for Data Science",
        "provider": "Udemy",
        "rating": 4.5,
        "final_score": 0.79,
        "skills": []
      }
    ]
  }
}
```

### Personalised recommendations (JWT required)

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:5000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"..."}' \
  | python -c 'import sys,json;print(json.load(sys.stdin)["data"]["access_token"])')

curl -X POST http://127.0.0.1:5000/api/v1/recommendations/personalized \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"top_n":3}'
```

```json
{
  "success": true,
  "data": {
    "count": 10,
    "recommendations": [
      {
        "id": "16393",
        "name": "Machine Learning",
        "provider": "Coursera",
        "rating": 4.9,
        "skills": ["Logistic Regression","Artificial Neural Network"]
      }
    ]
  }
}
```

### Autocomplete

```bash
curl 'http://127.0.0.1:5000/api/v1/courses/autocomplete?q=mac&limit=3'
```

```json
{
  "success": true,
  "data": {
    "suggestions": [
      { "id": "16393", "name": "Machine Learning", "provider": "Coursera" }
    ]
  }
}
```

### Envelope key cheat-sheet

| Endpoint                                | Key under `data` |
|-----------------------------------------|------------------|
| `/courses/popular`                      | `results`        |
| `/courses/top-rated`                    | `results`        |
| `/courses/search`                       | `results`        |
| `/courses/{id}/similar`                 | `results`        |
| `/courses/autocomplete`                 | `suggestions`    |
| `/courses/{id}`                         | `course`         |
| `/recommendations/query` (POST)         | `recommendations`|
| `/recommendations/personalized` (POST)  | `recommendations`|
| `/recommendations/similar/{id}`         | `results`        |
| `/recommendations/filters`              | `filters`        |

## License

MIT — see `LICENSE`.