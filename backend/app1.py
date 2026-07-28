"""EduCompass Flask application entry point.

Run with ``python app1.py`` or ``flask --app app1 run``.
"""

from __future__ import annotations

import os

from dotenv import load_dotenv

from billing_service import get_billing_provider
from config import get_config
from database_models import db
from extensions import cors, jwt
from model_service import load_recommender
from routes import bp as api_bp


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
        from database_models import (  # noqa: F401 — register tables
            BillingEvent,
            CourseProgress,
            Favorite,
            History,
            LearningPathProgress,
            Notification,
            Subscription,
            User,
            UserInterest,
        )

        with app.app_context():
            db.create_all()

    if not skip_model_load:
        app.extensions["educompass_model"] = load_recommender()

    app.extensions["billing_provider"] = get_billing_provider(app.config)

    app.register_blueprint(api_bp)
    return app


app = create_app()


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port, debug=app.config["DEBUG"])


__all__ = ["create_app"]
