"""Build the canonical EduCompass 21-column training catalogue.

The source repository already contains ``data/raw/combined_courses.csv`` with
all 21 fields used by EduCompass.  This script keeps those real values where
available, fills only missing metadata with conservative fallbacks, and sets
the app-facing ``provider`` and ``organization`` fields to ``EduCompass``.

Original provider/organization/source attribution is preserved separately in
``data/processed/course_source_map.csv`` so source provenance is not lost.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "data" / "raw" / "combined_courses.csv"
DEFAULT_OUTPUT = REPO_ROOT / "data" / "processed" / "educompass_courses.csv"
DEFAULT_SOURCE_MAP = REPO_ROOT / "data" / "processed" / "course_source_map.csv"

SCHEMA = [
    "course_id",
    "course_name",
    "description",
    "skills",
    "subject",
    "level",
    "organization",
    "provider",
    "rating",
    "reviews_count",
    "students_enrolled",
    "lectures_count",
    "duration",
    "instructor",
    "price",
    "language",
    "image_url",
    "url",
    "certificate_type",
    "course_type",
    "source_file",
]

SUBJECT_RULES: list[tuple[str, tuple[str, ...]]] = [
    ("Data Science", ("data science", "machine learning", "deep learning", "artificial intelligence", "ai ", "python", "statistics", "analytics", "tensorflow", "pytorch", "nlp", "neural network")),
    ("Computer Science", ("programming", "software", "computer science", "java", "javascript", "react", "flutter", "dart", "web development", "mobile app", "algorithm", "database", "sql", "c++", "c#", "git")),
    ("Information Technology", ("cybersecurity", "cloud", "aws", "azure", "devops", "network", "linux", "it support", "information technology")),
    ("Business", ("business", "marketing", "management", "entrepreneur", "leadership", "strategy", "sales", "finance", "accounting", "economics", "project management")),
    ("Math and Logic", ("mathematics", "math", "calculus", "algebra", "geometry", "logic", "probability")),
    ("Health", ("health", "medicine", "medical", "nutrition", "nursing", "biology", "anatomy", "psychology")),
    ("Physical Science and Engineering", ("engineering", "physics", "chemistry", "electronics", "mechanical", "electrical", "civil", "robotics")),
    ("Arts and Humanities", ("art", "design", "music", "history", "philosophy", "writing", "literature", "photography")),
    ("Language Learning", ("english", "spanish", "french", "german", "arabic", "language", "grammar")),
    ("Social Sciences", ("social", "sociology", "politics", "law", "education", "teaching", "communication")),
    ("Personal Development", ("personal development", "productivity", "career", "mindfulness", "self", "communication skills")),
]

SKILL_KEYWORDS = [
    "Python", "Machine Learning", "Deep Learning", "Artificial Intelligence",
    "Data Analysis", "Data Science", "Statistics", "SQL", "Excel",
    "JavaScript", "React", "Flutter", "Dart", "Java", "C++", "C#",
    "Web Development", "Mobile Development", "Cybersecurity", "AWS",
    "Azure", "Cloud Computing", "DevOps", "Linux", "Project Management",
    "Marketing", "Finance", "Accounting", "Leadership", "Communication",
    "UI/UX Design", "Graphic Design", "Mathematics", "Engineering",
]


def _clean_text(value: object) -> str:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return ""
    text = str(value).strip()
    if text.casefold() in {"nan", "none", "null", "not found", "-"}:
        return ""
    return text


def infer_subject(name: str, description: str, skills: str) -> str:
    hay = f" {name} {description} {skills} ".casefold()
    for subject, keywords in SUBJECT_RULES:
        if any(k.casefold() in hay for k in keywords):
            return subject
    return "General Learning"


def infer_skills(name: str, description: str, subject: str) -> str:
    hay = f" {name} {description} ".casefold()
    found: list[str] = []
    for skill in SKILL_KEYWORDS:
        if skill.casefold() in hay:
            found.append(skill)
    if not found and subject and subject != "General Learning":
        found.append(subject)
    if not found:
        # Course title is a useful content signal without inventing a
        # specific technical skill the source never claimed.
        tokens = [
            t.capitalize()
            for t in re.findall(r"[A-Za-z][A-Za-z0-9+#.-]{2,}", name)
            if t.casefold() not in {"the", "and", "for", "with", "from", "course", "introduction", "learn"}
        ]
        found.extend(tokens[:4])
    if not found:
        found.append(subject or "General Learning")
    return ", ".join(dict.fromkeys(found))


def normalise_level(value: object) -> str:
    text = _clean_text(value)
    if not text:
        return "All Levels"
    low = text.casefold()
    # Some scraped rows accidentally contain a price string in the level field.
    if "price:" in low or re.fullmatch(r"[£$€]?\s*\d+(?:\.\d+)?", text):
        return "All Levels"
    if low in {"mixed", "all levels", "all level"}:
        return "All Levels"
    if "beginner" in low or "introductory" in low:
        return "Beginner"
    if "intermediate" in low and "advanced" not in low:
        return "Intermediate"
    if "advanced" in low or "expert" in low:
        return "Advanced"
    return text


def normalise_course_type(value: object) -> str:
    text = _clean_text(value)
    if not text:
        return "Course"
    low = text.casefold()
    if "special" in low:
        return "Specialization"
    if "professional certificate" in low:
        return "Professional Certificate"
    if "guided project" in low or low == "project":
        return "Guided Project"
    if "degree" in low or "masters" in low or "bachelors" in low:
        return "Degree"
    if "micromasters" in low:
        return "MicroMasters"
    if "microbachelors" in low:
        return "MicroBachelors"
    if "executive" in low:
        return "Executive Education"
    if low in {"paid", "free", "bestseller", "course"}:
        return "Course"
    return text.title()


def normalise_certificate(value: object, course_type: str) -> str:
    text = _clean_text(value)
    if text:
        low = text.casefold()
        if low in {"course", "shareable certificate"}:
            return "Course Certificate"
        if "special" in low:
            return "Specialization Certificate"
        if "professional" in low:
            return "Professional Certificate"
        if "guided" in low:
            return "Guided Project Certificate"
        return text.title()
    if course_type in {"Professional Certificate", "Specialization"}:
        return course_type
    return "Not specified"


def build(source: Path, output: Path, source_map_path: Path) -> pd.DataFrame:
    df = pd.read_csv(source, low_memory=False)
    missing_cols = [c for c in SCHEMA if c not in df.columns]
    if missing_cols:
        raise ValueError(f"Source is missing required 21-column schema fields: {missing_cols}")

    # Keep attribution before replacing the two app-facing branding fields.
    source_map = df[["course_id", "provider", "organization", "source_file", "url"]].copy()
    source_map = source_map.rename(columns={
        "provider": "original_provider",
        "organization": "original_organization",
    })
    source_map_path.parent.mkdir(parents=True, exist_ok=True)
    source_map.to_csv(source_map_path, index=False)

    out = df[SCHEMA].copy()
    out["course_name"] = out["course_name"].map(_clean_text)
    out = out[out["course_name"].str.len() > 0].copy()

    # Conservative numeric cleanup: unknown engagement is zero rather than a
    # fabricated value. Rating 0 means "not rated" and is naturally demoted.
    for col in ("rating", "reviews_count", "students_enrolled", "lectures_count"):
        out[col] = pd.to_numeric(out[col], errors="coerce").fillna(0)
    out["rating"] = out["rating"].clip(lower=0, upper=5).round(2)
    for col in ("reviews_count", "students_enrolled", "lectures_count"):
        out[col] = out[col].clip(lower=0).round().astype("int64")

    # Clean text fields first, then infer only when a source value is missing.
    for col in (
        "description", "skills", "subject", "level", "duration", "instructor",
        "price", "language", "image_url", "url", "certificate_type",
        "course_type", "source_file",
    ):
        out[col] = out[col].map(_clean_text)

    out["level"] = out["level"].map(normalise_level)
    out["course_type"] = out["course_type"].map(normalise_course_type)

    subject_values: list[str] = []
    skill_values: list[str] = []
    desc_values: list[str] = []
    cert_values: list[str] = []
    for row in out.itertuples(index=False):
        name = _clean_text(row.course_name)
        desc = _clean_text(row.description)
        skills = _clean_text(row.skills)
        subject = _clean_text(row.subject)
        if not subject:
            subject = infer_subject(name, desc, skills)
        if not skills:
            skills = infer_skills(name, desc, subject)
        if not desc:
            desc = f"Learn {name}. This course focuses on {subject.lower()} concepts and practical skills."
        subject_values.append(subject)
        skill_values.append(skills)
        desc_values.append(desc)
        cert_values.append(normalise_certificate(row.certificate_type, normalise_course_type(row.course_type)))

    out["subject"] = subject_values
    out["skills"] = skill_values
    out["description"] = desc_values
    out["certificate_type"] = cert_values
    out["duration"] = out["duration"].replace("", "Self-paced")
    out["instructor"] = out["instructor"].replace("", "Not specified")
    out["language"] = out["language"].replace("", "Not specified")
    out["price"] = out["price"].replace("", "Not specified")
    out["source_file"] = out["source_file"].replace("", "combined_courses.csv")

    # User request: EduCompass is the displayed provider + organization.
    out["provider"] = "EduCompass"
    out["organization"] = "EduCompass"

    # Preserve original IDs; remove only duplicate IDs, keeping the first source
    # row to protect all existing API/deep-link references.
    out = out.drop_duplicates(subset=["course_id"], keep="first").reset_index(drop=True)
    out = out[SCHEMA]

    output.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(output, index=False)
    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--source-map", type=Path, default=DEFAULT_SOURCE_MAP)
    args = p.parse_args()
    out = build(args.source, args.output, args.source_map)
    print(f"Wrote {len(out):,} rows × {len(out.columns)} columns to {args.output}")
    print(f"Provider values: {sorted(out['provider'].unique().tolist())}")
    print(f"Organization values: {sorted(out['organization'].unique().tolist())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
