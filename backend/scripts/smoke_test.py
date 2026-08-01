"""In-process smoke test for the v3 model + Flask routes.

Uses Flask's test client — no network or detached process required.
"""
from __future__ import annotations

import json
import os
import sys
import time

os.environ.setdefault("MODEL_DIR",
                      r"E:\Flutter_app\ml\artifacts\models\v3")
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

t0 = time.perf_counter()
from app import create_app  # noqa: E402
app = create_app()
print(f"[smoke] create_app ok in {time.perf_counter()-t0:.1f}s",
      flush=True)

client = app.test_client()


def show(label, response, keys=None):
    body = response.get_json()
    snippet = json.dumps(body)
    if keys and isinstance(body, dict):
        data = body.get("data") or {}
        summary = {k: data.get(k) for k in keys if k in data}
        snippet += f"  (data: {summary})"
    print(f"[smoke] {label}: status={response.status_code}  {snippet}",
          flush=True)


print("--- /api/v1/health ---", flush=True)
show("health", client.get("/api/v1/health"))

print("--- /api/v1/recommendations/filters ---", flush=True)
r = client.get("/api/v1/recommendations/filters")
b = r.get_json()
flt = (b.get("data") or {}).get("filters") or {}
print(f"[smoke] filters status={r.status_code} keys={list(flt.keys())}",
      flush=True)
print(f"[smoke]   subjects[:3]={flt.get('subjects', [])[:3]}", flush=True)
print(f"[smoke]   levels[:3]={flt.get('levels', [])[:3]}", flush=True)
print(f"[smoke]   providers[:3]={flt.get('providers', [])[:3]}", flush=True)

print("--- /api/v1/recommendations/query ---", flush=True)
r = client.post("/api/v1/recommendations/query",
                json={"query": "python machine learning"})
b = r.get_json().get("data") or {}
recs = b.get("recommendations") or []
print(f"[smoke]   status={r.status_code} count={b.get('count')} "
      f"first={[r_.get('course_name') for r_ in recs[:2]]}",
      flush=True)

print("--- /api/v1/courses/search?q=python&page_size=3 ---", flush=True)
r = client.get("/api/v1/courses/search?q=python&page_size=3")
b = r.get_json().get("data") or {}
res = b.get("results") or []
print(f"[smoke]   status={r.status_code} total={b.get('total')} "
      f"returned={len(res)} first={res[0].get('course_name') if res else None}",
      flush=True)

print("--- /api/v1/courses/1 ---", flush=True)
r = client.get("/api/v1/courses/1")
b = (r.get_json().get("data") or {}).get("course") or {}
print(f"[smoke]   status={r.status_code} "
      f"course_id={b.get('course_id')} name={b.get('course_name')}",
      flush=True)

print("--- /api/v1/courses/1/similar ---", flush=True)
r = client.get("/api/v1/courses/1/similar?limit=3")
b = r.get_json().get("data") or {}
res = b.get("results") or []
print(f"[smoke]   status={r.status_code} returned={len(res)} "
      f"first={res[0].get('course_name') if res else None}",
      flush=True)

print("--- /api/v1/courses/popular ---", flush=True)
r = client.get("/api/v1/courses/popular?limit=3")
b = r.get_json().get("data") or {}
res = b.get("results") or []
print(f"[smoke]   status={r.status_code} returned={len(res)} "
      f"first={res[0].get('course_name') if res else None}",
      flush=True)

print("--- /api/v1/courses/top-rated ---", flush=True)
r = client.get("/api/v1/courses/top-rated?limit=3")
b = r.get_json().get("data") or {}
res = b.get("results") or []
print(f"[smoke]   status={r.status_code} returned={len(res)} "
      f"first={res[0].get('course_name') if res else None}",
      flush=True)

print("[smoke] OK", flush=True)
