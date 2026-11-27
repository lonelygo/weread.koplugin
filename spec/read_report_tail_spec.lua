package.path = "./?.lua;./?/init.lua;" .. package.path

local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = helper.connect }
end

local LibraryDB = require("weread.lib.library_db")
package.loaded["weread.lib.logger"].scoped = function()
    return package.loaded["weread.lib.logger"]
end
local unique = os.tmpname()
os.remove(unique)
local account = { user_vid = unique .. "-tail-a" }
local interval = 30
local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        if key == "account" then return account end
        if key == "read_report" then
            return { enabled = true, mode = "auto",
                interval_seconds = interval, report_on_open = true }
        end
        if key == "books" then return { book = { title = "Book" } } end
        return default
    end,
    is_cookie_configured = function() return true end,
}
local db = LibraryDB:new(settings)
local path_a = db:databasePath()
local account_a = account

local position5 = { book_id = "book", chapter_uid = 1,
    chapter_offset = 5, percent = 1 }
assert(db:stageOnlineReadTime("book", 5, position5, 30, false))
assert(db:onlineReadTail("book") == 5
    and db:readTimeStatus().pending == 0
    and db:offlineStatus().pending_seconds == 0
    and not db:hasPendingOfflineWork(true, false),
    "healthy five-second tail appeared as offline work")

-- A new host for the same account sees the durable tail, and only the next
-- normal interval tick turns 5+25 into one exact 30-second live delivery.
local reopened = LibraryDB:new(settings)
assert(reopened:onlineReadTail("book") == 5)
local position30 = { book_id = "book", chapter_uid = 1,
    chapter_offset = 30, percent = 3 }
local ok30, id30 = reopened:stageOnlineReadTime(
    "book", 25, position30, 30, true)
assert(ok30 and id30 and reopened:onlineReadTail("book") == 0
    and reopened:readTimeStatus().pending == 0
    and not reopened:hasPendingOfflineWork(true, false),
    "normal live reservation was exposed as offline backlog")
local live30 = assert(reopened:claimReadTime("reader", id30))
assert(live30._fresh_online and live30.elapsed_seconds == 30
    and live30.position.chapter_offset == 30)
assert(reopened:readTimeStatus().pending == 0
    and reopened:ackReadTime(live30)
    and reopened:readTimeReceipts().seconds == 30,
    "live receipt did not settle the hidden exact row")

-- The selected 60-second cadence remains one request, while a delayed 65s
-- capture makes two 30s/60s cadence rows plus the exact five-second tail.
assert(reopened:stageOnlineReadTime("book", 20, position30, 60, false))
local ok60, id60 = reopened:stageOnlineReadTime(
    "book", 40, { chapter_uid = 2, chapter_offset = 60 }, 60, true)
local live60 = assert(ok60 and reopened:claimReadTime("reader", id60))
assert(live60.elapsed_seconds == 60 and reopened:onlineReadTail("book") == 0)
assert(reopened:ackReadTime(live60))

local ok65, id65 = reopened:stageOnlineReadTime(
    "book", 65, { chapter_uid = 3, chapter_offset = 65 }, 30, true)
assert(ok65 and id65 and reopened:onlineReadTail("book") == 5)
local first65 = assert(reopened:claimReadTime("reader", id65))
assert(first65.elapsed_seconds == 30 and reopened:ackReadTime(first65))
local next65 = assert(reopened:nextLiveReadTime("book"))
local second65 = assert(reopened:claimReadTime("reader", next65))
assert(second65.elapsed_seconds == 30 and reopened:ackReadTime(second65)
    and not reopened:nextLiveReadTime("book"),
    "surplus live intervals were rounded, dropped or made replayable")

-- Longer supported cadences keep their configured due point while splitting
-- the actual wire work into bounded 60-second writes.
local ok120, id120 = reopened:stageOnlineReadTime(
    "long-cadence", 120, { chapter_uid = 3, chapter_offset = 120 }, 120, true)
local first120 = assert(ok120 and reopened:claimReadTime("reader", id120))
local next120_id = assert(reopened:nextLiveReadTime("long-cadence"))
local second120 = assert(reopened:claimReadTime("reader", next120_id))
assert(first120.elapsed_seconds == 60 and second120.elapsed_seconds == 60
    and reopened:ackReadTime(first120) and reopened:ackReadTime(second120)
    and reopened:onlineReadTail("long-cadence") == 0,
    "120-second cadence was clamped, rounded or dropped")

-- A deferred healthy row is re-anchored to the position verified at its
-- actual claim, never to the stale position captured before a progress choice.
local _, revalidate_id = reopened:stageOnlineReadTime(
    "revalidate", 30, { chapter_uid = 4, chapter_offset = 10 }, 30, true)
