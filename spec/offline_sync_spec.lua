package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local LibraryDB = require("weread.lib.library_db")
local unique = os.tmpname()
os.remove(unique)
local current_account = { user_vid = unique .. "-offline-a" }
local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        if key == "account" then return current_account end
        return default
    end,
}
local db = LibraryDB:new(settings)
local first_path = db:databasePath()

assert(db:enqueueReadTime("book", 65, { chapter_uid = 7, percent = 12 }))
assert(db:hasPendingOfflineWork(true, false)
    and db:pendingOfflineBook(true, false) == "book"
    and not db:hasPendingOfflineWork(false, true),
    "lightweight pending-work query did not isolate reading time")
local first = assert(db:claimReadTime("test"))
assert(first.elapsed_seconds == 30 and first.position.chapter_uid == 7,
    "reading time was not split into a 30-second positioned chunk")
current_account = { user_vid = unique .. "-offline-b" }
assert(not db:ackReadTime(first),
    "account switch acknowledged a claim from another account database")
current_account = { user_vid = unique .. "-offline-a" }
assert(db:ackReadTime(first))
local second = assert(db:claimReadTime("test"))
assert(second.elapsed_seconds == 30, "second replay chunk is not 30 seconds")
assert(db:quarantineReadTime(second, "ambiguous transport"))
local third = assert(db:nextReadTime())
assert(third.elapsed_seconds == 5,
    "quarantined ambiguous write was replayed or final chunk was lost")
local time_status = db:readTimeStatus()
assert(time_status.pending == 5 and time_status.unknown == 30,
    "reading-time status did not separate pending and uncertain seconds")
assert(db:ackReadTime(assert(db:claimReadTime("test"))))
assert(not db:hasPendingOfflineWork(true, false),
    "unknown reading-time write incorrectly triggered a network probe")
assert(db:enqueueReadTime("blocked-book", 30, {}))
assert(db:enqueueReadTime("next-book", 30, {}))
local deferred, deferred_count = db:deferPendingReadTimeForBook(
    "blocked-book", 60)
assert(deferred and deferred_count == 1
    and db:pendingOfflineBook(true, false) == "next-book",
    "one book's progress failure blocked another book's reading time")
local next_book = assert(db:claimReadTime("test"))
assert(next_book.book_id == "next-book" and db:ackReadTime(next_book),
    "the per-book delay was ignored by the reading-time claim")

local annotations = {
    {
        id = "one", page = "/body/DocFragment[1]", pos0 = "xp0", pos1 = "xp1",
        text = "selected", note = "local note", drawer = "lighten",
        ignored = function() end,
    },
}
assert(db:putLocalAnnotationSnapshot("book", "/books/book.epub", annotations))
local snapshot = assert(db:getLocalAnnotationSnapshot("book", "/books/book.epub"))
assert(snapshot.sync_state == "local_pending"
    and #snapshot.annotations == 1
    and snapshot.annotations[1].note == "local note"
    and snapshot.annotations[1].ignored == nil,
    "native annotation snapshot was not compact and pending")
assert(db:putLocalAnnotationSnapshot("book", "/books/book.epub", {}))
snapshot = assert(db:getLocalAnnotationSnapshot("book", "/books/book.epub"))
assert(#snapshot.annotations == 0,
    "deleting the last native annotation did not persist an empty tombstone snapshot")

local baseline = {
    { id = "baseline", page = "p0", text = "old highlight", drawer = "lighten" },
}
assert(db:putLocalAnnotationSnapshot("book", "/books/queue.epub", baseline))
assert(db:nextLocalAnnotationWork() == nil
    and db:localAnnotationStatus().local_existing == 1,
    "opening a pre-existing KOReader book queued historical annotations")
local created = {
    baseline[1],
    { id = "new", page = "p1", text = "new highlight", drawer = "lighten",
        _weread_upload = { bookId = "book", chapterUid = 1, range = "1-3" } },
}
assert(db:putLocalAnnotationSnapshot("book", "/books/queue.epub", created, {
    changed = { ["ko:new"] = true },
}))
local work = assert(db:nextLocalAnnotationWork())
assert(db:hasPendingOfflineWork(false, true)
    and db:pendingOfflineBook(false, true) == "book",
    "lightweight pending-work query did not find annotation work")
assert(work.local_id == "ko:new" and work.sync_state == "local_only"
    and work.upload.range == "1-3",
    "newly created annotation did not enter the single-item upload queue")
assert(db:updateLocalAnnotationWork("ko:new", {
    sync_state = "synced", remote_id = "remote-1", remote_kind = "highlight",
}))
created[2].note = "edited into a private thought"
assert(db:putLocalAnnotationSnapshot("book", "/books/queue.epub", created, {
    changed = { ["ko:new"] = true },
}))
work = assert(db:nextLocalAnnotationWork())
assert(work.sync_state == "delete_pending" and work.present
    and work.remote_kind == "highlight" and work.kind == "thought",
    "kind-changing edit did not preserve the old remote id for replacement")

local unlocated = {
    { id = "missing", page = "p2", text = "needs source", drawer = "lighten",
        _weread_upload_error = "missing_source" },
}
assert(db:putLocalAnnotationSnapshot("book", "/books/legacy.epub", unlocated, {
    changed = { ["ko:missing"] = true },
}))
local issues = db:listUnlocatedAnnotations()
local repair_ids = db:localAnnotationRepairIds("book", "/books/legacy.epub")
assert(#issues == 1 and issues[1].book_id == "book"
    and issues[1].document_path == "/books/legacy.epub"
    and issues[1].reason == "missing_source" and issues[1].count == 1
    and repair_ids["ko:missing"] == true,
    "unlocated annotations were not grouped by book, file and safe reason")

current_account = { user_vid = unique .. "-offline-b" }
local second_path = db:databasePath()
assert(db:nextReadTime() == nil,
    "reading-time outbox leaked across accounts")
assert(db:getLocalAnnotationSnapshot("book", "/books/book.epub") == nil,
    "annotation snapshot leaked across accounts")

for _, path in ipairs({ first_path, second_path }) do
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
end
helper.cleanup()
print("offline_sync_spec: chunking, acknowledgement, quarantine, snapshots and account isolation passed")
