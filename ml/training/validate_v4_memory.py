"""Standalone memory validation for the v4 bundle.

Run with::

    python ml/training/validate_v4_memory.py

Reports peak RSS, dataframe deep memory, sparse-matrix memory, course
count, matrix shape/dtype, and vocabulary size. Does **not** start
Flask. Requires ``psutil`` which is already in the dev requirements;
the production runtime intentionally does not depend on it.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MODEL_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4"


def main() -> int:
    model_dir = Path(os.environ.get("MODEL_DIR", str(DEFAULT_MODEL_DIR)))
    print(f"[mem] MODEL_DIR = {model_dir}", file=sys.stderr)

    import psutil

    proc = psutil.Process(os.getpid())
    rss_before_mb = proc.memory_info().rss / 1024 / 1024
    print(f"[mem] rss_before = {rss_before_mb:.1f} MB", file=sys.stderr)

    # Heavy imports happen here (pandas / scipy / sklearn). Measure now
    # so the report reflects what the production worker pays.
    import joblib
    import numpy as np
    import pandas as pd
    from scipy.sparse import issparse, load_npz

    rss_after_imports_mb = proc.memory_info().rss / 1024 / 1024
    print(f"[mem] rss_after_imports = {rss_after_imports_mb:.1f} MB",
          file=sys.stderr)

    courses_path = model_dir / "courses.parquet"
    matrix_path = model_dir / "tfidf_matrix.npz"
    vec_path = model_dir / "tfidf_vectorizer.joblib"
    for p in (courses_path, matrix_path, vec_path):
        if not p.exists():
            print(f"[mem] MISSING: {p}", file=sys.stderr)
            return 1

    df = pd.read_parquet(courses_path, engine="pyarrow")
    matrix = load_npz(matrix_path)
    if matrix.format != "csr":
        matrix = matrix.tocsr()
    if matrix.dtype != np.float32:
        matrix = matrix.astype(np.float32)
    vectorizer = joblib.load(vec_path)

    rss_after_load_mb = proc.memory_info().rss / 1024 / 1024

    df_mb = df.memory_usage(deep=True).sum() / 1024 / 1024
    sparse_bytes = (
        matrix.data.nbytes + matrix.indices.nbytes + matrix.indptr.nbytes
    )
    sparse_mb = sparse_bytes / 1024 / 1024
    vocab = len(getattr(vectorizer, "vocabulary_", {}) or {})

    report = {
        "model_dir": str(model_dir),
        "model_version": "v4",
        "courses": int(len(df)),
        "matrix_shape": list(matrix.shape),
        "matrix_dtype": str(matrix.dtype),
        "matrix_format": matrix.format,
        "matrix_nnz": int(matrix.nnz),
        "matrix_memory_mb": round(sparse_mb, 2),
        "dataframe_memory_mb": round(df_mb, 2),
        "vocabulary_size": int(vocab),
        "rss_before_mb": round(rss_before_mb, 2),
        "rss_after_imports_mb": round(rss_after_imports_mb, 2),
        "rss_after_load_mb": round(rss_after_load_mb, 2),
        "rss_increase_mb": round(rss_after_load_mb - rss_before_mb, 2),
        "course_id_dtype": str(df["course_id"].dtype) if "course_id" in df.columns else None,
    }
    print(json.dumps(report, indent=2))
    if rss_after_load_mb > 400:
        print(
            f"[mem] WARNING: rss_after_load = {rss_after_load_mb:.1f} MB "
            "exceeds the 400 MB pre-Flask target.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
