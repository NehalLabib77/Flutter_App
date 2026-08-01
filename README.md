# EduCompass — AI-Powered Course Recommendation System

EduCompass is a full-stack learning platform that turns 24,000+ online courses
from providers like Coursera and edX into a personalised recommendation feed.
It pairs a **Flask + scikit-learn** REST backend (TF-IDF + cosine similarity
over course titles, descriptions, skills, and subjects) with a **Flutter**
mobile app that lets users register, search, get AI recommendations by goal or
interests, follow curated learning paths, save favourites, and track progress.

## Repo layout

```text
.
├── backend/                 Flask REST API (package: app/)
│   ├── app/                 Config, routes, models, model loader, auth_otp
│   ├── tests/               pytest tests
│   ├── instance/            SQLite database (gitignored)
│   ├── run.py               entry point
│   ├── .env.example
│   └── requirements.txt
├── my_app/                  Flutter mobile client (Android, iOS, web, desktop)
│   ├── lib/                 Dart sources (screens/, providers, API client)
│   ├── android/ ios/ linux/ macos/ web/ windows/
│   └── pubspec.yaml
├── data/
│   ├── raw/                 raw CSV/JSON course dumps
│   └── processed/           combined datasets + curated outputs
├── ml/
│   ├── notebooks/           exploratory + training notebooks
│   ├── training/            training scripts
│   ├── evaluation/          baseline + comparison CSVs
│   ├── artifacts/models/    TF-IDF joblib bundles (incl. v2/)
│   └── requirements.txt
├── docs/
│   └── ui-references/       widget-tree / theme docs
├── .gitignore
├── LICENSE
└── README.md                (this file)
```

## Features

### Mobile app (Flutter 3, Android & iOS)

- Email/password registration with phone-OTP verification, JWT login.
- Onboarding carousel (3 screens), light + dark theme, persistent preferences.
- Home feed with personalised picks, popular courses, and subject browse.
- Debounced search with filters (level, language, rating) and recent searches.
- "For You" recommendations driven by the user's interests and learning goal.
- Course details with hero image, skills, rating, provider, and "Open course"
  deep-link to the browser.
- Favourites, recently-viewed history, and per-course progress tracking.
- Curated **learning paths** with step-by-step timeline.

### Backend (Flask 3 + scikit-learn)

- TF-IDF + cosine similarity over the course corpus, field-weighted scoring
  using `course_name`, `description`, `skills`, `subject` (weights configured
  in `ml/artifacts/models/v2/model_config.json`).
- 28 REST endpoints covering auth, courses, recommendations, learning paths,
  favourites, history, and progress.
- JWT auth (Flask-JWT-Extended), CORS (Flask-CORS), SQLite via SQLAlchemy.
- In-memory phone-OTP store (`backend/app/auth_otp.py`) for login / register
  verification — `dev_code` is returned in the response to ease local testing.

## Getting started

### 1. Clone

```bash
git clone <repo-url>
cd Flutter_App
```

### 2. Backend

```bash
cd backend
python -m venv .venv
```

Windows PowerShell:

```powershell
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python run.py          # serves on http://0.0.0.0:5000
```

macOS / Linux:

```bash
source .venv/bin/activate
pip install -r requirements.txt
python run.py
```

The first run auto-creates `backend/instance/educompass.db` and loads the
joblib bundle from `ml/artifacts/models/v2/` (override with `MODEL_DIR`).

Optional env vars (see `backend/.env.example`):

```text
FLASK_ENV=development
SECRET_KEY=<random>
JWT_SECRET_KEY=<random>
DATABASE_URL=sqlite:///educompass.db
CORS_ORIGINS=*
MODEL_DIR=../ml/artifacts/models/v2
LEARNING_PATHS_FILE=./data/learning_paths.json
AUTO_CREATE_DB=true
LOG_LEVEL=INFO
```

### 3. Mobile app

```bash
cd my_app
flutter pub get
flutter run            # pick a connected device / emulator
```

To point the app at a non-default backend host:

```bash
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:5000    # Android emulator default
```

### 4. Tests

Backend:

```bash
cd backend
pytest tests/ -q
```

Frontend:

```bash
cd my_app
flutter test
flutter analyze
```

## API surface

| Path | Method | Description |
| --- | --- | --- |
| `/api/v1/health` | GET | Service + model health |
| `/api/v1/auth/otp/request` | POST | Issue a phone OTP (returns `dev_code` in dev mode) |
| `/api/v1/auth/otp/verify` | POST | Verify a phone OTP |
| `/api/v1/auth/register` | POST | Create account (requires verified OTP reference) |
| `/api/v1/auth/login` | POST | Email + password + verified OTP → JWT pair |
| `/api/v1/auth/refresh` | POST | Refresh access token |
| `/api/v1/auth/me` | GET | Current user profile |
| `/api/v1/auth/profile` | PUT | Update name / interests |
| `/api/v1/courses/search` | GET | Debounced search with filters |
| `/api/v1/courses/autocomplete` | GET | Typeahead suggestions |
| `/api/v1/courses/popular` | GET | Popular courses |
| `/api/v1/courses/top-rated` | GET | Top-rated courses |
| `/api/v1/courses/<course_id>` | GET | Course details |
| `/api/v1/courses/<course_id>/similar` | GET | Similar courses |
| `/api/v1/recommendations/query` | POST | Query-based recommendations |
| `/api/v1/recommendations/personalized` | POST | Personalised picks |
| `/api/v1/recommendations/similar/<course_id>` | GET | Course-similar recommendations |
| `/api/v1/recommendations/filters` | GET | Available filter values |
| `/api/v1/me/favorites` | GET / POST | Favourites CRUD |
| `/api/v1/me/favorites/<course_id>` | DELETE | Remove favourite |
| `/api/v1/me/history` | GET / POST | Recently viewed courses |
| `/api/v1/me/progress` | GET | Per-course progress |
| `/api/v1/me/progress/<course_id>` | PUT | Update progress |
| `/api/v1/learning-paths` | GET | Curated learning paths |
| `/api/v1/learning-paths/<path_id>` | GET | Path detail |
| `/api/v1/learning-paths/<path_id>/progress` | GET / PUT | Path progress |

Full schema is also published as a Postman collection:
`backend/EduCompass.postman_collection.json`.

## License

See `LICENSE`.
