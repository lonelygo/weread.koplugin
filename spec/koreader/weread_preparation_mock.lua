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
local FileManager = require("apps/filemanager/filemanager")
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
local function reader() return assert(ReaderUI.instance) end
local function plugin() return (ReaderUI.instance or FileManager.instance).weread end
local id = "900001"
if os.getenv("WEREAD_PREP_ZH") then G_reader_settings:saveSetting("language", "zh_CN") end
local tr = require("weread.lib.i18n").tr
local function range(index)
    return require("ffi/util").template(tr("Offline through chapter %1"), index)
end
local function book() return plugin().settings:get("books", {})[id] end
local function widget(predicate)
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if predicate(w) then return w end
    end
end
local function footer(text)
    UIManager:forceRePaint()
    for _, action in ipairs(plugin()._book_detail_view._footer_actions) do
        if action.text == tr(text) then return action:onTapFooterAction() end
    end
    error("missing footer action: " .. text)
end
local function spin()
    return assert(widget(function(w) return w.title_text == tr("Prepare chapters") and w.value_widget end))
end
local function button(dialog, text)
    for _, row in ipairs(dialog.layout) do
        for _, b in ipairs(row) do
            if b.text == tr(text) then return b:onTapSelectButton() end
        end
    end
    error("missing dialog button: " .. text)
end
local function ready()
    local popup = widget(function(w) return w.text and type(w.text) == "string"
        and w.text:find(tr("Selected chapters are ready."), 1, true) end)
    if popup then UIManager:close(popup); return true end
end
local function detail()
    plugin():showBookRecord(book())
    wait_for("book detail", function() return plugin()._book_detail_view end)
end
local function close_to_shelf()
    reader():onClose()
    FileManager:showFiles(root .. "/books")
    wait_for("file manager", function() return FileManager.instance and FileManager.instance.weread end)
    plugin():showBookshelf()
    wait_for("shelf", function() return plugin().shelf_view and not plugin().shelf_view.refreshing end)
end

FileManager:showFiles(root .. "/books")
wait_for("manager ready", function() return FileManager.instance and FileManager.instance.weread end)
local initial = plugin()
if os.getenv("WEREAD_PREP_ZH") then
    local shelf_config = initial.settings:get("shelf")
    shelf_config.view_mode = "cover"
    initial.settings:set("shelf", shelf_config)
