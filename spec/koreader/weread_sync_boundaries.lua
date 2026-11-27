-- Real KOReader + synthetic WeRead HTTP fixture for online/offline ownership.
-- Select one bounded case with WEREAD_BOUNDARY_CASE.
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
local case = os.getenv("WEREAD_BOUNDARY_CASE") or "online"
local valid_cases = {
    ["offline-tail"] = true,
    online = true,
    ["phone-forward"] = true,
    ["phone-in-page"] = true,
    ["phone-rewind"] = true,
    tail = true,
}
assert(valid_cases[case], "unknown boundary case: " .. tostring(case))

UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)
local function wait_for(label, predicate, seconds)
    local deadline = socket.gettime() + (seconds or 55)
    repeat
        UIManager:handleInput()
        if predicate() then return true end
        socket.sleep(0.025)
    until socket.gettime() > deadline
    local active = ReaderUI.instance
    error("timeout: " .. label .. " reader=" .. tostring(active)
        .. " page=" .. tostring(active and active:getCurrentPage()))
end
local function spin(seconds)
    local deadline = socket.gettime() + seconds
    repeat UIManager:handleInput(); socket.sleep(0.025) until socket.gettime() >= deadline
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
local cache = plugin.settings:get("cache")
cache.auto_prefetch_next_chapter = false
cache.show_prefetch_notifications = false
cache.show_annotations = false
plugin.settings:set("cache", cache)
local sync = plugin.settings:get("sync")
sync.upload_on_close = true
sync.pull_on_open = true
sync.ask_on_conflict = true
plugin.settings:set("sync", sync)
local report = plugin.settings:get("read_report")
report.enabled = true
report.mode = "auto"
report.interval_seconds = 30
plugin.settings:set("read_report", report)
plugin.settings:flush()
plugin:openChapter(b, b.chapters[1])
confirm_download()
wait_for("book open", function()
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
NetworkMgr.isConnected = function() return connected end
NetworkMgr.isWifiOn = function() return connected end
local http = require("socket.http")
local ltn12 = require("ltn12")
local endpoint = reader().weread.settings.mock_endpoint
local function api(path, payload)
    local response = {}
    local body = payload and json.encode(payload)
    local _, code = http.request{
        url = endpoint .. path,
        method = body and "POST" or "GET",
        headers = body and {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        } or {},
        source = body and ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    assert(code == 200, "fixture request failed: " .. tostring(code))
    return json.decode(table.concat(response))
end
local function state() return api("/__state") end
local function positive_seconds(snapshot)
    local seconds = 0
    for _, item in ipairs(snapshot.read_reports) do
        seconds = seconds + math.max(0, tonumber(item.rt) or 0)
    end
    return seconds
end
local function mutations(snapshot)
    local count = 0
    for _, item in ipairs(snapshot.requests) do
        if item.method == "POST" and item.path == "/web/book/read" then
            count = count + 1
        end
    end
    return count
end
local function position(value)
    if not value then return nil end
    return {
        chapter_uid = value.chapter_uid or value.chapterUid,
        chapter_offset = value.chapter_offset or value.chapterOffset,
        percent = value.percent or value.progress,
    }
end
local function current_position()
    return reader().weread.progress_sync:capture_local()
end
local function choice_dialog()
    local tr = require("weread.lib.i18n").tr
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if widget.ok_text == tr("Keep KOReader progress")
            and widget.cancel_text == tr("Use WeRead progress") then
            return widget
        end
    end
end
local function choose_cloud()
    local dialog = assert(choice_dialog(), "progress choice missing")
    UIManager:close(dialog)
    dialog.cancel_callback()
end
local function heartbeat()
    local coordinator = reader().weread.offline_sync
    UIManager:unschedule(coordinator.heartbeat)
    UIManager:scheduleIn(0.01, coordinator.heartbeat)
end
local FileManager = require("apps/filemanager/filemanager")
local Event = require("ui/event")
local function close_to_manager()
    reader():onClose()
    FileManager:showFiles(root .. "/books")
    wait_for("file manager", function()
        return FileManager.instance and FileManager.instance.weread
    end)
    return FileManager.instance.weread
end
local function reopen(manager)
    manager:openFile(stable)
    wait_for("cached reopen", function()
        return ReaderUI.instance and reader().weread
            and reader().weread.read_report:status().running
    end)
    return reader().weread
end
local function set_phone(offset, progress, summary)
    local Protocol = require("weread.lib.protocol")
    api("/web/book/read", {
        b = Protocol.e("900001"), c = Protocol.e(1), ci = 1,
        co = offset, pr = progress, sm = summary, rt = 0,
    })
end
local evidence = { case = case, version = plugin.version }

wait_for("initial comparison", function() return reader().weread.progress_sync.verified end)
assert(reader().weread.read_report:_interval() == 30)

if case == "online" then
    local captured = {}
    local original = reader().weread.progress_sync._save_pending
    reader().weread.progress_sync._save_pending = function(self, value, reason)
        captured[#captured + 1] = reason
        return original(self, value, reason)
    end
    for turn = 1, 2 do
        reader().rolling:onGotoPage(turn + 1)
        local before = reader().weread.library_db:readTimeReceipts().seconds
        wait_for("live receipt " .. turn, function()
            return reader().weread.library_db:readTimeReceipts().seconds >= before + 30
        end, 42)
        local after_write = state()
        local sent = after_write.read_reports[#after_write.read_reports]
        local local_position = current_position()
        assert(sent.rt == 30 and sent.chapterUid == local_position.chapter_uid
            and sent.chapterOffset == local_position.chapter_offset,
            "live receipt lost the exact local position")
        api("/__control", { gateway_progress = {
            chapterUid = 1, chapterIdx = 1, chapterOffset = 0,
            progress = 0, updateTime = 1,
        } })
        heartbeat()
        spin(1.8)
        assert(not choice_dialog(), "online heartbeat opened a redundant progress choice")
        local record = reader().weread.settings:get("books", {})["900001"]
        assert(type(record.pending_upload_position) ~= "table",
            "online heartbeat created an offline progress row")
        api("/__control", { gateway_progress = false })
    end
    local final = state()
    evidence.live_seconds = positive_seconds(final)
    evidence.read_reports = final.read_reports
    evidence.reconnect_captures = captured
    assert(evidence.live_seconds == 60 and #captured == 0,
        "normal online cadence entered reconnect capture")

elseif case == "phone-forward" or case == "phone-in-page"
    or case == "phone-rewind" then
    local manager = close_to_manager()
    wait_for("close drain", function()
        return manager.library_db:readTimeStatus().pending == 0
    end)
    if case == "phone-rewind" then
        set_phone(13400, 46, "phone-forward")
        reopen(manager)
        wait_for("initial phone choice", choice_dialog)
        choose_cloud()
        wait_for("initial phone jump", function() return reader():getCurrentPage() > 1 end)
        manager = close_to_manager()
        wait_for("second close drain", function()
            return manager.library_db:readTimeStatus().pending == 0
        end)
        set_phone(0, 0, "phone-rewind")
    elseif case == "phone-in-page" then
        set_phone(13430, 46, "phone-in-page")
    else
        set_phone(13400, 46, "phone-forward")
    end
    local before = state()
    reopen(manager)
    wait_for("phone progress choice", choice_dialog)
    evidence.choice_text = choice_dialog().text
    assert(state().progress["900001"].chapterOffset
            == before.progress["900001"].chapterOffset,
        "Kindle overwrote phone progress before the choice")
    choose_cloud()
    local expected_page = case == "phone-rewind" and 1 or 3
    wait_for("phone jump", function() return reader():getCurrentPage() == expected_page end)
    spin(0.5)
    evidence.page = reader():getCurrentPage()
    evidence.position = position(current_position())
    if case == "phone-in-page" then
        assert(evidence.position.chapter_offset == 13400
                and evidence.position.chapter_offset
                    ~= before.progress["900001"].chapterOffset,
            "cloud in-page choice did not preserve the distinct rendered offset")
        local first_seconds = positive_seconds(state())
        wait_for("in-page live receipt", function()
            assert(not choice_dialog(),
                "in-page cloud choice reopened before the normal live receipt")
            return positive_seconds(state()) >= first_seconds + 30
        end, 42)
        local held = state()
        local held_report = held.read_reports[#held.read_reports]
        assert(held_report.rt == 30 and held_report.chapterOffset == 13430
                and held.progress["900001"].chapterOffset == 13430,
            "stationary rendered page replaced the exact chosen cloud offset")
        heartbeat()
        spin(1.8)
        assert(not choice_dialog()
                and state().progress["900001"].chapterOffset == 13430,
            "idle heartbeat reopened or overwrote the in-page cloud choice")

        reader().rolling:onGotoPage(2)
        wait_for("page turn position", function()
            return current_position().chapter_offset == 6700
        end)
        local turned_position = position(current_position())
        local turned_seconds = positive_seconds(state())
        wait_for("post-turn live receipt", function()
            assert(not choice_dialog(),
                "page turn reopened the settled in-page choice")
            return positive_seconds(state()) >= turned_seconds + 30
        end, 42)
        local turned = state()
        local turned_report = turned.read_reports[#turned.read_reports]
        assert(turned_report.rt == 30
                and turned_report.chapterOffset == turned_position.chapter_offset
                and turned_report.chapterOffset ~= 13430,
            "next live tick did not adopt the actual new local position")
        evidence.cloud = turned.progress["900001"]
        evidence.held_cloud_offset = held_report.chapterOffset
        evidence.rendered_offset = 13400
        evidence.turned_position = turned_position
        evidence.turned_report = turned_report
        evidence.read_reports = turned.read_reports
    else
        local after = state()
        evidence.cloud = after.progress["900001"]
        evidence.new_mutations = mutations(after) - mutations(before)
        assert(evidence.new_mutations == 0,
            "cloud choice emitted an unexpected progress mutation")
    end

elseif case == "tail" then
    local before = state()
    spin(5.1)
    local manager = close_to_manager()
    local SyncStatus = require("weread.lib.sync_status")
    local closed = SyncStatus.get(manager)
    evidence.closed_pending_seconds = closed.pending_seconds
    evidence.closed_posted_seconds = positive_seconds(state()) - positive_seconds(before)
    assert(closed.pending_seconds == 0 and evidence.closed_posted_seconds == 0,
        "healthy short close appeared as offline work or posted early")
    reopen(manager)
    wait_for("carried tail reaches normal interval", function()
        return positive_seconds(state()) - positive_seconds(before) >= 30
    end, 34)
    local final = state()
    evidence.posted_seconds = positive_seconds(final) - positive_seconds(before)
    evidence.reports = final.read_reports
    assert(evidence.posted_seconds >= 30 and evidence.posted_seconds <= 31,
        "short online sessions were not conserved into one normal report")

elseif case == "offline-tail" then
    connected = false
    reader():handleEvent(Event:new("NetworkDisconnected"))
    api("/__control", { times = -1, status = 503 })
    local before = state()
    spin(3.1)
    local manager = close_to_manager()
    local SyncStatus = require("weread.lib.sync_status")
    local pending = SyncStatus.get(manager)
    evidence.offline_pending_seconds = pending.pending_seconds
    assert(pending.pending_seconds >= 3,
        "real offline close was hidden as a healthy online tail")
    connected = true
    api("/__control", { times = 0 })
    FileManager.instance:handleEvent(Event:new("NetworkConnected"))
    wait_for("offline tail replay", function()
        return manager.library_db:readTimeStatus().pending == 0
            and positive_seconds(state()) > positive_seconds(before)
    end)
    evidence.replayed_seconds = positive_seconds(state()) - positive_seconds(before)
end

local output = assert(io.open(root .. "/evidence/boundaries-result.json", "wb"))
output:write(json.encode(evidence))
output:close()
if ReaderUI.instance then ReaderUI.instance:onClose() end
if FileManager.instance then FileManager.instance:onClose() end
UIManager:quit()
print("PASS: sync boundary " .. case)
