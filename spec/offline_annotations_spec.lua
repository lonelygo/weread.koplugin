package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local LibraryDB = require("weread.lib.library_db")
local OfflineAnnotations = require("weread.lib.offline_annotations")
local source_ready, source_repairs, source_result = false, 0, {}
package.preload["weread.lib.annotation_source_worker"] = function()
    return { run = function()
        source_repairs = source_repairs + 1
        source_ready = true
        return source_result
    end }
end
local unique = os.tmpname()
os.remove(unique)
local account = { user_vid = unique }
local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        if key == "account" then return account end
        return default
    end,
}
local db = LibraryDB:new(settings)
local path = db:databasePath()
local active
local worker = {
    busy = function() return active ~= nil end,
    start = function(_self, options)
        active = options
        return true, { token = "test" }
    end,
}
local function finish()
    local options = assert(active, "no queued background annotation task")
    active = nil
    local ok, value = pcall(options.task, { checkCancelled = function() end })
    options.on_done(ok and { ok = true, value = value }
        or { ok = false, error = value })
end

local scheduled = {}
local session, clock = 1, 1000
local online = true
local upload_enabled = true
local add_bookmark_result = "bookmark-1"
local add_review_result = "review-1"
local gate_allowed = true
local gate_calls = {}
local gate_releases = {}
local sync_requests = {}
local client = {
    add_bookmark = function() return add_bookmark_result,
        add_bookmark_result and nil or "unknown" end,
    add_private_review = function() return add_review_result,
        add_review_result and nil or "unknown" end,
    remove_bookmark = function() return true end,
    remove_private_review = function() return true end,
}
local annotations = {}
local document = { file = "/book.epub" }
local coordinator = OfflineAnnotations:new {
    library_db = db,
    settings = {
        get = function(_self, key, default)
            if key == "sync" then return { upload_annotations = upload_enabled } end
            return default
        end,
    },
    client = client,
    worker = worker,
    scheduler = {
        scheduleIn = function(_self, _delay, fn)
            scheduled[#scheduled + 1] = fn
        end,
    },
    resolver = {
        resolve = function(_document, _book, annotation)
            if tostring(annotation.id):match("^repair") and not source_ready then
                return nil, "missing_source"
            end
            return {
                bookId = "book", chapterUid = 1,
                range = annotation.id .. "-range", markText = annotation.text,
            }
        end,
        chapter = function(_document, _book, annotation)
            if tostring(annotation.id):match("^repair") then return { chapterUid = 7 } end
        end,
    },
    is_online = function() return online end,
    gate = function(kind, context)
        gate_calls[#gate_calls + 1] = { kind = kind, context = context }
        if not gate_allowed then return false, "offline" end
        return true, function(outcome)
            gate_releases[#gate_releases + 1] = outcome
        end
    end,
    request_sync = function(reason, context)
        sync_requests[#sync_requests + 1] = { reason = reason, context = context }
    end,
    get_document = function() return document end,
    get_book = function() return { book_id = "book" } end,
    get_store = function() return {} end,
    get_annotations = function() return annotations end,
    get_session = function() return session end,
    now = function() return clock end,
}

annotations[1] = { id = "old", page = "p0", text = "historical", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, nil))
assert(not active and db:localAnnotationStatus().local_existing == 1,
    "reader baseline silently queued historical local annotations")

annotations[2] = { id = "new", page = "p1", text = "selected", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(not active and sync_requests[#sync_requests].reason == "annotation_captured",
    "annotation capture bypassed the unified sync request")
assert(coordinator:drain(), "coordinated annotation drain did not start")
assert(active, "new highlight did not start the background worker")
assert(active.min_available_kb == 32 * 1024,
    "single-annotation upload retained the 64 MB download threshold")
finish()
assert(gate_calls[1].kind == "annotation_write"
    and gate_releases[1].write_attempted == true,
    "annotation network gate did not cover the worker request")
assert(db:localAnnotationStatus().synced == 1,
    "accepted highlight did not persist its remote identity")

annotations[2].note = "private note"
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(coordinator:drain(), "highlight-to-thought edit did not start replacement")
finish()
assert(db:localAnnotationStatus().synced == 1,
    "accepted private replacement did not return to synced state")

table.remove(annotations, 2)
assert(coordinator:capture("book", "/book.epub", annotations, {}))
assert(coordinator:drain(), "deleting a synced thought did not queue its tombstone")
finish()
assert(db:localAnnotationStatus().synced == nil,
    "accepted remote deletion retained the annotation outbox row")

annotations[2] = { id = "repair", page = "p7", text = "old source", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(active and coordinator.source_repair_request,
    "an opened old book did not schedule its missing chapter source")
assert(active.min_available_kb == 32 * 1024,
    "single-chapter source repair retained the 64 MB download threshold")
session = 2
annotations[3] = { id = "repair-new", page = "p8", text = "new edit", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[3] }))
local newer_repair = assert(coordinator.source_repair_pending)
finish()
assert(source_repairs == 1 and active and coordinator.source_repair_request
    and coordinator.source_repair_pending == nil,
    "an old reader-session result cleared or failed to start the newer repair")
finish()
assert(source_repairs == 2 and newer_repair.sequence == 2
    and db:hasPendingOfflineWork(false, true),
    "source repair did not re-resolve edits made while the old worker ran")
assert(coordinator:drain())
finish()
assert(coordinator:drain())
finish()
assert(db:localAnnotationStatus().synced == 2,
    "repaired annotations were not uploaded through the ordinary writer")
annotations[2], annotations[3] = nil, nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))
assert(coordinator:drain())
finish()
assert(coordinator:drain())
finish()
assert(db:localAnnotationStatus().synced == nil,
    "source-repair fixture did not clean up its remote row")

-- An old account's result cannot recapture the same path into a new account.
source_ready = false
session = 3
source_result = {
    catalog = {},
    sources = { { chapter_uid = "7", spans = { { "unsafe" } }, version = 17 } },
}
annotations[2] = { id = "repair-account", page = "p9", text = "account", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
local original_account = account
account = { user_vid = unique .. "-switched" }
local switched_path = db:databasePath()
finish()
assert(not coordinator.source_repair_request and not coordinator.source_repair_pending
    and db:localAnnotationStatus().local_only == nil,
    "an old account's repair result persisted or uploaded into the new account")
account = original_account
assert(db:localAnnotationRepairIds("book", "/book.epub")["ko:repair-account"],
    "account switch discarded the old account's unresolved local row")
assert(not require("weread.lib.annotation_store"):new(settings):get(
    "book", "original", "7"),
    "an old account's delayed result persisted staged source data")
source_result = {}
annotations[2] = nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))

-- A delayed result for a document that is no longer open cannot persist or
-- recapture its source, but the original unresolved row remains available.
source_ready = false
session = 4
annotations[2] = { id = "repair-path", page = "p10", text = "path", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
document.file = "/other.epub"
finish()
assert(not coordinator.source_repair_request and not coordinator.source_repair_pending,
    "a delayed source result survived a document switch")
document.file = "/book.epub"
assert(db:localAnnotationRepairIds("book", "/book.epub")["ko:repair-path"],
    "document switch discarded the unresolved local annotation")
annotations[2] = nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))

