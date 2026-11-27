"""Rider directory, public spot recommendations and opt-in verified contact matching."""
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import smtplib
import ssl
from email.message import EmailMessage
import time
import uuid
from urllib.parse import urlencode
from urllib.request import Request, urlopen

SCHEMA = """
CREATE TABLE IF NOT EXISTS contact_phones(
 owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
 digest TEXT UNIQUE NOT NULL, discoverable INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS contact_challenges(
 owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
 digest TEXT NOT NULL, proof TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS discovery_budget(bucket TEXT PRIMARY KEY, until_at INTEGER NOT NULL, used INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS discovery_key(id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL);
"""
ALERT_KINDS = ("message","sos","comment","reply","follow","reaction","repost","sound","vibrate","preview")
SCHEMA += """
CREATE TABLE IF NOT EXISTS rider_alert_settings(
 owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE, prefs TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS rider_alert_events(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
 event_key TEXT NOT NULL, kind TEXT NOT NULL, actor TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
 post TEXT REFERENCES posts(id) ON DELETE CASCADE, created REAL NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending', next_try REAL NOT NULL DEFAULT 0, UNIQUE(owner,event_key));
CREATE INDEX IF NOT EXISTS rider_alert_recent ON rider_alert_events(owner,sequence DESC);
CREATE INDEX IF NOT EXISTS rider_alert_pending ON rider_alert_events(status,next_try,created);
"""
def event_trigger(table, kind, query, delete_filter):
    return f"""
    CREATE TRIGGER IF NOT EXISTS alert_add_{table} AFTER INSERT ON {table} BEGIN
        INSERT OR IGNORE INTO rider_alert_events(owner,event_key,kind,actor,post,created)
        SELECT recipient, '{kind}:'||source, '{kind}', actor, post, created FROM ({query})
        WHERE recipient<>actor; END;
    CREATE TRIGGER IF NOT EXISTS alert_remove_{table} AFTER DELETE ON {table} BEGIN
        DELETE FROM rider_alert_events WHERE {delete_filter}; END;"""

SCHEMA += event_trigger("direct_messages","message",
    "SELECT NEW.recipient recipient, NEW.id source, NEW.sender actor, NULL post, NEW.created_at created",
    "event_key='message:'||OLD.id")
SCHEMA += event_trigger("follow_activity","follow",
    "SELECT NEW.target recipient, NEW.owner source, NEW.owner actor, NULL post, NEW.created_at created",
    "owner=OLD.target AND event_key='follow:'||OLD.owner")
SCHEMA += event_trigger("shakas","reaction",
    "SELECT owner recipient, NEW.post||NEW.owner source, NEW.owner actor, NEW.post post, NEW.created_at created FROM posts WHERE id=NEW.post",
    "event_key='reaction:'||OLD.post||OLD.owner")
SCHEMA += event_trigger("reposts","repost",
    "SELECT owner recipient, NEW.id source, NEW.owner actor, NEW.post post, NEW.created_at created FROM posts WHERE id=NEW.post",
    "event_key='repost:'||OLD.id")
SCHEMA += event_trigger("post_comments","comment",
    "SELECT owner recipient, NEW.id source, NEW.author actor, NEW.post post, NEW.created_at created FROM posts WHERE id=NEW.post",
    "event_key='comment:'||OLD.id")
SCHEMA += """
CREATE TRIGGER IF NOT EXISTS alert_add_reply AFTER INSERT ON comment_replies BEGIN
    INSERT INTO rider_alert_events(owner,event_key,kind,actor,post,created)
    SELECT p.author,'comment:'||c.id,'reply',c.author,c.post,c.created_at FROM post_comments p,post_comments c
    WHERE p.id=NEW.parent AND c.id=NEW.comment AND p.author<>c.author
    ON CONFLICT(owner,event_key) DO UPDATE SET kind='reply';
END;
"""
VISIBLE = """(e.kind='message' OR (EXISTS(SELECT 1 FROM public_profiles WHERE id=e.actor) AND
    (e.post IS NULL OR EXISTS(SELECT 1 FROM posts t JOIN public_profiles p ON p.id=t.owner WHERE t.id=e.post))))"""

