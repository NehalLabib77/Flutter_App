# EduCompass — Backend (Flask REST API)

The Flask backend powering EduCompass. See the top-level [`README.md`](../README.md)
for full repo layout, feature list, and the complete API table.

## Folder structure

```text
backend/
├── app/
│   ├── __init__.py            Flask app factory + blueprint registration
│   ├── config.py              Config classes (Dev/Prod/Testing) + env-var overrides
│   ├── extensions.py          db, jwt, cors singletons
│   ├── database_models.py     SQLAlchemy ORM models (User, Favorite, …)
│   ├── routes.py              Blueprint mounted at /api/v1
│   ├── model_loader.py        Loads TF-IDF joblib bundles from ml/artifacts/models/
│   ├── model_service.py       Recommender service wrapping the loaded model
│   ├── auth_otp.py            In-memory phone-OTP store (login / register)
│   ├── data/                  Seed data bundled with the package
│   ├── static/                Static assets served by Flask
│   └── templates/             Jinja2 templates (used by health views, etc.)
├── tests/                     pytest tests
├── instance/                  SQLite database (created on first run, gitignored)
├── run.py                     entry point — `python run.py`
├── .env.example
└── requirements.txt
```

The recommender joblib bundle lives at `../ml/artifacts/models/v2/` — override
the location with `MODEL_DIR=...` in your `.env`.

## Install

```bash
cd backend
python -m venv .venv
```

Windows PowerShell:

```powershell
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Windows Command Prompt:

```cmd
.venv\Scripts\activate
pip install -r requirements.txt
```

macOS / Linux:

```bash
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python run.py
```

Default address: `http://0.0.0.0:5000` (override `HOST` / `PORT`).

A Postman collection ships with the repo:
`backend/EduCompass.postman_collection.json`.

## Firebase Auth setup

User identity is stored in **Firebase Auth** (with a profile document in
**Firestore** under `users/{uid}`). The SQL `users` table is a thin
mirror used for JWT identity and existing favourites / progress /
history endpoints — passwords are never verified against SQL.

You need **two** pieces of configuration:

### 1. Service-account credentials (Admin SDK)

Pick one of:

* `GOOGLE_APPLICATION_CREDENTIALS` — filesystem path to a service-account
  JSON file. Easiest for local dev:

  ```powershell
  # Firebase Console → Project settings → Service accounts → Generate new private key
  $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\path\to\educompass-b925e-firebase-adminsdk-xxxxx.json"
  ```

* `FIREBASE_SERVICE_ACCOUNT_JSON` — inline JSON. Best for hosting
  platforms (Render, Railway, Cloud Run, Fly.io). Paste the entire
  contents of the service-account JSON file as one line.

Without either of these, the backend boots but `/auth/register` returns
`503 AUTH_BACKEND_UNAVAILABLE`.

### 2. Web API key (REST password verification)

The Admin SDK cannot verify passwords directly, so `/auth/login` calls
the Identity Toolkit REST endpoint with a public **Web API key**:

```powershell
# Firebase Console → Project settings → General → "Web API Key"
$env:FIREBASE_WEB_API_KEY = "AIzaSy..."
```

Optional Firestore defaults already match the Flutter `firebase_options.dart`
in `my_app/` (project `educompass-b925e`).

### Quick smoke test

```powershell
curl -X POST http://127.0.0.1:5000/api/v1/auth/register `
  -H "Content-Type: application/json" `
  -d '{"email":"you@example.com","password":"correcthorse","full_name":"You"}'
# → Expect {"success": true, "data": {"id": ..., "firebase_uid": "..."}}
# Then check Firebase Console → Authentication → Users; the new entry
# should be there, and Firestore users/{uid} should hold the profile.
```

