-- Real KOReader + scripts/mock_weread.py delivery acceptance. No product
-- methods or WeRead writes are mocked: only time and the OS link are virtual.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
load_plugin("weread.koplugin")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Registry = require("document/documentregistry")
local Event = require("ui/event")
local socket = require("socket")
local json = require("json")
local root = assert(home:match("^(.*)/profile$"))
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

local function wait_for(label, predicate)
    local deadline = socket.gettime() + 55
    repeat
        UIManager:handleInput()
        if predicate() then return end
        socket.sleep(0.02)
    until socket.gettime() > deadline
    error("timeout: " .. label)
end

local function reader() return assert(ReaderUI.instance, "reader instance") end
local function book() return reader().weread.settings:get("books", {})["900001"] end
local function confirm_download()
    for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget.ok_callback then
            local widget = entry.widget
            UIManager:close(widget)
            widget.ok_callback()
            return
        end
    end
    error("download confirmation absent")
end

local initial = ReaderUI:new{
    dimen = Screen:getSize(),
    document = Registry:openDocument(root .. "/books/开始测试.html"),
}
UIManager:show(initial)
wait_for("starter ready", function() return initial.weread ~= nil end)
local plugin = initial.weread
local Content = require("weread.lib.content")
local b = plugin.client:get_book_info("900001")
Content.ensure_reader_state(plugin.client, b)
b.chapters = Content.fetch_catalog(plugin.client, b)
assert(Content.save_catalog_cache(plugin.client, plugin.settings, b, b.chapters))
plugin.settings:set("books", { ["900001"] = b })
local cache = plugin.settings:get("cache")
cache.auto_prefetch_next_chapter = false
cache.show_prefetch_notifications = false
cache.show_annotations = false
plugin.settings:set("cache", cache)
local sync = plugin.settings:get("sync")
sync.upload_annotations = true
sync.ask_on_conflict = false
plugin.settings:set("sync", sync)
local report_config = plugin.settings:get("read_report")
report_config.enabled = true
report_config.mode = "auto"
report_config.interval_seconds = 30
plugin.settings:set("read_report", report_config)
plugin.settings:flush()

plugin:openChapter(b, b.chapters[1])
confirm_download()
wait_for("first chapter open", function()
    for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget.ok_callback and entry.widget.ok_text == "Read now" then
            local widget = entry.widget
            UIManager:close(widget)
            widget.ok_callback()
            break
        end
    end
    return ReaderUI.instance and book() and book().incremental_reader_file
        and reader().document.file == book().incremental_reader_file
end)

local NetworkMgr = require("ui/network/manager")
local connected = true
NetworkMgr.isConnected = function() return connected end
local http = require("socket.http")
local ltn12 = require("ltn12")
local endpoint = reader().weread.settings.mock_endpoint
local function api(path, payload)
    local response = {}
    local body = payload and json.encode(payload)
    local _, code = http.request{
        url = endpoint .. path, method = body and "POST" or "GET",
        headers = body and { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body) } or {},
        source = body and ltn12.source.string(body), sink = ltn12.sink.table(response),
    }
    assert(code == 200, "fixture response " .. tostring(code))
    return json.decode(table.concat(response))
