package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local LibraryDB = require("weread.lib.library_db")
local OfflineAnnotations = require("weread.lib.offline_annotations")
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
local document = {}
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
            return {
                bookId = "book", chapterUid = 1,
                range = annotation.id .. "-range", markText = annotation.text,
            }
        end,
    },
    is_online = function() return true end,
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
coordinator:drain()
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
helper.cleanup()
print("offline_annotations_spec: baseline, create, private replace, delete and unknown states passed")
