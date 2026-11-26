"""Authenticated nearby SOS and the APNs outbox worker."""
import json
import math
import os
import re
import sqlite3
import ssl
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from uuid import UUID

RADIUS_METERS = 1500
FIX_MAX_AGE = 300
VISIBLE_SECONDS = 900
PUSH_SECONDS = 120

SCHEMA = """
CREATE TABLE IF NOT EXISTS sos_receivers (
    owner TEXT PRIMARY KEY, token TEXT UNIQUE NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, captured_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS sos_fresh_receivers ON sos_receivers(captured_at);
CREATE TABLE IF NOT EXISTS sos_incidents (
    id TEXT PRIMARY KEY, owner TEXT NOT NULL, created REAL NOT NULL,
    name TEXT NOT NULL, equipment TEXT, latitude REAL NOT NULL, longitude REAL NOT NULL, accuracy REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS sos_sender_time ON sos_incidents(owner, created);
CREATE TABLE IF NOT EXISTS sos_closed (
    incident TEXT PRIMARY KEY REFERENCES sos_incidents(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS sos_outbox (
    incident TEXT NOT NULL REFERENCES sos_incidents(id) ON DELETE CASCADE, receiver TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', attempt_at REAL NOT NULL DEFAULT 0,
    PRIMARY KEY(incident, receiver)
);
CREATE INDEX IF NOT EXISTS sos_outbox_receiver ON sos_outbox(receiver);
CREATE TABLE IF NOT EXISTS sos_devices (
    owner TEXT PRIMARY KEY, token TEXT UNIQUE NOT NULL, refreshed REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS sos_responses (
    incident TEXT NOT NULL REFERENCES sos_incidents(id) ON DELETE CASCADE,
    receiver TEXT NOT NULL, name TEXT NOT NULL, action TEXT NOT NULL, decided REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', attempt_at REAL NOT NULL DEFAULT 0,
    PRIMARY KEY(incident,receiver)
);
CREATE INDEX IF NOT EXISTS sos_responses_pending ON sos_responses(status, decided);
CREATE TABLE IF NOT EXISTS sos_worker (id INTEGER PRIMARY KEY CHECK(id=1), heartbeat REAL NOT NULL);
"""


def number(value, low, high):
    return type(value) in (float, int) and low <= value <= high


def fix(raw, now):
    if not isinstance(raw, dict):
        raise ValueError("invalid coordinates")
    latitude, longitude, accuracy, captured = (raw.get(k) for k in ("latitude", "longitude", "accuracy", "capturedAt"))
    if not (number(latitude, -90, 90) and number(longitude, -180, 180)
            and number(accuracy, 0, 65) and number(captured, now - 45, now + 5)):
        raise ValueError("stale or inaccurate coordinates")
    return latitude, longitude, accuracy, captured


def distance(a, b):
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    haversine = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 12742000 * math.asin(math.sqrt(min(1, haversine)))


def recent_heartbeat(db, now):
    row = db.execute("SELECT heartbeat FROM sos_worker WHERE id=1").fetchone()
    return bool(row and row[0] >= now - 35)


def incident(row):
    identifier, created, name, equipment, latitude, longitude, accuracy, action = row
    return dict(id=identifier, createdAt=created, name=name, equipment=equipment,
                latitude=latitude, longitude=longitude, accuracy=accuracy, decision=action)


def push_token(raw):
    if not isinstance(raw, str) or not re.fullmatch(r"[a-f0-9]{32,512}", raw) or len(raw) % 2:
        raise ValueError("invalid push token")
    return raw


def rider_name(db, owner, raw):
    if not isinstance(raw, str) or len(raw) > 50:
        raise ValueError("invalid rider name")
    profile = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
    return json.loads(profile[0])["name"] if profile else raw.strip() or "Райдер"


def receipt(db, identifier):
    states = dict(db.execute("SELECT status,count(*) FROM sos_outbox WHERE incident=? GROUP BY status", (identifier,)))
    latitude, longitude, accuracy, created = db.execute(
        "SELECT latitude,longitude,accuracy,created FROM sos_incidents WHERE id=?", (identifier,)).fetchone()
    responses = db.execute("""SELECT receiver,name,decided FROM sos_responses
                              WHERE incident=? AND action='accept' ORDER BY decided,receiver""", (identifier,))
    return dict(id=identifier, recipients=sum(states.values()), acceptedByAPNs=states.get("accepted", 0),
                pending=states.get("pending", 0) + states.get("sending", 0),
                location=dict(latitude=latitude, longitude=longitude, accuracy=accuracy, capturedAt=created),
                createdAt=created, closed=bool(db.execute("SELECT 1 FROM sos_closed WHERE incident=?", (identifier,)).fetchone()),
                responders=[dict(id=owner, name=name, decidedAt=decided) for owner, name, decided in responses])


