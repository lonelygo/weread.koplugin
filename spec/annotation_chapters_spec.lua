package.path = "./?.lua;" .. package.path

local archives, archive_opens = {}, 0
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            local archive = archives[path]
            return archive and {
                size = archive.size,
                modification = archive.modification,
            } or nil
        end,
    }
end
package.preload["ffi/archiver"] = function()
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, self) end
    function Reader:open(path)
        self.archive = archives[path]
        archive_opens = archive_opens + 1
        return self.archive ~= nil
    end
    function Reader:iterate()
        local keys = {}
        for path in pairs(self.archive.files) do keys[#keys + 1] = path end
        table.sort(keys)
        local index = 0
        return function()
            index = index + 1
            local path = keys[index]
            if path then return { path = path, size = #self.archive.files[path] } end
        end
    end
    function Reader:extractToMemory(path) return self.archive.files[path] end
    function Reader:close() self.archive = nil end
    return { Reader = Reader }
end

local Chapters = require("weread.lib.annotation_chapters")
local toc = {
    { title = "第一章 开始", xpointer = "0", depth = 1 },
    { title = "子节", xpointer = "3", depth = 2 },
    { title = "第二章 继续", xpointer = "10", depth = 1 },
    { title = "第三章 结束", xpointer = "20", depth = 1 },
}
local doc = { getToc = function() return toc end }
local catalog = {
    { chapterUid = "9", title = "第一章 开始（第一更求票）" },
    { chapterUid = "12", title = "第二章 继续" },
    { chapterUid = "15", title = "第三章 结束" },
}
local selected, ranges = Chapters.map(doc, catalog)
assert(#selected == 3 and ranges["9"].end_xpointer == "10", "child TOC truncated parent chapter")
assert(Chapters.normalize("第二十四章 序列2") == "序列2")
assert(Chapters.normalize("第一章 标题（上）") == "标题（上）", "meaningful suffix lost")
assert(Chapters.normalize("第六章 姑娘请自重") == "姑娘请自重")
assert(Chapters.normalize("第二百八十四章 姑娘请自重") == "姑娘请自重",
    "different chapter numbering did not produce the same title key")
assert(Chapters.normalize("第１２篇 风起云涌（更新）") == "风起云涌",
    "full-width chapter number or extended ending was not normalized")
assert(Chapters.normalize("第一个章节说明") == "第一个章节说明",
    "non-numeric chapter prefix was stripped")
assert(Chapters.normalize("第六章 上") == "第六章 上", "short chapter title lost its number")
local partial_doc = { getToc = function() return { toc[1], toc[4] } end }
local descriptor = { chapters = { catalog[1], catalog[3] } }
selected, ranges = Chapters.map(partial_doc, catalog, descriptor)
assert(#selected == 2 and not ranges["12"] and ranges["9"].end_xpointer == "20")
local book = { chapters = catalog, annotation_documents = { ["selection.epub"] = descriptor },
    cached_chapters = { ["12"] = "chapter.epub" } }
assert(Chapters.descriptor(book, "selection.epub") == descriptor)
assert(#Chapters.descriptor(book, "chapter.epub").chapters == 1)
assert(not Chapters.descriptor(book, "legacy-full.epub"), "legacy partial file was assumed to be complete")
book.cached_chapters["9"] = "unordered.epub"
book.cached_chapters["12"] = "unordered.epub"
assert(not Chapters.descriptor(book, "unordered.epub")
    and not Chapters.recoverDescriptor(book, "unordered.epub"),
    "an old multi-chapter cache manufactured spine order from chapter UIDs")

local function synthetic_full_epub(path, book_id, chapters, options)
    options = options or {}
    local manifest = {
        '<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>',
        '<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    }
    local spine = { '<itemref idref="cover"/>' }
    local files = {
        ["META-INF/container.xml"] = [[<?xml version="1.0"?>
<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]],
        ["OEBPS/text/cover.xhtml"] = "<html><body>cover</body></html>",
    }
    local navigation = {}
    for index, chapter in ipairs(chapters) do
        local id = "chapter_" .. tostring(index)
        local href = string.format("text/chapter-%03d.xhtml", index)
        manifest[#manifest + 1] = '<item id="' .. id .. '" href="' .. href
            .. '" media-type="application/xhtml+xml"/>'
        spine[#spine + 1] = '<itemref idref="' .. id .. '"/>'
        navigation[#navigation + 1] = '<navPoint><content src="' .. href
            .. '"/></navPoint>'
        local uid = tostring(chapter.chapterUid)
        if options.duplicate_last and index == #chapters then
            uid = tostring(chapters[1].chapterUid)
        end
        local marker = options.missing_marker == index and ""
            or "<!-- weread-chapter-uid: " .. uid .. " -->"
        files["OEBPS/" .. href] = marker .. "<html><body>synthetic</body></html>"
    end
    files["OEBPS/content.opf"] = table.concat({
        '<package><metadata><dc:identifier xmlns:dc="urn:dc">weread-',
        options.wrong_book and "other" or book_id,
        '-full</dc:identifier></metadata><manifest>',
        table.concat(manifest), '</manifest><spine>',
        table.concat(spine), '</spine></package>',
    })
    if options.reverse_navigation then
        navigation[#navigation], navigation[#navigation - 1] =
            navigation[#navigation - 1], navigation[#navigation]
    end
    files["OEBPS/toc.ncx"] = "<ncx><navMap>" .. table.concat(navigation)
        .. "</navMap></ncx>"
    local size = 0
    for _, value in pairs(files) do size = size + #value end
    archives[path] = { files = files, size = size, modification = 10 }
end

local full_catalog = {}
for index = 1, 175 do
    full_catalog[index] = {
        chapterUid = tostring(100000 + index * 13),
        chapterIdx = index * 2,
        title = "Synthetic " .. tostring(index),
    }
end
local full_path = "/synthetic/legacy-full.epub"
synthetic_full_epub(full_path, "synthetic-book", full_catalog)
local full_book = {
    book_id = "synthetic-book",
    chapters = full_catalog,
    cached_file = full_path,
    cached_full_book = full_path,
    -- Some migrated records retained only one cached_chapters alias even
    -- though cached_file still points at the complete multi-chapter EPUB.
    cached_chapters = { [full_catalog[1].chapterUid] = full_path },
}
local recovered, did_recover = Chapters.recoverDescriptor(full_book, full_path)
assert(did_recover and recovered.source == "archive_uid_markers"
        and #recovered.chapters == 175
        and recovered.chapters[44].chapterUid == full_catalog[44].chapterUid,
    "legacy full-book ordinal filenames were not mapped by trusted UID markers")
local open_count = archive_opens
local existing, repeated = Chapters.recoverDescriptor(full_book, full_path)
assert(existing == recovered and not repeated and archive_opens == open_count,
    "an existing recovered descriptor rescanned the archive")
archives[full_path].modification = 11
assert(not Chapters.descriptor(full_book, full_path),
    "a replaced EPUB retained its recovered descriptor")
recovered, did_recover = Chapters.recoverDescriptor(full_book, full_path)
assert(did_recover and recovered.chapters[44].chapterUid == full_catalog[44].chapterUid,
    "a replaced legacy EPUB did not rebuild its descriptor")

local duplicate_path = "/synthetic/duplicate.epub"
synthetic_full_epub(duplicate_path, "synthetic-book", full_catalog,
    { duplicate_last = true })
assert(not Chapters.recoverDescriptor({
    book_id = "synthetic-book", chapters = full_catalog,
    cached_file = duplicate_path, cached_full_book = duplicate_path,
}, duplicate_path), "duplicate archive UID marker was accepted")
local missing_path = "/synthetic/missing.epub"
synthetic_full_epub(missing_path, "synthetic-book", full_catalog,
    { missing_marker = 44 })
assert(not Chapters.recoverDescriptor({
    book_id = "synthetic-book", chapters = full_catalog,
    cached_file = missing_path, cached_full_book = missing_path,
}, missing_path), "unmarked legacy chapter was guessed from its ordinal")
local wrong_path = "/synthetic/wrong-book.epub"
synthetic_full_epub(wrong_path, "synthetic-book", full_catalog,
    { wrong_book = true })
assert(not Chapters.recoverDescriptor({
    book_id = "synthetic-book", chapters = full_catalog,
    cached_file = wrong_path, cached_full_book = wrong_path,
}, wrong_path), "another book's archive markers were accepted")
local wrong_toc_path = "/synthetic/wrong-toc.epub"
synthetic_full_epub(wrong_toc_path, "synthetic-book", full_catalog,
    { reverse_navigation = true })
assert(not Chapters.recoverDescriptor({
    book_id = "synthetic-book", chapters = full_catalog,
    cached_file = wrong_toc_path, cached_full_book = wrong_toc_path,
}, wrong_toc_path), "NCX order inconsistent with the spine was accepted")

local _, sparse = Chapters.map(doc, { catalog[1], catalog[3] })
assert(sparse["9"].end_xpointer == "10", "an unmatched sibling leaked into the previous chapter")

local outline_doc = { getToc = function() return {
    { title = "第一章 女性主义理论", xpointer = "100", depth = 1 },
    { title = "二、男权制的定义", xpointer = "110", depth = 2 },
    { title = "三. 同与异的问题", xpointer = "120", depth = 2 },
    { title = "第二章 历史上的女性主义运动", xpointer = "200", depth = 1 },
    { title = "（一）第一次浪潮", xpointer = "210", depth = 2 },
} end }
local outline_catalog = {
    { chapterUid = "31", title = "第一章 女性主义到底在说什么" },
    { chapterUid = "32", title = "二 男权制的定义" },
    { chapterUid = "33", title = "三、同与异的问题" },
    { chapterUid = "34", title = "(一) 第一次浪潮" },
}
local outline_selected, outline_ranges = Chapters.map(outline_doc, outline_catalog)
assert(#outline_selected == 4, "relaxed title mapping changed chapter selection")
assert(not outline_ranges["31"], "differently worded chapter heading was force-matched")
assert(outline_ranges["32"] and outline_ranges["32"].start_xpointer == "110",
    "ideographic comma and space outline headings did not match")
assert(outline_ranges["33"] and outline_ranges["33"].start_xpointer == "120",
    "period and ideographic comma outline headings did not match")
assert(outline_ranges["34"] and outline_ranges["34"].start_xpointer == "210",
    "full-width and ASCII parenthesized outline headings did not match")

local ambiguous_doc = { getToc = function() return {
    { title = "一、概述", xpointer = "300", depth = 2 },
    { title = "二、概述", xpointer = "310", depth = 2 },
} end }
local _, ambiguous_ranges = Chapters.map(ambiguous_doc, {
    { chapterUid = "41", title = "三 概述" },
})
assert(not ambiguous_ranges["41"], "ambiguous relaxed title was force-matched")

local numbered_doc = { getToc = function() return {
    { title = "第二百八十四章 姑娘请自重", xpointer = "400", depth = 1 },
    { title = "第十二卷 风起云涌", xpointer = "410", depth = 1 },
} end }
local _, numbered_ranges = Chapters.map(numbered_doc, {
    { chapterUid = "51", title = "第六章 姑娘请自重（更新）" },
    { chapterUid = "52", title = "第三卷 风起云涌" },
})
assert(numbered_ranges["51"] and numbered_ranges["51"].start_xpointer == "400",
    "same title body with different chapter numbers did not match")
assert(numbered_ranges["52"] and numbered_ranges["52"].start_xpointer == "410",
    "volume-number prefix did not match by title body")
-- Manual choices reserve local anchors before all automatic matching passes.
local _, manual = Chapters.map(doc, catalog, nil, { ["3"] = "12" })
assert(manual["12"].start_xpointer == "3" and manual["9"].end_xpointer == "3")
assert(manual["12"].end_xpointer == "10", "unmatched sibling no longer bounds a manual chapter")
local _, removed = Chapters.map(doc, catalog, nil, { ["0"] = false })
assert(not removed["9"] and removed["12"], "explicit removal was auto-matched again")
local _, missing = Chapters.map(doc, catalog, nil, { ["0"] = "removed-uid" })
assert(not missing["9"], "a missing remote override silently switched to another chapter")
local _, duplicate = Chapters.map(doc, catalog, nil, { ["0"] = "12", ["3"] = "12" })
assert(duplicate["12"].start_xpointer == "0" and not duplicate["9"], "duplicate override reused a remote chapter")
local _, replaced = Chapters.map(partial_doc, catalog, descriptor, { ["0"] = "12" })
assert(replaced["12"].start_xpointer == "0" and not replaced["9"] and replaced["15"],
    "manual choice outside a generated partial EPUB descriptor was lost")
assert(descriptor.chapters[1] == catalog[1], "annotation mapping modified the download/progress descriptor")
print("annotation_chapters_spec: nested TOC, UTF-8 titles and noncontiguous selections passed")
