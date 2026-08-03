"""Rebuild the EduCompass v4 bundle under the strict-AND URL+image rule.

Goal
----
The previous v4 bundle retained ~15,000 courses using a tiered fallback
that filled missing slots with courses that had only a valid URL **or**
only a valid image. That violated the strict product rule:

  A course is eligible only when ``has_valid_course_url`` AND
  ``has_valid_image_url`` are both True.

This script:

  1. Loads the raw CSV from ``data/raw/combined_courses_app.csv``.
  2. Auto-detects URL and image columns and computes
     ``has_valid_course_url`` / ``has_valid_image_url`` flags using the
     strict invalid-token set::

         {null, NaN, None, "", whitespace, "none", "null", "nan",
          "n/a", "#", "undefined", "about:blank", values not starting
          with http:// or https://}

  3. Prints the before-filter inventory (original rows, both-valid,
     url-only, image-only, neither, duplicate counts).
  4. Drops every row whose URL or image is invalid — **strict AND**.
  5. Deduplicates by ``course_id`` → normalised URL → normalised
     (course_name + provider).
  6. Sorts and (if needed) trims to **at most 15,000** rows by ranking
     on ``popularity_score`` → ``rating`` → ``reviews_count`` →
     ``students_enrolled`` → description / skills completeness. If the
     eligible pool is smaller than 15,000, all valid rows are kept —
     we never pad with invalid rows.
  7. Refits the TF-IDF vectorizer on the deployment text and saves a
     CSR float32 matrix. Matrix row ``i`` corresponds exactly to
     DataFrame row ``i``.
  8. Writes the resulting bundle to ``ml/artifacts/models/v4/`` and
     backs up the previous bundle under
     ``ml/artifacts/models/v4_backup_before_15k/`` (excluded from Git).

Public API contract (route URLs, JSON shape) is NOT modified — the
loader in ``backend/app/model_loader.py`` continues to work because
``courses.parquet`` retains the same column names and the matrix
remains CSR float32.

Run with::

    python ml/training/train_v4_15k.py
"""
from __future__ import annotations

import argparse
import gc
import json
import math
import re
import shutil
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
BACKUP_DIR = REPO_ROOT / "ml" / "artifacts" / "models" / "v4_backup_before_15k"

TARGET_MAX_ROW_COUNT = 15_000  # upper bound; never a hard target


# ---------------------------------------------------------------------------
# Column sets
# ---------------------------------------------------------------------------

# Columns we want to KEEP in the slim courses.parquet. Matches the
# contract used by ``backend/app/model_loader.py`` (``_COURSE_FIELDS``)
# plus a few helper ranking fields that fall back gracefully when
# missing.
API_COLUMNS: list[str] = [
    "course_id", "course_name", "description", "skills", "subject",
    "level", "organization", "provider", "rating", "duration",
    "instructor", "price", "language", "image_url", "url",
    "reviews_count", "students_enrolled", "popularity_score",
    "reviews_for_ranking", "students_for_ranking",
    "certificate_type", "course_type", "is_free", "source_file",
    "has_image", "has_course_url",
]

# Candidate names for the "image" column in the source CSV.
IMAGE_COLUMN_CANDIDATES: tuple[str, ...] = (
    "image_url", "image", "thumbnail", "thumbnail_url",
)

# Candidate names for the "course URL" column in the source CSV.
URL_COLUMN_CANDIDATES: tuple[str, ...] = (
    "url", "course_url", "link",
)

# Tokens that mean "missing / invalid" when scraped from public
# course catalogs.
INVALID_URL_TOKENS: set[str] = {
    "", "none", "null", "nan", "n/a", "#", "-", "not found", "n.a.",
    "undefined", "about:blank",
}


# ---------------------------------------------------------------------------
# URL normalisation
# ---------------------------------------------------------------------------

_URL_RE = re.compile(r"^https?://", re.IGNORECASE)


