"""Smoke tests for the API."""

from app1 import create_app


def _client():
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


def test_health():
    c = _client()
    body = c.get("/api/v1/health").get_json()
    assert body["success"] is True
    assert body["data"]["courses_loaded"] > 0


def test_recommend():
    c = _client()
    body = c.get("/api/v1/courses/search?q=python&limit=3").get_json()
    assert body["success"] is True
    assert len(body["data"]["results"]) > 0


def test_empty_query():
    c = _client()
    body = c.get("/api/v1/courses/search?q=&limit=3").get_json()
    assert body["success"] is False
    assert body["error_code"] == "MISSING_QUERY"
