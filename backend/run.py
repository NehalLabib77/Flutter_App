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

from app import create_app  # noqa: E402


app = create_app()


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port, debug=app.config.get("DEBUG", False))