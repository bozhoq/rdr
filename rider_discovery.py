"""Rider directory, public spot recommendations and opt-in verified contact matching."""
import hashlib
import hmac
import json
import math
import os
import re
import secrets
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

def demo_member(db, owner):
    configured = {x.strip() for x in os.environ.get("RIDER_DEMO_RECIPIENT", "").split(",") if x.strip()}
    entry = db.execute("SELECT username FROM handles WHERE owner=?", (owner,)).fetchone()
    return bool(entry and entry[0] in configured)


def demo_tick(db, owner, restart=False):
    # Explicit configuration exists only on the home test server.
    handles = [x for x in os.environ.get("RIDER_DEMO_SENDERS","").split(",") if x]
    if not demo_member(db, owner) or len(handles)<2: return {"enabled":False}
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
        sender=db.execute("SELECT h.owner FROM handles h JOIN public_profiles p ON p.id=h.owner WHERE h.username=?",
                          (handles[step%len(handles)],)).fetchone()
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
    q = folded(query.lstrip("@"))
    if q:
        db.create_function("fold", 1, lambda s: folded(s or ""), deterministic=True)
        rows = db.execute("""WITH candidates AS (
          SELECT id,fold(json_extract(document,'$.name')) AS n,fold(json_extract(document,'$.username')) AS u
          FROM public_profiles WHERE id<>?)
          SELECT p.id,p.document FROM candidates c JOIN profiles p ON p.id=c.id
          WHERE instr(c.u,?) OR instr(c.n,?)
          ORDER BY CASE WHEN c.u=? THEN 0 WHEN c.n=? THEN 1 WHEN instr(c.u,?)=1 THEN 2
                        WHEN instr(c.n,?)=1 THEN 3 ELSE 4 END,c.u,c.id LIMIT 40""",
                          (owner,q,q,q,q,q,q))
        return {"people":[card(*row) for row in rows], "nearby":[]}
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
