package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local archive_path = "/synthetic/legacy-175.epub"
local archive_files, archive_size = {}, 0
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if path == archive_path then
                return { size = archive_size, modification = 17 }
            end
        end,
    }
end
package.preload["ffi/archiver"] = function()
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, self) end
    function Reader:open(path) self.opened = path == archive_path; return self.opened end
    function Reader:iterate()
        local names = {}
        for name in pairs(archive_files) do names[#names + 1] = name end
        table.sort(names)
        local index = 0
        return function()
            index = index + 1
            local name = names[index]
            if name then return { path = name, size = #archive_files[name] } end
        end
    end
    function Reader:extractToMemory(path) return archive_files[path] end
    function Reader:close() self.opened = false end
    return { Reader = Reader }
end

local catalog, manifest, spine, navigation = {}, {
    '<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>',
    '<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
}, { '<itemref idref="cover"/>' }, {}
archive_files["META-INF/container.xml"] =
    '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/>'
    .. '</rootfiles></container>'
archive_files["OEBPS/text/cover.xhtml"] = "<html><body>cover</body></html>"
for index = 1, 175 do
    local uid = tostring(800000 + index * 19)
    catalog[index] = { chapterUid = uid, chapterIdx = index * 2,
        title = "Synthetic " .. tostring(index) }
    local id = "chapter_" .. tostring(index)
    local href = string.format("text/chapter-%03d.xhtml", index)
    manifest[#manifest + 1] = '<item id="' .. id .. '" href="' .. href
        .. '" media-type="application/xhtml+xml"/>'
    spine[#spine + 1] = '<itemref idref="' .. id .. '"/>'
    navigation[#navigation + 1] = '<navPoint><content src="' .. href
        .. '"/></navPoint>'
    archive_files["OEBPS/" .. href] = '<!-- weread-chapter-uid: '
        .. uid .. ' --><html><body>synthetic</body></html>'
end
archive_files["OEBPS/content.opf"] = table.concat({
    '<package><metadata><dc:identifier xmlns:dc="urn:dc">',
    'weread-synthetic-full</dc:identifier></metadata><manifest>',
    table.concat(manifest), '</manifest><spine>', table.concat(spine),
    '</spine></package>',
})
archive_files["OEBPS/toc.ncx"] = "<ncx><navMap>"
    .. table.concat(navigation) .. "</navMap></ncx>"
for _, data in pairs(archive_files) do archive_size = archive_size + #data end

package.loaded.util = {
    htmlEntitiesToUtf8 = function(value) return value end,
}
local Source = require("weread.lib.annotation_source")
local Position = require("weread.lib.annotation_upload_position")
local LibraryDB = require("weread.lib.library_db")
local OfflineAnnotations = require("weread.lib.offline_annotations")
local AnnotationStore = require("weread.lib.annotation_store")

local source_html = [[<html><body><p>合成唯一句甲</p><p>合成唯一句乙</p></body></html>]]
local source_spans = Source.index(source_html)
local target = catalog[43]
package.preload["weread.lib.annotation_source_worker"] = function()
    return { run = function()
        return {
            sources = { {
                chapter_uid = target.chapterUid,
                spans = source_spans,
                version = 17,
            } },
            repaired = { target },
            book_version = 17,
        }
    end }
end

local unique = os.tmpname()
os.remove(unique)
local values = {
    account = { user_vid = unique },
    sync = { upload_annotations = true },
    cache = { show_annotations = false },
}
local book = {
    book_id = "synthetic",
    book_version = 17,
    chapters = catalog,
    cached_file = archive_path,
    cached_full_book = archive_path,
}
values.books = { synthetic = book }
local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        local value = values[key]
        return value == nil and default or value
    end,
    set = function(_self, key, value) values[key] = value end,
    flush = function() end,
}
local db = LibraryDB:new(settings)
local database_path = db:databasePath()
local store = AnnotationStore:new(settings)
store:put("synthetic", "original", target.chapterUid, source_spans, target.chapterUid)
assert(store:get("synthetic", "original", target.chapterUid))
assert(not store:get("synthetic", "original_version", target.chapterUid))
local annotations = {
    {
        id = "legacy-highlight", drawer = "lighten", text = "合成唯一句甲",
        pos0 = "/body/DocFragment[44]/body/p[1]/text().0",
        pos1 = "/body/DocFragment[44]/body/p[1]/text().6",
    },
    {
        id = "legacy-note", drawer = "lighten", text = "合成唯一句乙",
        note = "合成私密附注",
        pos0 = "/body/DocFragment[44]/body/p[2]/text().0",
        pos1 = "/body/DocFragment[44]/body/p[2]/text().6",
    },
}
local changed, seeded = {}, {}
for _, annotation in ipairs(annotations) do
    changed[LibraryDB.annotationLocalId("synthetic", archive_path, annotation)] = true
    local copy = {}
    for key, value in pairs(annotation) do copy[key] = value end
    copy._weread_upload_error = "unmapped_document"
    seeded[#seeded + 1] = copy
end
assert(db:putLocalAnnotationSnapshot(
    "synthetic", archive_path, seeded, { changed = changed }))
local before = db:listUnlocatedAnnotations()
assert(#before == 1 and before[1].reason == "unmapped_document"
        and before[1].count == 2,
    "legacy empty-payload rows were not reproduced")

local toc = {}
for index = 1, 175 do
    toc[index] = {
        xpointer = "/body/DocFragment[" .. tostring(index + 1) .. "].0",
    }
end
local document = {
    file = archive_path,
    getToc = function() return toc end,
    getTextFromXPointers = function(_self, pos0)
        return pos0:find("p%[1%]") and "合成唯一句甲" or "合成唯一句乙"
    end,
}
local active
local worker = {
    busy = function() return active ~= nil end,
    start = function(_self, options) active = options; return true, options end,
}
local function finish()
    local options = assert(active)
    active = nil
    local ok, value = pcall(options.task, { checkCancelled = function() end })
    options.on_done(ok and { ok = true, value = value }
        or { ok = false, error = value })
end
local online, session, writes = false, 2, {}
local coordinator = OfflineAnnotations:new {
    library_db = db,
    settings = settings,
    client = {
        add_bookmark = function(_self, payload)
            writes[#writes + 1] = { kind = "highlight", payload = payload }
            return "bookmark-synthetic"
        end,
        add_private_review = function(_self, payload)
            writes[#writes + 1] = { kind = "thought", payload = payload }
            return "review-synthetic"
        end,
    },
    worker = worker,
    scheduler = { scheduleIn = function() end },
    resolver = Position,
    is_online = function() return online end,
    gate = function() return true, function() end end,
    request_sync = function() end,
    get_document = function() return document end,
    get_book = function() return book end,
    get_store = function() return store end,
    get_annotations = function() return annotations end,
    get_session = function() return session end,
}

-- Baseline capture after reopening: no annotation was created or edited.
assert(coordinator:capture("synthetic", archive_path, annotations, nil))
assert(not active and coordinator.source_repair_pending
        and book.annotation_documents[archive_path]
        and #book.annotation_documents[archive_path].chapters == 175,
    "offline reopen did not recover the trusted legacy descriptor")
local offline_payload, offline_reason = Position.resolve(document, book, annotations[1], store)
assert(offline_payload == nil and offline_reason == "missing_source_version" and #writes == 0,
    "an unversioned local source must wait for its edition before sending a mark")
online = true
assert(coordinator:on_network_connected() and active,
    "reconnect did not start source repair for old rows")
finish()
local direct_payload, direct_reason = Position.resolve(
    document, book, annotations[1], store)
assert(direct_payload, "repaired source did not resolve: " .. tostring(direct_reason))
local first_drain = coordinator:drain()
local remaining_issue = db:listUnlocatedAnnotations()[1]
assert(first_drain and active,
    "first repaired row did not enter upload: " .. tostring(first_drain)
        .. "/" .. tostring(active)
        .. "/unlocated=" .. tostring(#db:listUnlocatedAnnotations())
        .. "/reason=" .. tostring(remaining_issue and remaining_issue.reason)
        .. "/count=" .. tostring(remaining_issue and remaining_issue.count))
finish()
assert(coordinator:drain() and active)
finish()
assert(#writes == 2 and writes[1].payload.chapterUid == tonumber(target.chapterUid)
        and writes[2].payload.chapterUid == tonumber(target.chapterUid),
    "legacy highlight and thought did not use the chapter selected by TOC order")
assert(db:localAnnotationStatus().synced == 2
        and #db:listUnlocatedAnnotations() == 0,
    "repaired legacy rows did not leave the unlocated queue")

os.remove(database_path)
os.remove(database_path .. "-wal")
os.remove(database_path .. "-shm")
helper.cleanup()
print("legacy_full_annotation_repair_spec: 175-chapter reopen and reconnect passed")
