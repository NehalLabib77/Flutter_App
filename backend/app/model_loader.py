"""Lightweight loader for the EduCompass v4 course recommender.

Loads the v4 bundle shipped under ``ml/artifacts/models/v4/``:

* ``courses.parquet``         – slim courses frame (no ``deployment_text``)
* ``tfidf_vectorizer.joblib`` – fitted :class:`TfidfVectorizer`
* ``tfidf_matrix.npz``        – pre-computed CSR float32 TF-IDF matrix
* ``model_config.json``       – optional field/rerank weights

The deployment sparse matrix is **precomputed at training time** and
loaded from disk with ``scipy.sparse.load_npz``. The loader never calls
``vectorizer.transform`` over the corpus during startup, which keeps
the cold-start peak RSS well below Render Free's 512 MiB cap.

Public surface required by ``model_service.py`` / ``routes.py``::

    BundleMeta, CourseRow, ModelLoadError,
    RecommendationModelAdapter, load_adapter

The dataclass keeps ``word_matrix`` / ``char_matrix`` and
``word_vectorizer`` / ``char_vectorizer`` as **aliases** that point to
the same sparse matrix / fitted vectorizer objects, so any legacy
downstream code that still reads those names keeps working.
"""
from __future__ import annotations

import json
import logging
import math
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

import joblib
import numpy as np
import pandas as pd
from scipy.sparse import issparse
from scipy.sparse import load_npz
from sklearn.feature_extraction.text import TfidfVectorizer

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_MODEL_DIR = (
    _REPO_ROOT / "ml" / "artifacts" / "models" / "v4"
)
DEFAULT_META_PATH = (
    _REPO_ROOT / "ml" / "artifacts" / "models" / "model_metadata.json"
)


def _resolve_model_dir() -> Path:
    """Pick the model directory based on the ``MODEL_DIR`` env var.

    Falls back to the repo-relative default. The result is always an
    absolute path so logs and downstream ``Path`` operations work the
    same on Windows and POSIX.
    """
    override = os.getenv("MODEL_DIR")
    candidate = Path(override).expanduser() if override else DEFAULT_MODEL_DIR
    return candidate.resolve() if not candidate.is_absolute() else candidate


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class ModelLoadError(Exception):
    """Raised when the v4 bundle cannot be assembled."""


# ---------------------------------------------------------------------------
# Course row schema (mirrors legacy behaviour)
# ---------------------------------------------------------------------------

_COURSE_FIELDS: tuple[str, ...] = (
    "course_id", "course_name", "description", "skills", "subject", "level",
    "organization", "provider", "rating", "reviews_count", "students_enrolled",
    "lectures_count", "duration", "instructor", "price", "language",
    "image_url", "url", "certificate_type", "course_type", "is_free",
    "has_image", "has_course_url", "popularity_score", "data_quality_score",
)

# Fields returned on list endpoints (search, popular, top-rated,
# recommendations, similar, favourites). The full ``course_row_to_dict``
# payload is only used on the detail endpoint, where the client has
# explicitly asked for everything.
_SLIM_LIST_FIELDS: tuple[str, ...] = (
    "course_id", "course_name", "image_url", "url", "rating",
    "reviews_count", "students_enrolled", "level", "subject",
    "provider", "duration", "is_free", "certificate_type",
    "popularity_score",
)

# Categorical columns (low-cardinality) that benefit from
# ``pd.Categorical`` storage. A 24k-row frame with object dtype for
# these fields bloats RSS by 10–30 MB.
_CATEGORICAL_FIELDS: tuple[str, ...] = (
    "subject", "level", "provider", "organization", "language",
    "certificate_type", "course_type",
)

# Numeric columns that should be downcast to 32-bit dtypes. ``float64``
# is the default pandas rehydrates from Parquet, but the schema never
# needs that precision for course metadata.
_FLOAT32_FIELDS: tuple[str, ...] = (
    "rating", "popularity_score", "data_quality_score", "price",
    "students_enrolled",
)
_INT32_FIELDS: tuple[str, ...] = (
    "reviews_count", "lectures_count",
)
_BOOL_FIELDS: tuple[str, ...] = (
    "is_free", "has_image", "has_course_url",
)


