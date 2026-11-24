"""WSGI service for opt-in rider cards and optional Yandex route times."""
import base64
import hashlib
import json
import math
import os
import re
import sqlite3
from contextlib import closing
from urllib.parse import urlencode
from urllib.request import urlopen

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
    if raw.get("bio") is not None:
        bio = raw["bio"]
        if not isinstance(bio, str) or len(bio) > 160:
            raise ValueError("Invalid bio")
        if bio.strip():
            result["bio"] = bio.strip()
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


def route_query(raw, api_key):
    def coordinate(point):
        if not isinstance(point, dict):
            raise ValueError("invalid point")
        latitude, longitude = point.get("latitude"), point.get("longitude")
        if (type(latitude) not in (int, float) or not -90 <= latitude <= 90
                or type(longitude) not in (int, float) or not -180 <= longitude <= 180):
            raise ValueError("invalid coordinates")
        return f"{latitude},{longitude}"

    if not isinstance(raw, dict) or not isinstance(raw.get("destinations"), list):
        raise ValueError("invalid route matrix")
    destinations = raw["destinations"]
    if not 1 <= len(destinations) <= 20:
        raise ValueError("invalid destination count")
    params = {
        "apikey": api_key,
        "origins": coordinate(raw.get("origin")),
        "destinations": "|".join(coordinate(point) for point in destinations),
        "mode": "driving",
    }
    return "https://api.routing.yandex.net/v2/distancematrix?" + urlencode(params), len(destinations)


def route_seconds(url, count):
    with urlopen(url, timeout=6) as response:
        payload = json.loads(response.read(65536))
    rows = payload["rows"]
    if not isinstance(rows, list) or len(rows) != 1:
        raise ValueError("invalid route response")
    elements = rows[0]["elements"]
    if not isinstance(elements, list) or len(elements) != count:
        raise ValueError("invalid route response")

    seconds = []
    for element in elements:
        duration = element["duration"]["value"] if element["status"] == "OK" else None
        if type(duration) in (int, float) and 0 <= duration <= 604800:
            seconds.append(duration)
        else:
            seconds.append(None)
    return seconds


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
    if (path, method) == ("/route-eta", "POST"):
        api_key = os.environ.get("RIDER_YANDEX_ROUTING_KEY")
        if not api_key:
            return send("503 Service Unavailable", {"error": "yandex routing disabled"})
        try:
            length = int(env.get("CONTENT_LENGTH") or 0)
            if not 0 < length <= 4096:
                return send("413 Payload Too Large", {"error": "route request size"})
            matrix = json.loads(env["wsgi.input"].read(length))
            url, count = route_query(matrix, api_key)
        except (ValueError, RecursionError):
            return send("400 Bad Request", {"error": "invalid route request"})
        try:
            return send("200 OK", {"seconds": route_seconds(url, count)})
        except (OSError, ValueError, TypeError, KeyError, RecursionError):
            return send("502 Bad Gateway", {"error": "yandex routing unavailable"})

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
