package.path = "./?.lua;" .. package.path

local Sync = require("weread.lib.offline_sync")
local function fixture()
    local state = { account = "alice", online = true, queued = nil, time = 1, probes = 0,
        positions = 0, times = 0, annotations = 0, captures = 0, pending_positions = 0, notices = {} }
    local prefs = { sync = { upload_annotations = true }, read_report = { enabled = true } }
    local tasks = {}
    local scheduler = {
        scheduleIn = function(_, delay, task) tasks[task] = delay end,
        unschedule = function(_, task) tasks[task] = nil end,
    }
    local plugin = {
        settings = { get = function(_, key, default)
            if key == "account" then return { user_vid = state.account } end
            return prefs[key] or default
        end },
        library_db = {
            data_dir = "coordinator-spec",
            accountKey = function() return state.account end,
            offlineStatus = function()
                return { available = true, pending_seconds = state.seconds or 0, annotations = {},
                    unknown_seconds = state.unknown or 0, last_confirmed_at = 1 }
            end,
            pendingOfflineBook = function(_, with_time, with_annotations)
                if with_time or with_annotations then return state.queued end
            end,
        },
        isNetworkConnected = function() return state.online end,
        showManualSyncResult = function(_, code) table.insert(state.notices, code) end,
        progress_sync = {
            capture_for_reconnect = function() state.captures = state.captures + 1 end,
            has_pending = function()
                return state.pending_positions > 0,
                    { actionable = state.pending_positions, book_id = state.position_book }
            end,
            awaiting_choice = function(_, book) return state.conflict and (not book or state.conflict == book) end,
            reconcile_pending = function(_, done, options)
                state.positions = state.positions + 1
                state.options = options
                if state.hold then state.finish = done else done({ status = "idle" }) end
            end,
        },
        read_report = { drain = function() state.times = state.times + 1; return state.scheduled end,
            capture_for_manual = function() end },
        _offlineAnnotationCoordinator = function()
            return { drain = function() state.annotations = state.annotations + 1 end }
        end,
        client = { probe_sync = function(_, book)
            assert(book == state.probe_book)
            return true
        end },
    }
    local worker = {
        available = function() return true end,
        start = function(_, job)
            state.probes = state.probes + 1
            state.job = job
            return true
        end,
    }
    local sync = Sync:new(plugin, scheduler, worker, function() return state.time end)
    local function run()
        assert(tasks[sync.run], "coordinator did not enqueue work")
        tasks[sync.run] = nil
        sync.run()
    end
    return sync, state, tasks, run, prefs
end

local sync, state, tasks, run, prefs = fixture()
sync:activate()
assert(tasks[sync.heartbeat] == 600, "ten minute default")
prefs.sync.heartbeat_minutes = 2
sync:reschedule_heartbeat()
assert(tasks[sync.heartbeat] == 120)
run()
assert(state.probes == 0, "empty queues should not contact the network")
state.queued, state.probe_book = "book", "book"
state.online = false
sync.heartbeat()
run()
assert(state.probes == 0 and state.positions == 0)
state.online = true
sync.heartbeat()
sync:request("network_connected")
run()
assert(state.probes == 1 and state.job.task({ checkCancelled = function() end }))
assert(not sync:gate("weread_read_write", { operation = "progress" }))
state.job.on_done({ ok = true, value = false })
sync:request("read_time_captured")
run()
assert(state.probes == 1 and state.times == 0, "failed probe must not claim an item or spin")
sync.heartbeat()
run()
state.job.on_done({ ok = true, value = true })
run()
assert(state.probes == 2 and state.times == 1 and state.annotations == 1)
state.conflict = "book"
assert(not sync:gate("weread_read_write", { operation = "reading_time", book_id = "book" }))
local granted, release = sync:gate("weread_read_write", { operation = "reading_time", book_id = "other" })
assert(granted, "a conflict should not block unrelated books")
assert(not sync:gate("weread_read_write", { operation = "progress" }))
local mark, release_mark = sync:gate("annotation_write", { book_id = "book" })
assert(mark, "annotation endpoint is independent")
release_mark({ accepted = true })
release({ accepted = true })
sync:request("manual_sync", { manual = true, book_id = "book" })
run()
state.job.on_done({ ok = true, value = true })
run()
assert(state.options.manual and state.options.book_id == "book")

sync:disconnected()
sync.heartbeat()
run()
local stale = state.job
state.account = "bob"
sync:request("network_connected")
run()
assert(state.job ~= stale)
stale.on_done({ ok = true, value = true })
assert(not sync:gate("annotation_write", {}), "a probe for the old account cannot authorize this one")
state.hold = true
state.job.on_done({ ok = true, value = true })
run()
state.account = "carol"
state.finish({ status = "idle" })
assert(sync.stage == nil, "account change during comparison must not wedge the coordinator")
run()
local before = state.probes
local old_job = state.job
sync:pause()
assert(not tasks[sync.heartbeat] and not tasks[sync.run])
old_job.on_done({ ok = true, value = true })
sync.heartbeat()
assert(state.probes == before and not tasks[sync.run])
sync:resume()
run()
state.hold = false
state.job.on_done({ ok = true, value = true })
run()
state.conflict = nil
local old_grant, old_release = sync:gate("weread_read_write", { operation = "progress" })
assert(old_grant)

