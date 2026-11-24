"""WSGI service for opt-in rider cards and optional Yandex route times."""
import base64
import hashlib
import json
import math
import os
import re
import sqlite3
import time
from uuid import UUID
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
CREATE TABLE IF NOT EXISTS handles(
    username TEXT PRIMARY KEY, owner TEXT UNIQUE NOT NULL REFERENCES profiles(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS posts(
    id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, caption TEXT NOT NULL, location TEXT, photo BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS posts_by_owner ON posts(owner, created_at DESC);
CREATE TABLE IF NOT EXISTS post_comments(
    id TEXT PRIMARY KEY, post TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    author TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, body TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS comments_by_post ON post_comments(post, created_at DESC);
CREATE TABLE IF NOT EXISTS records(
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL, spot_id TEXT, spot_name TEXT, started_at REAL NOT NULL,
    height REAL NOT NULL, airtime REAL, PRIMARY KEY(owner, session_id)
);
CREATE INDEX IF NOT EXISTS records_by_spot ON records(spot_id, started_at);
CREATE TABLE IF NOT EXISTS record_details(
    owner TEXT NOT NULL, session_id TEXT NOT NULL, distance REAL, kite TEXT, board TEXT,
    PRIMARY KEY(owner, session_id),
    FOREIGN KEY(owner, session_id) REFERENCES records(owner, session_id) ON DELETE CASCADE
);
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
    if raw.get("username") is not None:
        handle = raw["username"]
        if not isinstance(handle, str) or not re.fullmatch(r"[a-z0-9_]{3,24}", handle):
            raise ValueError("Invalid username")
        result["username"] = handle
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
        return dict(id=row[0], profile=json.loads(row[1]), followers=row[2],
                    following=bool(row[3]), followingCount=row[4])

    query = """SELECT p.id,p.document,
        (SELECT count(*) FROM follows f WHERE f.target=p.id),
        EXISTS(SELECT 1 FROM follows f WHERE f.owner=? AND f.target=p.id),
        (SELECT count(*) FROM follows f WHERE f.owner=p.id AND EXISTS (
            SELECT 1 FROM profiles following WHERE following.id=f.target))
        FROM profiles p """
    mine = db.execute(query + "WHERE p.id=?", (owner, owner)).fetchone()
    others = db.execute(query + "WHERE p.id<>? ORDER BY p.rowid DESC LIMIT 40", (owner, owner))
    return {"mine": entry(mine) if mine else None, "riders": [entry(row) for row in others]}


def read_json(env, limit):
    length = int(env.get("CONTENT_LENGTH") or 0)
    if not 0 < length <= limit:
        raise ValueError("invalid request size")
    return json.loads(env["wsgi.input"].read(length))


def identifier(value):
    if not isinstance(value, str):
        raise ValueError("invalid ID")
    return str(UUID(value))


def number(value, lower, upper):
    return type(value) in (int, float) and lower <= value <= upper


def score_rows(items):
    if not isinstance(items, list) or len(items) > 5000:
        raise ValueError("invalid records")
    normalized = {}
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("invalid record")
        key = identifier(item.get("id"))
        spot_id = identifier(item["spotID"]) if item.get("spotID") is not None else None
        spot = item.get("spot")
        if spot is not None and (not isinstance(spot, str) or len(spot) > 100):
            raise ValueError("invalid spot")
        started, height, airtime = item.get("startedAt"), item.get("height"), item.get("airtime")
        if not number(started, 0, 4e9) or not number(height, 0.01, 100):
            raise ValueError("invalid jump")
        if airtime is not None and not number(airtime, 0.01, 120):
            raise ValueError("invalid airtime")
        distance = item.get("distance")
        if distance is not None and not (number(distance, 0, 100000) and distance > 0):
            raise ValueError("invalid flight distance")
        kite, board = item.get("kite"), item.get("board")
        if any(label is not None and (not isinstance(label, str) or len(label) > 255) for label in (kite, board)):
            raise ValueError("invalid equipment")
        normalized[key] = (key, spot_id, spot.strip().casefold() if spot else None, started, height, airtime,
                           distance, kite.strip() if kite else None, board.strip() if board else None)
    return list(normalized.values())


def post_fields(raw, target):
    if not isinstance(raw, dict) or identifier(raw.get("id")) != target:
        raise ValueError("invalid post")
    caption, location, photo = raw.get("caption"), raw.get("location"), raw.get("photo")
    if not isinstance(caption, str) or len(caption) > 800 or not isinstance(photo, str):
        raise ValueError("invalid caption or photo")
    image = base64.b64decode(photo, validate=True)
    if not 3 < len(image) <= 390000 or not image.startswith(b"\xff\xd8\xff"):
        raise ValueError("invalid post photo")
    if location is not None:
        if not isinstance(location, dict) or not isinstance(location.get("name"), str):
            raise ValueError("invalid geotag")
        name = location["name"].strip()
        lat, lon = location.get("latitude"), location.get("longitude")
        if not 1 <= len(name) <= 100 or ((lat is not None or lon is not None)
                                       and not (number(lat, -90, 90) and number(lon, -180, 180))):
            raise ValueError("invalid geotag")
        location = json.dumps({"name": name, "latitude": lat, "longitude": lon}, ensure_ascii=False)
    return caption.strip(), location, image


def feed(db, owner, following):
    relation = "EXISTS" if following else "NOT EXISTS"
    query = f"""SELECT p.id,p.created_at,p.caption,p.location,r.document
        FROM posts p JOIN profiles r ON r.id=p.owner
        WHERE p.owner<>? AND {relation}(SELECT 1 FROM follows f WHERE f.owner=? AND f.target=p.owner)
        ORDER BY p.created_at DESC,p.id LIMIT 40"""
    entries = []
    for post_id, created_at, caption, location, document in db.execute(query, (owner, owner)):
        author = json.loads(document)
        entries.append({"post": {"id": post_id, "createdAt": created_at, "caption": caption, "published": True,
                                 "location": json.loads(location) if location else None},
                        "author": author["name"], "username": author.get("username"),
                        "avatar": author.get("avatar")})
    return entries


def comments(db, post_id, owner):
    query = """SELECT c.id,c.author,c.created_at,c.body,p.document
        FROM post_comments c JOIN profiles p ON p.id=c.author
        WHERE c.post=? ORDER BY c.created_at DESC,c.id LIMIT 100"""
    output = []
    for comment_id, author_id, created_at, body, document in db.execute(query, (post_id,)):
        profile = json.loads(document)
        output.append({"id": comment_id, "createdAt": created_at, "text": body,
                       "author": profile["name"], "username": profile.get("username"),
                       "mine": author_id == owner})
    return output


def top_rows(db, raw):
    columns = {"height": "r.height", "airtime": "r.airtime", "distance": "d.distance"}
    if not isinstance(raw, dict) or not isinstance(raw.get("metric"), str) or raw["metric"] not in columns:
        raise ValueError("invalid metric")
    metric = raw["metric"]
    selected = columns[metric]
    start_at, end_at = raw.get("startAt"), raw.get("endAt")
    days = raw.get("days")
    if start_at is not None or end_at is not None:
        if not (number(start_at, 0, 4e9) and number(end_at, 0, 4e9) and start_at < end_at):
            raise ValueError("invalid period")
    elif days is not None:
        if type(days) is not int or days not in (7, 30):
            raise ValueError("invalid period")
        start_at, end_at = time.time() - days * 86400, 4e9
    else:
        start_at, end_at = 0, 4e9

    spot_id = identifier(raw["spotID"]) if raw.get("spotID") is not None else None
    spot = raw.get("spot")
    if spot is not None and (not isinstance(spot, str) or len(spot) > 100):
        raise ValueError("invalid spot")
    name = spot.strip().casefold() if spot else None
    query = f"""WITH ranked AS (
        SELECT p.id,p.document,r.height,r.airtime,d.distance,d.kite,d.board,
               ROW_NUMBER() OVER (PARTITION BY r.owner ORDER BY {selected} DESC,r.started_at DESC,r.session_id) AS place
        FROM records r JOIN profiles p ON p.id=r.owner
        LEFT JOIN record_details d ON d.owner=r.owner AND d.session_id=r.session_id
        WHERE r.started_at>=? AND r.started_at<? AND {selected} IS NOT NULL
          AND ((? IS NULL AND ? IS NULL) OR r.spot_id=?
               OR ((r.spot_id IS NULL OR ? IS NULL) AND r.spot_name=?))
        )
        SELECT id,document,height,airtime,distance,kite,board FROM ranked
        WHERE place=1 ORDER BY {metric} DESC,id LIMIT 50"""
    rows = db.execute(query, (start_at, end_at, spot_id, name, spot_id, spot_id, name))
    output = []
    for index, (owner, doc, height, airtime, distance, kite, board) in enumerate(rows):
        profile = json.loads(doc)
        entry = {"id": owner, "name": profile["name"], "username": profile.get("username"),
                 "height": height, "airtime": airtime, "distance": distance}
        if index < 3:
            entry.update(avatar=profile.get("avatar"), kite=kite, board=board)
        output.append(entry)
    return output


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

    path, method = env.get("PATH_INFO", ""), env.get("REQUEST_METHOD", "")
    photo_path = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/photo", path)
    comment_path = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/comments(?:/([a-fA-F0-9-]{36}))?", path)
    if method == "GET" and photo_path:
        try:
            post_id = identifier(photo_path[1])
        except ValueError:
            return send("404 Not Found", {"error": "unknown photo"})
        with closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
            db.executescript(SCHEMA)
            row = db.execute("SELECT s.photo FROM posts s JOIN profiles p ON p.id=s.owner WHERE s.id=?", (post_id,)).fetchone()
        if row is None:
            return send("404 Not Found", {"error": "unknown photo"})
        photo, = row
        start_response("200 OK", [("Content-Type", "image/jpeg"), ("Content-Length", str(len(photo))),
                                  ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")])
        return [photo]

    auth = re.fullmatch(r"Bearer ([a-fA-F0-9-]{72})", env.get("HTTP_AUTHORIZATION", ""))
    if not auth:
        return send("401 Unauthorized", {"error": "authentication required"})
    owner = hashlib.sha256(auth[1].encode("ascii")).hexdigest()
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
                    raw = read_json(env, 1500000)
                    doc = publication(raw)
                    scores = score_rows(raw["records"]) if "records" in raw else None
                except (ValueError, TypeError, OverflowError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid profile"})
                db.execute("BEGIN IMMEDIATE")
                handle = doc.get("username")
                if handle and db.execute("SELECT 1 FROM handles WHERE username=? AND owner<>?", (handle, owner)).fetchone():
                    return send("409 Conflict", {"error": "username taken"})
                if scores is None and "username" not in raw:
                    saved_handle = db.execute("SELECT username FROM handles WHERE owner=?", (owner,)).fetchone()
                    if saved_handle:
                        handle = doc["username"] = saved_handle[0]
                db.execute("INSERT INTO profiles VALUES (?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document",
                           (owner, json.dumps(doc)))
                db.execute("DELETE FROM handles WHERE owner=?", (owner,))
                if handle:
                    db.execute("INSERT INTO handles VALUES (?,?)", (handle, owner))
                if scores is not None:
                    db.execute("DELETE FROM records WHERE owner=?", (owner,))
                    db.executemany("INSERT INTO records VALUES (?,?,?,?,?,?,?)",
                                   ((owner, *row[:6]) for row in scores))
                    db.executemany("INSERT INTO record_details VALUES (?,?,?,?,?)",
                                   ((owner, row[0], *row[6:]) for row in scores))
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
            elif method == "GET" and path in ("/feed/following", "/feed/recommended"):
                return send("200 OK", feed(db, owner, following=path.endswith("/following")))
            elif (path, method) == ("/tops", "POST"):
                try:
                    rows = top_rows(db, read_json(env, 4096))
                except (ValueError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid filters"})
                return send("200 OK", rows)
            elif comment_path:
                try:
                    post_id = identifier(comment_path[1])
                    comment_id = identifier(comment_path[2]) if comment_path[2] else None
                    if (method, comment_id is not None) not in (("GET", False), ("PUT", True), ("DELETE", True)):
                        return send("405 Method Not Allowed", {"error": "invalid comment method"})
                    if method == "PUT":
                        raw = read_json(env, 8192)
                        if not isinstance(raw, dict) or not isinstance(raw.get("text"), str):
                            raise ValueError("invalid comment")
                        body = raw["text"].strip()
                        if not 1 <= len(body) <= 2000:
                            raise ValueError("invalid comment length")
                except (ValueError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid comment"})
                if method != "GET":
                    db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM posts WHERE id=?", (post_id,)).fetchone():
                    return send("404 Not Found", {"error": "unknown post"})
                if method == "PUT":
                    if not db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "publish a profile first"})
                    changed = db.execute("""INSERT INTO post_comments VALUES (?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET body=excluded.body
                        WHERE post_comments.author=excluded.author AND post_comments.post=excluded.post""",
                        (comment_id, post_id, owner, time.time(), body))
                    if not changed.rowcount:
                        return send("409 Conflict", {"error": "comment ID is taken"})
                elif method == "DELETE":
                    db.execute("DELETE FROM post_comments WHERE id=? AND post=? AND author=?",
                               (comment_id, post_id, owner))
                return send("200 OK", comments(db, post_id, owner))
            elif path.startswith("/posts/") and method in ("PUT", "DELETE"):
                try:
                    post_id = identifier(path.removeprefix("/posts/"))
                    fields = post_fields(read_json(env, 560000), post_id) if method == "PUT" else None
                except (ValueError, TypeError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid post"})
                if fields is None:
                    db.execute("DELETE FROM posts WHERE id=? AND owner=?", (post_id, owner))
                    return send("200 OK", {"deleted": True})
                db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                    return send("403 Forbidden", {"error": "publish a profile first"})
                affected = db.execute("""INSERT INTO posts VALUES (?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET caption=excluded.caption,location=excluded.location,photo=excluded.photo
                    WHERE posts.owner=excluded.owner""", (post_id, owner, time.time(), *fields))
                if not affected.rowcount:
                    return send("409 Conflict", {"error": "post ID is taken"})
                return send("200 OK", {"published": True})
            elif (path, method) != ("/riders", "GET"):
                return send("404 Not Found", {"error": "unknown endpoint"})
        return send("200 OK", state(db, owner))
