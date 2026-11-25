-- Real KOReader + scripts/mock_weread.py cover regression. Product methods are
-- exercised directly; only the synthetic server's documented control endpoint
-- is used to make the source cover fail and recover.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
load_plugin("weread.koplugin")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path

local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local Registry = require("document/documentregistry")
local socket = require("socket")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local http = require("socket.http")
local ltn12 = require("ltn12")
local root = assert(home:match("^(.*)/profile$"))
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

local function wait_for(label, predicate)
    local deadline = socket.gettime() + 75
    repeat
        UIManager:handleInput()
        if predicate() then return end
        socket.sleep(0.03)
    until socket.gettime() > deadline
    error("timeout: " .. label)
end

local initial = ReaderUI:new{
    dimen = require("device").screen:getSize(),
    document = Registry:openDocument(root .. "/books/开始测试.html"),
}
UIManager:show(initial)
wait_for("starter ready", function() return initial.weread ~= nil end)
local plugin = initial.weread
local Content = require("weread.lib.content")
local cache = plugin.settings:get("cache")
cache.download_book_images = false
cache.auto_prefetch_next_chapter = false
cache.show_annotations = false
plugin.settings:set("cache", cache)
plugin.settings:flush()

local function request(path, payload)
    payload = json.encode(payload or {})
    local body = {}
    local _, code = http.request{
        url = plugin.settings.mock_endpoint .. path,
        method = path == "/__state" and "GET" or "POST",
        headers = { ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload) },
        source = ltn12.source.string(payload), sink = ltn12.sink.table(body),
    }
    assert(code == 200, path .. " returned " .. tostring(code))
    return json.decode(table.concat(body))
end

local function book_info(id)
    local book = plugin.client:get_book_info(id)
    Content.ensure_reader_state(plugin.client, book)
    book.chapters = Content.fetch_catalog(plugin.client, book)
    assert(Content.save_catalog_cache(
        plugin.client, plugin.settings, book, book.chapters))
    local books = plugin.settings:get("books", {})
    books[tostring(id)] = book
    plugin.settings:set("books", books)
    plugin.settings:flush()
    return book
end

local function cover_size(path)
    local document = Registry:openDocument(path)
    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local image = assert(BookInfo:getCoverImage(document, path),
        "native screensaver cover missing")
    local width, height = image:getWidth(), image:getHeight()
    if image.free then image:free() end
    if document.close then document:close() end
    return width, height
end

local function count_visible_epubs(dir)
    local count = 0
    for name in lfs.dir(dir) do
        if name:match("%.epub$") then count = count + 1 end
    end
    return count
end

local function wait_download(label)
    wait_for(label, function() return plugin.downloader._active_job == nil end)
end

-- Reproduce a v1.8.5 partial aggregate: chapter content and stable EPUB exist,
-- but no book cover was ever fetched or embedded.
local old = book_info("900001")
local old_chapter = old.chapters[6]
local package_path = Content.save_chapter_epub(plugin.settings, old,
    old_chapter, "<p>v1.8.5 old aggregate anchor text</p>", {}, "body{}")
old.cached_chapters = { [tostring(old_chapter.chapterUid)] = package_path }
local stable = assert(Content.save_incremental_book_epub(plugin.settings, old))
assert(not Content.incremental_cover_ready(plugin.settings, old))
local old_mtime = assert(lfs.attributes(stable, "modification"))
local books = plugin.settings:get("books", {})
books["900001"] = old
plugin.settings:set("books", books)
plugin.settings:flush()
plugin:openFile(stable)
wait_for("old aggregate open", function()
    return ReaderUI.instance and ReaderUI.instance.document.file == stable
end)
plugin = ReaderUI.instance.weread
local matches = assert(ReaderUI.instance.document:findAllText(
    "v1.8.5 old aggregate anchor text", true, 0, 20, false))
local anchor = assert(matches[1])
local xp0, xp1 = anchor.start, anchor["end"]
local anchor_text = ReaderUI.instance.document:getTextFromXPointers(xp0, xp1)
ReaderUI.instance.annotation:addItem{
    page = xp0, pos0 = xp0, pos1 = xp1, text = anchor_text,
    note = "cover-repair-note", drawer = "lighten",
}
ReaderUI.instance.rolling:onGotoXPointer(xp0)

