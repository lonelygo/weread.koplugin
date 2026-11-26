local SyncStatus = {}

-- FileManager and ReaderUI own separate Settings/LibraryDB objects. Key the
-- cache by their shared account storage identity so a write from either host
-- invalidates the status mounted on the other host's SimpleUI home screen.
local cache = {}
local refresh_scheduled = false

local PENDING_ANNOTATION_STATES = {
    "local_only", "update_pending", "delete_pending",
    "replace_delete_pending", "inflight",
}

local UNKNOWN_ANNOTATION_STATES = {
    "unknown", "delete_unknown", "replace_delete_unknown",
}

local function sum(states, names)
    local total = 0
    for _, name in ipairs(names) do
        total = total + (tonumber(states[name]) or 0)
    end
    return total
end

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do
        if type(item) == "table" then
            result[key] = copy(item)
        else
            result[key] = item
        end
    end
    return result
end

local function loaded_integrations()
    return package.loaded["integrations"] or package.loaded["integrations.init"]
end

local function deliver_refresh()
    refresh_scheduled = false
    local integrations = loaded_integrations()
    if type(integrations) == "table"
        and type(integrations.refreshSyncStatus) == "function" then
        pcall(integrations.refreshSyncStatus)
    end
end

local function request_refresh()
    if refresh_scheduled then return end
    refresh_scheduled = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager and type(UIManager.nextTick) == "function" then
        UIManager:nextTick(deliver_refresh)
    else
        deliver_refresh()
    end
end

local function account_id(settings)
    local account = settings and settings:get("account", {}) or {}
    return type(account) == "table" and tostring(account.user_vid or "") or ""
end

local function cache_key(settings)
    return tostring(settings and settings.data_dir or "") .. "\31"
        .. account_id(settings)
end

local function offline_work(offline)
    local annotations = offline.annotations or {}
    return (tonumber(offline.pending_seconds) or 0) > 0
        or (tonumber(offline.unknown_seconds) or 0) > 0
        or (tonumber(offline.rejected_seconds) or 0) > 0
        or sum(annotations, PENDING_ANNOTATION_STATES) > 0
        or sum(annotations, UNKNOWN_ANNOTATION_STATES) > 0
end

local function read_progress_status(settings, id)
    local pending = 0
    local conflicts = {}
    local ok, books = pcall(settings.get, settings, "books", {})
    if not ok or type(books) ~= "table" then return nil end
    for book_id, book in pairs(books) do
        if type(book) == "table"
            and type(book.pending_upload_position) == "table"
            and tostring(book.pending_upload_account or "") == id then
            pending = pending + 1
            if book.pending_upload_blocked == true then
                conflicts[#conflicts + 1] = {
                    book_id = tostring(book_id),
                    title = tostring(book.title or book.summary or book_id),
                }
            end
        end
    end
    table.sort(conflicts, function(left, right)
        if left.title == right.title then
            return left.book_id < right.book_id
        end
        return left.title < right.title
    end)
    return pending, conflicts, books
end

local function unavailable(state, signed_in)
    return {
        state = state,
        available = false,
        signed_in = signed_in == true,
        account_key = nil,
        pending_seconds = 0,
        pending_annotations = 0,
        pending_progress = 0,
        conflict_count = 0,
        conflicts = {},
        unknown_seconds = 0,
        unknown_annotations = 0,
        last_confirmed_at = nil,
    }
end

local function account_entry(settings)
    local key = cache_key(settings)
    local entry = cache[key]
    if not entry then
        entry = { account_id = account_id(settings) }
        cache[key] = entry
    end
    return key, entry
end

local function read_offline_status(plugin, entry)
    if entry.offline_loaded then return entry.offline end
    local library_db = plugin and plugin.library_db
    entry.offline = library_db and type(library_db.offlineStatus) == "function"
        and library_db:offlineStatus() or { available = false }
    entry.offline_loaded = entry.offline.available == true
    return entry.offline
end

local function read_cached_progress(settings, id, entry)
    if not entry.progress_loaded then
        entry.pending_progress, entry.conflicts, entry.books = read_progress_status(settings, id)
        entry.progress_loaded = entry.pending_progress ~= nil
    end
    return entry.pending_progress, entry.conflicts
end

