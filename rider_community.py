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
from datetime import datetime, timedelta, timezone
from html import escape
from contextlib import closing
from urllib.parse import urlencode
from urllib.request import urlopen

import rider_sos
import rider_discovery

VISIBILITY_FIELDS = ("publicProfile", "statsPublic", "recordsPublic")
RECORD_FIELDS = {"height", "airtime", "distance", "heightSum"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, document TEXT NOT NULL);
CREATE VIEW IF NOT EXISTS public_profiles AS
    SELECT id,document FROM profiles WHERE coalesce(json_extract(document,'$.publicProfile'),1)=1;
CREATE VIEW IF NOT EXISTS public_stats_profiles AS
    SELECT id,document FROM public_profiles WHERE coalesce(json_extract(document,'$.statsPublic'),1)=1;
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
CREATE TABLE IF NOT EXISTS comment_replies(
    comment TEXT PRIMARY KEY REFERENCES post_comments(id) ON DELETE CASCADE,
    parent TEXT NOT NULL REFERENCES post_comments(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS replies_by_parent ON comment_replies(parent);
CREATE TABLE IF NOT EXISTS post_equipment(
    post TEXT PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE, document TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS post_media(
    post TEXT PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
    section TEXT NOT NULL CHECK(section IN ('gallery','journal')), video BLOB
);
CREATE TABLE IF NOT EXISTS comment_likes(
    comment TEXT NOT NULL REFERENCES post_comments(id) ON DELETE CASCADE,
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    PRIMARY KEY(comment, owner)
);
CREATE TABLE IF NOT EXISTS shakas(
    post TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, PRIMARY KEY(post, owner)
);
CREATE TABLE IF NOT EXISTS reposts(
    id TEXT PRIMARY KEY, post TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, UNIQUE(owner, post)
);
CREATE TABLE IF NOT EXISTS follow_activity(
    owner TEXT NOT NULL, target TEXT NOT NULL, created_at REAL NOT NULL,
    PRIMARY KEY(owner, target),
    FOREIGN KEY(owner, target) REFERENCES follows(owner, target) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS direct_messages(
    id TEXT PRIMARY KEY,
    sender TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    recipient TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, body TEXT NOT NULL,
    post TEXT REFERENCES posts(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS direct_sender ON direct_messages(sender, recipient, created_at);
CREATE TABLE IF NOT EXISTS message_receipts(
    message TEXT PRIMARY KEY REFERENCES direct_messages(id) ON DELETE CASCADE,
    read INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS activity_reads(
    owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    sequence INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS activity_hidden(
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    id TEXT NOT NULL, PRIMARY KEY(owner,id)
);
CREATE TABLE IF NOT EXISTS activity_cleared(
    owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    through REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS stories(
    id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    created REAL NOT NULL, caption TEXT NOT NULL, photo BLOB NOT NULL, video BLOB
);
CREATE INDEX IF NOT EXISTS stories_created ON stories(created DESC);
CREATE INDEX IF NOT EXISTS stories_owner ON stories(owner, created DESC);
CREATE TABLE IF NOT EXISTS story_views(
    story TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    viewer TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    PRIMARY KEY(story, viewer)
);
CREATE TABLE IF NOT EXISTS story_likes(
    story TEXT NOT NULL, viewer TEXT NOT NULL,
    PRIMARY KEY(story, viewer),
    FOREIGN KEY(story, viewer) REFERENCES story_views(story, viewer) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS direct_recipient ON direct_messages(recipient, sender, created_at);
CREATE TABLE IF NOT EXISTS message_attachments(
    message TEXT PRIMARY KEY REFERENCES direct_messages(id) ON DELETE CASCADE,
    filename TEXT NOT NULL, content_type TEXT NOT NULL, data BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS rider_public_rides(
    owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    document TEXT NOT NULL
);
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
CREATE TABLE IF NOT EXISTS season_scores(
    owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    year INTEGER NOT NULL, activity_points INTEGER NOT NULL, generated_at REAL NOT NULL,
    PRIMARY KEY(owner, year)
);
CREATE INDEX IF NOT EXISTS scores_by_year ON season_scores(year);
"""

SEASON_ZONE = timezone(timedelta(hours=3))
MINIMUM_SCORING_HEIGHT = 2.0
MINIMUM_MISSION_SECONDS = 15 * 60
# Keep the stable mission IDs and rewards in sync with RiderMission in SessionInsights.swift.
MISSION_RULES = {
    "water15": ("water", 15, 5),
    "water25": ("water", 25, 8),
    "water35": ("water", 35, 10),
    "water45": ("water", 45, 12),
    "water60": ("water", 60, 15),
    "water90": ("water", 90, 20),
    "route1": ("route", 1000, 6),
    "route2": ("route", 2000, 8),
    "route3": ("route", 3000, 10),
    "route5": ("route", 5000, 14),
    "route8": ("route", 8000, 18),
    "route12": ("route", 12000, 22),
    "jumps1": ("jumps", 1, 6),
    "jumps3": ("jumps", 3, 9),
    "jumps5": ("jumps", 5, 12),
    "jumps8": ("jumps", 8, 15),
    "jumps12": ("jumps", 12, 20),
    "jumps20": ("jumps", 20, 25),
    "height2": ("height", 2, 6),
    "height3": ("height", 3, 8),
    "height4": ("height", 4, 11),
    "height5": ("height", 5, 14),
    "height6": ("height", 6, 18),
    "air1": ("air", 1, 6),
    "air15": ("air", 1.5, 8),
    "air2": ("air", 2, 10),
    "air25": ("air", 2.5, 13),
    "air3": ("air", 3, 16),
    "height7": ("height", 7, 21),
    "height8": ("height", 8, 24),
    "height9": ("height", 9, 27),
    "height10": ("height", 10, 30),
    "height11": ("height", 11, 33),
    "height12": ("height", 12, 36),
    "height13": ("height", 13, 39),
    "height14": ("height", 14, 42),
    "height15": ("height", 15, 45),
    "height16": ("height", 16, 48),
    "height17": ("height", 17, 51),
    "height18": ("height", 18, 54),
    "height19": ("height", 19, 57),
    "height20": ("height", 20, 60),
    "height21": ("height", 21, 63),
    "height22": ("height", 22, 66),
    "height23": ("height", 23, 69),
    "height24": ("height", 24, 72),
    "height25": ("height", 25, 75),
    "height26": ("height", 26, 78),
    "height27": ("height", 27, 81),
    "height28": ("height", 28, 84),
    "height29": ("height", 29, 87),
    "height30": ("height", 30, 90),
    "height31": ("height", 31, 93),
    "height32": ("height", 32, 96),
    "height33": ("height", 33, 99),
    "height34": ("height", 34, 100),
    "height35": ("height", 35, 100),
    "water75": ("water", 75, 18),
    "water105": ("water", 105, 24),
    "water120": ("water", 120, 28),
    "water150": ("water", 150, 34),
    "water180": ("water", 180, 40),
    "route15": ("route", 15000, 25),
    "route20": ("route", 20000, 31),
    "route25": ("route", 25000, 36),
    "route30": ("route", 30000, 42),
    "jumps25": ("jumps", 25, 29),
    "jumps30": ("jumps", 30, 34),
    "jumps40": ("jumps", 40, 43),
    "jumps50": ("jumps", 50, 52),
    "air35": ("air", 3.5, 19),
    "air4": ("air", 4, 22),
    "air5": ("air", 5, 27),
    "air6": ("air", 6, 33),
    "air7": ("air", 7, 39),
    "air8": ("air", 8, 45),
    "air10": ("air", 10, 55),
}


def season_at(now):
    year = datetime.fromtimestamp(now, SEASON_ZONE).year
    start = datetime(year, 1, 1, tzinfo=SEASON_ZONE).timestamp()
    end = datetime(year + 1, 1, 1, tzinfo=SEASON_ZONE).timestamp()
    return year, start, end


def activity_points(items, start, end, now):
    if not isinstance(items, list) or len(items) > 5000:
        raise ValueError("invalid rides")
    seen = set()
    missions_done = set()
    seconds = jumps = scoring_jumps = mission_points = 0
    best_height = best_airtime = 0
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("invalid ride")
        key = identifier(item.get("id"))
        recorded, duration, count = (item.get(k) for k in ("startedAt", "seconds", "jumps"))
        if key in seen or not number(recorded, start, min(end, now + 300)) or recorded >= end:
            raise ValueError("invalid ride")
        if type(duration) is not int or not 0 <= duration <= 28800 or type(count) is not int or not 0 <= count <= 100:
            raise ValueError("invalid ride totals")
        height, airtime = item.get("height"), item.get("airtime")
        if (height is None) != (count == 0) or (height is not None and not number(height, 0.5, 100)):
            raise ValueError("invalid ride height")
        if airtime is not None and (count == 0 or not number(airtime, 0.01, 120)):
            raise ValueError("invalid ride airtime")
        # Older clients only sent the total. A peak cannot show how many jumps cleared 2 m.
        qualifying = item.get("scoringJumps", 0)
        if type(qualifying) is not int or not 0 <= qualifying <= count:
            raise ValueError("invalid scoring jump count")
        if qualifying and (height is None or height < MINIMUM_SCORING_HEIGHT):
            raise ValueError("invalid scoring jump height")
        seen.add(key)
        seconds += duration
        jumps += count
        scoring_jumps += qualifying
        best_height = max(best_height, height or 0)
        best_airtime = max(best_airtime, airtime or 0)
        mission = item.get("mission")
        if mission is not None:
            if not isinstance(mission, str) or mission not in MISSION_RULES:
                raise ValueError("invalid mission")
            category, target, reward = MISSION_RULES[mission]
            distance = item.get("missionDistance")
            if distance is not None and (category != "route" or not number(distance, 0, 500000)):
                raise ValueError("invalid mission distance")
            values = {"water": duration / 60, "route": distance or 0, "jumps": qualifying,
                      "height": height or 0, "air": airtime or 0}
            if mission not in missions_done and duration >= MINIMUM_MISSION_SECONDS and values[category] >= target:
                missions_done.add(mission)
                mission_points += reward
    achievements = ((bool(seen), 20), (seconds >= 36000, 80), (seconds >= 180000, 200),
                    (best_height >= 5, 60), (best_height >= 10, 120),
                    (best_airtime >= 3, 40), (jumps >= 50, 80))
    return seconds // 60 + scoring_jumps * 5 + mission_points + sum(
        bonus for reached, bonus in achievements if reached
    )


def replace_records(db, owner, scores):
    db.execute("DELETE FROM records WHERE owner=?", (owner,))
    db.executemany("INSERT INTO records VALUES (?,?,?,?,?,?,?)",
                   ((owner, *row[:6]) for row in scores))
    db.executemany("INSERT INTO record_details VALUES (?,?,?,?,?)",
                   ((owner, row[0], *row[6:]) for row in scores))


def season_credit(db, owner, year, start, end):
    followers = db.execute("""SELECT count(*) FROM follow_activity
        WHERE target=? AND created_at>=? AND created_at<?
          AND owner IN (SELECT id FROM public_profiles)""", (owner, start, end)).fetchone()[0]
    return {"year": year, "followers": followers}


def season_rankings(db, start, end, year, viewer=None):
    rows = db.execute("""WITH followers AS (
        SELECT target, count(*) AS n
        FROM follow_activity
        WHERE created_at>=? AND created_at<? AND owner IN (SELECT id FROM public_profiles)
        GROUP BY target
    ), ranked AS (
        SELECT p.id, p.document, coalesce(s.activity_points, 0)
             + CASE WHEN f.n>=1 THEN 20 ELSE 0 END
             + CASE WHEN f.n>=10 THEN 40 ELSE 0 END
             + CASE WHEN f.n>=50 THEN 120 ELSE 0 END AS points
        FROM profiles p
        LEFT JOIN season_scores s ON s.owner=p.id AND s.year=?
        LEFT JOIN followers f ON f.target=p.id
        WHERE coalesce(json_extract(p.document,'$.recordsPublic'),1)=1
    )
    , places AS (SELECT *,row_number() OVER (ORDER BY points DESC,id) AS position FROM ranked)
    SELECT id,document,points,position FROM places WHERE position<=50 OR id=? ORDER BY position""", (start, end, year, viewer))
    output = []
    for rider, document, points, position in rows:
        profile = json.loads(document)
        entry = dict(id=rider, name=profile["name"], username=profile.get("username"), points=points)
        entry.update(avatar=profile.get("avatar"), premium=is_premium(profile), position=position)
        output.append(entry)
    return output


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
    if "birthday" in raw:
        value = raw["birthday"]
        if value != "":
            if not isinstance(value, str) or not re.fullmatch(r"[0-9]{2}-[0-9]{2}",value):
                raise ValueError("invalid birthday")
            datetime.strptime("2000-"+value,"%Y-%m-%d")
        result["birthday"] = value
        if type(raw.get("showBirthday",False)) is not bool:
            raise ValueError("invalid birthday visibility")
        result["showBirthday"] = raw.get("showBirthday",False)
    return result


RIDER_QUERY = """SELECT p.id,p.document,
    (SELECT count(*) FROM follows f JOIN public_profiles u ON u.id=f.owner WHERE f.target=p.id),
    EXISTS(SELECT 1 FROM follows f WHERE f.owner=? AND f.target=p.id),
    (SELECT count(*) FROM follows f JOIN public_profiles u ON u.id=f.target WHERE f.owner=p.id)
    FROM profiles p """


def rider_entry(row, owner):
    key, document, followers, following, following_count = row
    profile = json.loads(document)
    if key != owner and not (profile.get("showBirthday") and profile.get("publicProfile",True)):
        profile.pop("birthday",None)
        profile.pop("showBirthday",None)
    if key != owner and not profile.get("recordsPublic", True):
        profile["totals"] = {k: v for k, v in profile["totals"].items() if k not in RECORD_FIELDS}
    profile["premium"] = is_premium(profile)
    profile.pop("premiumUntil", None)
    return dict(id=key, profile=profile, followers=followers, following=bool(following),
                followingCount=following_count)


def state(db, owner, include_directory=True):
    mine = db.execute(RIDER_QUERY + "WHERE p.id=?", (owner, owner)).fetchone()
    others = db.execute(RIDER_QUERY + """WHERE p.id<>? AND p.id IN (SELECT id FROM public_profiles)
        ORDER BY p.rowid DESC LIMIT 40""", (owner, owner)) if include_directory else []
    return {"mine": rider_entry(mine, owner) if mine else None,
            "riders": [rider_entry(row, owner) for row in others]}


def rider_path_result(db, owner, key, relation):
    if key == "me":
        key = owner
    row = db.execute(RIDER_QUERY + """WHERE (p.id=? OR p.id=(SELECT owner FROM handles WHERE username=?))
        """, (owner, key, key)).fetchone()
    if row is None:
        return None
    key = row[0]
    if relation and key != owner and not json.loads(row[1]).get("publicProfile", True):
        return None
    if relation == "followers":
        query = "SELECT p.id,p.document FROM follows f JOIN public_profiles p ON p.id=f.owner WHERE f.target=?"
    elif relation == "following":
        query = "SELECT p.id,p.document FROM follows f JOIN public_profiles p ON p.id=f.target WHERE f.owner=?"
    else:
        rider = rider_entry(row, owner)
        result = {"rider": rider, "posts": feed(db, owner, "profile", key), "mine": owner == key}
        year, start, end = season_at(time.time())
        points = db.execute("SELECT activity_points FROM season_scores WHERE owner=? AND year=?",
                            (key, year)).fetchone()
        count = season_credit(db, key, year, start, end)["followers"]
        result["points"] = (points[0] if points else 0) + sum(
            bonus for threshold, bonus in ((1, 20), (10, 40), (50, 120)) if count >= threshold)
        records_visible = key == owner or rider["profile"].get("recordsPublic", True)
        if records_visible:
            result["distance"] = db.execute("SELECT max(distance) FROM record_details WHERE owner=?",
                                            (key,)).fetchone()[0]
        result["year"] = year
        history = db.execute("SELECT document FROM rider_public_rides WHERE owner=?", (key,)).fetchone()
        rides = json.loads(history[0]) if history else []
        if not records_visible:
            rides = [{k: v for k, v in ride.items() if k not in RECORD_FIELDS} for ride in rides]
        result["sessionRecords"] = [{k: v for k, v in ride.items() if k in
                                     ("id", "startedAt", "seconds", "jumps", "height", "airtime", "distance")}
                                    for ride in rides]
        if key == owner or (rider["profile"].get("publicProfile", True) and rider["profile"].get("statsPublic", True)):
            result["rides"] = rides
        if key != owner and not rider["profile"].get("publicProfile", True):
            rider["profile"].pop("bio", None)
        return result
    return [rider_card(*item) for item in db.execute(query + " ORDER BY p.id", (key,))]


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


def public_ride_rows(items):
    if not isinstance(items, list) or len(items) > 50000:
        raise ValueError("invalid public rides")
    cleaned = {}
    for item in items:
        key = identifier(item["id"])
        if key in cleaned or not number(item.get("startedAt"), 0, 4e9) or not number(item.get("seconds"), 1, 86400):
            raise ValueError("invalid public ride")
        if type(item.get("jumps")) is not int or not 0 <= item["jumps"] <= 10000:
            raise ValueError("invalid jump count")
        ride = {field: item[field] for field in ("id", "startedAt", "seconds", "jumps")}
        for field, maximum in (("height", 100), ("airtime", 120), ("distance", 100000)):
            value = item.get(field)
            if value is not None:
                if not number(value, 0, maximum):
                    raise ValueError("invalid ride metric")
                ride[field] = value
        for field in ("spot", "kite", "board"):
            value = item.get(field)
            if value is not None:
                if not isinstance(value, str) or len(value) > 255:
                    raise ValueError("invalid analytics label")
                if value.strip():
                    ride[field] = value.strip()
        for field, upper in (("windMS", 150), ("windDirection", 360), ("heightSum", 100 * item["jumps"])):
            if item.get(field) is not None:
                if not number(item[field], 0, upper):
                    raise ValueError("invalid ride measurement")
                ride[field] = item[field]
        cleaned[key] = ride
    return sorted(cleaned.values(), key=lambda item: (-item["startedAt"], item["id"]))


MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024
MAX_ATTACHMENT_BASE64 = 4 * ((MAX_ATTACHMENT_BYTES + 2) // 3)
# JSON encoders can escape every slash in base64. The parsed data has its own limit.
MAX_MESSAGE_JSON = 2 * MAX_ATTACHMENT_BASE64 + 8192


def message_attachment(item):
    if not isinstance(item, dict):
        raise ValueError("invalid attachment")
    name, mime, encoded = item.get("filename"), item.get("contentType"), item.get("data")
    if not isinstance(name, str) or not 1 <= len(name) <= 120 or name != name.strip():
        raise ValueError("invalid filename")
    if name in (".", "..") or any(character in name for character in ("/", chr(92), ":")) or any(ord(c) < 32 for c in name):
        raise ValueError("invalid filename")
    if not isinstance(mime, str) or not re.fullmatch(r"[a-z0-9.+-]{1,64}/[a-z0-9.+-]{1,64}", mime):
        raise ValueError("invalid content type")
    if not isinstance(encoded, str) or len(encoded) > MAX_ATTACHMENT_BASE64:
        raise ValueError("invalid attachment size")
    data = base64.b64decode(encoded, validate=True)
    if not 1 <= len(data) <= MAX_ATTACHMENT_BYTES:
        raise ValueError("invalid attachment size")
    if mime in ("audio/mp4", "video/mp4") and (len(data) <= 12 or data[4:8] != b"ftyp"):
        raise ValueError("invalid recorded media")
    return name, mime, data


def post_fields(raw, target):
    if not isinstance(raw, dict) or identifier(raw.get("id")) != target:
        raise ValueError("invalid post")
    caption, location, photo = raw.get("caption"), raw.get("location"), raw.get("photo")
    section, clip = raw.get("section", "gallery"), raw.get("video")
    if not isinstance(caption, str) or len(caption) > 800 or section not in ("gallery", "journal"):
        raise ValueError("invalid caption or section")
    image = b""
    if photo is not None:
        if not isinstance(photo, str):
            raise ValueError("invalid post photo")
        image = base64.b64decode(photo, validate=True)
        if not 3 < len(image) <= 390000 or not image.startswith(b"\xff\xd8\xff"):
            raise ValueError("invalid post photo")
    video = None
    if clip is not None:
        if not isinstance(clip, str):
            raise ValueError("invalid video")
        video = base64.b64decode(clip, validate=True)
        if not 12 < len(video) <= 12 * 1024 * 1024 or video[4:8] != b"ftyp" or not image:
            raise ValueError("invalid video or missing cover")
    if (section == "gallery" and not image) or (not caption.strip() and not image):
        raise ValueError("empty post or missing gallery media")
    if location is not None:
        if not isinstance(location, dict) or not isinstance(location.get("name"), str):
            raise ValueError("invalid geotag")
        name = location["name"].strip()
        lat, lon = location.get("latitude"), location.get("longitude")
        if not 1 <= len(name) <= 100 or ((lat is not None or lon is not None)
                                       and not (number(lat, -90, 90) and number(lon, -180, 180))):
            raise ValueError("invalid geotag")
        location = json.dumps({"name": name, "latitude": lat, "longitude": lon}, ensure_ascii=False)
    equipment = raw.get("equipment")
    if equipment is not None:
        if not isinstance(equipment, dict):
            raise ValueError("invalid equipment")
        fields = ("name", "kite", "board")
        if any(not isinstance(equipment.get(key), str) or not 1 <= len(equipment[key].strip()) <= 120 for key in fields):
            raise ValueError("invalid equipment")
        equipment = json.dumps({key: equipment[key].strip() for key in fields}, ensure_ascii=False)
    return caption.strip(), location, image, equipment, section, video


def is_premium(profile):
    return profile.get("premiumUntil", 0) > time.time()


def rider_card(owner, document):
    rider = json.loads(document)
    return {"id": owner, "premium": is_premium(rider), "name": rider["name"], "username": rider.get("username"), "avatar": rider.get("avatar")}


def reactions(db, post_id, owner, limit=3, offset=0):
    count, mine = db.execute("""SELECT count(*),max(s.owner=?) FROM shakas s
        JOIN public_profiles r ON r.id=s.owner WHERE s.post=?""", (owner, post_id)).fetchone()
    recent = db.execute("""SELECT r.id,r.document FROM shakas s JOIN public_profiles r ON r.id=s.owner
        WHERE s.post=? ORDER BY s.created_at DESC,s.owner LIMIT ? OFFSET ?""", (post_id, limit, offset))
    return {"total": count, "mine": bool(mine), "people": [rider_card(*row) for row in recent]}


def comment_reactors(db, comment_id, owner, offset):
    visible = "FROM comment_likes l JOIN public_profiles p ON p.id=l.owner WHERE l.comment=?"
    count, mine = db.execute("SELECT count(*),max(l.owner=?) " + visible, (owner, comment_id)).fetchone()
    rows = db.execute("SELECT p.id,p.document " + visible + " ORDER BY l.rowid DESC LIMIT 50 OFFSET ?",
                      (comment_id, offset))
    return {"total": count, "mine": bool(mine), "people": [rider_card(*row) for row in rows]}


def feed(db, owner, mode, post_id=None):
    filters = {
        "following": """e.owner<>? AND EXISTS(SELECT 1 FROM follows WHERE owner=? AND target=e.owner)""",
        "recommended": """e.owner<>? AND NOT EXISTS(SELECT 1 FROM follows WHERE owner=? AND target=e.owner)""",
        "my-reposts": "e.owner=? AND e.id<>e.source",
        "single": "e.id=?",
        "profile": "e.owner=?",
    }
    params = (owner, owner) if mode in ("following", "recommended") else (post_id or owner,)
    query = """WITH entries(id,source,owner,created_at) AS (
        SELECT id,id,owner,created_at FROM posts
        UNION ALL SELECT id,post,owner,created_at FROM reposts
    )
    SELECT e.id,p.id,e.created_at,p.caption,p.location,g.document,
           e.owner,r.document,p.owner,src.document,coalesce(m.section,'gallery'),m.video IS NOT NULL,length(p.photo)>0,
           EXISTS(SELECT 1 FROM follows WHERE owner=? AND target=e.owner),
           EXISTS(SELECT 1 FROM reposts WHERE owner=? AND post=p.id)
    FROM entries e JOIN posts p ON p.id=e.source JOIN public_profiles r ON r.id=e.owner
    JOIN public_profiles src ON src.id=p.owner LEFT JOIN post_equipment g ON g.post=p.id LEFT JOIN post_media m ON m.post=p.id
    WHERE """ + filters[mode] + " ORDER BY e.created_at DESC,e.id LIMIT 40"
    entries = []
    for row in db.execute(query, (owner, owner, *params)):
        entry_id, source, created, caption, location, gear, author_id, document, source_owner, source_doc, section, video, photo, following, reposted = row
        author = rider_card(author_id, document)
        post = {"id": entry_id, "createdAt": created, "caption": caption, "published": True,
                "location": json.loads(location) if location else None, "equipment": json.loads(gear) if gear else None,
                "section": section, "hasVideo": bool(video), "hasCover": bool(photo)}
        if entry_id != source:
            original = rider_card(source_owner, source_doc)
            post.update(sourceID=source, sourceAuthor=original["name"], sourceUsername=original["username"])
        entries.append({"post": post, "commentSummary": comment_summary(db, source), "author": author["name"], "username": author["username"],
                        "premium": author["premium"], "avatar": author["avatar"], "authorID": author_id, "following": bool(following),
                        "mine": owner == author_id, "reposted": bool(reposted), "reaction": reactions(db, source, owner)})
    return entries


def activity(db, owner):
    query = """WITH events AS (
        SELECT kind,actor,post,date,p.document,
               kind||':'||source||':'||printf('%!.17g',date) AS item_id FROM (
        SELECT 'shaka' AS kind,s.owner AS actor,s.post AS post,s.created_at AS date,s.post||s.owner AS source
        FROM shakas s JOIN posts r ON r.id=s.post WHERE r.owner=?
        UNION ALL
        SELECT 'comment',c.author,c.post,c.created_at,c.id FROM post_comments c JOIN posts r ON r.id=c.post WHERE r.owner=?
          AND NOT EXISTS (SELECT 1 FROM comment_replies x JOIN post_comments parent ON parent.id=x.parent
                          WHERE x.comment=c.id AND parent.author=r.owner)
        UNION ALL
        SELECT 'reply',c.author,c.post,c.created_at,c.id FROM comment_replies x
          JOIN post_comments c ON c.id=x.comment JOIN post_comments parent ON parent.id=x.parent
          JOIN posts r ON r.id=c.post JOIN public_profiles visible ON visible.id=r.owner WHERE parent.author=?
        UNION ALL
        SELECT 'follow',f.owner,NULL,f.created_at,f.owner FROM follow_activity f WHERE f.target=?
        UNION ALL
        SELECT 'repost',s.owner,s.post,s.created_at,s.id FROM reposts s JOIN posts r ON r.id=s.post WHERE r.owner=?
    ) AS a JOIN public_profiles p ON p.id=a.actor
    WHERE a.actor<>?)
    SELECT kind,actor,post,date,document,item_id FROM events
    WHERE date>coalesce((SELECT through FROM activity_cleared WHERE owner=?),0)
      AND NOT EXISTS (SELECT 1 FROM activity_hidden WHERE owner=? AND id=item_id)
    ORDER BY date DESC,actor,item_id LIMIT 60"""
    return [{"kind": kind, "person": rider_card(actor, document), "postID": post, "createdAt": date, "id": key}
            for kind, actor, post, date, document, key in db.execute(query, (owner,) * 8)]


def inbox(db, owner):
    query = """WITH dialogs AS (
        SELECT recipient AS peer, created_at FROM direct_messages WHERE sender=?
        UNION ALL SELECT sender, created_at FROM direct_messages WHERE recipient=?
    )
    SELECT p.id,p.document FROM profiles p JOIN dialogs d ON d.peer=p.id
    GROUP BY p.id ORDER BY max(d.created_at) DESC,p.id LIMIT 60"""
    return [rider_card(*row) for row in db.execute(query, (owner, owner))]


def deliver_inbox(db, owner):
    db.execute("""INSERT OR IGNORE INTO message_receipts(message)
        SELECT m.id FROM direct_messages m LEFT JOIN message_receipts x ON x.message=m.id
        WHERE m.recipient=? AND x.message IS NULL""", (owner,))


def unread_summary(db, owner):
    deliver_inbox(db, owner)
    messages = dict(db.execute("""SELECT m.sender,count(*) FROM direct_messages m
        JOIN message_receipts x ON x.message=m.id WHERE m.recipient=? AND x.read=0
        GROUP BY m.sender""", (owner,)))
    activity_count = db.execute(f"""SELECT count(*) FROM rider_alert_events e
        WHERE e.owner=? AND e.kind<>'message' AND {rider_discovery.VISIBLE}
        AND e.sequence > coalesce((SELECT sequence FROM activity_reads WHERE owner=?),0)""",
                                (owner, owner)).fetchone()[0]
    return {"threads": messages, "activity": activity_count}


def visible_stories(db, owner):
    rows = db.execute("""SELECT s.id,s.owner,p.document,s.caption,s.created,s.video IS NOT NULL,
        EXISTS(SELECT 1 FROM story_views v WHERE v.story=s.id AND v.viewer=?),
        EXISTS(SELECT 1 FROM story_likes l WHERE l.story=s.id AND l.viewer=?)
        FROM stories s JOIN public_profiles p ON p.id=s.owner WHERE s.created>?
        ORDER BY (s.owner=?) DESC,s.created DESC,s.id LIMIT 150""", (owner, owner, time.time()-86400, owner))
    return [dict(id=key, author=rider_card(author, document), caption=caption, createdAt=created,
                 video=bool(video), seen=owner==author or bool(seen), mine=owner==author, liked=bool(liked))
            for key,author,document,caption,created,video,seen,liked in rows]


def story_viewers(db, key, offset):
    people = []
    rows = db.execute("""SELECT p.id,p.document,l.viewer IS NOT NULL FROM story_views v
        JOIN profiles p ON p.id=v.viewer LEFT JOIN story_likes l ON l.story=v.story AND l.viewer=v.viewer
        JOIN stories s ON s.id=v.story WHERE v.story=? AND v.viewer<>s.owner
        ORDER BY v.viewer LIMIT 31 OFFSET ?""", (key, offset))
    for viewer, document, liked in rows:
        rider = json.loads(document)
        people.append(dict(person={"id":viewer, "name":rider["name"], "username":rider.get("username")},
                           liked=bool(liked)))
    return {"people":people[:30], "nextOffset":offset+30 if len(people)>30 else None}


def thread(db, owner, peer):
    query = """SELECT m.id,m.sender,m.body,m.created_at,m.post,a.filename,a.content_type,length(a.data),x.message IS NOT NULL,coalesce(x.read,0)
    FROM direct_messages m LEFT JOIN message_attachments a ON a.message=m.id
    LEFT JOIN message_receipts x ON x.message=m.id
    WHERE (m.sender=? AND m.recipient=?) OR (m.sender=? AND m.recipient=?)
    ORDER BY m.created_at DESC,m.id DESC LIMIT 100"""
    shared = {}
    output = []
    for key, sender, body, date, post, filename, mime, size, delivered, read in reversed(list(db.execute(query, (owner, peer, peer, owner)))):
        if post and post not in shared:
            shared[post] = next(iter(feed(db, owner, "single", post)), None)
        entry = shared.get(post)
        output.append({"id": key, "mine": sender == owner, "text": body, "createdAt": date, "postID": post,
                       "postCaption": entry["post"]["caption"] if entry else None, "sharedPost": entry,
                       "delivered": bool(delivered), "read": bool(read),
                       "attachment": {"filename": filename, "contentType": mime, "size": size} if filename else None})
    return output


def comment_summary(db, post_id):
    where = "FROM post_comments c JOIN public_profiles p ON p.id=c.author WHERE c.post=?"
    total = db.execute("SELECT count(*) " + where, (post_id,)).fetchone()[0]
    result = {"total": total}
    if total:
        body, document = db.execute("SELECT substr(c.body,1,181),p.document " + where +
                                    " ORDER BY c.created_at DESC,c.id DESC LIMIT 1", (post_id,)).fetchone()
        profile = json.loads(document)
        result["preview"] = {"text": body, "author": profile["name"], "username": profile.get("username")}
    return result


def comments(db, post_id, owner):
    query = """SELECT c.id,c.author,c.created_at,c.body,p.document,parent.id,pp.document,
        (SELECT count(*) FROM comment_likes l JOIN public_profiles r ON r.id=l.owner WHERE l.comment=c.id),
        EXISTS(SELECT 1 FROM comment_likes WHERE comment=c.id AND owner=?)
        FROM post_comments c JOIN public_profiles p ON p.id=c.author
        LEFT JOIN comment_replies x ON x.comment=c.id LEFT JOIN post_comments parent ON parent.id=x.parent
        LEFT JOIN public_profiles pp ON pp.id=parent.author
        WHERE c.post=? ORDER BY c.created_at DESC,c.id DESC LIMIT 100"""
    output = []
    for comment_id, author_id, created_at, body, document, parent, parent_doc, likes, liked in reversed(list(db.execute(query, (owner, post_id)))):
        person = rider_card(author_id, document)
        output.append({"id": comment_id, "createdAt": created_at, "text": body,
                       "author": person["name"], "username": person["username"], "avatar": person["avatar"],
                       "premium": person["premium"], "replyTo": parent, "replyName": (json.loads(parent_doc).get("username") or json.loads(parent_doc)["name"]) if parent_doc else None,
                       "authorID": author_id, "mine": author_id == owner, "likes": likes, "liked": bool(liked)})
    return output


def top_rows(db, raw, viewer=None):
    if isinstance(raw, dict) and raw.get("metric") == "rank":
        year, start, end = season_at(time.time())
        if type(raw.get("season")) is not int:
            raise ValueError("invalid season")
        return season_rankings(db, start, end, year, viewer) if raw["season"] == year else []
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
        SELECT p.id,p.document,r.height,r.airtime,d.distance,d.kite,d.board,r.session_id,r.spot_name,
               ROW_NUMBER() OVER (PARTITION BY r.owner ORDER BY {selected} DESC,r.started_at DESC,r.session_id) AS place
        FROM records r JOIN profiles p ON p.id=r.owner
        LEFT JOIN record_details d ON d.owner=r.owner AND d.session_id=r.session_id
        WHERE r.started_at>=? AND r.started_at<? AND {selected} IS NOT NULL
          AND coalesce(json_extract(p.document,'$.recordsPublic'),1)=1
          AND ((? IS NULL AND ? IS NULL) OR r.spot_id=?
               OR ((r.spot_id IS NULL OR ? IS NULL) AND r.spot_name=?))
        )
        , places AS (SELECT *,row_number() OVER (ORDER BY {metric} DESC,id) AS position FROM ranked WHERE place=1)
        SELECT id,document,height,airtime,distance,kite,board,session_id,spot_name,position FROM places
        WHERE position<=50 OR id=? ORDER BY position"""
    rows = db.execute(query, (start_at, end_at, spot_id, name, spot_id, spot_id, name, viewer))
    output = []
    for owner, doc, height, airtime, distance, kite, board, session_id, spot, position in rows:
        profile = json.loads(doc)
        entry = {"id": owner, "name": profile["name"], "username": profile.get("username"),
                 "height": height, "airtime": airtime, "distance": distance}
        entry.update(avatar=profile.get("avatar"), premium=is_premium(profile), position=position)
        if position <= 3:
            entry.update(kite=kite, board=board)
            if profile.get("publicProfile", True) and profile.get("statsPublic", True):
                # Use the winning session, even when a more recent ride has different conditions.
                ride = db.execute("""SELECT json_extract(ride.value,'$.spot'),
                                            json_extract(ride.value,'$.windMS'),
                                            json_extract(ride.value,'$.windDirection')
                    FROM rider_public_rides history JOIN json_each(history.document) AS ride
                    WHERE history.owner=? AND lower(json_extract(ride.value,'$.id'))=? LIMIT 1""",
                    (owner, session_id)).fetchone()
                display_spot, speed, direction = ride or (None, None, None)
                entry.update(spot=display_spot or spot, windMS=speed, windDirection=direction)
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
    secure = env.get("wsgi.url_scheme") == "https" or env.get("HTTPS") == "on"
    if (path, method) == ("/health", "GET"):
        return send("200 OK", {"status": "ready"})
    view_path = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/view", path)
    if method == "GET" and view_path:
        try:
            post_id = identifier(view_path[1])
        except ValueError:
            return send("404 Not Found", {"error": "unknown post"})
        with closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
            db.executescript(SCHEMA)
            row = db.execute("""SELECT r.document,p.caption,length(p.photo)>0,m.video IS NOT NULL FROM posts p JOIN public_profiles r ON r.id=p.owner LEFT JOIN post_media m ON m.post=p.id WHERE p.id=?""",
                             (post_id,)).fetchone()
        if row is None:
            return send("404 Not Found", {"error": "unknown post"})
        name, caption = escape(json.loads(row[0])["name"]), escape(row[1])
        media = ('<video width="100%" src="video" poster="photo" controls playsinline></video>' if row[3]
                 else '<img width="100%" src="photo" alt="Фото публикации">' if row[2] else '')
        page = (f'<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                f'<title>{name} · Rider</title><body style="max-width:680px;margin:24px auto;padding:0 16px;'
                f'font:17px system-ui;background:#eaf9f7;color:#083d43"><h1>{name} · Rider</h1>'
                f'{media}<p style="white-space:pre-wrap">{caption}</p></body></html>').encode("utf-8")
        start_response("200 OK", [("Content-Type", "text/html; charset=utf-8"),
                                  ("Cache-Control", "no-store"), ("Content-Length", str(len(page)))])
        return [page]

    post_action = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/(details|shaka|repost)", path)
    rider_path = re.fullmatch(r"/riders/([a-z0-9_]{2,64})(?:/(followers|following))?", path)
    attachment_path = re.fullmatch(r"/messages/([0-9a-f]{64})/([a-fA-F0-9-]{36})/attachment", path)
    direct_path = re.fullmatch(r"/messages/([0-9a-f]{64})(?:/([a-fA-F0-9-]{36}))?", path)
    media_path = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/(photo|video)", path)
    comment_path = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/comments(?:/([a-fA-F0-9-]{36}))?", path)
    comment_reaction = re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/comments/([a-fA-F0-9-]{36})/like(?:/([0-9]{1,9}))?", path)
    if method in ("GET", "HEAD") and media_path:
        try:
            post_id = identifier(media_path[1])
        except ValueError:
            return send("404 Not Found", {"error": "unknown media"})
        video = media_path[2] == "video"
        column = "m.video" if video else "s.photo"
        with closing(sqlite3.connect(os.environ.get("RIDER_DB", "rider-profiles.sqlite3"), timeout=5)) as db:
            db.executescript(SCHEMA)
            row = db.execute(f"""SELECT {column} FROM posts s JOIN public_profiles p ON p.id=s.owner
                LEFT JOIN post_media m ON m.post=s.id WHERE s.id=?""", (post_id,)).fetchone()
        if not row or not row[0]:
            return send("404 Not Found", {"error": "unknown media"})
        data = row[0]
        status = "200 OK"
        headers = [("Content-Type", "video/mp4" if video else "image/jpeg"),
                   ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]
        if video:
            size = len(data)
            headers.append(("Accept-Ranges", "bytes"))
            requested = env.get("HTTP_RANGE")
            if requested:
                bounds = re.fullmatch(r"bytes=([0-9]{0,12})-([0-9]{0,12})", requested)
                if bounds and bounds[1]:
                    first, last = int(bounds[1]), min(int(bounds[2]), size-1) if bounds[2] else size-1
                elif bounds and bounds[2]:
                    first, last = max(0, size - int(bounds[2])), size-1
                else:
                    first, last = 0, -1
                if first > last:
                    start_response("416 Range Not Satisfiable", headers + [("Content-Range", f"bytes */{size}"), ("Content-Length", "0")])
                    return [b""]
                data = data[first:last+1]
                status = "206 Partial Content"
                headers.append(("Content-Range", f"bytes {first}-{last}/{size}"))
        start_response(status, headers + [("Content-Length", str(len(data)))])
        return [data if method == "GET" else b""]

    auth = re.fullmatch(r"Bearer ([a-fA-F0-9-]{72})", env.get("HTTP_AUTHORIZATION", ""))
    if not auth:
        return send("401 Unauthorized", {"error": "authentication required"})
    device = hashlib.sha256(auth[1].encode("ascii")).hexdigest()
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
        db.executescript(SCHEMA + rider_sos.SCHEMA + rider_discovery.SCHEMA + rider_discovery.ACCOUNT_SCHEMA)
        with db:
            linked = db.execute("SELECT owner FROM login_devices WHERE device=?", (device,)).fetchone()
            owner = linked[0] if linked else device
            if path == "/account" or path.startswith("/account/"):
                if not secure:
                    return send("403 Forbidden", {"error":"HTTPS required"})
                try:
                    raw = read_json(env, 2048) if method == "POST" else {}
                    if not isinstance(raw, dict):
                        raise ValueError()
                    status, result = rider_discovery.account(db, owner, device, path, method, raw, env.get("REMOTE_ADDR", ""))
                    return send(status, result)
                except (ValueError, TypeError, RecursionError):
                    return send("400 Bad Request", {"error":"invalid account request"})
            if path.startswith("/people/"):
                try:
                    raw = read_json(env, 22000) if method in ("POST", "PATCH", "PUT") else {}
                    status, result = rider_discovery.handle(db, owner, path, method, raw, env.get("REMOTE_ADDR", ""), rider_card)
                    return send(status, result)
                except (ValueError, TypeError, KeyError, RecursionError):
                    return send("400 Bad Request", {"error":"invalid discovery request"})
            if path == "/sos" or path.startswith("/sos/"):
                try:
                    status, result = rider_sos.handle(db, owner, path, method, lambda: read_json(env, 4096))
                    return send(status, result)
                except (AttributeError, KeyError, TypeError, ValueError, OverflowError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid SOS request"})
            if method == "GET" and rider_path:
                result = rider_path_result(db, owner, *rider_path.groups())
                return send("200 OK", result) if result is not None else send("404 Not Found", {"error": "unknown rider"})
            if (path, method) == ("/membership", "PUT"):
                db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                    tag = "rider_" + owner[:12]
                    suffix = 0
                    while db.execute("SELECT 1 FROM handles WHERE username=?", (tag,)).fetchone():
                        suffix += 1
                        tag = f"rider_{owner[:12]}{suffix}"
                    doc = dict(name="Райдер", username=tag, publicProfile=False, statsPublic=False, onboardingPending=True,
                               totals=dict(seconds=0, sessions=0, jumps=0))
                    db.execute("INSERT INTO profiles VALUES (?,?)", (owner, json.dumps(doc)))
                    db.execute("INSERT INTO handles VALUES (?,?)", (tag, owner))
                return send("200 OK", {"member": True})
            if (path, method) == ("/registration", "GET"):
                existing = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
                doc = json.loads(existing[0]) if existing else {}
                pending = doc.get("onboardingPending", not doc or (
                    doc.get("name") == "Райдер" and (doc.get("username") or "").startswith("rider_" + owner[:12])
                    and not doc.get("publicProfile")))
                verified = db.execute("SELECT 1 FROM login_contacts WHERE owner=?", (owner,)).fetchone() is not None
                return send("200 OK", {"required": pending, "verified": verified, "profileID": owner if doc else None,
                                       "name": doc.get("name"), "username": doc.get("username"),
                                       "bio": doc.get("bio"), "avatar": doc.get("avatar"),
                                       "birthday": doc.get("birthday"), "showBirthday": doc.get("showBirthday")})
            if (path, method) == ("/me", "GET"):
                return send("200 OK", state(db, owner, include_directory=False))
            if (path, method) == ("/me", "PATCH"):
                try:
                    raw = read_json(env, 1024)
                    if not raw or not isinstance(raw, dict) or any(
                        key not in VISIBILITY_FIELDS or type(value) is not bool
                        for key, value in raw.items()
                    ):
                        raise ValueError("invalid visibility")
                except (ValueError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid visibility"})
                db.execute("BEGIN IMMEDIATE")
                previous = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
                if not previous:
                    return send("404 Not Found", {"error": "unknown rider"})
                doc = json.loads(previous[0])
                doc.update(raw)
                db.execute("UPDATE profiles SET document=? WHERE id=?", (json.dumps(doc), owner))
            elif method == "PUT" and path in ("/me", "/registration"):
                try:
                    raw = read_json(env, 1500000)
                    doc = publication(raw)
                    if path == "/registration" and not doc.get("username"):
                        raise ValueError("username is required")
                    scores = score_rows(raw["records"]) if "records" in raw else None
                    password = rider_discovery.password_bytes(raw["password"], creating=True) if path == "/registration" and "password" in raw else None
                    if password is not None and not secure:
                        return send("403 Forbidden", {"error":"HTTPS required"})
                except (ValueError, TypeError, OverflowError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid profile"})
                db.execute("BEGIN IMMEDIATE")
                previous = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
                old = json.loads(previous[0]) if previous else {}
                if path == "/registration" and old and not old.get("onboardingPending", (
                    old.get("name") == "Райдер" and (old.get("username") or "").startswith("rider_" + owner[:12])
                    and not old.get("publicProfile"))):
                    return send("200 OK", state(db, owner, include_directory=False))
                if path == "/registration" and (password is not None or any(rider_discovery.login_methods().values())) and not db.execute(
                    "SELECT 1 FROM login_contacts WHERE owner=?", (owner,)).fetchone():
                    return send("403 Forbidden", {"error":"verify an email address or phone number first"})
                doc["onboardingPending"] = False
                for key in VISIBILITY_FIELDS:
                    use_registration_default = path == "/registration" and key != "recordsPublic"
                    value = raw.get(key, True if use_registration_default else old.get(key, True))
                    if type(value) is not bool:
                        return send("400 Bad Request", {"error": "invalid visibility"})
                    doc[key] = value
                if scores is None and previous:
                    doc["totals"] = old["totals"]
                if "birthday" not in doc and "birthday" in old:
                    doc.update(birthday=old["birthday"], showBirthday=old.get("showBirthday",False))
                if "premiumUntil" in old:
                    doc["premiumUntil"] = old["premiumUntil"]
                if "secrets" in old:
                    doc["secrets"] = old["secrets"]
                handle = doc.get("username") or old.get("username")
                if not handle and "publicProfile" in raw:
                    suffix = 0
                    while True:
                        handle = f"rider_{owner[:12]}{suffix or ''}"
                        if not db.execute("SELECT 1 FROM handles WHERE username=?", (handle,)).fetchone():
                            break
                        suffix += 1
                if handle:
                    doc["username"] = handle
                if handle and db.execute("SELECT 1 FROM handles WHERE username=? AND owner<>?", (handle, owner)).fetchone():
                    return send("409 Conflict", {"error": "username taken"})
                db.execute("INSERT INTO profiles VALUES (?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document",
                           (owner, json.dumps(doc)))
                db.execute("DELETE FROM handles WHERE owner=?", (owner,))
                if handle:
                    db.execute("INSERT INTO handles VALUES (?,?)", (handle, owner))
                if scores is not None:
                    replace_records(db, owner, scores)
                if password is not None:
                    rider_discovery.new_password(db, owner, password)
            elif (path, method) == ("/statistics", "GET"):
                row = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
                if not row:
                    return send("403 Forbidden", {"error": "publish a profile first"})
                credit = season_credit(db, owner, *season_at(time.time()))
                if not json.loads(row[0]).get("statsPublic", True):
                    credit["statsPublic"] = False
                return send("200 OK", credit)
            elif (path, method) == ("/statistics", "PUT"):
                try:
                    now = time.time()
                    year, start, end = season_at(now)
                    raw = read_json(env, 32000000)
                    update = raw["update"]
                    generated = raw["generatedAt"]
                    if not number(generated, 0, now + 300) or type(update.get("year")) is not int:
                        raise ValueError("invalid statistics")
                    if update["year"] != year:
                        return send("409 Conflict", {"error": "season changed"})
                    points = activity_points(update["rides"], start, end, now)
                    scores = score_rows(update["records"])
                    public_rides = public_ride_rows(update["publicRides"]) if "publicRides" in update else None
                    secrets = update.get("secrets")
                    if secrets is not None and (not isinstance(secrets, list) or len(secrets) > len(MISSION_RULES)
                                                or any(not isinstance(key, str) or key not in MISSION_RULES for key in secrets)):
                        raise ValueError("invalid achievements")
                    totals = update["totals"]
                    validated = publication({"name": "Rider", "totals": totals})["totals"]
                except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid statistics"})
                db.execute("BEGIN IMMEDIATE")
                profile = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
                if not profile:
                    return send("403 Forbidden", {"error": "publish a profile first"})
                doc = json.loads(profile[0])
                saved = db.execute("""INSERT INTO season_scores VALUES (?,?,?,?)
                    ON CONFLICT(owner,year) DO UPDATE SET
                      activity_points=excluded.activity_points, generated_at=excluded.generated_at
                    WHERE excluded.generated_at>=season_scores.generated_at""", (owner, year, points, generated))
                if saved.rowcount:
                    doc["totals"] = validated
                    if secrets is not None:
                        doc["secrets"] = list(dict.fromkeys(secrets))
                    db.execute("UPDATE profiles SET document=? WHERE id=?", (json.dumps(doc), owner))
                    replace_records(db, owner, scores)
                    if public_rides is not None:
                        db.execute("""INSERT INTO rider_public_rides VALUES (?,?)
                            ON CONFLICT(owner) DO UPDATE SET document=excluded.document""",
                            (owner, json.dumps(public_rides)))
                return send("200 OK", season_credit(db, owner, year, start, end))
            elif (path, method) == ("/me", "DELETE"):
                db.execute("DELETE FROM follows WHERE owner=?", (owner,))
                db.execute("DELETE FROM login_security WHERE owner=?", (owner,))
                db.execute("DELETE FROM login_mfa_pending WHERE owner=? OR device=?", (owner,device))
                db.execute("DELETE FROM login_resets WHERE owner=? OR device=?", (owner,device))
                db.execute("DELETE FROM login_contacts WHERE owner=?", (owner,))
                db.execute("DELETE FROM login_challenges WHERE device=? OR device IN (SELECT device FROM login_devices WHERE owner=?)", (device,owner))
                db.execute("DELETE FROM login_devices WHERE owner=?", (owner,))
                db.execute("DELETE FROM profiles WHERE id=?", (owner,))
            elif path.startswith("/follow/") and method in ("PUT", "DELETE"):
                target = path.removeprefix("/follow/")
                db.execute("BEGIN IMMEDIATE")
                if target == owner or not db.execute(
                    "SELECT 1 FROM public_profiles WHERE id=?" if method == "PUT" else "SELECT 1 FROM profiles WHERE id=?",
                    (target,)
                ).fetchone():
                    return send("404 Not Found", {"error": "unknown rider"})
                if method == "PUT":
                    if not db.execute("""SELECT 1 FROM profiles WHERE id=?
                            AND coalesce(json_extract(document,'$.onboardingPending'),0)=0""", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "complete registration first"})
                    changed = db.execute("INSERT OR IGNORE INTO follows VALUES (?,?)", (owner, target))
                    if changed.rowcount and db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                        db.execute("INSERT INTO follow_activity VALUES (?,?,?)", (owner, target, time.time()))
                else:
                    db.execute("DELETE FROM follows WHERE owner=? AND target=?", (owner, target))
                return send("200 OK", {"following": method == "PUT"})
            elif method == "GET" and path in ("/feed/following", "/feed/recommended", "/feed/my-reposts"):
                return send("200 OK", feed(db, owner, path.split("/")[-1]))
            elif (path, method) == ("/unread", "GET"):
                return send("200 OK", unread_summary(db, owner))
            elif (path, method) == ("/activity", "DELETE"):
                if db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                    db.execute("""INSERT INTO activity_cleared VALUES(?,?)
                        ON CONFLICT(owner) DO UPDATE SET through=max(through,excluded.through)""", (owner,time.time()))
                    db.execute("DELETE FROM activity_hidden WHERE owner=?", (owner,))
                    db.execute("""INSERT INTO activity_reads SELECT ?, coalesce(max(sequence),0)
                        FROM rider_alert_events WHERE owner=? AND kind<>'message'
                        ON CONFLICT(owner) DO UPDATE SET sequence=max(activity_reads.sequence,excluded.sequence)""", (owner,owner))
                return send("200 OK", unread_summary(db, owner))
            elif (path, method) == ("/activity/hide", "PUT"):
                try:
                    key = read_json(env, 1024)["id"]
                    if not isinstance(key,str) or not 1<=len(key)<=220:
                        raise ValueError()
                except (ValueError, KeyError, TypeError):
                    return send("400 Bad Request", {"error":"invalid notification"})
                if any(item["id"] == key for item in activity(db, owner)):
                    db.execute("INSERT OR IGNORE INTO activity_hidden VALUES (?,?)", (owner,key))
                return send("200 OK", unread_summary(db, owner))
            elif (path, method) == ("/activity/read", "GET"):
                sequence = db.execute("SELECT coalesce(max(sequence),0) FROM rider_alert_events WHERE owner=? AND kind<>'message'",
                                      (owner,)).fetchone()[0]
                return send("200 OK", {"items": activity(db, owner), "sequence": sequence})
            elif (path, method) == ("/activity/read", "PUT"):
                try:
                    cursor = read_json(env, 256)["sequence"]
                    if type(cursor) is not int or not 0 <= cursor <= 2**63-1:
                        raise ValueError()
                except (ValueError, KeyError, TypeError):
                    return send("400 Bad Request", {"error": "invalid receipt"})
                known = db.execute("SELECT coalesce(max(sequence),0) FROM rider_alert_events WHERE owner=? AND kind<>'message'",
                                   (owner,)).fetchone()[0]
                if known > 0 and db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                    db.execute("""INSERT INTO activity_reads VALUES(?,?)
                        ON CONFLICT(owner) DO UPDATE SET sequence=max(sequence,excluded.sequence)""", (owner,min(known,cursor)))
                return send("200 OK", unread_summary(db, owner))
            elif method == "PUT" and (read_path := re.fullmatch(r"/messages/([0-9a-f]{64})/read", path)):
                try:
                    ids = read_json(env, 5500)["messages"]
                    if not isinstance(ids, list) or len(ids)>100:
                        raise ValueError()
                    keys = json.dumps([identifier(k) for k in ids])
                except (ValueError, KeyError, TypeError):
                    return send("400 Bad Request", {"error": "invalid receipt"})
                db.execute("""INSERT INTO message_receipts (message,read) SELECT id,1 FROM direct_messages
                    WHERE sender=? AND recipient=? AND id IN (SELECT value FROM json_each(?))
                    ON CONFLICT(message) DO UPDATE SET read=1""", (read_path[1],owner,keys))
                return send("200 OK", unread_summary(db, owner))
            elif (path, method) == ("/stories", "GET"):
                return send("200 OK", visible_stories(db, owner))
            elif (story_path := re.fullmatch(r"/stories/([a-fA-F0-9-]{36})(?:/(media|seen|like|viewers/([0-9]{1,9})))?", path)):
                try:
                    key = identifier(story_path[1])
                except ValueError:
                    return send("404 Not Found", {"error": "unknown story"})
                action = story_path[2]
                if method == "PUT" and action is None:
                    try:
                        caption, _, photo, _, _, video = post_fields(read_json(env, 17_400_000), key)
                        if not photo:
                            raise ValueError("no story media")
                    except (ValueError, TypeError, RecursionError):
                        return send("400 Bad Request", {"error": "invalid story"})
                    db.execute("BEGIN IMMEDIATE")
                    if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "publish a profile first"})
                    db.execute("DELETE FROM stories WHERE created<=?", (time.time()-86400,))
                    previous = db.execute("SELECT owner FROM stories WHERE id=?", (key,)).fetchone()
                    if previous:
                        if previous[0] != owner:
                            return send("409 Conflict", {"error": "story ID is taken"})
                    else:
                        if db.execute("SELECT count(*) FROM stories WHERE owner=?", (owner,)).fetchone()[0] >= 20:
                            return send("429 Too Many Requests", {"error": "daily story limit"})
                        db.execute("INSERT INTO stories VALUES(?,?,?,?,?,?)", (key,owner,time.time(),caption,photo,video))
                    return send("200 OK", visible_stories(db, owner))
                if method == "DELETE" and action is None:
                    db.execute("DELETE FROM stories WHERE id=? AND owner=?", (key,owner))
                    return send("200 OK", visible_stories(db, owner))
                if method == "PUT" and action == "seen":
                    db.execute("""INSERT OR IGNORE INTO story_views SELECT s.id,p.id FROM stories s
                        JOIN public_profiles author ON author.id=s.owner JOIN profiles p ON p.id=?
                        WHERE s.id=? AND s.created>? AND s.owner<>?""", (owner,key,time.time()-86400,owner))
                    return send("200 OK", {"seen":True})
                if (action == "like" and method in ("PUT", "DELETE")) or (story_path[3] and method == "GET"):
                    if action == "like":
                        db.execute("BEGIN IMMEDIATE")
                    story = db.execute("""SELECT s.owner FROM stories s JOIN public_profiles p ON p.id=s.owner
                        WHERE s.id=? AND s.created>?""", (key, time.time()-86400)).fetchone()
                    if story is None:
                        return send("404 Not Found", {"error": "unknown story"})
                    if story_path[3]:
                        if story[0] != owner:
                            return send("404 Not Found", {"error": "unknown story"})
                        return send("200 OK", story_viewers(db, key, int(story_path[3])))
                    if story[0] == owner or not db.execute("SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "invalid story viewer"})
                    if method == "PUT":
                        db.execute("INSERT OR IGNORE INTO story_views VALUES(?,?)", (key,owner))
                        db.execute("INSERT OR IGNORE INTO story_likes VALUES(?,?)", (key,owner))
                    else:
                        db.execute("DELETE FROM story_likes WHERE story=? AND viewer=?", (key,owner))
                    return send("200 OK", {"liked":method=="PUT"})
                if method == "GET" and action == "media":
                    asset = db.execute("""SELECT s.photo,s.video FROM stories s JOIN public_profiles p ON p.id=s.owner
                        WHERE s.id=? AND s.created>?""", (key,time.time()-86400)).fetchone()
                    if asset:
                        photo, video = asset
                        data, mime = (video, "video/mp4") if video else (photo, "image/jpeg")
                        start_response("200 OK", [("Content-Type",mime),("Content-Length", str(len(data))),
                                                   ("Cache-Control","no-store"),("X-Content-Type-Options","nosniff")])
                        return [data]
                return send("404 Not Found", {"error": "unknown story"})
            elif (path, method) == ("/activity", "GET"):
                return send("200 OK", activity(db, owner))
            elif (path, method) == ("/messages", "GET"):
                return send("200 OK", inbox(db, owner))
            elif method == "GET" and attachment_path:
                peer, message_id = attachment_path.groups()
                try:
                    message_id = identifier(message_id)
                except ValueError:
                    return send("404 Not Found", {"error": "unknown attachment"})
                row = db.execute("""SELECT a.data FROM message_attachments a JOIN direct_messages m ON m.id=a.message
                    WHERE m.id=? AND ((m.sender=? AND m.recipient=?) OR (m.sender=? AND m.recipient=?))""",
                    (message_id, owner, peer, peer, owner)).fetchone()
                if row is None:
                    return send("404 Not Found", {"error": "unknown attachment"})
                blob, = row
                start_response("200 OK", [("Content-Type", "application/octet-stream"),
                    ("Content-Length", str(len(blob))), ("Cache-Control", "no-store"),
                    ("Content-Disposition", "attachment"), ("X-Content-Type-Options", "nosniff")])
                return [blob]
            elif direct_path:
                peer, message_id = direct_path.groups()
                if (method, bool(message_id)) not in (("GET", False), ("PUT", True)):
                    return send("405 Method Not Allowed", {"error": "invalid messages method"})
                if method == "PUT":
                    try:
                        message_id = identifier(message_id)
                        raw = read_json(env, MAX_MESSAGE_JSON)
                        if not isinstance(raw, dict) or not isinstance(raw.get("text"), str):
                            raise ValueError("invalid message")
                        body = raw["text"].strip()
                        shared = identifier(raw["postID"]) if raw.get("postID") is not None else None
                        attachment = message_attachment(raw["attachment"]) if raw.get("attachment") is not None else None
                        if len(body) > 1000 or not (body or shared or attachment):
                            raise ValueError("invalid message length")
                    except (ValueError, TypeError, RecursionError):
                        return send("400 Bad Request", {"error": "invalid message"})
                    db.execute("BEGIN IMMEDIATE")
                    if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "publish a profile first"})
                    if peer == owner or not db.execute("SELECT 1 FROM profiles WHERE id=?", (peer,)).fetchone():
                        return send("404 Not Found", {"error": "unknown recipient"})
                    if shared and not feed(db, owner, "single", shared):
                        return send("404 Not Found", {"error": "unknown post"})
                    changed = db.execute("INSERT INTO direct_messages VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
                                         (message_id, owner, peer, time.time(), body, shared))
                    if changed.rowcount:
                        if attachment is not None:
                            db.execute("INSERT INTO message_attachments VALUES (?,?,?,?)", (message_id, *attachment))
                    else:
                        same_message = db.execute("""SELECT 1 FROM direct_messages
                            WHERE id=? AND sender=? AND recipient=? AND body=? AND post IS ?""",
                            (message_id, owner, peer, body, shared)).fetchone()
                        previous = db.execute("SELECT filename,content_type,data FROM message_attachments WHERE message=?",
                                              (message_id,)).fetchone()
                        if not same_message or previous != attachment:
                            return send("409 Conflict", {"error": "message ID is taken"})
                deliver_inbox(db, owner)
                return send("200 OK", thread(db, owner, peer))
            elif post_action:
                try:
                    post_id = identifier(post_action[1])
                    action = post_action[2]
                    if (action, method) not in (("details", "GET"), ("shaka", "PUT"), ("shaka", "DELETE"),
                                                 ("repost", "PUT"), ("repost", "DELETE")):
                        return send("405 Method Not Allowed", {"error": "invalid post action"})
                    repost_id = identifier(read_json(env, 512)["id"]) if (action, method) == ("repost", "PUT") else None
                except (ValueError, TypeError, RecursionError, KeyError):
                    return send("400 Bad Request", {"error": "invalid post action"})
                if action == "details":
                    result = feed(db, owner, "single", post_id)
                    return send("200 OK", result[0]) if result else send("404 Not Found", {"error": "unknown post"})
                db.execute("BEGIN IMMEDIATE")
                post = db.execute("SELECT s.owner FROM posts s JOIN public_profiles p ON p.id=s.owner WHERE s.id=?", (post_id,)).fetchone()
                if not post:
                    return send("404 Not Found", {"error": "unknown post"})
                if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                    return send("403 Forbidden", {"error": "publish a profile first"})
                if action == "shaka":
                    if method == "PUT":
                        db.execute("INSERT OR IGNORE INTO shakas VALUES (?,?,?)", (post_id, owner, time.time()))
                    else:
                        db.execute("DELETE FROM shakas WHERE post=? AND owner=?", (post_id, owner))
                    return send("200 OK", reactions(db, post_id, owner))
                if method == "DELETE":
                    db.execute("DELETE FROM reposts WHERE post=? AND owner=?", (post_id, owner))
                elif post[0] == owner:
                    return send("400 Bad Request", {"error": "cannot repost own publication"})
                else:
                    if db.execute("SELECT 1 FROM posts WHERE id=?", (repost_id,)).fetchone():
                        return send("409 Conflict", {"error": "post ID is taken"})
                    try:
                        db.execute("""INSERT INTO reposts VALUES (?,?,?,?)
                            ON CONFLICT(owner,post) DO NOTHING""", (repost_id, post_id, owner, time.time()))
                    except sqlite3.IntegrityError:
                        return send("409 Conflict", {"error": "repost ID is taken"})
                return send("200 OK", {"reposted": method == "PUT"})
            elif (path, method) == ("/tops", "POST"):
                try:
                    filters = read_json(env, 4096)
                    personal = isinstance(filters, dict) and filters.get("withMyPlace") is True
                    rows = top_rows(db, filters, owner if personal else None)
                    if personal:
                        rows = {"leaders": [r for r in rows if r["position"] <= 50],
                                "myPlace": next((r["position"] for r in rows if r["id"] == owner), None)}
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
                        parent = identifier(raw["replyTo"]) if raw.get("replyTo") else None
                        if not 1 <= len(body) <= 2000:
                            raise ValueError("invalid comment length")
                except (ValueError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid comment"})
                if method != "GET":
                    db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM posts s JOIN public_profiles p ON p.id=s.owner WHERE s.id=?", (post_id,)).fetchone():
                    return send("404 Not Found", {"error": "unknown post"})
                if method == "PUT":
                    if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                        return send("403 Forbidden", {"error": "publish a profile first"})
                    if parent and (parent == comment_id or not db.execute("""SELECT 1 FROM post_comments c
                            JOIN public_profiles p ON p.id=c.author WHERE c.id=? AND c.post=?""", (parent, post_id)).fetchone()):
                        return send("404 Not Found", {"error": "unknown parent comment"})
                    previous = db.execute("""SELECT x.parent FROM post_comments c LEFT JOIN comment_replies x
                        ON x.comment=c.id WHERE c.id=?""", (comment_id,)).fetchone()
                    if previous and previous[0] != parent:
                        return send("409 Conflict", {"error": "reply target changed"})
                    changed = db.execute("""INSERT INTO post_comments VALUES (?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET body=excluded.body
                        WHERE post_comments.author=excluded.author AND post_comments.post=excluded.post""",
                        (comment_id, post_id, owner, time.time(), body))
                    if not changed.rowcount:
                        return send("409 Conflict", {"error": "comment ID is taken"})
                    if parent:
                        db.execute("INSERT OR IGNORE INTO comment_replies VALUES (?,?)", (comment_id, parent))
                elif method == "DELETE":
                    db.execute("DELETE FROM post_comments WHERE id=? AND post=? AND author=?",
                               (comment_id, post_id, owner))
                return send("200 OK", comments(db, post_id, owner))
            elif method == "GET" and (reactors := re.fullmatch(r"/posts/([a-fA-F0-9-]{36})/shakas/([0-9]{1,9})", path)):
                source = identifier(reactors[1])
                if not db.execute("SELECT 1 FROM posts p JOIN public_profiles r ON r.id=p.owner WHERE p.id=?", (source,)).fetchone():
                    return send("404 Not Found", {"error": "unknown post"})
                return send("200 OK", reactions(db, source, owner, 50, int(reactors[2])))
            elif comment_reaction and ((method == "GET" and comment_reaction[3] is not None) or
                                       (method in ("PUT", "DELETE") and comment_reaction[3] is None)):
                post, comment = identifier(comment_reaction[1]), identifier(comment_reaction[2])
                if method != "GET":
                    db.execute("BEGIN IMMEDIATE")
                visible = db.execute("""SELECT 1 FROM post_comments c JOIN public_profiles author ON author.id=c.author
                    JOIN posts s ON s.id=c.post JOIN public_profiles p ON p.id=s.owner
                    WHERE c.id=? AND c.post=?""", (comment, post)).fetchone()
                if not visible:
                    return send("404 Not Found", {"error": "unknown comment"})
                if method == "GET":
                    return send("200 OK", comment_reactors(db, comment, owner, int(comment_reaction[3])))
                if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                    return send("403 Forbidden", {"error": "publish a profile first"})
                if method == "PUT":
                    db.execute("INSERT OR IGNORE INTO comment_likes VALUES (?,?)", (comment, owner))
                else:
                    db.execute("DELETE FROM comment_likes WHERE comment=? AND owner=?", (comment, owner))
                return send("200 OK", comments(db, post, owner))
            elif path.startswith("/posts/") and method in ("PUT", "DELETE"):
                try:
                    post_id = identifier(path.removeprefix("/posts/"))
                    fields = post_fields(read_json(env, 17_400_000), post_id) if method == "PUT" else None
                except (ValueError, TypeError, RecursionError):
                    return send("400 Bad Request", {"error": "invalid post"})
                if fields is None:
                    db.execute("DELETE FROM posts WHERE id=? AND owner=?", (post_id, owner))
                    return send("200 OK", {"deleted": True})
                db.execute("BEGIN IMMEDIATE")
                if not db.execute("SELECT 1 FROM public_profiles WHERE id=?", (owner,)).fetchone():
                    return send("403 Forbidden", {"error": "publish a profile first"})
                if db.execute("SELECT 1 FROM reposts WHERE id=?", (post_id,)).fetchone():
                    return send("409 Conflict", {"error": "post ID is taken"})
                caption, location, image, equipment, section, video = fields
                affected = db.execute("""INSERT INTO posts VALUES (?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET caption=excluded.caption,location=excluded.location,photo=excluded.photo
                    WHERE posts.owner=excluded.owner""", (post_id, owner, time.time(), caption, location, image))
                if not affected.rowcount:
                    return send("409 Conflict", {"error": "post ID is taken"})
                if equipment is None:
                    db.execute("DELETE FROM post_equipment WHERE post=?", (post_id,))
                else:
                    db.execute("""INSERT INTO post_equipment VALUES (?,?)
                        ON CONFLICT(post) DO UPDATE SET document=excluded.document""", (post_id, equipment))
                db.execute("""INSERT INTO post_media VALUES (?,?,?) ON CONFLICT(post)
                              DO UPDATE SET section=excluded.section,video=excluded.video""", (post_id, section, video))
                return send("200 OK", {"published": True})
            elif (path, method) != ("/riders", "GET"):
                return send("404 Not Found", {"error": "unknown endpoint"})
        return send("200 OK", state(db, owner, include_directory=path == "/riders"))
