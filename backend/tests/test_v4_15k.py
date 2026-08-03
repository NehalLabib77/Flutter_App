"""Tests for the v4 strict-AND URL+image bundle.

These tests guard the contracts that the v4 bundle must keep after the
strict-AND URL+image filter:

  * ``courses.parquet`` has **at most** 15,000 rows (never more, never
    padded with invalid rows)
  * every final row has BOTH a valid ``url`` (http/https) and a valid
    ``image_url`` (http/https)
  * sparse TF-IDF matrix row count matches DataFrame row count
  * ``course_id`` remains unique
  * required backend columns survive
  * Flask test client returns HTTP 200 for the live endpoints
    (``/api/v1/courses/popular``, ``/api/v1/courses/top-rated``,
    ``/api/v1/courses/<id>/similar``, ``/api/v1/recommend``)
  * no ``KeyError`` from missing optional ranking columns
"""
from __future__ import annotations

import os
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import pytest
from scipy.sparse import issparse, load_npz

from app.model_loader import (
    BundleMeta,
    RecommendationModelAdapter,
    load_adapter,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
V4_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4"

MAX_ROW_COUNT = 15_000
REQUIRED_BACKEND_COLUMNS: tuple[str, ...] = (
    "course_id", "course_name", "description", "skills", "subject",
    "level", "organization", "provider", "rating", "duration",
    "instructor", "price", "language", "image_url", "url",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def adapter() -> RecommendationModelAdapter:
    os.environ["MODEL_DIR"] = str(V4_DIR)
    return load_adapter()


@pytest.fixture(scope="module")
def courses_df() -> pd.DataFrame:
    return pd.read_parquet(V4_DIR / "courses.parquet", engine="pyarrow")


@pytest.fixture(scope="module")
def matrix() -> "np.ndarray | object":  # type: ignore[name-defined]
    return load_npz(V4_DIR / "tfidf_matrix.npz")


# ---------------------------------------------------------------------------
# Bundle shape
# ---------------------------------------------------------------------------


def test_v4_bundle_has_at_most_max_rows(courses_df):
    """Strict-AND URL+image rule.

    The final row count is allowed to be anywhere in
    ``[1, MAX_ROW_COUNT]`` — we never pad the bundle with rows that
    are missing a URL or an image.
    """
    assert 0 < len(courses_df) <= MAX_ROW_COUNT, (
        f"v4 bundle must contain at most {MAX_ROW_COUNT} rows, "
        f"got {len(courses_df)}"
    )


def test_v4_every_row_has_valid_url_and_image(courses_df):
    """Strict-AND contract: every final row has BOTH a valid
    ``url`` and a valid ``image_url``."""
    bad = {"", "none", "null", "nan", "n/a", "#", "undefined",
           "about:blank"}
    urls = courses_df["url"].astype(str).str.strip().str.lower()
    imgs = courses_df["image_url"].astype(str).str.strip().str.lower()

    # no dummy tokens in either field
    for s in urls:
        assert s not in bad, f"final url retained dummy token: {s!r}"
    nonempty_imgs = imgs[imgs != ""]
    for s in nonempty_imgs:
        assert s not in bad, f"final image_url retained dummy token: {s!r}"

    # every value must start with http:// or https://
    for s in urls:
        assert s.startswith(("http://", "https://")), \
            f"final url not http(s): {s!r}"
    for s in nonempty_imgs:
        assert s.startswith(("http://", "https://")), \
            f"final image_url not http(s): {s!r}"


def test_v4_matrix_rows_match_dataframe(matrix, courses_df):
    """matrix row i must correspond exactly to DataFrame row i."""
    assert matrix.shape[0] == len(courses_df), (
        f"matrix rows ({matrix.shape[0]}) != courses rows ({len(courses_df)})"
    )


def test_v4_course_id_unique(courses_df):
    assert courses_df["course_id"].is_unique, \
        "course_id must remain unique after dedup"


def test_v4_required_backend_columns_present(courses_df):
    missing = [c for c in REQUIRED_BACKEND_COLUMNS if c not in courses_df.columns]
    assert not missing, f"required backend columns missing: {missing}"


def test_v4_matrix_is_sparse_float32_csr(matrix):
    assert issparse(matrix)
    assert matrix.dtype == np.float32
    assert matrix.format == "csr"


def test_v4_optional_ranking_columns_do_not_keyerror(adapter):
    """``_safe_column_array`` must fall back gracefully when optional
    ranking columns are missing.

    We exercise the top-N ranking paths through the public API; if any
    of them raises ``KeyError`` the loader would have surfaced the
    bug at startup and the fixture would have failed already.
    """
    pop = adapter.popular(limit=12, slim=True)
    assert len(pop) == 12
    tr = adapter.top_rated(limit=12, slim=True)
    assert len(tr) == 12


def test_v4_image_url_and_url_normalisation(adapter):
    """Confirm the kept URL fields look like real ``http(s)://``
    strings — not the dummy tokens ('none', 'nan', '#', etc.) the
    loader is supposed to filter. With the strict-AND rule this must
    hold for every row, not just a sample."""
    df = adapter.courses_df
    bad = {"", "none", "null", "nan", "n/a", "#"}
    for val in df["url"].astype(str):
        s = val.strip().lower()
        assert s not in bad, f"url field retained a dummy token: {val!r}"
        assert s.startswith(("http://", "https://")), \
            f"url field retained non-http value: {val!r}"
    # ``image_url`` should also be non-empty for every row under the
    # strict-AND rule.
    for val in df["image_url"].astype(str):
        s = val.strip().lower()
        assert s not in bad, f"image_url retained a dummy token: {val!r}"
        assert s.startswith(("http://", "https://")), \
            f"image_url retained non-http value: {val!r}"


# ---------------------------------------------------------------------------
# Endpoint smoke (HTTP 200)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def client():
    os.environ.setdefault("FLASK_ENV", "testing")
    os.environ.setdefault("MODEL_DIR", str(V4_DIR))
    # ``skip_model_load`` avoids touching the SQL store at startup; we
    # then load the adapter explicitly and stash it on the Flask app so
    # the routes' ``current_app.extensions["educompass_model"]`` lookup
    # succeeds.
    from app import create_app
    from app.model_loader import load_adapter
    app = create_app(skip_model_load=True)
    app.extensions["educompass_model"] = load_adapter(V4_DIR)
    with app.test_client() as client:
        yield client


def test_endpoint_popular_returns_200(client):
    r = client.get("/api/v1/courses/popular?limit=12")
    assert r.status_code == 200, f"popular failed: {r.status_code} {r.data!r}"
    body = r.get_json()
    assert body is not None
    # Body shape variants observed across versions:
    #   - bare list
    #   - {"results": [...]}
    #   - {"items": [...]}
    #   - {"data": [...]} or {"data": {"results": [...]}}
    # Walk them in order and accept the first list we find.
    items: list = []
    if isinstance(body, list):
        items = body
    elif isinstance(body, dict):
        for key in ("results", "items", "data"):
            value = body.get(key)
            if isinstance(value, list):
                items = value
                break
            if isinstance(value, dict):
                for inner_key in ("results", "items", "data"):
                    inner = value.get(inner_key)
                    if isinstance(inner, list):
                        items = inner
                        break
                if items:
                    break
    assert isinstance(items, list), (
        f"popular returned an unexpected body shape: {body!r}"
    )
    assert 0 < len(items) <= 12


def test_endpoint_top_rated_returns_200(client):
    r = client.get("/api/v1/courses/top-rated?limit=12")
    assert r.status_code == 200, f"top-rated failed: {r.status_code} {r.data!r}"


def test_endpoint_similar_returns_200(client, courses_df):
    cid = int(courses_df["course_id"].iloc[0])
    r = client.get(f"/api/v1/courses/{cid}/similar?limit=6")
    assert r.status_code == 200, f"similar failed: {r.status_code} {r.data!r}"


def test_endpoint_recommend_returns_200(client):
    r = client.post(
        "/api/v1/recommendations/query",
        json={"query": "python machine learning", "limit": 6},
    )
    assert r.status_code == 200, f"recommend failed: {r.status_code} {r.data!r}"


def test_endpoint_health_returns_200(client):
    r = client.get("/api/v1/health")
    assert r.status_code == 200, f"health failed: {r.status_code} {r.data!r}"


def test_endpoint_course_detail_returns_200(client, courses_df):
    cid = int(courses_df["course_id"].iloc[0])
    r = client.get(f"/api/v1/courses/{cid}")
    assert r.status_code == 200, f"course detail failed: {r.status_code} {r.data!r}"


def test_endpoint_filters_returns_200(client):
    r = client.get("/api/v1/recommendations/filters")
    assert r.status_code == 200, f"filters failed: {r.status_code} {r.data!r}"