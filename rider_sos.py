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
CREATE TABLE IF NOT EXISTS sos_outbox (
    incident TEXT NOT NULL REFERENCES sos_incidents(id) ON DELETE CASCADE, receiver TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', attempt_at REAL NOT NULL DEFAULT 0,
    PRIMARY KEY(incident, receiver)
);
CREATE INDEX IF NOT EXISTS sos_outbox_receiver ON sos_outbox(receiver);
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
    identifier, created, name, equipment, latitude, longitude, accuracy = row
    return dict(id=identifier, createdAt=created, name=name, equipment=equipment,
                latitude=latitude, longitude=longitude, accuracy=accuracy)


def receipt(db, identifier):
    states = dict(db.execute("SELECT status,count(*) FROM sos_outbox WHERE incident=? GROUP BY status", (identifier,)))
    return dict(id=identifier, recipients=sum(states.values()), acceptedByAPNs=states.get("accepted", 0),
                pending=states.get("pending", 0) + states.get("sending", 0))


def handle(db, owner, path, method, body):
    now = time.time()
    if (path, method) == ("/sos/status", "GET"):
        return "200 OK", {"ready": recent_heartbeat(db, now)}
    if (path, method) == ("/sos/receiver", "DELETE"):
        db.execute("DELETE FROM sos_receivers WHERE owner=?", (owner,))
        db.execute("UPDATE sos_outbox SET status='failed' WHERE receiver=? AND status='pending'", (owner,))
        return "200 OK", {"enabled": False}
    if (path, method) == ("/sos/receiver", "PUT"):
        raw = body()
        token = raw.get("token")
        if not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{32,512}", token) or len(token) % 2:
            raise ValueError("invalid push token")
        latitude, longitude, _, captured = fix(raw.get("location"), now)
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM sos_receivers WHERE token=? AND owner<>?", (token, owner))
        db.execute("""INSERT INTO sos_receivers VALUES (?,?,?,?,?)
                      ON CONFLICT(owner) DO UPDATE SET token=excluded.token,latitude=excluded.latitude,
                        longitude=excluded.longitude,captured_at=excluded.captured_at
                      WHERE excluded.captured_at>=sos_receivers.captured_at""",
                   (owner, token, latitude, longitude, captured))
        return "200 OK", {"enabled": True}
    if (path, method) == ("/sos/inbox", "GET"):
        rows = db.execute("""SELECT i.id,i.created,i.name,i.equipment,i.latitude,i.longitude,i.accuracy
            FROM sos_incidents i JOIN sos_outbox o ON o.incident=i.id
            WHERE o.receiver=? AND i.created>=? ORDER BY i.created DESC""", (owner, now - VISIBLE_SECONDS))
        return "200 OK", [incident(row) for row in rows]
    if method == "GET" and re.fullmatch(r"/sos/[0-9a-f-]{36}/receipt", path):
        identifier = str(UUID(path.split("/")[2]))
        found = db.execute("SELECT 1 FROM sos_incidents WHERE id=? AND owner=? AND created>=?",
                           (identifier, owner, now - VISIBLE_SECONDS)).fetchone()
        return ("200 OK", receipt(db, identifier)) if found else ("404 Not Found", {"error": "unknown SOS"})
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
    if db.execute("SELECT 1 FROM sos_incidents WHERE owner=? AND created>=?", (owner, now - 60)).fetchone():
        return "429 Too Many Requests", {"error": "recent SOS"}
    latitude, longitude, accuracy, _ = fix(raw.get("location"), now)
    name = raw.get("name", "").strip()
    equipment = raw.get("equipment")
    if len(name) > 50 or (equipment is not None and (not isinstance(equipment, str) or len(equipment) > 320)):
        raise ValueError("invalid rider details")
    profile = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
    if profile:
        name = json.loads(profile[0])["name"]
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
        db.execute("""UPDATE sos_outbox SET status='failed'
                      WHERE status IN ('pending','sending') AND (
                      incident IN (SELECT id FROM sos_incidents WHERE created<?)
                      OR NOT EXISTS (SELECT 1 FROM sos_receivers r WHERE r.owner=sos_outbox.receiver))""",
                   (now - PUSH_SECONDS,))
        jobs = db.execute("""SELECT o.incident,o.receiver,r.token,i.created,i.name,i.equipment
            FROM sos_outbox o JOIN sos_incidents i ON i.id=o.incident JOIN sos_receivers r ON r.owner=o.receiver
            WHERE (o.status='pending' AND o.attempt_at<=?) OR (o.status='sending' AND o.attempt_at<=?)
            ORDER BY i.created,o.receiver LIMIT 16""", (now - 5, now - 25)).fetchall()
        db.executemany("UPDATE sos_outbox SET status='sending',attempt_at=? WHERE incident=? AND receiver=?",
                       [(now, identifier, receiver) for identifier, receiver, _, _, _, _ in jobs])

    def deliver(job):
        identifier, _, token, created, name, equipment = job
        return push(token, identifier, int(created + PUSH_SECONDS), name, equipment)

    if jobs:
        with ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(deliver, jobs))
        with db:
            db.executemany("""UPDATE sos_outbox SET status=? WHERE incident=? AND receiver=?
                              AND status='sending' AND attempt_at=?""",
                           [(status, job[0], job[1], now) for job, status in zip(jobs, statuses)])


def worker():
    # Imported only by the outbox process, so the main WSGI API can run without APNs extras.
    import httpx

    context = ssl.create_default_context()
    context.load_cert_chain(os.environ["RIDER_APNS_CERT"], os.environ.get("RIDER_APNS_KEY"))
    topic = os.environ["RIDER_APNS_TOPIC"]
    host = "api.sandbox.push.apple.com" if os.environ.get("RIDER_APNS_SANDBOX") == "1" else "api.push.apple.com"
    with httpx.Client(base_url="https://" + host, http2=True, verify=context, timeout=4) as client, \
            closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(SCHEMA)

        def push(token, identifier, expiration, name, equipment):
            headers = {"apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10",
                       "apns-expiration": str(expiration), "apns-collapse-id": identifier}
            message = f"{name} подал сигнал SOS поблизости."
            if equipment:
                message += " Комплект: " + equipment[:100]
            payload = {"aps": {"alert": {"title": "SOS Rider", "body": message},
                               "sound": "default"}, "riderSOS": identifier}
            try:
                response = client.post("/3/device/" + token, headers=headers, json=payload)
            except httpx.HTTPError:
                return "pending"
            if response.status_code == 200:
                return "accepted"
            return "pending" if response.status_code == 429 or response.status_code >= 500 else "failed"

        while True:
            worker_batch(db, push)
            time.sleep(2)


if __name__ == "__main__":
    worker()
