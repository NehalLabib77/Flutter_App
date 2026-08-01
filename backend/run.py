"""Backend entry point.

Run with ``python backend/run.py`` (from the repo root) or
``python run.py`` (from inside ``backend/``).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


# Make the ``backend`` package importable when this file is invoked directly
# from the repo root (``python backend/run.py``).
BACKEND_ROOT = Path(__file__).resolve().parent
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app import app as flask_app  # noqa: E402  (imported for side effects; sets up routes + loads model)

# `app` must be the symbol Gunicorn imports. Reuse the module-level
# instance created when ``app/__init__.py`` was first imported so the
# recommendation model is loaded exactly **once** per worker.
app = flask_app
# ``create_app`` is exposed for the unit-test suite and ``python run.py``
# direct usage; both flows import the same factory.
__all__ = ["app", "create_app"]  # noqa: F401

try:
    from app import create_app  # noqa: F401,E402  -- available for direct scripts/tests
except ImportError:  # pragma: no cover
    pass


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port, debug=app.config.get("DEBUG", False))