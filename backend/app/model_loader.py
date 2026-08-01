"""Standalone loader for the pre-trained TF-IDF course recommender.

Loads the v2 bundle in ``E:/Flutter_app/ml/artifacts/models/v2/`` (plus the
shared metadata in ``model_metadata.json``) and exposes a small
``RecommendationModelAdapter`` that the Flask routes consume.

Public surface required by ``model_service.py``:

    BundleMeta, CourseRow, ModelLoadError,
    RecommendationModelAdapter, load_adapter
"""

from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

import joblib
import numpy as np
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity, linear_kernel


_REPO_ROOT = Path(__file__).resolve().parents[2]

_DEFAULT_MODEL_DIR = Path(
    os.getenv(
        "MODEL_DIR",
        str(_REPO_ROOT / "ml" / "artifacts" / "models" / "v2"),
    )
).resolve()

_DEFAULT_META_PATH = (
    _REPO_ROOT / "ml" / "artifacts" / "models" / "model_metadata.json"
)


class ModelLoadError(Exception):
    """Raised when the v2 bundle cannot be assembled."""


def _safe_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value)


# Columns from the v2 combined_courses_app.csv schema
_COURSE_FIELDS: tuple[str, ...] = (
    "course_id", "course_name", "description", "skills", "subject", "level",
    "organization", "provider", "rating", "reviews_count", "students_enrolled",
    "lectures_count", "duration", "instructor", "price", "language",
    "image_url", "url", "certificate_type", "course_type", "is_free",
    "has_image", "has_course_url", "popularity_score", "data_quality_score",
)


def _parse_skills(value: Any) -> list[str]:
    """Normalise the messy ``skills`` column into a clean list of strings.

    The combined dataset stores skills in three different formats:

    * a comma-separated string — ``"Python, ML, Statistics"``
    * a Python list literal — ``"['Python', 'ML']"``
    * a JSON-ish list — ``'["Python", "ML"]'``
    * an actual list (rare; happens after pandas re-load)

    This helper returns a list of trimmed, non-empty strings and never raises,
    so the API contract is stable even if a row has dirty data.
    """
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
            parts = re.split(r",\s*", inner)
            return [
                p.strip().strip("'\"")
                for p in parts
                if p.strip().strip("'\"")
            ]
        return []
    parts = re.split(r",\s*", text)
    return [p.strip() for p in parts if p.strip()]


def course_row_to_dict(row: pd.Series) -> dict:
    """Convert a DataFrame row to the JSON dict expected by the routes."""
    out: dict = {}
    for f in _COURSE_FIELDS:
        if f not in row.index:
            out[f] = None
            continue
        v = row[f]
        if v is None:
            out[f] = None
        elif isinstance(v, float) and (math.isnan(v) or pd.isna(v)):
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
    out["id"] = str(out.get("course_id") or row.name)
    out["name"] = out.get("course_name") or ""
    out["skills"] = _parse_skills(out.get("skills"))
    return out


@dataclass
class CourseRow:
    course_id: str
    payload: dict
    text: str


