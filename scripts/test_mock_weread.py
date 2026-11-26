#!/usr/bin/env python3
"""Run with python3 scripts/test_mock_weread.py; no KOReader or network account."""
import base64
from http.client import RemoteDisconnected
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener
import zipfile

from fetch_weread_epub import decode_content_shards, decode_style_shard, weread_e
from mock_weread import BOOK_ID, CHAPTERS, MockServer, annotation, chapter_html, prepare, shards


class MockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = MockServer(0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.opener = build_opener(ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path, data=None):
        request = Request(self.base + path, data=None if data is None else json.dumps(data).encode(),
                          headers={"Content-Type": "application/json"})
        try:
            response = self.opener.open(request, timeout=3)
        except HTTPError as exc:
            response = exc
        with response:
            body = response.read()
            if response.headers["Content-Type"] == "application/json":
                body = json.loads(body)
            return response.status, body

    def gateway(self, api, **params):
        return self.request("/api/agent/gateway", dict(api_name=api, **params))

    def setUp(self):
        self.request("/__control", dict(delay=0, match="", status=503, times=0, drop=False,
                                        empty_shelf=False, empty_annotations=False, progress_successes_before_failure=-1,
                                        progress_reply="ok", renew_reply="ok", retry_after=0,
                                        read_replies=[]))

    def test_prepare_can_install_an_exact_candidate_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            (runtime / "luajit").write_text("runtime")
            (runtime / "reader.lua").write_text("runtime")
            archive = root / "official.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("weread.koplugin/_meta.lua", 'return { version = "baseline" }\n')
            expected = archive.read_bytes()
            run_dir = root / "run"

            launcher = prepare(run_dir, runtime, 12345, archive)

            self.assertEqual((run_dir / "candidate.zip").read_bytes(), expected)
            self.assertEqual(
                (run_dir / "profile/plugins/weread.koplugin/_meta.lua").read_text(),
                'return { version = "baseline" }\n')
            self.assertEqual(launcher, run_dir / "launch.command")
            self.assertIn("port = 12345", (run_dir / "profile/settings/weread-environment.lua").read_text())

    def test_contract_and_real_reference_decoder(self):
        status, shelf = self.gateway("/shelf/sync")
        self.assertEqual(status, 200)
        self.assertEqual(len(shelf["books"]), 26)
        self.assertEqual(len(shelf["archive"]), 3)
        _, catalog = self.request("/web/book/chapterInfos", dict(bookIds=[BOOK_ID]))
        self.assertEqual(catalog["data"][0]["updated"], CHAPTERS)
        for uid in range(1, 7):
            params = dict(b=weread_e(BOOK_ID), c=weread_e(uid))
            parts = [self.request("/web/book/chapter/" + part, params)[1].decode()
                     for part in ("e_0", "e_1", "e_3")]
            self.assertEqual(decode_content_shards(*parts), chapter_html(uid))
            mark = annotation(uid)
            begin, end = map(int, mark["range"].split("-"))
            self.assertEqual(chapter_html(uid)[begin:end], mark["markText"])
        self.assertIn("line-height", decode_style_shard(self.request("/web/book/chapter/e_2", params)[1].decode()))
        for text in ("", "a", "你好", "🌿" * 31, "abcdef" * 103):
            self.assertEqual(decode_content_shards(*shards(text)), text)

    def test_annotations_and_progress_write_read(self):
        _, result = self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=2)
        mark = result["underlines"][0]
        self.assertIn("metadata", mark)
        self.assertIsNone(mark["metadata"])
        _, thoughts = self.gateway("/book/readreviews", bookId=BOOK_ID, chapterUid=2, reviews=[dict(range=mark["range"])])
        self.assertEqual(thoughts["reviews"][0]["range"], mark["range"])
        self.assertIn("metadata", thoughts["reviews"][0])
        self.assertIsNone(thoughts["reviews"][0]["metadata"])
        self.assertGreater(len(thoughts["reviews"][0]["pageReviews"][0]["review"]["content"]), 100)
        self.request("/web/book/read", dict(b=weread_e(BOOK_ID), c=weread_e(2), ci=2, co=120, pr=25))
        _, progress = self.gateway("/book/getprogress", bookId=BOOK_ID)
        self.assertEqual(progress["book"]["chapterOffset"], 120)

    def test_private_annotation_write_contract_and_delete(self):
        quote = "这是第2章的第1段"
        start = chapter_html(2).index(quote)
        base = dict(bookId=BOOK_ID, chapterUid=2, chapterIdx=2, bookVersion=17,
                    range=f"{start}-{start + len(quote)}")
        bookmark = dict(base, markText=base64.b64encode(quote.encode()).decode(), type=1)
        self.assertEqual(self.request("/web/book/addBookmark", dict(bookmark, range="0-4"))[0], 400)
        self.assertEqual(self.request("/web/book/addBookmark", dict(bookmark, bookVersion=16))[0], 400)
        self.assertEqual(self.request("/web/book/addBookmark", dict(bookmark, markText="%%%"))[0], 400)
        status, added = self.request("/web/book/addBookmark", bookmark)
        self.assertEqual(status, 200)
        # The fixture deliberately does not deduplicate creates: integration
        # tests must prove the product avoids duplicate network mutations.
        _, duplicate = self.request("/web/book/addBookmark", bookmark)
        self.assertNotEqual(added["bookmarkId"], duplicate["bookmarkId"])
        self.request("/web/book/removeBookmark", dict(bookmarkId=duplicate["bookmarkId"]))
        thought = dict(base, abstract=quote, content="合成私密笔记", isPrivate=1, type=1)
        self.assertEqual(self.request("/web/review/add", dict(thought, isPrivate=0))[0], 400)
        status, review = self.request("/web/review/add", thought)
        self.assertEqual(status, 200)
        state = self.request("/__state")[1]
        self.assertEqual(state["bookmarks"][added["bookmarkId"]]["decoded_mark_text"], quote)
        self.assertEqual(state["private_reviews"][review["reviewId"]]["content"], thought["content"])
        self.assertEqual(self.request("/web/book/removeBookmark", dict(bookmarkId=added["bookmarkId"]))[0], 200)
        self.assertEqual(self.request("/web/review/delete", dict(reviewId=review["reviewId"]))[0], 200)
        state = self.request("/__state")[1]
        self.assertNotIn(added["bookmarkId"], state["bookmarks"])
        self.assertNotIn(review["reviewId"], state["private_reviews"])
        self.assertEqual(self.request("/web/review/delete", dict(reviewId="unknown"))[0], 400)

    def test_readonly_progress_probe_and_failure_do_not_mutate(self):
        before = self.request("/__state")[1]
        status, body = self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        self.assertEqual(status, 200)
        self.assertIn("book", body)
        self.request("/__control", dict(match="/web/book/getProgress", times=1, status=503))
        self.assertEqual(self.request("/web/book/getProgress?bookId=" + BOOK_ID)[0], 503)
        after = self.request("/__state")[1]
        for key in ("progress", "read_reports", "annotation_writes", "bookmarks", "private_reviews"):
            self.assertEqual(after[key], before[key])

    def test_readonly_progress_probe_can_drop_transport_without_mutation(self):
        before = self.request("/__state")[1]
        self.request("/__control", dict(
            match="/web/book/getProgress", times=-1, drop=True))
        with self.assertRaises(RemoteDisconnected):
            self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        after = self.request("/__state")[1]
        event = next(event for event in reversed(after["requests"])
                     if event["path"] == "/web/book/getProgress")
        self.assertEqual(event["status"], 599)
        for key in ("progress", "read_reports", "annotation_writes", "bookmarks", "private_reviews"):
            self.assertEqual(after[key], before[key])

    def test_readonly_progress_probe_can_return_expired_login_without_mutation(self):
        before = self.request("/__state")[1]
        self.assertEqual(self.request("/__control", dict(progress_reply="authentication"))[0], 200)
        status, body = self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        self.assertEqual(status, 200)
        self.assertEqual(body["errCode"], -2010)
        status, body = self.gateway("/book/getprogress", bookId=BOOK_ID)
        self.assertEqual(status, 200)
        self.assertEqual(body["errCode"], -2010)
        after = self.request("/__state")[1]
        for key in ("progress", "read_reports", "annotation_writes", "bookmarks", "private_reviews"):
            self.assertEqual(after[key], before[key])

    def test_expired_login_renews_then_requires_a_fresh_probe(self):
        before = self.request("/__state")[1]
        self.request("/__control", dict(progress_reply="expired", renew_reply="ok"))
        status, body = self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        self.assertEqual((status, body["errCode"]), (200, -2012))
        status, body = self.request("/web/login/renewal", dict(rq="%2Fweb%2Fbook%2Fread", ql=False))
        self.assertEqual((status, body["succ"]), (200, 1))
        status, body = self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        self.assertEqual(status, 200)
        self.assertIn("book", body)
        after = self.request("/__state")[1]
        for key in ("progress", "read_reports", "annotation_writes", "bookmarks", "private_reviews"):
            self.assertEqual(after[key], before[key])

    def test_rejected_renewal_leaves_expired_probe_blocked(self):
        self.request("/__control", dict(progress_reply="expired", renew_reply="reject"))
        status, body = self.request("/web/login/renewal", dict(rq="%2Fweb%2Fbook%2Fread", ql=False))
        self.assertEqual((status, body["succ"], body["errCode"]), (200, 0, -2012))
        status, body = self.request("/web/book/getProgress?bookId=" + BOOK_ID)
        self.assertEqual((status, body["errCode"]), (200, -2012))

    def test_successful_probe_followed_by_failed_progress_sources(self):
        before = self.request("/__state")[1]
        self.request("/__control", dict(progress_successes_before_failure=1))
        self.assertEqual(self.request("/web/book/getProgress?bookId=" + BOOK_ID)[0], 200)
        self.assertEqual(self.gateway("/book/getprogress", bookId=BOOK_ID)[0], 503)
        self.assertEqual(self.request("/web/book/getProgress?bookId=" + BOOK_ID)[0], 503)
        after = self.request("/__state")[1]
        self.assertEqual(after["read_reports"], before["read_reports"])
        self.assertEqual(after["annotation_writes"], before["annotation_writes"])
        self.request("/__control", dict(progress_successes_before_failure=-1))
        self.assertEqual(self.gateway("/book/getprogress", bookId=BOOK_ID)[0], 200)
        self.assertEqual(self.request("/web/book/getProgress?bookId=" + BOOK_ID)[0], 200)

    def test_fault_once_delay_and_recovery(self):
        self.request("/__control", dict(match="/book/info", times=1, status=503, delay=0.02))
        start = time.monotonic()
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.02)
        self.assertEqual(self.gateway("/book/info", bookId=BOOK_ID)[0], 200)
        self.assertEqual(self.gateway("/shelf/sync")[0], 200)
        self.request("/__control", dict(empty_shelf=True, empty_annotations=True))
        self.assertEqual(self.gateway("/shelf/sync")[1]["books"], [])
        self.assertEqual(self.gateway("/book/underlines", bookId=BOOK_ID, chapterUid=1)[1]["underlines"], [])

    def test_scripted_read_replies_distinguish_commit_reject_and_lost_reply(self):
        payload = dict(b=weread_e(BOOK_ID), c=weread_e(1), ci=1, co=120, pr=25, rt=30)
        self.assertEqual(self.request("/__control", dict(read_replies=["blank", "reject", "timeout", "drop", "ok"]))[0], 200)
        self.assertEqual(self.request("/web/book/read", payload), (200, {}))
        status, rejected = self.request("/web/book/read", payload)
        self.assertEqual(status, 200)
        self.assertEqual(rejected["succ"], 0)
        self.assertEqual(self.request("/web/book/read", payload)[0], 504)
        with self.assertRaises(RemoteDisconnected):
            self.request("/web/book/read", payload)
        self.assertEqual(self.request("/web/book/read", payload)[1]["succ"], 1)
        state = self.request("/__state")[1]
        self.assertEqual([item["reply"] for item in state["read_reports"][-4:]], ["blank", "timeout", "drop", "ok"])
        self.assertEqual(state["control"]["read_replies"], [])

    def test_read_reply_control_is_bounded_and_ignores_zero_time_progress(self):
        self.assertEqual(self.request("/__control", dict(read_replies=["unknown"]))[0], 400)
        self.assertEqual(self.request("/__control", dict(read_replies=["blank"] * 21))[0], 400)
        self.assertEqual(self.request("/__control", dict(read_replies=["reject"]))[0], 200)
        payload = dict(b=weread_e(BOOK_ID), c=weread_e(1), ci=1, co=120, pr=25, rt=0)
        self.assertEqual(self.request("/web/book/read", payload)[1]["succ"], 1)
        self.assertEqual(self.request("/__state")[1]["control"]["read_replies"], ["reject"])

    def test_read_events_measure_ack_timing_and_concurrency(self):
        before = self.request("/__state")[1]
        previous_id = max((event.get("request_id") or 0 for event in before["requests"]), default=0)
        self.request("/__control", dict(
            delay=0.02, match="/web/book/read", read_replies=["ok", "ok"]))
        payload = dict(b=weread_e(BOOK_ID), c=weread_e(1), ci=1,
                       co=120, pr=25, rt=13)
        self.assertEqual(self.request("/web/book/read", payload)[1]["succ"], 1)
        self.assertEqual(self.request("/web/book/read", payload)[1]["succ"], 1)
        state = self.request("/__state")[1]
        events = [event for event in state["requests"]
                  if (event.get("request_id") or 0) > previous_id
                  and event["path"] == "/web/book/read"]
        self.assertEqual(len(events), 2)
        self.assertTrue(all(event["rt"] == 13 for event in events))
        self.assertTrue(all(event["duration_ms"] >= 15 for event in events))
        self.assertTrue(all(event["read_write_concurrency"] == 1 for event in events))
        self.assertLessEqual(events[0]["completed_at"], events[1]["started_at"])
        self.assertEqual(state["active_read_writes"], 0)
        self.assertGreaterEqual(state["max_read_write_concurrency"], 1)

    def test_rate_limit_can_supply_retry_after(self):
        self.request("/__control", dict(
            match="/web/book/read", retry_after=2,
            read_replies=["rate_limited", "ok"]))
        payload = dict(b=weread_e(BOOK_ID), c=weread_e(1), ci=1,
                       co=120, pr=25, rt=11)
        request = Request(self.base + "/web/book/read",
                          data=json.dumps(payload).encode(),
                          headers={"Content-Type": "application/json"})
        with self.assertRaises(HTTPError) as limited:
            self.opener.open(request, timeout=3)
        self.assertEqual(limited.exception.code, 429)
        self.assertEqual(limited.exception.headers["Retry-After"], "2")
        self.assertEqual(self.request("/web/book/read", payload)[1]["succ"], 1)

    def test_unknown_routes_and_malformed_control_fail(self):
        with self.assertRaises(ValueError):
            MockServer(0, bind="8.8.8.8")
        lan_server = MockServer(0, bind="0.0.0.0")
        self.assertEqual(lan_server.server_address[0], "0.0.0.0")
        lan_server.server_close()
        self.assertEqual(self.request("/unknown")[0], 501)
        self.assertEqual(self.request("/__proxy?url=https%3A%2F%2Fexample.invalid%2Fx")[0], 501)
        self.assertEqual(self.gateway("/unknown")[0], 501)
        self.assertEqual(self.gateway("/book/info", bookId="unknown")[0], 400)
        self.assertEqual(self.gateway("/book/underlines", chapterUid=1)[0], 400)
        self.assertEqual(self.request("/web/book/chapterInfos", dict(bookIds=["unknown"]))[0], 400)
        self.assertEqual(self.request("/__control", dict(delay=-1))[0], 400)
        self.assertEqual(self.request("/__control", dict(times="forever"))[0], 400)
        self.assertEqual(self.request("/__control", dict(progress_reply="unknown"))[0], 400)
        self.assertEqual(self.request("/__control", dict(renew_reply="unknown"))[0], 400)
        self.assertEqual(self.request("/__control", dict(drop="yes"))[0], 400)
        self.assertEqual(self.request("/__control", dict(unknown=True))[0], 400)
        self.assertEqual(self.request("/web/book/chapter/e_0", dict(b="unknown", c="bad"))[0], 400)
        self.assertEqual(self.request("/__control", [1, 2])[0], 400)
        self.assertEqual(self.request("/__proxy?url=http%3A%2F%2F%5Bbad")[0], 400)
        _, state = self.request("/__state")
        self.assertTrue(any(event["status"] == 501 for event in state["requests"]))
        self.assertTrue(all("headers" not in event for event in state["requests"]))


if __name__ == "__main__":
    unittest.main()
