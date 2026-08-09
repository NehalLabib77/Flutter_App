"""User preference + interaction persistence for hybrid recommendations."""
from __future__ import annotations

import json
from typing import Any

from .database_models import UserInteraction, UserPreference
from .extensions import db

INTERACTION_WEIGHTS: dict[str, float] = {
    "view": 1.0,
    "click": 1.0,
    "favorite": 3.0,
    "enroll": 5.0,
    "complete": 7.0,
    "rating_positive": 5.0,
    "dislike": -3.0,
}


def _clean_list(value: Any, *, limit: int = 20) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        parts = value.split("|") if "|" in value else value.split(",")
    elif isinstance(value, (list, tuple, set)):
        parts = list(value)
    else:
        parts = [value]
    out: list[str] = []
    seen: set[str] = set()
    for item in parts:
        text = str(item).strip()
        key = text.casefold()
        if text and key not in seen:
            seen.add(key)
            out.append(text)
        if len(out) >= limit:
            break
    return out


def _clean_scalar(value: Any, *, default: str = "") -> str:
    text = "" if value is None else str(value).strip()
    if text.casefold() in {"any", "all", "all levels", "no preference"}:
        return ""
    return text or default


def normalize_preferences(payload: Any) -> dict[str, Any]:
    """Return one stable preference payload used by routes and ranking.

    Both Flutter-friendly names (``subjects``) and DB/spec names
    (``preferred_subjects``) are accepted so clients can evolve without
    breaking old sessions.
    """
    data = payload if isinstance(payload, dict) else {}
    return {
        "subjects": _clean_list(data.get("subjects", data.get("preferred_subjects"))),
        "skills": _clean_list(data.get("skills", data.get("preferred_skills"))),
        "level": _clean_scalar(data.get("level", data.get("preferred_level"))),
        "course_type": _clean_scalar(data.get("course_type", data.get("preferred_course_type"))),
        "certificate_type": _clean_scalar(data.get("certificate_type", data.get("preferred_certificate_type"))),
        "price_preference": _clean_scalar(data.get("price_preference")),
        "provider": _clean_scalar(data.get("provider", data.get("preferred_provider"))),
        "organization": _clean_scalar(data.get("organization", data.get("preferred_organization"))),
    }


def preferences_are_empty(preferences: dict[str, Any] | None) -> bool:
    if not preferences:
        return True
    return not any(
        preferences.get(key)
        for key in (
            "subjects", "skills", "level", "course_type",
            "certificate_type", "price_preference",
        )
    )


def _dumps_list(values: list[str]) -> str:
    return json.dumps(values, ensure_ascii=False)


def _loads_list(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        raw = json.loads(value)
        return _clean_list(raw)
    except (ValueError, TypeError):
        return _clean_list(value)


def get_user_preferences(user_id: int) -> dict[str, Any]:
    row = UserPreference.query.filter_by(user_id=user_id).first()
    if row is None:
        return normalize_preferences({})
    return normalize_preferences({
        "subjects": _loads_list(row.preferred_subjects),
        "skills": _loads_list(row.preferred_skills),
        "level": row.preferred_level,
        "course_type": row.preferred_course_type,
        "certificate_type": row.preferred_certificate_type,
        "price_preference": row.price_preference,
        "provider": row.preferred_provider,
        "organization": row.preferred_organization,
    })


def upsert_user_preferences(
    user_id: int,
    preferences: dict[str, Any],
    *,
    commit: bool = True,
) -> dict[str, Any]:
    prefs = normalize_preferences(preferences)
    row = UserPreference.query.filter_by(user_id=user_id).first()
    if row is None:
        row = UserPreference(user_id=user_id)
        db.session.add(row)
    row.preferred_subjects = _dumps_list(prefs["subjects"])
    row.preferred_skills = _dumps_list(prefs["skills"])
    row.preferred_level = prefs["level"]
    row.preferred_course_type = prefs["course_type"]
    row.preferred_certificate_type = prefs["certificate_type"]
    row.price_preference = prefs["price_preference"]
    row.preferred_provider = prefs["provider"] or "EduCompass"
    row.preferred_organization = prefs["organization"] or "EduCompass"
    if commit:
        db.session.commit()
    return prefs


def record_interaction(
    user_id: int,
    course_id: str,
    interaction_type: str,
    *,
    weight: float | None = None,
    commit: bool = True,
) -> UserInteraction | None:
    kind = str(interaction_type or "").strip().casefold()
    if kind not in INTERACTION_WEIGHTS:
        return None
    cid = str(course_id or "").strip()
    if not cid:
        return None
    effective = INTERACTION_WEIGHTS[kind] if weight is None else float(weight)
    # Bound custom weights so a malformed client cannot overwhelm every other
    # ranking signal. Server-generated events use the defaults above.
    effective = max(-10.0, min(10.0, effective))
    row = UserInteraction(
        user_id=user_id,
        course_id=cid,
        interaction_type=kind,
        weight=effective,
    )
    db.session.add(row)
    if commit:
        db.session.commit()
    return row


def get_recent_interactions(user_id: int, *, limit: int = 300) -> list[dict[str, Any]]:
    rows = (
        UserInteraction.query
        .filter_by(user_id=user_id)
        .order_by(UserInteraction.created_at.desc())
        .limit(max(1, min(int(limit), 1000)))
        .all()
    )
    return [
        {
            "course_id": row.course_id,
            "interaction_type": row.interaction_type,
            "weight": float(row.weight),
            "timestamp": row.created_at.isoformat() if row.created_at else None,
        }
        for row in rows
    ]
