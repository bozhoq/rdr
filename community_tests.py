import io
import json
import os
import tempfile
import unittest
from datetime import datetime
from unittest.mock import patch
from uuid import UUID

import rider_community as service


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
        self.assertEqual(len(self.call("GET", "/messages", self.me)), 1)
        self.call("DELETE", path, self.me)
        self.assertEqual(self.call("GET", "/feed/my-reposts", self.audience), [])


if __name__ == "__main__":
    unittest.main()
