-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
local catalog_fetch_count = 0
local reader_book_version
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
        ensure_reader_state = function(_client, book)
            book.psvts = "fresh-session"
            book.pclts = "fresh-clock"
            book.book_version = reader_book_version or book.book_version
            return {}
        end,
        fetch_catalog = function(_client, book)
            catalog_fetch_count = catalog_fetch_count + 1
            book.chapters = cached_catalog
            return cached_catalog
        end,
        first_readable_chapter = function(chapters)
            return chapters and chapters[1]
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
        classify_response_error = function(value)
            local code = type(value) == "table"
                and tonumber(value.errCode or value.errcode) or nil
            if code == -2010 or code == -2012 then return "authentication" end
            if code and code ~= 0 then return "rejected" end
            if type(value) == "table" and value.succ ~= nil
                and tonumber(value.succ) ~= 1 then return "rejected" end
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function fixture(provider)
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
        is_api_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
        get_progress = function()
            return { book = { bookId = "book", progress = 25,
                chapterUid = 22, chapterIdx = 2, chapterOffset = 150 } }
        end,
        get_web_progress = function()
            return { book = { bookId = "book", progress = 25,
                chapterUid = 22, chapterIdx = 2, chapterOffset = 150 } }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("a refused session entry preserves elapsed time for a future login", function()
    local report = fixture()
    local requests = {}
    report.client.report_read = function(_client, payload)
        requests[#requests + 1] = payload.kind
        return { succ = 0 }, 401
    end
    local book = { book_id = "book", chapter_uid = 11 }
    report.ensure_context = function() return book end
    local result = report:_run_pipeline("book", { elapsed_seconds = 30 })
    eq(table.concat(requests, ","), "enter", "only session entry requested")
    eq(result.error_kind, "authentication", "login refusal")
    eq(result.write_attempted, false, "elapsed time was never sent")
    eq(book.read_session_entered_at, nil, "a denied session is not marked entered")
end)

test("HTTP 200 login expiry at session entry preserves elapsed time", function()
    local report = fixture()
    local requests = 0
    report.client.report_read = function()
        requests = requests + 1
        return { errCode = -2010, errMsg = "user missing" }, 200
    end
    local book = { book_id = "book", chapter_uid = 11 }
    report.ensure_context = function() return book end
    local result = report:_run_pipeline("book", {
        elapsed_seconds = 30, allow_renewal = false,
    })
    eq(requests, 1, "only refused session entry was sent")
    eq(result.error_kind, "authentication", "HTTP 200 login error kind")
    eq(result.write_attempted, false, "elapsed write remained pending")
end)

test("forced historical context uses fresh cloud location and cached catalog", function()
    local report = fixture()
    cached_catalog = {
        { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
        { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    }
    catalog_fetch_count = 0
    reader_book_version = nil
    local book = {
        book_id = "book", chapters = cached_catalog,
        chapter_uid = 11, chapter_offset = 10, progress = 2,
    }
    report.client.get_progress = function()
        return { book = { bookId = "book", progress = 99,
            chapterUid = 22, chapterIdx = 2, chapterOffset = 150 } }
    end
    report.client.get_web_progress = report.client.get_progress
    local context = report:_build_context("book", true, book)
    eq(context.chapter_uid, 22, "fresh cloud chapter")
    eq(context.chapter_offset, 150, "fresh cloud offset")
    eq(context.progress, 99, "original cloud percent")
    eq(catalog_fetch_count, 0, "valid catalog was not downloaded again")
end)

test("verified live position does not depend on auxiliary cloud progress", function()
    local report, records = fixture()
    report._no_persist = true
    cached_catalog = {
        { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
        { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    }
    report.client.get_progress = function() error("HTTP 503") end
    report.client.get_web_progress = report.client.get_progress
    local result = report:_run_pipeline("book", {
        position = {
            book_id = "book", chapter_uid = 22, chapter_idx = 2,
            chapter_offset = 150, percent = 25,
        },
        elapsed_seconds = 30,
    })
    eq(result.accepted, true, "live report accepted")
    eq(records[#records].chapter_uid, 22, "verified live chapter")
    eq(records[#records].chapter_offset, 150, "verified live offset")
end)

test("an explicit position cannot cross book scope", function()
    local report, records = fixture()
    local result = report:_run_pipeline("book", {
        position = {
            book_id = "other", chapter_uid = 22,
            chapter_offset = 150, percent = 25,
        },
        elapsed_seconds = 30,
    })
    eq(result.error_kind, "context", "cross-book position classification")
    eq(result.write_attempted, false, "cross-book position was not sent")
    eq(#records, 0, "cross-book position issued no report")
end)

test("a changed reader version refreshes the catalog once", function()
    local report = fixture()
    cached_catalog = {
        { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    }
    catalog_fetch_count = 0
    reader_book_version = 2
    local book = {
        book_id = "book", book_version = 1, chapters = cached_catalog,
        chapter_uid = 22, chapter_offset = 10, progress = 2,
    }
    report:_build_context("book", true, book)
    eq(catalog_fetch_count, 1, "new catalog fetched for changed version")
    eq(book.book_version, 2, "reader version retained")
    reader_book_version = nil
end)

test("historical context without a remote offset stays pending", function()
    local report, records = fixture()
    cached_catalog = {
        { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
        { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    }
    report.client.get_progress = function()
        return { book = { bookId = "book", progress = 50, chapterUid = 22 } }
    end
    report.client.get_web_progress = report.client.get_progress
    local result = report:_run_pipeline("book", {
        force_context = true, elapsed_seconds = 30,
    })
    eq(result.error_kind, "context", "missing remote offset classification")
    eq(result.write_attempted, false, "unsafe elapsed POST was not sent")
    eq(#records, 0, "no enter or elapsed write was issued")
end)

test("network failure preparing a report never submits or quarantines its time", function()
    local report, records = fixture()
    for message, kind in pairs({
        ["HTTP nil, content_type=unknown, body_bytes=0"] = "transport",
        ["HTTP 503, content_type=text/plain"] = "rate_limited",
        ["remote progress unavailable: service_unreachable"] = "transport",
    }) do
        report.ensure_context = function() error(message) end
        local result = report:_run_pipeline("book", { elapsed_seconds = 30 })
        eq(result.error_kind, kind, "pre-write failure classification")
        eq(result.write_attempted, false, "no elapsed write was attempted")
        eq(#records, 0, "no request for reading time was issued")
    end
end)

test("historical context renews after a definite login error", function()
    local report, records = fixture()
    cached_catalog = {
        { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    }
    report.client.get_progress = function()
        return { errCode = -2012, errMsg = "login expired" }
    end
    report.client.get_web_progress = report.client.get_progress
    local renewals = 0
    report.client.renew_cookie = function()
        renewals = renewals + 1
        return { succ = 1 }
    end
    local result = report:_run_pipeline("book", {
        force_context = true, elapsed_seconds = 30, allow_renewal = true,
    })
    eq(result.error_kind, "authentication", "context login error kind")
    eq(result.auth_renewed, true, "context login renewal")
    eq(result.write_attempted, false, "context did not send elapsed time")
    eq(renewals, 1, "context renewed exactly once")
    eq(#records, 0, "context authentication sent no report")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