def handle(db, owner, path, method, body):
    now = time.time()
    if (path, method) == ("/sos/status", "GET"):
        return "200 OK", {"ready": recent_heartbeat(db, now)}
    if (path, method) == ("/sos/device", "PUT"):
        token = push_token(body().get("token"))
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM sos_devices WHERE token=? AND owner<>?", (token, owner))
        db.execute("""INSERT INTO sos_devices VALUES (?,?,?) ON CONFLICT(owner) DO UPDATE SET
                      token=excluded.token,refreshed=excluded.refreshed""", (owner, token, now))
        return "200 OK", {"enabled": True}
    if method == "DELETE" and path in ("/sos/device", "/sos/receiver"):
        if path == "/sos/device":
            db.execute("DELETE FROM sos_devices WHERE owner=?", (owner,))
        db.execute("DELETE FROM sos_receivers WHERE owner=?", (owner,))
        db.execute("UPDATE sos_outbox SET status='failed' WHERE receiver=? AND status='pending'", (owner,))
        return "200 OK", {"enabled": False}
    if (path, method) == ("/sos/receiver", "PUT"):
        raw = body()
        token = push_token(raw.get("token"))
        latitude, longitude, _, captured = fix(raw.get("location"), now)
        db.execute("BEGIN IMMEDIATE")
        prefs = db.execute("SELECT prefs FROM rider_alert_settings WHERE owner=?", (owner,)).fetchone()
        if prefs and not json.loads(prefs[0]).get("sos", True):
            return "200 OK", {"enabled": False}
        db.execute("DELETE FROM sos_receivers WHERE token=? AND owner<>?", (token, owner))
        db.execute("""INSERT INTO sos_receivers VALUES (?,?,?,?,?)
                      ON CONFLICT(owner) DO UPDATE SET token=excluded.token,latitude=excluded.latitude,
                        longitude=excluded.longitude,captured_at=excluded.captured_at
                      WHERE excluded.captured_at>=sos_receivers.captured_at""",
                   (owner, token, latitude, longitude, captured))
        return "200 OK", {"enabled": True}
    if (path, method) == ("/sos/inbox", "GET"):
        rows = db.execute("""SELECT i.id,i.created,i.name,i.equipment,i.latitude,i.longitude,i.accuracy,s.action
            FROM sos_incidents i JOIN sos_outbox o ON o.incident=i.id
            LEFT JOIN sos_responses s ON s.incident=o.incident AND s.receiver=o.receiver
            WHERE o.receiver=? AND i.created>=? AND NOT EXISTS(SELECT 1 FROM sos_closed WHERE incident=i.id)
                AND (s.action IS NULL OR s.action='accept')
            ORDER BY i.created DESC""", (owner, now - VISIBLE_SECONDS))
        return "200 OK", [incident(row) for row in rows]
    if method == "GET" and re.fullmatch(r"/sos/[0-9a-f-]{36}/receipt", path):
        identifier = str(UUID(path.split("/")[2]))
        found = db.execute("SELECT 1 FROM sos_incidents WHERE id=? AND owner=? AND created>=?",
                           (identifier, owner, now - VISIBLE_SECONDS)).fetchone()
        return ("200 OK", receipt(db, identifier)) if found else ("404 Not Found", {"error": "unknown SOS"})
    if method == "PUT" and re.fullmatch(r"/sos/[0-9a-f-]{36}/close", path):
        identifier = str(UUID(path.split("/")[2]))
        db.execute("BEGIN IMMEDIATE")
        if not db.execute("SELECT 1 FROM sos_incidents WHERE id=? AND owner=?", (identifier,owner)).fetchone():
            return "404 Not Found", {"error":"unknown SOS"}
        db.execute("INSERT OR IGNORE INTO sos_closed VALUES (?)", (identifier,))
        db.execute("UPDATE sos_outbox SET status='failed' WHERE incident=? AND status IN ('pending','sending')", (identifier,))
        db.execute("UPDATE sos_responses SET status='failed' WHERE incident=? AND status IN ('pending','sending')", (identifier,))
        return "200 OK", receipt(db,identifier)
    if method == "PUT" and re.fullmatch(r"/sos/[0-9a-f-]{36}/decision", path):
        identifier = str(UUID(path.split("/")[2]))
        raw = body()
        action = raw.get("action")
        if action not in ("accept", "skip"):
            raise ValueError("invalid decision")
        db.execute("BEGIN IMMEDIATE")
        assigned = db.execute("""SELECT 1 FROM sos_outbox o JOIN sos_incidents i ON i.id=o.incident
            WHERE o.incident=? AND o.receiver=? AND i.created>=?
                AND NOT EXISTS(SELECT 1 FROM sos_closed WHERE incident=i.id)""", (identifier, owner, now - VISIBLE_SECONDS)).fetchone()
        if not assigned:
            return "404 Not Found", {"error": "unknown SOS"}
        name = rider_name(db, owner, raw.get("name", ""))
        db.execute("""INSERT INTO sos_responses(incident,receiver,name,action,decided,status) VALUES (?,?,?,?,?,?)
                      ON CONFLICT(incident,receiver) DO NOTHING""",
                   (identifier, owner, name, action, now, "pending" if action == "accept" else "skipped"))
        saved = db.execute("SELECT action FROM sos_responses WHERE incident=? AND receiver=?", (identifier, owner)).fetchone()
        status = "responded" if saved[0] == "accept" else "skipped"
        db.execute("""UPDATE sos_outbox SET status=?
                      WHERE incident=? AND receiver=? AND status IN ('pending','sending')""", (status, identifier, owner))
        return "200 OK", {"action": saved[0]}
    if (path, method) != ("/sos", "POST"):
        return "404 Not Found", {"error": "unknown SOS endpoint"}

    raw = body()
    identifier = str(UUID(raw["id"]))
    db.execute("BEGIN IMMEDIATE")
    exists = db.execute("SELECT owner FROM sos_incidents WHERE id=?", (identifier,)).fetchone()
    if exists:
        return ("200 OK", receipt(db, identifier)) if exists[0] == owner else ("409 Conflict", {"error": "ID taken"})
    if not recent_heartbeat(db, now):
        return "503 Service Unavailable", {"error": "SOS dispatcher unavailable"}
    if db.execute("SELECT 1 FROM sos_incidents WHERE owner=? AND created>=? AND id NOT IN (SELECT incident FROM sos_closed)", (owner, now - 60)).fetchone():
        return "429 Too Many Requests", {"error": "recent SOS"}
    latitude, longitude, accuracy, _ = fix(raw.get("location"), now)
    name = rider_name(db, owner, raw.get("name", ""))
    equipment = raw.get("equipment")
    if equipment is not None and (not isinstance(equipment, str) or len(equipment) > 320):
        raise ValueError("invalid rider details")
    db.execute("INSERT INTO sos_incidents VALUES (?,?,?,?,?,?,?,?)",
               (identifier, owner, now, name or "Райдер", equipment, latitude, longitude, accuracy))
    nearby = db.execute("""SELECT owner,latitude,longitude FROM sos_receivers
                           WHERE owner<>? AND captured_at>=?""", (owner, now - FIX_MAX_AGE))
    db.executemany("INSERT INTO sos_outbox(incident,receiver) VALUES (?,?)",
                   [(identifier, target) for target, lat, lon in nearby
                    if distance((latitude, longitude), (lat, lon)) <= RADIUS_METERS])
    return "200 OK", receipt(db, identifier)


