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
├── frontend/                Flutter app (was my_app/)
├── backend/                 Flask REST API
│   ├── app/                 package modules (config, routes, models, ...)
│   ├── tests/               pytest tests
│   ├── instance/            SQLite database (gitignored)
│   ├── run.py               entry point
│   └── requirements.txt
├── data/
│   ├── raw/                 raw CSV/JSON course dumps
│   └── processed/           combined datasets + curated outputs
├── ml/
│   ├── notebooks/           exploratory + training notebooks
│   ├── training/            training scripts
│   ├── evaluation/          baseline + comparison CSVs
│   └── artifacts/
│       └── models/          TF-IDF joblib bundles (incl. v2/)
├── docs/
│   ├── screenshots/         *.png from manual QA
│   ├── ui-references/       widget-tree / theme docs
│   └── xml/                 view-dump XML captures
├── scripts/                 ad-hoc ops scripts
├── .gitignore
├── LICENSE
└── README.md                (this file)
```

## Features

### Mobile app (Flutter, Android & iOS)
- Email/password registration and JWT login (auto-login after signup).
- Onboarding carousel (3 screens), light + dark theme, persistent preferences.
- Home feed with personalised picks, popular courses, and subject browse.
- Debounced search with filters (level, language, price, rating) and recent searches.
- "For You" recommendations driven by the user's interests and learning goal.
- Course details with hero image, skills, rating, provider, and "Open course"
  deep-link to the browser.
- Favourites, recently-viewed history, and per-course progress tracking.
- Curated **learning paths** with step-by-step timeline.
- bKash-style OTP billing flow (`/api/v1/billing/otp/request`, `/verify`,
  `/subscription/activate`) — real provider integration behind env vars, not a
  mock.

### Backend (Flask 3 + scikit-learn)
- TF-IDF + cosine similarity over 24,646 courses, 50,000 vocab tokens.
- Field-weighted scoring using `course_name`, `description`, `skills`,
  `subject` (weights configured in `ml/artifacts/models/v2/model_config.json`).
- 30+ REST endpoints covering auth, courses, recommendations, learning paths,
  favourites, history, progress, billing, and notifications.
- JWT auth (Flask-JWT-Extended), CORS (Flask-CORS), SQLite via SQLAlchemy.
- `billing_service` plugs in a configurable bKash-style OTP provider; default
  `mock` provider returns a deterministic dev OTP (`000000`).

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

The first run auto-creates `backend/instance/educompass.db` and seeds the
recommender using the v2 joblib bundle in `ml/artifacts/models/v2/`.

Optional env vars (see `backend/.env.example`):

```text
FLASK_ENV=development
SECRET_KEY=<random>
JWT_SECRET_KEY=<random>
DATABASE_URL=sqlite:///educompass.db
CORS_ORIGINS=*
MODEL_DIR=../ml/artifacts/models/v2
BILLING_PROVIDER=mock
BDAPPS_BASE_URL=https://api.example.com
BDAPPS_API_KEY=
BDAPPS_CLIENT_ID=
```

### 3. Frontend

```bash
cd frontend
flutter pub get
flutter run            # pick a connected device / emulator
```

To point the app at a non-default backend host:

```bash
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:5000/api/v1   # Android emulator
```

### 4. Tests

Backend:

```bash
cd backend
pytest tests/ -q
```

Frontend:

```bash
cd frontend
flutter test
flutter analyze
```

## API surface (highlights)

| Path | Method | Description |
| --- | --- | --- |
| `/api/v1/auth/register` | POST | Create account, returns JWT pair |
| `/api/v1/auth/login` | POST | Email/password → JWT pair |
| `/api/v1/courses/search` | GET | Debounced search with filters |
| `/api/v1/courses/recommend` | GET | "For You" recommendations |
| `/api/v1/me/favorites` | GET / POST / DELETE | Hydrated favourites CRUD |
| `/api/v1/billing/otp/request` | POST | Start OTP flow |
| `/api/v1/billing/otp/verify` | POST | Verify OTP code |
| `/api/v1/billing/subscription/activate` | POST | Activate paid plan |
| `/api/v1/learning-paths` | GET | Curated learning paths |

Full schema is also published as a Postman collection:
`backend/EduCompass.postman_collection.json`.

## License

See `LICENSE`.