-- Reconnect enters through wake() and repairs old source without another user
-- annotation action.
source_ready = false
session = 5
online = false
annotations[2] = { id = "repair-reconnect", page = "p11", text = "reconnect", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(not active and coordinator.source_repair_pending,
    "offline source repair unexpectedly launched a network task")
assert(coordinator:pendingSourceBook() == "book", "the service probe needs the open source book")
online = true
local reconnect_started = coordinator:on_network_connected()
assert(reconnect_started and active,
    "network restoration did not launch pending source repair: "
        .. tostring(reconnect_started) .. "/" .. tostring(active)
        .. "/request=" .. tostring(coordinator.request)
        .. "/lease=" .. tostring(coordinator.network_lease))
finish()
assert(db:nextLocalAnnotationWork(),
    "reconnect source repair did not make the old row uploadable")
annotations[2] = nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))

-- A low-memory launch backs off instead of retrying every five seconds.
source_ready = false
session = 6
local original_start, low_memory_calls = worker.start, 0
worker.start = function()
    low_memory_calls = low_memory_calls + 1
    return false, "low_memory"
end
annotations[2] = { id = "repair-low", page = "p10", text = "low", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
local low_memory_repair = assert(coordinator.source_repair_pending)
assert(low_memory_calls == 1 and low_memory_repair.next_attempt_at == clock + 120,
    "low-memory source repair did not apply its bounded backoff")
assert(not coordinator:pendingSourceBook(), "a delayed source repair must not cause a service probe")
assert(coordinator.source_retry_task and not coordinator.retry_task,
    "source repair reused the upload retry timer instead of its bounded backoff")
for _ = 1, 10 do coordinator:_start_source_repair() end
assert(low_memory_calls == 1, "low-memory source repair entered a busy retry loop")
clock = clock + 120
coordinator:_start_source_repair()
assert(low_memory_calls == 2 and low_memory_repair.next_attempt_at == clock + 240,
    "repeated low-memory repair did not increase its backoff")
worker.start = original_start
annotations[2] = nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))
session = session + 1
coordinator:_start_source_repair()
assert(not coordinator.source_repair_pending,
    "closed reader session retained a delayed source repair")