local revalidated = assert(reopened:claimReadTime("reader", revalidate_id,
    { chapter_uid = 9, chapter_offset = 99 }))
assert(revalidated.position.chapter_uid == 9
    and revalidated.position.chapter_offset == 99
    and reopened:ackReadTime(revalidated),
    "deferred live row retained a stale pre-choice position")

-- A positive disconnect moves the existing tail and disconnected span into
-- the ordinary visible queue, preserving the full 5+7 seconds.
local offline_ok, offline_id = reopened:enqueueOfflineReadTime(
    "book", 7, { chapter_uid = 3, chapter_offset = 72 })
assert(offline_ok and offline_id and reopened:onlineReadTail("book") == 0
    and reopened:offlineStatus().pending_seconds == 12,
    "offline boundary did not expose the complete carried duration")

account = { user_vid = unique .. "-tail-offline-handoff" }
local path_offline_handoff = reopened:databasePath()
local _, offline_live_id = reopened:stageOnlineReadTime(
    "offline-handoff", 30, { chapter_uid = 3 }, 30, true)
assert(offline_live_id and reopened:stageOnlineReadTime(
    "offline-handoff", 5, { chapter_uid = 3 }, 30, false))
local offline_handoff_ok, offline_handoff_id = reopened:enqueueOfflineReadTime(
    "offline-handoff", 7, { chapter_uid = 3 })
assert(offline_handoff_ok and offline_handoff_id == offline_live_id
    and not reopened:nextLiveReadTime("offline-handoff")
    and reopened:readTimeStatus().pending == 42,
    "disconnect left an earlier busy live row hidden")
account = account_a

-- A denied live gate must have an explicit safe handoff into the existing
-- queue. Until that handoff the row stays invisible to Home.
local _, denied_id = reopened:stageOnlineReadTime(
    "denied", 30, { chapter_uid = 4 }, 30, true)
assert(denied_id and reopened:offlineStatus().pending_seconds == 12)
assert(reopened:releaseLiveReadTime(denied_id)
    and reopened:offlineStatus().pending_seconds == 42,
    "failed live reservation did not become actionable replay work")

-- Once claimed, a known pre-write failure also hands the live row to the
-- ordinary ACK-gated replay lane. An ambiguous write is held for review and
-- never replayed blindly.
local _, failed_id = reopened:stageOnlineReadTime(
    "failed", 30, { chapter_uid = 5 }, 30, true)
local failed_live = assert(reopened:claimReadTime("reader", failed_id))
assert(failed_live._fresh_online
    and reopened:releaseReadTimeClaim(failed_live)
    and reopened:offlineStatus().pending_seconds == 72,
    "known failed live claim was not handed to offline replay")
local _, ambiguous_id = reopened:stageOnlineReadTime(
    "ambiguous", 30, { chapter_uid = 6 }, 30, true)
local ambiguous_live = assert(reopened:claimReadTime("reader", ambiguous_id))
assert(ambiguous_live._fresh_online
    and reopened:quarantineReadTime(ambiguous_live, "timeout")
    and reopened:readTimeStatus().unknown == 30
    and not reopened:nextLiveReadTime("ambiguous"),
    "ambiguous live claim was not held from blind replay")

-- Process ownership makes crash recovery independent of reopening the book:
-- an unattempted orphan becomes replayable; an orphaned claimed write remains
-- uncertain and is never replayed blindly.
local _, orphan_id = reopened:stageOnlineReadTime(
    "orphan", 30, { chapter_uid = 7 }, 30, true)
local raw = assert(reopened:open())
raw:exec("UPDATE read_time_outbox SET claim_token='old-process' WHERE id=" .. orphan_id)
raw:close()
assert(reopened:recoverStaleReadTimeClaims(0)
    and reopened:readTimeStatus().pending == 102,
    "unattempted row from a crashed process remained hidden")
local _, orphan_claim_id = reopened:stageOnlineReadTime(
    "orphan-claim", 30, { chapter_uid = 8 }, 30, true)
local orphan_claim = assert(reopened:claimReadTime("reader", orphan_claim_id))
raw = assert(reopened:open())
raw:exec("UPDATE read_time_outbox SET claim_token='old-process' WHERE id="
    .. orphan_claim.id)
raw:close()
assert(reopened:recoverStaleReadTimeClaims(0)
    and reopened:readTimeStatus().unknown == 60,
    "claimed row from a crashed process was not quarantined")

