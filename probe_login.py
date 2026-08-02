import json
import urllib.error
import urllib.request

url = "https://educompass-api.onrender.com/api/v1/auth/login"
with open(r"e:\Flutter_app\probe_body.json", "rb") as fh:
    body = fh.read()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
try:
    print(urllib.request.urlopen(req, timeout=120).read().decode())
except urllib.error.HTTPError as exc:
    print("status", exc.code)
    print(exc.read().decode())
