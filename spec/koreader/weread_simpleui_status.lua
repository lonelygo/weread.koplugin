-- Real KOReader + official SimpleUI 3.1.0 + packaged WeRead candidate.
-- The status is driven through product queues and the real mock HTTP service.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
local root = assert(home:match("^(.*)/profile$"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")

local Screen = require("device").screen
-- KOReader's dummy framebuffer defaults to 600x800 regardless of SDL env.
-- Resize its real BlitBuffer before loading SimpleUI or any of its widgets.
local screen_width = tonumber(os.getenv("EMULATE_READER_W")) or 600
local screen_height = tonumber(os.getenv("EMULATE_READER_H")) or 800
local screen_dpi = tonumber(os.getenv("EMULATE_READER_DPI")) or 167
if Screen:getWidth() ~= screen_width or Screen:getHeight() ~= screen_height then
    local BB = require("ffi/blitbuffer")
    Screen.bb:free()
    Screen.bb = BB.new(screen_width, screen_height)
    Screen.bb:fill(BB.COLOR_WHITE)
    Screen.screen_size = Screen:getRawSize()
end
Screen:setDPI(screen_dpi)
assert(Screen:getWidth() == screen_width and Screen:getHeight() == screen_height,
    "requested framebuffer dimensions were not installed")
assert(Screen:getDPI() == screen_dpi, "requested framebuffer DPI was not installed")
print(string.format("Framebuffer: %dx%d at %d DPI",
    screen_width, screen_height, screen_dpi))

local lfs = require("libs/libkoreader-lfs")
local function mkdir(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        lfs.mkdir(current)
    end
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    file:write(value)
    file:close()
end
local cache = home .. "/weread-mock/cache"
local books = {
    { "900001", "山谷来信 · 离线测试", 0.67 },
    { "900002", "海边手记", 0.40 },
    { "900003", "纸上行旅", 0.21 },
}
for _, item in ipairs(books) do
    local dir = cache .. "/" .. item[1]
    mkdir(dir)
    item.path = dir .. "/" .. item[2] .. " - offline.html"
    write(item.path, '<html><head><meta charset="utf-8"/><title>' .. item[2]
        .. '</title></head><body><h1>' .. item[2]
        .. '</h1><p>用于 SimpleUI 首页同步状态验收的本地书。</p></body></html>')
end

G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("flash_ui", false)
require("gettext").changeLang("zh_CN")

local NetworkMgr = require("ui/network/manager")
local connected = false
local wifi_wake_calls = 0
NetworkMgr.isConnected = function() return connected end
for _, name in ipairs({ "turnOnWifi", "enableWifi", "restoreWifiAsync",
        "turnOnWifiAndWaitForConnection", "promptWifiOn" }) do
    NetworkMgr[name] = function()
        wifi_wake_calls = wifi_wake_calls + 1
        return false
    end
end

local loader = require("pluginloader")
local enabled = { coverbrowser = true, simpleui = true, weread = true, statistics = true }
local disabled = {}
for _, item in ipairs(loader:_discover()) do
    if not enabled[item.name] then disabled[item.name] = true end
end
G_reader_settings:saveSetting("plugins_disabled", disabled)
loader.enabled_plugins = nil
loader:loadPlugins()

local socket = require("socket")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local ReadHistory = require("readhistory")
local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
local DocSettings = require("docsettings")
local util = require("ffi/util")
local json = require("json")
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

local function spin(seconds)
    local deadline = socket.gettime() + seconds
    repeat UIManager:handleInput(); socket.sleep(0.02) until socket.gettime() >= deadline
end
local function wait_for(label, predicate, timeout)
    local deadline = socket.gettime() + (timeout or 12)
    repeat
        UIManager:handleInput()
        if predicate() then return end
        socket.sleep(0.02)
    until socket.gettime() > deadline
    error("timeout: " .. label)
end
local function tap(x, y)
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "tap", pos = Geom:new{ x = x, y = y },
        time = require("ui/time").now(),
    }))
