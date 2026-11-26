-- Reproduce the mixed pending state reported on Kindle with real KOReader,
-- HTTP and SQLite. Only the OS memory/network boundaries and mock replies are
-- controlled. Product gates, verification state and report delivery remain
-- untouched.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("language", "zh_CN")
require("gettext").changeLang("zh_CN")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
load_plugin("weread.koplugin")

local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
local Registry = require("document/documentregistry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local json = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")
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

local function reader()
    return assert(ReaderUI.instance, "reader instance")
end

local function confirm_download()
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if widget.ok_callback then
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
local book = plugin.client:get_book_info("900001")
Content.ensure_reader_state(plugin.client, book)
book.chapters = Content.fetch_catalog(plugin.client, book)
assert(Content.save_catalog_cache(
    plugin.client, plugin.settings, book, book.chapters))
plugin.settings:set("books", { ["900001"] = book })
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

plugin:openChapter(book, book.chapters[1])
confirm_download()
local read_now_text = require("weread.lib.plugin_util").tr("Read now")
wait_for("first chapter open", function()
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if widget.ok_callback and widget.ok_text == read_now_text then
            UIManager:close(widget)
            widget.ok_callback()
            break
        end
    end
    local saved = plugin.settings:get("books", {})["900001"]
    return ReaderUI.instance and saved and saved.incremental_reader_file
        and reader().document.file == saved.incremental_reader_file
end)

