"""Tests for the production DATABASE_URL handling and the safe
``/api/v1/health/db`` endpoint."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest


CFG_PATH = Path(__file__).resolve().parent.parent / "app" / "config.py"


def _load_config_module():
    """Import ``app/config.py`` directly so we don't trigger
    ``create_app()`` (which would try to connect to a real database)."""
    spec = importlib.util.spec_from_file_location("cfgmod_under_test", CFG_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_normalize_postgres_to_postgresql():
    cfg = _load_config_module()
    assert cfg._normalize_database_url(
        "postgres://u:p@h:5432/d"
    ) == "postgresql://u:p@h:5432/d"


def test_normalize_keeps_postgresql_psycopg2_scheme():
    cfg = _load_config_module()
    assert cfg._normalize_database_url(
        "postgresql+psycopg2://u:p@h:5432/d"
    ) == "postgresql+psycopg2://u:p@h:5432/d"


def test_describe_redacts_password():
    cfg = _load_config_module()
    assert cfg._describe_database_url(
        "postgresql://alice:supersecret@db.internal:5432/educompass"
    ) == "postgresql://alice:***@db.internal:5432/educompass"


def test_resolve_missing_raises_runtime_error(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    cfg = _load_config_module()
    with pytest.raises(RuntimeError) as exc:
        cfg._resolve_production_database_url()
    assert "DATABASE_URL" in str(exc.value)


def test_resolve_warns_on_legacy_educompass_user(monkeypatch, caplog):
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://educompass:old@db.internal:5432/educompass",
    )
    cfg = _load_config_module()
    with caplog.at_level("WARNING"):
        url = cfg._resolve_production_database_url()
    assert "postgresql://educompass" in url
    assert any("deprecated 'educompass'" in rec.message for rec in caplog.records)


def test_engine_options_match_render_defaults():
    cfg = _load_config_module()
    assert cfg._RENDER_ENGINE_OPTIONS == {
        "pool_pre_ping": True,
        "pool_recycle": 300,
        "pool_size": 4,
        "max_overflow": 0,
        "pool_timeout": 30,
    }


def test_health_db_returns_200_without_credentials(monkeypatch):
    monkeypatch.setenv("FLASK_ENV", "testing")
    # Re-import so the FLASK_ENV change is picked up.
    from app import create_app  # noqa: WPS433

    app = create_app(skip_model_load=True)
    client = app.test_client()
    resp = client.get("/api/v1/health/db")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["success"] is True
    assert body["data"]["database"] == "reachable"
    # No credentials leak into the response payload.
    raw = resp.get_data(as_text=True)
    assert "password" not in raw.lower()
    assert "educompass" not in raw  # username from default sqlite path
    assert "postgresql" not in raw.lower()