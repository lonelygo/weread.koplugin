-- Chapter identity and bounds, independent of the book download form.
local Chapters = {}
local MAX_ARCHIVE_ENTRIES = 10000
local MAX_PACKAGE_BYTES = 2 * 1024 * 1024
local MAX_CHAPTER_BYTES = 8 * 1024 * 1024
local MAX_ARCHIVE_CHAPTERS = 4096

function Chapters.uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or "")
end

local function archive_identity(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if not ok or type(lfs.attributes) ~= "function" then return nil end
    local attributes = lfs.attributes(path)
    if type(attributes) ~= "table" then return nil end
    local size = tonumber(attributes.size)
    local modified = tonumber(attributes.modification)
    if not size or not modified then return nil end
    return { size = size, modification = modified }
end

local function same_archive(identity, path)
    if type(identity) ~= "table" then return true end
    local current = archive_identity(path)
    return current and current.size == tonumber(identity.size)
        and current.modification == tonumber(identity.modification) or false
end

local function xml_text(value)
    value = tostring(value or "")
    value = value:gsub("&#x([%da-fA-F]+);", function(hex)
        local number = tonumber(hex, 16)
        return number and number < 128 and string.char(number) or ""
    end)
    value = value:gsub("&#(%d+);", function(decimal)
        local number = tonumber(decimal)
        return number and number < 128 and string.char(number) or ""
    end)
    return value:gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
end

local function xml_attributes(tag)
    local result = {}
    for key, value in tostring(tag or ""):gmatch(
        '([%w_:%.%-]+)%s*=%s*"([^"]*)"') do
        result[key] = xml_text(value)
    end
    for key, value in tostring(tag or ""):gmatch(
        "([%w_:%.%-]+)%s*=%s*'([^']*)'") do
        if result[key] == nil then result[key] = xml_text(value) end
    end
    return result
end

local function archive_path(base, href)
    href = xml_text(href):match("^[^#?]*") or ""
    if href == "" or href:find("\\", 1, true) or href:sub(1, 1) == "/" then
        return nil
    end
    local parts = {}
    for part in (tostring(base or "") .. "/" .. href):gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return nil end
            parts[#parts] = nil
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function extract_bounded(archive, entries, path, limit)
    local entry = entries[path]
    if not entry or (entry.size and entry.size > limit) then return nil end
    local value = archive:extractToMemory(path)
    if type(value) ~= "string" or #value > limit then return nil end
    return value
end

-- Legacy full-book EPUBs predate annotation_documents. Their filenames and
-- manifest IDs are package-local ordinals, not WeRead chapter UIDs. Accept the
-- archive only when every catalog chapter is bound exactly once by the UID
-- marker written into the generated XHTML itself.
local function recover_archive_descriptor(book, path)
    if path ~= book.cached_full_book and path ~= book.cached_file then return nil end
    local identity = archive_identity(path)
    if not identity then return nil end
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or not Archiver.Reader then return nil end
    local archive = Archiver.Reader:new()
    if not archive:open(path) then return nil end
    local descriptor
    local ok = xpcall(function()
        local entries, count = {}, 0
        for entry in archive:iterate() do
            count = count + 1
            if count > MAX_ARCHIVE_ENTRIES then error("too many archive entries", 0) end
            local name = tostring(entry.path or "")
            if name == "" or entries[name] or name:sub(1, 1) == "/"
                or name:find("\\", 1, true) then
                error("unsafe archive entry", 0)
            end
            entries[name] = { size = tonumber(entry.size) }
        end
        local container = extract_bounded(archive, entries,
            "META-INF/container.xml", MAX_PACKAGE_BYTES)
        if not container then error("missing EPUB container", 0) end
        local rootfile
        for tag in container:gmatch("<[^>]+>") do
            local name = tag:match("^<%s*([%w_:%.%-]+)")
            if name and name:match("([^:]+)$") == "rootfile" then
                rootfile = xml_attributes(tag)["full-path"]
                break
            end
        end
        rootfile = archive_path("", rootfile)
        local opf = rootfile and extract_bounded(
            archive, entries, rootfile, MAX_PACKAGE_BYTES) or nil
        if not opf then error("missing EPUB package", 0) end
        local identifier = opf:match(
            "<[%w_:%.%-]*identifier[^>]*>(.-)</[%w_:%.%-]*identifier%s*>")
        identifier = xml_text(identifier):gsub("^%s+", ""):gsub("%s+$", "")
        local book_id = tostring(book.book_id or book.bookId or "")
        if book_id == "" or identifier:sub(1, #book_id + 8)
            ~= "weread-" .. book_id .. "-" then
            error("EPUB book identity mismatch", 0)
        end

        local manifest, spine, navigation_item = {}, {}, nil
        for tag in opf:gmatch("<[^>]+>") do
            local name = tag:match("^<%s*([%w_:%.%-]+)")
            name = name and name:match("([^:]+)$")
            local attributes = name and xml_attributes(tag) or nil
            if name == "item" then
                local id = attributes.id
                if not id or manifest[id] then error("ambiguous manifest", 0) end
                manifest[id] = attributes
                if attributes["media-type"] == "application/x-dtbncx+xml" then
                    if navigation_item then error("ambiguous navigation", 0) end
                    navigation_item = attributes
                end
            elseif name == "itemref" then
                if not attributes.idref then error("missing spine reference", 0) end
                spine[#spine + 1] = attributes.idref
            end
        end
        if #spine == 0 or #spine > MAX_ARCHIVE_CHAPTERS + 1 then
            error("invalid spine size", 0)
        end
        local catalog, by_uid = {}, {}
        for _, chapter in ipairs(book.chapters or {}) do
            local uid = Chapters.uid(chapter)
            if uid == "" or by_uid[uid] then error("ambiguous catalog", 0) end
            catalog[#catalog + 1], by_uid[uid] = chapter, chapter
        end
        if #catalog == 0 or #catalog > MAX_ARCHIVE_CHAPTERS then
            error("invalid catalog size", 0)
        end

        local base = rootfile:match("^(.*)/[^/]+$") or ""
        local selected, selected_paths, seen, cover_seen = {}, {}, {}, false
        for index, idref in ipairs(spine) do
            local item = manifest[idref]
            if not item or item["media-type"] ~= "application/xhtml+xml" then
                error("unresolved spine item", 0)
            end
            local chapter_path = archive_path(base, item.href)
            local xhtml = chapter_path and extract_bounded(
                archive, entries, chapter_path, MAX_CHAPTER_BYTES) or nil
            if not xhtml then error("missing spine document", 0) end
            local uid = xhtml:match(
                "<!%-%-%s*weread%-chapter%-uid:%s*([^%s<>]+)%s*%-%->")
            if uid then
                uid = xml_text(uid)
                if not by_uid[uid] or seen[uid] then
                    error("unknown or duplicate chapter marker", 0)
                end
                selected[#selected + 1], seen[uid] = by_uid[uid], true
                selected_paths[#selected_paths + 1] = chapter_path
            else
                local properties = tostring(item.properties or ""):lower()
                local is_cover = tostring(idref):lower() == "cover"
                    or properties:find("cover", 1, true) ~= nil
                if index ~= 1 or cover_seen or not is_cover then
                    error("unmarked spine document", 0)
                end
                cover_seen = true
            end
            if index % 16 == 0 then collectgarbage("step", 256) end
        end
        if #selected ~= #catalog then error("incomplete chapter marker set", 0) end
        for uid in pairs(by_uid) do
            if not seen[uid] then error("catalog chapter absent from spine", 0) end
        end
        if not navigation_item then error("missing NCX navigation", 0) end
        local navigation_path = archive_path(base, navigation_item.href)
        local navigation = navigation_path and extract_bounded(
            archive, entries, navigation_path, MAX_PACKAGE_BYTES) or nil
        if not navigation then error("missing NCX document", 0) end
        local navigation_base = navigation_path:match("^(.*)/[^/]+$") or ""
        local navigation_paths = {}
        for tag in navigation:gmatch("<[^>]+>") do
            local name = tag:match("^<%s*([%w_:%.%-]+)")
            if name and name:match("([^:]+)$") == "content" then
                local source = xml_attributes(tag).src
                local resolved = source and archive_path(navigation_base, source)
                if not resolved then error("invalid NCX target", 0) end
                navigation_paths[#navigation_paths + 1] = resolved
            end
        end
        if #navigation_paths ~= #selected_paths then
            error("navigation and spine size mismatch", 0)
        end
        for index, selected_path in ipairs(selected_paths) do
            if navigation_paths[index] ~= selected_path then
                error("navigation and spine order mismatch", 0)
            end
        end
        descriptor = {
            chapters = selected,
            recovered = true,
            source = "archive_uid_markers",
            archive_identity = identity,
        }
    end, debug.traceback)
    pcall(function() archive:close() end)
    return ok and descriptor or nil
end
local UPDATE_SUFFIX_KEYWORDS = { "更", "求", "订", "阅", "票", "藏", "赏" }
local CHAPTER_ENDINGS = { "章", "节", "回", "卷", "部", "集", "篇" }
local NUMBER_TOKENS = {
    "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九",
    "十", "百", "千", "万", "两",
}

local function has_update_keyword(text)
    for _i, keyword in ipairs(UPDATE_SUFFIX_KEYWORDS) do
        if text:find(keyword, 1, true) then return true end
    end
    return false
end

local function strip_update_suffix(title)
    local function strip_group(value, opening, closing)
        local last_open, from = nil, 1
        while true do
            local pos = value:find(opening, from, true)
            if not pos then break end
            last_open, from = pos, pos + #opening
        end
        local close_at = #value - #closing + 1
        if last_open and close_at > last_open
            and value:sub(close_at, close_at + #closing - 1) == closing
            and has_update_keyword(value:sub(last_open + #opening, close_at - 1)) then
            return value:sub(1, last_open - 1)
        end
        return value
    end
    local previous
    repeat
        previous = title
        title = strip_group(title, "（", "）")
        title = strip_group(title, "(", ")")
    until title == previous
    return title
end

local function is_chapter_number(value)
    local original = tostring(value or "")
    if original == "" then return false end
    local number = original:gsub("%d", "")
    for _i, token in ipairs(NUMBER_TOKENS) do
        number = number:gsub(token, "")
    end
    return number == ""
end

local function strip_chapter_number(value)
    if value:sub(1, #"第") ~= "第" then return value end
    local rest = value:sub(#"第" + 1)
    local ending_pos, ending_len
    for _i, ending in ipairs(CHAPTER_ENDINGS) do
        local pos = rest:find(ending, 1, true)
        if pos and (not ending_pos or pos < ending_pos) then
            ending_pos, ending_len = pos, #ending
        end
    end
    if not ending_pos or ending_pos <= 1
        or not is_chapter_number(rest:sub(1, ending_pos - 1)) then
        return value
    end
    return rest:sub(ending_pos + ending_len)
end

local function normalized_chapter_title(value)
    local title = tostring(value or "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    -- Normalize full-width punctuation and spaces to ASCII up front so the
    -- patterns below never place multi-byte characters inside a class.
    title = title:gsub("\xE3\x80\x80", " ") -- full-width space U+3000
    title = title:gsub("\xEF\xBC\x9A", ":") -- full-width colon ：
    title = title:gsub("\xE3\x80\x81", ",") -- ideographic comma 、
    title = title:gsub("\239\188([\144-\153])", function(digit)
        return string.char(digit:byte() - 96)
    end)
    title = strip_update_suffix(title)
    local stripped = strip_chapter_number(title)
    if stripped ~= title then
        stripped = stripped:gsub("^[%s,:%.%-]+", "")
            :gsub("^%s+", ""):gsub("%s+$", "")
        -- Keep short titles such as 上/下 tied to their chapter number.
        if #stripped >= 6 then title = stripped end
    end
    title = title:gsub(
        "^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%divxlcdmIVXLCDM%d]+[%s:%.%-]*", "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title:gsub("%s+", " ")
end

local function is_outline_number(value)
    local original = tostring(value or "")
    if original == "" then return false end
    local number = original:gsub("%d", "")
        :gsub("[IVXLCDMivxlcdm]", "")
    for _, token in ipairs(NUMBER_TOKENS) do
        number = number:gsub(token, "")
    end
    return number == ""
end

-- Local EPUBs and WeRead catalogs often spell the same outline heading as
-- `二、标题`, `二 标题`, `二. 标题` or `（二）标题`. Keep the strict key as the
-- first choice, then use the title body as a conservative fallback. Very short
-- bodies retain their full title because headings such as `一、上` repeat often.
local function relaxed_chapter_title(value)
    local title = normalized_chapter_title(value)
    title = title:gsub("\xEF\xBC\x88", "(") -- full-width opening parenthesis （
    title = title:gsub("\xEF\xBC\x89", ")") -- full-width closing parenthesis ）
    title = title:gsub("\xEF\xBC\x8C", ",") -- full-width comma ，
    title = title:gsub("\xEF\xBC\x8E", ".") -- full-width full stop ．
    local number, rest = title:match("^%((.-)%)[%s,:%.%-]*(.+)$")
    if not number then
        number, rest = title:match("^([^,%s:%.%-%)]+)[,%s:%.%-%)]+(.+)$")
    end
    if number and rest and is_outline_number(number) then
        rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
        if #rest >= 6 then return rest end
    end
    return title
end


Chapters.normalize = normalized_chapter_title

function Chapters.documentEnd(document)
    if not document.getPageCount or not document.getPageXPointer
        or not document.getNextVisibleWordEnd then return nil end
    local ok, xp = pcall(function()
        return document:getPageXPointer(document:getPageCount())
    end)
    if not ok or not xp then return nil end
    local last
    for _ = 1, 10000 do
        local success, next_xp = pcall(document.getNextVisibleWordEnd, document, xp)
        if not success then return nil end
        if not next_xp or next_xp == xp then return last end
        last, xp = next_xp, next_xp
    end
end

-- Resolve identity independently of catalog order. Only unique names are
-- automatic; duplicate names need a unique parent context.
function Chapters.map(document, catalog, descriptor, overrides)
    local ok, toc = pcall(document.getToc, document)
    toc = ok and type(toc) == "table" and toc or {}
    local available = catalog
    catalog = descriptor and descriptor.chapters or catalog
    local indexes, counts = { {}, {}, {} }, { {}, {}, {} }
    local function keys(title)
        return { tostring(title or ""), normalized_chapter_title(title), relaxed_chapter_title(title) }
    end
    local parents, stack = {}, {}
    for i, entry in ipairs(toc) do
        local depth = tonumber(entry.depth) or 1
        while #stack > 0 and (tonumber(toc[stack[#stack]].depth) or 1) >= depth do
            table.remove(stack)
        end
        parents[i] = stack[#stack]
        stack[#stack + 1] = i
        for n, key in ipairs(keys(entry.title)) do
            indexes[n][key] = indexes[n][key] or {}
            table.insert(indexes[n][key], i)
        end
    end
    for _, chapter in ipairs(catalog) do
        for n, key in ipairs(keys(chapter.title)) do counts[n][key] = (counts[n][key] or 0) + 1 end
    end
    local chosen, occupied, candidates = {}, {}, {}
    local by_uid = {}
    for _, chapter in ipairs(available) do by_uid[Chapters.uid(chapter)] = chapter end
    -- Saved choices belong to this document's TOC anchors. Reserve them before
    -- automatic matching, including explicit removals and missing remote UIDs.
    for index, entry in ipairs(toc) do
        local uid = overrides and overrides[entry.xpointer]
        if uid ~= nil then
            occupied[index] = true
            if uid ~= false and by_uid[tostring(uid)] and not chosen[tostring(uid)] then
                uid = tostring(uid)
                chosen[uid], occupied[index] = index, uid
            end
        end
    end
    for i, chapter in ipairs(catalog) do
        local uid = Chapters.uid(chapter)
        local chapter_keys = keys(chapter.title)
        for n, key in ipairs(chapter_keys) do
            if indexes[n][key] then
                candidates[uid] = indexes[n][key]
                if key ~= "" and not descriptor and #indexes[n][key] == 1 and counts[n][key] == 1 then
                    local target = indexes[n][key][1]
                    if not chosen[uid] and not occupied[target] then
                        chosen[uid], occupied[target] = target, uid
                    end
                end
                break
            end
        end
        if descriptor and not chosen[uid] and toc[i] and not occupied[i] then
            chosen[uid], occupied[i] = i, uid
        end
    end
    -- Resolve duplicate children only inside an already identified parent.
    -- Avoid quadratic work for pathological catalogs of repeated headings.
    local scope, scope_counts = {}, {}
    stack = {}
    for i, chapter in ipairs(catalog) do
        local depth = tonumber(chapter.level) or 1
        while #stack > 0 and (tonumber(catalog[stack[#stack]].level) or 1) >= depth do
            table.remove(stack)
        end
        local uid = Chapters.uid(chapter)
        scope[uid] = tostring(stack[#stack] or 0) .. "\n" .. normalized_chapter_title(chapter.title)
        scope_counts[scope[uid]] = (scope_counts[scope[uid]] or 0) + 1
        stack[#stack + 1] = i
    end
    stack = {}
    for i, chapter in ipairs(catalog) do
        local depth = tonumber(chapter.level) or 1
        while #stack > 0 and (tonumber(catalog[stack[#stack]].level) or 1) >= depth do
            table.remove(stack)
        end
        local uid = Chapters.uid(chapter)
        local parent = stack[#stack] and chosen[Chapters.uid(catalog[stack[#stack]])]
        local options = candidates[uid] or {}
        if not chosen[uid] and parent and #options <= 32
            and scope_counts[scope[uid]] == 1 then
            local target, ambiguous
            for _, candidate in ipairs(options) do
                if parents[candidate] == parent and not occupied[candidate] then
                    if target then ambiguous = true end
                    target = candidate
                end
            end
            if target and not ambiguous then
                chosen[uid], occupied[target] = target, uid
            end
        end
        stack[#stack + 1] = i
    end
    -- A generated partial EPUB may be manually linked to another chapter of
    -- the same book. Keep its original descriptor unchanged.
    if descriptor and overrides then
        local combined, included = {}, {}
        for _, chapter in ipairs(catalog) do
            combined[#combined + 1], included[Chapters.uid(chapter)] = chapter, true
        end
        for _, chapter in ipairs(available) do
            local uid = Chapters.uid(chapter)
            if chosen[uid] and not included[uid] then combined[#combined + 1] = chapter end
        end
        catalog = combined
    end
    local matched, selected, ranges = {}, {}, {}
    for _, chapter in ipairs(catalog) do
        local uid = Chapters.uid(chapter)
        local i = chosen[uid]
        if i and toc[i].xpointer then matched[#matched + 1] = { chapter = chapter, index = i } end
    end
    table.sort(matched, function(a, b) return a.index < b.index end)
    -- Compute sibling boundaries once, including unmapped local entries.
    local stops = {}
    stack = {}
    for i, entry in ipairs(toc) do
        while #stack > 0 and (tonumber(toc[stack[#stack]].depth) or 1) >= (tonumber(entry.depth) or 1) do
            stops[table.remove(stack)] = i
        end
        stack[#stack + 1] = i
    end
    local doc_end = Chapters.documentEnd(document)
    for i, match in ipairs(matched) do
        local entry = toc[match.index]
        local stop = stops[match.index]
        local next_match = matched[i + 1]
        if next_match and (not stop or next_match.index < stop) then stop = next_match.index end
        ranges[Chapters.uid(match.chapter)] = {
            start_xpointer = entry.xpointer, end_xpointer = stop and toc[stop].xpointer or doc_end,
            title = entry.title, toc_index = match.index,
        }
        selected[#selected + 1] = match.chapter
    end
    -- Preserve the existing API's unbound entries; callers filter by ranges.
    for _, chapter in ipairs(catalog) do
        if not ranges[Chapters.uid(chapter)] then selected[#selected + 1] = chapter end
    end
    return selected, ranges
end

-- Versioned range identity also invalidates checkpoints from older algorithms.
function Chapters.rangeKey(range)
    if not range then return nil end
    return "mapping-v2:" .. tostring(range.start_xpointer) .. "\n" .. tostring(range.end_xpointer)
end

function Chapters.descriptor(book, path)
    if not book then return nil end
    local explicit = book.annotation_documents and book.annotation_documents[path]
    if explicit then
        return same_archive(explicit.archive_identity, path) and explicit or nil
    end
    if path == book.cached_full_book then return nil end
    local selected = {}
    for _, chapter in ipairs(book.chapters or {}) do
        if book.cached_chapters and book.cached_chapters[Chapters.uid(chapter)] == path then
            selected[#selected + 1] = chapter
        end
    end
    -- A single-chapter cache has an unambiguous spine. Older multi-chapter
    -- cache aliases did not persist their spine order, so catalog/UID order
    -- must not be used to manufacture one.
    if #selected == 1 then return { chapters = selected, legacy = true } end
    -- Legacy combined EPUBs have no trustworthy full/partial distinction.
    -- The caller maps their actual TOC and only includes chapters with bounds.
end

-- v1.8.5 incremental EPUBs may predate the persisted annotation_documents
-- entry. Reconstruct it only from exact chapter identities already recorded
-- for this file. Titles and TOC positions are deliberately not used here.
function Chapters.recoverDescriptor(book, path)
    if type(book) ~= "table" or type(path) ~= "string" or path == "" then
        return nil, false
    end
    local explicit = book.annotation_documents and book.annotation_documents[path]
    if explicit and same_archive(explicit.archive_identity, path) then
        return explicit, false
    end

    local requested = {}
    if path == book.incremental_reader_file then
        for _, uid in ipairs(book.incremental_chapter_uids or {}) do
            requested[#requested + 1] = tostring(uid)
        end
    else
        local archive_descriptor = recover_archive_descriptor(book, path)
        if archive_descriptor then
            book.annotation_documents = book.annotation_documents or {}
            book.annotation_documents[path] = archive_descriptor
            return archive_descriptor, true
        end
        if path == book.cached_full_book then return nil, false end
        local descriptor = Chapters.descriptor(book, path)
        if descriptor then return descriptor, false end
        for uid, source in pairs(book.cached_chapters or {}) do
            if source == path then requested[#requested + 1] = tostring(uid) end
        end
        if #requested ~= 1 then return nil, false end
    end
    if #requested == 0 then return nil, false end

    local catalog = {}
    for _, chapter in ipairs(book.chapters or {}) do
        catalog[Chapters.uid(chapter)] = chapter
    end
    local selected = {}
    for _, uid in ipairs(requested) do
        local chapter = catalog[uid]
        if not chapter then return nil, false end
        selected[#selected + 1] = {
            chapterUid = chapter.chapterUid or chapter.chapterId,
            title = chapter.title,
            chapterIdx = chapter.chapterIdx,
        }
    end
    local descriptor = { chapters = selected, recovered = true }
    book.annotation_documents = book.annotation_documents or {}
    book.annotation_documents[path] = descriptor
    return descriptor, true
end
return Chapters