def _normalise_url_token(value) -> str:
    """Return a canonical lower-cased token or empty string."""
    if value is None:
        return ""
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return ""
    s = str(value).strip().lower()
    if s in INVALID_URL_TOKENS:
        return ""
    return s


def is_valid_url(value) -> bool:
    s = _normalise_url_token(value)
    return bool(s) and bool(_URL_RE.match(s))


def normalised_url(value) -> str:
    """Return a canonicalised URL used for duplicate detection."""
    s = _normalise_url_token(value)
    if not s:
        return ""
    # Strip trailing slash + collapse common tracking params so
    # Coursera/edX duplicates with different utm_* tags collapse.
    s = re.sub(r"#.*$", "", s)
    s = re.sub(r"\?utm_[^=&]+=[^&]*(&utm_[^=&]+=[^&]*)*$", "", s)
    s = re.sub(r"\?+$", "", s)
    s = re.sub(r"/+$", "", s)
    return s


def normalised_name_provider(name, provider) -> str:
    n = "" if name is None else str(name).strip().lower()
    p = "" if provider is None else str(provider).strip().lower()
    return f"{n}::{p}"


# ---------------------------------------------------------------------------
# Field-weighted deployment text (matches train_v4.py recipe)
# ---------------------------------------------------------------------------

FIELD_REPEAT: dict[str, int] = {
    "course_name": 3,
    "skills": 3,
    "subject": 2,
    "description": 1,
}


def _safe_str(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value).strip()


def build_weighted_text(df: pd.DataFrame) -> list[str]:
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
                bits.extend([val] * repeat)
        out.append(" ".join(bits))
    return out


# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------


def compute_quality_score(df: pd.DataFrame) -> np.ndarray:
    """Float32 quality score used for ranking.

    Components (all 0–1, summed with weights):

      * popularity_score (0.30)  – min-max normalised, NaN/Inf safe
      * rating           (0.25)  – clip( rating / 5.0, 0, 1 )
      * reviews_count    (0.10)  – log-scaled, NaN/Inf safe
      * students_enrolled(0.10)  – log-scaled, NaN/Inf safe
      * description len  (0.10)  – saturating at ~1200 chars
      * skill count      (0.10)  – saturating at ~12 skills
      * provider present (0.03)
      * subject present  (0.02)

    All lookups are guarded with ``in df.columns`` so missing optional
    columns never raise KeyError.
    """
    n = len(df)
    score = np.zeros(n, dtype=np.float32)

    def _col_numeric(name: str) -> np.ndarray:
        if name not in df.columns:
            return np.zeros(n, dtype=np.float32)
        return pd.to_numeric(df[name], errors="coerce").to_numpy(dtype=np.float32)

    # popularity_score (log-scaled, works because the column is large).
    pop = _col_numeric("popularity_score")
    pop = np.nan_to_num(pop, nan=0.0, posinf=0.0, neginf=0.0)
    pop_max = float(pop.max()) if pop.size else 0.0
    if pop_max > 0:
        score += 0.30 * np.log1p(np.clip(pop, 0, None)) / math.log1p(pop_max)

    # rating.
    r = _col_numeric("rating")
    r = np.nan_to_num(r, nan=0.0)
    score += 0.25 * np.clip(r / 5.0, 0.0, 1.0)

    # reviews_count (use reviews_for_ranking as fallback).
    rev = _col_numeric("reviews_count")
    if not rev.any():
        rev = _col_numeric("reviews_for_ranking")
    rev = np.nan_to_num(rev, nan=0.0, posinf=0.0, neginf=0.0)
    rev_max = float(rev.max()) if rev.size else 0.0
    if rev_max > 0:
        score += 0.10 * np.log1p(np.clip(rev, 0, None)) / math.log1p(rev_max)

    # students_enrolled (log-scaled, use students_for_ranking as fallback).
    stu = _col_numeric("students_enrolled")
    if not stu.any():
        stu = _col_numeric("students_for_ranking")
    stu = np.nan_to_num(stu, nan=0.0, posinf=0.0, neginf=0.0)
    stu_max = float(stu.max()) if stu.size else 0.0
    if stu_max > 0:
        score += 0.10 * np.log1p(np.clip(stu, 0, None)) / math.log1p(stu_max)

    # description length.
    if "description" in df.columns:
        desc = df["description"].astype(str).str.len().to_numpy(dtype=np.float32)
        score += 0.10 * np.clip(desc / 1200.0, 0.0, 1.0)

    # skill count.
    if "skills" in df.columns:
        skills = df["skills"].astype(str).fillna("")
        sc = skills.str.count(",") + 1
        sc = np.where(skills.str.strip() == "", 0, sc).astype(np.float32)
        score += 0.10 * np.clip(sc / 12.0, 0.0, 1.0)

    # provider + subject present.
    if "provider" in df.columns:
        m = df["provider"].astype(str).str.strip().ne("").to_numpy(dtype=np.float32)
        score += 0.03 * m
    if "subject" in df.columns:
        m = df["subject"].astype(str).str.strip().ne("").to_numpy(dtype=np.float32)
        score += 0.02 * m

    return score


# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------


def backup_existing_bundle(out_dir: Path, backup_dir: Path) -> None:
    if backup_dir.exists():
        print(f"[15k] backup already present at {backup_dir}", file=sys.stderr)
        return
    if not out_dir.exists():
        print(f"[15k] no existing bundle at {out_dir}; skipping backup",
              file=sys.stderr)
        return
    backup_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(out_dir, backup_dir)
    print(f"[15k] backed up existing bundle to {backup_dir}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Rebuild v4 bundle (strict-AND)")
    p.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    p.add_argument("--max-rows", type=int, default=TARGET_MAX_ROW_COUNT,
                   help="Hard upper bound on final row count. Default 15,000.")
    p.add_argument("--max-features", type=int, default=20_000)
    p.add_argument("--min-df", type=int, default=2)
    p.add_argument("--max-df", type=float, default=0.98)
    p.add_argument("--ngram-max", type=int, default=2)
    p.add_argument("--no-backup", action="store_true",
                   help="skip copying the current bundle into v4_backup_before_15k/")
    return p.parse_args()


def detect_columns(df: pd.DataFrame) -> tuple[str | None, str | None]:
    image_col = next((c for c in IMAGE_COLUMN_CANDIDATES if c in df.columns), None)
    url_col = next((c for c in URL_COLUMN_CANDIDATES if c in df.columns), None)
    return image_col, url_col


