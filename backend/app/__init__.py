"""EduCompass Flask application entry point.

Run with ``python app1.py`` or ``flask --app app1 run``.
"""

from __future__ import annotations

import os

from dotenv import load_dotenv

from .config import get_config
from .database_models import db
from .extensions import cors, jwt
from .migrations import apply_lightweight_migrations
from .model_service import load_recommender
from .routes import bp as api_bp


load_dotenv()


def create_app(skip_model_load: bool = False):
    """Build a Flask app with the EduCompass defaults."""

    from flask import Flask

    app = Flask(__name__)
    app.config.from_object(get_config(os.environ.get("FLASK_ENV")))

    db.init_app(app)
    jwt.init_app(app)

    cors.init_app(
        app,
        resources={r"/api/*": {"origins": app.config["CORS_ORIGINS"]}},
        supports_credentials=False,
    )

    if app.config["AUTO_CREATE_DB"]:
        from .database_models import (  # noqa: F401 — register tables
            CourseProgress,
            Enrollment,
            Favorite,
            History,
            LearningPathProgress,
            Notification,
            User,
            UserInterest,
        )

        with app.app_context():
            db.create_all()
            # SQLite-only additive migrations (e.g. add firebase_uid to
            # an existing users table). Safe no-ops when the columns
            # are already present.
            apply_lightweight_migrations(db)

    if not skip_model_load:
        app.extensions["educompass_model"] = load_recommender()

    app.register_blueprint(api_bp)

    # Friendly homepage so `curl http://127.0.0.1:5000/` (and the browser
    # smoke test) returns something useful instead of a 404. The real
    # API lives under `/api/v1/*` — this is purely a discoverability aid.
    @app.route("/", methods=["GET"])
    def home():
        return {
            "message": "EduCompass backend is running",
            "status": "success",
            "endpoints": {
                "health": "/api/v1/health",
                "popular": "/api/v1/courses/popular",
                "top_rated": "/api/v1/courses/top-rated",
                "recommend": "/api/v1/recommendations/query",
                "filters": "/api/v1/filters",
                "learning_paths": "/api/v1/learning-paths",
            },
        }, 200

    return app


app = create_app()


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port, debug=app.config["DEBUG"])


__all__ = ["create_app"]