-- Close/suspend handoff also catches a row deferred by a busy writer and a
-- full interval accumulated by earlier non-flushing captures, even when the
-- final lifecycle callback itself adds zero seconds.
local _, deferred_id = reopened:stageOnlineReadTime(
    "lifecycle-handoff", 30, { chapter_uid = 9 }, 30, true)
local handoff_ok, handoff_id = reopened:stageOnlineReadTime(
    "lifecycle-handoff", 0, { chapter_uid = 10 }, 30, true, true)
assert(deferred_id and handoff_ok and handoff_id == deferred_id
    and not reopened:nextLiveReadTime("lifecycle-handoff")
    and reopened:readTimeStatus().pending == 132,
    "lifecycle handoff left a deferred full row hidden")
assert(reopened:stageOnlineReadTime(
    "full-tail", 20, { chapter_uid = 10 }, 30, false))
assert(reopened:stageOnlineReadTime(
    "full-tail", 10, { chapter_uid = 10 }, 30, false))
local full_ok, full_id = reopened:stageOnlineReadTime(
    "full-tail", 0, { chapter_uid = 10 }, 30, true, true)
assert(full_ok and full_id and reopened:onlineReadTail("full-tail") == 0
    and reopened:readTimeStatus().pending == 162,
    "zero-second lifecycle boundary left a due tail hidden")

account = { user_vid = unique .. "-tail-b" }
local path_b = reopened:databasePath()
assert(reopened:onlineReadTail("book") == 0
    and reopened:readTimeStatus().pending == 0,
    "online tail leaked across accounts")

