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

    def call(self, method, path, token, data=None, expect=200):
        payload = json.dumps(data).encode() if data is not None else b""
        env = dict(REQUEST_METHOD=method, PATH_INFO=path, CONTENT_LENGTH=str(len(payload)))
        env["wsgi.input"] = io.BytesIO(payload)
        env["HTTP_AUTHORIZATION"] = "Bearer " + token
        headers = []
        response = b"".join(service.application(env, lambda status, _: headers.append(status)))
        self.assertEqual(int(headers[0].split()[0]), expect, response)
        return json.loads(response)

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
        self.assertEqual(self.ranking(2027), [])
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
                  rides=[self.ride], totals=self.totals, records=[record], secrets=["height3"])))
        post = str(UUID(int=101))
        path = "/posts/" + post
        self.call("PUT", path, self.me, dict(id=post, caption="Ветер", photo="/9j/2Q=="))
        comment = "/comments/" + str(UUID(int=102))
        row = self.call("PUT", path + comment, self.audience, {"text": "Здорово!"})[0]
        self.assertEqual((row["authorID"], row["username"], row["avatar"]), (viewer["id"], "viewer", "/9j/2Q=="))
        page = self.call("GET", "/riders/rider", self.audience)
        self.assertEqual(page["points"], 165)
        self.assertEqual(page["distance"], 19)
        self.assertEqual(page["rider"]["profile"]["secrets"], ["height3"])
        self.assertEqual(page["posts"][0]["post"]["id"], post)
        self.assertEqual(self.call("GET", "/riders/rider/followers", self.audience)[0]["id"], viewer["id"])
        self.assertEqual(self.call("GET", "/riders/me/following", self.audience)[0]["id"], rider["id"])
        thread = "/messages/" + rider["id"]
        self.call("PUT", thread + "/" + str(UUID(int=103)), self.audience, {"text": "", "postID": post})

        self.call("PATCH", "/me", self.me, {"statsPublic": False})
        self.assertEqual(self.call("GET", "/statistics", self.me)["statsPublic"], False)
        self.stats([], revision=1)
        page = self.call("GET", "/riders/rider", self.audience)
        self.assertNotIn("points", page)
        self.assertNotIn("distance", page)
        self.assertNotIn("secrets", page["rider"]["profile"])
        self.assertEqual(page["rider"]["profile"]["totals"], {"seconds": 0, "sessions": 0, "jumps": 0})
        self.assertEqual(len(page["posts"]), 1)
        self.assertEqual(self.call("POST", "/tops", self.audience, {"metric": "height"}), [])
        self.assertEqual(self.ranking(2026), [])

        self.call("PATCH", "/me", self.me, {"publicProfile": False})
        self.call("PUT", "/me", self.me, dict(name="Renamed", username="rider", totals=self.totals))
        self.assertFalse(self.call("GET", "/me", self.me)["mine"]["profile"]["publicProfile"])
        self.call("GET", "/riders/rider", self.audience, expect=404)
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


if __name__ == "__main__":
    unittest.main()
