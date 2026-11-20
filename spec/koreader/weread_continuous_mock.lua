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
local lfs = require("libs/libkoreader-lfs")
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
local chapters = b.chapters
assert(Content.save_catalog_cache(plugin.client, plugin.settings, b, b.chapters))
plugin.settings:set("books", { ["900001"] = b })
local config = plugin.settings:get("cache")
config.auto_prefetch_next_chapter = true
config.show_prefetch_notifications = false
config.show_annotations = false
plugin.settings:set("cache", config)
plugin.settings:flush()
local start_uid = tonumber(os.getenv("WEREAD_START_CHAPTER")) or 1
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
local original_reader = reader()
local phrase = "这是第" .. start_uid .. "章的第1段"
local matches = reader().document:findAllText(phrase, true, 0, 20, false)
assert(matches and matches[1], "first chapter searchable")
local xp0, xp1 = matches[1].start, matches[1]["end"]
local original_text = reader().document:getTextFromXPointers(xp0, xp1)
assert(original_text:find(phrase, 1, true), "anchor text")
reader().annotation:addItem{
    page = xp0, pos0 = xp0, pos1 = xp1, text = original_text,
    note = "continuous-native-note", drawer = "lighten",
}
reader().rolling:onGotoXPointer(xp0)
Screen:shot(root .. "/evidence/continuous-first.png")
local next_uid = tostring(start_uid + 1)
wait_for("background next chapter cache", function()
    local record = book()
    return record.cached_chapters and record.cached_chapters[next_uid]
        and not reader().weread.downloader:isPrefetching(record, chapters[start_uid + 1])
end)
-- Natural book-end event, through the installed plugin's ReaderStatus hook.
reader().rolling:onGotoPage(reader().document:getPageCount())
reader().status:onEndOfBook()
wait_for("reloaded next chapter", function()
    return ReaderUI.instance and reader() ~= original_reader
        and book().active_chapter_uid == next_uid
end)
assert(reader().document.file == stable, "same visible EPUB identity")
local toc = reader().document:getToc()
assert(#toc >= 2, "aggregated TOC")
assert(reader().document:isXPointerInDocument(xp0), "old anchor remains valid")
assert(reader().document:getTextFromXPointers(xp0, xp1) == original_text, "old anchor text unchanged")
local note
for _, item in ipairs(reader().annotation.annotations) do
    if item.note == "continuous-native-note" then note = item end
end
assert(note and note.pos0 == xp0 and note.pos1 == xp1, "native note survives reload")
assert(reader():getCurrentPage() > reader().document:getPageFromXPointer(xp0), "next chapter position beyond first annotation")
Screen:shot(root .. "/evidence/continuous-next.png")
-- A second automatic prefetch/reload checks repeated aggregation.
local third_uid = tostring(start_uid + 2)
wait_for("second prefetch", function()
    local record = book()
    return record.cached_chapters and record.cached_chapters[third_uid]
        and not reader().weread.downloader:isPrefetching(record, chapters[start_uid + 2])
end)
local second_reader = reader()
reader().rolling:onGotoPage(reader().document:getPageCount())
reader().status:onEndOfBook()
wait_for("second reload", function()
    return ReaderUI.instance and reader() ~= second_reader
        and book().active_chapter_uid == third_uid
end)
assert(reader().document.file == stable, "second reload same path")
assert(reader().document:getTextFromXPointers(xp0, xp1) == original_text, "second append anchor")
if start_uid > 1 then
    -- Insert an earlier chapter through the ordinary download/read prompts.
    reader().weread.downloader:cancelPrefetch("test_prepend")
    local before_prepend = reader()
    reader().weread:openChapter(book(), chapters[1])
    confirm_download()
    wait_for("prepend first chapter", function()
        for _, entry in ipairs(UIManager._window_stack) do
            if entry.widget.ok_callback and entry.widget.ok_text == "Read now" then
                local widget = entry.widget
                UIManager:close(widget)
                widget.ok_callback()
                break
            end
        end
        return ReaderUI.instance and reader() ~= before_prepend and book().active_chapter_uid == "1"
    end)
    assert(reader().document:getTextFromXPointers(xp0, xp1) == original_text, "prepend preserves existing chapter XPointer")
    local retained
    for _, item in ipairs(reader().annotation.annotations) do
        if item.note == "continuous-native-note" then retained = item end
    end
    assert(retained and retained.pos0 == xp0 and retained.pos1 == xp1, "prepend preserves native note")
end
-- Stop any new prefetch, then force all HTTP fixture responses to fail.
reader().weread.downloader:cancelPrefetch("test_offline")
local http = require("socket.http")
local ltn12 = require("ltn12")
local payload = json.encode({ status = 503, times = -1 })
local _, code = http.request{
    url = reader().weread.settings.mock_endpoint .. "/__control", method = "POST",
    headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#payload) },
    source = ltn12.source.string(payload), sink = ltn12.sink.table({}),
}
assert(code == 200, "offline fixture enabled")
local current = reader()
reader().weread:openChapter(book(), chapters[start_uid])
wait_for("offline return", function()
    return ReaderUI.instance and reader() ~= current
        and book().active_chapter_uid == tostring(start_uid)
end)
assert(reader().document.file == stable, "offline same path")
assert(reader():getCurrentPage() == reader().document:getPageFromXPointer(xp0), "offline return locates original chapter page")
assert(reader().document:getTextFromXPointers(xp0, xp1) == original_text, "offline anchor text: " .. tostring(reader().document:getTextFromXPointers(xp0, xp1)) .. " expected=" .. original_text .. " XP=" .. xp0)
local final_note
for _, item in ipairs(reader().annotation.annotations) do
    if item.note == "continuous-native-note" then final_note = item end
end
assert(final_note and final_note.pos0 == xp0 and final_note.pos1 == xp1, "offline native note endpoints")
assert(reader().document:getTextFromXPointers(final_note.pos0, final_note.pos1) == original_text, "offline native note text")
local visible = 0
for name in lfs.dir(book().cache_dir) do
    if name:match("%.epub$") then visible = visible + 1 end
end
assert(visible == 1, "one user-visible EPUB, got " .. visible)
Screen:shot(root .. "/evidence/continuous-return.png")
local evidence = assert(io.open(root .. "/evidence/continuous-result.json", "wb"))
evidence:write(json.encode({ start_chapter = start_uid, next_chapter = start_uid + 1,
    stable_path = stable, xpointer_start = xp0, xpointer_end = xp1,
    anchor_text = original_text, toc_entries = #reader().document:getToc(), visible_epubs = visible }))
evidence:close()
reader():onClose()
UIManager:quit()
print("PASS: normal open/prefetch/end -> same EPUB reload -> offline return; native note and XPointer stable")
