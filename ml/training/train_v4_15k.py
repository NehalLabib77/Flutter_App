"""Train the lightweight EduCompass v4 deployment bundle.

The canonical input is ``data/processed/educompass_courses.csv`` (21 course
fields).  The runtime architecture stays unchanged: a single word TF-IDF
vectorizer plus a precomputed CSR float32 matrix.  Hybrid personalization is a
ranking layer in Flask and therefore reuses these exact content vectors instead
of training a second heavy model.

Only courses with both a valid course URL and a valid image URL are deployed to
the mobile catalogue.  The full 21-column CSV remains in ``data/processed``.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix, save_npz
from sklearn.feature_extraction.text import TfidfVectorizer

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "data" / "processed" / "educompass_courses.csv"
DEFAULT_OUT_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4"
TARGET_MAX_ROW_COUNT = 15_000

COURSE_SCHEMA = [
    "course_id", "course_name", "description", "skills", "subject", "level",
    "organization", "provider", "rating", "reviews_count", "students_enrolled",
    "lectures_count", "duration", "instructor", "price", "language",
    "image_url", "url", "certificate_type", "course_type", "source_file",
]

API_COLUMNS = COURSE_SCHEMA + [
    "popularity_score", "data_quality_score", "is_free", "has_image",
    "has_course_url",
]

# Requested content recipe. Provider/organization remain in the model at a low
# weight; because all app-facing rows are branded EduCompass, max_df naturally
# removes globally constant tokens from the vocabulary.
FIELD_REPEAT: dict[str, int] = {
    "course_name": 4,
    "skills": 4,
    "subject": 3,
    "description": 2,
    "level": 2,
    "course_type": 1,
    "certificate_type": 1,
    "organization": 1,
    "provider": 1,
    "instructor": 1,
}

INVALID_URL_TOKENS = {
    "", "none", "null", "nan", "n/a", "#", "-", "not found", "n.a.",
    "undefined", "about:blank",
}
_URL_RE = re.compile(r"^https?://", re.IGNORECASE)


def _safe_str(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return ""
    return str(value).strip()


def _url_token(value: object) -> str:
    s = _safe_str(value).casefold()
    return "" if s in INVALID_URL_TOKENS else s


def is_valid_url(value: object) -> bool:
    s = _url_token(value)
    return bool(s and _URL_RE.match(s))


def normalised_url(value: object) -> str:
    s = _url_token(value)
    if not s:
        return ""
    s = re.sub(r"#.*$", "", s)
    s = re.sub(r"([?&])utm_[^=&]+=[^&]*", r"\1", s)
    s = re.sub(r"[?&]+$", "", s)
    return re.sub(r"/+$", "", s)


def normalised_name_source(name: object, source: object) -> str:
    n = re.sub(r"\s+", " ", _safe_str(name).casefold())
    src = re.sub(r"\s+", " ", _safe_str(source).casefold())
    return f"{n}::{src}"


def _is_free(price: object, course_type: object = "") -> bool:
    text = _safe_str(price).casefold()
    ctype = _safe_str(course_type).casefold()
    if "free" in ctype:
        return True
    if text in {"free", "0", "0.0", "0.00", "$0", "bdt 0"}:
        return True
    if "free" in text and "not free" not in text:
        return True
    # Numeric-only zero prices.
    cleaned = re.sub(r"[^0-9.\-]", "", text)
    if cleaned:
        try:
            return float(cleaned) == 0.0
        except ValueError:
            pass
    return False


def _log_norm(values: pd.Series) -> np.ndarray:
    arr = pd.to_numeric(values, errors="coerce").fillna(0).clip(lower=0).to_numpy(dtype=np.float32)
    if arr.size == 0:
        return arr
    transformed = np.log1p(arr)
    max_v = float(transformed.max()) if transformed.size else 0.0
    if max_v <= 0:
        return np.zeros_like(transformed, dtype=np.float32)
    return (transformed / max_v).astype(np.float32)


def add_ranking_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    reviews = _log_norm(out["reviews_count"])
    students = _log_norm(out["students_enrolled"])
    rating = pd.to_numeric(out["rating"], errors="coerce").fillna(0).clip(0, 5).to_numpy(dtype=np.float32) / 5.0
    out["popularity_score"] = (0.65 * students + 0.35 * reviews).astype(np.float32)

    desc_ok = out["description"].fillna("").astype(str).str.len().clip(upper=1200).to_numpy(dtype=np.float32) / 1200.0
    skills = out["skills"].fillna("").astype(str)
    skill_count = (skills.str.count(",") + 1).where(skills.str.strip().ne(""), 0).clip(upper=12).to_numpy(dtype=np.float32) / 12.0
    out["data_quality_score"] = (
        0.55 * rating + 0.15 * reviews + 0.10 * students + 0.10 * desc_ok + 0.10 * skill_count
    ).astype(np.float32)
    out["is_free"] = [
        _is_free(p, t) for p, t in zip(out["price"], out["course_type"])
    ]
    return out


def build_weighted_text(df: pd.DataFrame) -> list[str]:
    columns = {
        col: [_safe_str(v) for v in df[col].tolist()]
        for col in FIELD_REPEAT if col in df.columns
    }
    texts: list[str] = []
    for i in range(len(df)):
        parts: list[str] = []
        for col, repeat in FIELD_REPEAT.items():
            vals = columns.get(col)
            if vals is None:
                continue
            value = vals[i]
            if value:
                parts.extend([value] * repeat)
        texts.append(" ".join(parts))
    return texts


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train EduCompass v4 TF-IDF bundle")
    p.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    p.add_argument("--max-rows", type=int, default=TARGET_MAX_ROW_COUNT)
    p.add_argument("--max-features", type=int, default=20_000)
    p.add_argument("--min-df", type=int, default=2)
    p.add_argument("--max-df", type=float, default=0.98)
    p.add_argument("--ngram-max", type=int, default=2)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    df = pd.read_csv(args.source, low_memory=False)
    missing = [c for c in COURSE_SCHEMA if c not in df.columns]
    if missing:
        raise SystemExit(f"Training data is missing fields: {missing}")
    print(f"[v4] source: {args.source}", file=sys.stderr)
    print(f"[v4] rows before filter: {len(df):,}", file=sys.stderr)

    # Normalise numeric fields without fabricating engagement counts.
    for col in ("rating", "reviews_count", "students_enrolled", "lectures_count"):
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    df["rating"] = df["rating"].clip(0, 5)
    for col in ("reviews_count", "students_enrolled", "lectures_count"):
        df[col] = df[col].clip(lower=0)

    df["has_image"] = df["image_url"].apply(is_valid_url).astype(bool)
    df["has_course_url"] = df["url"].apply(is_valid_url).astype(bool)
    df = add_ranking_columns(df)
    print(f"[v4] valid URL + image: {(df['has_image'] & df['has_course_url']).sum():,}", file=sys.stderr)

    # Preserve current strict product rule.
    df = df[df["has_image"] & df["has_course_url"]].copy()
    df["_norm_url"] = df["url"].apply(normalised_url)
    df["_norm_name_source"] = [
        normalised_name_source(n, s)
        for n, s in zip(df["course_name"], df["source_file"])
    ]

    # Stable IDs and URLs are authoritative.  Name+source catches scraper
    # duplicates without accidentally collapsing same-title courses from two
    # different original catalogues after provider was branded EduCompass.
    df = df.sort_values(["data_quality_score", "rating"], ascending=False)
    df = df.drop_duplicates(subset=["course_id"], keep="first")
    df = df.drop_duplicates(subset=["_norm_url"], keep="first")
    df = df.drop_duplicates(subset=["_norm_name_source"], keep="first")

    if len(df) > args.max_rows:
        df = df.sort_values(
            ["data_quality_score", "popularity_score", "rating"],
            ascending=False,
        ).head(args.max_rows)
    df = df.reset_index(drop=True)
    print(f"[v4] deployment rows after dedupe: {len(df):,}", file=sys.stderr)

    final = df[[c for c in API_COLUMNS if c in df.columns]].copy()
    final["course_id"] = final["course_id"].astype(str)
    final["rating"] = pd.to_numeric(final["rating"], errors="coerce").fillna(0).astype("float32")
    final["popularity_score"] = final["popularity_score"].astype("float32")
    final["data_quality_score"] = final["data_quality_score"].astype("float32")
    for col in ("reviews_count", "students_enrolled", "lectures_count"):
        final[col] = pd.to_numeric(final[col], errors="coerce").fillna(0).astype("int32")
    for col in ("subject", "level", "organization", "provider", "language", "certificate_type", "course_type"):
        final[col] = final[col].astype("category")
    final["is_free"] = final["is_free"].astype(bool)
    final["has_image"] = final["has_image"].astype(bool)
    final["has_course_url"] = final["has_course_url"].astype(bool)

    texts = build_weighted_text(final)
    vectorizer = TfidfVectorizer(
        stop_words="english",
        ngram_range=(1, args.ngram_max),
        max_features=args.max_features,
        min_df=args.min_df,
        max_df=args.max_df,
        sublinear_tf=True,
        dtype=np.float32,
    )
    matrix = vectorizer.fit_transform(texts).astype(np.float32, copy=False).tocsr()
    assert isinstance(matrix, csr_matrix)
    assert matrix.shape[0] == len(final)

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    # Compressed CSV keeps deployment portable and removes the pyarrow runtime dependency.
    final.to_csv(out_dir / "courses.csv.gz", index=False, compression="gzip")
    joblib.dump(vectorizer, out_dir / "tfidf_vectorizer.joblib", compress=3)
    save_npz(out_dir / "tfidf_matrix.npz", matrix, compressed=True)

    config = {
        "selected_model_version": "v4_word_tfidf_hybrid_ready",
        "source_preprocessor": "educompass_21_column_catalog",
        "number_of_courses": int(len(final)),
        "number_of_features": int(matrix.shape[1]),
        "max_row_count": int(args.max_rows),
        "filter_policy": {
            "rule": "strict_AND",
            "require_valid_course_url": True,
            "require_valid_image_url": True,
        },
        "field_weights": {k: float(v) for k, v in FIELD_REPEAT.items()},
        "hybrid_ranking": {
            "active_user": {
                "content": 0.45,
                "behavior": 0.20,
                "preferences": 0.15,
                "quality": 0.10,
                "popularity": 0.10,
            },
            "cold_start": {
                "content": 0.45,
                "preferences": 0.20,
                "quality": 0.20,
                "popularity": 0.15,
            },
        },
        "interaction_weights": {
            "view": 1.0,
            "click": 1.0,
            "favorite": 3.0,
            "enroll": 5.0,
            "complete": 7.0,
            "rating_positive": 5.0,
            "dislike": -3.0,
        },
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
        },
    }
    (out_dir / "model_config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    metadata = {
        "model_name": "EduCompass TF-IDF + Hybrid Ranking v4",
        "model_type": "Content vectors with preference/behavior hybrid reranking",
        "model_version": "v4",
        "number_of_courses": int(len(final)),
        "number_of_features": int(matrix.shape[1]),
        "training_source": str(args.source.relative_to(REPO_ROOT)) if args.source.is_relative_to(REPO_ROOT) else str(args.source),
        "provider": "EduCompass",
        "organization": "EduCompass",
        "course_schema_columns": COURSE_SCHEMA,
    }
    (out_dir / "model_metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    sparse_mb = (matrix.data.nbytes + matrix.indices.nbytes + matrix.indptr.nbytes) / 1024 / 1024
    print(f"[v4] matrix={matrix.shape} nnz={matrix.nnz:,} sparse={sparse_mb:.1f} MB", file=sys.stderr)
    print(f"[v4] wrote bundle to {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
