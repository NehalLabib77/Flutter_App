# EduCompass Flask REST API

## Folder structure

```text
EduCompass/
├── backend/
│   ├── app.py
│   └── requirements.txt
└── models/
    ├── courses.joblib
    ├── tfidf_matrix.joblib
    └── tfidf_vectorizer.joblib
```

Copy the three model files created by the notebook into `models/`.

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

macOS/Linux:

```bash
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python app.py
```

Default address:

```text
http://127.0.0.1:5000
```

## Test health

```text
GET http://127.0.0.1:5000/api/health
```

## Recommend courses

```http
POST /api/recommend
Content-Type: application/json
```

Body:

```json
{
  "query": "beginner Python data analysis using pandas",
  "top_n": 10,
  "level": "Beginner",
  "minimum_rating": 4.0,
  "free_only": false
}
```

## Similar courses

```text
GET /api/courses/101/similar?top_n=10
```

## Course details

```text
GET /api/courses/101
```

## Filter options

```text
GET /api/filters
```

## Flutter connection

Android emulator:

```dart
const apiBaseUrl = "http://10.0.2.2:5000";
```

A physical phone must use the computer's local network IP address, for example:

```dart
const apiBaseUrl = "http://192.168.0.10:5000";
```

The computer and phone must be connected to the same network, and the firewall must allow port 5000.