local second, next_state, _, next_run = fixture()
next_state.account = state.account
second:activate()
assert(not tasks[sync.heartbeat] and not sync:request("network_connected"))
next_state.queued = "new"
next_run()
next_state.job.on_done({ ok = true, value = true })
next_run()
assert(not second:gate("weread_read_write", { operation = "progress" }), "overlapping writers at screen transition")
old_release({ accepted = false, error_kind = "transport" })
assert(not second:gate("annotation_write", {}), "a late transport failure from the same login must revoke the new grant")
second.heartbeat()
next_run()
next_state.job.on_done({ ok = true, value = true })
next_run()
local yes, finish = second:gate("weread_read_write", { operation = "progress" })
assert(yes)
finish({ accepted = false, write_attempted = true, error_kind = "transport" })
assert(not second:gate("annotation_write", {}), "failed transport should require another probe")
second:deactivate()

local feedback, f, _, step, flags = fixture()
local status = require("weread.lib.sync_status")
local function work(seconds, unknown)
    f.seconds, f.unknown = seconds, unknown
    f.queued = seconds > 0 and "book" or nil
    status.invalidateOffline(feedback.plugin.settings)
end
local function notices(expected)
    assert(table.concat(f.notices, ",") == expected, table.concat(f.notices, ","))
    f.notices = {}
end
feedback:activate()
f.scheduled = true
work(50)
feedback.heartbeat()
step()
f.job.on_done({ ok = true, value = true })
step()
local _, ack = feedback:gate("weread_read_write", { operation = "reading_time" })
work(0)
ack({ accepted = true })
step()
notices("") -- background replay stays silent

feedback:startManual()
step()
notices("started,empty") -- yesterday's confirmation is not today's receipt
work(50)
feedback:startManual()
feedback:startManual()
step()
f.job.on_done({ ok = true, value = true })
step()
local _, part = feedback:gate("weread_read_write", { operation = "reading_time" })
work(20)
part({ accepted = true })
step()
notices("started") -- a positive reply for only the first item
local _, lost = feedback:gate("weread_read_write", { operation = "reading_time" })
work(0, 20)
lost({ accepted = false, write_attempted = true, error_kind = "transport" })
step()
notices("uploaded_with_review") -- this tap received an ACK before the later lost reply
work(10)
feedback:startManual()
step()
f.job.on_done({ ok = true, value = true })
step()
local _, rejected = feedback:gate("weread_read_write", { operation = "reading_time" })
rejected({ accepted = false, error_kind = "server" })
step()
notices("started,unconfirmed")

feedback:startManual()
step()
f.job.on_done({ ok = true, value = true })
step()
local _, from_alice = feedback:gate("weread_read_write", { operation = "reading_time" })
f.account = "other"
work(0)
from_alice({ accepted = true })
step()
notices("started") -- stale replies do not notify the new login
flags.read_report.enabled, flags.sync.upload_annotations = false, false
work(20)
feedback:startManual()
step()
notices("started,pending")
work(0)
f.position_book, f.pending_positions = "book", 1
feedback:startManual()
step()
f.hold = true
f.job.on_done({ ok = true, value = true })
step()
f.position_book, f.pending_positions = nil, 0
f.finish({ status = "synced" })
feedback:request("matching_progress_finished")
step()
notices("started,matched") -- a read-only match does not claim an upload
local reader, reader_state, _, reader_step = fixture()
reader_state.account = f.account
reader:activate()
assert(feedback:startManual(), "Home tap on the reused FileManager should reach the active reader")
reader_step()
assert(table.concat(reader_state.notices, ",") == "started,empty")
reader_state.account = "separate-login"
assert(not feedback:startManual(), "a Home tap cannot start work on behalf of a different login")
reader:deactivate()
feedback:deactivate()
-- A connected reader uses the normal reporting interval even when an old
-- ambiguous write is awaiting review and progress polling cannot run.
local live, l, _, live_run = fixture()
live:activate()
live_run()
l.unknown, l.seconds, l.queued, l.probe_book = 14, 5223, "other", "other"
local live_ctx = { operation = "live_reading_time", book_id = "here", position_verified = true }
local live_ok, live_ack = live:gate("weread_read_write", live_ctx)
assert(live_ok and l.probes == 0, "live reports must not wait for offline replay or a progress probe")
assert(not live:gate("weread_read_write", live_ctx), "live reports must serialize with other read writes")
local ann_ok, ann_ack = live:gate("annotation_write", { operation = "live_annotation", book_id = "here" })
assert(ann_ok, "a live note should be able to upload while a time write is in flight")
ann_ack({ accepted = true })
live_ack({ accepted = true })
assert(live:_verified(l.account), "a real write receipt confirms service reachability")
live.plugin.ui = { document = { file = "book.epub" } }
local hidden = fixture()
hidden.plugin.ui = {}
assert(not hidden:activate(), "a hidden FileManager stole the active reader's upload timers")
assert(live:request("annotation_captured", {live = true, book_id = "here"}))
assert(l.annotations == 1, "new online note waited for an offline progress probe")
local relogin_ok, relogin = live:gate("weread_read_write", live_ctx)
assert(relogin_ok)
relogin({ accepted = false, write_attempted = true, error_kind = "authentication", auth_renewed = true })
live_run()
assert(l.probes == 1 and not live:_verified(l.account), "renewed credentials require a fresh service probe")
l.job.on_done({ ok = true, value = true })
l.conflict = "here"
assert(not live:gate("weread_read_write", live_ctx), "respect in-book progress choices")
l.conflict, l.online = nil, false
assert(not live:gate("weread_read_write", live_ctx), "a disconnected reader must buffer locally")
assert(not live:gate("annotation_write", {operation = "live_annotation"}))
live:deactivate()
print("offline_coordinator_spec: passive checks, replay gates, account and screen transitions passed")