def worker_batch(db, push):
    now = time.time()
    with db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("INSERT OR REPLACE INTO sos_worker VALUES (1,?)", (now,))
        db.execute("DELETE FROM sos_incidents WHERE created<?", (now - VISIBLE_SECONDS,))
        db.execute("DELETE FROM sos_receivers WHERE captured_at<?", (now - FIX_MAX_AGE,))
        db.execute("DELETE FROM sos_devices WHERE refreshed<?", (now - 90 * 86400,))
        db.execute("""UPDATE sos_responses SET status='failed'
                      WHERE status IN ('pending','sending') AND decided<?""", (now - PUSH_SECONDS,))
        db.execute("""UPDATE sos_outbox SET status='failed'
                      WHERE status IN ('pending','sending') AND (
                      incident IN (SELECT id FROM sos_incidents WHERE created<?)
                      OR NOT EXISTS (SELECT 1 FROM sos_receivers r WHERE r.owner=sos_outbox.receiver))""",
                   (now - PUSH_SECONDS,))
        jobs = db.execute("""SELECT o.incident,o.receiver,r.token,i.created,i.name,i.equipment
            FROM sos_outbox o JOIN sos_incidents i ON i.id=o.incident JOIN sos_receivers r ON r.owner=o.receiver
            WHERE ((o.status='pending' AND o.attempt_at<=?) OR (o.status='sending' AND o.attempt_at<=?))
              AND NOT EXISTS (SELECT 1 FROM sos_responses s WHERE s.incident=o.incident AND s.receiver=o.receiver)
            ORDER BY i.created,o.receiver LIMIT 16""", (now - 5, now - 25)).fetchall()
        db.executemany("UPDATE sos_outbox SET status='sending',attempt_at=? WHERE incident=? AND receiver=?",
                       [(now, identifier, receiver) for identifier, receiver, _, _, _, _ in jobs])

        replies = db.execute("""SELECT s.incident,s.receiver,coalesce(d.token,r.token),s.decided,s.name,NULL
            FROM sos_responses s JOIN sos_incidents i ON i.id=s.incident
            LEFT JOIN sos_devices d ON d.owner=i.owner LEFT JOIN sos_receivers r ON r.owner=i.owner
            WHERE ((s.status='pending' AND s.attempt_at<=?) OR (s.status='sending' AND s.attempt_at<=?))
                AND coalesce(d.token,r.token) IS NOT NULL
            ORDER BY s.decided,s.receiver LIMIT 16""", (now - 5, now - 25)).fetchall()
        db.executemany("UPDATE sos_responses SET status='sending',attempt_at=? WHERE incident=? AND receiver=?",
                       [(now, identifier, receiver) for identifier, receiver, _, _, _, _ in replies])

    for table, batch in (("sos_responses", replies), ("sos_outbox", jobs)):
        if not batch:
            continue

        def deliver(job):
            identifier, _, token, created, name, equipment = job
            return push(token, identifier, int(created + PUSH_SECONDS), name, equipment, table == "sos_responses")

        with ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(deliver, batch))
        with db:
            db.executemany(f"""UPDATE {table} SET status=? WHERE incident=? AND receiver=?
                              AND status='sending' AND attempt_at=?""",
                           [(status, job[0], job[1], now) for job, status in zip(batch, statuses)])


