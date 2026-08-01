"""Train the EduCompass v4 deployment bundle.

Output artefacts (written to ``ml/artifacts/models/v4/``):

* ``courses.parquet``         – slim courses frame, **no deployment_text**
* ``tfidf_vectorizer.joblib`` – fitted :class:`TfidfVectorizer` (max 20k feats)
* ``tfidf_matrix.npz``        – pre-computed CSR float32 TF-IDF matrix
* ``model_config.json``       – field weights / vectorizer params
* ``model_metadata.json``     – human-readable model card

Memory strategy
---------------
v3 still had to rebuild the full TF-IDF matrix from ``deployment_text``
on every Flask cold start. On Render Free that single ``transform`` call
plus the resulting CSR matrix pushed peak RSS over the 512 MiB cap.

v4 shifts that cost to training time:

  * Build the (weighted) deployment text once during this script.
  * Fit a single TfidfVectorizer (max_features=20000, float32 CSR).
  * Persist the fitted matrix to disk with
    ``scipy.sparse.save_npz(..., compressed=True)``.

At runtime the loader just ``load_npz``'s the pre-built matrix — no
``vectorizer.transform`` over the corpus happens during startup.

Weighted text recipe
--------------------
The v2 ``field_weights`` were honoured only at ranking time in the
legacy API; the v3 runtime flattened the same fields into a single
deployment string. v4 keeps that flattening here and applies the v2
weights by repeating fields a fixed number of times::

    course_name  x3
    skills       x3
    subject      x2
    description  x1.5   (rounded to x1 to keep integers)
    metadata     x0.5   (dropped — value below 1)

This matches what the v3 runtime produced, with a smaller vocab.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix, save_npz
from sklearn.feature_extraction.text import TfidfVectorizer


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "data" / "raw" / "combined_courses_app.csv"
DEFAULT_OUT_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4"


# Fields that the API surfaces through ``course_row_to_dict`` /
# ``routes.py`` directly. We deliberately keep only what the live API
# needs and drop every v3-only ranking helper.
API_COLUMNS: list[str] = [
    "course_id", "course_name", "description", "skills", "subject",
    "level", "organization", "provider", "rating", "duration",
    "instructor", "price", "language", "image_url", "url",
]


# Weighted repetition for the training-time text recipe. Values were
# taken from v2's ``field_weights`` (scaled to integers >= 1).
FIELD_REPEAT: dict[str, int] = {
    "course_name": 3,
    "skills": 3,
    "subject": 2,
    "description": 1,
    # "metadata" had weight 0.5 in v2 — omitted.
}


def _safe_str(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    s = str(value).strip()
    return s


def build_weighted_text(df: pd.DataFrame) -> list[str]:
    """Construct the deployment text used to fit the vectorizer.

    Each field is repeated ``FIELD_REPEAT[col]`` times so the resulting
    TF-IDF weights match v2's ``field_weights`` semantics.
    """
    cleaned: dict[str, list[str]] = {}
    for col in FIELD_REPEAT:
        if col not in df.columns:
            continue
        cleaned[col] = [_safe_str(v) for v in df[col].tolist()]

    n = len(df)
    out: list[str] = []
    for i in range(n):
        bits: list[str] = []
        for col, repeat in FIELD_REPEAT.items():
            cell = cleaned.get(col)
            if cell is None:
                continue
            val = cell[i]
            if val:
                # Each repetition adds an independent token so TF-IDF
                # weights scale with field importance.
                bits.extend([val] * repeat)
        out.append(" ".join(bits))
    return out


def prune_and_cast(df: pd.DataFrame) -> pd.DataFrame:
    """Keep only API columns and apply compact Parquet dtypes."""
    available = [c for c in API_COLUMNS if c in df.columns]
    slim = df[available].copy()
    slim = slim.drop_duplicates(subset=["course_id"]).reset_index(drop=True)

    if "course_id" in slim.columns:
        slim["course_id"] = pd.to_numeric(slim["course_id"], errors="coerce") \
            .fillna(0).astype("int32")
    if "rating" in slim.columns:
        slim["rating"] = pd.to_numeric(slim["rating"], errors="coerce") \
            .astype("float32")

    for col in (
        "subject", "level", "organization", "provider",
        "language", "certificate_type", "course_type",
    ):
        if col in slim.columns:
            # ``category`` with a small cardinality round-trips through
            # Parquet as Arrow dictionary encoding and stays compact.
            slim[col] = slim[col].astype("category")

    return slim


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train the v4 bundle")
    p.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    p.add_argument("--max-features", type=int, default=20000)
    p.add_argument("--min-df", type=int, default=2)
    p.add_argument("--max-df", type=float, default=0.98)
    p.add_argument("--ngram-max", type=int, default=2)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[v4] reading {args.source}", file=sys.stderr)
    df = pd.read_csv(args.source)
    print(f"[v4] raw rows: {len(df):,}", file=sys.stderr)

    slim = prune_and_cast(df)
    print(f"[v4] pruned rows: {len(slim):,}", file=sys.stderr)

    print("[v4] building weighted deployment text", file=sys.stderr)
    texts = build_weighted_text(slim)
    avg_len = sum(len(t) for t in texts) / max(len(texts), 1)
    print(f"[v4] avg deployment text length: {avg_len:.0f} chars", file=sys.stderr)

    print(f"[v4] fitting TfidfVectorizer "
          f"(max_features={args.max_features}, ngram=(1,{args.ngram_max}))",
          file=sys.stderr)
    vectorizer = TfidfVectorizer(
        stop_words="english",
        ngram_range=(1, args.ngram_max),
        max_features=args.max_features,
        min_df=args.min_df,
        max_df=args.max_df,
        sublinear_tf=True,
        dtype=np.float32,
    )
    matrix = vectorizer.fit_transform(texts)

    # CSR float32 — required by the loader; ``astype(float32)`` before
    # ``tocsr`` keeps the conversion copy-free.
    matrix = matrix.astype(np.float32, copy=False).tocsr()
    if matrix.dtype != np.float32 or not isinstance(matrix, csr_matrix):
        matrix = matrix.astype(np.float32).tocsr()

    nnz = matrix.nnz
    vocab = len(vectorizer.vocabulary_)
    sparse_bytes = (
        matrix.data.nbytes + matrix.indices.nbytes + matrix.indptr.nbytes
    )
    print(f"[v4] vocab={vocab:,} nnz={nnz:,} shape={matrix.shape} "
          f"dtype={matrix.dtype} sparse_mem={sparse_bytes/1024/1024:.1f} MB",
          file=sys.stderr)

    # Sanity: matrix rows must match the courses frame.
    assert matrix.shape[0] == len(slim), (
        f"matrix rows ({matrix.shape[0]}) != courses rows ({len(slim)})"
    )

    # ---- write artefacts --------------------------------------------------
    courses_path = out_dir / "courses.parquet"
    vec_path = out_dir / "tfidf_vectorizer.joblib"
    matrix_path = out_dir / "tfidf_matrix.npz"
    config_path = out_dir / "model_config.json"
    meta_path = out_dir / "model_metadata.json"

    slim.to_parquet(courses_path, engine="pyarrow", index=False)
    joblib.dump(vectorizer, vec_path, compress=3)
    save_npz(matrix_path, matrix, compressed=True)

    config = {
        "selected_model_version": "v4_word_tfidf_lite",
        "source_preprocessor": "tfidf_lite_v4",
        "field_weights": {
            "course_name": 3.0,
            "skills": 3.0,
            "subject": 2.0,
            "description": 1.5,
            "metadata": 0.5,
        },
        "rerank_weights": {
            "similarity_weight": 0.85,
            "popularity_weight": 0.10,
            "quality_weight": 0.05,
        },
        "number_of_courses": int(len(slim)),
        "number_of_features": int(vocab),
        "vectorizer": {
            "stop_words": "english",
            "ngram_range": [1, args.ngram_max],
            "max_features": args.max_features,
            "min_df": args.min_df,
            "max_df": args.max_df,
            "sublinear_tf": True,
            "dtype": "float32",
        },
        "required_packages": {
            "pandas": "2.2.3",
            "numpy": "1.26.4",
            "scikit_learn": "1.6.1",
            "scipy": "1.13.1",
            "joblib": "1.4.2",
            "pyarrow": "15.0.2",
        },
    }
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    metadata = {
        "model_name": "EduCompass TF-IDF Course Recommender (v4 lite)",
        "model_type": "Content-based NLP recommendation system",
        "model_version": "v4",
        "number_of_courses": int(len(slim)),
        "number_of_features": int(vocab),
        "vectorizer": "TfidfVectorizer",
        "ngram_range": [1, args.ngram_max],
        "max_features": args.max_features,
        "recommendation_methods": [
            "Natural-language query recommendation",
            "Similar-course recommendation",
        ],
    }
    meta_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print("[v4] wrote:", file=sys.stderr)
    for p in (courses_path, vec_path, matrix_path, config_path, meta_path):
        size_mb = p.stat().st_size / 1024 / 1024
        print(f"  - {p.relative_to(REPO_ROOT)}  ({size_mb:.2f} MB)",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