def _optimize_courses_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """Downcast object/float columns to keep RSS small.

    A 24k-row Parquet round-trip can leave the DataFrame with object
    dtype everywhere — that's ~3× the on-disk size in RAM. We
    categorise low-cardinality columns and downcast numerics to
    float32/int32, which together usually shrinks the frame by
    50–70%.
    """
    for col in _CATEGORICAL_FIELDS:
        if col not in df.columns:
            continue
        try:
            df[col] = df[col].astype("category")
        except (TypeError, ValueError):
            log.debug("could not convert %s to category", col)

    for col in _FLOAT32_FIELDS:
        if col not in df.columns:
            continue
        try:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("float32")
        except (TypeError, ValueError):
            log.debug("could not downcast %s to float32", col)

    for col in _INT32_FIELDS:
        if col not in df.columns:
            continue
        try:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).astype("int32")
        except (TypeError, ValueError):
            log.debug("could not downcast %s to int32", col)

    for col in _BOOL_FIELDS:
        if col not in df.columns:
            continue
        try:
            df[col] = df[col].astype("bool")
        except (TypeError, ValueError):
            log.debug("could not convert %s to bool", col)

    return df


def _safe_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value)


def _parse_skills(value: Any) -> list[str]:
    """Normalise the messy ``skills`` column into a clean list of strings."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(s).strip() for s in value if str(s).strip()]
    if isinstance(value, float) and (math.isnan(value) or pd.isna(value)):
        return []
    text = str(value).strip()
    if not text:
        return []
    text = text.strip(" \"'")
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if inner:
            parts = re_split_comma(inner)
            return [
                p.strip().strip("'\"")
                for p in parts
                if p.strip().strip("'\"")
            ]
        return []
    parts = re_split_comma(text)
    return [p.strip() for p in parts if p.strip()]


def re_split_comma(text: str) -> list[str]:
    """``", "`` / ``","`` split. ``re`` lives here so the import is local
    and stays cheap for callers that don't hit skills."""
    import re
    return re.split(r",\s*", text)


def course_row_to_dict(row: pd.Series) -> dict:
    """Convert a DataFrame row to the JSON dict expected by the routes."""
    out: dict = {}
    for f in _COURSE_FIELDS:
        if f not in row.index:
            out[f] = None
            continue
        v = row[f]
        if v is None or (isinstance(v, float) and (math.isnan(v) or pd.isna(v))):
            out[f] = None
        elif isinstance(v, (np.integer,)):
            out[f] = int(v)
        elif isinstance(v, (np.floating,)):
            fv = float(v)
            out[f] = None if (math.isnan(fv) or math.isinf(fv)) else fv
        elif isinstance(v, (np.bool_,)):
            out[f] = bool(v)
        else:
            out[f] = v
    # The v3 bundle stores course_id as int64 — JSON consumers always want
    # a string here. Coerce so downstream `==` assertions and stringly
    # typed callers stay happy.
    out["course_id"] = str(out.get("course_id") or row.name)
    out["id"] = out["course_id"]
    out["name"] = out.get("course_name") or ""
    out["skills"] = _parse_skills(out.get("skills"))
    return out


def course_row_to_slim(row: pd.Series) -> dict:
    """Compact row payload for list endpoints.

    Drops the heavy ``description`` blob (used only on the detail
    endpoint) and any non-marketing columns the client doesn't render
    on cards. ``skills`` is **kept** because the Flutter client draws
    it as small badges on each card and the parsed list is tiny.
    """
    fields = _SLIM_LIST_FIELDS
    out: dict = {}
    for f in fields:
        if f not in row.index:
            out[f] = None
            continue
        v = row[f]
        if v is None:
            out[f] = None
        elif isinstance(v, float):
            fv = v
            out[f] = None if (math.isnan(fv) or math.isinf(fv)) else fv
        elif isinstance(v, (np.integer,)):
            out[f] = int(v)
        elif isinstance(v, (np.floating,)):
            fv = float(v)
            out[f] = None if (math.isnan(fv) or math.isinf(fv)) else fv
        elif isinstance(v, (np.bool_,)):
            out[f] = bool(v)
        else:
            out[f] = v
    cid = out.get("course_id")
    out["course_id"] = str(cid) if cid is not None else str(row.name)
    out["id"] = out["course_id"]
    out["name"] = out.get("course_name") or ""
    # ``skills`` is small and the client renders it on cards. Cost is
    # bounded (a few hundred bytes per row) and the parser is cheap.
    out["skills"] = _parse_skills(row.get("skills")) \
        if "skills" in row.index else []
    return out


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------