def worker():
    # Imported only by the outbox process, so the main WSGI API can run without APNs extras.
    import httpx
    import rider_community
    import rider_discovery

    context = ssl.create_default_context()
    context.load_cert_chain(os.environ["RIDER_APNS_CERT"], os.environ.get("RIDER_APNS_KEY"))
    topic = os.environ["RIDER_APNS_TOPIC"]
    host = "api.sandbox.push.apple.com" if os.environ.get("RIDER_APNS_SANDBOX") == "1" else "api.push.apple.com"
    with httpx.Client(base_url="https://" + host, http2=True, verify=context, timeout=4) as client, \
            closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(rider_community.SCHEMA + SCHEMA + rider_discovery.SCHEMA)

        def push(token, identifier, expiration, name, equipment, reply):
            headers = {"apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10",
                       "apns-expiration": str(expiration),
                       "apns-collapse-id": identifier + "-reply" if reply else identifier}
            if reply:
                title = "На SOS откликнулись"
                message = f"{name} сообщил, что идёт на помощь."
            else:
                title = "SOS Rider"
                message = f"{name} подал сигнал SOS поблизости."
                if equipment:
                    message += " Комплект: " + equipment[:100]
            aps = {"alert": {"title": title, "body": message}, "sound": "default"}
            if not reply:
                aps["category"] = "RIDER_SOS"
            payload = {"aps": aps, ("riderSOSReply" if reply else "riderSOS"): identifier}
            return deliver(token, headers, payload)

        def deliver(token, headers, payload):
            try:
                response = client.post("/3/device/" + token, headers=headers, json=payload)
            except httpx.HTTPError:
                return "pending"
            if response.status_code == 200:
                return "accepted"
            return "pending" if response.status_code == 429 or response.status_code >= 500 else "failed"

        labels = {"message": "Новое сообщение", "follow": "Новый подписчик",
                  "reaction": "Шака", "comment": "Комментарий под постом",
                  "reply": "Ответ на комментарий", "repost": "Репост"}
        def social_push(token, sequence, kind, name, prefs):
            alert = {"title": labels[kind]}
            if prefs.get("preview", True):
                alert["body"] = name
            aps = {"alert": alert}
            if prefs.get("sound", True):
                aps["sound"] = "default"
            headers = {"apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10",
                       "apns-expiration": str(int(time.time()) + 3600),
                       "apns-collapse-id": f"social-{sequence}"}
            return deliver(token, headers, {"aps": aps, "riderSocial": kind})

        while True:
            worker_batch(db, push)
            rider_discovery.push_batch(db, social_push)
            time.sleep(2)


if __name__ == "__main__":
    worker()
