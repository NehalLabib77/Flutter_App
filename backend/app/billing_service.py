"""Billing provider abstraction (stub).

This module exists so that the import smoke-test in
``tests/test_imports.py`` continues to pass after the reorg. The real
billing integration is not in scope yet; until then
``get_billing_provider()`` returns a no-op provider that always reports
"free" so callers can stay wired up without paying anything.

Replace this file when the real provider (Stripe / Razorpay / etc.)
is added — the public surface (``get_billing_provider``) should stay
the same so callers don't need to change.
"""

from __future__ import annotations

from typing import Protocol


class BillingProvider(Protocol):
    """Minimal interface every concrete provider must implement."""

    name: str

    def charge(self, user_id: int, amount_cents: int, currency: str = "USD") -> dict:
        ...


class FreeBillingProvider:
    """No-op provider used in dev and tests."""

    name = "free"

    def charge(self, user_id: int, amount_cents: int, currency: str = "USD") -> dict:
        return {
            "status": "skipped",
            "provider": self.name,
            "user_id": user_id,
            "amount_cents": amount_cents,
            "currency": currency,
            "message": "No billing provider configured; charge was not attempted.",
        }


_PROVIDER: BillingProvider = FreeBillingProvider()


def get_billing_provider() -> BillingProvider:
    """Return the active billing provider.

    Today this is always the :class:`FreeBillingProvider`. When a real
    provider is wired in, swap the module-level ``_PROVIDER`` based on
    configuration (e.g. ``current_app.config["BILLING_PROVIDER"]``).
    """
    return _PROVIDER
