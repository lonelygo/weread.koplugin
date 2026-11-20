#!/usr/bin/env python3
"""Run with python3 scripts/test_mock_weread.py; no KOReader or network account."""
import base64
import json
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from fetch_weread_epub import decode_content_shards, decode_style_shard, weread_e
from mock_weread import BOOK_ID, CHAPTERS, MockServer, annotation, chapter_html, shards


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
        self.request("/__control", dict(delay=0, match="", status=503, times=0,
                                        empty_shelf=False, empty_annotations=False))

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
        self.assertEqual(self.request("/__control", dict(unknown=True))[0], 400)
        self.assertEqual(self.request("/web/book/chapter/e_0", dict(b="unknown", c="bad"))[0], 400)
        self.assertEqual(self.request("/__control", [1, 2])[0], 400)
        self.assertEqual(self.request("/__proxy?url=http%3A%2F%2F%5Bbad")[0], 400)
        _, state = self.request("/__state")
        self.assertTrue(any(event["status"] == 501 for event in state["requests"]))
        self.assertTrue(all("headers" not in event for event in state["requests"]))


if __name__ == "__main__":
    unittest.main()
