package.path = "./?.lua;" .. package.path
package.loaded.util = {
    htmlEntitiesToUtf8 = function(s) return (s:gsub("&amp;", "&")) end,
}
local Source = require("weread.lib.annotation_source")
local Position = require("weread.lib.annotation_upload_position")
local Resolve = Position.resolve

local fragment = "/body[1]/DocFragment[4]"
local mark = { pos0 = fragment .. "/body/p/text().2", pos1 = fragment .. "/body/p/text().6" }
local book = { bookId = "42", annotation_documents = {
    ["book.epub"] = { chapters = { { chapterUid = 88, chapterIdx = 12, title = "水" } } },
} }
local raw = "<html><body><p>先看水&amp;光</p><p>再看水&amp;光</p></body></html>"
local spans, version = Source.index(raw), 17
local store = { get = function(_, book_id, kind, uid)
    assert(book_id == "42" and uid == "88")
    if kind == "original_version" then return version end
    return spans
end }
local doc = {
    file = "book.epub",
    getToc = function() return {{ xpointer = fragment .. ".0" }} end,
    getTextFromXPointers = function() return "水&光" end,
}
assert(not Resolve(doc, book, mark, store), "a repeated quote needs local context")
doc.getSelectedWordContext = function() return "再看", "" end
local p = assert(Resolve(doc, book, mark, store))
local selected, selected_error = Position.chapter(doc, book, mark)
assert(selected and selected.chapterUid == 88 and selected_error == nil,
    "successful chapter selection returned an error value")
assert(p.bookId == "42" and p.chapterUid == 88 and p.chapterIdx == 12 and p.bookVersion == 17)
assert(p.markText == "水&光" and Source.quote(spans, p.range) == "水&光")
local prefix = raw:sub(1, assert(raw:find("再看", 1, true)) - 1) .. "再看"
local _, rune_count = prefix:gsub("[^\128-\191]", "")
assert(p.range == rune_count .. "-" .. (rune_count + 7), "range counts original HTML runes including the entity")

version = nil
assert(not Resolve(doc, book, mark, store), "old XHTML without an edition cannot be uploaded")
version = 17
mark.pos1 = "/body/DocFragment[5]/body/p"
assert(not Resolve(doc, book, mark, store), "cross-chapter selection cannot use one chapter's range")

book.annotation_documents = nil
book.incremental_reader_file = "book.epub"
book.incremental_chapter_uids = { "88" }
book.chapters = { { chapterUid = 88, chapterIdx = 12, title = "水" } }
mark.pos1 = fragment .. "/body/p/text().6"
assert(Resolve(doc, book, mark, store)
    and book.annotation_documents["book.epub"].recovered,
    "an exact v1.8.5 incremental chapter identity did not recover its descriptor")
book.incremental_chapter_uids = { "missing" }
book.annotation_documents = nil
assert(not Resolve(doc, book, mark, store),
    "a missing legacy chapter was guessed from its title or TOC position")

-- A legacy full book may place a cover in DocFragment[1], while its TOC and
-- recovered chapter descriptor both begin with the first real chapter. The
-- fragment number is an archive position, never a chapter UID.
local legacy_chapters, legacy_toc = {}, {}
for index = 1, 175 do
    legacy_chapters[index] = {
        chapterUid = tostring(700000 + index * 17),
        chapterIdx = index * 3,
    }
    legacy_toc[index] = {
        xpointer = "/body/DocFragment[" .. tostring(index + 1) .. "].0",
    }
end
local legacy_mark = {
    pos0 = "/body/DocFragment[44]/body/p/text().0",
    pos1 = "/body/DocFragment[44]/body/p/text().4",
}
local legacy_source = Source.index("<html><body><p>唯一文本</p></body></html>")
local legacy_doc = {
    file = "legacy-full.epub",
    getToc = function() return legacy_toc end,
    getTextFromXPointers = function() return "唯一文本" end,
}
local legacy_book = {
    bookId = "legacy",
    annotation_documents = {
        ["legacy-full.epub"] = { chapters = legacy_chapters },
    },
}
local legacy_store = { get = function(_, book_id, kind, uid)
    assert(book_id == "legacy" and uid == legacy_chapters[43].chapterUid)
    return kind == "original_version" and 19 or legacy_source
end }
local legacy_payload = assert(Resolve(
    legacy_doc, legacy_book, legacy_mark, legacy_store))
assert(tostring(legacy_payload.chapterUid) == legacy_chapters[43].chapterUid,
    "DocFragment ordinal was mistaken for the legacy book's chapter UID")

mark.pos0 = nil
local missing, missing_reason = Resolve(doc, book, mark, store)
assert(not missing and missing_reason == "missing_selection",
    "a nil CREngine endpoint reached the document selection functions")
mark.pos0, mark.pos1 = {}, fragment .. "/body/p/text().6"
missing, missing_reason = Resolve(doc, book, mark, store)
assert(not missing and missing_reason == "missing_selection",
    "a non-string CREngine endpoint reached the document selection functions")
print("annotation_upload_position_spec: context disambiguation, HTML rune offsets, entity, version and chapter verified")