@dataclass
class CourseRow:
    course_id: str
    payload: dict
    text: str


@dataclass
class BundleMeta:
    model_version: str = "v4"
    source: str = ""
    field_vectorizers: dict[str, TfidfVectorizer] = field(default_factory=dict)
    field_weights: dict[str, float] = field(default_factory=dict)
    number_of_features: int = 0

    @property
    def version(self) -> str:
        return self.model_version


@dataclass
class RecommendationModelAdapter:
    courses_df: pd.DataFrame
    row_index: dict[str, int]
    rows: list[CourseRow]
    tfidf_vectorizer: TfidfVectorizer
    tfidf_matrix: Any  # scipy.sparse.csr_matrix (float32)
    # Legacy aliases. Routes may reference either name; both point to the
    # same object to avoid duplicating the sparse matrix in memory.
    word_vectorizer: TfidfVectorizer
    word_matrix: Any
    char_vectorizer: TfidfVectorizer
    char_matrix: Any
    meta: BundleMeta

    # -- introspection --------------------------------------------------

    @property
    def number_of_courses(self) -> int:
        return len(self.rows)

    def sparse_memory_mb(self) -> float:
        """Estimate resident memory of the sparse matrix in MB."""
        m = self.tfidf_matrix
        if not issparse(m):
            return float(m.nbytes) / 1024 / 1024
        return float(m.data.nbytes + m.indices.nbytes + m.indptr.nbytes) / 1024 / 1024

    # -- direct lookups -------------------------------------------------

    def get_course(self, course_id: str) -> Optional[dict]:
        idx = self.row_index.get(str(course_id))
        if idx is None:
            return None
        return course_row_to_dict(self.courses_df.iloc[idx])

    def list_courses(self, limit: int = 50, offset: int = 0) -> list[dict]:
        end = min(offset + limit, len(self.courses_df))
        if offset >= end:
            return []
        return [
            course_row_to_dict(self.courses_df.iloc[i])
            for i in range(offset, end)
        ]

    # -- search ---------------------------------------------------------

    def suggest(self, prefix: str, n: int = 8) -> list[str]:
        """Naive prefix scan over course name + skills for live autocomplete."""
        import re
        prefix = prefix.lower().strip()
        if not prefix:
            return []
        seen: set[str] = set()
        out: list[str] = []
        for row in self.rows:
            name = row.payload.get("course_name") or ""
            skills = row.payload.get("skills") or []
            if isinstance(skills, (list, tuple)):
                skills_str = " ".join(str(s) for s in skills)
            else:
                skills_str = str(skills)
            tokens = re.split(r"[^a-z0-9]+", (name + " " + skills_str).lower())
            for t in tokens:
                if t.startswith(prefix) and t not in seen and len(t) > 2:
                    seen.add(t)
                    out.append(t)
                    if len(out) >= n:
                        return out
        return out

    def search_courses(
        self,
        query: str,
        limit: int = 20,
        offset: int = 0,
        subject: Optional[str] = None,
        level: Optional[str] = None,
        provider: Optional[str] = None,
        is_free: Optional[bool] = None,
        slim: bool = True,
    ) -> tuple[list[dict], int]:
        """Sparse TF-IDF search returning (rows, total_matches).

        ``slim=True`` (default) returns the compact list payload; the
        detail endpoint opts back into the full schema.
        """
        q = (query or "").strip().lower()
        serializer = course_row_to_slim if slim else course_row_to_dict
        if not q:
            # No query → page through the full DataFrame in declared order.
            try:
                page = self._slice_df(
                    offset=offset, limit=limit,
                    subject=subject, level=level,
                    provider=provider, is_free=is_free,
                    serializer=serializer,
                )
                return page["items"], page["total"]
            except Exception:
                # Fallback to the legacy scan if the filter path raises.
                results = [serializer(self.courses_df.iloc[i])
                           for i in range(len(self.courses_df))]
                filtered = self._apply_filters(
                    results, subject=subject, level=level,
                    provider=provider, is_free=is_free,
                )
                return filtered[offset:offset + limit], len(filtered)

        try:
            q_vec = self.tfidf_vectorizer.transform([q])
            sims = _row_similarities(q_vec, self.tfidf_matrix)
        except Exception as exc:
            raise ModelLoadError(
                f"failed to transform query against vectorizer: {exc}"
            ) from exc

        # Score-sorted order. We never materialise a full sorted copy
        # of the scores — we just iterate in argsort order and stop at
        # ``offset + limit + 1`` so we know the total.
        order = np.argsort(-sims)
        ranked_idx: list[int] = []
        for i in order:
            if sims[i] <= 0:
                break
            ranked_idx.append(int(i))

        # Apply filters *before* slicing so the returned ``total`` is
        # the count of matches that satisfy the filter, not the global
        # rank size.
        if any(x is not None for x in (subject, level, provider, is_free)):
            filtered_rows: list[dict] = []
            for i in ranked_idx:
                row = self.courses_df.iloc[i]
                if not self._row_matches_filters(
                    row, subject=subject, level=level,
                    provider=provider, is_free=is_free,
                ):
                    continue
                filtered_rows.append(serializer(row))
            total = len(filtered_rows)
            return filtered_rows[offset:offset + limit], total

        # No filters → raw top-k slice.
        page = ranked_idx[offset:offset + limit]
        total = len(ranked_idx)
        return [serializer(self.courses_df.iloc[i]) for i in page], total

    @staticmethod
    def _row_matches_filters(
        row: pd.Series,
        *,
        subject: Optional[str],
        level: Optional[str],
        provider: Optional[str],
        is_free: Optional[bool],
    ) -> bool:
        if subject is not None and str(row.get("subject") or "").lower() != subject.lower():
            return False
        if level is not None and str(row.get("level") or "").lower() != level.lower():
            return False
        if provider is not None and str(row.get("provider") or "").lower() != provider.lower():
            return False
        if is_free is not None and bool(row.get("is_free")) != bool(is_free):
            return False
        return True

    def _slice_df(
        self,
        *,
        offset: int,
        limit: int,
        subject: Optional[str],
        level: Optional[str],
        provider: Optional[str],
        is_free: Optional[bool],
        serializer,
    ) -> dict:
        """Materialise a small slice of the DataFrame without building a
        dense copy of the full frame.

        For ``limit`` ≪ ``n_rows`` this is much faster than building
        the entire list first and then slicing — and far cheaper in
        peak RSS.
        """
        df = self.courses_df
        if any(x is not None for x in (subject, level, provider, is_free)):
            mask = pd.Series(True, index=df.index)
            if subject is not None:
                mask &= df["subject"].astype(str).str.lower() == subject.lower()
            if level is not None:
                mask &= df["level"].astype(str).str.lower() == level.lower()
            if provider is not None:
                mask &= df["provider"].astype(str).str.lower() == provider.lower()
            if is_free is not None:
                mask &= df["is_free"].astype(bool) == bool(is_free)
            positions = np.flatnonzero(mask.to_numpy())
        else:
            positions = np.arange(len(df))

        total = int(positions.shape[0])
        page = positions[offset:offset + limit]
        rows = [serializer(df.iloc[int(i)]) for i in page]
        return {"items": rows, "total": total}

    def _apply_filters(self, results, *, subject, level, provider, is_free):
        def keep(d: dict) -> bool:
            if subject and str(d.get("subject") or "").lower() != subject.lower():
                return False
            if level and str(d.get("level") or "").lower() != level.lower():
                return False
            if provider and str(d.get("provider") or "").lower() != provider.lower():
                return False
            if is_free is not None and bool(d.get("is_free")) != bool(is_free):
                return False
            return True
        return [d for d in results if keep(d)]

    # -- popularity -----------------------------------------------------

    def popular(self, limit: int = 12, slim: bool = True) -> list[dict]:
        return self._top_by_score(
            score_columns=("popularity_score",),
            bonus_columns=("students_enrolled",),
            bonus_divisor=1_000_000.0,
            limit=limit,
            slim=slim,
        )

    def top_rated(self, limit: int = 12, slim: bool = True) -> list[dict]:
        return self._top_by_score(
            score_columns=("rating",),
            bonus_columns=("reviews_count",),
            bonus_divisor=1_000_000.0,
            limit=limit,
            slim=slim,
        )

    def _top_by_score(
        self,
        *,
        score_columns: tuple[str, ...],
        bonus_columns: tuple[str, ...],
        bonus_divisor: float,
        limit: int,
        slim: bool,
    ) -> list[dict]:
        """Sort the top-``limit`` rows by a composite score, but never
        copy the whole DataFrame. ``argpartition`` runs in O(n) instead
        of O(n log n) and only allocates ``limit`` result rows.
        """
        df = self.courses_df
        n = len(df)
        if n == 0 or limit <= 0:
            return []

        primary = df[score_columns[0]].to_numpy(dtype=np.float32, copy=False)
        bonus = df[bonus_columns[0]].to_numpy(dtype=np.float32, copy=False) \
            if bonus_columns else np.zeros(n, dtype=np.float32)
        # NaN/inf-safe: replace with 0 so ranking stays stable.
        primary = np.nan_to_num(primary, nan=0.0, posinf=0.0, neginf=0.0)
        bonus = np.nan_to_num(bonus, nan=0.0, posinf=0.0, neginf=0.0)
        score = primary + bonus / bonus_divisor

        k = min(limit, n)
        top_idx = np.argpartition(-score, kth=k - 1)[:k]
        top_idx = top_idx[np.argsort(-score[top_idx])]

        serializer = course_row_to_slim if slim else course_row_to_dict
        return [serializer(df.iloc[int(i)]) for i in top_idx]

    # -- recommendation -------------------------------------------------

    def recommend_similar(self, course_id: str, limit: int = 6, slim: bool = True) -> list[dict]:
        idx = self.row_index.get(str(course_id))
        if idx is None:
            return []
        sims = _row_similarities(self.tfidf_matrix[idx], self.tfidf_matrix)
        # argpartition is O(n); avoid sorting all 24k rows just to take 6.
        k = min(limit + 1, len(sims))
        top_idx = np.argpartition(-sims, kth=k - 1)[:k]
        top_idx = top_idx[np.argsort(-sims[top_idx])]
        serializer = course_row_to_slim if slim else course_row_to_dict
        out: list[dict] = []
        for i in top_idx:
            if int(i) == idx:
                continue
            out.append(serializer(self.courses_df.iloc[int(i)]))
            if len(out) >= limit:
                break
        return out

    def recommend_query(self, query: str, limit: int = 10, slim: bool = True) -> list[dict]:
        """Sparse-query recommendation. Linear-kernel safe, no dense build."""
        q = (query or "").strip()
        if not q:
            return self.popular(limit=limit, slim=slim)
        q_vec = self.tfidf_vectorizer.transform([q])
        sims = _row_similarities(q_vec, self.tfidf_matrix)
        # top-k via argpartition; preserves score order inside the top-k.
        k = min(limit, len(sims))
        top_idx = np.argpartition(-sims, kth=k - 1)[:k]
        top_idx = top_idx[np.argsort(-sims[top_idx])]
        serializer = course_row_to_slim if slim else course_row_to_dict
        out: list[dict] = []
        for i in top_idx:
            if sims[i] <= 0:
                continue
            out.append(serializer(self.courses_df.iloc[int(i)]))
            if len(out) >= limit:
                break
        return out

    def recommend_personalized(
        self,
        interests: Iterable[str],
        history_ids: Iterable[str],
        favorites_ids: Iterable[str],
        limit: int = 10,
    ) -> list[dict]:
        parts: list[str] = [s for s in (interests or []) if s]
        seed_ids = list(dict.fromkeys(
            list(favorites_ids or []) + list(history_ids or [])
        ))
        for cid in seed_ids:
            idx = self.row_index.get(str(cid))
            if idx is None:
                continue
            parts.append(self.rows[idx].text[:500])
        if not parts:
            return self.popular(limit=limit)
        q = " ".join(parts)
        return self.recommend_query(q, limit=limit)

    # -- filter listings -----------------------------------------------

    @property
    def filter_lists(self) -> dict[str, list[str]]:
        """Distinct values for filterable course fields, sorted."""

        def _unique(series_name: str) -> list[str]:
            if series_name not in self.courses_df.columns:
                return []
            series = self.courses_df[series_name].dropna().astype(str)
            series = series[series.str.strip() != ""]
            return sorted(series.unique().tolist())

        return {
            "subjects": _unique("subject"),
            "levels": _unique("level"),
            "providers": _unique("provider") or _unique("organization"),
            "languages": _unique("language"),
            "certificates": _unique("certificate_type"),
            "course_types": _unique("course_type"),
        }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _row_similarities(q_vec, matrix) -> np.ndarray:
    """Compute sparse-safe row-similarity scores as a 1-D float32 array."""
    from sklearn.metrics.pairwise import linear_kernel
    sims = linear_kernel(q_vec, matrix).ravel()
    return np.asarray(sims, dtype=np.float32)