-- Failing the small-task memory gate happens before a network write. Preserve
-- the replayable row and apply a long retry instead of marking it unknown or
-- entering the normal one-second completion loop.
coordinator:_cancel_retry()
worker.start = function() return false, "low_memory" end
source_ready = true
annotations[2] = { id = "low-upload", page = "p12", text = "low upload", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(not coordinator:drain(), "low-memory upload unexpectedly launched")
local low_upload_status = db:localAnnotationStatus()
assert(low_upload_status.local_only == 1 and not low_upload_status.unknown,
    "pre-launch low-memory failure was classified as an ambiguous upload")
assert(coordinator.retry_task
        and gate_releases[#gate_releases].write_attempted == false,
    "pre-launch low-memory failure did not keep its bounded retry state")
worker.start = original_start
annotations[2] = nil
assert(coordinator:capture("book", "/book.epub", annotations, {}))
coordinator:_cancel_retry()

add_bookmark_result = nil
annotations[2] = { id = "uncertain", page = "p2", text = "uncertain", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[2] }))
assert(coordinator:drain(), "ambiguous annotation did not start")
finish()
local status = coordinator:status()
assert(status.unknown == 1 and status.counts.unknown == 1,
    "ambiguous create was replayable instead of visible as unknown")
assert(db:nextLocalAnnotationWork() == nil,
    "ambiguous create remained eligible for blind retry")
assert(not db:hasPendingOfflineWork(false, true),
    "ambiguous annotation incorrectly triggered a network probe")

add_bookmark_result = "bookmark-gated"
gate_allowed = false
annotations[3] = { id = "gated", page = "p3", text = "gated", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[3] }))
assert(not coordinator:drain() and not active,
    "denied gate still started an annotation network worker")
local denied_request_count = #sync_requests
assert(not coordinator:drain() and #sync_requests == denied_request_count,
    "unchanged annotation gate denial created a coordinator wake loop")
gate_allowed = true
assert(coordinator:drain(), "pending annotation did not resume after gate opened")
finish()

active = { kind = "other_worker" }
annotations[4] = { id = "wait", page = "p4", text = "wait", drawer = "lighten" }
assert(coordinator:capture("book", "/book.epub", annotations, { annotations[4] }))
assert(coordinator:drain(), "manual sync must wait for the shared worker retry")
local retry_task = assert(coordinator.retry_task,
    "busy shared worker did not arm a delayed annotation retry")
coordinator:wake()
assert(coordinator.retry_task == retry_task,
    "busy annotation wake stacked duplicate retry timers")
upload_enabled = false
coordinator:wake()
assert(coordinator.retry_task == nil,
    "disabling annotation upload left its retry timer armed")
active = nil

os.remove(path)
os.remove(path .. "-wal")
os.remove(path .. "-shm")
os.remove(switched_path)
os.remove(switched_path .. "-wal")
os.remove(switched_path .. "-shm")
helper.cleanup()
print("offline_annotations_spec: baseline, create, private replace, delete and unknown states passed")
