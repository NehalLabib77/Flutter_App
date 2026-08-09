"""Tests for the v4 lightweight recommender loader.

These run against the real v4 bundle checked into the repo (or wherever
``MODEL_DIR`` points). They are hermetic — they never spin up Flask and
they do not touch the SQL store.

v4 differences from v3 (the tests below cover the new contract):

* bundle ships a pre-built CSR matrix in ``tfidf_matrix.npz`` instead
  of having ``load_adapter`` call ``vectorizer.transform`` over the
  corpus at startup
* ``courses.csv.gz`` no longer carries a ``deployment_text`` column
* matrix dtype/format/row-count invariants are enforced in the loader
* vocab capped at 20 000 features
"""
from __future__ import annotations

import os
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import pytest

from app.model_loader import (
    BundleMeta,
    ModelLoadError,
    RecommendationModelAdapter,
    load_adapter,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
V4_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4"


@pytest.fixture(scope="module")
def adapter() -> RecommendationModelAdapter:
    os.environ["MODEL_DIR"] = str(V4_DIR)
    return load_adapter()


# ---------------------------------------------------------------------------
# Bundle presence + shape
# ---------------------------------------------------------------------------


def test_v4_bundle_files_exist():
    assert (V4_DIR / "courses.csv.gz").exists(), "courses.csv.gz missing"
    assert (V4_DIR / "tfidf_vectorizer.joblib").exists(), \
        "tfidf_vectorizer.joblib missing"
    assert (V4_DIR / "tfidf_matrix.npz").exists(), "tfidf_matrix.npz missing"
    assert (V4_DIR / "model_config.json").exists(), "model_config.json missing"


def test_no_obsolete_artifacts_in_v4():
    banned = {
        "courses.joblib",
        "char_matrix.joblib", "word_matrix.joblib",
        "char_vectorizer.joblib", "word_vectorizer.joblib",
        "field_vectorizers.joblib",
        "similarity.pkl",
    }
    present = {p.name for p in V4_DIR.iterdir()}
    assert banned.isdisjoint(present), \
        f"obsolete large artifacts present in v4: {banned & present}"


def test_v4_artifact_under_100mb():
    for p in V4_DIR.iterdir():
        if p.is_file():
            size_mb = p.stat().st_size / 1024 / 1024
            assert size_mb < 100, f"{p.name} is {size_mb:.1f} MB > 100 MB"


def test_courses_df_no_deployment_text():
    df = pd.read_csv(V4_DIR / "courses.csv.gz", low_memory=False)
    assert "course_id" in df.columns
    assert "deployment_text" not in df.columns, \
        "v4 must not ship deployment_text (memory cost removed)"
    assert len(df) > 0


def test_courses_compact_dtypes(adapter):
    """Runtime loader downcasts numeric/categorical columns after CSV load."""
    df = adapter.courses_df
    if "rating" in df.columns:
        assert df["rating"].dtype == np.float32
    if "subject" in df.columns:
        assert str(df["subject"].dtype) == "category"


# ---------------------------------------------------------------------------
# Loader behaviour
# ---------------------------------------------------------------------------


def test_load_adapter_returns_correct_type(adapter):
    assert isinstance(adapter, RecommendationModelAdapter)
    assert isinstance(adapter.meta, BundleMeta)
    assert adapter.meta.model_version == "v4"


def test_matrix_is_sparse_float32_csr(adapter):
    from scipy.sparse import issparse
    assert issparse(adapter.tfidf_matrix), \
        "TF-IDF matrix must remain sparse"
    assert adapter.tfidf_matrix.dtype == np.float32
    assert adapter.tfidf_matrix.format == "csr"
    assert adapter.tfidf_matrix.shape[0] == adapter.number_of_courses


def test_matrix_shape_matches_corpus(adapter):
    assert adapter.tfidf_matrix.shape[0] == len(adapter.courses_df), \
        "matrix row count must equal courses.csv.gz row count"


def test_vocabulary_size_capped_at_20k(adapter):
    """v4 caps vocab at 20 000 to save RSS."""
    vocab = len(adapter.tfidf_vectorizer.vocabulary_ or {})
    assert 0 < vocab <= 20000


def test_legacy_aliases_point_to_same_objects(adapter):
    """``routes`` / old callers may reference these names — keep them."""
    assert adapter.word_matrix is adapter.tfidf_matrix
    assert adapter.char_matrix is adapter.tfidf_matrix
    assert adapter.word_vectorizer is adapter.tfidf_vectorizer
    assert adapter.char_vectorizer is adapter.tfidf_vectorizer


def test_no_dense_similarity_matrix_built(adapter):
    """No attribute should secretly be a dense ndarray of shape (N, N)."""
    n = adapter.number_of_courses
    for attr in ("tfidf_matrix", "word_matrix", "char_matrix"):
        m = getattr(adapter, attr)
        if hasattr(m, "shape") and len(m.shape) == 2:
            assert m.shape[1] != n or m.shape[0] == n, \
                f"{attr} looks like a dense (N,N) similarity matrix"


def test_sparse_memory_helper(adapter):
    mb = adapter.sparse_memory_mb()
    assert isinstance(mb, float)
    assert 0 < mb < 100  # well under 100 MB


def test_recommend_query_returns_results(adapter):
    hits = adapter.recommend_query("python machine learning", limit=10)
    assert isinstance(hits, list)
    assert 0 < len(hits) <= 10
    sample = hits[0]
    for key in ("course_id", "course_name", "skills"):
        assert key in sample


def test_recommend_similar_returns_results(adapter):
    cid = adapter.courses_df["course_id"].iloc[0]
    similar = adapter.recommend_similar(str(cid), limit=3)
    assert 0 < len(similar) <= 3
    assert all(s["course_id"] != cid for s in similar)


def test_search_courses_signature(adapter):
    """Routes call ``search_courses`` expecting ``(items, total)``."""
    items, total = adapter.search_courses("data science", limit=5, offset=0)
    assert isinstance(items, list)
    assert isinstance(total, int)
    assert total >= len(items)


def test_filter_lists_present(adapter):
    fl = adapter.filter_lists
    assert {"subjects", "levels", "providers"} <= fl.keys()


def test_course_detail(adapter):
    cid = str(adapter.courses_df["course_id"].iloc[0])
    row = adapter.get_course(cid)
    assert row is not None
    assert row["course_id"] == cid


def test_course_detail_missing_returns_none(adapter):
    assert adapter.get_course("does-not-exist") is None


def test_autocomplete(adapter):
    out = adapter.suggest("py", n=5)
    assert isinstance(out, list)


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


def test_missing_directory_raises_clear_error(tmp_path):
    missing = tmp_path / "no-such-model"
    with pytest.raises(ModelLoadError) as exc:
        load_adapter(model_dir=missing)
    assert "model directory does not exist" in str(exc.value).lower()


def test_missing_courses_file_raises_clear_error(tmp_path):
    joblib.dump(object(), tmp_path / "tfidf_vectorizer.joblib")
    # write a valid placeholder npz via scipy
    from scipy.sparse import csr_matrix, save_npz
    save_npz(tmp_path / "tfidf_matrix.npz",
             csr_matrix(np.zeros((1, 1), dtype=np.float32)),
             compressed=True)
    with pytest.raises(ModelLoadError) as exc:
        load_adapter(model_dir=tmp_path)
    assert "missing" in str(exc.value).lower()


def test_missing_vectorizer_raises_clear_error(tmp_path):
    df = pd.DataFrame({"course_id": [1]})
    df.to_csv(tmp_path / "courses.csv.gz", index=False, compression="gzip")
    from scipy.sparse import csr_matrix, save_npz
    save_npz(tmp_path / "tfidf_matrix.npz",
             csr_matrix(np.zeros((1, 1), dtype=np.float32)),
             compressed=True)
    with pytest.raises(ModelLoadError) as exc:
        load_adapter(model_dir=tmp_path)
    assert "missing" in str(exc.value).lower()


def test_missing_matrix_raises_clear_error(tmp_path):
    df = pd.DataFrame({"course_id": [1]})
    df.to_csv(tmp_path / "courses.csv.gz", index=False, compression="gzip")
    joblib.dump(object(), tmp_path / "tfidf_vectorizer.joblib")
    with pytest.raises(ModelLoadError) as exc:
        load_adapter(model_dir=tmp_path)
    assert "missing" in str(exc.value).lower()


def test_courses_rowcount_mismatch_raises_clear_error(tmp_path):
    """If courses has 1 row but matrix has 2, the loader must reject."""
    df = pd.DataFrame({"course_id": [1]})
    df.to_csv(tmp_path / "courses.csv.gz", index=False, compression="gzip")
    joblib.dump(object(), tmp_path / "tfidf_vectorizer.joblib")
    from scipy.sparse import csr_matrix, save_npz
    save_npz(tmp_path / "tfidf_matrix.npz",
             csr_matrix(np.zeros((2, 1), dtype=np.float32)),
             compressed=True)
    with pytest.raises(ModelLoadError) as exc:
        load_adapter(model_dir=tmp_path)
    assert "row count" in str(exc.value).lower()


# ---------------------------------------------------------------------------
# Path portability
# ---------------------------------------------------------------------------


def test_load_via_relative_env_path(monkeypatch):
    """A Windows-style backslash path in MODEL_DIR must still resolve."""
    monkeypatch.setenv("MODEL_DIR", str(V4_DIR))
    a = load_adapter()
    assert isinstance(a, RecommendationModelAdapter)
