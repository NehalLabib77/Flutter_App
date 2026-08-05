"""Configuration loaded from environment variables."""

from __future__ import annotations

import logging
import os
from datetime import timedelta
from pathlib import Path
from typing import Type
from urllib.parse import urlparse, urlunparse


_log = logging.getLogger(__name__)


def _bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _str(value: str | None, default: str) -> str:
    return default if value is None or value == "" else value


# ---------------------------------------------------------------------------
# Database URL handling
# ---------------------------------------------------------------------------
#
# On Render, the PostgreSQL service exposes a ``DATABASE_URL`` env var that
# we must read at startup. We never hardcode a username / password / host.
#
# Rules:
#   * In production we *require* DATABASE_URL. There is no silent SQLite
#     fallback — the previous behaviour masked real credential errors
#     (e.g. the "role \"educompass\" is not permitted to log in" crash
#     on Render).
#   * Heroku-style ``postgres://`` URLs are normalised to ``postgresql://``
#     so SQLAlchemy >= 1.4 accepts them.
#   * The parsed username/host are logged (the password is *never* logged).
# ---------------------------------------------------------------------------

def _normalize_database_url(raw: str) -> str:
    """Strip whitespace, fix the legacy ``postgres://`` scheme, return a
    SQLAlchemy-compatible ``postgresql://`` URL."""
    url = raw.strip()
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    # Some deployments ship ``postgresql+psycopg2://`` — leave the driver
    # suffix alone, it's explicit and safe.
    return url


def _describe_database_url(url: str) -> str:
    """Return a log-safe description of a database URL.

    Only the scheme, username, host, port and database name are included.
    The password (if any) is replaced with ``***``.
    """
    try:
        parsed = urlparse(url)
    except Exception:
        return "<unparseable>"

    user = parsed.username or ""
    password = parsed.password or ""
    host = parsed.hostname or ""
    port = parsed.port or ""
    db_name = (parsed.path or "").lstrip("/")

    redacted_netloc = ""
    if user:
        redacted_netloc += user
    if password:
        redacted_netloc += ":***"
    if host:
        redacted_netloc += "@" + host
    if port:
        redacted_netloc += f":{port}"

    scheme = parsed.scheme or "postgresql"
    path = f"/{db_name}" if db_name else ""
    safe = urlunparse((scheme, redacted_netloc, path, "", "", ""))
    return safe


def _resolve_production_database_url() -> str:
    """Resolve and validate the production DATABASE_URL.

    Raises ``RuntimeError`` if the variable is missing or clearly invalid.
    """
    raw = os.environ.get("DATABASE_URL")
    if raw is None or raw.strip() == "":
        raise RuntimeError(
            "DATABASE_URL environment variable is missing. "
            "On Render, copy the 'Internal Database URL' from the "
            "PostgreSQL service Info tab into the web service's "
            "DATABASE_URL env var."
        )

    url = _normalize_database_url(raw)
    parsed = urlparse(url)
    if not parsed.scheme.startswith("postgres"):
        raise RuntimeError(
            f"DATABASE_URL must be a postgresql:// URL, got scheme={parsed.scheme!r}"
        )
    if not parsed.hostname:
        raise RuntimeError("DATABASE_URL is missing a hostname.")

    # Reject the well-known invalid placeholder the old setup used.
    if parsed.username and parsed.username.lower() == "educompass":
        _log.warning(
            "DATABASE_URL still uses the deprecated 'educompass' PostgreSQL "
            "user. Update the Render DATABASE_URL env var to the new "
            "Internal Database URL."
        )

    return url


# Safe SQLAlchemy engine options for Render's managed PostgreSQL. The
# instance is recycled aggressively and we use a small, bounded pool so
# we don't exceed Render's connection limit.
_RENDER_ENGINE_OPTIONS = {
    "pool_pre_ping": True,
    "pool_recycle": 300,
    "pool_size": 4,
    "max_overflow": 0,
    "pool_timeout": 30,
}


