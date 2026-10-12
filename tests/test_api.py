"""End-to-end API tests for the Stage 2 server (Sections 16-17 contracts)."""

import importlib.util
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ["TERRASTEP_DB"] = str(Path(tempfile.mkdtemp()) / "test.db")
os.environ["TERRASTEP_PUBLIC_DELAY_MIN"] = "0"
os.environ["TERRASTEP_SECRET"] = "test-secret"

spec = importlib.util.spec_from_file_location("terrastep_server", ROOT / "server" / "app.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

from http.server import ThreadingHTTPServer  # noqa: E402

HTTP = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
PORT = HTTP.server_address[1]
threading.Thread(target=HTTP.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{PORT}"


def call(method, path, token=None, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def signup_and_login(email, nickname):
    s, _ = call("POST", "/v1/auth/signup", body={"email": email, "password": "password123", "nickname": nickname})
    assert s == 201
    s, out = call("POST", "/v1/auth/login", body={"email": email, "password": "password123"})
    assert s == 200
    return out["token"], out["user_id"]


def walk_samples(start_lat, start_lng, steps=10, dt_ms=10_000, dlat=0.00013):
    import time

    base = int(time.time() * 1000) - (steps + 1) * dt_ms  # walks happen "now"
    return [
        {"t": base + i * dt_ms, "lat": start_lat + i * dlat, "lng": start_lng, "acc": 5}
        for i in range(steps + 1)
    ]


def test_full_walk_loop_two_users():
    import h3

    amina_token, _ = signup_and_login("amina@example.com", "amina")
    bilal_token, _ = signup_and_login("bilal@example.com", "bilal")

    # Amina opts into public competition (Section 19 separate opt-in).
    s, _ = call("PATCH", "/v1/me/profile", token=amina_token, body={"competition_opt_in": 1, "weight_kg": 62})
    assert s == 200

    # Start at a cell centroid so the short walk stays in one cell.
    center = h3.cell_to_latlng(h3.latlng_to_cell(34.1688, 73.2215, 9))
    s, sess = call("POST", "/v1/sessions", token=amina_token, body={"installation_id": "dev-1"})
    assert s == 201
    sid, ticket = sess["session_id"], sess["ticket"]

    # Out-and-back walk: 90 s north then 90 s back south = 3 credited minutes
    # inside one cell — enough to pass the 2-point neutral capture threshold.
    samples = walk_samples(center[0], center[1], steps=9)
    back_at = samples[-1]["t"]
    for i in range(1, 10):
        samples.append({"t": back_at + i * 10_000, "lat": center[0] + (9 - i) * 0.00013,
                        "lng": center[1], "acc": 5})
    batch = {"batch_id": "b1", "seq_from": 0, "seq_to": len(samples) - 1, "samples": samples}
    s, receipt = call("POST", f"/v1/sessions/{sid}/batches", token=amina_token, body=batch,
                      headers={"X-Session-Ticket": ticket})
    assert s == 201, receipt
    assert receipt["status"] == "accepted"
    assert receipt["credited_minutes"] >= 1.5  # 100 s of walking, minus nothing

    # Idempotent retry: same content -> same receipt, flagged duplicate (Section 17).
    s, again = call("POST", f"/v1/sessions/{sid}/batches", token=amina_token, body=batch,
                    headers={"X-Session-Ticket": ticket})
    assert s == 200 and again["duplicate"] is True
    assert again["receipt_id"] == receipt["receipt_id"]

    # Same batch id, different content -> 409 conflict.
    tampered = dict(batch)
    tampered["samples"] = walk_samples(center[0], center[1], steps=3)
    s, _ = call("POST", f"/v1/sessions/{sid}/batches", token=amina_token, body=tampered,
                headers={"X-Session-Ticket": ticket})
    assert s == 409

    # Another user cannot touch Amina's session (Section 15 access boundaries).
    s, _ = call("POST", f"/v1/sessions/{sid}/batches", token=bilal_token, body=batch,
                headers={"X-Session-Ticket": ticket})
    assert s == 404

    # Finish: personal summary + verified decision, idempotent.
    s, summary = call("POST", f"/v1/sessions/{sid}/finish", token=amina_token, body={})
    assert s == 200, summary
    assert summary["status"] == "verified"
    assert summary["recorded_distance_m"] > 100
    assert len(summary["owned_cells_now"]) >= 1
    s, summary2 = call("POST", f"/v1/sessions/{sid}/finish", token=amina_token, body={})
    assert s == 200 and summary2["duplicate"] is True

    # Board shows Amina; private history is per-user.
    s, board = call("GET", "/v1/leagues/abbottabad-pilot/board", token=bilal_token)
    assert s == 200
    assert board["board"][0]["nickname"] == "amina"
    s, mine = call("GET", "/v1/me/activities", token=amina_token)
    assert len(mine["activities"]) == 1
    s, his = call("GET", "/v1/me/activities", token=bilal_token)
    assert his["activities"] == []

    # Region snapshot exposes only the sanitized public projection.
    s, region = call("GET", f"/v1/regions/abbottabad-pilot/cells?lat={center[0]}&lng={center[1]}&k=1")
    owners = [c["owner"] for c in region["cells"] if c["owner"]]
    assert owners and owners[0]["nickname"] == "amina"


def test_auth_and_validation():
    s, _ = call("POST", "/v1/auth/signup", body={"email": "x@example.com", "password": "short", "nickname": "xy"})
    assert s == 422
    s, _ = call("GET", "/v1/me/activities")
    assert s == 401
    token, _ = signup_and_login("carol@example.com", "carol")
    s, out = call("POST", "/v1/reports", token=token, body={"category": "unsafe_cell", "cell_id": "abc"})
    assert s == 201 and out["case_id"] >= 1
    s, out = call("POST", "/v1/me/export", token=token, body={})
    assert s == 200 and out["profile"]["nickname"] == "carol"
