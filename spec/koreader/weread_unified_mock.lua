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
sync.ask_on_conflict = os.getenv("WEREAD_SYNC_CHOICE") ~= "auto"
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
local Protocol = require("weread.lib.protocol")
local I18n = require("weread.lib.i18n")
local choice = os.getenv("WEREAD_SYNC_CHOICE") or "local"
local surface = os.getenv("WEREAD_SYNC_SURFACE") or "reader"
assert(choice == "local" or choice == "remote" or choice == "default" or choice == "auto", "valid choice")
local wake_calls = 0
for _, name in ipairs({ "turnOnWifi", "enableWifi", "restoreWifiAsync", "turnOnWifiAndWaitForConnection", "promptWifiOn" }) do
    NetworkMgr[name] = function() wake_calls = wake_calls + 1; error("synchronization must not wake Wi-Fi") end
end
local function active()
    return ReaderUI.instance or assert(FileManager.instance, "active UI")
end
local function current_plugin() return assert(active().weread) end
local function spin(seconds)
    local ending = socket.gettime() + seconds
    repeat UIManager:handleInput(); socket.sleep(0.03) until socket.gettime() >= ending
end
local function heartbeat()
    local coordinator = assert(current_plugin().offline_sync, "unified sync coordinator installed")
    assert(type(coordinator.heartbeat) == "function", "stable heartbeat callback")
    UIManager:unschedule(coordinator.heartbeat)
    UIManager:scheduleIn(0.01, coordinator.heartbeat)
end
local function mutations(state)
    local count = 0
    for _, request in ipairs(state.requests) do
        if request.method == "POST" and (request.path == "/web/book/read"
            or request.path == "/web/book/addBookmark" or request.path == "/web/review/add"
            or request.path == "/web/book/removeBookmark" or request.path == "/web/review/delete") then
            count = count + 1
        end
    end
    return count
end
local function positive_seconds(state)
    local total = 0
    for _, item in ipairs(state.read_reports) do total = total + item.rt end
    return total
end
local function annotate(phrase, note, stamp)
    local found = assert(reader().document:findAllText(phrase, true, 0, 20, false))[1]
    assert(found, "native selection")
    reader().highlight.selected_text = { pos0 = found.start, pos1 = found["end"], text = phrase,
        drawer = "lighten", note = note, datetime = stamp }
    reader().highlight:saveHighlight(false)
    reader().highlight.selected_text = nil
end
local function select_conflict()
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        local wanted = choice == "remote"
            and "Use WeRead progress" or "Keep KOReader progress"
        local translated = I18n.tr(wanted)
        local ok_matches = widget.ok_text == wanted or widget.ok_text == translated
        local cancel_matches = widget.cancel_text == wanted or widget.cancel_text == translated
        if choice == "auto" and (ok_matches or cancel_matches) then
            error("disabled conflict prompts must keep the local position automatically")
        end
        if choice == "default" and cancel_matches then
            error("local choice must be the default primary button")
        end
        if ok_matches then
            UIManager:close(widget)
            widget.ok_callback()
            return true
        elseif cancel_matches then
            UIManager:close(widget)
            widget.cancel_callback()
            return true
        end
    end
end
local function close_to_manager()
    reader():onClose()
    FileManager:showFiles(root .. "/books")
    wait_for("file manager plugin", function() return FileManager.instance and FileManager.instance.weread end)