def push_batch(db,send):
    now=time.time()
    with db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM rider_alert_events WHERE created<?",(now-86400*7,))
        jobs=db.execute(f"""SELECT e.sequence,d.token,e.kind,json_extract(p.document,'$.name'),s.prefs
            FROM rider_alert_events e JOIN sos_devices d ON d.owner=e.owner AND d.refreshed>=?
            JOIN profiles p ON p.id=e.actor LEFT JOIN rider_alert_settings s ON s.owner=e.owner
            WHERE e.status='pending' AND e.created>=? AND e.next_try<=? AND {VISIBLE}
            ORDER BY e.sequence LIMIT 12""",(now-90*86400,now-3600,now)).fetchall()
        db.executemany("UPDATE rider_alert_events SET next_try=? WHERE sequence=?",[(now+90,j[0]) for j in jobs])
    for seq,token,kind,name,raw in jobs:
        prefs=json.loads(raw or "{}")
        status=send(token,seq,kind,name,prefs) if prefs.get(kind,True) else "muted"
        with db:
            db.execute("UPDATE rider_alert_events SET status=? WHERE sequence=? AND next_try=?",(status,seq,now+90))

SCHEMA += """
CREATE TABLE IF NOT EXISTS demo_sequence(
 owner TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE, started REAL NOT NULL, step INTEGER NOT NULL);
"""

def demo_ids(variable):
    return [value.strip() for value in os.environ.get(variable, "").split(",")
            if re.fullmatch(r"[a-f0-9]{64}", value.strip())]


def demo_member(db, owner):
    return owner in demo_ids("RIDER_DEMO_RECIPIENT_IDS") and db.execute(
        "SELECT 1 FROM profiles WHERE id=?", (owner,)).fetchone() is not None


def demo_tick(db, owner, restart=False):
    # Explicit configuration exists only on the home test server.
    senders = demo_ids("RIDER_DEMO_SENDER_IDS")
    if not demo_member(db, owner) or len(senders)<2: return {"enabled":False}
    db.execute("BEGIN IMMEDIATE")
    now=time.time()
    db.execute("INSERT OR IGNORE INTO demo_sequence VALUES(?,?,0)",(owner,now))
    if restart:
        db.execute("UPDATE demo_sequence SET started=?,step=0 WHERE owner=?",(now,owner))
    started,step=db.execute("SELECT started,step FROM demo_sequence WHERE owner=?",(owner,)).fetchone()
    result={"enabled":True,"drill":False}
    if step>=3 or now-started < (20,45,70)[step]: return result
    if step==2: result["drill"]=True
    else:
        sender=db.execute("SELECT id FROM public_profiles WHERE id=?", (senders[step],)).fetchone()
        if not sender: return result
        options=(("Привет! Ты сегодня выходишь на воду?","Как прошла последняя каталка?"),
                 ("Шака! Какой кайт берёшь на следующий выезд?","Привет! Уже выбрал спот на выходные?"))
        db.execute("INSERT INTO direct_messages VALUES(?,?,?,?,?,NULL)",
                   (str(uuid.uuid4()),sender[0],owner,now,"Демо · "+secrets.choice(options[step])))
    db.execute("UPDATE demo_sequence SET step=step+1 WHERE owner=?",(owner,))
    return result


def folded(value):
    return " ".join(value.casefold().replace("ё", "е").split())

