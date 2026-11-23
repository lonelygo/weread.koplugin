package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local LibraryDB = require("weread.lib.library_db")
local SyncStatus = require("weread.lib.sync_status")

local unique = os.tmpname()
os.remove(unique)
local values = { account = {}, books = {} }
local book_reads = 0
local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        if key == "books" then book_reads = book_reads + 1 end
        local value = values[key]
        return value == nil and default or value
    end,
}
local db = LibraryDB:new(settings)
local plugin = { settings = settings, library_db = db }

local second_settings = {
    data_dir = settings.data_dir,
    get = settings.get,
}
local second_db = LibraryDB:new(second_settings)
local second_plugin = { settings = second_settings, library_db = second_db }

local signed_out = SyncStatus.get(plugin)
assert(signed_out.state == "signed_out" and not signed_out.signed_in
    and not signed_out.available, "signed-out state was not explicit")

values.account = { user_vid = unique .. "-alice" }
local alice_path = db:databasePath()
assert(SyncStatus.get(second_plugin).state == "idle",
    "FileManager-side initial cache was not primed")
assert(book_reads == 1, "initial status did not cache the progress summary")
assert(db:enqueueReadTime("book-a", 480, {}))
local cross_host = SyncStatus.get(second_plugin)
assert(cross_host.pending_seconds == 480,
    "Reader-side enqueue did not invalidate FileManager-side cached status")
assert(book_reads == 1, "reading-time enqueue reloaded every book")
local annotations = {}
local changed = {}
for i = 1, 2 do
    annotations[i] = {
        id = "note-" .. i, page = "p" .. i, text = "mark " .. i,
        drawer = "lighten",
        _weread_upload = { bookId = "book-a", chapterUid = 1, range = "1-2" },
    }
    changed["ko:note-" .. i] = true
end
assert(db:putLocalAnnotationSnapshot("book-a", "/books/a.epub", annotations, {
    changed = changed,
}))
assert(SyncStatus.get(plugin).pending_annotations == 2
    and book_reads == 1, "annotation enqueue reloaded every book")
values.books = {
    ["book-a"] = {
        title = "Alpha",
        pending_upload_account = values.account.user_vid,
        pending_upload_position = { percent = 45 },
    },
}
SyncStatus.invalidateProgress(settings)
local pending = SyncStatus.get(plugin)
assert(pending.state == "pending" and pending.pending_seconds == 480
    and pending.pending_annotations == 2 and pending.pending_progress == 1,
    "combined pending counts were incomplete")
assert(book_reads == 2, "progress invalidation did not perform exactly one rescan")

values.books["book-a"].pending_upload_blocked = true
SyncStatus.invalidate(settings)
local conflict = SyncStatus.get(plugin)
assert(conflict.state == "conflict" and conflict.conflict_count == 1
    and conflict.conflicts[1].title == "Alpha",
    "progress conflict did not take display priority")

local time = assert(db:claimReadTime("spec"))
assert(db:quarantineReadTime(time, "ambiguous"))
values.books["book-a"] = nil
SyncStatus.invalidate(settings)
local unknown = SyncStatus.get(plugin)
assert(unknown.state == "unknown" and unknown.unknown_seconds == 30,
    "ambiguous server write did not remain visible")

values.account = { user_vid = unique .. "-bob" }
values.books = {}
SyncStatus.invalidate(settings)
local bob_path = db:databasePath()
assert(db:enqueueReadTime("book-b", 60, {}))
local first = assert(db:claimReadTime("spec"))
local forged = {}
for key, value in pairs(first) do forged[key] = value end
forged.claim_token = "wrong-token"
assert(not db:ackReadTime(forged) and db:readTimeStatus().pending == 60,
    "conditional reading-time ACK reported a non-existent affected row")
assert(db:ackReadTime(first))
local reads_before_partial_ack = book_reads
assert(not SyncStatus.noteAck(plugin, 1234),
    "one item acknowledgement marked an unfinished batch complete")
assert(book_reads == reads_before_partial_ack,
    "partial reading-time ACK rescanned every book")
