"""Lightweight hybrid reranker that reuses the existing TF-IDF matrix.

No second ML model is loaded.  A user vector is a weighted sparse average of
course vectors from interactions; explicit preferences, quality and popularity
are combined with content similarity into one final score.
"""
from __future__ import annotations

import math
from typing import Any, Iterable

import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix

DEFAULT_INTERACTION_WEIGHTS = {
    "view": 1.0,
    "click": 1.0,
    "favorite": 3.0,
    "enroll": 5.0,
    "complete": 7.0,
    "rating_positive": 5.0,
    "dislike": -3.0,
}


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        raw = value.split("|") if "|" in value else value.split(",")
    elif isinstance(value, (list, tuple, set)):
        raw = value
    else:
        raw = [value]
    return [str(v).strip() for v in raw if str(v).strip()]


def _normalize01(arr: np.ndarray) -> np.ndarray:
    x = np.nan_to_num(np.asarray(arr, dtype=np.float32), nan=0.0, posinf=0.0, neginf=0.0)
    if x.size == 0:
        return x
    lo = float(x.min())
    hi = float(x.max())
    if hi <= lo:
        return np.zeros_like(x, dtype=np.float32) if hi <= 0 else np.ones_like(x, dtype=np.float32)
    return ((x - lo) / (hi - lo)).astype(np.float32)


def _log_norm_series(df: pd.DataFrame, column: str) -> np.ndarray:
    if column not in df.columns:
        return np.zeros(len(df), dtype=np.float32)
    vals = pd.to_numeric(df[column], errors="coerce").fillna(0).clip(lower=0).to_numpy(dtype=np.float32)
    vals = np.log1p(vals)
    max_v = float(vals.max()) if vals.size else 0.0
    return (vals / max_v).astype(np.float32) if max_v > 0 else np.zeros_like(vals, dtype=np.float32)


def _quality_scores(df: pd.DataFrame) -> np.ndarray:
    if "data_quality_score" in df.columns:
        return np.clip(pd.to_numeric(df["data_quality_score"], errors="coerce").fillna(0).to_numpy(dtype=np.float32), 0, 1)
    rating = (
        pd.to_numeric(df["rating"], errors="coerce").fillna(0).clip(0, 5).to_numpy(dtype=np.float32) / 5.0
        if "rating" in df.columns else np.zeros(len(df), dtype=np.float32)
    )
    reviews = _log_norm_series(df, "reviews_count")
    # Weighted rating with evidence: a 5.0 course with two reviews does not
    # automatically outrank a 4.8 course with thousands of reviews.
    return np.clip(0.75 * rating + 0.25 * reviews, 0, 1).astype(np.float32)


def _popularity_scores(df: pd.DataFrame) -> np.ndarray:
    if "popularity_score" in df.columns:
        return np.clip(pd.to_numeric(df["popularity_score"], errors="coerce").fillna(0).to_numpy(dtype=np.float32), 0, 1)
    students = _log_norm_series(df, "students_enrolled")
    reviews = _log_norm_series(df, "reviews_count")
    return np.clip(0.65 * students + 0.35 * reviews, 0, 1).astype(np.float32)


def _preference_query(preferences: dict[str, Any] | None, interests: Iterable[str] | None) -> str:
    prefs = preferences or {}
    bits: list[str] = []
    bits.extend(_list(prefs.get("subjects")) * 3)
    bits.extend(_list(prefs.get("skills")) * 4)
    level = _text(prefs.get("level"))
    if level:
        bits.extend([level] * 2)
    for key in ("course_type", "certificate_type"):
        value = _text(prefs.get(key))
        if value:
            bits.append(value)
    bits.extend([_text(v) for v in (interests or []) if _text(v)] * 2)
    return " ".join(bits).strip()


def _content_scores(adapter, query: str) -> np.ndarray:
    if not query:
        return np.zeros(adapter.number_of_courses, dtype=np.float32)
    from .model_loader import _row_similarities
    vec = adapter.tfidf_vectorizer.transform([query])
    scores = _row_similarities(vec, adapter.tfidf_matrix)
    return np.clip(scores, 0, 1).astype(np.float32)


