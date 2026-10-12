"""
Terrastep server — Stage 2 reference implementation (Sections 14-19).

A runnable implementation of the blueprint's API contracts (Section 16) and
authoritative referee procedure (Section 17) using only the Python standard
library + SQLite for local/dev use. The production deployment target is the
Postgres schema in schema.sql (Supabase): table names and access boundaries
mirror it, and the referee logic is shared verbatim from referee/engine.py.

Auth: this dev build issues its own bearer tokens (salted PBKDF2 password
hashes). In production, Supabase Auth owns identity and this layer verifies
its JWTs instead — the boundary is the `current_user()` function only.

Run:  TERRASTEP_SECRET=dev .venv/bin/python server/app.py  (port 8791)
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from referee.engine import Contribution, Referee, Rules  # noqa: E402
from referee.fitness import Fix, filtered_distance_m, haversine_m  # noqa: E402
from referee.h3_adapter import cell_area_km2, cell_for  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = os.environ.get("TERRASTEP_DB", str(ROOT / "server" / "terrastep.db"))
SECRET = os.environ.get("TERRASTEP_SECRET", "dev-secret-change-me").encode()
PUBLIC_DELAY_MS = int(os.environ.get("TERRASTEP_PUBLIC_DELAY_MIN", "30")) * 60_000
RULES = Rules.from_json(ROOT / "referee" / "rules_v1.json")
SEASON_ID = "abbottabad-s01"
PILOT_CENTER = (34.1688, 73.2215)  # Abbottabad (Section 4 pilot)
EVIDENCE_RETENTION_MS = 72 * 3600 * 1000  # Section 19: 72 hours


def now_ms() -> int:
    return int(time.time() * 1000)


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


# --------------------------------------------------------------------- storage
class Store:
    def __init__(self, path: str):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self._init_schema()

    def _init_schema(self) -> None:
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS users(
                id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, pw TEXT NOT NULL,
                nickname TEXT UNIQUE NOT NULL, kingdom_name TEXT, kingdom_color TEXT,
                weight_kg REAL, units TEXT DEFAULT 'metric', weekly_goal_walks INT,
                hide_calories INT DEFAULT 0, competition_opt_in INT DEFAULT 0,
                created_ms INT NOT NULL);
            CREATE TABLE IF NOT EXISTS tokens(token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions(
                id TEXT PRIMARY KEY, user_id TEXT NOT NULL, installation_id TEXT,
                status TEXT NOT NULL, rules_version TEXT NOT NULL, ticket TEXT NOT NULL,
                started_ms INT NOT NULL, expires_ms INT NOT NULL, ended_ms INT,
                summary TEXT);
            CREATE TABLE IF NOT EXISTS batches(
                session_id TEXT NOT NULL, batch_id TEXT NOT NULL, digest TEXT NOT NULL,
                payload TEXT NOT NULL, receipt TEXT NOT NULL, expires_ms INT NOT NULL,
                PRIMARY KEY(session_id, batch_id));
            CREATE TABLE IF NOT EXISTS contributions(
                seq INTEGER PRIMARY KEY, user_id TEXT NOT NULL, cell_id TEXT NOT NULL,
                session_id TEXT NOT NULL, activity_start_ms INT NOT NULL,
                activity_end_ms INT NOT NULL, credited_micro INT NOT NULL, league_day TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS owners(
                cell_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, visible_after_ms INT NOT NULL,
                evaluated_ms INT NOT NULL);
            CREATE TABLE IF NOT EXISTS ownership_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, cell_id TEXT NOT NULL,
                prev_owner TEXT, new_owner TEXT, cause TEXT NOT NULL, at_ms INT NOT NULL);
            CREATE TABLE IF NOT EXISTS reports(
                id INTEGER PRIMARY KEY AUTOINCREMENT, reporter_id TEXT NOT NULL,
                subject_user_id TEXT, cell_id TEXT, category TEXT NOT NULL,
                detail TEXT, created_ms INT NOT NULL);
            CREATE TABLE IF NOT EXISTS exclusions(
                user_id TEXT NOT NULL, cell_id TEXT NOT NULL, PRIMARY KEY(user_id, cell_id));
            """
        )
        self.db.commit()

    def execute(self, sql: str, args: tuple = ()) -> sqlite3.Cursor:
        with self.lock:
            cur = self.db.execute(sql, args)
            self.db.commit()
            return cur

    def query(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self.lock:
            return self.db.execute(sql, args).fetchall()


STORE = Store(DB_PATH)
REFEREE = Referee(RULES)


def load_referee() -> None:
    rows = STORE.query("SELECT * FROM contributions ORDER BY seq")
    contribs = [
        Contribution(
            seq=r["seq"], user_id=r["user_id"], cell_id=r["cell_id"], session_id=r["session_id"],
            activity_start_ms=r["activity_start_ms"], activity_end_ms=r["activity_end_ms"],
            credited_micro=r["credited_micro"], league_day=r["league_day"],
        )
        for r in rows
    ]
    owners = {r["cell_id"]: r["user_id"] for r in STORE.query("SELECT * FROM owners")}
    REFEREE.restore(contribs, owners)


load_referee()


def make_ticket(session_id: str) -> str:
    return hmac.new(SECRET, session_id.encode(), hashlib.sha256).hexdigest()


# --------------------------------------------------------------------- verification (Sections 17-18)
def verify_batch(user_id: str, session: sqlite3.Row, samples: list[dict]) -> dict:
    """Turn raw fixes into per-(cell, day) eligible moving durations.

    Conservative attribution: a segment earns moving time only when its
    implied speed is walking-plausible (0.3-3.5 m/s). Faster segments are
    rejected evidence; slower is stationary; >60 s gaps are unknown.
    Excluded cells (Section 19) earn personal fitness but no competition time.
    """
    excluded = {r["cell_id"] for r in STORE.query("SELECT cell_id FROM exclusions WHERE user_id=?", (user_id,))}
    ordered = sorted(samples, key=lambda s: s["t"])
    buckets: dict[tuple[str, int], int] = {}  # (cell, first_start_ms) -> duration_ms
    stats = {"moving_ms": 0, "stationary_ms": 0, "rejected_ms": 0, "gap_segments": 0,
             "excluded_ms": 0, "segments": 0}
    for a, b in zip(ordered, ordered[1:]):
        dt = b["t"] - a["t"]
        if dt <= 0:
            continue
        stats["segments"] += 1
        if dt > 60_000:
            stats["gap_segments"] += 1
            continue
        d = haversine_m(Fix(a["t"], a["lat"], a["lng"], a.get("acc", 10)),
                        Fix(b["t"], b["lat"], b["lng"], b.get("acc", 10)))
        speed = d / (dt / 1000)
        if speed > 3.5:
            stats["rejected_ms"] += dt
            continue
        if speed < 0.3:
            stats["stationary_ms"] += dt
            continue
        cell = cell_for(a["lat"], a["lng"], RULES.h3_resolution)
        if cell in excluded:
            stats["excluded_ms"] += dt
            continue
        key = (cell, a["t"])
        buckets[key] = buckets.get(key, 0) + dt
        stats["moving_ms"] += dt
    return {"buckets": buckets, "stats": stats}


def apply_buckets(user_id: str, session_id: str, buckets: dict) -> dict:
    """Credit buckets through the referee (caps inside), persist, re-evaluate owners."""
    credited_total = 0
    cap_notes: set[str] = set()
    per_cell: dict[str, int] = {}
    affected: set[str] = set()
    at_ms = 0
    for (cell, start_ms), duration in sorted(buckets.items(), key=lambda kv: kv[0][1]):
        acc = REFEREE.accept(user_id=user_id, cell_id=cell, session_id=session_id,
                             activity_start_ms=start_ms, moving_duration_ms=duration)
        at_ms = max(at_ms, start_ms)
        if acc.contribution is not None:
            c = acc.contribution
            STORE.execute(
                "INSERT INTO contributions(seq,user_id,cell_id,session_id,activity_start_ms,activity_end_ms,credited_micro,league_day) VALUES(?,?,?,?,?,?,?,?)",
                (c.seq, c.user_id, c.cell_id, c.session_id, c.activity_start_ms, c.activity_end_ms, c.credited_micro, c.league_day))
            credited_total += acc.credited_micro
            per_cell[cell] = per_cell.get(cell, 0) + acc.credited_micro
            affected.add(cell)
        if acc.cap_reason:
            cap_notes.add(acc.cap_reason)
    changes = []
    for cell in affected:
        before = STORE.query("SELECT user_id FROM owners WHERE cell_id=?", (cell,))
        before_id = before[0]["user_id"] if before else None
        after_id = REFEREE.evaluate_ownership(cell, at_ms or now_ms())
        if after_id != before_id:
            cause = "capture" if before_id is None else "takeover"
            STORE.execute(
                "INSERT INTO ownership_events(cell_id,prev_owner,new_owner,cause,at_ms) VALUES(?,?,?,?,?)",
                (cell, before_id, after_id, cause, now_ms()))
            if after_id is None:
                STORE.execute("DELETE FROM owners WHERE cell_id=?", (cell,))
            else:
                STORE.execute(
                    "INSERT INTO owners(cell_id,user_id,visible_after_ms,evaluated_ms) VALUES(?,?,?,?) "
                    "ON CONFLICT(cell_id) DO UPDATE SET user_id=excluded.user_id, visible_after_ms=excluded.visible_after_ms, evaluated_ms=excluded.evaluated_ms",
                    (cell, after_id, now_ms() + PUBLIC_DELAY_MS, now_ms()))
            changes.append({"cell": cell, "from": before_id, "to": after_id, "cause": cause})
    return {"credited_micro": credited_total, "cap_notes": sorted(cap_notes),
            "per_cell_micro": per_cell, "ownership_changes": changes}


# --------------------------------------------------------------------- http layer
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep test output clean; no payloads logged (Section 19)
        pass

    # -- plumbing
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def current_user(self) -> sqlite3.Row | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        rows = STORE.query("SELECT user_id FROM tokens WHERE token_hash=?", (sha(auth[7:]),))
        if not rows:
            return None
        users = STORE.query("SELECT * FROM users WHERE id=?", (rows[0]["user_id"],))
        return users[0] if users else None

    def require_user(self) -> sqlite3.Row | None:
        user = self.current_user()
        if user is None:
            self._send(401, {"error": "unauthorized"})
        return user

    # -- routing
    def do_POST(self): self._route("POST")
    def do_GET(self): self._route("GET")
    def do_PATCH(self): self._route("PATCH")
    def do_DELETE(self): self._route("DELETE")

    def _route(self, method: str) -> None:
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        query = parse_qs(parsed.query)
        try:
            if parts == ["healthz"] and method == "GET":
                return self._send(200, {"ok": True, "service": "terrastep"})
            if parts[:2] == ["v1", "auth"] and method == "POST":
                return self._auth(parts[2])
            if parts == ["v1", "sessions"] and method == "POST":
                return self._start_session()
            if len(parts) == 4 and parts[:2] == ["v1", "sessions"] and parts[3] == "batches" and method == "POST":
                return self._upload_batch(parts[2])
            if len(parts) == 4 and parts[:2] == ["v1", "sessions"] and parts[3] == "finish" and method == "POST":
                return self._finish_session(parts[2])
            if len(parts) == 4 and parts[:2] == ["v1", "regions"] and parts[3] == "cells" and method == "GET":
                return self._region_cells(parts[2], query)
            if len(parts) == 4 and parts[:2] == ["v1", "leagues"] and parts[3] == "board" and method == "GET":
                return self._board(parts[2])
            if parts == ["v1", "me", "activities"] and method == "GET":
                return self._my_activities()
            if parts == ["v1", "me", "profile"] and method == "PATCH":
                return self._patch_profile()
            if parts == ["v1", "me", "exclusions"] and method == "POST":
                return self._add_exclusion()
            if parts == ["v1", "reports"] and method == "POST":
                return self._report()
            if parts == ["v1", "me", "export"] and method == "POST":
                return self._export()
            if parts == ["v1", "me"] and method == "DELETE":
                return self._delete_me()
            return self._send(404, {"error": "not_found", "path": parsed.path})
        except Exception as exc:  # never leak internals or payloads
            return self._send(500, {"error": "internal", "detail": type(exc).__name__})

    # -- endpoints
    def _auth(self, action: str) -> None:
        body = self._body()
        email = (body.get("email") or "").strip().lower()
        password = body.get("password") or ""
        if action == "signup":
            nickname = (body.get("nickname") or "").strip()
            if not email or len(password) < 8 or len(nickname) < 2:
                return self._send(422, {"error": "email, password (>=8) and nickname (>=2) required"})
            salt = secrets.token_hex(16)
            pw = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000).hex()
            uid = str(uuid.uuid4())
            try:
                STORE.execute(
                    "INSERT INTO users(id,email,pw,nickname,created_ms) VALUES(?,?,?,?,?)",
                    (uid, email, f"{salt}${pw}", nickname, now_ms()))
            except sqlite3.IntegrityError:
                return self._send(409, {"error": "email or nickname already registered"})
            return self._send(201, {"user_id": uid, "nickname": nickname})
        if action == "login":
            rows = STORE.query("SELECT * FROM users WHERE email=?", (email,))
            if not rows:
                return self._send(401, {"error": "invalid credentials"})
            user = rows[0]
            salt, expected = user["pw"].split("$")
            actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000).hex()
            if not hmac.compare_digest(actual, expected):
                return self._send(401, {"error": "invalid credentials"})
            token = secrets.token_urlsafe(32)
            STORE.execute("INSERT INTO tokens(token_hash,user_id) VALUES(?,?)", (sha(token), user["id"]))
            return self._send(200, {"token": token, "user_id": user["id"]})
        return self._send(404, {"error": "unknown auth action"})

    def _get_session(self, session_id: str) -> sqlite3.Row | None:
        rows = STORE.query("SELECT * FROM sessions WHERE id=?", (session_id,))
        return rows[0] if rows else None

    def _start_session(self) -> None:
        user = self.require_user()
        if user is None:
            return
        body = self._body()
        sid = str(uuid.uuid4())
        expires = now_ms() + 12 * 3600 * 1000
        STORE.execute(
            "INSERT INTO sessions(id,user_id,installation_id,status,rules_version,ticket,started_ms,expires_ms) VALUES(?,?,?,?,?,?,?,?)",
            (sid, user["id"], body.get("installation_id"), "recording", RULES.rules_version, make_ticket(sid), now_ms(), expires))
        return self._send(201, {"session_id": sid, "ticket": make_ticket(sid), "server_time_ms": now_ms(),
                                "rules_version": RULES.rules_version, "expires_ms": expires})

    def _upload_batch(self, session_id: str) -> None:
        user = self.require_user()
        if user is None:
            return
        session = self._get_session(session_id)
        if session is None or session["user_id"] != user["id"]:
            return self._send(404, {"error": "session not found"})
        body = self._body()
        ticket = self.headers.get("X-Session-Ticket") or body.get("ticket")
        if not ticket or not hmac.compare_digest(ticket, session["ticket"]):
            return self._send(403, {"error": "invalid session ticket"})
        batch_id = body.get("batch_id")
        samples = body.get("samples")
        if not batch_id or not isinstance(samples, list) or not samples:
            return self._send(422, {"error": "batch_id and non-empty samples required"})
        canonical = json.dumps({"batch_id": batch_id, "samples": samples}, sort_keys=True)
        digest = sha(canonical)
        existing = STORE.query("SELECT * FROM batches WHERE session_id=? AND batch_id=?", (session_id, batch_id))
        if existing:
            if existing[0]["digest"] == digest:
                receipt = json.loads(existing[0]["receipt"])
                receipt["duplicate"] = True
                return self._send(200, receipt)  # Section 17 step 2: same canonical receipt
            return self._send(409, {"error": "idempotency conflict: batch_id reused with different content"})
        result = verify_batch(user["id"], session, samples)
        applied = apply_buckets(user["id"], session_id, result["buckets"])
        stats = result["stats"]
        status = "accepted" if stats["rejected_ms"] == 0 else "partial"
        receipt = {
            "receipt_id": f"rcpt-{session_id[:8]}-{batch_id}",
            "batch_id": batch_id, "status": status,
            "credited_minutes": round(applied["credited_micro"] / 1_000_000, 3),
            "cap_notes": applied["cap_notes"],
            "moving_ms": stats["moving_ms"], "stationary_ms": stats["stationary_ms"],
            "rejected_ms": stats["rejected_ms"], "gap_segments": stats["gap_segments"],
            "excluded_ms": stats["excluded_ms"],
            "per_cell_minutes": {c: round(m / 1_000_000, 3) for c, m in applied["per_cell_micro"].items()},
            "ownership_changes": applied["ownership_changes"],
        }
        STORE.execute(
            "INSERT INTO batches(session_id,batch_id,digest,payload,receipt,expires_ms) VALUES(?,?,?,?,?,?)",
            (session_id, batch_id, digest, canonical, json.dumps(receipt), now_ms() + EVIDENCE_RETENTION_MS))
        return self._send(201, receipt)

    def _finish_session(self, session_id: str) -> None:
        user = self.require_user()
        if user is None:
            return
        session = self._get_session(session_id)
        if session is None or session["user_id"] != user["id"]:
            return self._send(404, {"error": "session not found"})
        if session["summary"]:
            summary = json.loads(session["summary"])
            summary["duplicate"] = True
            return self._send(200, summary)
        batches = STORE.query("SELECT payload, receipt FROM batches WHERE session_id=?", (session_id,))
        all_fixes: list[Fix] = []
        credited_micro = 0
        rejected_ms = 0
        cells: dict[str, float] = {}
        for b in batches:
            payload = json.loads(b["payload"])
            all_fixes += [Fix(s["t"], s["lat"], s["lng"], s.get("acc", 10)) for s in payload["samples"]]
            receipt = json.loads(b["receipt"])
            credited_micro += int(receipt["credited_minutes"] * 1_000_000)
            rejected_ms += receipt["rejected_ms"]
            for c, m in receipt["per_cell_minutes"].items():
                cells[c] = cells.get(c, 0.0) + m
        distance, _ = filtered_distance_m(all_fixes)
        moving_ms = int(credited_micro / 1_000_000 * 60_000)
        status = "verified" if rejected_ms == 0 else "partially_verified"
        summary = {
            "session_id": session_id, "status": status,
            "recorded_distance_m": round(distance, 1),
            "recorded_moving_minutes": round(sum(json.loads(b["receipt"])["moving_ms"] for b in batches) / 60_000, 2) if batches else 0,
            "verified_minutes": round(credited_micro / 1_000_000, 2),
            "contributions_by_cell": cells,
            "owned_cells_now": [c for c in cells if REFEREE.owner_of(c) == user["id"]],
            "explanation": "Verified minutes come only from walking-plausible GPS segments; "
                           "stationary, gap and implausible segments stay personal-fitness only.",
        }
        STORE.execute("UPDATE sessions SET status=?, ended_ms=?, summary=? WHERE id=?",
                      (status, now_ms(), json.dumps(summary), session_id))
        return self._send(200, summary)

    def _region_cells(self, region_id: str, query: dict) -> None:
        lat = float(query.get("lat", [PILOT_CENTER[0]])[0])
        lng = float(query.get("lng", [PILOT_CENTER[1]])[0])
        k = int(query.get("k", ["2"])[0])
        from referee.h3_adapter import neighbors
        center = cell_for(lat, lng, RULES.h3_resolution)
        import h3 as _h3
        cells = list(_h3.grid_disk(center, k))
        owners = {r["cell_id"]: r for r in STORE.query("SELECT * FROM owners")}
        profiles = {r["id"]: r for r in STORE.query("SELECT id,nickname,kingdom_name,kingdom_color,competition_opt_in FROM users")}
        out = []
        for cell in cells:
            entry = {"cell": cell, "area_km2": round(cell_area_km2(cell), 4), "owner": None}
            owner_row = owners.get(cell)
            if owner_row and owner_row["visible_after_ms"] <= now_ms():  # Section 19: 30-min delay
                profile = profiles.get(owner_row["user_id"])
                if profile and profile["competition_opt_in"]:
                    entry["owner"] = {"nickname": profile["nickname"], "kingdom": profile["kingdom_name"],
                                      "color": profile["kingdom_color"]}
                elif profile:
                    entry["owner"] = {"nickname": "Private player", "kingdom": None, "color": None}
            out.append(entry)
        return self._send(200, {"region": region_id, "season": SEASON_ID, "cells": out,
                                "freshness_ms": now_ms()})

    def _board(self, league_id: str) -> None:
        user = self.current_user()
        areas = {}
        owners = REFEREE.evaluate_all(now_ms())
        from referee.h3_adapter import cell_area_km2 as area_of
        cache: dict[str, float] = {}
        for cell in owners:
            try:
                cache[cell] = area_of(cell)
            except Exception:
                cache[cell] = 0.1053
        board = REFEREE.territory_board(now_ms(), cache)
        profiles = {r["id"]: r for r in STORE.query("SELECT id,nickname,competition_opt_in FROM users")}
        rows = []
        for i, r in enumerate(board, 1):
            profile = profiles.get(r["user_id"])
            if profile and not profile["competition_opt_in"] and (not user or user["id"] != r["user_id"]):
                name = "Private player"
            else:
                name = profile["nickname"] if profile else "player"
            rows.append({"rank": i, "nickname": name, "cells": r["cells"], "area_km2": round(r["area_km2"], 3),
                         "is_you": bool(user and user["id"] == r["user_id"])})
        return self._send(200, {"league": league_id, "season": SEASON_ID, "cutoff_ms": now_ms(), "board": rows})

    def _my_activities(self) -> None:
        user = self.require_user()
        if user is None:
            return
        rows = STORE.query("SELECT id,status,started_ms,ended_ms,summary FROM sessions WHERE user_id=? ORDER BY started_ms DESC", (user["id"],))
        activities = [
            {"session_id": r["id"], "status": r["status"], "started_ms": r["started_ms"],
             "summary": json.loads(r["summary"]) if r["summary"] else None}
            for r in rows
        ]
        return self._send(200, {"activities": activities})

    def _patch_profile(self) -> None:
        user = self.require_user()
        if user is None:
            return
        body = self._body()
        allowed = {"nickname": "nickname", "kingdom_name": "kingdom_name", "kingdom_color": "kingdom_color",
                   "weight_kg": "weight_kg", "units": "units", "weekly_goal_walks": "weekly_goal_walks",
                   "hide_calories": "hide_calories", "competition_opt_in": "competition_opt_in"}
        sets, vals = [], []
        for key, col in allowed.items():
            if key in body:
                sets.append(f"{col}=?")
                vals.append(body[key])
        if not sets:
            return self._send(422, {"error": "no permitted fields supplied"})
        vals.append(user["id"])
        try:
            STORE.execute(f"UPDATE users SET {', '.join(sets)} WHERE id=?", tuple(vals))
        except sqlite3.IntegrityError:
            return self._send(409, {"error": "nickname already taken"})
        return self._send(200, {"updated": sorted(k for k in allowed if k in body)})

    def _add_exclusion(self) -> None:
        user = self.require_user()
        if user is None:
            return
        body = self._body()
        lat, lng = body.get("lat"), body.get("lng")
        if lat is None or lng is None:
            return self._send(422, {"error": "lat and lng required"})
        import h3 as _h3
        center = cell_for(float(lat), float(lng), RULES.h3_resolution)
        # ~300 m buffer at res 9 (edge ~200 m): the cell plus its first ring
        # intersects the zone; the second ring is included conservatively.
        cells = list(_h3.grid_disk(center, 2))
        for cell in cells:
            STORE.execute("INSERT OR IGNORE INTO exclusions(user_id,cell_id) VALUES(?,?)", (user["id"], cell))
        return self._send(201, {"excluded_cells": len(cells)})

    def _report(self) -> None:
        user = self.require_user()
        if user is None:
            return
        body = self._body()
        category = body.get("category")
        if category not in ("content", "cheating", "unsafe_cell", "other"):
            return self._send(422, {"error": "valid category required"})
        cur = STORE.execute(
            "INSERT INTO reports(reporter_id,subject_user_id,cell_id,category,detail,created_ms) VALUES(?,?,?,?,?,?)",
            (user["id"], body.get("subject_user_id"), body.get("cell_id"), category, body.get("detail"), now_ms()))
        return self._send(201, {"case_id": cur.lastrowid})

    def _export(self) -> None:
        user = self.require_user()
        if user is None:
            return
        sessions = STORE.query("SELECT id,status,started_ms,summary FROM sessions WHERE user_id=?", (user["id"],))
        contribs = STORE.query("SELECT cell_id,credited_micro,league_day FROM contributions WHERE user_id=?", (user["id"],))
        return self._send(200, {
            "profile": {"nickname": user["nickname"], "email": user["email"]},
            "sessions": [dict(r) for r in sessions],
            "contributions": [dict(r) for r in contribs],
        })

    def _delete_me(self) -> None:
        user = self.require_user()
        if user is None:
            return
        uid = user["id"]
        for table, col in [("tokens", "user_id"), ("sessions", "user_id"), ("contributions", "user_id"),
                           ("owners", "user_id"), ("exclusions", "user_id"), ("reports", "reporter_id")]:
            STORE.execute(f"DELETE FROM {table} WHERE {col}=?", (uid,))
        STORE.execute("DELETE FROM users WHERE id=?", (uid,))
        REFEREE.restore(
            [Contribution(r["seq"], r["user_id"], r["cell_id"], r["session_id"], r["activity_start_ms"],
                          r["activity_end_ms"], r["credited_micro"], r["league_day"])
             for r in STORE.query("SELECT * FROM contributions ORDER BY seq")],
            {r["cell_id"]: r["user_id"] for r in STORE.query("SELECT * FROM owners")})
        return self._send(200, {"deleted": True, "receipt": f"del-{uid[:8]}"})


def main() -> None:
    # TERRASTEP_HOST defaults to loopback for local dev; PaaS hosts (Render,
    # Railway, ...) set it to 0.0.0.0 and inject their own PORT.
    host = os.environ.get("TERRASTEP_HOST", "127.0.0.1")
    port = int(os.environ.get("TERRASTEP_PORT") or os.environ.get("PORT", "8791"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Terrastep Stage 2 server on http://{host}:{port} (rules {RULES.rules_version}, season {SEASON_ID})")
    server.serve_forever()


if __name__ == "__main__":
    main()