def directory(db, owner, raw, card):
    query = raw.get("query", "")
    if not isinstance(query, str) or len(query) > 100:
        raise ValueError()
    q = folded(query.strip().lstrip("@"))
    mentions = raw.get("mentions") is True
    if mentions and not q:
        return {"people": [], "nearby": [], "following": [], "followers": []}
    if q:
        db.create_function("fold", 1, lambda s: folded(s or ""), deterministic=True)
        matches = """WITH candidates AS (
          SELECT id,fold(json_extract(document,'$.name')) AS n,fold(json_extract(document,'$.username')) AS u
          FROM public_profiles WHERE id<>:owner
        ), matches AS (
          SELECT id,u,CASE WHEN u=:q THEN 0 WHEN n=:q THEN 1 WHEN instr(u,:q)=1 THEN 2
                           WHEN instr(n,:q)=1 THEN 3 ELSE 4 END AS relevance
          FROM candidates WHERE instr(u,:q) OR instr(n,:q)
        )"""
        params = {"owner": owner, "q": q}
        if not mentions:
            rows = db.execute(matches + """
                SELECT p.id,p.document FROM matches m JOIN profiles p ON p.id=m.id
                ORDER BY m.relevance,m.u,m.id LIMIT 40""", params)
            return {"people": [card(*row) for row in rows], "nearby": []}

        groups = {"people": [], "nearby": [], "following": [], "followers": []}
        rows = db.execute(matches + """, relations AS (
            SELECT m.*, CASE WHEN EXISTS(SELECT 1 FROM follows WHERE owner=:owner AND target=m.id) THEN 'following'
                             WHEN EXISTS(SELECT 1 FROM follows WHERE owner=m.id AND target=:owner) THEN 'followers'
                             ELSE 'people' END AS relation
            FROM matches m WHERE m.u <> ''
        ), ranked AS (
            SELECT id,relation,row_number() OVER (PARTITION BY relation ORDER BY relevance,u,id) AS position
            FROM relations
        )
        SELECT p.id,p.document,r.relation FROM ranked r JOIN profiles p ON p.id=r.id
        WHERE r.position <= 5 ORDER BY r.relation,r.position""", params)
        for person_id, document, relation in rows:
            groups[relation].append(card(person_id, document))
        return groups
    # Overlap between accounts the viewer follows and their subscriptions.
    rows = db.execute("""SELECT p.id,p.document FROM public_profiles p WHERE p.id<>?
        AND NOT EXISTS(SELECT 1 FROM follows WHERE owner=? AND target=p.id)
        ORDER BY (SELECT count(*) FROM follows f JOIN follows mine ON mine.target=f.owner
                  WHERE mine.owner=? AND f.target=p.id) DESC,
                 (SELECT max(created_at) FROM posts WHERE owner=p.id) DESC,p.id LIMIT 12""",(owner,owner,owner))
    result = {"people":[card(*row) for row in rows], "nearby":[]}
    if "lat" not in raw and "lon" not in raw:
        return result
    lat, lon = raw.get("lat"), raw.get("lon")
    if any(type(n) not in (float,int) or not math.isfinite(n) or abs(n)>limit for n,limit in [(lat,90),(lon,180)]):
        raise ValueError()
    def km(a,b):
        if a is None or b is None:
            return None
        f=math.pi/180
        h=math.sin((a-lat)*f/2)**2+math.cos(a*f)*math.cos(lat*f)*math.sin((b-lon)*f/2)**2
        return 12742*math.asin(math.sqrt(min(1,max(0,h))))
    db.create_function("spot_km",2,km)
    nearby = db.execute("""WITH local AS (
         SELECT s.owner,min(spot_km(json_extract(s.location,'$.latitude'),json_extract(s.location,'$.longitude'))) AS km
         FROM posts s JOIN public_profiles p ON p.id=s.owner WHERE s.owner<>? AND s.location IS NOT NULL
         AND s.created_at>=? GROUP BY s.owner HAVING km<=60)
         SELECT p.id,p.document FROM local JOIN public_profiles p ON p.id=local.owner
         ORDER BY local.km,p.id LIMIT 16""",(owner,time.time()-90*86400))
    result["nearby"] = [card(*r) for r in nearby]
    return result

def normalized(raw):
    if not isinstance(raw,str) or not re.fullmatch(r"[+0-9() .-]{7,40}",raw):
        raise ValueError()
    digits=re.sub(r"[^0-9]","",raw)
    if not raw.startswith("+"):
        if len(digits)==11 and digits[0] in "78": digits="7"+digits[1:]
        elif len(digits)==10: digits="7"+digits
        else: raise ValueError()
    if not re.fullmatch(r"[1-9][0-9]{7,14}",digits): raise ValueError()
    return "+"+digits

def secret_key(db):
    db.execute("INSERT OR IGNORE INTO discovery_key VALUES (1,?)",(secrets.token_bytes(32),))
    return db.execute("SELECT value FROM discovery_key WHERE id=1").fetchone()[0]

def sealed(key, label):
    return hmac.new(key,label.encode(),hashlib.sha256).hexdigest()

def digest_phone(key, phone):
    return sealed(key, "phone:"+hashlib.sha256(phone.encode()).hexdigest())

def spend(db, limits, now):
    db.execute("DELETE FROM discovery_budget WHERE until_at<=?",(now,))
    for bucket, maximum, cost, window in limits:
        row=db.execute("SELECT used FROM discovery_budget WHERE bucket=?",(bucket,)).fetchone()
        if (row[0] if row else 0)+cost>maximum: return False
    for bucket, maximum, cost, window in limits:
        db.execute("""INSERT INTO discovery_budget VALUES(?,?,?) ON CONFLICT(bucket)
                      DO UPDATE SET used=used+excluded.used""",(bucket,now+window,cost))
    return True

def deliver(phone, otp):
    form=urlencode(dict(api_id=os.environ["RIDER_SMS_RU_API_ID"],to=phone[1:],
                        msg="Rider: "+otp,json=1,ttl=5)).encode()
    with urlopen(Request("https://sms.ru/sms/send",data=form),timeout=6) as reply:
        data=json.load(reply)
    if data.get("sms",{}).get(phone[1:],{}).get("status")!="OK": raise OSError("SMS not accepted")

