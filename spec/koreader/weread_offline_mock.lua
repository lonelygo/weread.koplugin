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
local offline_start
local function offline()
    offline_start = #api("/__state").requests
    connected = false
    api("/__control", { times = -1, status = 503 })
    reader():handleEvent(require("ui/event"):new("NetworkDisconnected"))
end
local function online()
    local requests = api("/__state").requests
    for index = offline_start + 1, #requests do
        local path = requests[index].path
        assert(path ~= "/web/book/addBookmark" and path ~= "/web/book/removeBookmark"
            and path ~= "/web/review/add" and path ~= "/web/review/delete",
            "offline annotation contacted the service: " .. path)
    end
    api("/__control", { times = 0 })
    connected = true
    reader():handleEvent(require("ui/event"):new("NetworkConnected"))
end
local function counts()
    return reader().weread:_offlineAnnotationCoordinator():status().counts
end
local function add(phrase, note, stamp)
    local found = assert(reader().document:findAllText(phrase, true, 0, 20, false))[1]
    assert(found, "selection found")
    reader().highlight.selected_text = {
        pos0 = found.start, pos1 = found["end"], text = phrase,
        drawer = "lighten", note = note, datetime = stamp,
    }
    local debug_file = assert(io.open(root .. "/evidence/selection-debug.json", "wb"))
    debug_file:write(json.encode({ toc = reader().document:getToc(), selection = reader().highlight.selected_text,
        book = book() }))
    debug_file:close()
    local index = reader().highlight:saveHighlight(false)
    reader().highlight.selected_text = nil
    return reader().annotation.annotations[index]
end
local function find_note()
    for i, item in ipairs(reader().annotation.annotations) do
        if item.note then return i, item end
    end
    error("native note missing")
end
local function idle(label)
    wait_for(label, function()
        local c = counts()
        return (c.synced or 0) == 2 and not reader().weread.offline_annotations:status().busy
    end)
end
assert(api("/__state").annotation_writes[1] == nil, "no writes before test")
offline()
add("这是第1章的第1段", nil, "2026-11-20 12:00:01")
add("这是第1章的第2段", "离线合成私密笔记", "2026-11-20 12:00:02")
assert((counts().local_only or 0) == 2, "two durable offline writes queued: " .. json.encode(counts()))
assert(#api("/__state").annotation_writes == 0, "offline means no writes")
local before = reader()
reader():reloadDocument()
wait_for("offline reader restart", function() return ReaderUI.instance and reader() ~= before end)
assert(#reader().annotation.annotations == 2, "native annotations persist across reader restart")
assert((counts().local_only or 0) == 2, "pending queue survives reader restart")
online()
idle("two annotations acknowledged")
local state = api("/__state")
assert(#state.annotation_writes == 2, "exactly two first uploads")
assert(next(state.bookmarks) and next(state.private_reviews), "bookmark and private note persisted remotely")
-- Repeated reconnect and unchanged capture must not duplicate writes.
reader():handleEvent(require("ui/event"):new("NetworkConnected"))
reader().weread:_captureLocalAnnotationSnapshot()
local until_time = socket.gettime() + 1.5
while socket.gettime() < until_time do UIManager:handleInput(); socket.sleep(0.03) end
assert(#api("/__state").annotation_writes == 2, "reconnect/snapshot idempotence")
-- Native Edit note UI and its Save callback, while offline.
offline()
local index = find_note()
reader().highlight:editNote(index, false)
local input
for _, entry in ipairs(UIManager._window_stack) do
    if entry.widget.getInputText and entry.widget.setInputText then input = entry.widget end
end
assert(input, "native note editor")
input:setInputText("离线修改后的私密笔记")
local saved = false
for _, row in ipairs(input.buttons) do
    for _, button in ipairs(row) do
        if button.is_enter_default then button.callback(); saved = true end
    end
end
assert(saved, "native Save action")
assert(#api("/__state").annotation_writes == 2, "offline edit not sent")
online()
wait_for("note edit upload", function()
    local s = api("/__state")
    for _, item in pairs(s.private_reviews) do
        if item.content == "离线修改后的私密笔记" then
            return #s.annotation_writes == 4 and not reader().weread.offline_annotations:status().busy
        end
    end
end)
-- Native deletion, including deletion of the last annotation.
offline()
while #reader().annotation.annotations > 0 do reader().highlight:deleteHighlight(1) end
assert(#api("/__state").annotation_writes == 4, "offline deletions not sent")
online()
wait_for("remote removals", function()
    local s = api("/__state")
    return next(s.bookmarks) == nil and next(s.private_reviews) == nil
        and #s.annotation_writes == 6 and not reader().weread.offline_annotations:status().busy
end)
local final = api("/__state")
assert(reader().document.file == stable, "same book throughout")
local evidence = assert(io.open(root .. "/evidence/offline-result.json", "wb"))
evidence:write(json.encode({ writes = final.annotation_writes, counts = counts(),
    offline_create = true, reader_restart = true, edit = true, delete = true, idempotence = true }))
evidence:close()
reader():onClose()
UIManager:quit()
print("PASS: native offline highlight/note -> reader restart -> private upload -> idempotent reconnect -> native edit/delete")
