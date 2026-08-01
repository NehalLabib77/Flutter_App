"""Train the lightweight EduCompass v3 recommender bundle.

Output artefacts (written to ``ml/artifacts/models/v3/``):

* ``courses.parquet``         – slim courses frame (API + ranking columns)
* ``tfidf_vectorizer.joblib`` – fitted :class:`TfidfVectorizer`
* ``model_config.json``       – field weights / rerank weights
* ``model_metadata.json``     – human-readable model card

Note: the courses frame is persisted as **Parquet**, not joblib, so the
deployment environment's pandas version (currently 2.2.3 on Render) can
read it regardless of the pandas version used at training time.

The full TF-IDF matrix is **not** saved. The deployment loader builds it
once at startup with ``vectorizer.transform(deployment_text)`` so we only
carry the vectorizer + corpus text at boot.

Recipe notes
------------
The deployment text follows exactly the formula used by the runtime
loader (see ``backend/app/model_loader.py::_safe_text`` join):

    course_name + ' ' + description + ' ' + skills + ' ' + subject

Field weights from ``model_config.json`` (``v2``) are honoured at
*ranking* time by the API layer (see the legacy adapter); the vectorizer
ingests the flat deployment text only — matching what the existing v2
loader did at request time.

Usage::

    python ml/training/train_v3.py
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
from sklearn.feature_extraction.text import TfidfVectorizer


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "data" / "raw" / "combined_courses_app.csv"
DEFAULT_OUT_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v3"


# Columns the API actually returns (from ``course_row_to_dict``).
API_OUTPUT_COLUMNS = [
    "course_id", "course_name", "description", "skills", "subject",
    "level", "organization", "provider", "rating", "reviews_count",
    "students_enrolled", "lectures_count", "duration", "instructor",
    "price", "language", "image_url", "url", "certificate_type",
    "course_type",
]

# Extra columns the adapter uses for ranking / filtering.
RANKING_COLUMNS = [
    "is_free", "has_image", "has_course_url",
    "popularity_score", "data_quality_score",
    "students_for_ranking", "reviews_for_ranking",
    "nlp_level", "nlp_language", "nlp_certificate_type", "nlp_course_type",
]

KEEP_COLUMNS = list(dict.fromkeys(API_OUTPUT_COLUMNS + RANKING_COLUMNS))


INT_COLUMNS = [
    "reviews_count", "students_enrolled", "lectures_count",
]
BOOL_INT8_COLUMNS = ["is_free", "has_image", "has_course_url"]
FLOAT32_COLUMNS = [
    "rating",
    "popularity_score", "data_quality_score",
    "students_for_ranking", "reviews_for_ranking",
]
CATEGORY_COLUMNS = [
    "subject", "level", "organization", "provider",
    "nlp_level", "nlp_language", "nlp_certificate_type", "nlp_course_type",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _safe_str(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value).strip()


def build_deployment_text(df: pd.DataFrame) -> pd.Series:
    """Reproduce the runtime text-building formula (see model_loader)."""
    return (
        df["course_name"].map(_safe_str) + " "
        + df["description"].map(_safe_str) + " "
        + df["skills"].map(_safe_str) + " "
        + df["subject"].map(_safe_str)
    ).str.replace(r"\s+", " ", regex=True).str.strip()


def load_courses_frame(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    must_have = {"course_id", "course_name", "description", "skills",
                 "subject", "level", "organization", "provider", "rating"}
    missing_real = [c for c in must_have if c not in df.columns]
    if missing_real:
        raise SystemExit(
            f"Source CSV {csv_path} is missing required columns: "
            f"{missing_real}"
        )
    return df


def prune_and_cast(df: pd.DataFrame) -> pd.DataFrame:
    """Keep only API + ranking columns and use compact dtypes."""
    available = [c for c in KEEP_COLUMNS if c in df.columns]
    slim = df[available].copy()

    # Strip duplicate rows just in case the source CSV has any.
    slim = slim.drop_duplicates(subset=["course_id"]).reset_index(drop=True)

    # Cast integers where safe.
    for col in INT_COLUMNS:
        if col in slim.columns:
            slim[col] = (
                pd.to_numeric(slim[col], errors="coerce")
                .fillna(0)
                .astype("int32")
            )
    for col in BOOL_INT8_COLUMNS:
        if col in slim.columns:
            slim[col] = (
                pd.to_numeric(slim[col], errors="coerce")
                .fillna(0)
                .astype("int8")
            )
    for col in FLOAT32_COLUMNS:
        if col in slim.columns:
            slim[col] = (
                pd.to_numeric(slim[col], errors="coerce")
                .astype("float32")
            )
    for col in CATEGORY_COLUMNS:
        if col in slim.columns:
            slim[col] = slim[col].astype("category")
    return slim



# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train the v3 bundle")
    p.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                   help="Source combined CSV")
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR,
                   help="Output bundle directory")
    p.add_argument("--max-features", type=int, default=30000)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[v3] reading courses from {args.source}", file=sys.stderr)
    df = load_courses_frame(args.source)
    print(f"[v3] raw courses: {len(df):,} rows", file=sys.stderr)

    slim = prune_and_cast(df)
    slim["deployment_text"] = build_deployment_text(slim)
    print(f"[v3] pruned courses: {len(slim):,} rows, "
          f"{slim.memory_usage(deep=True).sum() / 1024 / 1024:.1f} MB resident",
          file=sys.stderr)

    print(f"[v3] fitting TF-IDF (max_features={args.max_features})",
          file=sys.stderr)
    vectorizer = TfidfVectorizer(
        stop_words="english",
        ngram_range=(1, 2),
        max_features=args.max_features,
        min_df=2,
        max_df=0.95,
        sublinear_tf=True,
        dtype=np.float32,
        lowercase=True,
        token_pattern=r"(?u)\b[a-zA-Z][a-zA-Z]+\b",
    )
    matrix = vectorizer.fit_transform(slim["deployment_text"])
    vocab_size = len(vectorizer.vocabulary_)
    nnz = matrix.nnz
    sparse_bytes = (
        matrix.data.nbytes + matrix.indices.nbytes + matrix.indptr.nbytes
    )
    print(f"[v3]   vocab: {vocab_size:,}  nnz: {nnz:,}  "
          f"shape: {matrix.shape}  dtype: {matrix.dtype}  "
          f"sparse mem: {sparse_bytes / 1024 / 1024:.1f} MB",
          file=sys.stderr)

    # ---- write artefacts ------------------------------------------------
    courses_path = out_dir / "courses.parquet"
    vec_path = out_dir / "tfidf_vectorizer.joblib"
    config_path = out_dir / "model_config.json"
    meta_path = out_dir / "model_metadata.json"

    # Parquet preserves Arrow types and is decoupled from the pandas
    # version on the reader side (unlike ``joblib.dump(df)``, which
    # embeds the writer's pandas ``StringDtype`` pickle layout).
    slim.to_parquet(courses_path, engine="pyarrow", index=False)
    joblib.dump(vectorizer, vec_path, compress=3)

    config = {
        "selected_model_version": "v3_word_tfidf_lite",
        "source_preprocessor": "tfidf_lite_v3",
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
        "number_of_features": int(vocab_size),
        "vectorizer": {
            "stop_words": "english",
            "ngram_range": [1, 2],
            "max_features": args.max_features,
            "min_df": 2,
            "max_df": 0.95,
            "sublinear_tf": True,
            "dtype": "float32",
        },
        "required_packages": {
            "pandas": pd.__version__,
            "numpy": np.__version__,
            "scikit_learn": "1.6.1",
            "joblib": joblib.__version__,
        },
    }
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    metadata = {
        "model_name": "EduCompass TF-IDF Course Recommender (v3 lite)",
        "model_type": "Content-based NLP recommendation system",
        "model_version": "v3",
        "number_of_courses": int(len(slim)),
        "number_of_features": int(vocab_size),
        "vectorizer": "TfidfVectorizer",
        "ngram_range": [1, 2],
        "max_features": args.max_features,
        "recommendation_methods": [
            "Natural-language query recommendation",
            "Similar-course recommendation",
        ],
    }
    meta_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    # ---- summary --------------------------------------------------------
    print("[v3] wrote:", file=sys.stderr)
    for p in (courses_path, vec_path, config_path, meta_path):
        size_mb = p.stat().st_size / 1024 / 1024
        print(f"  - {p.relative_to(REPO_ROOT)}  ({size_mb:.2f} MB)",
              file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