end
assert(current_plugin().offline_sync:interval_seconds() == 600, "default heartbeat is ten minutes")
local heartbeat_schedule = {}
local coordinator = assert(current_plugin().offline_sync)
local schedule_in = UIManager.scheduleIn
UIManager.scheduleIn = function(self, seconds, callback, ...)
    if callback == coordinator.heartbeat then heartbeat_schedule[#heartbeat_schedule + 1] = seconds end
    return schedule_in(self, seconds, callback, ...)
end
local interval_menu = current_plugin():getOfflineSyncMenuItems()[2]
local choices = interval_menu.sub_item_table_func()
local intervals = { 1, 2, 5, 10, 30, 60 }
assert(#choices == #intervals)
for index, minutes in ipairs(intervals) do
    assert(choices[index].text == minutes .. " min", "wrong heartbeat choice label")
    assert(choices[index].checked_func() == (minutes == 10), "wrong default heartbeat choice")
end
choices[2].callback()
local saved = require("luasettings"):open(current_plugin().settings.settings_file)
assert(saved:readSetting("sync").heartbeat_minutes == 2 and interval_menu.sub_item_table_func()[2].checked_func(),
    "selected heartbeat persists and is checked when the menu is reopened")
assert(coordinator:interval_seconds() == 120 and heartbeat_schedule[#heartbeat_schedule] == 120,
    "configured heartbeat schedules two minutes")
choices[4].callback()
assert(coordinator:interval_seconds() == 600 and heartbeat_schedule[#heartbeat_schedule] == 600,
    "default heartbeat schedules ten minutes")
UIManager.scheduleIn = schedule_in
wait_for("initial local progress ready", function() return reader().weread.progress_sync.local_position ~= nil end)
offline()
reader().rolling:onGotoPage(2)
annotate("这是第1章的第1段", "统一同步私密笔记一", "2026-11-23 11:00:01")
spin(3.2)
reader():handleEvent(Event:new("Suspend"))
reader():handleEvent(Event:new("Resume"))
if surface == "filemanager" then close_to_manager() end
local expected_seconds = current_plugin().library_db:readTimeStatus().pending
assert(expected_seconds > 0, "offline reading time queued")
local before = mutations(api("/__state"))
heartbeat()
active():handleEvent(Event:new("NetworkConnected"))
spin(0.3)
assert(mutations(api("/__state")) == before, "disconnected triggers attempt no mutation")
assert(wake_calls == 0, "no Wi-Fi wake")
-- Interface link is now up, but the authenticated read-only probe still fails.
connected = true
heartbeat()
spin(0.5)
assert(mutations(api("/__state")) == before, "failed connectivity probe attempts no mutation")
-- Simulate a phone advancing within the cached chapter while the device was offline.
api("/__control", { times = 0 })
api("/web/book/read", { b = Protocol.e("900001"), c = Protocol.e(1), ci = 1,
    co = 1500, pr = 14, sm = "模拟手机超前", rt = 0 })
local comparison_failure_checked = false
if os.getenv("WEREAD_COMPARE_FAILURE") == "1" then
    local baseline = api("/__state")
    local start = #baseline.requests
    local baseline_mutations = mutations(baseline)
    local baseline_reads = #baseline.read_reports
    local baseline_annotations = #baseline.annotation_writes
    api("/__control", { progress_successes_before_failure = 1 })
    heartbeat()
    local probe_ok, gateway_failed, web_failed = false, false, false
    wait_for("probe succeeds but progress comparison fails", function()
        local state = api("/__state")
        for i = start + 1, #state.requests do
            local request = state.requests[i]
            if request.path == "/web/book/getProgress" and request.status == 200 then probe_ok = true end
            if probe_ok and request.api == "/book/getprogress" and request.status == 503 then gateway_failed = true end
            if probe_ok and request.path == "/web/book/getProgress" and request.status == 503 then web_failed = true end
        end
        assert(#state.read_reports == baseline_reads,
            "failed progress comparison must not write progress or time")
        assert(#state.annotation_writes <= baseline_annotations + 1,
            "failed comparison duplicated an independent annotation")
        return probe_ok and gateway_failed and web_failed
            and current_plugin().offline_sync.stage == nil
    end)
    spin(0.5)
    local failed_state = api("/__state")
    assert(#failed_state.read_reports == baseline_reads,
        "no delayed progress or time write after failed comparison")
    assert(#failed_state.annotation_writes == baseline_annotations + 1
        and failed_state.annotation_writes[#failed_state.annotation_writes].id,
        "one independently located annotation should receive an ACK")
    local proof = assert(io.open(root .. "/evidence/compare-failure.json", "wb"))
    local events = {}
    for i = start + 1, #failed_state.requests do events[#events + 1] = failed_state.requests[i] end
    proof:write(json.encode({ events = events, probe_success = probe_ok,
        gateway_failed = gateway_failed, web_failed = web_failed,
        writes_before = baseline_mutations, writes_after = mutations(failed_state),
        read_writes_before = baseline_reads,
        read_writes_after = #failed_state.read_reports,
        annotation_writes_before = baseline_annotations,
        annotation_writes_after = #failed_state.annotation_writes }))
    proof:close()
    comparison_failure_checked = true
    api("/__control", { progress_successes_before_failure = -1 })
end
-- No NetworkConnected event. Exercise the normal heartbeat or an explicit tap.
local manual = os.getenv("WEREAD_MANUAL_SYNC") == "1"
if manual then current_plugin():getOfflineSyncMenuItems()[1].callback() else heartbeat() end
local selected = false
wait_for("unified heartbeat drains queues", function()
    if choice == "auto" then
        select_conflict()
        selected = true
    elseif not selected then
        selected = select_conflict() or false
    end
    local state = api("/__state")
    return selected and #state.annotation_writes == 1
        and positive_seconds(state) >= expected_seconds
        and (surface == "reader" or current_plugin().library_db:readTimeStatus().pending == 0)
        and type(current_plugin().settings:get("books", {})["900001"].pending_upload_position) ~= "table"
end)
local first = api("/__state")
assert(first.annotation_writes[1].payload.isPrivate == 1, "private note uploaded")
local function completion()
    local expected = "Sync complete. WeRead confirmed the upload."
    local translated = I18n.tr(expected)
    for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget.text == expected or entry.widget.text == translated then
            return entry.widget
        end
    end
end
if manual then
    wait_for("full-batch confirmation after progress choice", completion)
    assert(require("weread.lib.sync_status").get(current_plugin()).state == "synced")
    UIManager:close(completion())
else
    assert(not completion(), "a background heartbeat showed a manual upload confirmation")
end
local position_after_choice
if ReaderUI.instance then
    position_after_choice = reader().weread.progress_sync:capture_local()
    local diagnostic = assert(io.open(root .. "/evidence/choice-position.json", "wb"))
    diagnostic:write(json.encode({ page = reader():getCurrentPage(), pages = reader().document:getPageCount(),
        position = position_after_choice, toc = reader().document:getToc(), remote = first.progress["900001"] }))
    diagnostic:close()
    if choice == "remote" then
        assert(position_after_choice.percent >= 10, "cloud choice moves reader forward")
    else
        assert(position_after_choice.percent <= 6, "local choice keeps local reader position")
    end
end
if choice ~= "remote" then
    assert(first.progress["900001"].progress <= 6, "local choice wins over phone position")
else
    assert(first.progress["900001"].progress >= 10, "cloud choice does not regress remote")
end
-- A choice is not a permanent block: a new offline session must sync again.
connected = false
active():handleEvent(Event:new("NetworkDisconnected"))
api("/__control", { times = -1, status = 503 })
if not ReaderUI.instance then
    current_plugin():openFile(stable)
    wait_for("cached reopen", function() return ReaderUI.instance and reader().weread.progress_sync.local_position end)
    if choice == "remote" then
        wait_for("persisted cloud choice applied on reopen", function()
            return type(reader().weread.settings:get("books", {})["900001"].pending_remote_position) ~= "table"
        end)
        assert(reader().weread.progress_sync:capture_local().percent >= 10,
            "cloud choice in file manager applies when cached book reopens")
    end
end
reader().rolling:onGotoPage(2)
annotate("这是第1章的第2段", "统一同步私密笔记二", "2026-11-23 11:00:02")
spin(3.2)
close_to_manager()
local second_pending = current_plugin().library_db:readTimeStatus().pending
assert(second_pending > 0, "second offline session queues seconds")
api("/__control", { times = 0 })
connected = true
active():handleEvent(Event:new("NetworkConnected"))
selected = false
wait_for("second session sync after choice", function()
    if choice == "auto" then
        select_conflict()
        selected = true
    elseif not selected then
        selected = select_conflict() or false
    end
    local state = api("/__state")
    return #state.annotation_writes == 2
        and positive_seconds(state) >= positive_seconds(first) + second_pending
        and current_plugin().library_db:readTimeStatus().pending == 0
        and type(current_plugin().settings:get("books", {})["900001"].pending_upload_position) ~= "table"
end)
local final = api("/__state")
local seconds, writes = positive_seconds(final), #final.annotation_writes
heartbeat()
active():handleEvent(Event:new("NetworkConnected"))
spin(1.5)
local repeated = api("/__state")
assert(positive_seconds(repeated) == seconds and #repeated.annotation_writes == writes,
    "closed reader reconnect/heartbeat does not duplicate acknowledged data")
assert(wake_calls == 0, "never wake Wi-Fi")
local out = assert(io.open(root .. "/evidence/unified-result.json", "wb"))
out:write(json.encode({ choice = choice, surface = surface, expected_first_seconds = expected_seconds,
    second_seconds = second_pending, total_seconds = seconds, annotation_writes = repeated.annotation_writes,
    position_after_choice = position_after_choice, final_progress = repeated.progress["900001"],
    wifi_wake_calls = wake_calls, heartbeat_without_event = true, comparison_failure_checked = comparison_failure_checked, heartbeat_schedule = heartbeat_schedule }))
out:close()
active():onClose()
UIManager:quit()
print("PASS: unified reconnect/heartbeat, offline guard, conflict choice, subsequent offline cycle, no wake or duplicates")
