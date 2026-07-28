"""Configuration loaded from environment variables."""

from __future__ import annotations

import os
from datetime import timedelta
from pathlib import Path
from typing import Type


def _bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _str(value: str | None, default: str) -> str:
    return default if value is None or value == "" else value


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

    BILLING_PROVIDER = _str(os.environ.get("BILLING_PROVIDER"), "mock")
    BILLING_OTP_TTL_SECONDS = int(os.environ.get("BILLING_OTP_TTL_SECONDS", "300"))
    BILLING_OTP_RESEND_SECONDS = int(
        os.environ.get("BILLING_OTP_RESEND_SECONDS", "30")
    )
    BILLING_OTP_MAX_ATTEMPTS = int(
        os.environ.get("BILLING_OTP_MAX_ATTEMPTS", "5")
    )

    BDAPPS_BASE_URL = _str(
        os.environ.get("BDAPPS_BASE_URL"), "https://api.example.com"
    )
    BDAPPS_API_KEY = _str(os.environ.get("BDAPPS_API_KEY"), "")
    BDAPPS_CLIENT_ID = _str(os.environ.get("BDAPPS_CLIENT_ID"), "")
    BDAPPS_OTP_PATH = _str(os.environ.get("BDAPPS_OTP_PATH"), "/otp")
    BDAPPS_VERIFY_PATH = _str(os.environ.get("BDAPPS_VERIFY_PATH"), "/otp/verify")

    LEARNING_PATHS_FILE = _str(
        os.environ.get("LEARNING_PATHS_FILE"),
        str(Path(__file__).resolve().parent / "data" / "learning_paths.json"),
    )
    AUTO_CREATE_DB = _bool(os.environ.get("AUTO_CREATE_DB"), True)


class DevelopmentConfig(Config):
    DEBUG = True


class ProductionConfig(Config):
    DEBUG = False


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
    return _REGISTRY.get(key, DevelopmentConfig)


__all__ = [
    "Config",
    "DevelopmentConfig",
    "ProductionConfig",
    "TestingConfig",
    "get_config",
]