-- Exercise the reporter boundary itself: close stores five healthy seconds,
-- reopen schedules only the missing 25, and the ACK callback receives the
-- exact position that was sent under the still-current account.
account = { user_vid = unique .. "-tail-c" }
local path_c = reopened:databasePath()
local ReadReport = require("weread.lib.read_report")
local active_clock = 100
local document = { file = "/book.epub" }
local scheduled = {}
local callback
local gate_allowed = true
local network_online = true
local scheduler = {
    scheduleIn = function(_self, delay, task)
        scheduled[#scheduled + 1] = { delay = delay, task = task }
    end,
    unschedule = function() end,
}
local function new_report()
    return ReadReport:new{
        settings = settings, client = {}, library_db = reopened,
        scheduler = scheduler,
        get_document = function() return document end,
        detect_book = function() return "book" end,
        position_provider = function()
            return { book_id = "book", chapter_uid = 5,
                chapter_offset = active_clock, percent = 20 }, nil, true
        end,
        is_online = function() return network_online end,
        gate = function()
            if gate_allowed then return true, function() end end
            return false, "writer_busy"
        end,
        request_sync = function() end,
        active_now = function() return active_clock end,
        now = function() return active_clock end,
        on_live_position_ack = function(book_id, position, account_key)
            callback = { book_id, position, account_key }
        end,
    }
end
local first_report = new_report()
assert(first_report:start("reader_ready") and scheduled[#scheduled].delay == 30)
active_clock = 105
first_report:on_close_document()
assert(reopened:onlineReadTail("book") == 5
    and reopened:readTimeStatus().pending == 0,
    "online close exposed or dropped a short tail")

scheduled = {}
active_clock = 200
local second_report = new_report()
assert(second_report:start("reader_ready")
    and scheduled[#scheduled].delay == 25,
    "reopen ignored the durable five-second tail")
active_clock = 225
local proceed, live_book, sent_position, live_row = second_report:_precheck()
assert(proceed and live_book == "book" and live_row.elapsed_seconds == 30
    and sent_position.chapter_offset == 225
    and reopened:readTimeStatus().pending == 0,
    "5+25 did not become one hidden normal live delivery")
assert(second_report:_apply_queued_outcome(live_row, { accepted = true })
    and callback and callback[1] == "book"
    and callback[2].chapter_offset == 225
    and callback[3] == reopened:accountKey(),
    "live ACK did not publish its exact sent position and account")

-- A busy writer may defer a due row, but a later progress choice can move the
-- book. The eventual write must atomically adopt the newly verified position.
active_clock = 255
gate_allowed = false
assert(not second_report:_precheck()
    and reopened:readTimeStatus().pending == 0
    and reopened:nextLiveReadTime("book"),
    "busy live row became offline backlog or disappeared")
active_clock = 260
gate_allowed = true
local retry_ok, _, retry_position, retry_row = second_report:_precheck()
assert(retry_ok and retry_position.chapter_offset == 260
    and retry_row.position.chapter_offset == 260
    and second_report:_apply_queued_outcome(retry_row, { accepted = true }),
    "deferred live write used its stale pre-choice position")

-- A positive disconnect captures both sides of the offline span. Repeated
-- restore notifications are idempotent and cannot add seconds again.
active_clock = 265
network_online = false
assert(second_report:on_network_disconnected())
active_clock = 272
network_online = true
assert(second_report:on_network_restored()
    and not second_report:on_network_restored())
assert(reopened:readTimeStatus().pending == 17
    and reopened:onlineReadTail("book") == 0,
    "observed offline span was hidden, rounded or double-counted")

-- KOReader may omit NetworkConnected. A later positive active connectivity
-- check closes the observed offline span once, then healthy ticks return to
-- the private online tail instead of remaining in replay forever.
active_clock = 277
network_online = false
assert(second_report:on_network_disconnected())
active_clock = 284
network_online = true
assert(second_report:_capture_active_time() == 7
    and not second_report.network_offline
    and reopened:readTimeStatus().pending == 29,
    "missed reconnect event did not close the offline span")
active_clock = 294
assert(second_report:_capture_active_time() == 10
    and reopened:readTimeStatus().pending == 29
    and reopened:onlineReadTail("book") == 10,
    "confirmed healthy tick remained trapped in offline replay")

-- Reconfiguring a running reporter keeps its accumulated exact tail instead
-- of waiting a full new interval and over-delivering on the next tick.
interval = 60
active_clock = 314
assert(second_report:_capture_active_time() == 20
    and reopened:onlineReadTail("book") == 30)
scheduled = {}
assert(second_report:reschedule("test_interval_change")
    and scheduled[#scheduled].delay == 30,
    "interval reschedule ignored the persisted online tail")
active_clock = 344
second_report:on_suspend()
assert(reopened:onlineReadTail("book") == 0
    and reopened:readTimeStatus().pending == 89,
    "suspend at the exact interval left a full record hidden")

-- Close at the threshold also hands due work to replay. Account changes use
-- an explicit pre/post boundary so neither login inherits the other's clock;
-- the fallback mismatch guard refuses to cross-charge when a hook is missed.
interval = 30
account = { user_vid = unique .. "-tail-boundary-old" }
local path_boundary_old = reopened:databasePath()
scheduled = {}
active_clock = 300
local boundary_report = new_report()
assert(boundary_report:start("boundary"))
active_clock = 330
boundary_report:on_close_document()
assert(reopened:readTimeStatus().pending == 30
    and reopened:onlineReadTail("book") == 0,
    "close at the exact interval left a full record hidden")
active_clock = 335
local old_key = reopened:accountKey()
assert(boundary_report:on_account_changed(old_key)
    and reopened:onlineReadTail("book") == 5,
    "pre-login boundary lost or exposed the old account's short tail")
account = { user_vid = unique .. "-tail-boundary-new" }
local path_boundary_new = reopened:databasePath()
scheduled = {}
assert(boundary_report:on_account_ready()
    and reopened:onlineReadTail("book") == 0
    and scheduled[#scheduled].delay == 30,
    "new login inherited the previous account's tail or schedule")
active_clock = 340
account = { user_vid = unique .. "-tail-boundary-missed" }
local path_boundary_missed = reopened:databasePath()
assert(boundary_report:_capture_active_time() == 0
    and reopened:onlineReadTail("book") == 0,
    "missed account hook cross-charged elapsed time to the new login")

-- A database created by v1.8.9 has user_version=1 and no tail table. Opening
-- it under this version must add the table without touching its outbox.
account = { user_vid = unique .. "-tail-migration" }
local path_migration = reopened:databasePath()
local legacy = assert(reopened:open())
legacy:exec("DROP TABLE read_time_online_tail")
legacy:exec("PRAGMA user_version=1")
legacy:close()
assert(reopened:stageOnlineReadTime("book", 4, position5, 30, false)
    and reopened:onlineReadTail("book") == 4,
    "v1.8.9 database did not migrate its durable online tail")
local migrated = assert(reopened:open())
local columns = migrated:prepare("PRAGMA table_info(read_time_online_tail)")
local column_names = {}
local column = columns:reset():step()
while column do
    column_names[tostring(column[2])] = true
    column = columns:step()
end
columns:close()
migrated:close()
assert(column_names.book_id and column_names.elapsed_seconds
    and not column_names.position_payload and not column_names.updated_at,
    "private online tail persisted unused position metadata")

for _, path in ipairs({ path_a, path_offline_handoff, path_b, path_c, path_boundary_old,
        path_boundary_new, path_boundary_missed, path_migration }) do
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
end
helper.cleanup()
print("read_report_tail_spec: durable healthy tails, cadence, offline handoff and account isolation passed")