# ---------------------------------------------------------------------------
# Loader
# ---------------------------------------------------------------------------


def load_adapter(
    model_dir: str | Path | None = None,
    meta_path: str | Path | None = None,
) -> RecommendationModelAdapter:
    """Load the v4 bundle (matrix is pre-built; never transformed at startup)."""
    mdir = Path(model_dir).expanduser().resolve() if model_dir else _resolve_model_dir()
    mfile: Optional[Path] = (
        Path(meta_path).expanduser().resolve() if meta_path
        else (mdir.parent / "model_metadata.json")
    )

    if not mdir.exists():
        raise ModelLoadError(
            f"model directory does not exist: {mdir}. "
            f"Set the MODEL_DIR env var or ship the v4 bundle under "
            f"{DEFAULT_MODEL_DIR}."
        )
    if not mdir.is_dir():
        raise ModelLoadError(f"model path is not a directory: {mdir}")

    courses_path = mdir / "courses.parquet"
    vectorizer_path = mdir / "tfidf_vectorizer.joblib"
    matrix_path = mdir / "tfidf_matrix.npz"

    missing_paths = [
        p for p in (courses_path, vectorizer_path, matrix_path) if not p.exists()
    ]
    if missing_paths:
        raise ModelLoadError(
            "required model files missing under "
            f"{mdir}: {', '.join(p.name for p in missing_paths)}"
        )

    log.info("loading v4 model from %s", mdir)

    # Parquet; Arrow schema is stable across pandas versions. We only
    # pull the columns API endpoints actually serialize so the
    # DataFrame stays small (≪ 200 MB even with 24k courses).
    try:
        all_cols = pd.read_parquet(
            courses_path, engine="pyarrow", columns=None
        ).columns.tolist()
    except Exception as exc:
        raise ModelLoadError(
            f"failed to inspect courses.parquet: {exc}. "
            f"Re-run ml/training/train_v4.py to regenerate the bundle."
        ) from exc

    if "course_id" not in all_cols:
        raise ModelLoadError(
            "courses.parquet is missing required 'course_id' column; "
            "re-run ml/training/train_v4.py to regenerate the v4 bundle."
        )

    wanted_cols = [c for c in _COURSE_FIELDS if c in all_cols]
    extra_cols = [c for c in all_cols if c not in _COURSE_FIELDS]
    if extra_cols:
        log.info(
            "courses.parquet: dropping %d unused columns at load time: %s",
            len(extra_cols), ", ".join(extra_cols[:8]) +
            ("..." if len(extra_cols) > 8 else ""),
        )

    try:
        courses_df = pd.read_parquet(
            courses_path, engine="pyarrow",
            columns=wanted_cols,
        )
    except Exception as exc:
        raise ModelLoadError(
            f"failed to load courses.parquet: {exc}. "
            f"Re-run ml/training/train_v4.py to regenerate the bundle."
        ) from exc

    courses_df = _optimize_courses_dataframe(courses_df)

    # Pre-built CSR matrix from disk. ``load_npz`` reads straight into
    # float32 (matches the dtype we wrote).
    try:
        tfidf_matrix = load_npz(matrix_path)
    except Exception as exc:
        raise ModelLoadError(
            f"failed to load tfidf_matrix.npz: {exc}. "
            f"Re-run ml/training/train_v4.py to regenerate the bundle."
        ) from exc

    if not issparse(tfidf_matrix):
        raise ModelLoadError(
            "tfidf_matrix.npz did not load as a sparse matrix; refusing "
            "to densify to keep the service under 512 MB."
        )
    if tfidf_matrix.format != "csr":
        tfidf_matrix = tfidf_matrix.tocsr()
    if tfidf_matrix.dtype != np.float32:
        tfidf_matrix = tfidf_matrix.astype(np.float32)

    if tfidf_matrix.shape[0] != len(courses_df):
        raise ModelLoadError(
            f"matrix row count ({tfidf_matrix.shape[0]}) does not match "
            f"courses.parquet row count ({len(courses_df)}). "
            f"Re-run ml/training/train_v4.py to regenerate the bundle."
        )

    try:
        vectorizer: TfidfVectorizer = joblib.load(vectorizer_path)
    except Exception as exc:
        raise ModelLoadError(
            f"failed to load tfidf_vectorizer.joblib: {exc}"
        ) from exc

    # Optional config / metadata.
    config_path = mdir / "model_config.json"
    field_weights: dict[str, float] = {}
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8"))
            fw = cfg.get("field_weights") or {}
            if isinstance(fw, dict):
                field_weights = {str(k): float(v) for k, v in fw.items()}
        except Exception:  # noqa: BLE001
            log.warning("could not parse %s; field_weights empty",
                        config_path, exc_info=True)

    meta = BundleMeta(
        model_version="v4",
        source=str(mdir),
        field_weights=field_weights,
        number_of_features=len(getattr(vectorizer, "vocabulary_", {}) or {}),
    )

    # Legacy metadata file (optional).
    if mfile is not None and mfile.exists():
        try:
            raw = json.loads(mfile.read_text(encoding="utf-8"))
            section = raw.get("v4", raw.get("default", raw))
            fw = section.get("field_weights") or {}
            if isinstance(fw, dict) and not field_weights:
                field_weights = {str(k): float(v) for k, v in fw.items()}
                meta.field_weights = field_weights
            meta.model_version = str(section.get("model_version", "v4"))
        except Exception:  # noqa: BLE001
            log.debug("legacy metadata at %s could not be parsed", mfile)

    # Course rows.
    rows: list[CourseRow] = []
    index: dict[str, int] = {}
    for i, (_, row) in enumerate(courses_df.iterrows()):
        cid = str(row.get("course_id") or i)
        index[cid] = i
        text = " ".join(filter(None, (
            _safe_text(row.get("course_name")),
            _safe_text(row.get("description")),
            _safe_text(row.get("skills")),
            _safe_text(row.get("subject")),
        )))
        rows.append(CourseRow(course_id=cid,
                              payload=course_row_to_dict(row), text=text))

    # Diagnostic memory figures.
    sparse_bytes = (
        tfidf_matrix.data.nbytes
        + tfidf_matrix.indices.nbytes
        + tfidf_matrix.indptr.nbytes
    )
    sparse_mb = sparse_bytes / 1024 / 1024
    df_bytes = int(courses_df.memory_usage(deep=True).sum())
    df_mb = df_bytes / 1024 / 1024

    log.info(
        "v4 model ready: courses=%d vocab=%d matrix=%s dtype=%s "
        "nnz=%d sparse_mem=%.1f MB df_mem=%.1f MB",
        len(rows),
        meta.number_of_features,
        tfidf_matrix.shape,
        tfidf_matrix.dtype,
        tfidf_matrix.nnz,
        sparse_mb,
        df_mb,
    )

    return RecommendationModelAdapter(
        courses_df=courses_df,
        row_index=index,
        rows=rows,
        tfidf_vectorizer=vectorizer,
        tfidf_matrix=tfidf_matrix,
        word_vectorizer=vectorizer,        # legacy alias (same object)
        word_matrix=tfidf_matrix,          # legacy alias (same object)
        char_vectorizer=vectorizer,        # legacy alias (same object)
        char_matrix=tfidf_matrix,          # legacy alias (same object)
        meta=meta,
    )


__all__ = [
    "BundleMeta",
    "CourseRow",
    "ModelLoadError",
    "RecommendationModelAdapter",
    "load_adapter",
    "DEFAULT_MODEL_DIR",
]
