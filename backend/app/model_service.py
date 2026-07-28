"""Thin wrapper around the recommendation model loader.

The actual adapter lives in `backend/model_loader.py`. This module only
re-exposes its public names and provides route-friendly helpers
(``extract_features``, ``bounded_int``).

The new flat layout treats the v2 joblib artifacts as the source of truth —
no package-relative imports, no leftover ``app/`` prefix.
"""

from __future__ import annotations

from .model_loader import (
    BundleMeta,
    CourseRow,
    ModelLoadError,
    RecommendationModelAdapter,
    load_adapter,
)

DEFAULT_LIMIT = 20
DEFAULT_PAGE = 1
MAX_LIMIT = 50
MAX_PAGE = 500
MAX_OFFSET = 100_000
MIN_QUERY_LEN = 1
POPULAR_DEFAULT_LIMIT = 12
SIMILAR_DEFAULT_LIMIT = 6


def load_recommender(model_dir: str | None = None) -> RecommendationModelAdapter:
    """Load the bundled TF-IDF recommender.

    The loader walks ancestors for a `models/` folder or honours the
    `MODEL_DIR` env var on its own, so we just hand it through.
    """

    if model_dir:
        os.environ["MODEL_DIR"] = model_dir
    return load_adapter()


__all__ = [
    "DEFAULT_LIMIT",
    "DEFAULT_PAGE",
    "MAX_LIMIT",
    "MAX_PAGE",
    "MAX_OFFSET",
    "MIN_QUERY_LEN",
    "POPULAR_DEFAULT_LIMIT",
    "SIMILAR_DEFAULT_LIMIT",
    "BundleMeta",
    "CourseRow",
    "ModelLoadError",
    "RecommendationModelAdapter",
    "load_recommender",
]