@dataclass
class BundleMeta:
    model_version: str = "v2"
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
    tfidf_matrix: Any  # sparse
    word_vectorizer: TfidfVectorizer
    word_matrix: Any  # sparse
    char_vectorizer: TfidfVectorizer
    char_matrix: Any  # sparse
    meta: BundleMeta

    # -- direct lookups --------------------------------------------------

    @property
    def number_of_courses(self) -> int:
        return len(self.rows)

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

    # -- search ----------------------------------------------------------

    def _autocomplete_vocab(self, prefix: str, n: int) -> list[str]:
        """Naive prefix scan over course name + skills for live autocomplete."""
        prefix = prefix.lower().strip()
        if not prefix:
            return []
        seen: set[str] = set()
        out: list[str] = []
        for row in self.rows:
            for source in (row.payload.get("course_name"), row.payload.get("skills")):
                if isinstance(source, (list, tuple)):
                    source = " ".join(str(s) for s in source)
                tokens = re.split(r"[^a-z0-9]+", (source or "").lower())
                for t in tokens:
                    if t.startswith(prefix) and t not in seen and len(t) > 2:
                        seen.add(t)
                        out.append(t)
                        if len(out) >= n:
                            return out
        return out

    def suggest(self, prefix: str, n: int = 8) -> list[str]:
        return self._autocomplete_vocab(prefix, n)

    def search_courses(
        self,
        query: str,
        limit: int = 20,
        offset: int = 0,
        subject: Optional[str] = None,
        level: Optional[str] = None,
        provider: Optional[str] = None,
        is_free: Optional[bool] = None,
    ) -> list[dict]:
        q = (query or "").strip().lower()
        if not q:
            results = self.list_courses(limit=limit, offset=offset)
        else:
            q_vec = self.tfidf_vectorizer.transform([q])
            sims = linear_kernel(q_vec, self.tfidf_matrix).ravel()
            order = np.argsort(-sims)
            ids: list[str] = []
            for i in order:
                if sims[i] <= 0:
                    break
                ids.append(self.rows[int(i)].course_id)
            df = self.courses_df.copy()
            df["__match_score"] = sims
            df = df.set_index("course_id").loc[ids].reset_index()
            results = [course_row_to_dict(df.iloc[i]) for i in range(len(df))]
        results = self._apply_filters(
            results, subject=subject, level=level,
            provider=provider, is_free=is_free,
        )
        return results[offset:offset + limit]

    def _apply_filters(
        self, results: list[dict], *, subject, level, provider, is_free,
    ) -> list[dict]:
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

    # -- popularity ------------------------------------------------------

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

    # -- recommendation --------------------------------------------------

    def recommend_similar(self, course_id: str, limit: int = 6) -> list[dict]:
        idx = self.row_index.get(str(course_id))
        if idx is None:
            return []
        target = self.tfidf_matrix[idx]
        sims = linear_kernel(target, self.tfidf_matrix).ravel()
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
        return self.search_courses(query, limit=limit)

    def recommend_personalized(
        self,
        interests: Iterable[str],
        history_ids: Iterable[str],
        favorites_ids: Iterable[str],
        limit: int = 10,
    ) -> list[dict]:
        parts: list[str] = [s for s in (interests or []) if s]
        # seed from favorite / history rows
        seed_ids = list(dict.fromkeys(list(favorites_ids or []) + list(history_ids or [])))
        for cid in seed_ids:
            idx = self.row_index.get(str(cid))
            if idx is None:
                continue
            parts.append(self.rows[idx].text[:500])
        if not parts:
            return self.popular(limit=limit)
        q = " ".join(parts)
        return self.recommend_query(q, limit=limit)

    # -- filter listings -------------------------------------------------

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


def load_adapter(
    model_dir: str | Path | None = None,
    meta_path: str | Path | None = None,
) -> Optional[RecommendationModelAdapter]:
    """Load the v2 bundle, returning ``None`` on any structural error."""
    mdir = Path(model_dir) if model_dir else _DEFAULT_MODEL_DIR
    mfile = Path(meta_path) if meta_path else _DEFAULT_META_PATH
    try:
        courses_df = joblib.load(mdir / "courses.joblib")
        tfidf_vec = joblib.load(mdir / "tfidf_vectorizer.joblib")
        tfidf_mat = joblib.load(mdir / "tfidf_matrix.joblib")
        # Optional per-field vectorizers (only present in v2+).
        field_vectorizers = {}
        fv_path = mdir / "field_vectorizers.joblib"
        if fv_path.exists():
            try:
                loaded = joblib.load(fv_path)
                if isinstance(loaded, dict):
                    field_vectorizers = loaded
            except Exception:
                field_vectorizers = {}
    except Exception as exc:
        raise ModelLoadError(f"failed to load joblib from {mdir}: {exc}") from exc

    meta = BundleMeta(model_version="v2", source=str(mdir))
    meta.number_of_features = len(getattr(tfidf_vec, "vocabulary_", {}) or {})
    config_path = mdir / "model_config.json"
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8"))
            fw = cfg.get("field_weights") or {}
            if isinstance(fw, dict):
                meta.field_weights = {str(k): float(v) for k, v in fw.items()}
        except Exception:
            pass
    if mfile.exists():
        try:
            raw = json.loads(mfile.read_text(encoding="utf-8"))
            section = raw.get("v2", raw.get("default", raw))
            fw = section.get("field_weights") or {}
            if isinstance(fw, dict) and not meta.field_weights:
                meta.field_weights = {
                    str(k): float(v) for k, v in fw.items()
                }
            meta.model_version = str(section.get("model_version", "v2"))
        except Exception:
            pass  # non-fatal

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
        rows.append(CourseRow(course_id=cid, payload=course_row_to_dict(row), text=text))

    return RecommendationModelAdapter(
        courses_df=courses_df,
        row_index=index,
        rows=rows,
        tfidf_vectorizer=tfidf_vec,
        tfidf_matrix=tfidf_mat,
        word_vectorizer=tfidf_vec,  # alias: routes.py may reference either
        word_matrix=tfidf_mat,
        char_vectorizer=tfidf_vec,
        char_matrix=tfidf_mat,
        meta=meta,
    )
