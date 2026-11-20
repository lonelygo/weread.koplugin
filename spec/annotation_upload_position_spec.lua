package.path = "./?.lua;" .. package.path
package.loaded.util = {
    htmlEntitiesToUtf8 = function(s) return (s:gsub("&amp;", "&")) end,
}
local Source = require("weread.lib.annotation_source")
local Resolve = require("weread.lib.annotation_upload_position").resolve

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
print("annotation_upload_position_spec: context disambiguation, HTML rune offsets, entity, version and chapter verified")