-- ReaderReady installs a per-book custom fallback. It does not rebuild the
-- already-open v1.8.5 EPUB or alter its text spine.
local repaired = plugin.settings:get("books", {})["900001"]
assert(not Content.incremental_cover_ready(plugin.settings, repaired))
assert(lfs.attributes(stable, "modification") == old_mtime,
    "legacy cover handling rewrote the open EPUB")
local fallback_w, fallback_h = cover_size(stable)
assert(math.abs(fallback_w / fallback_h - 3 / 4) < 0.01,
    "unexpected fallback cover dimensions: " .. fallback_w .. "x" .. fallback_h)
assert(ReaderUI.instance.document:getTextFromXPointers(xp0, xp1) == anchor_text)
local repaired_note
for _, item in ipairs(ReaderUI.instance.annotation.annotations) do
    if item.note == "cover-repair-note" then repaired_note = item end
end
assert(repaired_note and repaired_note.pos0 == xp0 and repaired_note.pos1 == xp1,
    "cover repair moved the native note")

-- A later successful source request replaces only the plugin-managed fallback
-- custom cover and preserves the open file and chapter fragment endpoints.
repaired = plugin.settings:get("books", {})["900001"]
assert(Content.ensure_book_cover(plugin.client, plugin.settings, repaired))
books = plugin.settings:get("books", {})
books["900001"] = repaired
plugin.settings:set("books", books)
plugin.settings:flush()
local source_w, source_h = cover_size(stable)
assert(math.abs(source_w / source_h - 2 / 3) < 0.01,
    "source cover did not replace fallback: " .. source_w .. "x" .. source_h)
assert(ReaderUI.instance.document:getTextFromXPointers(xp0, xp1) == anchor_text)
assert(lfs.attributes(stable, "modification") == old_mtime,
    "source custom cover upgrade rewrote the open EPUB")

-- A first download may begin at the last chapter. With chapter images disabled,
-- the visible incremental EPUB must still have the real book cover.
local partial = book_info("900002")
assert(plugin.downloader:start(partial, { partial.chapters[6] }, "chapter", {
    single_chapter = true, silent_completion = true, offer_read = false,
}))
wait_download("last-chapter partial download")
partial = plugin.settings:get("books", {})["900002"]
assert(partial.cached_chapters["6"] and not partial.cached_chapters["1"])
assert(count_visible_epubs(partial.cache_dir) == 1)
local partial_w, partial_h = cover_size(partial.incremental_reader_file)
assert(math.abs(partial_w / partial_h - 2 / 3) < 0.01)

-- The isolated background prefetch worker follows the same book-level cover
-- path even though chapter illustration downloads remain disabled.
local prefetched = book_info("900003")
assert(plugin.downloader:start(prefetched, { prefetched.chapters[6] }, "chapter", {
    prefetch = true, single_chapter = true, silent_completion = true,
}))
wait_download("background last-chapter prefetch")
prefetched = plugin.settings:get("books", {})["900003"]
assert(prefetched.cached_chapters["6"] and prefetched.incremental_reader_file)
local prefetch_w, prefetch_h = cover_size(prefetched.incremental_reader_file)
assert(math.abs(prefetch_w / prefetch_h - 2 / 3) < 0.01)

local state = request("/__state")
local cover_requests, illustration_requests = 0, 0
for _, event in ipairs(state.requests or {}) do
    if event.path == "/mock/cover.png" then cover_requests = cover_requests + 1 end
    if event.path == "/mock/illustration.png" then illustration_requests = illustration_requests + 1 end
end
assert(cover_requests >= 3, "book covers were not requested for every source book")
assert(illustration_requests == 0,
    "chapter image setting was ignored while downloading covers")

local evidence = assert(io.open(root .. "/evidence/covers-result.json", "wb"))
evidence:write(json.encode({
    fallback = { width = fallback_w, height = fallback_h },
    source = { width = source_w, height = source_h },
    partial = { width = partial_w, height = partial_h },
    prefetch = { width = prefetch_w, height = prefetch_h },
    cover_requests = cover_requests, illustration_requests = illustration_requests,
    stable_path = stable, xpointer_start = xp0, xpointer_end = xp1,
}))
evidence:close()
ReaderUI.instance:onClose()
UIManager:quit()
print("PASS: native fallback/source covers, v1.8.5 repair, partial and prefetch")
