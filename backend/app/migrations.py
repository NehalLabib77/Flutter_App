"""Lightweight, additive SQLite migrations.

SQLAlchemy's ``db.create_all()`` only creates tables that don't yet
exist — it never adds new columns to an existing table. That left the
``firebase_uid`` column missing on the dev database after the Firebase
cutover, causing::

    sqlalchemy.exc.OperationalError: no such column: users.firebase_uid

We run these migrations automatically at app startup so a developer
who already has a populated ``educompass.db`` doesn't need to delete it
to pick up new columns. Each entry is idempotent — running it twice is
safe.

SQLite has one quirk worth knowing about: ``ALTER TABLE ADD COLUMN``
cannot include ``UNIQUE``. So the DDL here is plain column definitions
only, and unique indexes are added in a second step after the column
exists.
"""

from __future__ import annotations

import logging

from sqlalchemy import inspect, text

log = logging.getLogger(__name__)


# Each entry is (table, column_type, unique?, index_name?).
#
# - ``column_type`` is the bare SQL type — e.g. ``"VARCHAR(128)"``.
# - ``unique=True`` creates a unique index after the column is added
#   (skipped automatically if the table already has duplicates).
# - ``index_name`` defaults to ``ix_<table>_<column>``.
_ADDITIVE_MIGRATIONS: list[tuple[str, str, bool, str | None]] = [
    ("users", "VARCHAR(128)", True, "ix_users_firebase_uid"),
]


def _sqlite_columns(db, table_name: str) -> set[str]:
    inspector = inspect(db.engine)
    try:
        return {c["name"] for c in inspector.get_columns(table_name)}
    except Exception:  # noqa: BLE001 — table may not exist yet
        return set()


def _index_exists(db, index_name: str) -> bool:
    inspector = inspect(db.engine)
    try:
        return index_name in {i["name"] for i in inspector.get_indexes("users")}
    except Exception:  # noqa: BLE001
        return False


def apply_lightweight_migrations(db) -> None:
    """Add any columns from ``_ADDITIVE_MIGRATIONS`` that are missing."""

    with db.engine.begin() as conn:
        for table, col_type, unique, index_name in _ADDITIVE_MIGRATIONS:
            existing = _sqlite_columns(db, table)
            col_name = col_type.split("(")[0].lower()
            # We hardcode the column names here because the SQLAlchemy
            # ``Column`` definitions don't survive in the migration list.
            if table == "users":
                col_name = "firebase_uid"

            if col_name in existing:
                log.debug("Migration: %s.%s already present", table, col_name)
            else:
                log.info("Migration: adding %s.%s %s", table, col_name, col_type)
                conn.execute(text(
                    f"ALTER TABLE {table} ADD COLUMN {col_name} {col_type}"
                ))

            if unique and not _index_exists(db, index_name or ""):
                # SQLite refuses to create a unique index when the
                # existing data violates uniqueness. That's fine — the
                # column itself stays nullable, and any future writes
                # that would duplicate the constraint will raise, which
                # is what we want.
                try:
                    conn.execute(text(
                        f"CREATE UNIQUE INDEX IF NOT EXISTS "
                        f"{index_name} ON {table}({col_name}) "
                        f"WHERE {col_name} IS NOT NULL"
                    ))
                    log.info("Migration: created unique index %s",
                             index_name)
                except Exception:  # noqa: BLE001
                    log.exception(
                        "Could not create unique index %s; "
                        "duplicate firebase_uids will fail at write time.",
                        index_name,
                    )

    # ``db.create_all`` usually creates this table, but on partially
    # upgraded deployments we defensively ensure it exists.
    inspector = inspect(db.engine)
    if not inspector.has_table("payments"):
        from .database_models import Payment

        log.info("Migration: creating payments table")
        Payment.__table__.create(bind=db.engine, checkfirst=True)


__all__ = ["apply_lightweight_migrations"]