end
local config = initial.settings:get("cache")
config.auto_prefetch_next_chapter, config.show_annotations = false, false
initial.settings:set("cache", config)
local sync = initial.settings:get("sync")
sync.upload_on_close, sync.pull_on_open = false, false
initial.settings:set("sync", sync)
initial.settings:flush()
initial:showBookshelf()
wait_for("first shelf", function() return initial.shelf_view and #initial.shelf_view.books > 0 end)
local item
for _, candidate in ipairs(initial.shelf_view.books) do
    if tostring(candidate.bookId or candidate.book_id) == id then item = candidate end
end
initial.shelf_view.on_select(assert(item), "books")
wait_for("new book detail", function() return initial._book_detail_view end)
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/start-detail.png")
footer("Start reading")
wait_for("first chapter opens directly", function()
    assert(not widget(function(w) return w.ok_text == tr("Read now") end), "unexpected second confirmation")
    return ReaderUI.instance and book() and reader().document.file == book().incremental_reader_file
end)
local stable = reader().document.file
local chapters = plugin():ensureChaptersLoaded(book())
detail()
footer("Prepare next 5")
assert(spin().value_widget:getValue() == 5)
spin():onSpinButtonPressed({ -1, false })
assert(spin().value_widget:getValue() == 4)
spin():onSpinButtonPressed({ 1, false })
assert(spin().value_widget:getValue() == 5)
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/prepare-dialog.png")
button(spin(), "Cancel")
plugin()._book_detail_view:onClose()
local initial_reader = reader()
assert(plugin().downloader:start(book(), { chapters[5] }, "chapter", { single_chapter = true, silent_completion = true }))
wait_for("nonconsecutive cache", function() return book().cached_chapters["5"] end)
assert(plugin().downloader:start(book(), { chapters[3] }, "chapter", { single_chapter = true, open_on_complete = true }))
wait_for("chapter 3 open", function()
    return ReaderUI.instance and reader() ~= initial_reader and book().active_chapter_uid == "3"
end)
local doc = reader().document
local match = assert(doc:findAllText("这是第3章的第12段", true, 0, 20, false))[1]
local note = { page = match.start, pos0 = match.start, pos1 = match["end"],
    text = doc:getTextFromXPointers(match.start, match["end"]), note = "offline-preparation-note", drawer = "lighten" }
reader().annotation:addItem(note)
reader().rolling:onGotoXPointer(match.start)
local stopped = doc:getXPointer()
assert(plugin().progress_sync:capture_local().current_chapter_uid == 3)
close_to_shelf()
local shelf = plugin().shelf_view
local shelf_item
for _, candidate in ipairs(shelf.books) do
    if tostring(candidate.bookId or candidate.book_id) == id then shelf_item = candidate end
end
assert(shelf:itemStatus(assert(shelf_item)) == range(3), shelf:itemStatus(shelf_item))
if shelf.cover_mode then
    local visible = false
    for _, cell in ipairs(shelf._item_rows) do
        if cell.book == shelf_item then visible = cell.range_text == range(3) end
    end
    assert(visible, "visible cover is missing the offline range")
    UIManager:forceRePaint()
    Screen:shot(root .. "/evidence/cover-range.png")
end
shelf.on_select(shelf_item, "books")
wait_for("middle detail", function() return plugin()._book_detail_view end)
assert(plugin()._book_detail_view.data.status_line:find(range(3), 1, true))
footer("Prepare next 5")
assert(spin().value_widget:getValue() == 3)
spin():onSpinButtonPressed({ -1, false })
assert(spin().value_widget:getValue() == 2)
button(spin(), "Prepare")
wait_for("selected ready", ready)
assert(book().cached_chapters["4"] and not book().cached_chapters["2"] and not book().cached_chapters["6"])
assert(plugin()._book_detail_view.data.status_line:find(range(5), 1, true))
footer("Prepare next 5")
spin():onSpinButtonPressed({ -1, false })
button(spin(), "Download remaining book")
if os.getenv("WEREAD_PREP_INTERRUPT") then
    wait_for("first missing chapter is staged", function()
        local job = plugin().downloader._active_job
        if job and job.prepared_paths and job.prepared_paths["2"] and job.progress_dialog then
            job.progress_dialog.buttons[1][1].callback()
            return true
        end
    end)
    wait_for("cancelled job stopped", function() return not plugin().downloader._active_job end)
    assert(book().cached_chapters["2"] and not book().cached_chapters["6"], "cancel lost a completed chapter")
    footer("Prepare next 5")
    button(spin(), "Download remaining book")
end
wait_for("full book ready", ready)
assert(plugin()._book_detail_view.data.status_line:find(tr("Whole book offline"), 1, true))
UIManager:forceRePaint()
Screen:shot(root .. "/evidence/full-offline-detail.png")
local http, ltn12 = require("socket.http"), require("ltn12")
local payload = json.encode({ status = 503, times = -1 })
local _, code = http.request{ url = plugin().settings.mock_endpoint .. "/__control", method = "POST",
    headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#payload) },
    source = ltn12.source.string(payload), sink = ltn12.sink.table({}) }
assert(code == 200)
footer("Continue reading")
wait_for("offline continue", function() return ReaderUI.instance and reader().document.file == stable end)
doc = reader().document
assert(doc:getPageFromXPointer(stopped) == reader():getCurrentPage(), "did not restore the saved page")
assert(doc:getTextFromXPointers(note.pos0, note.pos1) == note.text, "note moved after backfill")
local found = false
for _, stored in ipairs(reader().annotation.annotations) do
    if stored.note == note.note and stored.pos0 == note.pos0 and stored.pos1 == note.pos1 then found = true end
end
assert(found, "native annotation missing")
local function turn(from, to)
    local rec = book()
    plugin():ensureChaptersLoaded(rec)
    local _, ch, _, bounds = plugin():getChapterInfoFromFile(rec, stable)
    assert(ch and tonumber(ch.chapterUid) == from, "expected chapter " .. from .. ", got " .. tostring(ch and ch.chapterUid))
    reader().rolling:onGotoPage(to > from and bounds.stop_page - 1 or bounds.start_page)
    reader().rolling:onGotoViewRel(to > from and 1 or -1)
    local _, next_ch = plugin():getChapterInfoFromFile(rec, stable)
    assert(next_ch and tonumber(next_ch.chapterUid) == to, "turn " .. from .. " to " .. to .. " went to " .. tostring(next_ch and next_ch.chapterUid))
end
turn(3, 4)
turn(4, 5)
turn(5, 6)
turn(6, 5)
turn(5, 4)
turn(4, 3)
turn(3, 2)
turn(2, 1)
local visible = 0
for name in lfs.dir(book().cache_dir) do if name:match("%.epub$") then visible = visible + 1 end end
assert(visible == 1)
reader():onClose()
UIManager:quit()
print("PASS: direct start, adjustable window, all holes, offline resume, native note, catalog turns")
