#!/usr/bin/env python3
"""Synthetic WeRead HTTP server and isolated KOReader launcher (stdlib only).

No upstream requests. Unknown routes fail with HTTP 501. This models the
contracts consumed by this plugin, not authentication or the real service.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
import hashlib
import ipaddress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import posixpath
import shlex
import shutil
import struct
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlsplit
import xml.etree.ElementTree as ET
import zipfile
import zlib

from fetch_weread_epub import swap_positions, weread_e

REPO = Path(__file__).resolve().parent.parent
BOOK_ID = "900001"
DROP_RESPONSE = object()
TITLES = ["启程", "雨中的小站", "山间来信", "海边的夜晚", "重逢", "归途"]
QUOTE = "窗外的风穿过树梢，带来远处山谷的回声。"
BOOKS = [dict(bookId=str(900001 + i), title=("山谷来信 · 离线测试" if i == 0 else f"合成读物 {i:02d}：用于长标题与分页验证"),
              author="测试作者", cover="https://weread.qq.com/mock/cover.png",
              category="文学", intro="自写合成内容，用于 KOReader 集成测试。", wordCount=12000,
              totalChapter=6, bookVersion=17, type=0, updateTime=1700000000 + i) for i in range(26)]
CHAPTERS = [dict(chapterUid=i, chapterIdx=i, title=f"第{i}章 {title}", level=1,
                 wordCount=1800) for i, title in enumerate(TITLES, 1)]


def chapter_html(uid):
    heading = CHAPTERS[uid - 1]["title"]
    paragraphs = [f"<p>{QUOTE}这是第{uid}章的第{i}段。我们沿着小路慢慢前行，"
                  "记下沿途的灯光、溪水和陌生人的问候。每一次翻页，都能看见新的文字。</p>"
                  for i in range(1, 19)]
    return ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            f'<head><title>{heading}</title></head><body><h1>{heading}</h1>'
            + "\n".join(paragraphs)
            + '<p>脚注验证<a href="#note1" epub:type="noteref">[1]</a></p>'
              '<aside id="note1" epub:type="footnote"><p>这是自写的原书脚注。</p></aside>'
              '<p><img src="https://weread.qq.com/mock/illustration.png" alt="合成插图"/></p>'
              '</body></html>')


def annotation(uid):
    source = chapter_html(uid)
    start = source.index(QUOTE)
    return dict(range=f"{start}-{start + len(QUOTE)}", markText=QUOTE, count=12, metadata=None)


def shards(text, count=3):
    """Inverse of the existing decoder; real Client still checks MD5 and decodes."""
    encoded = base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")
    chars = list(encoded)
    positions = swap_positions(encoded)
    for i in range(0, len(positions), 2):
        for k in (0, 1):
            a, b = positions[i] + k, positions[i + 1] + k
            chars[a], chars[b] = chars[b], chars[a]
    body = "0" + "".join(chars)
    parts = [body[len(body) * i // count:len(body) * (i + 1) // count] for i in range(count)]
    return [hashlib.md5(part.encode()).hexdigest().upper() + part for part in parts]


def png():
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + bytes((60 + y, 120, 90)) * 64 for y in range(96))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 64, 96, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def review(uid=1):
    return dict(reviewId=f"mock-review-{uid}", author={"nick": "合成读者"}, abstract=QUOTE,
                content=("这是一条合成想法，用来检查中文、换行与长文本翻页。🌿\n" * 18),
                createTime=1700000000, likesCount=7, commentsCount=2, star=90)


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port=8765, log_path=None, bind="127.0.0.1"):
        address = ipaddress.IPv4Address(bind)
        if bind != "0.0.0.0" and not any(address in ipaddress.IPv4Network(network) for network in
                                          ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")):
            raise ValueError("bind must be a LAN/loopback IPv4 address or 0.0.0.0")
        super().__init__((bind, port), Handler)
        self.lock = threading.Lock()
        self.log_path = log_path
        # Full-scale replay acceptance emits several context requests per row.
        # Retain the complete 190-row trace so timing and conservation checks
        # do not silently inspect only the tail of the run.
        self.events = deque(maxlen=5000)
        self.progress = {}
        self.read_reports = []
        self.bookmarks = {}
        self.private_reviews = {}
        self.annotation_writes = []
        self.next_annotation_id = 1
        self.next_request_id = 1
        self.active_read_writes = 0
        self.max_read_write_concurrency = 0
        self.control = dict(delay=0, match="", status=503, times=0,
                            empty_shelf=False, empty_annotations=False, progress_successes_before_failure=-1,
                            progress_reply="ok", renew_reply="ok", retry_after=0,
                            read_replies=[])

    def record(self, event):
        with self.lock:
            self.events.append(event)
            if self.log_path:
                with self.log_path.open("a") as out:
                    out.write(json.dumps(event, ensure_ascii=False) + "\n")

    def begin_request(self, method, target):
        path = urlsplit(target).path
        is_read_write = method == "POST" and path == "/web/book/read"
        with self.lock:
            request_id = self.next_request_id
            self.next_request_id += 1
            if is_read_write:
                self.active_read_writes += 1
                self.max_read_write_concurrency = max(
                    self.max_read_write_concurrency, self.active_read_writes)
            concurrency = self.active_read_writes
        return request_id, is_read_write, concurrency

    def finish_measured_request(self, is_read_write):
        if not is_read_write:
            return
        with self.lock:
            self.active_read_writes -= 1

    def route(self, method, target, data):
        url = urlsplit(target)
        path = url.path
        if url.hostname not in {"weread.qq.com", "i.weread.qq.com"}:
            raise LookupError("host is not implemented")
        query = parse_qs(url.query)
        api = data.get("api_name", "") if path == "/api/agent/gateway" else ""
        with self.lock:
            control = self.control.copy()
            matches = not control["match"] or control["match"] in (api or path)
            fail = matches and control["times"] != 0
            if fail and control["times"] > 0:
                self.control["times"] -= 1
            progress_read = (method == "GET" and path == "/web/book/getProgress") or api == "/book/getprogress"
            progress_budget = control["progress_successes_before_failure"]
            if progress_read and not fail and progress_budget >= 0:
                if progress_budget == 0:
                    fail = True
                else:
                    self.control["progress_successes_before_failure"] -= 1
        if matches:
            time.sleep(control["delay"])
        if fail:
            headers = {}
            if control["status"] == 429 and control["retry_after"] > 0:
                headers["Retry-After"] = str(control["retry_after"])
            return control["status"], dict(
                errcode=-1, errmsg="Injected mock failure"), headers

        book_id = str(data.get("bookId") or query.get("bookId", [BOOK_ID])[0])
        if progress_read and control["progress_reply"] in {"authentication", "expired"}:
            code = -2010 if control["progress_reply"] == "authentication" else -2012
            return 200, dict(errCode=code, errMsg="login expired")
        if path == "/web/login/renewal" and method == "POST":
            if control["renew_reply"] == "reject":
                return 200, dict(succ=0, errCode=-2012, errMsg="login expired")
            with self.lock:
                if self.control["progress_reply"] == "expired":
                    self.control["progress_reply"] = "ok"
            return 200, dict(succ=1), {
                "Set-Cookie": "wr_skey=XXX-mock-renewed; Path=/",
                "x-wr-ticket": "mock-renewed-ticket",
            }
        if path == "/api/agent/gateway" and method == "POST":
            if api in {"/book/info", "/book/getprogress", "/review/list", "/book/underlines", "/book/readreviews"}:
                if "bookId" not in data or not any(b["bookId"] == book_id for b in BOOKS):
                    raise ValueError("missing or unknown bookId")
            if api == "/shelf/sync":
                return 200, dict(books=[] if control["empty_shelf"] else BOOKS, archive=[
                    dict(archiveId=1, name="旅途", bookIds=[b["bookId"] for b in BOOKS[:15]]),
                    dict(archiveId=2, name="待读", bookIds=[b["bookId"] for b in BOOKS[15:]]),
                    dict(archiveId=3, name="空分组", bookIds=[])])
            if api == "/book/info":
                return 200, next(b for b in BOOKS if b["bookId"] == book_id)
            if api == "/store/search":
                keyword = data.get("keyword", "")
                return 200, dict(results=[dict(books=[dict(bookInfo=b) for b in BOOKS
                                                      if keyword in b["title"] or keyword in b["author"]])])
            if api == "/book/getprogress":
                return 200, self.get_progress(book_id)
            if api == "/review/list":
                return 200, dict(reviewsCnt=1, reviewsHasMore=0, reviews=[dict(review=review())])
            if api in {"/book/underlines", "/book/readreviews"}:
                uid = int(data["chapterUid"])
                if not 1 <= uid <= len(CHAPTERS):
                    raise ValueError("unknown chapterUid")
                mark = annotation(uid)
                if api == "/book/underlines":
                    return 200, dict(chapterUid=uid, underlines=[] if control["empty_annotations"] else [mark])
                return 200, dict(reviews=[] if control["empty_annotations"] else [
                    dict(range=item["range"], metadata=None, pageReviews=[dict(review=review(uid))])
                    for item in data.get("reviews", []) if item["range"] == mark["range"]])
        if path.startswith("/web/reader/") and method == "GET":
            encoded = path.rsplit("/", 1)[1].split("k")
            book = next(b for b in BOOKS if weread_e(b["bookId"]) == encoded[0])
            chapter = next((c for c in CHAPTERS if len(encoded) > 1 and weread_e(c["chapterUid"]) == encoded[1]), CHAPTERS[0])
            state = dict(reader=dict(bookInfo=book, psvts="mock-session", pclts="mock-clock",
                                     currentChapter=chapter, progress=self.get_progress(book["bookId"])))
            return 200, "<script>window.__INITIAL_STATE__=" + json.dumps(state, ensure_ascii=False) + ";(function(){})();</script>"
        if path == "/web/book/chapterInfos" and method == "POST":
            if not isinstance(data.get("bookIds"), list) or not data["bookIds"] or any(
                not any(b["bookId"] == str(book_id) for b in BOOKS) for book_id in data["bookIds"]
            ):
                raise ValueError("missing or unknown bookIds")
            return 200, dict(data=[dict(bookId=str(b), updated=CHAPTERS) for b in data["bookIds"]])
        if path.startswith("/web/book/chapter/") and method == "POST":
            if not any(weread_e(b["bookId"]) == data.get("b") for b in BOOKS):
                raise ValueError("unknown encoded book")
            uid = next(c["chapterUid"] for c in CHAPTERS if weread_e(c["chapterUid"]) == data["c"])
            part = path.rsplit("/", 1)[1]
            if part == "e_2":
                return 200, shards("p { line-height: 1.5; } img { max-width: 100%; }", 1)[0]
            if part in {"e_0", "e_1", "e_3"}:
                return 200, shards(chapter_html(uid))[["e_0", "e_1", "e_3"].index(part)]
        if path in {"/web/book/addBookmark", "/web/review/add"} and method == "POST":
            uid = int(data["chapterUid"])
            if not 1 <= uid <= len(CHAPTERS) or book_id not in {b["bookId"] for b in BOOKS}:
                raise ValueError("unknown annotation book/chapter")
            if data.get("bookVersion") != 17 or data.get("chapterIdx") != uid:
                raise ValueError("annotation edition/chapter mismatch")
            bounds = data.get("range", "").split("-")
            if len(bounds) != 2 or not all(part.isdigit() for part in bounds):
                raise ValueError("annotation range must be half-open rune offsets")
            start, end = map(int, bounds)
            source = chapter_html(uid)
            if not 0 <= start < end <= len(source):
                raise ValueError("annotation range out of bounds")
            is_review = path == "/web/review/add"
            if is_review:
                if data.get("isPrivate") != 1 or not isinstance(data.get("content"), str):
                    raise ValueError("only private text reviews are accepted")
                quote = data.get("abstract")
            else:
                try:
                    quote = base64.b64decode(data["markText"], validate=True).decode("utf-8")
                except (ValueError, UnicodeError) as exc:
                    raise ValueError("invalid bookmark base64") from exc
            if source[start:end] != quote:
                raise ValueError("annotation range does not match original markText")
            with self.lock:
                identifier = ("review-" if is_review else "bookmark-") + str(self.next_annotation_id)
                self.next_annotation_id += 1
                record = dict(data, decoded_mark_text=quote)
                (self.private_reviews if is_review else self.bookmarks)[identifier] = record
                self.annotation_writes.append(dict(path=path, id=identifier, payload=record))
            return 200, {"reviewId" if is_review else "bookmarkId": identifier, "succ": 1}
        if path in {"/web/book/removeBookmark", "/web/review/delete"} and method == "POST":
            is_review = path == "/web/review/delete"
            identifier = data["reviewId" if is_review else "bookmarkId"]
            with self.lock:
                records = self.private_reviews if is_review else self.bookmarks
                if identifier not in records:
                    raise ValueError("unknown annotation id")
                del records[identifier]
                self.annotation_writes.append(dict(path=path, id=identifier, payload=dict(data)))
            return 200, dict(succ=1)
        if path == "/web/review/single" and method == "GET":
            return 200, dict(review=review(), comments=[
                dict(commentId=f"mock-comment-{i}", content=f"合成回复 {i}", author={"nick": "测试读者"}, createTime=1700000000)
                for i in range(1, 3)], commentsHasMore=0)
        if path == "/web/book/getProgress" and method == "GET":
            return 200, self.get_progress(book_id)
        if path == "/web/book/read" and method == "POST":
            book_id = next(b["bookId"] for b in BOOKS if weread_e(b["bookId"]) == data["b"])
            uid = next(c["chapterUid"] for c in CHAPTERS if weread_e(c["chapterUid"]) == data["c"])
            reply = "ok"
            with self.lock:
                if data.get("rt", 0) > 0 and self.control["read_replies"]:
                    reply = self.control["read_replies"].pop(0)
                if reply == "reject":
                    return 200, dict(succ=0, errCode=4001, errMsg="Injected reading-time rejection")
                if reply == "rate_limited":
                    headers = {}
                    if control["retry_after"] > 0:
                        headers["Retry-After"] = str(control["retry_after"])
                    return 429, dict(errcode=-1, errmsg="Injected rate limit"), headers
                self.read_reports.append(dict(bookId=book_id, chapterUid=uid, rt=data.get("rt", 0),
                                              chapterOffset=data["co"], progress=data["pr"], reply=reply))
                self.progress[book_id] = dict(chapterUid=uid, chapterIdx=data["ci"],
                                              chapterOffset=data["co"], progress=data["pr"], summary=data.get("sm", ""))
            if reply == "blank":
                return 200, {}
            if reply == "timeout":
                return 504, dict(errcode=-1, errmsg="Injected timeout after commit")
            if reply == "drop":
                return 200, DROP_RESPONSE
            return 200, dict(succ=1)
        if path in {"/mock/cover.png", "/mock/illustration.png"} and method == "GET":
            return 200, png()
        raise LookupError("route is not implemented")

    def get_progress(self, book_id):
        with self.lock:
            return dict(book=self.progress.get(book_id, dict(chapterUid=1, chapterIdx=1,
                                                             chapterOffset=0, progress=0, summary="" )).copy())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Structured log below deliberately excludes credentials and headers.

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        target = self.path
        data = {}
        response_headers = {}
        request_id = None
        read_write = False
        concurrency = 0
        started_at = time.monotonic()
        try:
            size = int(self.headers.get("Content-Length", 0))
            if not 0 <= size <= 1024 * 1024:
                raise ValueError("request too large")
            data = json.loads(self.rfile.read(size)) if size else {}
            if not isinstance(data, dict):
                data = {}
                raise ValueError("request JSON must be an object")
            path = urlsplit(self.path)
            if path.path == "/health" and self.command == "GET":
                status, result = 200, dict(service="weread-mock", fixture_version=1)
            elif path.path == "/__state" and self.command == "GET":
                with self.server.lock:
                    status, result = 200, dict(control=self.server.control.copy(), requests=list(self.server.events), progress=self.server.progress.copy(),
                                              bookmarks=self.server.bookmarks.copy(), private_reviews=self.server.private_reviews.copy(),
                                              annotation_writes=list(self.server.annotation_writes), read_reports=list(self.server.read_reports),
                                              active_read_writes=self.server.active_read_writes,
                                              max_read_write_concurrency=self.server.max_read_write_concurrency)
            elif path.path == "/__control" and self.command == "POST":
                self.set_control(data)
                status, result = 200, dict(ok=True)
            else:
                if path.path == "/__proxy":
                    target = parse_qs(path.query)["url"][0]
                else:
                    target = "https://weread.qq.com" + self.path
                request_id, read_write, concurrency = self.server.begin_request(
                    self.command, target)
                try:
                    routed = self.server.route(self.command, target, data)
                finally:
                    self.server.finish_measured_request(read_write)
                status, result = routed[:2]
                if len(routed) > 2:
                    response_headers = routed[2]
        except (ValueError, KeyError, TypeError, StopIteration) as exc:
            status, result = 400, dict(errcode=-1, errmsg="Invalid mock request: " + str(exc))
        except LookupError as exc:
            status, result = 501, dict(errcode=-1, errmsg="Unimplemented mock route: " + str(exc))
        try:
            parsed = urlsplit(target)
        except ValueError:
            parsed = urlsplit("")
        completed_at = time.monotonic()
        self.server.record(dict(method=self.command, host=parsed.hostname, path=parsed.path,
                                api=data.get("api_name"), book=data.get("bookId"), chapter=data.get("chapterUid"),
                                encoded_chapter=data.get("c"), rt=data.get("rt"), status=status,
                                request_id=request_id, started_at=started_at,
                                completed_at=completed_at,
                                duration_ms=round((completed_at - started_at) * 1000, 3),
                                read_write_concurrency=concurrency))
        if result is DROP_RESPONSE:
            self.close_connection = True
            return
        if isinstance(result, bytes):
            content_type, body = "image/png", result
        elif isinstance(result, str):
            content_type, body = "text/plain; charset=utf-8", result.encode()
        else:
            content_type, body = "application/json", json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in response_headers.items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the real downloader cancels a delayed request.

    def set_control(self, data):
        with self.server.lock:
            candidate = self.server.control | data
            if set(candidate) != set(self.server.control):
                raise ValueError("unknown control key")
            if type(candidate["delay"]) not in (float, int) or not 0 <= candidate["delay"] <= 60:
                raise ValueError("delay must be 0..60 seconds")
            if type(candidate["times"]) is not int or candidate["times"] < -1:
                raise ValueError("times must be -1 (always) or a non-negative integer")
            if type(candidate["progress_successes_before_failure"]) is not int or candidate["progress_successes_before_failure"] < -1:
                raise ValueError("progress_successes_before_failure must be -1 or a non-negative integer")
            if candidate["progress_reply"] not in {"ok", "authentication", "expired"}:
                raise ValueError("progress_reply must be ok, authentication or expired")
            if candidate["renew_reply"] not in {"ok", "reject"}:
                raise ValueError("renew_reply must be ok or reject")
            if type(candidate["status"]) is not int or not 400 <= candidate["status"] <= 599:
                raise ValueError("status must be 400..599")
            if type(candidate["retry_after"]) not in (float, int) or not 0 <= candidate["retry_after"] <= 60:
                raise ValueError("retry_after must be 0..60 seconds")
            if not isinstance(candidate["match"], str):
                raise ValueError("match must be a string")
            for key in ("empty_shelf", "empty_annotations"):
                if type(candidate[key]) is not bool:
                    raise ValueError(key + " must be boolean")
            if not isinstance(candidate["read_replies"], list) or len(candidate["read_replies"]) > 20:
                raise ValueError("read_replies must be a list of at most 20 reply modes")
            if any(reply not in {"ok", "blank", "reject", "rate_limited", "timeout", "drop"} for reply in candidate["read_replies"]):
                raise ValueError("read_replies contains an unknown reply mode")
            self.server.control = dict(candidate, read_replies=list(candidate["read_replies"]))


def prepare(run_dir, runtime, port):
    """Fresh directory only: never read or overwrite the user's KOReader profile."""
    if not (runtime / "luajit").is_file() or not (runtime / "reader.lua").is_file():
        raise ValueError("--koreader must point to the built runtime containing luajit and reader.lua")
    if (runtime / "plugins/weread.koplugin").exists() or (runtime / "plugins/weread.koplugin").is_symlink():
        raise ValueError("remove the duplicate runtime/plugins/weread.koplugin installation first")
    run_dir.mkdir(parents=True, exist_ok=False)
    profile = run_dir / "profile"
    for name in ("settings", "plugins"):
        (profile / name).mkdir(parents=True)
    (run_dir / "books").mkdir()
    (run_dir / "evidence").mkdir()
    archive = run_dir / "candidate.zip"
    subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(archive)], check=True)
    with zipfile.ZipFile(archive) as package:
        package.extractall(profile / "plugins")
    (run_dir / "evidence/package.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  candidate.zip\n")
    (run_dir / "evidence/build.json").write_text(json.dumps(dict(
        fixture_version=1, plugin_sha=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        workspace_status=subprocess.check_output(["git", "status", "--short"], cwd=REPO, text=True),
        runtime=str(runtime), ko_home=str(profile),
    ), ensure_ascii=False, indent=2) + "\n")
    (profile / "settings.reader.lua").write_text('return { language = "zh_CN", color_rendering = false, auto_save_settings_interval_minutes = 0 }\n')
    (profile / "settings/weread-environment.lua").write_text(
        f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n')
    (run_dir / "books/开始测试.html").write_text('<html><head><meta charset="utf-8"/></head><body><h1>本地微信读书测试</h1><p>按 F1 → 工具 → 微信读书 → 我的书架。</p></body></html>')
    bootstrap = profile / "launch.lua"
    bootstrap.write_text('require("setupkoenv")\ndofile("reader.lua")\n')
    launcher = run_dir / "launch.command"
    launcher.write_text("#!/bin/sh\nset -eu\n" + "\n".join(f"export {key}={shlex.quote(str(value))}" for key, value in {
        "KO_HOME": profile,
        "EMULATE_READER": 1, "EMULATE_READER_W": 600, "EMULATE_READER_H": 800, "EMULATE_READER_DPI": 167,
    }.items()) + f"\ncd {shlex.quote(str(runtime))}\nexec ./luajit {shlex.quote(str(bootstrap))} {shlex.quote(str(run_dir / 'books'))} > {shlex.quote(str(run_dir / 'evidence/runtime.log'))} 2>&1\n")
    launcher.chmod(0o755)
    app = run_dir / "WeReadMock.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    shutil.copyfile(launcher, app / "MacOS/WeReadMock")
    (app / "MacOS/WeReadMock").chmod(0o755)
    (app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable="WeReadMock", CFBundleIdentifier="local.weread.mock", CFBundleName="WeRead Mock", CFBundlePackageType="APPL", NSHighResolutionCapable=True)))
    return launcher


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--bind", default="127.0.0.1", help="listen address; use 0.0.0.0 for Kindle on the same LAN")
    parser.add_argument("--run-dir", type=Path, help="create a NEW isolated candidate installation")
    parser.add_argument("--koreader", type=Path, help="built KOReader runtime directory (not source root)")
    parser.add_argument("--log", type=Path, help="JSONL request log, without headers or private data")
    parser.add_argument("--smoke", action="store_true", help="run real KOReader offscreen smoke, save evidence, then exit")
    parser.add_argument("--scenario", choices=("basic", "covers", "delivery", "menu", "pending", "preparation", "continuous", "offline", "reading", "replay", "unified", "chunks"), default="basic",
                        help="offscreen integration scenario (requires --smoke)")
    args = parser.parse_args()
    if bool(args.run_dir) != bool(args.koreader):
        parser.error("--run-dir and --koreader must be provided together")
    if args.scenario != "basic" and not args.smoke:
        parser.error("--scenario requires --smoke")
    if args.smoke and not args.run_dir:
        parser.error("--smoke requires a fresh --run-dir and --koreader")
    if args.run_dir and args.bind not in ("127.0.0.1", "0.0.0.0"):
        parser.error("local launcher requires --bind 127.0.0.1 or 0.0.0.0; use --bind LAN_IP without --run-dir for a device-only server")
    server = MockServer(args.port, args.log, args.bind)
    if args.run_dir:
        args.run_dir = args.run_dir.resolve()
        launcher = prepare(args.run_dir, args.koreader.resolve(), server.server_port)
        server.log_path = args.run_dir / "evidence/requests.jsonl"
        print(f"Launch: {launcher}", flush=True)
    print(f"Mock server: http://{args.bind}:{server.server_port} (Ctrl-C to stop)", flush=True)
    if args.smoke:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ | dict(KO_HOME=str(args.run_dir / "profile"),
                                EMULATE_READER="1", EMULATE_READER_W="600", EMULATE_READER_H="800", EMULATE_READER_DPI="167", KO_DYLD_PREFIX=str(args.koreader.resolve()))
        log = args.run_dir / "evidence/smoke.log"
        try:
            smoke_timeout = 360 if (args.scenario == "replay"
                                    and os.environ.get("WEREAD_REPLAY_SCALE") == "190") else 180
            with log.open("w") as out:
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / {"basic": "weread_mock_smoke.lua", "covers": "weread_covers_mock.lua", "delivery": "weread_delivery_mock.lua", "menu": "weread_menu_consistency.lua", "pending": "weread_pending_diagnostics.lua", "preparation": "weread_preparation_mock.lua", "continuous": "weread_continuous_mock.lua", "offline": "weread_offline_mock.lua", "reading": "weread_reading_mock.lua", "replay": "weread_replay_pacing.lua", "unified": "weread_unified_mock.lua", "chunks": "weread_chunks_mock.lua"}[args.scenario])],
                                        cwd=args.koreader, env=env, stdout=out, stderr=subprocess.STDOUT,
                                        timeout=smoke_timeout)
            if result.returncode == 0 and args.scenario == "basic":
                full_books = list((args.run_dir / "profile/weread-mock/cache").rglob("* - full.epub"))
                assert len(full_books) == 1, "expected one completed full EPUB"
                with zipfile.ZipFile(full_books[0]) as epub:
                    assert epub.testzip() is None, "corrupt EPUB"
                    pages = [epub.read(name).decode() for name in epub.namelist() if name.startswith("OEBPS/text/") and name.endswith(".xhtml")]
                    for uid in range(1, 7):
                        assert any(f"这是第{uid}章的第1段" in page for page in pages), f"missing chapter {uid}"
                    assert any("images/" in name for name in epub.namelist()), "missing image asset"
            if result.returncode == 0 and args.scenario == "preparation":
                books = list((args.run_dir / "profile/weread-mock/cache").glob("*/*.epub"))
                assert len(books) == 1, "expected one visible EPUB"
                with zipfile.ZipFile(books[0]) as epub:
                    assert epub.testzip() is None
                    for uid in range(1, 7):
                        assert f"这是第{uid}章" in epub.read(f"OEBPS/text/chapter-{uid}.xhtml").decode()
                events = [json.loads(line) for line in server.log_path.read_text().splitlines()]
                chunks = [e["encoded_chapter"] for e in events if e["path"] == "/web/book/chapter/e_0"]
                assert chunks == [weread_e(i) for i in (1, 5, 3, 4, 2, 6)], chunks
                offline_at = next(i for i, e in enumerate(events) if e["path"] == "/__control")
                assert not any(e["path"].startswith("/web/book/chapter") for e in events[offline_at + 1:])
            if result.returncode == 0 and args.scenario == "continuous":
                books = list((args.run_dir / "profile/weread-mock/cache").glob("*/* - offline.epub"))
                assert len(books) == 1, "expected one continuous EPUB"
                images = []
                with zipfile.ZipFile(books[0]) as epub:
                    assert epub.testzip() is None, "corrupt continuous EPUB"
                    names = epub.namelist()
                    for name in names:
                        if name.startswith("OEBPS/text/") and name.endswith(".xhtml"):
                            for element in ET.fromstring(epub.read(name)).iter():
                                if element.tag.split("}")[-1] == "img":
                                    target = posixpath.normpath(posixpath.join(posixpath.dirname(name), element.attrib["src"]))
                                    assert target in names, "missing chapter image: " + target
                                    images.append(target)
                assert len(images) >= 3, "expected images from at least three chapters"
                events = [json.loads(line) for line in server.log_path.read_text().splitlines()]
                offline_at = next(i for i, event in enumerate(events) if event["path"] == "/__control")
                assert not events[offline_at + 1:], "offline return unexpectedly used HTTP"
                (args.run_dir / "evidence/archive-check.json").write_text(json.dumps(dict(
                    valid_zip=True, image_references=images, offline_requests=0), indent=2))
            print(("PASS" if result.returncode == 0 else "FAIL") + f": {log}")
            raise SystemExit(result.returncode)
        finally:
            with server.lock:
                (args.run_dir / "evidence/server-state.json").write_text(json.dumps(dict(
                    bookmarks=server.bookmarks, private_reviews=server.private_reviews,
                    annotation_writes=server.annotation_writes, progress=server.progress,
                    read_reports=server.read_reports,
                    max_read_write_concurrency=server.max_read_write_concurrency), ensure_ascii=False, indent=2))
            server.shutdown()
            server.server_close()
            thread.join()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
