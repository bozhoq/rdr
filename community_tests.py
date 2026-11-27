import base64
from contextlib import closing
import io
import json
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime
from unittest.mock import patch
from uuid import UUID

import rider_community as service
import rider_sos
import rider_discovery
import hashlib


class CommunityTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch.dict(os.environ, {"RIDER_DB": directory + "/rider.sqlite3"}))
        self.now = datetime.fromisoformat("2026-12-31T22:00:00+03:00").timestamp()
        self.clock = self.enterContext(patch.object(service.time, "time", side_effect=lambda: self.now))
        self.me = "a" * 72
        self.audience = "b" * 72
        self.totals = {"sessions": 1, "seconds": 900, "jumps": 2, "height": 5.2, "airtime": 3.1}
        self.ride = dict(id=str(UUID(int=1)), startedAt=self.now - 1000, seconds=900, jumps=2, scoringJumps=2, height=5.2, airtime=3.1)

    def call(self, method, path, token, data=None, expect=200, raw=False):
        payload = json.dumps(data).replace("/", r"\/").encode() if data is not None else b""
        env = dict(REQUEST_METHOD=method, PATH_INFO=path, CONTENT_LENGTH=str(len(payload)))
        env["wsgi.url_scheme"] = "https"
        env["wsgi.input"] = io.BytesIO(payload)
        env["HTTP_AUTHORIZATION"] = "Bearer " + token
        headers = []
        response = b"".join(service.application(env, lambda status, _: headers.append(status)))
        self.assertEqual(int(headers[0].split()[0]), expect, response)
        return response if raw else json.loads(response)

    def publish(self, token, handle):
        return self.call("PUT", "/me", token, dict(name=handle, username=handle, totals=self.totals, records=[]))

    def stats(self, rides, revision=0, expect=200):
        return self.call("PUT", "/statistics", self.me, dict(generatedAt=self.now + revision,
                         update=dict(year=2026, rides=rides, totals=self.totals, records=[])), expect=expect)

    def ranking(self, year):
        return self.call("POST", "/tops", self.me, {"metric": "rank", "season": year})

    def test_season_totals_privacy_and_retries(self):
        self.call("GET", "/statistics", self.me, expect=403)
        self.stats([self.ride], expect=403)
        rider = self.publish(self.me, "rider")["mine"]
        self.publish(self.audience, "viewer")
        self.assertEqual(self.stats([self.ride]), {"year": 2026, "followers": 0})
        self.assertEqual(self.ranking(2026)[0]["points"], 145)
        self.call("PUT", "/follow/" + rider["id"], self.audience)
        self.call("PUT", "/follow/" + rider["id"], self.audience)
        self.assertEqual(self.call("GET", "/statistics", self.me)["followers"], 1)
        self.assertEqual(self.ranking(2026)[0]["points"], 165)
        self.stats([self.ride, self.ride], expect=400)
        self.stats([], revision=2)
        self.stats([self.ride], revision=1)
        self.assertEqual(self.ranking(2026)[0]["points"], 20)
        self.now = datetime.fromisoformat("2027-01-01T00:00:00+03:00").timestamp()
        self.assertEqual([row["points"] for row in self.ranking(2027)], [0, 0])
        self.assertEqual(self.ranking(2026), [])
        self.stats([self.ride], expect=409)
        self.call("DELETE", "/me", self.me)
        self.call("GET", "/statistics", self.me, expect=403)

    def test_scoring_threshold_legacy_and_points_above_s(self):
        self.publish(self.me, "rider")
        self.stats([dict(self.ride, height=1.999, scoringJumps=1)], expect=400)
        self.stats([dict(self.ride, height=2, scoringJumps=3)], expect=400)
        small = dict(self.ride, height=1.999, scoringJumps=0)
        self.stats([small])
        self.assertEqual(self.ranking(2026)[0]["points"], 75)
        self.stats([dict(small, height=2, scoringJumps=1)], revision=1)
        self.assertEqual(self.ranking(2026)[0]["points"], 80)
        legacy = {key: value for key, value in self.ride.items() if key != "scoringJumps"}
        self.stats([legacy], revision=2)
        self.assertEqual(self.ranking(2026)[0]["points"], 135)
        long_season = [dict(id=str(UUID(int=i + 10)), startedAt=self.now - i * 86400,
                            seconds=28800, jumps=0, scoringJumps=0) for i in range(1, 8)]
        self.stats(long_season, revision=3)
        self.assertEqual(self.ranking(2026)[0]["points"], 3660)

    def test_missions_use_session_metrics(self):
        self.publish(self.me, "rider")
        self.stats([dict(self.ride, mission="jumps1", scoringJumps=1)])
        self.assertEqual(self.ranking(2026)[0]["points"], 146)
        self.stats([dict(self.ride, mission="route1")], revision=1)
        self.assertEqual(self.ranking(2026)[0]["points"], 145)
        self.stats([dict(self.ride, mission="route1", missionDistance=1000)], revision=2)
        self.assertEqual(self.ranking(2026)[0]["points"], 151)
        self.stats([dict(self.ride, mission="height3", seconds=899)], revision=3)
        self.assertEqual(self.ranking(2026)[0]["points"], 144)
        self.stats([dict(self.ride, mission="unknown")], expect=400)

    def test_nearby_sos_selection_and_delivery(self):
        uid = str(UUID(int=321))
        coords = dict(latitude=45, longitude=33, accuracy=10, capturedAt=self.now)
        payload = dict(id=uid, name="Rider", equipment="Core · Jaime", location=coords)
        self.call("POST", "/sos", self.me, payload, expect=503)

        self.call("PUT", "/sos/receiver", self.audience, dict(token="a1" * 32,
                  location=dict(coords, latitude=45.012)))
        far = "c" * 72
        self.call("PUT", "/sos/receiver", far, dict(token="a2" * 32, location=dict(coords, latitude=45.014)))
        stale = "d" * 72
        self.call("PUT", "/sos/receiver", stale, dict(token="a3" * 32,
                  location=dict(coords, capturedAt=self.now - 46)), expect=400)

        db = sqlite3.connect(os.environ["RIDER_DB"])
        self.addCleanup(db.close)
        db.execute("PRAGMA foreign_keys=ON")
        rider_sos.worker_batch(db, None)
        response = self.call("POST", "/sos", self.me, payload)
        self.assertEqual(response["recipients"], 1)
        self.assertEqual(response["pending"], 1)
        self.assertEqual(self.call("POST", "/sos", self.me, payload), response)
        self.assertEqual(self.call("GET", "/sos/inbox", far), [])
        self.assertEqual(self.call("GET", "/sos/inbox", self.audience)[0]["equipment"], "Core · Jaime")
        path = "/sos/" + uid + "/receipt"
        self.call("GET", path, self.audience, expect=404)

        delivered = []
        def push(token, identifier, expiration, name, equipment, reply):
            delivered.append((token, identifier, name, equipment, reply))
            return "accepted"
        rider_sos.worker_batch(db, push)
        self.assertEqual(delivered, [("a1" * 32, uid, "Rider", "Core · Jaime", False)])
        self.assertEqual(self.call("GET", path, self.me)["acceptedByAPNs"], 1)
        self.now += rider_sos.VISIBLE_SECONDS + 1
        rider_sos.worker_batch(db, None)
        self.assertEqual(self.call("GET", "/sos/inbox", self.audience), [])

    def test_lan_sos_between_nearby_phones_without_apns(self):
        self.enterContext(patch.dict(os.environ, {"RIDER_SOS_FOREGROUND": "1"}))
        coords = dict(latitude=45.0, longitude=35.0, accuracy=12, capturedAt=self.now)
        far = "c" * 72
        opted_out = "d" * 72
        for device, name in [(self.me, "sender"), (self.audience, "receiver"),
                             (far, "far_rider"), (opted_out, "opted_out")]:
            self.publish(device, name)
            location = dict(coords, latitude=46.0) if device == far else coords
            self.call("PUT", "/sos/foreground", device, {"location":location})
        self.call("PUT", "/people/preferences", opted_out,
                  {kind:kind != "sos" for kind in rider_discovery.ALERT_KINDS})
        self.assertEqual(self.call("GET", "/sos/status", self.me), {"ready":True})

        for sender, receiver, key in [(self.me, self.audience, 700), (self.audience, self.me, 701)]:
            uid = str(UUID(int=key))
            path = "/sos/" + uid
            result = self.call("POST", "/sos", sender, dict(id=uid, name="Rider", location=coords))
            self.assertEqual((result["recipients"], result["inApp"], result["seenInApp"]), (1,1,0))
            for excluded in (sender, far, opted_out):
                self.assertEqual(self.call("GET", "/sos/inbox", excluded), [])
            self.assertEqual([row["id"] for row in self.call("GET", "/sos/inbox", receiver)], [uid])
            self.call("GET", "/sos/inbox", receiver)
            self.assertEqual(self.call("GET", path + "/receipt", sender)["seenInApp"], 1)
            self.call("PUT", path + "/decision", receiver, {"action":"accept"})
            self.assertEqual(len(self.call("GET", path + "/receipt", sender)["responders"]), 1)
            self.call("PUT", path + "/close", sender)
            self.assertEqual(self.call("GET", "/sos/inbox", receiver), [])

        self.call("DELETE", "/sos/receiver", self.audience)
        uid = str(UUID(int=702))
        result = self.call("POST", "/sos", self.me, dict(id=uid, name="Rider", location=coords))
        self.assertEqual(result["recipients"], 0)
        self.call("PUT", "/sos/foreground", self.audience, {"location":coords})
        self.assertEqual(self.call("GET", "/sos/inbox", self.audience)[0]["id"], uid)

    def test_sos_accept_skip_and_sender_notification(self):
        coords = dict(latitude=45, longitude=33, accuracy=10, capturedAt=self.now)
        uid = str(UUID(int=322))
        person_a = self.audience
        person_b = "c" * 72
        sender_token = "b1" * 32
        self.call("PUT", "/sos/device", self.me, {"token": sender_token})
        for account, token in [(person_a, "b2" * 32), (person_b, "b3" * 32)]:
            self.call("PUT", "/sos/receiver", account, dict(token=token, location=coords))
        db = sqlite3.connect(os.environ["RIDER_DB"])
        self.addCleanup(db.close)
        db.execute("PRAGMA foreign_keys=ON")
        rider_sos.worker_batch(db, None)
        self.call("POST", "/sos", self.me, dict(id=uid, name="Sender", location=coords))

        endpoint = "/sos/" + uid
        self.call("PUT", endpoint + "/decision", "e" * 72, {"action": "accept"}, expect=404)
        decision = {"action": "accept", "name": "Nearby Rider"}
        for _ in range(2):
            result = self.call("PUT", endpoint + "/decision", person_a, decision)
            self.assertEqual(result["action"], "accept")
        self.call("PUT", endpoint + "/decision", person_b, {"action": "skip"})
        self.assertEqual(self.call("GET", "/sos/inbox", person_b), [])
        self.assertEqual(self.call("GET", "/sos/inbox", person_a)[0]["decision"], "accept")
        receipt = self.call("GET", endpoint + "/receipt", self.me)
        self.assertEqual([r["name"] for r in receipt["responders"]], ["Nearby Rider"])
        self.assertEqual(receipt["pending"], 0)
        self.assertEqual(receipt["location"]["latitude"], coords["latitude"])
        self.call("GET", endpoint + "/receipt", person_a, expect=404)

        delivered = []
        def push(token, identifier, expiration, name, equipment, reply):
            delivered.append((token, identifier, name, reply))
            return "accepted"
        rider_sos.worker_batch(db, push)
        rider_sos.worker_batch(db, push)
        self.assertEqual(delivered, [(sender_token, uid, "Nearby Rider", True)])

    def test_name_handle_and_nearby_search_respect_visibility(self):
        profile = dict(name="Алёна Ветер", username="wind_test", totals=self.totals, records=[])
        self.call("PUT", "/me", self.me, profile)
        self.publish(self.audience, "viewer")
        def search(**criteria):
            return self.call("POST", "/people/search", self.audience, criteria)
        for query in ("алена", "@wind_", "ВЕТЕР"):
            found = search(query=query)["people"]
            self.assertEqual([(p["username"], p["name"]) for p in found], [("wind_test", "Алёна Ветер")])
        post = str(UUID(int=810))
        self.call("PUT", "/posts/" + post, self.me, dict(id=post, caption="Демо", photo="/9j/2Q==",
                  location=dict(name="Тест", latitude=1.1, longitude=2.2)))
        self.assertTrue(search(lat=1, lon=2)["nearby"])
        self.assertFalse(search(lat=50, lon=40)["nearby"])
        self.call("PUT", "/me", self.me, dict(profile, publicProfile=False))
        self.assertFalse(search(lat=1, lon=2)["nearby"])
        self.assertFalse(search(query="ветер")["people"])

    def test_verified_opt_in_contacts(self):
        self.publish(self.me, "person")
        self.publish(self.audience, "viewer")
        self.enterContext(patch.dict(os.environ, {"RIDER_SMS_RU_API_ID":"test"}))
        sms = self.enterContext(patch.object(rider_discovery, "deliver"))
        for token, phone in [(self.me,"+12025550101"), (self.audience,"+12025550102")]:
            self.call("POST", "/people/phone/start", token, {"phone":phone})
            code = sms.call_args.args[1]
            self.call("POST", "/people/phone/verify", token, {"code":str((int(code)+1)%1000000).zfill(6)}, expect=403)
            self.assertTrue(self.call("POST", "/people/phone/verify", token, {"code":code})["verified"])
        request = {"hashes":[hashlib.sha256(b"+12025550101").hexdigest()]}
        self.assertEqual(self.call("POST", "/people/contacts", self.audience, request), [])
        self.call("PATCH", "/people/phone", self.me, {"discoverable":True})
        self.assertEqual(self.call("POST", "/people/contacts", self.audience, request)[0]["username"], "person")
        self.call("DELETE", "/people/phone", self.me)
        self.assertEqual(self.call("POST", "/people/contacts", self.audience, request), [])
        self.call("POST", "/people/phone/start", self.me, {"phone":"+12025550103"})
        self.now += 301
        self.call("POST", "/people/phone/verify", self.me, {"code":sms.call_args.args[1]}, expect=403)

    def test_account_registration_and_recovery_by_phone_or_email(self):
        self.enterContext(patch.dict(os.environ, {"RIDER_SMS_RU_API_ID":"test", "RIDER_SMTP_HOST":"localhost",
                                                  "RIDER_SMTP_FROM":"rider@example.test"}))
        sms = self.enterContext(patch.object(rider_discovery, "deliver"))
        email = self.enterContext(patch.object(rider_discovery, "deliver_email"))
        profile = dict(name="Rider", username="persistent", totals=self.totals)
        self.call("PUT", "/registration", self.me, profile, expect=403)
        self.assertEqual(self.call("GET", "/account", self.me)["methods"], {"phone":True,"email":True})

        def request(device, kind, contact, sender):
            self.call("POST", "/account/start", device, {"kind":kind, "contact":contact})
            return sender.call_args.args[1]

        def verify(device, code, expect=200):
            return self.call("POST", "/account/verify", device, {"code":code}, expect=expect)

        number = "+12025550101"
        address = "rider@example.test"
        code = request(self.me, "phone", number, sms)
        verify(self.me, str((int(code)+1)%1_000_000).zfill(6), expect=403)
        verify(self.me, code)
        verify(self.me, code, expect=403)
        first = self.call("PUT", "/registration", self.me, profile)["mine"]["id"]
        verify(self.me, request(self.me, "email", "Rider@Example.Test", email))
        self.assertEqual(self.call("GET", "/account", self.me)["linked"], ["email","phone"])
        self.publish(self.me, "renamed")

        self.now += 61
        verify(self.audience, request(self.audience, "email", address, email))
        self.assertFalse(self.call("GET", "/registration", self.audience)["required"])
        self.assertEqual(self.call("GET", "/me", self.audience)["mine"]["id"], first)
        self.assertEqual(self.call("GET", "/registration", self.audience)["username"], "renamed")

        third = "c"*72
        verify(third, request(third, "phone", number, sms))
        self.assertEqual(self.call("GET", "/me", third)["mine"]["id"], first)
        separate = "d"*72
        self.publish(separate, "separate")
        self.now += 61
        verify(separate, request(separate, "email", address, email), expect=409)
        self.assertNotEqual(self.call("GET", "/me", separate)["mine"]["id"], first)
        late = "e"*72
        code = request(late, "phone", number, sms)
        self.now += 301
        verify(late, code, expect=403)

        fresh = "f"*72
        verify(fresh, request(fresh, "email", "new@example.test", email))
        result = self.call("PUT", "/registration", fresh, dict(profile, username="email_first"))
        self.assertNotEqual(result["mine"]["id"], first)
        self.assertEqual(self.call("GET", "/account", fresh)["linked"], ["email"])

        self.now += 61
        for device, intent, contact in [("1"*72, "signIn", "not-registered@example.test"),
                                        ("2"*72, "register", address),
                                        ("3"*72, "signIn", "new@example.test")]:
            self.call("POST", "/account/start", device, {"kind":"email","contact":contact,"intent":intent})
            verify(device, email.call_args.args[1], expect=200 if device == "3"*72 else 409)
            status = self.call("GET", "/registration", device)
            if device == "3"*72:
                self.assertEqual(status["profileID"], result["mine"]["id"])
            else:
                self.assertTrue(status["required"])
                self.assertFalse(status["verified"])

    def test_password_policy_mfa_and_restricted_reset(self):
        self.enterContext(patch.dict(os.environ, {"RIDER_SMS_RU_API_ID":"test",
                         "RIDER_SMTP_HOST":"localhost", "RIDER_SMTP_FROM":"rider@example.test"}))
        email = self.enterContext(patch.object(rider_discovery, "deliver_email"))
        sms = self.enterContext(patch.object(rider_discovery, "deliver"))
        address, phone = "rider@example.test", "+12025550105"
        password, new_password = "summer wind over the lagoon", "ride by the warm shoreline"

        def code(device, *, contact=address, kind="email", intent="auto", expect=200):
            self.call("POST", "/account/start", device, {"kind":kind,"contact":contact,"intent":intent})
            pin = (email if kind == "email" else sms).call_args.args[1]
            return self.call("POST", "/account/verify", device, {"code":pin}, expect=expect)

        code(self.me)
        code(self.me, contact=phone, kind="phone")
        body = dict(name="Local Rider", username="password_rider", totals=self.totals, password=password)
        owner = self.call("PUT", "/registration", self.me, body)["mine"]["id"]
        self.assertTrue(self.call("GET", "/account", self.me)["passwordEnabled"])

        def login(device, *, secret=password, kind="email", contact=address, expect=200, **extra):
            return self.call("POST", "/account/password-login", device, dict(
                kind=kind, contact=contact, password=secret, **extra), expect=expect)

        login(self.audience, secret="bad password", expect=403)
        self.assertEqual(login(self.audience, kind="phone", contact=phone), {"step":"complete"})
        self.assertEqual(self.call("GET", "/me", self.audience)["mine"]["id"], owner)
        policy = dict(currentPassword=password, passwordEnabled=True, emailEnabled=False, smsEnabled=False, mfa=True)
        self.call("POST", "/account/security", self.me, dict(policy,currentPassword="wrong"), expect=403)
        self.call("POST", "/account/security", self.me, dict(policy,passwordEnabled=False), expect=409)
        self.call("POST", "/account/security", self.me, dict(policy,passwordEnabled=False,mfa=False), expect=409)
        self.call("POST", "/account/security", self.me, policy)
        self.now += 61
        other = "c"*72
        code(other, intent="signIn", expect=409)
        self.assertTrue(self.call("GET", "/registration", other)["required"])
        self.now += 61
        code(other, intent="reset", expect=409)
        self.now += 3600
        self.assertEqual(login(other, kind="phone", contact=phone), {"step":"emailRequired"})
        login(other, kind="phone", contact=phone, secondEmail="someone@example.test", expect=403)
        self.assertEqual(login(other, kind="phone", contact=phone, secondEmail=address), {"step":"codeRequired"})
        self.assertTrue(self.call("GET", "/registration", other)["required"])
        pin = email.call_args.args[1]
        self.call("POST", "/account/verify", other, {"code":pin})
        self.call("POST", "/account/verify", other, {"code":pin}, expect=403)
        self.assertEqual(self.call("GET", "/me", other)["mine"]["id"], owner)

        self.call("POST", "/account/security", self.me, dict(policy,mfa=False))
        self.now += 61
        recovering = "d"*72
        self.assertEqual(code(recovering, intent="reset"), {"resetReady":True})
        self.assertTrue(self.call("GET", "/registration", recovering)["required"])
        self.call("POST", "/account/password-reset", recovering, {"password":new_password})
        self.call("POST", "/account/password-reset", recovering, {"password":new_password}, expect=403)
        old_device = "e"*72
        login(old_device, expect=403)
        self.assertEqual(login(old_device, secret=new_password), {"step":"complete"})
        self.assertEqual(self.call("GET", "/me", old_device)["mine"]["id"], owner)

    def test_demo_alert_delivery_and_preferences(self):
        recipient = self.publish(self.me, "recipient")["mine"]["id"]
        alpha = self.publish(self.audience, "alpha")["mine"]["id"]
        beta = self.publish("c"*72, "beta")["mine"]["id"]
        self.enterContext(patch.dict(os.environ, {"RIDER_DEMO_RECIPIENT_IDS":recipient,
                                                  "RIDER_DEMO_SENDER_IDS":",".join((alpha,beta))}))
        renamed = self.call("PUT", "/me", self.me,
                            dict(name="New nickname", username="new_recipient", totals=self.totals))["mine"]
        self.assertEqual(renamed["id"], recipient)
        newcomer = "d"*72
        self.publish(newcomer, "recipient")
        self.assertFalse(self.call("GET", "/people/demo/status", newcomer)["enabled"])
        self.assertTrue(self.call("GET", "/people/demo/status", self.me)["enabled"])
        self.publish(self.audience, "new_alpha")
        def tick(who): return self.call("POST", "/people/demo", who, {})
        self.assertFalse(tick(self.audience)["enabled"])
        self.assertTrue(tick(self.me)["enabled"])
        self.call("PUT", "/sos/device", self.me, {"token":"a"*64})
        prefs = dict.fromkeys(rider_discovery.ALERT_KINDS, True)
        self.call("PUT", "/people/preferences", self.me, dict(prefs, message=False, sos=False))
        fix = dict(latitude=1, longitude=2, accuracy=5, capturedAt=self.now)
        self.assertFalse(self.call("PUT", "/sos/receiver", self.me, dict(token="a"*64, location=fix))["enabled"])
        self.now += 22
        self.assertFalse(tick(self.me)["drill"])
        with closing(sqlite3.connect(os.environ["RIDER_DB"])) as db:
            deliveries = []
            def send(*args):
                deliveries.append(args)
                return "accepted"
            rider_discovery.push_batch(db, send)
            self.assertFalse(deliveries)
            self.call("PUT", "/people/preferences", self.me, prefs)
            self.now += 25
            self.assertFalse(tick(self.me)["drill"])
            rider_discovery.push_batch(db, send)
            self.assertEqual([item[2] for item in deliveries], ["message"])
            self.now += 25
            self.assertTrue(tick(self.me)["drill"])
            self.assertFalse(tick(self.me)["drill"])
            self.assertEqual(db.execute("SELECT count(*) FROM sos_incidents").fetchone()[0], 0)
        events = self.call("GET", "/people/alerts", self.me)
        self.assertEqual([e["kind"] for e in events], ["message","message"])

    def test_registration_and_delivery_receipts(self):
        self.assertTrue(self.call("GET", "/registration", self.me)["required"])
        self.call("PUT", "/membership", self.me)
        self.assertTrue(self.call("GET", "/registration", self.me)["required"])
        a = self.call("PUT", "/registration", self.me,
                      dict(name="First Rider", username="first_rider", totals=self.totals))["mine"]
        self.assertTrue(a["profile"]["publicProfile"])
        self.assertTrue(a["profile"]["statsPublic"])
        self.assertFalse(self.call("GET", "/registration", self.me)["required"])
        b = self.publish(self.audience, "second_rider")["mine"]
        self.call("PUT", "/follow/" + b["id"], self.me)
        row = self.call("GET", "/activity/read", self.audience)
        self.assertEqual(row["items"][0]["kind"], "follow")
        self.assertEqual(self.call("GET", "/unread", self.audience)["activity"], 1)
        self.assertEqual(self.call("PUT", "/activity/read", self.audience, {"sequence": row["sequence"]})["activity"], 0)
        first = str(UUID(int=812))
        outgoing = "/messages/" + b["id"]
        incoming = "/messages/" + a["id"]
        sent = self.call("PUT", outgoing + "/" + first, self.me, {"text":"Hello!"})[0]
        self.assertFalse(sent["delivered"])
        self.assertFalse(sent["read"])
        self.assertEqual(self.call("GET", "/unread", self.audience)["threads"], {a["id"]:1})
        sent = self.call("GET", outgoing, self.me)[0]
        self.assertTrue(sent["delivered"])
        self.assertFalse(sent["read"])
        self.call("PUT", outgoing + "/read", self.me, {"messages":[first]})
        self.assertFalse(self.call("GET", outgoing, self.me)[0]["read"])
        self.assertEqual(self.call("PUT", incoming + "/read", self.audience, {"messages":[first]})["threads"], {})
        self.assertTrue(self.call("GET", outgoing, self.me)[0]["read"])
        self.call("PATCH", "/me", self.me, {"statsPublic":False})
        replay = self.call("PUT", "/registration", self.me, dict(name="Replay", username="first_rider",
                           totals=self.totals))["mine"]["profile"]
        self.assertFalse(replay["statsPublic"])

    def test_story_likes_and_viewer_list(self):
        self.publish(self.me, "author")
        viewer = self.publish(self.audience, "viewer")["mine"]
        key = str(UUID(int=815))
        path = "/stories/" + key
        self.call("PUT", path, self.me, dict(id=key, caption="", photo="/9j/2Q=="))
        self.call("PUT", path + "/seen", self.me)
        self.assertEqual(self.call("GET", path + "/viewers/0", self.me)["people"], [])
        self.call("GET", path + "/viewers/0", self.audience, expect=404)
        self.call("PUT", path + "/like", self.me, expect=403)
        for _ in range(2):
            self.assertEqual(self.call("PUT", path + "/like", self.audience), {"liked": True})
        item = self.call("GET", "/stories", self.audience)[0]
        self.assertTrue(item["liked"])
        self.assertTrue(item["seen"])
        people = self.call("GET", path + "/viewers/0", self.me)["people"]
        self.assertEqual([(row["person"]["id"], row["liked"]) for row in people], [(viewer["id"], True)])
        self.assertEqual(self.call("DELETE", path + "/like", self.audience), {"liked": False})
        self.assertFalse(self.call("GET", path + "/viewers/0", self.me)["people"][0]["liked"])
        self.now += 86400
        self.call("PUT", path + "/like", self.audience, expect=404)
        self.call("GET", path + "/viewers/0", self.me, expect=404)

    def test_stories_expire_and_voice_attachments_are_private(self):
        rider = self.publish(self.me, "author")["mine"]
        viewer = self.publish(self.audience, "viewer")["mine"]
        third = "c"*72
        self.publish(third, "third")
        story = str(UUID(int=813))
        path = "/stories/" + story
        post = dict(id=story, caption="Rider", photo="/9j/2Q==")
        self.call("PUT", path, self.me, post)
        self.call("PUT", path, self.me, post)
        items = self.call("GET", "/stories", self.audience)
        self.assertEqual(len(items),1)
        self.assertFalse(items[0]["seen"])
        self.assertEqual(self.call("GET", path + "/media", self.audience, raw=True), base64.b64decode(post["photo"]))
        self.call("PUT", path + "/seen", self.audience)
        self.assertTrue(self.call("GET", "/stories", self.audience)[0]["seen"])
        self.call("DELETE", path, third)
        self.assertEqual(len(self.call("GET", "/stories", self.audience)),1)
        self.now += 86400
        self.assertEqual(self.call("GET", "/stories", self.audience), [])
        self.call("GET", path + "/media", self.audience, expect=404)
        message = str(UUID(int=814))
        clip = bytes.fromhex("000000186674797069736f6d30303030")
        attachment = dict(filename="voice.m4a", contentType="audio/mp4", data=base64.b64encode(clip).decode())
        self.call("PUT", "/messages/" + viewer["id"] + "/" + message, self.me, {"text":"", "attachment":attachment})
        suffix = "/" + message + "/attachment"
        self.assertEqual(self.call("GET", "/messages/" + rider["id"] + suffix, self.audience, raw=True), clip)
        self.call("GET", "/messages/" + rider["id"] + suffix, third, expect=404)

    def test_private_registered_rider_follows_and_activity_can_be_cleared(self):
        rider = self.call("PUT", "/me", self.me, dict(name="Private", username="private_rider",
                          totals=self.totals, publicProfile=False))["mine"]
        target = self.publish(self.audience, "public_rider")["mine"]
        unused = "c" * 72
        self.call("PUT", "/membership", unused)
        path = "/follow/" + target["id"]
        self.call("PUT", path, unused, expect=403)
        self.assertTrue(self.call("PUT", path, self.me)["following"])
        self.assertTrue(self.call("GET", "/riders/" + target["id"], self.me)["rider"]["following"])
        self.assertFalse(self.call("DELETE", path, self.me)["following"])
        self.call("PATCH", "/me", self.me, {"publicProfile":True})
        self.call("PUT", path, self.me)
        item = self.call("GET", "/activity/read", self.audience)["items"][0]
        self.call("PUT", "/activity/hide", self.audience, {"id":item["id"]})
        self.assertEqual(self.call("GET", "/activity", self.audience), [])
        self.call("DELETE", path, self.me)
        self.now += 1
        self.call("PUT", path, self.me)
        self.assertEqual(len(self.call("GET", "/activity", self.audience)),1)
        self.call("DELETE", "/activity", self.audience)
        self.assertEqual(self.call("GET", "/activity", self.audience), [])
        self.assertEqual(self.call("GET", "/unread", self.audience)["activity"],0)
        self.call("DELETE", path, self.me)
        self.now += 1
        self.call("PUT", path, self.me)
        self.assertEqual(len(self.call("GET", "/activity", self.audience)),1)

    def test_sos_can_be_closed_and_started_again_and_demo_is_isolated(self):
        tester = self.publish(self.me, "local_tester")["mine"]["id"]
        self.publish(self.audience, "rider_nearby")
        coords = dict(latitude=45, longitude=33, accuracy=10, capturedAt=self.now)
        self.call("PUT", "/sos/receiver", self.audience, dict(token="a1"*32, location=coords))
        with closing(sqlite3.connect(os.environ["RIDER_DB"])) as db:
            rider_sos.worker_batch(db,None)
        first = str(UUID(int=952))
        second = str(UUID(int=953))
        self.call("POST", "/sos", self.me, dict(id=first, name="Rider", location=coords))
        close = "/sos/" + first + "/close"
        self.call("PUT", close, self.audience, expect=404)
        self.assertTrue(self.call("PUT", close, self.me)["closed"])
        self.assertEqual(self.call("GET", "/sos/inbox", self.audience), [])
        self.call("PUT", "/sos/"+first+"/decision", self.audience, {"action":"accept"}, expect=404)
        self.assertFalse(self.call("POST", "/sos", self.me, dict(id=second, name="Rider", location=coords))["closed"])
        with patch.dict(os.environ, {"RIDER_DEMO_RECIPIENT_IDS":tester}):
            self.assertTrue(self.call("GET", "/people/demo/status", self.me)["enabled"])
            self.call("POST", "/people/demo/sos", self.audience, {}, expect=403)
            self.assertTrue(self.call("POST", "/people/demo/sos", self.me, {})["drill"])
        with closing(sqlite3.connect(os.environ["RIDER_DB"])) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM sos_incidents").fetchone()[0],2)

    def test_delete_gallery_post_preserves_adjacent_posts(self):
        self.publish(self.me, "gallery_owner")
        self.publish(self.audience, "viewer")
        identifiers = [str(UUID(int=700+i)) for i in range(4)]
        for index, post in enumerate(identifiers, start=1):
            self.call("PUT", "/posts/" + post, self.me,
                      dict(id=post, caption=f"Post {index}", photo="/9j/2Q=="))
            self.now += 1
        self.assertEqual(
            [entry["post"]["id"] for entry in self.call("GET", "/riders/me", self.me)["posts"]],
            identifiers[::-1],
        )
        target = "/posts/" + identifiers[2]
        self.call("DELETE", target, self.audience)
        self.call("GET", target + "/details", self.me)
        self.call("DELETE", target, self.me)
        self.call("DELETE", target, self.me)
        self.call("GET", target + "/details", self.me, expect=404)
        self.assertEqual(
            [entry["post"]["id"] for entry in self.call("GET", "/riders/me", self.me)["posts"]],
            [identifiers[3], identifiers[1], identifiers[0]],
        )

    def test_journal_video_privacy_and_idempotent_publish(self):
        rider = self.publish(self.me, "author")["mine"]
        self.publish(self.audience, "viewer")
        note = str(UUID(int=700))
        path = "/posts/" + note
        self.call("PUT", path, self.me, dict(id=note, caption="   ", section="journal"), expect=400)
        self.call("PUT", path, self.me, dict(id=note, caption="Тест"), expect=400)
        self.call("PUT", path, self.me, dict(id=note, caption="Текст заметки", section="journal"))
        self.call("PUT", path, self.me, dict(id=note, caption="Текст заметки", section="journal"))
        items = self.call("GET", "/riders/" + rider["id"], self.me)["posts"]
        self.assertEqual(len(items), 1)
        self.assertFalse(items[0]["post"]["hasCover"])
        self.assertEqual(items[0]["post"]["section"], "journal")
        self.assertNotIn(b"<img", self.call("GET", path + "/view", self.audience, raw=True))
        self.call("GET", path + "/photo", self.audience, expect=404)

        clip = bytes.fromhex("000000186674797069736f6d30303030")
        video = str(UUID(int=701))
        video_path = "/posts/" + video
        content = dict(id=video, caption="", photo="/9j/2Q==", video=base64.b64encode(clip).decode())
        self.call("PUT", video_path, self.me, dict(content, video="c2NyaXB0"), expect=400)
        self.call("PUT", video_path, self.me, content)
        self.call("PUT", video_path, self.audience, content, expect=409)
        self.assertEqual(self.call("GET", video_path + "/video", self.audience, raw=True), clip)
        captured = []
        response = service.application(dict(REQUEST_METHOD="GET", PATH_INFO=video_path + "/video", HTTP_RANGE="bytes=4-7"),
                                       lambda status, headers: captured.append((status, dict(headers))))
        self.assertEqual(b"".join(response), b"ftyp")
        self.assertEqual(captured[0][0], "206 Partial Content")
        self.assertEqual(captured[0][1]["Content-Range"], f"bytes 4-7/{len(clip)}")
        self.call("PATCH", "/me", self.me, {"publicProfile":False})
        self.call("GET", video_path + "/video", self.audience, expect=404)

    def test_comment_likes_and_complete_shaka_list(self):
        self.publish(self.me, "author")
        tokens = [letter * 72 for letter in "bcde"]
        people = [self.publish(token, "rider_" + token[0])["mine"]["id"] for token in tokens]
        identifier = str(UUID(int=710))
        post = "/posts/" + identifier
        self.call("PUT", post, self.me, dict(id=identifier, caption="Фото", photo="/9j/2Q=="))
        for token in tokens:
            self.now += 1
            preview = self.call("PUT", post + "/shaka", token)
        self.assertEqual((preview["total"], len(preview["people"])), (4, 3))
        full = self.call("GET", post + "/shakas/0", self.me)
        self.assertEqual({person["id"] for person in full["people"]}, set(people))
        self.assertEqual(self.call("GET", post + "/shakas/3", self.me)["people"][0]["id"], people[0])
        comment = post + "/comments/" + str(UUID(int=711))
        self.call("PUT", comment, tokens[0], {"text":"Круто!"})
        for _ in range(2):
            updated = self.call("PUT", comment + "/like", tokens[1])
        self.assertEqual((updated[0]["likes"], updated[0]["liked"]), (1, True))
        other = self.call("GET", post + "/comments", tokens[2])[0]
        self.assertEqual((other["likes"], other["liked"]), (1, False))
        self.call("PUT", post + "/comments/" + str(UUID(int=712)) + "/like", tokens[1], expect=404)
        self.assertEqual(self.call("DELETE", comment + "/like", tokens[1])[0]["likes"], 0)

    def test_post_interaction_endpoints(self):
        rider = self.publish(self.me, "rider")["mine"]
        self.publish(self.audience, "viewer")
        post = str(UUID(int=2))
        path = "/posts/" + post
        self.call("PUT", path, self.me, dict(id=post, caption="Каталка", photo="/9j/2Q=="))
        self.assertEqual(len(self.call("GET", "/feed/recommended", self.audience)), 1)
        self.assertTrue(self.call("PUT", path + "/shaka", self.audience)["mine"])
        comment = str(UUID(int=3))
        self.call("PUT", path + "/comments/" + comment, self.audience, {"text": "Отличная каталка"})
        self.assertEqual(len(self.call("GET", path + "/comments", self.me)), 1)
        summary = self.call("GET", path + "/details", self.me)["commentSummary"]
        self.assertEqual(summary["total"], 1)
        self.assertEqual(summary["preview"]["text"], "Отличная каталка")
        self.call("PUT", path + "/repost", self.audience, {"id": str(UUID(int=4))})
        self.assertEqual(len(self.call("GET", "/feed/my-reposts", self.audience)), 1)
        self.assertEqual(self.call("GET", path + "/details", self.me)["reaction"]["total"], 1)
        self.assertTrue(self.call("GET", "/activity", self.me))
        message = str(UUID(int=5))
        sent = self.call("PUT", "/messages/" + rider["id"] + "/" + message, self.audience,
                         {"text": "Look", "postID": post})
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["sharedPost"]["post"]["caption"], "Каталка")
        self.assertEqual(sent[0]["sharedPost"]["authorID"], rider["id"])
        self.assertEqual(len(self.call("GET", "/messages", self.me)), 1)
        self.call("DELETE", path, self.me)
        self.assertEqual(self.call("GET", "/feed/my-reposts", self.audience), [])


    def test_profile_visibility_hides_data_without_deleting_relationships(self):
        viewer = self.call("PUT", "/me", self.audience, dict(
            name="Wave", username="viewer", totals=self.totals, avatar="/9j/2Q=="))["mine"]
        record = dict(id=str(UUID(int=100)), startedAt=self.now - 60, height=5.2, airtime=3.1, distance=19)
        rider = self.call("PUT", "/me", self.me, dict(
            name="Rider", username="rider", totals=self.totals, records=[record]))["mine"]
        self.call("PUT", "/follow/" + rider["id"], self.audience)
        self.call("PUT", "/statistics", self.me, dict(generatedAt=self.now, update=dict(year=2026,
                  rides=[self.ride], totals=self.totals, records=[record], secrets=["height3"],
                  publicRides=[dict(record, seconds=900, jumps=2, windMS=7, spot="Example", kite="Kite", board="Board", heightSum=8.3, latitude=1, longitude=2)])))
        post = str(UUID(int=101))
        path = "/posts/" + post
        self.call("PUT", path, self.me, dict(id=post, caption="Ветер", photo="/9j/2Q=="))
        comment = "/comments/" + str(UUID(int=102))
        row = self.call("PUT", path + comment, self.audience, {"text": "Здорово!"})[0]
        self.assertEqual((row["authorID"], row["username"], row["avatar"]), (viewer["id"], "viewer", "/9j/2Q=="))
        page = self.call("GET", "/riders/rider", self.audience)
        self.assertEqual(page["points"], 165)
        self.assertEqual(page["distance"], 19)
        self.assertEqual(page["rides"][0]["seconds"], 900)
        self.assertNotIn("latitude", page["rides"][0])
        self.assertEqual(page["rider"]["profile"]["secrets"], ["height3"])
        self.assertEqual(page["posts"][0]["post"]["id"], post)
        self.assertEqual(self.call("GET", "/riders/rider/followers", self.audience)[0]["id"], viewer["id"])
        self.assertEqual(self.call("GET", "/riders/me/following", self.audience)[0]["id"], rider["id"])
        thread = "/messages/" + rider["id"]
        self.call("PUT", thread + "/" + str(UUID(int=103)), self.audience, {"text": "", "postID": post})

        self.call("PATCH", "/me", self.me, {"statsPublic": False})
        self.assertEqual(self.call("GET", "/statistics", self.me)["statsPublic"], False)
        page = self.call("GET", "/riders/rider", self.audience)
        self.assertEqual(page["points"], 165)
        self.assertEqual(page["distance"], 19)
        self.assertNotIn("rides", page)
        self.assertEqual(page["rider"]["profile"]["secrets"], ["height3"])
        self.assertEqual(page["rider"]["profile"]["totals"], self.totals)
        self.assertEqual(len(page["posts"]), 1)
        self.assertEqual(page["sessionRecords"][0]["height"], 5.2)
        self.assertTrue(set(page["sessionRecords"][0]).isdisjoint({"spot", "board", "windMS", "kite", "heightSum"}))
        self.assertEqual(self.call("POST", "/tops", self.audience, {"metric": "height"})[0]["id"], rider["id"])
        self.assertEqual(self.ranking(2026)[0]["points"], 165)

        self.call("PATCH", "/me", self.me, {"publicProfile": False})
        self.call("PUT", "/me", self.me, dict(name="Renamed", username="rider", totals=self.totals))
        self.assertFalse(self.call("GET", "/me", self.me)["mine"]["profile"]["publicProfile"])
        closed = self.call("GET", "/riders/rider", self.audience)
        self.assertEqual(closed["points"], 165)
        self.assertEqual(closed["posts"], [])
        self.assertNotIn("rides", closed)
        for suffix in ("details", "comments", "view", "photo"):
            self.call("GET", path + "/" + suffix, self.audience, expect=404)
        self.assertEqual(self.call("GET", "/feed/following", self.audience), [])
        self.assertIsNone(self.call("GET", thread, self.audience)[0]["sharedPost"])
        self.assertEqual(self.call("GET", "/riders/me/following", self.audience), [])
        self.call("PATCH", "/me", self.me, {"publicProfile": True, "statsPublic": True})
        page = self.call("GET", "/riders/rider", self.audience)
        self.assertEqual(page["rider"]["profile"]["name"], "Renamed")
        self.assertTrue(page["rider"]["following"])
        self.assertEqual(page["points"], 165)
        self.assertEqual(self.call("GET", thread, self.audience)[0]["sharedPost"]["post"]["caption"], "Ветер")


    def test_reply_links_and_alerts(self):
        self.publish(self.me, "author")
        self.publish(self.audience, "visitor")
        other = "c" * 72
        self.publish(other, "third")
        post = str(UUID(int=21))
        path = "/posts/" + post
        self.call("PUT", path, self.me, dict(id=post, caption="Test", photo="/9j/2Q=="))
        parent, reply = str(UUID(int=22)), str(UUID(int=23))
        self.call("PUT", path + "/comments/" + parent, self.audience, {"text": "Hello"})
        payload = {"text": "A reply", "replyTo": parent}
        for _ in range(2):
            rows = self.call("PUT", path + "/comments/" + reply, other, payload)
            self.assertEqual(rows[-1]["replyName"], "visitor")
        events = self.call("GET", "/activity", self.audience)
        self.assertEqual([(e["kind"], e["postID"]) for e in events], [("reply", post)])
        self.assertEqual(len(self.call("GET", path + "/comments", self.me)), 2)
        self.call("PUT", path + "/comments/" + reply, other, {"text": "Change target"}, expect=409)
        second = str(UUID(int=24))
        self.call("PUT", "/posts/" + second, self.me, dict(id=second, caption="", photo="/9j/2Q=="))
        self.call("PUT", "/posts/" + second + "/comments/" + str(UUID(int=25)), other, payload, expect=404)
        own = str(UUID(int=26))
        self.call("PUT", path + "/comments/" + own, self.me, {"text": "Question"})
        self.call("PUT", path + "/comments/" + str(UUID(int=27)), self.audience, {"text": "Answer", "replyTo": own})
        self.assertEqual([e["kind"] for e in self.call("GET", "/activity", self.me)].count("reply"), 1)
        self.call("DELETE", path + "/comments/" + reply, other)
        self.assertEqual(self.call("GET", "/activity", self.audience), [])

    def test_private_member_placement_outside_public_fifty(self):
        for _ in range(2):
            self.call("PUT", "/membership", self.me)
        me = self.call("GET", "/me", self.me)["mine"]["id"]
        with closing(sqlite3.connect(os.environ["RIDER_DB"])) as db, db:
            for i in range(60):
                key = f"{i:064x}"
                db.execute("INSERT INTO profiles VALUES (?,?)", (key, json.dumps(dict(
                    name=str(i), publicProfile=False, statsPublic=False, totals=self.totals))))
                db.execute("INSERT INTO season_scores VALUES (?,?,?,?)", (key, 2026, 100+i, self.now))
                service.replace_records(db, key, service.score_rows([dict(self.ride, height=3+i)]))
            service.replace_records(db, me, service.score_rows([dict(self.ride, height=1)]))
        for query in (dict(metric="height"), dict(metric="rank", season=2026)):
            result = self.call("POST", "/tops", self.me, dict(query, withMyPlace=True))
            self.assertEqual(len(result["leaders"]), 50)
            self.assertEqual(result["myPlace"], 61)
            self.assertNotIn(me, [row["id"] for row in result["leaders"]])
        scoped = self.call("POST", "/tops", self.me, dict(metric="height", spot="Elsewhere", withMyPlace=True))
        self.assertEqual(scoped, dict(leaders=[], myPlace=None))
        profile = self.call("PUT", "/me", self.me, dict(name="Member", totals=self.totals, premium=True,
                                                        premiumUntil=4e9))["mine"]["profile"]
        self.assertFalse(profile["premium"])
        self.assertFalse(profile["publicProfile"])
        self.assertFalse(profile["statsPublic"])

    def test_message_attachment_private_and_retry_safe(self):
        sender = self.publish(self.me, "rider")["mine"]["id"]
        peer = self.publish(self.audience, "viewer")["mine"]["id"]
        message = str(UUID(int=105))
        outgoing = "/messages/" + peer + "/" + message
        incoming = "/messages/" + sender + "/" + message
        file = {"filename": "Каталка.txt", "contentType": "text/plain", "data": "cmlkZXI="}
        payload = {"text": "", "attachment": file}
        result = self.call("PUT", outgoing, self.me, payload)
        self.assertEqual(result[0]["attachment"], {"filename": "Каталка.txt", "contentType": "text/plain", "size": 5})
        self.assertEqual(self.call("PUT", outgoing, self.me, payload), result)
        self.call("PUT", outgoing, self.me, {"text": "", "attachment": dict(file, data="ZmFrZQ==")}, expect=409)
        self.assertEqual(self.call("GET", incoming + "/attachment", self.audience, raw=True), b"rider")
        self.assertEqual(self.call("GET", outgoing + "/attachment", self.me, raw=True), b"rider")
        self.call("GET", incoming + "/attachment", "f" * 72, expect=404)
        self.call("GET", incoming + "/attachment", self.me, expect=404)
        self.call("PUT", outgoing, self.me, {"text": "", "attachment": dict(file, filename="../secret.txt")}, expect=400)
        binary = b"\xff" * service.MAX_ATTACHMENT_BYTES
        large_file = dict(file, data=base64.b64encode(binary).decode("ascii"))
        second = "/messages/" + peer + "/" + str(UUID(int=106))
        received = self.call("PUT", second, self.me, {"text": "", "attachment": large_file})
        self.assertEqual(received[-1]["attachment"]["size"], len(binary))


if __name__ == "__main__":
    unittest.main()