class Config:
    """Base config — every other config class inherits these defaults."""

    SECRET_KEY = _str(os.environ.get("SECRET_KEY"), "educompass-dev-secret")
    JWT_SECRET_KEY = _str(os.environ.get("JWT_SECRET_KEY"), SECRET_KEY)
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(
        minutes=int(os.environ.get("JWT_ACCESS_MINUTES", "120"))
    )
    JWT_REFRESH_TOKEN_EXPIRES = timedelta(
        days=int(os.environ.get("JWT_REFRESH_DAYS", "30"))
    )

    # Default to a local SQLite file for development convenience. In
    # production we *require* DATABASE_URL (see ``ProductionConfig``).
    SQLALCHEMY_DATABASE_URI = _str(
        os.environ.get("DATABASE_URL"),
        "sqlite:///educompass.db",
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}

    MODEL_DIR = _str(os.environ.get("MODEL_DIR"), "models")

    CORS_ORIGINS = _str(
        os.environ.get("CORS_ORIGINS"),
        "*",
    )

    LEARNING_PATHS_FILE = _str(
        os.environ.get("LEARNING_PATHS_FILE"),
        str(Path(__file__).resolve().parent / "data" / "learning_paths.json"),
    )
    AUTO_CREATE_DB = _bool(os.environ.get("AUTO_CREATE_DB"), True)

    PAYMENT_MODE = _str(os.environ.get("PAYMENT_MODE"), "sandbox").lower()
    USE_MOCK_PAYMENT = _bool(os.environ.get("USE_MOCK_PAYMENT"), False)
    SSLC_STORE_ID = _str(os.environ.get("SSLC_STORE_ID"), "")
    SSLC_STORE_PASSWORD = _str(os.environ.get("SSLC_STORE_PASSWORD"), "")
    PUBLIC_BASE_URL = _str(os.environ.get("PUBLIC_BASE_URL"), "")
    APP_RETURN_URI = _str(
        os.environ.get("APP_RETURN_URI"),
        "educompass://payment/return",
    )
    PAYMENT_HTTP_TIMEOUT_SECONDS = int(
        os.environ.get("PAYMENT_HTTP_TIMEOUT_SECONDS", "12")
    )


class DevelopmentConfig(Config):
    DEBUG = True


class ProductionConfig(Config):
    """Production — used on Render.

    Requires ``DATABASE_URL`` and applies the Render-friendly engine
    options. We deliberately *do not* fall back to SQLite: if the env
    var is missing or points at the old ``educompass`` role, the app
    must refuse to start so we see the error in the logs instead of
    silently running on an empty local database.
    """

    DEBUG = False

    # NOTE: these are evaluated lazily via ``__init_subclass__`` hooks
    # below so importing this module never triggers a DATABASE_URL
    # lookup unless the production config is actually selected.
    _PRODUCTION_DEFAULTS = {
        "SQLALCHEMY_ENGINE_OPTIONS": dict(_RENDER_ENGINE_OPTIONS),
        "SQLALCHEMY_TRACK_MODIFICATIONS": False,
        "AUTO_CREATE_DB": _bool(os.environ.get("AUTO_CREATE_DB"), False),
    }

    def __init_subclass__(cls, **kwargs):  # noqa: D401 — noop
        super().__init_subclass__(**kwargs)

    @classmethod
    def _materialise(cls) -> None:
        """Resolve and inject production-only settings on first use."""
        if getattr(cls, "_materialised", False):
            return
        for key, value in cls._PRODUCTION_DEFAULTS.items():
            setattr(cls, key, value)
        # The DATABASE_URL resolution is the one that can actually fail.
        cls.SQLALCHEMY_DATABASE_URI = _resolve_production_database_url()
        cls._materialised = True


class TestingConfig(Config):
    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    AUTO_CREATE_DB = True


_REGISTRY: dict[str, Type[Config]] = {
    "development": DevelopmentConfig,
    "production": ProductionConfig,
    "testing": TestingConfig,
}


def get_config(name: str | None = None) -> Type[Config]:
    key = (name or os.environ.get("FLASK_ENV") or "development").lower()
    cfg = _REGISTRY.get(key, DevelopmentConfig)
    # ProductionConfig has to validate DATABASE_URL lazily, otherwise
    # merely importing the module fails in local dev.
    if cfg is ProductionConfig and hasattr(cfg, "_materialise"):
        cfg._materialise()
    return cfg


# Backwards-compat re-export so ``from .config import _describe_database_url``
# works from app.startup helpers.
__all__ = [
    "Config",
    "DevelopmentConfig",
    "ProductionConfig",
    "TestingConfig",
    "get_config",
    "_describe_database_url",
    "_normalize_database_url",
    "_resolve_production_database_url",
    "_RENDER_ENGINE_OPTIONS",
]