local NetworkMgr = require("ui/network/manager")
NetworkMgr.isConnected = function() return true end
local endpoint = reader().weread.settings.mock_endpoint
local function api(path, payload)
    local response = {}
    local body = payload and json.encode(payload)
    local _, code = require("socket.http").request{
        url = endpoint .. path, method = body and "POST" or "GET",
        headers = body and {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        } or {},
        source = body and ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    assert(code == 200, path .. " returned " .. tostring(code))
    return json.decode(table.concat(response))
end

local function positive_reports(state)
    local reports = {}
    for _, report in ipairs(state.read_reports or {}) do
        if tonumber(report.rt) and report.rt > 0 then
            reports[#reports + 1] = report
        end
    end
    return reports
end

local function unlocated_count(host)
    local count = 0
    for _, issue in ipairs(host.library_db:listUnlocatedAnnotations()) do
        count = count + (tonumber(issue.count) or 0)
    end
    return count
end

reader().weread.read_report:stop("pending_diagnostics_setup")
plugin = reader().weread
local store = plugin:_annotationStore()
store:put("900001", "original", "1", nil, "1")
store:put("900001", "original_version", "1", nil, "1")
plugin.prefetch_worker.read_memory = function()
    return "MemAvailable: 1024 kB\n"
end
local reader_sync = plugin.settings:get("sync")
reader_sync.upload_annotations = false
plugin.settings:set("sync", reader_sync)
local unresolved = {}
for index, phrase in ipairs({ "这是第1章的第1段", "这是第1章的第2段" }) do
    local found = assert(reader().document:findAllText(
        phrase, true, 0, 20, false))[1]
    assert(found, "native diagnostic selection missing")
    reader().highlight.selected_text = {
        pos0 = found.start, pos1 = found["end"], text = phrase,
        drawer = "lighten",
        note = index == 2 and "旧私密笔记" or nil,
        datetime = "2026-11-26 09:01:0" .. tostring(index),
    }
    local saved_index = assert(reader().highlight:saveHighlight(false))
    reader().highlight.selected_text = nil
    local item = assert(reader().annotation.annotations[saved_index])
    -- Keep valid KOReader XPointers while modelling a legacy source-cache
    -- gap. The low-memory boundary prevents the safe source repair worker from
    -- starting, so no upload can be guessed from display text alone.
    unresolved[#unresolved + 1] = item
end
reader_sync.upload_annotations = true
plugin.settings:set("sync", reader_sync)
plugin.settings:flush()
plugin:onAnnotationsModified(unresolved)
assert(unlocated_count(plugin) == 2,
    "native reader did not retain its two unresolved annotations")

local position = {
    book_id = "900001", chapter_uid = 1, chapter_idx = 1,
    chapter_offset = 0, percent = 0, summary = "",
}
assert(plugin.progress_sync:_save_pending(position, "diagnostic_fixture"))
assert(plugin.library_db:enqueueReadTime("900001", 1930, position))
local SyncStatus = require("weread.lib.sync_status")
local initial_reader_status = SyncStatus.get(plugin)
assert(initial_reader_status.pending_seconds == 1930
    and initial_reader_status.pending_annotations == 2
    and initial_reader_status.unlocated_annotations == 2
    and initial_reader_status.pending_progress == 1,
    "mixed reader fixture does not match the reported state")
local review_books = SyncStatus.reviewBooks(plugin, initial_reader_status)
assert(#review_books == 1
    and review_books[1].seconds == 1930
    and review_books[1].segments == 65
    and review_books[1].annotations == 2
    and review_books[1].progress == true
    and #review_books[1].issues == 1
    and review_books[1].issues[1].count == 2,
    "pending details did not group 1930 s, 65 segments, progress and two unlocated annotations")

plugin:showOfflineSyncStatus()
local status_dialog
wait_for("mixed pending status dialog", function()
    local top = UIManager._window_stack[#UIManager._window_stack]
    status_dialog = top and top.widget
    return status_dialog and status_dialog.getButtonById
        and status_dialog:getButtonById("review")
        and status_dialog:getContentSize()
end)
local status_bounds = status_dialog:getContentSize()
assert(status_bounds.w <= Screen:getWidth() and status_bounds.h <= Screen:getHeight(),
    "mixed pending status dialog exceeds the 600x800 screen")
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/pending-status-1930s-2-unlocated.png")
UIManager:close(status_dialog)

plugin:showPendingSyncReview()
local review_dialog
wait_for("mixed pending review dialog", function()
    local top = UIManager._window_stack[#UIManager._window_stack]
    review_dialog = top and top.widget
    return review_dialog and review_dialog.getButtonById
        and review_dialog:getButtonById("close")
        and review_dialog:getContentSize()
end)
local review_bounds = review_dialog:getContentSize()
assert(review_bounds.w <= Screen:getWidth() and review_bounds.h <= Screen:getHeight(),
    "mixed pending review dialog exceeds the 600x800 screen")
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/pending-review-1930s-65-segments.png")
UIManager:close(review_dialog)

local before_reader = api("/__state")
assert(plugin.offline_sync:request("network_connected"),
    "reader coordinator did not accept a reconnect pass")
wait_for("correct book drains time past unlocated annotations", function()
    local queue = plugin.library_db:readTimeStatus()
    local books = plugin.settings:get("books", {})
    return queue.pending < 1930
        and type(books["900001"].pending_upload_position) ~= "table"
end)
wait_for("reader writer released SQLite", function()
    return plugin.read_report.job == nil
        and plugin.read_report.network_lease == nil
        and plugin.offline_sync.stage == nil
end)
local after_reader = api("/__state")
local before_reader_reports = positive_reports(before_reader)
local after_reader_reports = positive_reports(after_reader)
assert(#after_reader_reports == #before_reader_reports + 1
    and after_reader_reports[#after_reader_reports].rt == 30
    and #after_reader.annotation_writes == #before_reader.annotation_writes,
    "unlocated annotations blocked or caused an unsafe reader write")
assert(unlocated_count(plugin) == 2,
    "reader upload lost the two unresolved annotation rows")
local after_reader_seconds = plugin.library_db:readTimeStatus().pending
assert(after_reader_seconds == 1900,
    "reader did not consume exactly one confirmed historical segment")

reader():onClose()
wait_for("reader closed", function() return ReaderUI.instance == nil end)
FileManager:showFiles(root .. "/books")
wait_for("file manager ready", function()
    return FileManager.instance and FileManager.instance.weread
end)
plugin = FileManager.instance.weread
assert(plugin.library_db:enqueueReadTime("900001", 30, position))
assert(plugin.progress_sync:_save_pending(position, "diagnostic_home_fixture"))
plugin.offline_sync.worker.read_memory = function()
    return "MemAvailable: 1024 kB\n"
end
assert(plugin.offline_sync.worker:available()
    and plugin.offline_sync.worker:availableMemoryKB() == 1024
    and plugin.offline_sync.worker.min_available_kb > 1024,
    "fixture did not reach the real low-memory worker gate")
local initial_home_status = require("weread.lib.sync_status").get(plugin)
assert(initial_home_status.pending_seconds == 1930
    and initial_home_status.pending_annotations == 2
    and initial_home_status.unlocated_annotations == 2
    and initial_home_status.pending_progress == 1,
    "mixed homepage fixture does not match the reported state")

-- Exercise the actual Home/manual coordinator first. The low-memory worker
-- cannot start, so the explicit tap must make exactly one bounded in-process
-- GET. A business-level HTTP 200/-2010 is still authentication failure and
-- must not unlock any write path.
api("/__control", { progress_reply = "authentication" })
local before_auth = api("/__state")
assert(plugin:syncOfflineNow(), "authentication diagnostic did not start from Home")
local auth_text = require("weread.lib.plugin_util").tr(
    "WeRead declined this login. Open Saved account in the WeRead menu to scan again.")
local auth_dialog
wait_for("homepage authentication result", function()
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if tostring(widget.text or ""):find(auth_text, 1, true) then
            auth_dialog = widget
            break
        end
    end
    local result = plugin.library_db:lastManualSyncResult()
    return auth_dialog and result and result.reason == "authentication_required"
        and plugin.offline_sync.stage == nil
        and plugin.read_report.job == nil
        and plugin.read_report.network_lease == nil
end)
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/pending-authentication-result.png")
local after_auth = api("/__state")
local auth_probe_count, unauthorized_posts = 0, 0
for index = #before_auth.requests + 1, #after_auth.requests do
    local event = after_auth.requests[index]
    if event.method == "GET" and event.path == "/web/book/getProgress"
        and event.status == 200 then
        auth_probe_count = auth_probe_count + 1
    elseif event.method == "POST" and not event.path:find("/__", 1, true) then
        unauthorized_posts = unauthorized_posts + 1
    end
end
assert(auth_probe_count == 1,
    "Home manual authentication check did not issue exactly one bounded GET")
assert(unauthorized_posts == 0
    and #after_auth.read_reports == #before_auth.read_reports
    and #after_auth.annotation_writes == #before_auth.annotation_writes,
    "Home manual authentication denial allowed a mutation")
local auth_status = SyncStatus.get(plugin)
local auth_books = SyncStatus.reviewBooks(plugin, auth_status)
local pending_position = plugin.settings:get("books", {})["900001"].pending_upload_position
assert(auth_status.pending_seconds == 1930
    and auth_status.pending_annotations == 2
    and auth_status.unlocated_annotations == 2
    and auth_status.pending_progress == 1
    and type(pending_position) == "table"
    and #auth_books == 1 and auth_books[1].segments == 65,
    "authentication denial changed the durable SQLite/settings queue")
UIManager:close(auth_dialog)

-- A definite -2012 may attempt one Cookie renewal, but a rejected renewal
-- still cannot release any queued write.
api("/__control", { progress_reply = "expired", renew_reply = "reject" })
local before_rejected_renewal = api("/__state")
assert(plugin:syncOfflineNow(), "rejected renewal diagnostic did not start")
local rejected_dialog
wait_for("rejected renewal result", function()
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if tostring(widget.text or ""):find(auth_text, 1, true) then
            rejected_dialog = widget
            break
        end
    end
    return rejected_dialog and plugin.offline_sync.stage == nil
        and plugin.read_report.job == nil
        and plugin.read_report.network_lease == nil
end)
local after_rejected_renewal = api("/__state")
local rejected_probe_count, rejected_renewal_count = 0, 0
for index = #before_rejected_renewal.requests + 1,
        #after_rejected_renewal.requests do
    local event = after_rejected_renewal.requests[index]
    if event.method == "GET" and event.path == "/web/book/getProgress" then
        rejected_probe_count = rejected_probe_count + 1
    elseif event.method == "POST" and event.path == "/web/login/renewal" then
        rejected_renewal_count = rejected_renewal_count + 1
    end
end
assert(rejected_probe_count == 1 and rejected_renewal_count == 1
    and #after_rejected_renewal.read_reports
        == #before_rejected_renewal.read_reports
    and #after_rejected_renewal.annotation_writes
        == #before_rejected_renewal.annotation_writes
    and plugin.library_db:readTimeStatus().pending == 1930,
    "a rejected -2012 renewal mutated or consumed the pending queue")
UIManager:close(rejected_dialog)

-- Advance only the coordinator's injected clock past its renewal cooldown.
-- The successful path must renew once, merge the confirmed credentials, run
-- another real GET, and only then allow the first 30-second write.
local sync_now = plugin.offline_sync.now
plugin.offline_sync.now = function() return sync_now() + 601 end
api("/__control", { progress_reply = "expired", renew_reply = "ok" })
local before_home = api("/__state")
assert(plugin:syncOfflineNow(), "homepage manual upload did not start")
wait_for("homepage low-memory fallback and first time receipt", function()
    local queue = plugin.library_db:readTimeStatus()
    local books = plugin.settings:get("books", {})
    return queue.pending < 1930
        and type(books["900001"].pending_upload_position) ~= "table"
end)
wait_for("homepage writer released SQLite", function()
    return plugin.read_report.job == nil
        and plugin.read_report.network_lease == nil
        and plugin.offline_sync.stage == nil
end)
local after_home = api("/__state")
local before_home_reports = positive_reports(before_home)
local after_home_reports = positive_reports(after_home)
local home_probe_count, home_renewal_count = 0, 0
for index = #before_home.requests + 1, #after_home.requests do
    local event = after_home.requests[index]
    if event.method == "GET" and event.path == "/web/book/getProgress" then
        home_probe_count = home_probe_count + 1
    elseif event.method == "POST" and event.path == "/web/login/renewal" then
        home_renewal_count = home_renewal_count + 1
    end
end
assert(home_probe_count >= 2 and home_renewal_count == 1,
    "-2012 renewal did not require one renewal and a fresh read-only GET")
assert(#after_home_reports == #before_home_reports + 1
    and after_home_reports[#after_home_reports].rt == 30,
    "homepage did not obtain the first real reading-time receipt")
assert(#after_home.annotation_writes == #before_home.annotation_writes,
    "unlocated annotations were guessed and written")
local home_seconds = plugin.library_db:readTimeStatus().pending
assert(home_seconds == 1900 and unlocated_count(plugin) == 2,
    "homepage upload did not preserve both unlocated rows")

local evidence = assert(io.open(
    root .. "/evidence/pending-diagnostics-result.json", "wb"))
evidence:write(json.encode({
    initial_seconds = 1930,
    home_seconds = home_seconds,
    reader_seconds = after_reader_seconds,
    unlocated_annotations = 2,
    home_probe_count = home_probe_count,
    home_renewal_count = home_renewal_count,
    rejected_probe_count = rejected_probe_count,
    rejected_renewal_count = rejected_renewal_count,
    rejected_read_writes = #after_rejected_renewal.read_reports
        - #before_rejected_renewal.read_reports,
    rejected_annotation_writes = #after_rejected_renewal.annotation_writes
        - #before_rejected_renewal.annotation_writes,
    auth_probe_count = auth_probe_count,
    auth_result = "authentication_required",
    unauthorized_posts = unauthorized_posts,
    unauthorized_read_writes = #after_auth.read_reports - #before_auth.read_reports,
    unauthorized_annotation_writes = #after_auth.annotation_writes - #before_auth.annotation_writes,
}))
evidence:close()
if FileManager.instance then
    FileManager.instance:onClose()
end
UIManager:quit()
print("PASS: mixed pending data drains time through low-memory fallback and blocks auth writes")