assert(SyncStatus.get(plugin).last_confirmed_at == nil,
    "unfinished batch exposed a success timestamp")
local second = assert(db:claimReadTime("spec"))
assert(db:ackReadTime(second))
assert(SyncStatus.noteAck(plugin, 1235), "complete acknowledged batch was not recorded")
assert(book_reads == reads_before_partial_ack + 1,
    "final ACK did not perform exactly one necessary progress rescan")
local synced = SyncStatus.get(plugin)
assert(synced.state == "synced" and synced.last_confirmed_at == 1235,
    "confirmed timestamp was not persisted")
assert(book_reads == reads_before_partial_ack + 1,
    "display refresh after final ACK rescanned every book")

local one_mark = {{
    id = "claim-check", page = "p", text = "mark", drawer = "lighten",
    _weread_upload = { bookId = "book-b", chapterUid = 1, range = "1-2" },
}}
assert(db:putLocalAnnotationSnapshot("book-b", "/books/b.epub", one_mark, {
    changed = { ["ko:claim-check"] = true },
}))
local annotation_claim = assert(db:claimLocalAnnotationWork("spec"))
local wrong_claim = {}
for key, value in pairs(annotation_claim) do wrong_claim[key] = value end
wrong_claim.claim_token = "wrong-token"
assert(not db:updateLocalAnnotationWork(wrong_claim, { sync_state = "synced" }),
    "conditional annotation ACK reported a non-existent affected row")
assert(db:localAnnotationStatus().inflight == 1,
    "failed annotation ACK changed the claimed row")
assert(db:updateLocalAnnotationWork(annotation_claim, { sync_state = "synced" }),
    "matching annotation claim was not updated")

values.account = {}
SyncStatus.invalidateAccount(settings)
assert(SyncStatus.get(plugin).state == "signed_out",
    "account reset left the mounted status on the previous account")
values.account = { user_vid = unique .. "-alice" }
SyncStatus.invalidateAccount(settings)
assert(SyncStatus.get(plugin).last_confirmed_at == nil,
    "confirmed timestamp leaked into another account")
values.account = { user_vid = unique .. "-bob" }
SyncStatus.invalidate(settings)
assert(SyncStatus.get(plugin).last_confirmed_at == 1235,
    "confirmed timestamp did not survive an account switch")
SyncStatus.invalidate(second_settings)
assert(SyncStatus.get(second_plugin).last_confirmed_at == 1235,
    "second host instance did not reload the account confirmation")

local unavailable = SyncStatus.get({
    settings = {
        data_dir = "/broken",
        get = settings.get,
    },
    library_db = { accountKey = function() return "broken" end,
        offlineStatus = function() return { available = false } end },
})
assert(unavailable.state == "unavailable" and unavailable.signed_in,
    "storage failure was confused with signed-out state")

local function fixed_settings(user_vid)
    local own = { account = { user_vid = user_vid }, books = {} }
    return {
        data_dir = "/tmp",
        get = function(_self, key, default)
            local value = own[key]
            return value == nil and default or value
        end,
    }
end
local stale_settings = fixed_settings(unique .. "-stale-reader")
local current_settings = fixed_settings(unique .. "-current-filemanager")
local stale_db = LibraryDB:new(stale_settings)
local current_db = LibraryDB:new(current_settings)
local stale_path, current_path = stale_db:databasePath(), current_db:databasePath()
assert(current_db:enqueueReadTime("current", 30, {}))
assert(SyncStatus.noteAck({ settings = stale_settings, library_db = stale_db }, 9999))
local current_status = SyncStatus.get({
    settings = current_settings, library_db = current_db,
})
assert(current_status.state == "pending" and current_status.last_confirmed_at == nil,
    "late acknowledgement from an old account replaced the active account status")

for _, path in ipairs({ alice_path, bob_path, stale_path, current_path }) do
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
end
helper.cleanup()
print("sync_status_spec: combined queues, conflicts, unknowns, account isolation and acknowledgements passed")
