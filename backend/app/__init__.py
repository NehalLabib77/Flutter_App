"""EduCompass Flask application entry point.

Run with ``python run.py`` or ``flask --app app run``. A separate
``init-db`` CLI is exposed for creating tables on first deploy
(see ``init_db_command`` below).
"""

from __future__ import annotations

import logging
import os
import sys

import click
from dotenv import load_dotenv
from flask import Flask
from sqlalchemy import text
from sqlalchemy.exc import OperationalError, SQLAlchemyError

from .config import (
    _describe_database_url,
    get_config,
)
from .database_models import db
from .extensions import cors, jwt
from .migrations import apply_lightweight_migrations
from .model_service import load_recommender
from .payment_routes import payment_bp
from .routes import bp as api_bp, json_error, json_ok


load_dotenv()


_log = logging.getLogger("educompass.startup")


def _safe_db_log() -> None:
    """Log the active database target *without* leaking the password."""
    try:
        from flask import current_app

        uri = current_app.config.get("SQLALCHEMY_DATABASE_URI", "")
    except RuntimeError:
        uri = ""
    if uri:
        _log.info("Database target: %s", _describe_database_url(uri))


def _maybe_create_tables(app: Flask) -> None:
    """Create tables + run additive migrations, but never silently fall
    back to SQLite. If PostgreSQL is unreachable we log the error and
    re-raise so the process exits with a non-zero status (Render will
    then surface the cause in the deploy logs).
    """
    if not app.config.get("AUTO_CREATE_DB", True):
        _log.info(
            "AUTO_CREATE_DB is disabled; skipping automatic table creation."
        )
        return

    # Import models so they register with SQLAlchemy before create_all().
    from .database_models import (  # noqa: F401 — register tables
        CourseProgress,
        Enrollment,
        Favorite,
        History,
        LearningPathProgress,
        Notification,
        Payment,
        User,
        UserInterest,
    )

    with app.app_context():
        try:
            db.create_all()
            apply_lightweight_migrations(db)
        except OperationalError as exc:
            _log.error(
                "Database connection failed during db.create_all(): %s",
                exc,
            )
            _safe_db_log()
            raise
        except SQLAlchemyError as exc:
            _log.error(
                "Unexpected SQLAlchemy error during db.create_all(): %s",
                exc,
            )
            _safe_db_log()
            raise


def create_app(skip_model_load: bool = False) -> Flask:
    """Build a Flask app with the EduCompass defaults."""

    app = Flask(__name__)

    # Validate / load the config. ProductionConfig raises RuntimeError
    # if DATABASE_URL is missing, which is exactly what we want — a
    # loud, clear failure at boot instead of a silent SQLite fallback.
    app.config.from_object(get_config(os.environ.get("FLASK_ENV")))

    _safe_db_log()

    db.init_app(app)
    jwt.init_app(app)

    cors.init_app(
        app,
        resources={r"/api/*": {"origins": app.config["CORS_ORIGINS"]}},
        supports_credentials=False,
    )

    _maybe_create_tables(app)

    if not skip_model_load:
        app.extensions["educompass_model"] = load_recommender()

    app.register_blueprint(api_bp)
    app.register_blueprint(payment_bp)

    # Friendly homepage so `curl http://127.0.0.1:5000/` (and the browser
    # smoke test) returns something useful instead of a 404. The real
    # API lives under `/api/v1/*` — this is purely a discoverability aid.
    @app.route("/", methods=["GET"])
    def home():
        return {
            "message": "EduCompass backend is running",
            "status": "success",
            "endpoints": {
                "health": "/api/health",
                "health_db": "/api/v1/health/db",
                "popular": "/api/v1/courses/popular",
                "top_rated": "/api/v1/courses/top-rated",
                "recommend": "/api/v1/recommendations/query",
                "filters": "/api/v1/filters",
                "learning_paths": "/api/v1/learning-paths",
            },
        }, 200

    # --------------------------------------------------------------------------
    # JSON error handlers — Render's default 404 page is HTML, which the
    # Flutter client cannot parse. Override with a JSON envelope so the
    # error reaches the UI as a normal ApiException.
    # --------------------------------------------------------------------------
    @app.errorhandler(404)
    def _not_found(_e):
        return json_error(
            "Endpoint not found. The API lives under /api/v1/*.",
            status=404, code="NOT_FOUND",
        )

    @app.errorhandler(405)
    def _method_not_allowed(_e):
        return json_error(
            "Method not allowed for this endpoint.",
            status=405, code="METHOD_NOT_ALLOWED",
        )

    @app.errorhandler(500)
    def _server_error(_e):
        return json_error(
            "Internal server error.",
            status=500, code="SERVER_ERROR",
        )

    # --------------------------------------------------------------------------
    # Bare /api/health alias — same payload as /api/v1/health, exposed
    # under the unprefixed /api namespace so the Flutter
    # `ApiClient.health()` ping and the Render health check both work.
    # --------------------------------------------------------------------------
    @app.get("/api/health")
    def _api_health():
        adapter = app.extensions.get("educompass_model")
        if adapter is None:
            return json_ok({"status": "starting"})
        return json_ok({
            "status": "healthy",
            "model_version": adapter.meta.version,
            "courses_loaded": adapter.number_of_courses,
            "feature_count": adapter.meta.number_of_features,
        })

    # --------------------------------------------------------------------------
    # Database health probe — runs ``SELECT 1`` and never returns the
    # connection URL or any credentials.
    # --------------------------------------------------------------------------
    @app.get("/api/v1/health/db")
    def _db_health():
        try:
            db.session.execute(text("SELECT 1"))
        except OperationalError as exc:
            _log.warning("DB health check failed: %s", exc)
            return json_error(
                "Database is not reachable.",
                status=503, code="DB_UNREACHABLE",
            )
        except SQLAlchemyError as exc:
            _log.warning("DB health check raised SQLAlchemyError: %s", exc)
            return json_error(
                "Database health check failed.",
                status=503, code="DB_UNREACHABLE",
            )
        return json_ok({"status": "healthy", "database": "reachable"})

    # --------------------------------------------------------------------------
    # Flask CLI: ``flask init-db`` (or ``python -m app init-db``) creates
    # tables + runs additive migrations on a deployed database. Safe to
    # re-run; ignores tables that already exist.
    # --------------------------------------------------------------------------
    @app.cli.command("init-db")
    def init_db_command() -> None:
        """Create database tables and run additive migrations."""
        from .database_models import (  # noqa: F401
            CourseProgress,
            Enrollment,
            Favorite,
            History,
            LearningPathProgress,
            Notification,
            Payment,
            User,
            UserInterest,
        )

        with app.app_context():
            try:
                db.create_all()
                apply_lightweight_migrations(db)
            except OperationalError as exc:
                click.echo(
                    "Database connection failed while running init-db. "
                    "Check DATABASE_URL. Original error:",
                    err=True,
                )
                click.echo(str(exc), err=True)
                sys.exit(1)
        click.echo("Database tables are up to date.")

    return app


app = create_app()


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port, debug=app.config["DEBUG"])


__all__ = ["create_app"]