end
local function swipe(direction)
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "swipe", direction = direction,
        pos = Geom:new{ x = 300, y = 175 }, distance = 150,
        time = require("ui/time").now(),
    }))
end
local function close_setup_notices()
    for _ = 1, 5 do
        local top = UIManager._window_stack[#UIManager._window_stack].widget
        if top.name == "homescreen" then return end
        local message = tostring(top.text)
        assert(message:find("数据库", 1, true) or message:find("转换", 1, true),
            "unexpected startup overlay: " .. message)
        UIManager:close(top)
        spin(0.1)
    end
    error("startup notices did not close")
end
local function find_current(widget, seen)
    if type(widget) ~= "table" or seen[widget] then return end
    seen[widget] = true
    if widget._fp and widget.onTapBook then return widget end
    for index = 1, #widget do
        local found = find_current(widget[index], seen)
        if found then return found end
    end
end
local function screen_shot(name)
    Screen:shot(root .. "/evidence/" .. name .. ".png")
end

local now = os.time()
for index, item in ipairs(books) do
    local metadata = DocSettings:open(item.path)
    metadata:saveSetting("doc_props", { title = item[2], authors = "测试作者" })
    metadata:saveSetting("percent_finished", item[3])
    metadata:flush()
    ReadHistory:addItem(item.path, now - index * 60)
end

FileManager:showFiles(cache)
wait_for("FileManager plugins", function()
    return FileManager.instance and FileManager.instance.weread
        and FileManager.instance.simpleui
end)
local plugin = FileManager.instance.weread
local current_path = assert(util.realpath(books[1].path))
plugin.settings:set("books", { ["900001"] = {
    book_id = "900001", title = books[1][2], author = "测试作者",
    cached_file = current_path,
} })
plugin.settings:flush()

local adapter = require("integrations.simpleui")
assert(adapter.registered == true, "WeRead SimpleUI module was not registered")
local Registry = require("modules/moduleregistry")
assert(Registry.get("weread_sync_status"), "registered module absent from official registry")
local store = require("infra/sui_store")
local layout = assert(store:get("simpleui_layout"), "SimpleUI layout")
local page = assert(layout.pages and layout.pages[1], "SimpleUI first page")
local currently, status
for index, id in ipairs(page.modules or {}) do
    id = type(id) == "table" and id.id or id
    if id == "currently" then currently = index end
    if id == "weread_sync_status" then status = index end
end
assert(currently and status == currently + 1,
    "first install must place sync status immediately after Currently Reading")
assert(store:get("simpleui_hs_weread_sync_status_enabled") == true,
    "first install must enable the status module")

FileManager.instance.simpleui:onSimpleUIGoHomescreen()
local Home = require("screens/sui_homescreen")
wait_for("SimpleUI Home", function() return Home.getInstance("hs") end)
spin(0.4)
close_setup_notices()
adapter:refresh()
local home_screen = assert(Home.getInstance("hs"))
local function status_row() return adapter.mounts[home_screen] end
local function status_text() return status_row().status_label.text end
wait_for("mounted status line", function()
    return status_row() and status_row().dimen and status_row().dimen.y > 0
end)
assert(status_text():find("暂无待传", 1, true), status_text())
local initial_status_dimen = status_row().dimen:copy()
local card = assert(find_current(home_screen, {}), "Currently Reading card missing")
local card_dimen = card.dimen:copy()
assert(card_dimen.y + card_dimen.h <= initial_status_dimen.y,
    "status line overlaps the book card")
screen_shot("01-empty")

local database = plugin.library_db
assert(database:enqueueReadTime("900001", 30, {
    book_id = "900001", chapter_uid = 1, progress = 67,
}))
local annotations, changed = {}, {}
for index = 1, 2 do
    annotations[index] = {
        id = "simpleui-demo-" .. index,
        page = "xp" .. index, pos0 = "xp" .. index, pos1 = "end" .. index,
        text = "窗外的风穿过树梢，带来远处山谷的回声。",
        note = "私密笔记" .. index, drawer = "lighten",
        datetime = "2026-11-23 11:10:0" .. index,
        _weread_upload = {
            bookId = "900001", chapterUid = 1, chapterIdx = 1,
            bookVersion = 17, range = "143-162",
            markText = "窗外的风穿过树梢，带来远处山谷的回声。",
        },
    }
    changed[database.annotationLocalId("900001", current_path, annotations[index])] = true
end
assert(database:putLocalAnnotationSnapshot(
    "900001", current_path, annotations, { changed = changed }))
wait_for("pending Home summary", function()
    return status_text():find("30 秒", 1, true)
        and status_text():find("2 条", 1, true)
end)
assert(status_row().dimen.x == initial_status_dimen.x
    and status_row().dimen.y == initial_status_dimen.y
    and status_row().dimen.w == initial_status_dimen.w
    and status_row().dimen.h == initial_status_dimen.h,
    "status change moved the mounted row")
screen_shot("02-pending")

local function open_details()
    local row = status_row().dimen
    tap(row.x + row.w - 7, row.y + math.floor(row.h / 2))
    local dialog
    wait_for("sync details", function()
        dialog = UIManager._window_stack[#UIManager._window_stack].widget
        return dialog.title == "微信读书同步状态" and dialog:getContentSize()
    end)
    return dialog
end
local function tap_action(dialog, id)
    local button = assert(dialog:getButtonById(id))
    local d = button.dimen
    tap(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
end
local function back_on_home()
    return UIManager._window_stack[#UIManager._window_stack].widget == home_screen
end
local dialog = open_details()
local bounds = dialog:getContentSize()
assert(bounds.w < screen_width and bounds.h < screen_height * 0.6, "pending details should fit a compact popup")
assert(math.abs(bounds.x * 2 + bounds.w - screen_width) <= 2
    and math.abs(bounds.y * 2 + bounds.h - screen_height) <= 2, "popup should be centered")
local close = assert(dialog:getButtonById("close"))
local upload = assert(dialog:getButtonById("upload"))
assert(close.text == "关闭" and upload.text == "立即上传" and upload.enabled)
assert(close.dimen.y == upload.dimen.y and close.dimen.h == upload.dimen.h
    and close.dimen.x + close.dimen.w <= upload.dimen.x, "actions should share one row")
assert(wifi_wake_calls == 0, "viewing sync status woke Wi-Fi")
screen_shot("03-details")
tap_action(dialog, "close")
wait_for("close returns to Home", back_on_home)
local SyncStatus = require("weread.lib.sync_status")
assert(SyncStatus.get(plugin).pending_seconds == 30 and SyncStatus.get(plugin).pending_annotations == 2)

tap_action(open_details(), "upload")
wait_for("offline feedback", function()
    return UIManager._window_stack[#UIManager._window_stack].widget.text == "当前未联网，待传记录会保留在本机。"
end)
wait_for("offline upload returns to Home", back_on_home)
assert(SyncStatus.get(plugin).pending_seconds == 30 and SyncStatus.get(plugin).pending_annotations == 2)
assert(wifi_wake_calls == 0, "offline upload woke Wi-Fi")

dialog = open_details()
-- No network event: the tap itself must reach the manual coordinator from Home.
connected = true
tap_action(dialog, "upload")
wait_for("upload returns to Home", back_on_home)
wait_for("real service acknowledgements", function()
    local snapshot = SyncStatus.get(plugin)
    return snapshot.state == "synced" and snapshot.last_confirmed_at ~= nil
end, 45)
local acknowledged = SyncStatus.get(plugin)
assert(acknowledged.pending_seconds == 0 and acknowledged.pending_annotations == 0,
    "acknowledged queue did not drain")
wait_for("acknowledgement shown on Home", function() return status_text():find("已同步", 1, true) end)
screen_shot("05-synced")

local hidden_row = assert(status_row())
local hidden_page_snapshot = status_text()
connected = false
swipe("west")
wait_for("second Home page", function() return home_screen._current_page == 2 end)
local recent = home_screen._ctx_cache.recent_fps
assert(recent[1] == util.realpath(books[2].path)
    and recent[2] == util.realpath(books[3].path),
    "Recent page is not ordered after the current book")
local pending_position = {
    book_id = "900001", chapter_uid = 2, chapter_idx = 2,
    progress = 45, chapter_offset = 120, captured_at = os.time(),
}
assert(plugin.progress_sync:_save_pending(pending_position, "simpleui_acceptance"))
wait_for("progress-only status", function()
    local snapshot = SyncStatus.get(plugin)
    return snapshot.pending_progress == 1 and snapshot.state == "pending"
end)
spin(0.2)
assert(hidden_row.status_label.text == hidden_page_snapshot,
    "background status refresh mutated a hidden Home page mount")
screen_shot("04-recent")
swipe("east")
wait_for("return to first Home page", function() return home_screen._current_page == 1 end)
wait_for("latest status after returning to page one", function()
    return status_text():find("进度", 1, true)
end)
assert(status_text():find("进度", 1, true), status_text())
screen_shot("06-progress")

assert(plugin.progress_sync:_persist("900001", {
    title = string.rep("关于阅读与记忆的长书名", 55),
    pending_upload_blocked = true,
    pending_upload_remote = { chapter_uid = 6, progress = 98 },
    last_sync_error = "offline_progress_conflict",
}))
wait_for("conflict status", function()
    local snapshot = SyncStatus.get(plugin)
    return snapshot.state == "conflict" and snapshot.conflict_count == 1
end)
wait_for("conflict shown on Home", function() return status_text():find("需选择进度", 1, true) end)
screen_shot("07-conflict")

-- Exercise wrapped conflict details through the normal Home and touch paths.
dialog = open_details()
local scroll = dialog._added_widgets[1]
local _, last_visible = scroll.text_widget:getVisibleHeightRatios()
assert(last_visible < 1, "long conflict details should scroll")
local footer = dialog:getButtonById("upload").dimen:copy()
assert(dialog:getContentSize().h < screen_height * 0.8 and scroll.dimen.y + scroll.dimen.h <= footer.y)
tap(scroll.dimen.x + math.floor(scroll.dimen.w * 0.75), scroll.dimen.y + math.floor(scroll.dimen.h / 2))
wait_for("scrolling reaches more conflict text", function()
    return scroll.text_widget:getVisibleHeightRatios() > 0
end)
assert(dialog:getButtonById("upload").dimen.y == footer.y, "scrolling moved the footer")
tap_action(dialog, "close")
wait_for("closing long details returns to Home", back_on_home)

local final_card = assert(find_current(home_screen, {}), "book card missing after status updates")
assert(final_card.dimen.y == card_dimen.y and final_card.dimen.h == card_dimen.h,
    "status updates moved the book card")
tap(final_card.dimen.x + math.floor(final_card.dimen.w / 2),
    final_card.dimen.y + math.floor(final_card.dimen.h / 2))
wait_for("one-tap resume", function()
    return ReaderUI.instance and ReaderUI.instance.document
        and ReaderUI.instance.document.file == current_path
end)
assert(wifi_wake_calls == 0, "Home interactions woke Wi-Fi")

local evidence = {
    empty = "暂无待传记录",
    pending = "待传 30 秒 · 2 条标注",
    synced_at = acknowledged.last_confirmed_at,
    progress = "待传 1 本书的进度",
    conflict = "1 本书需选择进度",
    wifi_wake_calls = wifi_wake_calls,
    card = { x = card_dimen.x, y = card_dimen.y, w = card_dimen.w, h = card_dimen.h },
    status = { x = initial_status_dimen.x, y = initial_status_dimen.y,
        w = initial_status_dimen.w, h = initial_status_dimen.h },
}
write(root .. "/evidence/result.json", json.encode(evidence))
UIManager:quit()
print("PASS: SimpleUI status placement, queue states, details, pages, ACK, conflict, one-tap resume")
