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
local virtual_now = os.time()
local virtual_active = reader().weread.read_report.active_now()
reader().weread.read_report.now = function() return virtual_now end
reader().weread.read_report.active_now = function() return virtual_active end
local function spin(seconds)
    local ending = socket.gettime() + seconds
    repeat UIManager:handleInput(); socket.sleep(0.02) until socket.gettime() >= ending
end
local function reports()
    local positive = {}
    for _, item in ipairs(api("/__state").read_reports) do
        if item.rt > 0 then positive[#positive + 1] = item end
    end
    return positive
end
local function heartbeat()
    local coordinator = assert(FileManager.instance.weread.offline_sync)
    UIManager:unschedule(coordinator.heartbeat)
    UIManager:scheduleIn(0.01, coordinator.heartbeat)
end
offline()
virtual_now = virtual_now + 65
virtual_active = virtual_active + 65
reader():handleEvent(Event:new("Suspend"))
local expected = reader().weread.library_db:readTimeStatus().pending
assert(expected >= 65 and expected <= 66, "virtual offline session accounted once")
reader():onClose()
FileManager:showFiles(root .. "/books")
wait_for("file manager", function() return FileManager.instance and FileManager.instance.weread end)
FileManager.instance.weread.read_report.now = function() return virtual_now end
api("/__control", { times = 0 })
connected = true
heartbeat()
wait_for("first 30-second slice", function() return #reports() == 1 and FileManager.instance.weread.read_report.job == nil
    and FileManager.instance.weread.library_db:readTimeStatus().pending == expected - 30 end)
assert(reports()[1].rt == 30, "first slice bounded to 30 seconds")
for _ = 1, 3 do
    FileManager.instance:handleEvent(Event:new("NetworkConnected"))
    heartbeat()
    spin(0.2)
end
assert(#reports() == 1, "repeated triggers cannot accelerate replay")
virtual_now = virtual_now + 29
heartbeat()
spin(0.4)
assert(#reports() == 1, "29 seconds is still inside replay cooldown")
virtual_now = virtual_now + 1
heartbeat()
wait_for("second 30-second slice", function() return #reports() == 2 and FileManager.instance.weread.read_report.job == nil
    and FileManager.instance.weread.library_db:readTimeStatus().pending == expected - 60 end)
assert(reports()[2].rt == 30, "second slice bounded to 30 seconds")
virtual_now = virtual_now + 30
heartbeat()
wait_for("final remaining slice", function()
    return #reports() == 3 and FileManager.instance.weread.library_db:readTimeStatus().pending == 0
end)
local result = reports()
assert(result[3].rt == expected - 60, "remaining exact seconds")
virtual_now = virtual_now + 60
heartbeat()
FileManager.instance:handleEvent(Event:new("NetworkConnected"))
spin(0.5)
assert(#reports() == 3, "acknowledged slices never replay")
local out = assert(io.open(root .. "/evidence/chunks-result.json", "wb"))
out:write(json.encode({ expected_seconds = expected, positive_reports = result,
    clock_injected = true, repeated_triggers_blocked = true, cooldown_boundary = { 29, 30 } }))
out:close()
FileManager.instance:onClose()
UIManager:quit()
print("PASS: real queued 65-second session -> FileManager heartbeat 30/30/remainder; clock boundary cooldown and idempotence")