def main() -> int:
    args = parse_args()
    out_dir: Path = args.out_dir
    max_rows: int = args.max_rows

    if not args.no_backup:
        backup_existing_bundle(out_dir, BACKUP_DIR)

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[15k] reading {args.source}", file=sys.stderr)
    df_raw = pd.read_csv(args.source)
    original_row_count = len(df_raw)
    print(f"[15k] raw rows: {original_row_count:,}", file=sys.stderr)
    print(f"[15k] columns: {list(df_raw.columns)}", file=sys.stderr)

    image_col, url_col = detect_columns(df_raw)
    print(f"[15k] detected image column: {image_col}", file=sys.stderr)
    print(f"[15k] detected url column:   {url_col}", file=sys.stderr)
    if image_col is None or url_col is None:
        print(
            "[15k] FATAL: could not detect image/url columns. "
            f"Looked for {IMAGE_COLUMN_CANDIDATES} and {URL_COLUMN_CANDIDATES}",
            file=sys.stderr,
        )
        return 2

    # ---- normalisation + flags ----------------------------------------
    df = df_raw.copy()
    df["has_valid_image_url"] = df[image_col].apply(is_valid_url).astype(bool)
    df["has_valid_course_url"] = df[url_col].apply(is_valid_url).astype(bool)
    df["_norm_url"] = df[url_col].apply(normalised_url)
    df["_norm_name_prov"] = df.apply(
        lambda r: normalised_name_provider(r.get("course_name"), r.get("provider")),
        axis=1,
    )

    counts = {
        "both_valid": int((df["has_valid_image_url"] & df["has_valid_course_url"]).sum()),
        "image_only": int((df["has_valid_image_url"] & ~df["has_valid_course_url"]).sum()),
        "url_only":   int((~df["has_valid_image_url"] & df["has_valid_course_url"]).sum()),
        "neither":    int((~df["has_valid_image_url"] & ~df["has_valid_course_url"]).sum()),
    }
    dup_course_id = int(df["course_id"].duplicated().sum()) \
        if "course_id" in df.columns else 0
    dup_norm_url = int(df["_norm_url"].duplicated().sum())

    print("[15k] pre-filter counts:", file=sys.stderr)
    print(f"           original rows            : {original_row_count:,}",
          file=sys.stderr)
    print(f"           both valid               : {counts['both_valid']:,}",
          file=sys.stderr)
    print(f"           image only               : {counts['image_only']:,}",
          file=sys.stderr)
    print(f"           url only                 : {counts['url_only']:,}",
          file=sys.stderr)
    print(f"           neither                  : {counts['neither']:,}",
          file=sys.stderr)
    print(f"           duplicate course_id      : {dup_course_id:,}",
          file=sys.stderr)
    print(f"           duplicate normalized URL : {dup_norm_url:,}",
          file=sys.stderr)

    # ---- strict-AND filter (this is the rule) --------------------------
    before_filter = len(df)
    df = df[df["has_valid_image_url"] & df["has_valid_course_url"]].copy()
    after_filter = len(df)
    print(
        f"[15k] strict-AND filter: {before_filter:,} → {after_filter:,} rows",
        file=sys.stderr,
    )

    # ---- deduplication --------------------------------------------------
    n0 = len(df)
    if "course_id" in df.columns:
        # Keep the row with the highest quality score per duplicate id.
        qc = compute_quality_score(df)
        df["_quality"] = qc
        df = df.sort_values("_quality", ascending=False)
        df = df.drop_duplicates(subset=["course_id"], keep="first")
        df = df.sort_index()  # restore source order
    n_after_id = len(df)
    df = df.drop_duplicates(subset=["_norm_url"], keep="first")
    n_after_url = len(df)
    df = df.drop_duplicates(subset=["_norm_name_prov"], keep="first")
    n_after_name = len(df)
    print(
        f"[15k] dedup: rows after id={n_after_id:,} "
        f"after url={n_after_url:,} after name+provider={n_after_name:,}",
        file=sys.stderr,
    )

    # ---- quality score (re-evaluate on the deduped frame) --------------
    df["_quality"] = compute_quality_score(df)

    # ---- selection: keep all valid rows; trim to max_rows only if needed
    if len(df) > max_rows:
        df = df.sort_values("_quality", ascending=False).head(max_rows)
        df = df.reset_index(drop=True)
        print(
            f"[15k] eligible pool ({len(df):,}) exceeded max_rows={max_rows:,} "
            f"→ kept top {max_rows:,} by quality",
            file=sys.stderr,
        )
    elif len(df) < max_rows:
        print(
            f"[15k] eligible pool ({len(df):,}) < max_rows={max_rows:,} "
            f"→ keeping all valid rows (no padding with invalid data)",
            file=sys.stderr,
        )
    else:
        print(f"[15k] eligible pool ({len(df):,}) == max_rows → keeping all",
              file=sys.stderr)

    # ---- prune & cast --------------------------------------------------
    # Keep the original ``course_id`` values (never renumber). Only the
    # DataFrame index is reset.
    df = df.rename(columns={
        "has_valid_image_url": "has_image",
        "has_valid_course_url": "has_course_url",
    })
    keep_cols = [c for c in API_COLUMNS if c in df.columns]
    for extra in ("has_image", "has_course_url"):
        if extra in df.columns and extra not in keep_cols:
            keep_cols.append(extra)
    final_df = df[keep_cols].copy()
    final_df = final_df.reset_index(drop=True)

    # Compact dtypes
    if "course_id" in final_df.columns:
        final_df["course_id"] = pd.to_numeric(final_df["course_id"], errors="coerce") \
            .fillna(0).astype("int32")
    if "rating" in final_df.columns:
        final_df["rating"] = pd.to_numeric(final_df["rating"], errors="coerce") \
            .astype("float32")
    if "popularity_score" in final_df.columns:
        final_df["popularity_score"] = pd.to_numeric(
            final_df["popularity_score"], errors="coerce"
        ).astype("float32")
    if "reviews_count" in final_df.columns:
        final_df["reviews_count"] = pd.to_numeric(
            final_df["reviews_count"], errors="coerce"
        ).fillna(0).astype("int32")
    if "students_enrolled" in final_df.columns:
        final_df["students_enrolled"] = pd.to_numeric(
            final_df["students_enrolled"], errors="coerce"
        ).fillna(0).astype("int32")
    for col in (
        "subject", "level", "organization", "provider",
        "language", "certificate_type", "course_type",
    ):
        if col in final_df.columns:
            try:
                final_df[col] = final_df[col].astype("category")
            except (TypeError, ValueError):
                pass

    # ---- validation assertions ----------------------------------------
    assert len(final_df) <= max_rows, (
        f"final row count {len(final_df)} > max_rows {max_rows}"
    )
    assert final_df["course_id"].is_unique, \
        "course_id must be unique after dedup"
    assert (final_df["has_image"]).all(), \
        "every final row must have has_image=True"
    assert (final_df["has_course_url"]).all(), \
        "every final row must have has_course_url=True"
    # Spot-check the actual URL fields: no dummy tokens, all http(s).
    bad = {"", "none", "null", "nan", "n/a", "#", "undefined", "about:blank"}
    for val in final_df["url"].astype(str):
        s = val.strip().lower()
        assert s not in bad, f"final url retained dummy token: {val!r}"
        assert s.startswith(("http://", "https://")), \
            f"final url not http(s): {val!r}"
    nonempty_img = final_df["image_url"].astype(str)
    nonempty_img = nonempty_img[nonempty_img.str.strip() != ""]
    for val in nonempty_img:
        s = val.strip().lower()
        assert s not in bad, f"final image_url retained dummy token: {val!r}"
        assert s.startswith(("http://", "https://")), \
            f"final image_url not http(s): {val!r}"

    # Required backend columns must all still exist.
    required_cols = {
        "course_id", "course_name", "description", "skills",
        "subject", "level", "organization", "provider", "rating",
        "duration", "instructor", "price", "language",
        "image_url", "url",
    }
    missing = required_cols - set(final_df.columns)
    assert not missing, f"required backend columns missing: {missing}"

    # ---- build deployment text + TF-IDF --------------------------------
    print("[15k] building weighted deployment text", file=sys.stderr)
    texts = build_weighted_text(final_df)
    avg_len = sum(len(t) for t in texts) / max(len(texts), 1)
    print(f"[15k] avg deployment text length: {avg_len:.0f} chars",
          file=sys.stderr)

    print(
        f"[15k] fitting TfidfVectorizer "
        f"(max_features={args.max_features}, ngram=(1,{args.ngram_max}))",
        file=sys.stderr,
    )
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
    matrix = matrix.astype(np.float32, copy=False).tocsr()
    if matrix.dtype != np.float32 or not isinstance(matrix, csr_matrix):
        matrix = matrix.astype(np.float32).tocsr()

    nnz = matrix.nnz
    vocab = len(vectorizer.vocabulary_)
    sparse_bytes = (
        matrix.data.nbytes + matrix.indices.nbytes + matrix.indptr.nbytes
    )
    print(
        f"[15k] vocab={vocab:,} nnz={nnz:,} shape={matrix.shape} "
        f"dtype={matrix.dtype} sparse_mem={sparse_bytes/1024/1024:.1f} MB",
        file=sys.stderr,
    )

    assert matrix.shape[0] == len(final_df), (
        f"matrix rows ({matrix.shape[0]}) != final_df rows ({len(final_df)})"
    )

    # ---- write artefacts -----------------------------------------------
    courses_path = out_dir / "courses.parquet"
    vec_path = out_dir / "tfidf_vectorizer.joblib"
    matrix_path = out_dir / "tfidf_matrix.npz"
    config_path = out_dir / "model_config.json"
    meta_path = out_dir / "model_metadata.json"

    final_df.to_parquet(courses_path, engine="pyarrow", index=False)
    joblib.dump(vectorizer, vec_path, compress=3)
    save_npz(matrix_path, matrix, compressed=True)

    config = {
        "selected_model_version": "v4_word_tfidf_strict_url_image",
        "source_preprocessor": "tfidf_strict_v4",
        "filter_policy": {
            "rule": "strict_AND",
            "require_valid_course_url": True,
            "require_valid_image_url": True,
            "invalidate_tokens": sorted(INVALID_URL_TOKENS),
        },
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
        "number_of_courses": int(len(final_df)),
        "number_of_features": int(vocab),
        "max_row_count": int(max_rows),
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
        "model_name": "EduCompass TF-IDF Course Recommender (v4 strict-AND)",
        "model_type": "Content-based NLP recommendation system",
        "model_version": "v4",
        "subset_size": int(len(final_df)),
        "number_of_courses": int(len(final_df)),
        "number_of_features": int(vocab),
        "vectorizer": "TfidfVectorizer",
        "ngram_range": [1, args.ngram_max],
        "max_features": args.max_features,
        "filter_policy": "strict_AND: valid course_url AND valid image_url",
        "recommendation_methods": [
            "Natural-language query recommendation",
            "Similar-course recommendation",
        ],
    }
    meta_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    # ---- final report --------------------------------------------------
    df_mb = final_df.memory_usage(deep=True).sum() / 1024 / 1024
    matrix_mb = sparse_bytes / 1024 / 1024

    print("\n========== v4 strict-AND rebuild report ==========", file=sys.stderr)
    print(f"original row count            : {original_row_count:,}",
          file=sys.stderr)
    print(f"valid (both URL + image)      : {counts['both_valid']:,}",
          file=sys.stderr)
    print(f"rows after strict-AND filter  : {after_filter:,}",
          file=sys.stderr)
    print(f"duplicates removed            : {n0 - n_after_name:,}",
          file=sys.stderr)
    print(f"final row count               : {len(final_df):,}",
          file=sys.stderr)
    print(f"rows p                         : {original_row_count - len(final_df):,}",
          file=sys.stderr)
    print(f"invalid final URL count       : {int((~final_df['has_course_url']).sum())}",
          file=sys.stderr)
    print(f"invalid final image count     : {int((~final_df['has_image']).sum())}",
          file=sys.stderr)
    print(f"DataFrame memory              : {df_mb:.1f} MB",
          file=sys.stderr)
    print(f"sparse matrix memory          : {matrix_mb:.1f} MB",
          file=sys.stderr)
    print(f"generated files               :", file=sys.stderr)
    for p in (courses_path, vec_path, matrix_path, config_path, meta_path):
        size_mb = p.stat().st_size / 1024 / 1024
        print(f"  - {p.relative_to(REPO_ROOT)}  ({size_mb:.2f} MB)",
              file=sys.stderr)
    print("==================================================\n", file=sys.stderr)

    # ---- cleanup --------------------------------------------------------
    del df, df_raw, texts, matrix, vectorizer
    gc.collect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())