ACCOUNT_SCHEMA = """
CREATE TABLE IF NOT EXISTS login_contacts(
 owner TEXT NOT NULL, kind TEXT NOT NULL, digest TEXT NOT NULL,
 PRIMARY KEY(owner,kind), UNIQUE(kind,digest));
CREATE TABLE IF NOT EXISTS login_challenges(
 device TEXT PRIMARY KEY, kind TEXT NOT NULL, digest TEXT NOT NULL, proof TEXT NOT NULL,
 expires INTEGER NOT NULL, attempts INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS login_devices(
 device TEXT PRIMARY KEY, owner TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS login_devices_owner ON login_devices(owner);
CREATE TABLE IF NOT EXISTS login_security(
 owner TEXT PRIMARY KEY, salt BLOB NOT NULL, verifier BLOB NOT NULL,
 password_enabled INTEGER NOT NULL DEFAULT 1, email_enabled INTEGER NOT NULL DEFAULT 1,
 sms_enabled INTEGER NOT NULL DEFAULT 1, mfa INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS login_mfa_pending(
 device TEXT PRIMARY KEY, owner TEXT NOT NULL, verifier BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS login_resets(
 device TEXT PRIMARY KEY, owner TEXT NOT NULL, expires INTEGER NOT NULL);

"""


def login_methods():
    smtp_configured = bool(os.environ.get("RIDER_SMTP_HOST") and os.environ.get("RIDER_SMTP_FROM"))
    smtp_auth_ready = not os.environ.get("RIDER_SMTP_USER") or bool(os.environ.get("RIDER_SMTP_PASSWORD"))
    return {"phone": bool(os.environ.get("RIDER_SMS_RU_API_ID")),
            "email": smtp_configured and smtp_auth_ready}


def deliver_email(address, code):
    message = EmailMessage()
    message["From"] = os.environ["RIDER_SMTP_FROM"]
    message["To"] = address
    message["Subject"] = "Код входа в Rider"
    message.set_content(f"Код входа в Rider: {code}. Он действует 5 минут. Если ты его не запрашивал, проигнорируй письмо.")
    with smtplib.SMTP_SSL(os.environ["RIDER_SMTP_HOST"], int(os.environ.get("RIDER_SMTP_PORT", "465")),
                         timeout=8, context=ssl.create_default_context()) as server:
        if username := os.environ.get("RIDER_SMTP_USER"):
            server.login(username, os.environ["RIDER_SMTP_PASSWORD"])
        server.send_message(message)


def login_address(kind, raw):
    if kind == "phone":
        return normalized(raw)
    if kind == "email" and isinstance(raw, str):
        address = raw.strip().lower()
        if len(address) <= 254 and re.fullmatch(r"[a-z0-9.!#$%&'*+/=?^_{|}~-]+@[a-z0-9-]+(?:[.][a-z0-9-]+)+", address):
            return address
    raise ValueError()


def contact_digest(key, kind, address):
    return digest_phone(key, address) if kind == "phone" else sealed(key, "email:" + address)


def password_bytes(value, *, creating=False):
    if not isinstance(value, str) or not 1 <= len(value) <= 128 or (creating and len(value) < 15):
        raise ValueError("invalid password")
    return value.encode("utf-8")


def derive_password(password, salt):
    return hashlib.scrypt(password, salt=salt, n=2**15, r=8, p=3, maxmem=64*1024*1024, dklen=32)


def security_row(db, owner):
    return db.execute("""SELECT salt,verifier,password_enabled,email_enabled,sms_enabled,mfa
        FROM login_security WHERE owner=?""", (owner,)).fetchone()


def new_password(db, owner, password):
    salt = secrets.token_bytes(16)
    db.execute("""INSERT INTO login_security(owner,salt,verifier) VALUES(?,?,?) ON CONFLICT(owner) DO UPDATE SET
        salt=excluded.salt,verifier=excluded.verifier,password_enabled=1""",
               (owner, salt, derive_password(password, salt)))
    db.execute("DELETE FROM login_mfa_pending WHERE owner=?", (owner,))
    db.execute("DELETE FROM login_resets WHERE owner=?", (owner,))


