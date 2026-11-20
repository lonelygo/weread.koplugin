-- Real KOReader + scripts/mock_weread.py fixture. No product methods mocked.
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
local Registry = require("document/documentregistry")
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
        socket.sleep(0.03)
    until socket.gettime() > deadline
    local r = ReaderUI.instance
    local record = r and r.weread and r.weread.settings:get("books", {})["900001"]
    error("timeout: " .. label .. " reader=" .. tostring(r) .. " active=" .. tostring(record and record.active_chapter_uid) .. " page=" .. tostring(r and r:getCurrentPage()))
end
local function reader() return assert(ReaderUI.instance, "reader instance") end
local function book() return reader().weread.settings:get("books", {})["900001"] end
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
local b = plugin.client:get_book_info("900001")
Content.ensure_reader_state(plugin.client, b)
b.chapters = Content.fetch_catalog(plugin.client, b)
assert(Content.save_catalog_cache(plugin.client, plugin.settings, b, b.chapters))
plugin.settings:set("books", { ["900001"] = b })
local config = plugin.settings:get("cache")
config.auto_prefetch_next_chapter = false
config.show_prefetch_notifications = false
config.show_annotations = false
plugin.settings:set("cache", config)
local sync = plugin.settings:get("sync")
sync.upload_on_close = true
sync.ask_on_conflict = true
plugin.settings:set("sync", sync)
local report_config = plugin.settings:get("read_report")
report_config.enabled = true
report_config.mode = "auto"
report_config.interval_seconds = 10
plugin.settings:set("read_report", report_config)
plugin.settings:flush()
local start_uid = 1
plugin:openChapter(b, b.chapters[start_uid])
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
local stable = reader().document.file
local NetworkMgr = require("ui/network/manager")
local connected = true
-- Only the OS link boundary is simulated; real Client performs every HTTP call.
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
    assert(code == 200, "fixture control response " .. tostring(code))
    return json.decode(table.concat(response))
end
local function offline()
    connected = false
    api("/__control", { times = -1, status = 503 })
end
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local WeRead = require("weread.lib.protocol")
local function spin(seconds)
    local ending = socket.gettime() + seconds
    repeat UIManager:handleInput(); socket.sleep(0.03) until socket.gettime() >= ending
end
local function reported()
    local total = 0
    for _, report in ipairs(api("/__state").read_reports) do total = total + (tonumber(report.rt) or 0) end
    return total
end
local function manager()
    return assert(FileManager.instance, "file manager instance")
end
local function snapshot(label, instance)
    local progress_sync = instance.progress_sync
    local file = assert(io.open(root .. "/evidence/reading-lifecycle.jsonl", "ab"))
    file:write(json.encode({ label = label, dirty = progress_sync.dirty, verified = progress_sync.verified,
        state = progress_sync.state, local_position = progress_sync.local_position,
        book = instance.settings:get("books", {})["900001"],
        timer = instance.read_report:status() }) .. "\n")
    file:close()
end
local function close_to_manager()
    snapshot("before_close", reader().weread)
    local closing_plugin = reader().weread
    reader():onClose()
    snapshot("after_close", closing_plugin)
    FileManager:showFiles(root .. "/books")
    wait_for("file manager ready", function() return FileManager.instance and manager().weread end)
    snapshot("file_manager", manager().weread)
end
local evidence = { early_page = os.getenv("WEREAD_EARLY_PAGE") == "1" }
assert(reader().weread.read_report:status().target_book_id == "900001", "downloaded book auto-associated")
assert(reader().weread.read_report:status().running, "automatic timer started")
offline()
if os.getenv("WEREAD_EARLY_PAGE") ~= "1" then
    wait_for("progress baseline ready", function()
        return reader().weread.progress_sync.current_book_id == "900001"
            and reader().weread.progress_sync.local_position ~= nil
    end)
end
local first_start = os.time()
reader().rolling:onGotoPage(2)
spin(3.2)
local suspend_at = os.time()
reader():handleEvent(Event:new("Suspend"))
spin(2.2)
close_to_manager()
local pending = manager().weread.library_db:readTimeStatus()
assert(pending.pending > 0, "offline seconds persisted at suspend")
assert(math.abs(pending.pending - (suspend_at - first_start)) <= 1, "suspend excludes sleep seconds")
local expected_first = pending.pending
spin(2.2)
assert(manager().weread.library_db:readTimeStatus().pending == expected_first, "closed idle adds no time")
assert(reported() == 0, "offline no reported time")
api("/__control", { times = 0 })
connected = true
manager():handleEvent(Event:new("NetworkConnected"))
wait_for("file manager drains first reading time", function()
    return manager().weread.library_db:readTimeStatus().pending == 0 and reported() == expected_first
end)
local after_first = reported()
local first_progress = api("/__state").progress["900001"]
assert(first_progress and first_progress.chapterUid == 1 and first_progress.progress > 0,
    "close uploads actual advanced page position")
manager():handleEvent(Event:new("NetworkConnected"))
manager():handleEvent(Event:new("NetworkConnected"))
spin(2.2)
assert(reported() == after_first, "reconnect does not replay acknowledged seconds")
evidence.first_seconds = expected_first
evidence.first_clock_delta = suspend_at - first_start
evidence.first_progress = first_progress
evidence.sleep_seconds = 2.2
evidence.closed_idle_seconds = 2.2
-- Read another session offline, then let a simulated phone advance remotely.
connected = false
api("/__control", { times = -1, status = 503 })
manager().weread:openFile(stable)
wait_for("reopen cached book offline", function() return ReaderUI.instance and reader().weread.read_report:status().running end)
local second_start = os.time()
spin(3.2)
reader().rolling:onGotoPage(2)
local second_end = os.time()
close_to_manager()
local second = manager().weread.library_db:readTimeStatus().pending
assert(second > 0 and math.abs(second - (second_end - second_start)) <= 1, "close captures actual foreground seconds")
spin(2.2)
assert(manager().weread.library_db:readTimeStatus().pending == second, "second closed idle excluded")
api("/__control", { times = 0 })
api("/web/book/read", { b = WeRead.e("900001"), c = WeRead.e(6), ci = 6,
    co = 500, pr = 98, sm = "模拟手机进度", rt = 0 })
local phone_event_count = #api("/__state").read_reports
connected = true
manager():handleEvent(Event:new("NetworkConnected"))
wait_for("file manager drains second reading time", function()
    return manager().weread.library_db:readTimeStatus().pending == 0 and reported() == after_first + second
end)
local state = api("/__state")
assert(state.progress["900001"].chapterUid == 6 and state.progress["900001"].progress == 98,
    "time replay must not regress phone progress")
for i = phone_event_count + 1, #state.read_reports do
    local report = state.read_reports[i]
    assert(report.chapterUid == 6 and report.progress == 98, "each replay preserves remote position")
end
manager():handleEvent(Event:new("NetworkConnected"))
spin(2.2)
assert(reported() == after_first + second, "second reconnect idempotence")
evidence.second_seconds = second
evidence.second_clock_delta = second_end - second_start
evidence.total_reported_seconds = reported()
evidence.read_reports = api("/__state").read_reports
evidence.remote_progress = api("/__state").progress["900001"]
local output = assert(io.open(root .. "/evidence/reading-result.json", "wb"))
output:write(json.encode(evidence)); output:close()
manager():onClose()
UIManager:quit()
print("PASS: real offline seconds, suspend/close exclude idle, FileManager reconnect drains once, phone progress preserved")
