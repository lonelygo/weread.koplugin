-- Map a native KOReader selection back to the original edition's HTML rune
-- offsets. Only a unique match in the selected EPUB fragment may be uploaded.
local Chapters = require("weread.lib.annotation_chapters")
local Source = require("weread.lib.annotation_source")
local Position = {}

local function fragment(xp)
    if type(xp) ~= "string" then return nil end
    -- CREngine points the TOC at the fragment itself (DocFragment[1].0),
    -- while highlight endpoints continue into its body.
    return xp:match("/DocFragment%[(%d+)%]") or (xp:match("/DocFragment[/.]") and "1")
end

local function normalized(s)
    return (s:gsub("%s", ""):gsub(" ", ""):gsub("　", ""):gsub("­", ""))
end

-- Each displayed character retains the bounds of the source token that
-- produced it. An HTML entity can occupy several source runes.
local function index_text(spans)
    local chunks, starts, stops, length = {}, {}, {}, 0
    for _, span in ipairs(spans) do
        local raw, i, offset = span[3], 1, span[1]
        while i <= #raw do
            local lead = raw:byte(i)
            local size = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
            local token, runes = raw:sub(i, i + size - 1), 1
            if not span[4] and token == "&" then
                local entity = raw:match("^(&[#%w]+;)", i)
                if entity then
                    local decoded = require("util").htmlEntitiesToUtf8(entity)
                    if decoded ~= entity then
                        token, runes, size = decoded, #entity, #entity
                    end
                end
            end
            token = normalized(token)
            if token ~= "" then
                chunks[#chunks + 1] = token
                starts[length + 1] = offset
                length = length + #token
                stops[length] = offset + runes
            end
            offset, i = offset + runes, i + size
        end
    end
    return table.concat(chunks), starts, stops
end

local function matches_context(text, first, last, before, after)
    local left = math.min(#before, first - 1)
    local right = math.min(#after, #text - last)
    return (left + right > 0)
        and (left == 0 or text:sub(first - left, first - 1) == before:sub(-left))
        and (right == 0 or text:sub(last + 1, last + right) == after:sub(1, right))
end

local function locate(document, mark, quote, spans)
    local text, starts, stops = index_text(spans)
    local needle, from = normalized(quote), 1
    if needle == "" then return nil end
    local first, last = text:find(needle, from, true)
    if not first then return nil end
    if text:find(needle, first + 1, true) then
        if not document.getSelectedWordContext then return nil end
        local before, after = document:getSelectedWordContext(quote, 5, mark.pos0, mark.pos1)
        before, after = normalized(before or ""), normalized(after or "")
        local match_start, match_end
        repeat
            if matches_context(text, first, last, before, after) then
                if match_start then return nil end
                match_start, match_end = first, last
            end
            first, last = text:find(needle, first + 1, true)
        until not first
        first, last = match_start, match_end
    end
    if not starts[first] or not stops[last] then return nil end
    local range = ("%d-%d"):format(starts[first], stops[last])
    local original = Source.quote(spans, range)
    if normalized(original) == needle then return range, original end
end

function Position.resolve(document, book, mark, store)
    if not document or not mark or not book or not store then return nil, "missing_source" end
    local part = fragment(mark.pos0)
    if not part or fragment(mark.pos1) ~= part then return nil, "cross_chapter_selection" end
    local descriptor = Chapters.descriptor(book, document.file)
    if not descriptor then return nil, "unmapped_document" end
    local selected
    for i, row in ipairs(document:getToc() or {}) do
        if fragment(row.xpointer) == part then
            if selected then return nil, "ambiguous_chapter" end
            selected = descriptor.chapters[i]
        end
    end
    if not selected then return nil, "unmapped_chapter" end
    local id, uid = book.book_id or book.bookId, Chapters.uid(selected)
    local spans = store:get(id, "original", uid)
    if not spans then return nil, "missing_source" end
    local version = store:get(id, "original_version", uid)
    if not version and spans[1] and spans[1][4] then version = 0 end
    if not version then return nil, "missing_source_version" end
    local quote = document:getTextFromXPointers(mark.pos0, mark.pos1)
    if type(quote) ~= "string" then return nil, "missing_selection" end
    local range, original = locate(document, mark, quote, spans)
    if not range then return nil, "ambiguous_selection" end
    return {
        bookId = tostring(id), chapterUid = tonumber(uid) or uid,
        chapterIdx = tonumber(selected.chapterIdx), bookVersion = version,
        range = range, markText = original, chapterName = selected.title,
    }
end

return Position