def may_use_account(db, owner, target):
    if owner == target:
        return True
    current = db.execute("SELECT document FROM profiles WHERE id=?", (owner,)).fetchone()
    has_contact = db.execute("SELECT 1 FROM login_contacts WHERE owner=?", (owner,)).fetchone()
    return not has_contact and (not current or json.loads(current[0]).get("onboardingPending", False))


def bind_account(db, device, owner, target):
    if owner != target:
        db.execute("INSERT INTO login_devices VALUES(?,?) ON CONFLICT(device) DO UPDATE SET owner=excluded.owner",
                   (device,target))


def issue_login_code(db, *, key, device, kind, address, digest, intent, ip, now, mfa=None):
    if not login_methods().get(kind):
        return "503 Service Unavailable", {"error":"delivery unavailable"}
    if not spend(db, [("login:device:"+device, 3, 1, 3600), ("login:contact:"+digest, 1, 1, 60),
                      ("login:day:"+digest, 6, 1, 86400), ("login:ip:"+sealed(key,ip), 12, 1, 3600),
                      ("login:global:"+kind, 100, 1, 86400)], now):
        return "429 Too Many Requests", {"error":"try later"}
    code = f"{secrets.randbelow(1000000):06d}"
    purpose = f"{intent}:{kind}"
    proof = sealed(key, "login:"+purpose+device+digest+code)
    db.execute("DELETE FROM login_challenges WHERE expires<=?", (now,))
    db.execute("DELETE FROM login_mfa_pending WHERE device=? OR device NOT IN (SELECT device FROM login_challenges)", (device,))
    db.execute("INSERT OR REPLACE INTO login_challenges VALUES(?,?,?,?,?,5)", (device,purpose,digest,proof,now+300))
    if mfa is not None:
        db.execute("INSERT INTO login_mfa_pending VALUES(?,?,?)", (device,*mfa))
    db.commit()
    try:
        (deliver if kind == "phone" else deliver_email)(address, code)
    except (OSError, ValueError, KeyError, smtplib.SMTPException):
        removed = db.execute("DELETE FROM login_challenges WHERE device=? AND proof=?", (device,proof))
        if removed.rowcount:
            db.execute("DELETE FROM login_mfa_pending WHERE device=?", (device,))
        return "503 Service Unavailable", {"error":"delivery unavailable"}
    return "200 OK", {"sent":True}


def password_login(db, owner, device, raw, key, ip, now):
    kind = raw.get("kind")
    address = login_address(kind, raw.get("contact"))
    digest = contact_digest(key, kind, address)
    password = password_bytes(raw.get("password"))
    existing = db.execute("SELECT owner FROM login_contacts WHERE kind=? AND digest=?", (kind,digest)).fetchone()
    target = existing[0] if existing else None
    if not spend(db, [("pw:id:"+(target or digest), 8, 1, 900), ("pw:device:"+device, 12, 1, 900),
                      ("pw:ip:"+sealed(key,ip), 36, 1, 900), ("pw:global", 120, 1, 900)], now):
        return "429 Too Many Requests", {"error":"try later"}
    security = security_row(db, target)
    candidate = derive_password(password, security[0] if security else b"rider-unknown-v1")
    valid = hmac.compare_digest(candidate, security[1] if security else bytes(32))
    if not (security and valid and security[2] and may_use_account(db, owner, target)):
        return "403 Forbidden", {"error":"invalid credentials"}
    if not security[5]:
        bind_account(db, device, owner, target)
        return "200 OK", {"step":"complete"}
    email = address if kind == "email" else raw.get("secondEmail")
    if not email:
        return "200 OK", {"step":"emailRequired"}
    email = login_address("email", email)
    email_digest = contact_digest(key, "email", email)
    if not db.execute("SELECT 1 FROM login_contacts WHERE owner=? AND kind='email' AND digest=?",
                      (target,email_digest)).fetchone():
        return "403 Forbidden", {"error":"invalid credentials"}
    status, response = issue_login_code(db, key=key, device=device, kind="email", address=email, digest=email_digest,
                                        intent="mfa", ip=ip, now=now, mfa=(target,security[1]))
    return status, {"step":"codeRequired"} if status == "200 OK" else response