local function build(plugin, entry, offline_snapshot)
    local settings = plugin and plugin.settings
    local library_db = plugin and plugin.library_db
    local id = settings and account_id(settings) or ""
    if id == "" then return unavailable("signed_out", false) end
    if not library_db then return unavailable("unavailable", true) end
    local account_key = library_db:accountKey()
    local offline = offline_snapshot or read_offline_status(plugin, entry)
    if not account_key or not offline.available then
        return unavailable("unavailable", true)
    end
    local progress, conflicts = read_cached_progress(settings, id, entry)
    if progress == nil then return unavailable("unavailable", true) end
    local annotations = offline.annotations or {}
    local review_records = copy(offline.review_records or {})
    local books = entry.books or {}
    for _, record in ipairs(review_records) do
        local book = books[tostring(record.book_id)] or books[record.book_id]
        record.title = type(book) == "table"
            and tostring(book.title or book.summary or record.book_id)
            or tostring(record.book_id)
    end
    local snapshot = {
        available = true,
        signed_in = true,
        account_key = account_key,
        pending_seconds = tonumber(offline.pending_seconds) or 0,
        pending_annotations = sum(annotations, PENDING_ANNOTATION_STATES),
        unlocated_annotations = tonumber(offline.unlocated_annotations) or 0,
        pending_progress = progress,
        conflict_count = #conflicts,
        conflicts = conflicts,
        unknown_seconds = tonumber(offline.unknown_seconds) or 0,
        rejected_seconds = tonumber(offline.rejected_seconds) or 0,
        unknown_annotations = sum(annotations, UNKNOWN_ANNOTATION_STATES),
        review_records = review_records,
        review_time_count = #review_records,
        last_confirmed_at = tonumber(offline.last_confirmed_at),
    }
    if snapshot.conflict_count > 0 then
        snapshot.state = "conflict"
    elseif snapshot.pending_seconds > 0 or snapshot.pending_annotations > 0
        or snapshot.pending_progress > 0 then
        snapshot.state = "pending"
    elseif snapshot.unknown_seconds > 0 or snapshot.unknown_annotations > 0 then
        snapshot.state = "unknown"
    elseif snapshot.rejected_seconds > 0 then
        snapshot.state = "review"
    elseif snapshot.last_confirmed_at then
        snapshot.state = "synced"
    else
        snapshot.state = "idle"
    end
    return snapshot
end

function SyncStatus.get(plugin)
    if not plugin or not plugin.settings then return unavailable("unavailable", false) end
    local id = account_id(plugin.settings)
    if id == "" then return unavailable("signed_out", false) end
    local _, entry = account_entry(plugin.settings)
    return copy(build(plugin, entry))
end

function SyncStatus.reviewBooks(plugin, status)
    local db = plugin.library_db
    if not status.available or db:accountKey() ~= status.account_key then return {} end
    local _, entry = account_entry(plugin.settings)
    read_cached_progress(plugin.settings, entry.account_id, entry)
    local books = entry.books or {}
    local items, by_id = {}, {}
    local function add(id)
        id = tostring(id)
        if not by_id[id] then
            local book = books[id]
            local title = type(book) == "table" and book.title
            local item = { book_id = id, title = type(title) == "string" and title ~= "" and title or id, issues = {} }
            by_id[id] = item
            items[#items + 1] = item
        end
        return by_id[id]
    end
    for _, group in ipairs(db:listPendingSyncBooks()) do
        local item = add(group.book_id)
        item.seconds, item.segments, item.annotations = group.seconds, group.segments, group.annotations
    end
    for id, book in pairs(books) do
        if type(book) == "table" and type(book.pending_upload_position) == "table"
            and tostring(book.pending_upload_account or "") == entry.account_id then
            add(id).progress = true
        end
    end
    if (status.unlocated_annotations or 0) > 0 then
        for _, issue in ipairs(db:listUnlocatedAnnotations()) do
            local item = add(issue.book_id)
            item.issues[#item.issues + 1] = issue
        end
    end
    table.sort(items, function(a, b)
        if a.title == b.title then return a.book_id < b.book_id end
        return a.title < b.title
    end)
    return items
end

function SyncStatus.invalidate(settings)
    if settings then cache[cache_key(settings)] = nil end
    request_refresh()
end

function SyncStatus.invalidateOffline(settings)
    local entry = settings and cache[cache_key(settings)] or nil
    if entry then
        entry.offline = nil
        entry.offline_loaded = false
    end
    request_refresh()
end

function SyncStatus.invalidateProgress(settings)
    local entry = settings and cache[cache_key(settings)] or nil
    if entry then
        entry.pending_progress = nil
        entry.conflicts = nil
        entry.books = nil
        entry.progress_loaded = false
    end
    request_refresh()
end

function SyncStatus.invalidateAccount(settings)
    local prefix = tostring(settings and settings.data_dir or "") .. "\31"
    for key in pairs(cache) do
        if key:sub(1, #prefix) == prefix then cache[key] = nil end
    end
    request_refresh()
end

-- Call this only after an explicit server acknowledgement. The timestamp is
-- published only after all account work has cleared and no ambiguous record
-- remains, so a single successful item cannot make a partly synced batch look
-- complete.
function SyncStatus.noteAck(plugin, timestamp)
    if not plugin or not plugin.settings or not plugin.library_db then return false end
    local _, entry = account_entry(plugin.settings)
    local offline = type(plugin.library_db.offlineStatus) == "function"
        and plugin.library_db:offlineStatus() or { available = false }
    entry.offline = offline
    entry.offline_loaded = offline.available == true
    if not offline.available or offline_work(offline) then
        request_refresh()
        return false
    end
    local snapshot = build(plugin, entry, offline)
    if snapshot.state ~= "idle" and snapshot.state ~= "synced" then
        request_refresh()
        return false
    end
    local confirmed_at = math.floor(tonumber(timestamp) or os.time())
    if type(plugin.library_db.setSyncLastConfirmedAt) ~= "function"
        or not plugin.library_db:setSyncLastConfirmedAt(confirmed_at) then
        request_refresh()
        return false
    end
    entry.offline = nil
    entry.offline_loaded = false
    request_refresh()
    return true
end

return SyncStatus
