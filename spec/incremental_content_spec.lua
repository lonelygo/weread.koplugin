package.path = "./?.lua;./?/init.lua;" .. package.path

local archives = {
    ["/cache/one.epub"] = {
        ["OEBPS/style.css"] = "body{color:#111}",
        ["OEBPS/text/chapter-1.xhtml"] =
            '<html><head><link href="../style.css"/></head><body><p>one</p><img src="../images/pic.jpg"/></body></html>',
        ["OEBPS/images/pic.jpg"] = "\255\216\255one",
    },
    ["/cache/two.epub"] = {
        ["OEBPS/style.css"] = "body{color:#222}",
        ["OEBPS/text/chapter-2.xhtml"] =
            '<html><head><link href="../style.css"/></head><body><p>two</p><img src="../images/pic.jpg"/></body></html>',
        ["OEBPS/images/pic.jpg"] = "\255\216\255two",
    },
}
local writes = {}
local memory_extracts = {}
local build_count = 0
local candidate_paths = {}
local inject_publish_conflict = false
local conflict_manifest_path

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function()
    return { sha256_hex = function(data) return tostring(#data) end }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function(id) return "https://reader/" .. tostring(id) end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        mkdir = function(path)
            local result = os.execute("mkdir " .. string.format("%q", path)
                .. " 2>/dev/null")
            return result == true or result == 0
        end,
        lock = function() return true end,
        unlock = function() return true end,
    }
end
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({}, { __index = self }) end
    function Reader:open(path)
        self.files = archives[path]
        if not self.files then self.err = "missing archive" return false end
        self.names = {}
        for name in pairs(self.files) do self.names[#self.names + 1] = name end
        table.sort(self.names)
        return true
    end
    function Reader:iterate()
        local index = 0
        return function()
            index = index + 1
            local name = self.names[index]
            return name and { path = name } or nil
        end
    end
    function Reader:extractToMemory(name)
        memory_extracts[#memory_extracts + 1] = name
        return self.files[name]
    end
    function Reader:extractToPath(name, path)
        local file = assert(io.open(path, "wb"))
        assert(file:write(self.files[name]))
        file:close()
        return true
    end
    function Reader:close() end

    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        build_count = build_count + 1
        candidate_paths[#candidate_paths + 1] = path
        local file = assert(io.open(path, "wb"))
        file:write("PKepub-" .. tostring(build_count))
        file:close()
        writes = {}
        return true
    end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory(name, data)
        writes[name] = data
        return true
    end
    function Writer:addPath(root, path)
        local listing = assert(io.popen("ls -1 " .. string.format("%q", path)))
        for name in listing:lines() do
            local file = assert(io.open(path .. "/" .. name, "rb"))
            writes[root .. "/" .. name] = file:read("*a")
            file:close()
        end
        listing:close()
        return true
    end
    function Writer:close()
        if inject_publish_conflict and conflict_manifest_path then
            local file = assert(io.open(conflict_manifest_path, "wb"))
            file:write("generation=concurrent\nuid=1:2\nuid=1:1\n")
            file:close()
            inject_publish_conflict = false
        end
    end
    return { Reader = Reader, Writer = Writer }
end

local Content = require("weread.lib.content")
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
conflict_manifest_path = root .. "/incremental-spine.meta"
local settings = { cache_dir = root, get = function(_self, _key, default) return default end }
local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
}
local book = {
    book_id = "book", title = "Book", cache_dir = root,
    chapters = chapters, cached_chapters = {},
}
local stale_lock = assert(io.open(
    root .. "/.weread-incremental-publish-lock", "wb"))
stale_lock:write("999999999\n")
stale_lock:close()

local path = assert(Content.activate_chapter_epub(
    settings, book, chapters[2], "/cache/two.epub"))
assert(book.annotation_documents[path]
    and #book.annotation_documents[path].chapters == 1)
assert(writes["OEBPS/text/chapter-2.xhtml"]:find("two", 1, true),
    "initial chapter did not get a UID-stable XHTML path")
local same_path = assert(Content.activate_chapter_epub(
    settings, book, chapters[1], "/cache/one.epub"))
assert(same_path == path, "incremental EPUB path changed")
assert(#book.annotation_documents[path].chapters == 2,
    "aggregate descriptor did not keep both chapters")
assert(book.annotation_documents[path].chapters[1].chapterUid == 2
        and book.annotation_documents[path].chapters[2].chapterUid == 1,
    "front-inserted cache changed the append-only spine order")
local opf = assert(writes["OEBPS/content.opf"])
local spine_two = assert(opf:find('idref="chapter_2"', 1, true))
local spine_one = assert(opf:find('idref="chapter_1"', 1, true))
assert(spine_two < spine_one, "existing DocFragment moved after front insertion")
assert(opf:find('idref="chapter_1" linear="no"', 1, true),
    "backfilled chapter would re-enter the forward linear reading flow")
assert(writes["OEBPS/text/chapter-1.xhtml"]:find("one", 1, true))
assert(writes["OEBPS/text/chapter-2.xhtml"]:find("two", 1, true))
assert(writes["OEBPS/images/1-pic.jpg"] == "\255\216\255one")
assert(writes["OEBPS/images/2-pic.jpg"] == "\255\216\255two")
assert(writes["OEBPS/styles/chapter-1.css"] == "body{color:#111}")
assert(writes["OEBPS/styles/chapter-2.css"] == "body{color:#222}")
assert(writes["OEBPS/text/chapter-1.xhtml"]:find(
    "../images/1-pic.jpg", 1, true))
assert(writes["OEBPS/text/chapter-2.xhtml"]:find(
    "../images/2-pic.jpg", 1, true))
assert(writes["OEBPS/text/chapter-1.xhtml"]:find(
    "../styles/chapter-1.css", 1, true))
assert(writes["OEBPS/text/chapter-2.xhtml"]:find(
    "../styles/chapter-2.css", 1, true))
for _, name in ipairs(memory_extracts) do
    assert(not name:match("/images/"),
        "chapter media was loaded into Lua memory: " .. name)
end

local reused_path, reused_uids, reused = Content.activate_chapter_epub(
    settings, book, chapters[2], "/cache/two.epub")
assert(reused and reused_path == path and #reused_uids == 2,
    "published chapter did not reuse the stable aggregate")
assert(build_count == 2, "cache hit unexpectedly rebuilt the full aggregate")

local stable = assert(io.open(path, "rb"))
local stable_before_failure = stable:read("*a")
stable:close()
chapters[3] = { chapterUid = 3, title = "Three" }
local failed = Content.activate_chapter_epub(
    settings, book, chapters[3], "/cache/missing.epub")
assert(not failed, "missing chapter cache unexpectedly published a new spine")
stable = assert(io.open(path, "rb"))
assert(stable:read("*a") == stable_before_failure,
    "failed aggregate build damaged the previously published EPUB")
stable:close()

archives["/cache/three.epub"] = {
    ["OEBPS/style.css"] = "body{color:#333}",
    ["OEBPS/text/chapter-3.xhtml"] =
        '<html><head><link href="../style.css"/></head><body><p>three</p></body></html>',
}
inject_publish_conflict = true
book.cached_chapters["3"] = "/cache/three.epub"
local conflicted = Content.save_incremental_book_epub(settings, book)
assert(not conflicted, "stale concurrent build overwrote a newer publication")
stable = assert(io.open(path, "rb"))
assert(stable:read("*a") == stable_before_failure,
    "publish conflict damaged the previously published EPUB")
stable:close()
assert(candidate_paths[1] ~= candidate_paths[2]
        and candidate_paths[2] ~= candidate_paths[3],
    "incremental builds reused a shared mutable workspace")

-- Before the stable reader existed, a selected batch could occupy the full-book
-- alias. Its XHTML numbers are positions within that batch, independent of UID.
local legacy = "/cache/selected.epub"
archives[legacy] = {
    ["OEBPS/text/chapter-001.xhtml"] = "<html><body><p>legacy two</p></body></html>",
    ["OEBPS/text/chapter-002.xhtml"] = "<html><body><p>legacy one</p></body></html>",
}
local migrated = {
    book_id = "legacy", title = "Legacy", cache_dir = root .. "/legacy", chapters = chapters,
    cached_full_book = legacy, cached_chapters = { ["1"] = legacy, ["2"] = legacy, ["3"] = "/cache/three.epub" },
    annotation_documents = { [legacy] = { chapters = { chapters[2], chapters[1] } } },
}
assert(Content.save_incremental_book_epub(settings, migrated))
assert(writes["OEBPS/text/chapter-1.xhtml"]:find("legacy one", 1, true))
assert(writes["OEBPS/text/chapter-2.xhtml"]:find("legacy two", 1, true))
assert(writes["OEBPS/text/chapter-3.xhtml"]:find("three", 1, true))

assert(os.execute("rm -rf " .. string.format("%q", root)))
print("incremental_content_spec: stable aggregate, spine and asset isolation passed")