def manage_password(db, owner, device, path, raw, key, ip, now):
    if path == "/account/password-reset":
        reset = db.execute("SELECT owner FROM login_resets WHERE device=? AND expires>?", (device,now)).fetchone()
        security = security_row(db, reset[0]) if reset else None
        if not reset or (security and security[5]) or not may_use_account(db, owner, reset[0]):
            return "403 Forbidden", {"error":"reset unavailable"}
        new_password(db, reset[0], password_bytes(raw.get("password"), creating=True))
        bind_account(db, device, owner, reset[0])
        return "200 OK", {"saved":True}
    linked = {row[0] for row in db.execute("SELECT kind FROM login_contacts WHERE owner=?", (owner,))}
    if not linked:
        return "403 Forbidden", {"error":"verify contact first"}
    security = security_row(db, owner)
    if security:
        if not spend(db, [("pw:settings:"+owner, 8, 1, 900), ("pw:settings-ip:"+sealed(key,ip), 36, 1, 900)], now):
            return "429 Too Many Requests", {"error":"try later"}
        old_password = raw.get("currentPassword")
        if not old_password or not hmac.compare_digest(derive_password(password_bytes(old_password), security[0]), security[1]):
            return "403 Forbidden", {"error":"invalid password"}
    if path == "/account/password":
        new_password(db, owner, password_bytes(raw.get("password"), creating=True))
        return "200 OK", {"saved":True}
    if not security:
        return "403 Forbidden", {"error":"set a password first"}
    fields = ("passwordEnabled", "emailEnabled", "smsEnabled", "mfa")
    if set(raw) - {*fields,"currentPassword"} or any(type(raw.get(field)) is not bool for field in fields):
        raise ValueError()
    password, email, sms, mfa = (raw[field] for field in fields)
    providers = login_methods()
    if mfa and (not password or not ("email" in linked and providers["email"])):
        return "409 Conflict", {"error":"mfa requires password and verified email"}
    if not (password or (email and "email" in linked and providers["email"]) or (sms and "phone" in linked and providers["phone"])):
        return "409 Conflict", {"error":"keep an available sign-in method"}
    db.execute("""UPDATE login_security SET password_enabled=?,email_enabled=?,sms_enabled=?,mfa=? WHERE owner=?""",
               (password,email,sms,mfa,owner))
    db.execute("DELETE FROM login_mfa_pending WHERE owner=?", (owner,))
    db.execute("DELETE FROM login_resets WHERE owner=?", (owner,))
    return "200 OK", {"saved":True}


def account(db, owner, device, path, method, raw, ip):
    if (path, method) == ("/account", "GET"):
        linked = {row[0] for row in db.execute("SELECT kind FROM login_contacts WHERE owner=?", (owner,))}
        security = security_row(db, owner)
        return "200 OK", {"methods":login_methods(), "linked":sorted(linked), "hasPassword":bool(security),
                           "passwordEnabled":bool(security and security[2]),
                           "emailEnabled":not security or bool(security[3]),
                           "smsEnabled":not security or bool(security[4]), "mfa":bool(security and security[5])}
    if method != "POST" or path not in ("/account/start", "/account/verify", "/account/password",
                                         "/account/password-login", "/account/security", "/account/password-reset"):
        return "404 Not Found", {"error":"unknown account request"}
    db.execute("BEGIN IMMEDIATE")
    # Another request may have enrolled this device while this operation waited for the writer lock.
    device_owner = db.execute("SELECT owner FROM login_devices WHERE device=?", (device,)).fetchone()
    owner = device_owner[0] if device_owner else device
    now = int(time.time())
    key = secret_key(db)
    if path == "/account/password-login":
        return password_login(db, owner, device, raw, key, ip, now)
    if path in ("/account/password", "/account/security", "/account/password-reset"):
        return manage_password(db, owner, device, path, raw, key, ip, now)
    if path == "/account/start":
        kind = raw.get("kind")
        intent = raw.get("intent", "auto")
        if intent not in ("auto", "signIn", "register", "reset"):
            raise ValueError()
        address = login_address(kind, raw.get("contact"))
        digest = contact_digest(key, kind, address)
        return issue_login_code(db, key=key, device=device, kind=kind, address=address, digest=digest,
                                intent=intent, ip=ip, now=now)

    code = raw.get("code")
    if not isinstance(code, str) or not re.fullmatch(r"[0-9]{6}", code):
        raise ValueError()
    challenge = db.execute("SELECT kind,digest,proof,expires,attempts FROM login_challenges WHERE device=?", (device,)).fetchone()
    if not challenge or challenge[3] <= now or not challenge[4]:
        return "403 Forbidden", {"error":"code expired"}
    purpose, digest, proof = challenge[:3]
    intent, separator, kind = purpose.partition(":")
    if not separator:
        kind, intent = purpose, "auto"
    db.execute("UPDATE login_challenges SET attempts=attempts-1 WHERE device=?", (device,))
    if not hmac.compare_digest(proof, sealed(key, "login:"+(purpose if separator else "")+device+digest+code)):
        return "403 Forbidden", {"error":"invalid code"}
    db.execute("DELETE FROM login_challenges WHERE device=?", (device,))
    existing = db.execute("SELECT owner FROM login_contacts WHERE kind=? AND digest=?", (kind,digest)).fetchone()
    target = existing[0] if existing else None
    security = security_row(db, target)
    if intent == "mfa":
        pending = db.execute("SELECT owner,verifier FROM login_mfa_pending WHERE device=?", (device,)).fetchone()
        db.execute("DELETE FROM login_mfa_pending WHERE device=?", (device,))
        if not (pending and target == pending[0] and security and security[2] and security[5]
                and hmac.compare_digest(pending[1], security[1]) and may_use_account(db, owner, target)):
            return "403 Forbidden", {"error":"invalid second factor"}
        bind_account(db, device, owner, target)
        return "200 OK", {"verified":True}
    if intent == "reset":
        if not target or (security and security[5]) or not may_use_account(db, owner, target):
            return "409 Conflict", {"error":"reset unavailable"}
        db.execute("DELETE FROM login_resets WHERE expires<=?", (now,))
        db.execute("INSERT OR REPLACE INTO login_resets VALUES(?,?,?)", (device,target,now+300))
        return "200 OK", {"resetReady":True}
    if intent == "signIn" and not existing:
        return "409 Conflict", {"error":"contact is not registered for sign-in"}
    if existing and target != owner:
        if intent == "register" or not may_use_account(db, owner, target):
            return "409 Conflict", {"error":"contact belongs to an existing account"}
        if security and (security[5] or not security[3 if kind == "email" else 4]):
            return "409 Conflict", {"error":"code sign-in is disabled"}
        bind_account(db, device, owner, target)
    elif not existing:
        if kind == "phone" and db.execute("SELECT 1 FROM contact_phones WHERE digest=? AND owner<>?",
                                          (digest,owner)).fetchone():
            return "409 Conflict", {"error":"link this phone from the existing profile"}
        linked = db.execute("SELECT 1 FROM login_contacts WHERE owner=? AND kind=?", (owner,kind)).fetchone()
        if linked:
            return "409 Conflict", {"error":"this account already has a contact of this type"}
        db.execute("INSERT INTO login_contacts VALUES(?,?,?)", (owner,kind,digest))
    return "200 OK", {"verified":True}


