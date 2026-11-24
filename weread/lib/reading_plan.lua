-- Work in catalog order. Chapter UIDs identify packages and need not be numeric or consecutive.
local M = {}

local function uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or "")
end

function M.build(book, chapters, full_path, stable_path, published, history, live, exists, saved_page)
    local state = { catalog = {}, cached = {}, published = {}, paths = {}, total_cached = 0 }
    local path_uids, mapped, index_by_uid = {}, {}, {}
    local function add_path(path)
        if path and state.paths[path] == nil then state.paths[path] = exists(path) == true end
        return state.paths[path]
    end
    if stable_path then
        state.paths[stable_path] = true
        for _, key in ipairs(published) do
            local id = tostring(key)
            state.published[id] = true
            state.cached[id] = stable_path
        end
    end
    for key, path in pairs(book.cached_chapters or {}) do
        local id = tostring(key)
        if type(path) == "string" then
            mapped[path] = (mapped[path] or 0) + 1
            path_uids[path] = id
            -- The manifest and the one visible EPUB already prove availability.
            -- Avoid reopening hundreds of hidden chapter files to draw a shelf row.
            if not state.published[id] and add_path(path) then state.cached[id] = path end
        end
    end
    for _, ch in ipairs(chapters or {}) do
        if uid(ch) ~= "" and not index_by_uid[uid(ch)] and ch.title ~= "封面"
            and (ch.wordCount == nil or (tonumber(ch.wordCount) or 0) > 0) then
            state.catalog[#state.catalog + 1] = ch
            index_by_uid[uid(ch)] = #state.catalog
        end
    end
    if add_path(full_path) then
        local descriptor = (book.annotation_documents or {})[full_path]
        -- Older versions also used cached_file for a selected group of chapters.
        -- A recorded subset can only vouch for the chapters it actually contains.
        if descriptor and descriptor.chapters and #descriptor.chapters > 0 then
            for _, ch in ipairs(descriptor.chapters) do state.cached[uid(ch)] = state.cached[uid(ch)] or full_path end
        elseif full_path == book.cached_full_book or not mapped[full_path] then
            for _, ch in ipairs(state.catalog) do state.cached[uid(ch)] = state.cached[uid(ch)] or full_path end
        end
    end
    local position = live or book.last_local_position or book.pending_upload_position
    local queued = book.pending_upload_position
    if not live and position and queued
        and (tonumber(queued.captured_at) or 0) > (tonumber(position.captured_at) or 0) then
        position = queued
    end
    for _, entry in ipairs(history or {}) do
        if state.paths[entry.file] or (mapped[entry.file] and add_path(entry.file)) then
            state.resume_path = entry.file
            break
        end
    end
    -- A chapter download alone (or remote shelf progress) is not a local read.
    local anchor_uid = position and (position.current_chapter_uid or position.chapter_uid)
        or book.active_chapter_uid
    if not anchor_uid and saved_page then
        local candidates = state.resume_path and { state.resume_path } or { stable_path or full_path, full_path }
        for _, path in ipairs(candidates) do
            if state.paths[path] then
                local xpointer = saved_page(path)
                if xpointer then
                    state.resume_path = path
                    local slot = tonumber(tostring(xpointer):match("/DocFragment%[(%d+)%]"))
                    local descriptor = (book.annotation_documents or {})[path]
                    local ch = descriptor and descriptor.chapters and descriptor.chapters[slot]
                    anchor_uid = ch and uid(ch) or (path == stable_path and published[slot] or nil)
                    break
                end
            end
        end
    end
    if not anchor_uid and mapped[state.resume_path] == 1 then
        anchor_uid = path_uids[state.resume_path]
    end
    state.started = anchor_uid ~= nil or state.resume_path ~= nil
    state.index = index_by_uid[tostring(anchor_uid)] or 1
    state.current = state.catalog[state.index]
    if state.started and not state.resume_path then
        local path = state.current and state.cached[uid(state.current)]
        if path == stable_path or path == full_path then state.resume_path = path end
    end
    for i, ch in ipairs(state.catalog) do
        if state.cached[uid(ch)] then
            state.total_cached = state.total_cached + 1
            if i == (state.last or state.index - 1) + 1 then state.last = i end
        end
    end
    state.complete = #state.catalog > 0 and state.total_cached == #state.catalog
    state.first_to_prepare = state.started and state.index + 1 or 1
    state.forward_count = math.max(0, #state.catalog - state.first_to_prepare + 1)
    return state
end

function M.missing(state, count)
    local first = count and state.first_to_prepare or 1
    local last = count and math.min(#state.catalog, first + count - 1) or #state.catalog
    local result = {}
    for i = first, last do
        local ch = state.catalog[i]
        if not state.cached[uid(ch)] then result[#result + 1] = ch end
    end
    return result
end

return M
