"""SQLAlchemy tables for user data.

Course records are NOT stored here — they live in the loaded TF-IDF bundle.
This module only persists user accounts, favourites, history, progress,
and notifications.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Float,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import relationship
from werkzeug.security import check_password_hash, generate_password_hash

from .extensions import db


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


PAYMENT_STATUS_INITIATED = "INITIATED"
PAYMENT_STATUS_PENDING = "PENDING"
PAYMENT_STATUS_VALID = "VALID"
PAYMENT_STATUS_VALIDATED = "VALIDATED"
PAYMENT_STATUS_REVIEW_REQUIRED = "REVIEW_REQUIRED"
PAYMENT_STATUS_FAILED = "FAILED"
PAYMENT_STATUS_CANCELLED = "CANCELLED"
PAYMENT_STATUS_INITIATION_FAILED = "INITIATION_FAILED"
PAYMENT_STATUS_VALIDATION_FAILED = "VALIDATION_FAILED"


class User(db.Model):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True)
    full_name = Column(String(120), nullable=False)
    email = Column(String(180), unique=True, nullable=False, index=True)
    # Firebase Auth UID — the source of truth for identity. The SQL
    # row is a thin mirror so existing favourites / progress / history
    # endpoints keep working with the same JWT identity (`User.id`).
    firebase_uid = Column(String(128), unique=True, nullable=True,
                          index=True)
    # Local password hash kept for backward compatibility. Existing
    # users created before Firebase cutover still need to be able to
    # authenticate. New users register through Firebase and the hash
    # is set to a random sentinel value.
    password_hash = Column(String(255), nullable=False)
    phone_number = Column(String(32), nullable=True, index=True)
    phone_verified = Column(Boolean, nullable=False, default=False)
    avatar_key = Column(String(64), nullable=False, default="default")
    created_at = Column(DateTime, nullable=False, default=_utcnow)
    updated_at = Column(DateTime, nullable=False,
                        default=_utcnow, onupdate=_utcnow)

    interests = relationship("UserInterest", backref="user",
                             cascade="all, delete-orphan")
    preference = relationship("UserPreference", backref="user", uselist=False,
                              cascade="all, delete-orphan")
    interactions = relationship("UserInteraction", backref="user",
                                cascade="all, delete-orphan")
    favorites = relationship("Favorite", backref="user",
                             cascade="all, delete-orphan")
    history = relationship("History", backref="user",
                           cascade="all, delete-orphan")
    progress = relationship("CourseProgress", backref="user",
                            cascade="all, delete-orphan")
    learning_progress = relationship("LearningPathProgress", backref="user",
                                     cascade="all, delete-orphan")
    enrollments = relationship("Enrollment", backref="user",
                               cascade="all, delete-orphan")
    payments = relationship("Payment", backref="user",
                            cascade="all, delete-orphan")

    def set_password(self, password: str) -> None:
        self.password_hash = generate_password_hash(password)

    def check_password(self, password: str) -> bool:
        return check_password_hash(self.password_hash, password) # type: ignore

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "full_name": self.full_name,
            "email": self.email,
            "firebase_uid": self.firebase_uid,
            "phone_number": self.phone_number,
            "phone_verified": self.phone_verified,
            "avatar_key": self.avatar_key,
            "interests": [i.interest for i in self.interests],
            "created_at": self.created_at.isoformat() if self.created_at else None, # type: ignore
        }


class UserInterest(db.Model):
    __tablename__ = "user_interests"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    interest = Column(String(80), nullable=False)

    __table_args__ = (
        UniqueConstraint("user_id", "interest", name="uq_user_interest"),
    )


class UserPreference(db.Model):
    """Structured preferences collected during first-launch onboarding."""

    __tablename__ = "user_preferences"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, unique=True, index=True)
    preferred_subjects = Column(Text, nullable=False, default="[]")
    preferred_skills = Column(Text, nullable=False, default="[]")
    preferred_level = Column(String(80), nullable=False, default="")
    preferred_course_type = Column(String(100), nullable=False, default="")
    preferred_certificate_type = Column(String(100), nullable=False, default="")
    preferred_provider = Column(String(120), nullable=False, default="EduCompass")
    preferred_organization = Column(String(120), nullable=False, default="EduCompass")
    price_preference = Column(String(32), nullable=False, default="")
    updated_at = Column(DateTime, nullable=False, default=_utcnow, onupdate=_utcnow)


class UserInteraction(db.Model):
    """Implicit/explicit learner signals used by the hybrid reranker."""

    __tablename__ = "user_interactions"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=False, index=True)
    interaction_type = Column(String(30), nullable=False, index=True)
    weight = Column(Float, nullable=False, default=1.0)
    created_at = Column(DateTime, nullable=False, default=_utcnow, index=True)


class Favorite(db.Model):
    __tablename__ = "favorites"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=False, index=True)
    created_at = Column(DateTime, nullable=False, default=_utcnow)

    __table_args__ = (
        UniqueConstraint("user_id", "course_id", name="uq_user_favorite"),
    )


class History(db.Model):
    __tablename__ = "history"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=True, index=True)
    query = Column(String(255), nullable=True) # type: ignore
    action = Column(String(64), nullable=False)
    created_at = Column(DateTime, nullable=False, default=_utcnow)


class CourseProgress(db.Model):
    __tablename__ = "course_progress"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=False, index=True)
    progress = Column(Integer, nullable=False, default=0)
    completed = Column(Boolean, nullable=False, default=False)
    started_at = Column(DateTime, nullable=False, default=_utcnow)
    updated_at = Column(DateTime, nullable=False,
                        default=_utcnow, onupdate=_utcnow)

    __table_args__ = (
        UniqueConstraint("user_id", "course_id", name="uq_user_course"),
    )


class LearningPathProgress(db.Model):
    __tablename__ = "learning_path_progress"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    path_id = Column(String(64), nullable=False, index=True)
    step_id = Column(String(64), nullable=False)
    completed = Column(Boolean, nullable=False, default=False)
    updated_at = Column(DateTime, nullable=False,
                        default=_utcnow, onupdate=_utcnow)

    __table_args__ = (
        UniqueConstraint("user_id", "path_id", "step_id",
                         name="uq_user_path_step"),
    )


class Notification(db.Model):
    __tablename__ = "notifications"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    title = Column(String(180), nullable=False)
    body = Column(String(500), nullable=False, default="")
    category = Column(String(64), nullable=False, default="general")
    course_id = Column(String(64), nullable=True)
    is_read = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime, nullable=False, default=_utcnow)


class Enrollment(db.Model):
    """A paid (or free) course the user has enrolled in.

    Mirrors the Firestore ``users/{uid}/enrollments/{courseId}`` doc
    schema so the Flutter client can keep both stores in sync:

        course_id         str
        payment_method    str   (e.g. "bKash", "Nagad", "Card", "free")
        transaction_id    str   (gateway txn id; "free" for no-payment rows)
        payment_status    str   (default "completed")
        enrolled_at       ISO-8601 UTC timestamp

    Unique on ``(user_id, course_id)`` so a re-enroll just upserts.
    """

    __tablename__ = "enrollments"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=False, index=True)
    payment_method = Column(String(32), nullable=False, default="")
    transaction_id = Column(String(64), nullable=False, default="")
    payment_status = Column(String(32), nullable=False, default="completed")
    enrolled_at = Column(DateTime, nullable=False, default=_utcnow)

    __table_args__ = (
        UniqueConstraint("user_id", "course_id", name="uq_user_enrollment"),
    )

    def to_dict(self) -> dict:
        return {
            "course_id": self.course_id,
            "payment_method": self.payment_method,
            "transaction_id": self.transaction_id,
            "payment_status": self.payment_status,
            "enrolled_at": self.enrolled_at.isoformat() if self.enrolled_at else None, # type: ignore
        }


class Payment(db.Model):
    """Tracks gateway payment lifecycle for course enrollment."""

    __tablename__ = "payments"

    id = Column(Integer, primary_key=True)
    transaction_id = Column(String(80), unique=True, nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    course_id = Column(String(64), nullable=False, index=True)
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(8), nullable=False, default="BDT")
    status = Column(String(32), nullable=False, default=PAYMENT_STATUS_INITIATED,
                    index=True)
    session_key = Column(String(128), nullable=True)
    gateway_url = Column(String(512), nullable=True)
    validation_id = Column(String(128), nullable=True)
    bank_transaction_id = Column(String(128), nullable=True)
    card_type = Column(String(64), nullable=True)
    risk_level = Column(Integer, nullable=True)
    risk_title = Column(String(255), nullable=True)
    validated = Column(Boolean, nullable=False, default=False)
    enrollment_completed = Column(Boolean, nullable=False, default=False)
    gateway_payload = Column(Text, nullable=True)
    created_at = Column(DateTime, nullable=False, default=_utcnow)
    updated_at = Column(DateTime, nullable=False,
                        default=_utcnow, onupdate=_utcnow)

    __table_args__ = (
        UniqueConstraint("transaction_id", name="uq_payment_transaction_id"),
    )

    def to_dict(self) -> dict:
        return {
            "transaction_id": self.transaction_id,
            "course_id": self.course_id,
            "status": self.status,
            "amount": str(self.amount) if self.amount is not None else None,
            "currency": self.currency,
            "validated": bool(self.validated),
            "enrollment_completed": bool(self.enrollment_completed),
            "card_type": self.card_type,
            "bank_transaction_id": self.bank_transaction_id,
            "risk_level": self.risk_level,
            "risk_title": self.risk_title,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None, # type: ignore
        }


__all__ = [
    "User",
    "UserInterest",
    "Favorite",
    "History",
    "CourseProgress",
    "LearningPathProgress",
    "Notification",
    "Enrollment",
    "Payment",
    "PAYMENT_STATUS_INITIATED",
    "PAYMENT_STATUS_PENDING",
    "PAYMENT_STATUS_VALID",
    "PAYMENT_STATUS_VALIDATED",
    "PAYMENT_STATUS_REVIEW_REQUIRED",
    "PAYMENT_STATUS_FAILED",
    "PAYMENT_STATUS_CANCELLED",
    "PAYMENT_STATUS_INITIATION_FAILED",
    "PAYMENT_STATUS_VALIDATION_FAILED",
]