def _preference_match_scores(df: pd.DataFrame, preferences: dict[str, Any] | None) -> np.ndarray:
    prefs = preferences or {}
    n = len(df)
    score = np.zeros(n, dtype=np.float32)
    max_weight = 0.0

    subjects = {v.casefold() for v in _list(prefs.get("subjects"))}
    if subjects and "subject" in df.columns:
        series = df["subject"].astype("string").fillna("").str.casefold()
        score += 0.35 * series.isin(subjects).to_numpy(dtype=np.float32)
        max_weight += 0.35

    skills = [v.casefold() for v in _list(prefs.get("skills"))]
    if skills and "skills" in df.columns:
        series = df["skills"].astype("string").fillna("").str.casefold()
        # Fraction of selected skills mentioned in each course.
        matches = np.zeros(n, dtype=np.float32)
        for skill in skills:
            matches += series.str.contains(skill, regex=False).to_numpy(dtype=np.float32)
        matches /= max(len(skills), 1)
        score += 0.30 * np.clip(matches, 0, 1)
        max_weight += 0.30

    level = _text(prefs.get("level")).casefold()
    if level and "level" in df.columns:
        series = df["level"].astype("string").fillna("").str.casefold()
        # "Beginner Level" and "Beginner" should both match.
        score += 0.15 * series.str.contains(level, regex=False).to_numpy(dtype=np.float32)
        max_weight += 0.15

    course_type = _text(prefs.get("course_type")).casefold()
    if course_type and "course_type" in df.columns:
        series = df["course_type"].astype("string").fillna("").str.casefold()
        score += 0.08 * series.str.contains(course_type, regex=False).to_numpy(dtype=np.float32)
        max_weight += 0.08

    certificate = _text(prefs.get("certificate_type")).casefold()
    if certificate and "certificate_type" in df.columns:
        series = df["certificate_type"].astype("string").fillna("").str.casefold()
        if certificate in {"yes", "certificate", "with certificate"}:
            match = ~series.isin({"", "not specified", "none", "no certificate"})
        elif certificate in {"no", "without certificate"}:
            match = series.isin({"", "not specified", "none", "no certificate"})
        else:
            match = series.str.contains(certificate, regex=False)
        score += 0.07 * match.to_numpy(dtype=np.float32)
        max_weight += 0.07

    price = _text(prefs.get("price_preference")).casefold()
    if price and "is_free" in df.columns:
        free = df["is_free"].astype(bool).to_numpy()
        if price in {"free", "free only"}:
            match = free
        elif price in {"paid", "paid only"}:
            match = ~free
        else:
            match = np.ones(n, dtype=bool)
        score += 0.05 * match.astype(np.float32)
        max_weight += 0.05

    return np.clip(score / max_weight, 0, 1).astype(np.float32) if max_weight > 0 else score


def _behavior_scores(
    adapter,
    interactions: Iterable[dict[str, Any]] | None,
    favorites_ids: Iterable[str] | None,
    history_ids: Iterable[str] | None,
) -> tuple[np.ndarray, bool]:
    aggregated: dict[tuple[str, str], float] = {}
    for item in interactions or []:
        if not isinstance(item, dict):
            continue
        cid = _text(item.get("course_id"))
        kind = _text(item.get("interaction_type")).casefold()
        if not cid or cid not in adapter.row_index or kind not in DEFAULT_INTERACTION_WEIGHTS:
            continue
        try:
            weight = float(item.get("weight", DEFAULT_INTERACTION_WEIGHTS[kind]))
        except (TypeError, ValueError):
            weight = DEFAULT_INTERACTION_WEIGHTS[kind]
        # Multiple recent views can add evidence, but cap per course/type so a
        # refresh loop cannot dominate the profile.
        key = (cid, kind)
        aggregated[key] = max(-10.0, min(10.0, aggregated.get(key, 0.0) + weight))

    # Backward compatibility: existing favourites/history immediately work even
    # before the new interaction table has collected events.
    existing = set(aggregated)
    for cid in favorites_ids or []:
        cid = str(cid)
        if cid in adapter.row_index and (cid, "favorite") not in existing:
            aggregated[(cid, "favorite")] = DEFAULT_INTERACTION_WEIGHTS["favorite"]
    for cid in history_ids or []:
        cid = str(cid)
        if cid in adapter.row_index and (cid, "view") not in existing:
            aggregated[(cid, "view")] = DEFAULT_INTERACTION_WEIGHTS["view"]

    positives: list[tuple[int, float]] = []
    negatives: list[tuple[int, float]] = []
    for (cid, _kind), weight in aggregated.items():
        idx = adapter.row_index.get(cid)
        if idx is None or weight == 0:
            continue
        (positives if weight > 0 else negatives).append((idx, abs(weight)))

    n = adapter.number_of_courses
    if not positives and not negatives:
        return np.zeros(n, dtype=np.float32), False

    from .model_loader import _row_similarities

    def profile_score(rows: list[tuple[int, float]]) -> np.ndarray:
        if not rows:
            return np.zeros(n, dtype=np.float32)
        profile: csr_matrix | None = None
        total = 0.0
        for idx, weight in rows:
            piece = adapter.tfidf_matrix[idx].multiply(np.float32(weight))
            profile = piece if profile is None else profile + piece
            total += weight
        if profile is None or total <= 0:
            return np.zeros(n, dtype=np.float32)
        profile = profile.multiply(np.float32(1.0 / total)).tocsr()
        return np.clip(_row_similarities(profile, adapter.tfidf_matrix), 0, 1)

    positive = profile_score(positives)
    negative = profile_score(negatives)
    behavior = np.clip(positive - 0.65 * negative, 0, 1).astype(np.float32)
    return behavior, bool(positives)