def handle(db, owner, path, method, raw, ip, card):
    if not isinstance(raw,dict): raise ValueError()
    if (path,method)==("/people/demo/status","GET"):
        return "200 OK",{"enabled":demo_member(db,owner)}
    if (path,method)==("/people/demo/sos","POST"):
        if not demo_member(db,owner):
            return "403 Forbidden",{"error":"home test is disabled for this account"}
        return "200 OK",{"drill":True}
    if (path,method)==("/people/demo","POST"):
        return "200 OK",demo_tick(db,owner,raw.get("restart") is True)
    if (path,method)==("/people/search","POST"):
        return "200 OK",directory(db,owner,raw,card)
    if (path,method)==("/people/alerts","GET"):
        rows=db.execute(f"""SELECT e.sequence,e.kind,e.created,json_extract(p.document,'$.name')
            FROM rider_alert_events e JOIN profiles p ON p.id=e.actor WHERE e.owner=? AND {VISIBLE}
            ORDER BY e.sequence DESC LIMIT 32""",(owner,))
        return "200 OK",[dict(id=i,kind=k,created=t,name=n) for i,k,t,n in rows]
    if (path,method)==("/people/preferences","PUT"):
        if set(raw)!=set(ALERT_KINDS) or any(type(x) is not bool for x in raw.values()): raise ValueError()
        if not db.execute("SELECT 1 FROM profiles WHERE id=?",(owner,)).fetchone():
            return "403 Forbidden",{"error":"membership required"}
        db.execute("INSERT OR REPLACE INTO rider_alert_settings VALUES(?,?)",(owner,json.dumps(raw)))
        if not raw["sos"]:
            db.execute("DELETE FROM sos_receivers WHERE owner=?",(owner,))
            db.execute("DELETE FROM sos_foreground WHERE owner=?",(owner,))
            db.execute("UPDATE sos_outbox SET status='failed' WHERE receiver=? AND status='pending'",(owner,))
        return "200 OK",{"saved":True}
    db.execute("BEGIN IMMEDIATE")
    if not db.execute("SELECT 1 FROM profiles WHERE id=?",(owner,)).fetchone():
        return "403 Forbidden",{"error":"membership required"}
    key=secret_key(db)
    row=db.execute("SELECT discoverable FROM contact_phones WHERE owner=?",(owner,)).fetchone()
    def status():
        current=db.execute("SELECT discoverable FROM contact_phones WHERE owner=?",(owner,)).fetchone()
        return {"verified":current is not None,"discoverable":bool(current and current[0]),
                "smsAvailable":bool(os.environ.get("RIDER_SMS_RU_API_ID"))}
    if (path,method)==("/people/phone","GET"): return "200 OK",status()
    if (path,method)==("/people/phone","DELETE"):
        db.execute("DELETE FROM contact_challenges WHERE owner=?",(owner,))
        db.execute("DELETE FROM contact_phones WHERE owner=?",(owner,))
        return "200 OK",status()
    if (path,method)==("/people/phone","PATCH"):
        if not row or type(raw.get("discoverable")) is not bool: raise ValueError()
        db.execute("UPDATE contact_phones SET discoverable=? WHERE owner=?",(raw["discoverable"],owner))
        return "200 OK",status()
    now=int(time.time())
    if (path,method)==("/people/phone/start","POST"):
        phone=normalized(raw.get("phone"))
        if not os.environ.get("RIDER_SMS_RU_API_ID"):
            return "503 Service Unavailable",{"error":"sms offline"}
        digest=digest_phone(key,phone)
        if not spend(db,[(owner+":sms",3,1,3600),(digest+":sms",1,1,60),(digest+":day",5,1,86400),
                         (sealed(key,ip)+":sms",10,1,3600),("sms-global",100,1,86400)],now):
            return "429 Too Many Requests",{"error":"try later"}
        otp=f"{secrets.randbelow(1000000):06d}"
        proof=sealed(key,owner+digest+otp)
        db.execute("INSERT OR REPLACE INTO contact_challenges VALUES(?,?,?,?,5)",(owner,digest,proof,now+300))
        db.commit()
        try: deliver(phone,otp)
        except (OSError,ValueError,TypeError,AttributeError):
            db.execute("DELETE FROM contact_challenges WHERE owner=? AND proof=?",(owner,proof))
            return "503 Service Unavailable",{"error":"sms offline"}
        return "200 OK",{"sent":True}
    if (path,method)==("/people/phone/verify","POST"):
        code=raw.get("code")
        if not isinstance(code,str) or not re.fullmatch(r"[0-9]{6}",code): raise ValueError()
        challenge=db.execute("SELECT digest,proof,expires,attempts FROM contact_challenges WHERE owner=?",(owner,)).fetchone()
        if not challenge or challenge[2]<=now or not challenge[3]:
            return "403 Forbidden",{"error":"code expired"}
        digest,proof=challenge[:2]
        db.execute("UPDATE contact_challenges SET attempts=attempts-1 WHERE owner=?",(owner,))
        if not hmac.compare_digest(proof,sealed(key,owner+digest+code)):
            return "403 Forbidden",{"error":"invalid code"}
        db.execute("DELETE FROM contact_challenges WHERE owner=?",(owner,))
        if db.execute("SELECT 1 FROM contact_phones WHERE digest=? AND owner<>?",(digest,owner)).fetchone():
            return "409 Conflict",{"error":"already linked"}
        db.execute("""INSERT INTO contact_phones VALUES(?,?,0) ON CONFLICT(owner)
                   DO UPDATE SET digest=excluded.digest,discoverable=0""",(owner,digest))
        return "200 OK",status()
    if (path,method)==("/people/contacts","POST"):
        hashes=raw.get("hashes")
        if not row: return "403 Forbidden",{"error":"verify your number"}
        if not isinstance(hashes,list) or len(hashes)>250 or any(not isinstance(h,str) or not re.fullmatch("[a-f0-9]{64}",h) for h in hashes):
            raise ValueError()
        keys={sealed(key,"phone:"+h) for h in hashes}
        if not spend(db,[(owner+":contacts",6000,max(1,len(keys)),86400)],now):
            return "429 Too Many Requests",{"error":"try later"}
        rows=db.execute("""SELECT p.id,p.document FROM contact_phones c JOIN public_profiles p ON p.id=c.owner
                        WHERE c.discoverable=1 AND c.owner<>? AND c.digest IN (SELECT value FROM json_each(?))
                        ORDER BY p.id""",(owner,json.dumps(sorted(keys))))
        return "200 OK",[card(*r) for r in rows]
    return "404 Not Found",{"error":"unknown action"}
