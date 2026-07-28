"""Smoke test: backend package imports cleanly after the reorg.

This catches the most common regression — forgetting to convert
``from billing_service import …`` style imports to ``from .billing_service
import …`` after moving modules into the ``app/`` package.
"""

from __future__ import annotations


def test_app_factory_imports():
    from app import create_app

    app = create_app(skip_model_load=True)
    assert app is not None
    assert "educompass_model" not in app.extensions  # skipped on purpose


def test_all_modules_importable():
    import app
    import app.billing_service
    import app.config
    import app.database_models
    import app.extensions
    import app.model_loader
    import app.model_service
    import app.routes

    assert hasattr(app, "create_app")
    assert hasattr(app.billing_service, "get_billing_provider")
    assert hasattr(app.routes, "bp")