def _reasons_for_row(
    row: pd.Series,
    *,
    preferences: dict[str, Any] | None,
    content: float,
    behavior: float,
    quality: float,
    popularity: float,
) -> list[str]:
    prefs = preferences or {}
    reasons: list[str] = []
    subject = _text(row.get("subject"))
    if subject and subject.casefold() in {v.casefold() for v in _list(prefs.get("subjects"))}:
        reasons.append(f"Matches {subject}")
    selected_skills = _list(prefs.get("skills"))
    row_skills = _text(row.get("skills")).casefold()
    for skill in selected_skills:
        if skill.casefold() in row_skills:
            reasons.append(f"Matches {skill}")
            break
    if behavior >= 0.30:
        reasons.append("Based on your learning activity")
    elif content >= 0.25:
        reasons.append("Matches your learning preferences")
    if quality >= 0.75:
        reasons.append("Highly rated")
    if popularity >= 0.75:
        reasons.append("Popular with learners")
    return reasons[:3] or ["Recommended for you"]


def rank_courses(
    adapter,
    *,
    preferences: dict[str, Any] | None = None,
    interests: Iterable[str] | None = None,
    interactions: Iterable[dict[str, Any]] | None = None,
    favorites_ids: Iterable[str] | None = None,
    history_ids: Iterable[str] | None = None,
    enrolled_ids: Iterable[str] | None = None,
    limit: int = 10,
    mode: str = "for_you",
    query_text: str = "",
) -> list[dict[str, Any]]:
    from .model_loader import course_row_to_slim

    n = adapter.number_of_courses
    if n == 0 or limit <= 0:
        return []

    preference_query = _preference_query(preferences, interests)
    goal_query = _text(query_text)
    # For goal searches, the learner's explicit goal remains the dominant
    # semantic signal while stored preferences gently steer ties/relevance.
    query = " ".join(
        part for part in ([goal_query] * 4 + [preference_query]) if part
    ).strip()
    content = _content_scores(adapter, query)
    pref = _preference_match_scores(adapter.courses_df, preferences)
    quality = _quality_scores(adapter.courses_df)
    popularity = _popularity_scores(adapter.courses_df)
    behavior, has_behavior = _behavior_scores(
        adapter, interactions, favorites_ids, history_ids
    )

    if mode == "popular":
        final = 0.30 * content + 0.15 * pref + 0.15 * quality + 0.40 * popularity
    elif mode == "top_rated":
        final = 0.30 * content + 0.15 * pref + 0.45 * quality + 0.10 * popularity
    elif mode == "goal":
        final = 0.65 * content + 0.18 * pref + 0.10 * quality + 0.07 * popularity
    elif has_behavior:
        final = 0.45 * content + 0.20 * behavior + 0.15 * pref + 0.10 * quality + 0.10 * popularity
    else:
        # Cold-start: explicit preferences dominate until behavior exists.
        final = 0.45 * content + 0.20 * pref + 0.20 * quality + 0.15 * popularity

    final = np.nan_to_num(final.astype(np.float32), nan=0.0, posinf=0.0, neginf=0.0)
    excluded = {str(x) for x in (enrolled_ids or [])}
    if excluded:
        for cid in excluded:
            idx = adapter.row_index.get(cid)
            if idx is not None:
                final[idx] = -1.0

    k = min(max(limit * 4, limit), n)
    top_idx = np.argpartition(-final, kth=k - 1)[:k]
    top_idx = top_idx[np.argsort(-final[top_idx])]

    out: list[dict[str, Any]] = []
    for raw_idx in top_idx:
        idx = int(raw_idx)
        if final[idx] < 0:
            continue
        row = adapter.courses_df.iloc[idx]
        item = course_row_to_slim(row)
        item["similarity_score"] = round(float(content[idx]), 6)
        item["final_score"] = round(float(final[idx]), 6)
        item["reasons"] = _reasons_for_row(
            row,
            preferences=preferences,
            content=float(content[idx]),
            behavior=float(behavior[idx]),
            quality=float(quality[idx]),
            popularity=float(popularity[idx]),
        )
        out.append(item)
        if len(out) >= limit:
            break
    return out
