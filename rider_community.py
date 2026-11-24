"""WSGI service for opt-in rider cards. Set RIDER_DB to a persistent database."""
import base64
import hashlib
import json
import math
import os
import re
import sqlite3
from contextlib import closing

SCHEMA = """
CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, document TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS follows(
    owner TEXT NOT NULL, target TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    PRIMARY KEY(owner,target)
);
CREATE INDEX IF NOT EXISTS by_target ON follows(target);
"""


def publication(raw):
    if not isinstance(raw, dict) or not isinstance(raw.get("name"), str):
        raise ValueError("Invalid profile")
    name = raw["name"].strip()
    totals = raw.get("totals")
    if not 1 <= len(name) <= 50 or not isinstance(totals, dict):
        raise ValueError("Invalid name or totals")
    cleaned = {}
    for key in ("sessions", "jumps", "seconds", "height", "airtime"):
        value = totals.get(key)
        if value is None and key in ("height", "airtime"):
            continue
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1e10:
            raise ValueError("Invalid statistic")
        if key in ("sessions", "jumps") and type(value) is not int:
            raise ValueError("Invalid count")
        cleaned[key] = value
    result = {"name": name, "totals": cleaned}
    if raw.get("avatar") is not None:
        blob = base64.b64decode(raw["avatar"], validate=True)
        if len(blob) > 96000 or not blob.startswith(bytes.fromhex("ffd8ff")):
            raise ValueError("Invalid avatar")
        result["avatar"] = raw["avatar"]
    return result


def state(db, owner):
    def entry(row):
        return dict(id=row[0], profile=json.loads(row[1]), followers=row[2], following=bool(row[3]))

    query = """SELECT p.id,p.document,
        (SELECT count(*) FROM follows f WHERE f.target=p.id),
        EXISTS(SELECT 1 FROM follows f WHERE f.owner=? AND f.target=p.id)
        FROM profiles p """
    mine = db.execute(query + "WHERE p.id=?", (owner, owner)).fetchone()
    others = db.execute(query + "WHERE p.id<>? ORDER BY p.rowid DESC LIMIT 40", (owner, owner))
    return {"mine": entry(mine) if mine else None, "riders": [entry(row) for row in others]}


def application(env, start_response):
    def send(status, obj):
        data = json.dumps(obj, ensure_ascii=False, allow_nan=False).encode("utf-8")
        start_response(status, [("Content-Type", "application/json; charset=utf-8"),
                                ("Cache-Control", "no-store"), ("Content-Length", str(len(data)))])
        return [data]

    auth = re.fullmatch(r"Bearer ([a-fA-F0-9-]{72})", env.get("HTTP_AUTHORIZATION", ""))
    if not auth:
        return send("401 Unauthorized", {"error": "authentication required"})
    owner = hashlib.sha256(auth[1].encode("ascii")).hexdigest()
    path, method = env.get("PATH_INFO", ""), env.get("REQUEST_METHOD", "")
    with closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(SCHEMA)
        with db:
            if (path, method) == ("/me", "PUT"):
                try:
                    length = int(env.get("CONTENT_LENGTH") or 0)
                    if not 0 < length <= 150000:
                        return send("413 Payload Too Large", {"error": "profile size"})
                    doc = publication(json.loads(env["wsgi.input"].read(length)))
                except (ValueError, TypeError, OverflowError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid profile"})
                db.execute("INSERT INTO profiles VALUES (?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document",
                           (owner, json.dumps(doc)))
            elif (path, method) == ("/me", "DELETE"):
                db.execute("DELETE FROM profiles WHERE id=?", (owner,))
            elif path.startswith("/follow/") and method in ("PUT", "DELETE"):
                target = path.removeprefix("/follow/")
                if target == owner or not db.execute("SELECT 1 FROM profiles WHERE id=?", (target,)).fetchone():
                    return send("404 Not Found", {"error": "unknown rider"})
                if method == "PUT":
                    db.execute("INSERT OR IGNORE INTO follows VALUES (?,?)", (owner, target))
                else:
                    db.execute("DELETE FROM follows WHERE owner=? AND target=?", (owner, target))
            elif (path, method) != ("/riders", "GET"):
                return send("404 Not Found", {"error": "unknown endpoint"})
        return send("200 OK", state(db, owner))
