"""Lightweight loader for the EduCompass v3 course recommender.

Loads the v3 bundle shipped under ``ml/artifacts/models/v3/``:

* ``courses.joblib``           – slim courses frame with a
  ``deployment_text`` column
* ``tfidf_vectorizer.joblib``  – fitted :class:`TfidfVectorizer`
* ``model_config.json``        – optional field/rerank weights

The deployment sparse matrix is **not** persisted on disk — it is built
once at startup from the ``deployment_text`` column. This keeps the
shipping artefact at ~30 MB and the in-process sparse CSR at ~20 MB,
which lets the service fit comfortably inside Render Free's 512 MB cap.

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
from sklearn.feature_extraction.text import TfidfVectorizer

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_MODEL_DIR = (
    _REPO_ROOT / "ml" / "artifacts" / "models" / "v3"
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
    """Raised when the v3 bundle cannot be assembled."""


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
    model_version: str = "v3"
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
    ) -> tuple[list[dict], int]:
        """Sparse TF-IDF search returning (rows, total_matches)."""
        q = (query or "").strip().lower()
        if not q:
            results = [course_row_to_dict(self.courses_df.iloc[i])
                       for i in range(len(self.courses_df))]
            total = len(results)
        else:
            try:
                q_vec = self.tfidf_vectorizer.transform([q])
                sims = _row_similarities(q_vec, self.tfidf_matrix)
            except Exception as exc:
                raise ModelLoadError(
                    f"failed to transform query against vectorizer: {exc}"
                ) from exc
            order = np.argsort(-sims)
            df = self.courses_df.copy()
            df["__match_score"] = sims
            results = []
            for i in order:
                if sims[i] <= 0:
                    break
                results.append(course_row_to_dict(df.iloc[int(i)]))
            total = len(results)
        filtered = self._apply_filters(
            results, subject=subject, level=level,
            provider=provider, is_free=is_free,
        )
        return filtered[offset:offset + limit], len(filtered)

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

    def popular(self, limit: int = 12) -> list[dict]:
        df = self.courses_df.copy()
        df["__score"] = (
            df.get("popularity_score", pd.Series([0] * len(df))).fillna(0)
            + df.get("students_for_ranking", pd.Series([0] * len(df))).fillna(0) / 1e6
        )
        df = df.sort_values("__score", ascending=False).head(limit)
        return [course_row_to_dict(df.iloc[i]) for i in range(len(df))]

    def top_rated(self, limit: int = 12) -> list[dict]:
        df = self.courses_df.copy()
        df["__score"] = (
            df.get("rating", pd.Series([0] * len(df))).fillna(0)
            + df.get("reviews_count", pd.Series([0] * len(df))).fillna(0) / 1e6
        )
        df = df.sort_values("__score", ascending=False).head(limit)
        return [course_row_to_dict(df.iloc[i]) for i in range(len(df))]

    # -- recommendation -------------------------------------------------

    def recommend_similar(self, course_id: str, limit: int = 6) -> list[dict]:
        idx = self.row_index.get(str(course_id))
        if idx is None:
            return []
        sims = _row_similarities(self.tfidf_matrix[idx], self.tfidf_matrix)
        order = np.argsort(-sims)
        out: list[dict] = []
        for i in order:
            if int(i) == idx:
                continue
            out.append(course_row_to_dict(self.courses_df.iloc[int(i)]))
            if len(out) >= limit:
                break
        return out

    def recommend_query(self, query: str, limit: int = 10) -> list[dict]:
        """Sparse-query recommendation. Linear-kernel safe, no dense build."""
        q = (query or "").strip()
        if not q:
            return self.popular(limit=limit)
        q_vec = self.tfidf_vectorizer.transform([q])
        sims = _row_similarities(q_vec, self.tfidf_matrix)
        # top-k via argpartition; preserves score order inside the top-k.
        k = min(limit, len(sims))
        top_idx = np.argpartition(-sims, kth=k - 1)[:k]
        top_idx = top_idx[np.argsort(-sims[top_idx])]
        out: list[dict] = []
        for i in top_idx:
            if sims[i] <= 0:
                continue
            out.append(course_row_to_dict(self.courses_df.iloc[int(i)]))
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
    """Load the v3 bundle.

    The full TF-IDF matrix is rebuilt from ``deployment_text`` at startup
    instead of being persisted, so the shipping artefact stays small.
    """
    mdir = Path(model_dir).expanduser().resolve() if model_dir else _resolve_model_dir()
    mfile: Optional[Path] = (
        Path(meta_path).expanduser().resolve() if meta_path
        else (mdir.parent / "model_metadata.json")
    )

    if not mdir.exists():
        raise ModelLoadError(
            f"model directory does not exist: {mdir}. "
            f"Set the MODEL_DIR env var or ship the v3 bundle under "
            f"{DEFAULT_MODEL_DIR}."
        )
    if not mdir.is_dir():
        raise ModelLoadError(f"model path is not a directory: {mdir}")

    courses_path = mdir / "courses.joblib"
    vectorizer_path = mdir / "tfidf_vectorizer.joblib"

    missing_paths = [
        p for p in (courses_path, vectorizer_path) if not p.exists()
    ]
    if missing_paths:
        raise ModelLoadError(
            "required model files missing under "
            f"{mdir}: {', '.join(p.name for p in missing_paths)}"
        )

    log.info("loading v3 model from %s", mdir)

    try:
        courses_df = joblib.load(courses_path)
    except Exception as exc:
        raise ModelLoadError(
            f"failed to load courses.joblib: {exc}"
        ) from exc

    if "deployment_text" not in courses_df.columns:
        raise ModelLoadError(
            "courses.joblib is missing required 'deployment_text' column; "
            "re-run ml/training/train_v3.py to regenerate the v3 bundle."
        )
    if "course_id" not in courses_df.columns:
        raise ModelLoadError(
            "courses.joblib is missing required 'course_id' column."
        )

    try:
        vectorizer: TfidfVectorizer = joblib.load(vectorizer_path)
    except Exception as exc:
        raise ModelLoadError(
            f"failed to load tfidf_vectorizer.joblib: {exc}"
        ) from exc

    # Build the sparse deployment matrix in-place. ``astype(np.float32)``
    # mirrors the vectorizer's ``dtype`` to keep memory predictable.
    try:
        texts = courses_df["deployment_text"].astype(str).tolist()
        tfidf_matrix = vectorizer.transform(texts).astype(np.float32, copy=False)
        tfidf_matrix = tfidf_matrix.tocsr()
    except Exception as exc:
        raise ModelLoadError(
            f"failed to transform deployment_text: {exc}. "
            f"Check that the vectorizer was fit on the same text corpus."
        ) from exc

    if not issparse(tfidf_matrix):
        raise ModelLoadError(
            "TF-IDF matrix is not sparse; refusing to load dense matrix "
            "to keep the service under 512 MB."
        )
    if tfidf_matrix.dtype != np.float32:
        tfidf_matrix = tfidf_matrix.astype(np.float32)

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
        model_version="v3",
        source=str(mdir),
        field_weights=field_weights,
        number_of_features=len(getattr(vectorizer, "vocabulary_", {}) or {}),
    )

    # Legacy metadata file (optional).
    if mfile is not None and mfile.exists():
        try:
            raw = json.loads(mfile.read_text(encoding="utf-8"))
            section = raw.get("v3", raw.get("default", raw))
            fw = section.get("field_weights") or {}
            if isinstance(fw, dict) and not field_weights:
                field_weights = {str(k): float(v) for k, v in fw.items()}
                meta.field_weights = field_weights
            meta.model_version = str(section.get("model_version", "v3"))
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

    # Sparse matrix memory footprint.
    sparse_bytes = (
        tfidf_matrix.data.nbytes
        + tfidf_matrix.indices.nbytes
        + tfidf_matrix.indptr.nbytes
    )
    sparse_mb = sparse_bytes / 1024 / 1024

    log.info(
        "v3 model ready: courses=%d vocab=%d matrix=%s dtype=%s sparse_mem=%.1f MB",
        len(rows),
        meta.number_of_features,
        tfidf_matrix.shape,
        tfidf_matrix.dtype,
        sparse_mb,
    )

    return RecommendationModelAdapter(
        courses_df=courses_df,
        row_index=index,
        rows=rows,
        tfidf_vectorizer=vectorizer,
        tfidf_matrix=tfidf_matrix,
        word_vectorizer=vectorizer,        # legacy alias
        word_matrix=tfidf_matrix,          # legacy alias
        char_vectorizer=vectorizer,        # legacy alias
        char_matrix=tfidf_matrix,          # legacy alias
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