end
local function positive_reports()
    local result = {}
    for _, item in ipairs(api("/__state").read_reports) do
        if item.rt > 0 then result[#result + 1] = item end
    end
    return result
end
local function annotate(phrase, note, stamp)
    local found = assert(reader().document:findAllText(phrase, true, 0, 20, false))[1]
    assert(found, "native selection")
    reader().highlight.selected_text = { pos0 = found.start, pos1 = found["end"], text = phrase,
        drawer = "lighten", note = note, datetime = stamp }
    reader().highlight:saveHighlight(false)
    reader().highlight.selected_text = nil
end
local function unlocated_count()
    local total = 0
    for _, issue in ipairs(plugin.library_db:listUnlocatedAnnotations()) do
        total = total + issue.count
    end
    return total
end

-- Simulate a v1.8.5 incremental book whose chapter identity and source index
-- were not retained. Opening this exact book may rebuild those records, but it
-- must never guess coordinates or upload before the source is fetched again.
local stable = reader().document.file
local store = plugin:_annotationStore()
store:put("900001", "original", "1", nil, "1")
store:put("900001", "original_version", "1", nil, "1")
local old_books = plugin.settings:get("books", {})
old_books["900001"].annotation_documents[stable] = nil
plugin.settings:set("books", old_books)
plugin.settings:flush()
assert(not store:get("900001", "original", "1")
    and not plugin.settings:get("books", {})["900001"].annotation_documents[stable],
    "legacy annotation fixture retained its source metadata")
connected = false
annotate("这是第1章的第1段", "在线私密笔记一", "2026-11-25 09:00:01")
annotate("这是第1章的第2段", "在线私密笔记二", "2026-11-25 09:00:02")
local old_issues = plugin.library_db:listUnlocatedAnnotations()
local unlocated_before_reopen = unlocated_count()
assert(#api("/__state").annotation_writes == 0
    and #old_issues >= 1 and unlocated_before_reopen == 2,
    "legacy offline marks were not retained as two unlocated rows")
reader():onClose()
FileManager:showFiles(root .. "/books")
wait_for("file manager before legacy reopen", function()
    return FileManager.instance and FileManager.instance.weread
end)
FileManager.instance.weread:openFile(stable)
wait_for("legacy aggregate reopened", function()
    return ReaderUI.instance and reader().weread
        and reader().document.file == stable
end)
plugin = reader().weread
store = plugin:_annotationStore()
wait_for("legacy marks loaded without user editing", function()
    return unlocated_count() == 2
end)
local requests_before_repair = #api("/__state").requests

-- A normal reconnect event retries both saved sidecar annotations. There are
-- no new highlight or note actions after reopening the book.
connected = true
reader():handleEvent(Event:new("NetworkConnected"))
wait_for("second live annotation receipt", function()
    return #api("/__state").annotation_writes == 2
        and plugin.library_db:localAnnotationStatus().synced == 2
end)
assert(plugin.library_db:localAnnotationStatus().synced == 2,
    "both actionable marks retain receipts")
assert(store:get("900001", "original", "1")
    and plugin.settings:get("books", {})["900001"].annotation_documents[stable],
    "opening the old incremental book did not restore its source metadata")
assert(#plugin.library_db:listUnlocatedAnnotations() == 0,
    "source-repaired marks remained listed as unlocated")
local repair_requests = api("/__state").requests
local repair_chapter_requests = 0
for index = requests_before_repair + 1, #repair_requests do
    local event = repair_requests[index]
    if event.path and event.path:match("^/web/book/chapter/") then
        repair_chapter_requests = repair_chapter_requests + 1
        assert(event.encoded_chapter == require("weread.lib.protocol").e(1),
            "annotation repair downloaded a chapter unrelated to either mark")
    end
end
assert(repair_chapter_requests == 3,
    "annotation repair did not fetch exactly one EPUB chapter source")

reader().rolling:onGotoPage(2)
wait_for("nonzero live position", function()
    local position = reader().weread.progress_sync:capture_local()
    return position and tonumber(position.percent) and position.percent > 0
end)
local position = assert(reader().weread.progress_sync:capture_local())
local report = reader().weread.read_report
report:stop("delivery_setup")
report.subprocess = nil
local virtual_now = os.time()
local virtual_active = report.active_now()
report.now = function() return virtual_now end
report.active_now = function() return virtual_active end
plugin.offline_sync.now = function() return virtual_now end

-- The 14-second row represents an old write whose response was lost. It is
-- account-bound, visible for review, and never enters the runnable lane.
local ok, ambiguous_id = plugin.library_db:enqueueReadTime("900001", 14, position)
assert(ok and ambiguous_id, "seed ambiguous row")
local ambiguous = assert(plugin.library_db:claimReadTime("delivery-seed", ambiguous_id))
assert(plugin.library_db:quarantineReadTime(ambiguous, "seed_lost_reply"))
local historical_seconds = 243
local historical_rows = 9
assert(plugin.library_db:enqueueReadTime("900001", historical_seconds, position))

-- A fresh 30-second ReaderUI tick must bypass the historical queue and carry
-- the actual live progress instead of being swallowed by offline replay.
assert(report:start("delivery_live"))
report.last_accounted_at = virtual_active
virtual_active = virtual_active + 30
virtual_now = virtual_now + 30
assert(report:report_once(), "fresh live tick accepted")
local live = positive_reports()[1]
assert(live and live.rt == 30
        and tostring(live.bookId) == "900001"
        and tostring(live.chapterUid) == tostring(position.chapter_uid),
    "live report sends genuine time and progress")
local after_live = plugin.library_db:readTimeStatus()
assert(after_live.pending == historical_seconds and after_live.unknown == 14,
    "live exact-id claim leaves historical queue intact")

-- A second foreground interval must still send the newly captured position,
-- even while historical backlog exists.
virtual_active = virtual_active + 30
virtual_now = virtual_now + 30
assert(report:report_once(), "second fresh foreground interval accepted")
local live_receipts = plugin.library_db:readTimeReceipts()
local live_reports = positive_reports()
assert(live_receipts.count == 2 and live_receipts.seconds == 60
        and plugin.library_db:readTimeStatus().pending == historical_seconds,
    "two live intervals bypass historical backlog")
assert(#live_reports == 2 and live_reports[2].rt == 30
        and tostring(live_reports[2].chapterUid) == tostring(position.chapter_uid),
    "second live interval carries the current ReaderUI position")

-- Historical replay is a distinct bounded task on the same real gate. It may
-- first defer for probe/progress work, which the actual UI scheduler drives.
virtual_now = virtual_now + 31
report.manual_replay_tick = true
local historical_direct = report:report_once()
wait_for("foreground progress gate drains distinct historical work", function()
    local receipts = plugin.library_db:readTimeReceipts()
    return receipts.count == 3 and receipts.seconds == 90
        and plugin.library_db:readTimeStatus().pending == historical_seconds - 30
end)
assert(historical_direct == true or report.last_gate_denial ~= "inactive",
    "foreground historical report uses the real active host gate")

-- Leave ReaderUI exactly as a user does. The visible FileManager/SimpleUI host
-- must become the sole active coordinator before homepage sync is requested.
reader():onClose()
FileManager:showFiles(root .. "/books")
wait_for("visible file manager plugin", function()
    return FileManager.instance and FileManager.instance.weread
end)
plugin = FileManager.instance.weread
report = plugin.read_report
report.subprocess = nil
report.now = function() return virtual_now end
plugin.offline_sync.now = function() return virtual_now end

-- A 200 response without a receipt may already have committed. It must be
-- quarantined after exactly one POST; refreshing context must not resend it.
api("/__control", { read_replies = { "blank" } })
local before_blank = #positive_reports()
virtual_now = virtual_now + 31
assert(plugin:syncOfflineNow(), "homepage sync starts on visible FileManager")
wait_for("homepage blank response is quarantined", function()
    local state = plugin.library_db:readTimeStatus()
    return state.pending == historical_seconds - 60 and state.unknown == 44
end)
local after_blank_reports = positive_reports()
assert(#after_blank_reports == before_blank + 1
        and after_blank_reports[#after_blank_reports].reply == "blank",
    "blank 200 is held without a duplicate POST")
local after_blank = plugin.library_db:readTimeStatus()
assert(after_blank.pending == historical_seconds - 60 and after_blank.unknown == 44,
    "only the blank row moves to uncertain review")

-- One explicit business denial establishes a definitive rejection. That row
-- leaves the runnable lane but newer rows continue.
report.last_renew_attempt = virtual_now
api("/__control", { read_replies = { "reject" } })
assert(plugin.offline_sync:request("network_connected"),
    "explicit denial starts through the real coordinator")
wait_for("explicit denial is isolated", function()
    local state = plugin.library_db:readTimeStatus()
    return state.pending == historical_seconds - 90
        and state.rejected == 30
end)
local after_reject = plugin.library_db:readTimeStatus()
assert(after_reject.pending == historical_seconds - 90 and after_reject.unknown == 44
        and after_reject.rejected == 30,
    "one rejected row does not block the remaining backlog")

-- A timeout after the fixture commits models a lost HTTP reply. The client
-- must hold that exact row and continue with the following one later.
api("/__control", { read_replies = { "timeout" } })
local before_drop = #positive_reports()
virtual_now = virtual_now + 31
assert(plugin.offline_sync:request("network_connected"),
    "expired historical gate starts a real reconnect probe")
wait_for("timeout row is held after the real reconnect gate", function()
    local state = plugin.library_db:readTimeStatus()
    return state.pending == historical_seconds - 120 and state.unknown == 74
end)
local after_drop_reports = positive_reports()
assert(#after_drop_reports == before_drop + 1
        and after_drop_reports[#after_drop_reports].reply == "timeout",
    "timeout row reached HTTP exactly once: gate="
        .. tostring(report.last_gate_denial) .. " state=" .. tostring(report.state)
        .. " stage=" .. tostring(plugin.offline_sync.stage))
local after_drop = plugin.library_db:readTimeStatus()
assert(after_drop.pending == historical_seconds - 120 and after_drop.unknown == 74
        and after_drop.rejected == 30,
    "one timed-out row does not block newer records")
virtual_now = virtual_now + 31
assert(plugin.offline_sync:request("network_connected"),
    "actual reconnect requests a fresh probe")
wait_for("reconnect resumes a newer row after timeout", function()
    local state = plugin.library_db:readTimeStatus()
    return state.pending <= historical_seconds - 150 and state.unknown == 74
        and plugin.library_db:readTimeReceipts().count >= 4
end)

wait_for("remaining delivery queue drains", function()
    return plugin.library_db:readTimeStatus().pending == 0
end)

local queue = plugin.library_db:readTimeStatus()
local receipts = plugin.library_db:readTimeReceipts()
local status = require("weread.lib.sync_status").get(plugin)
local review = plugin.library_db:listReadTimeReview()
local reports = positive_reports()
local server_seconds, blank_count = 0, 0
for _, item in ipairs(reports) do
    server_seconds = server_seconds + item.rt
    if item.reply == "blank" then blank_count = blank_count + 1 end
end
assert(queue.pending == 0 and queue.unknown == 74 and queue.rejected == 30,
    "remaining queue totals distinguish uncertain and rejected rows")
local expected_receipt_count = historical_rows - 3 + 2
local expected_receipt_seconds = historical_seconds - 90 + 60
assert(receipts.count == expected_receipt_count
        and receipts.seconds == expected_receipt_seconds and receipts.last_time,
    "ACK status counts only genuine receipts")
assert(#review == 4 and review[1].elapsed_seconds == 14
        and review[1].state == "unknown" and review[2].state == "unknown"
        and review[3].state == "rejected" and review[4].state == "unknown",
    "review rows remain individually identified")
-- The three uncertain records (14s seed, 30s blank, 30s timeout) plus one
-- rejected record are conserved; nothing is invented or dropped.
assert(receipts.seconds + queue.unknown + queue.rejected
        == 14 + historical_seconds + 60,
    "read-time conservation")
assert(server_seconds == historical_seconds - 30 + 60
        and blank_count == 1 and #reports == historical_rows - 1 + 2,
    "server sees one blank commit and no fabricated or duplicate reports")
assert(status.state == "unknown" and status.pending_seconds == 0
        and status.unknown_seconds == 74 and status.rejected_seconds == 30
        and status.review_time_count == 4,
    "home/manual snapshot exposes actionable and held totals")
assert(status.pending_annotations == 0 and status.unknown_annotations == 0,
    "online annotations are fully acknowledged")

local before_repeat = #reports
for _ = 1, 3 do
    plugin.offline_sync:request("network_connected")
    for _poll = 1, 5 do
        UIManager:handleInput()
        socket.sleep(0.02)
    end
end
assert(#positive_reports() == before_repeat
        and plugin.library_db:readTimeReceipts().count == expected_receipt_count,
    "empty queue and repeated reconnect work never replay receipts")

local out = assert(io.open(root .. "/evidence/delivery-result.json", "wb"))
out:write(json.encode({
    input_seconds = 14 + historical_seconds + 60,
    receipt_count = receipts.count, receipt_seconds = receipts.seconds,
    queue = queue, review = review, status = status,
    server_seconds = server_seconds, server_report_count = #reports,
    annotation_writes = api("/__state").annotation_writes,
    unlocated_annotations_before_reopen = unlocated_before_reopen,
    annotation_repair_chapter_requests = repair_chapter_requests,
    blank_count = blank_count, replayed_after_empty = #positive_reports() - before_repeat,
}))
out:close()
FileManager.instance:onClose()
UIManager:quit()
print("PASS: mixed delivery preserves live writes, drains runnable backlog, and holds blank/rejected rows without duplication")
