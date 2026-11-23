package.path = "./?.lua;" .. package.path

local Sync = require("weread.lib.offline_sync")
local function fixture()
    local state = { account = "alice", online = true, queued = nil, time = 1, probes = 0,
        positions = 0, times = 0, annotations = 0, captures = 0, pending_positions = 0 }
    local prefs = { sync = { upload_annotations = true }, read_report = { enabled = true } }
    local tasks = {}
    local scheduler = {
        scheduleIn = function(_, delay, task) tasks[task] = delay end,
        unschedule = function(_, task) tasks[task] = nil end,
    }
    local plugin = {
        settings = { get = function(_, key) return prefs[key] end },
        library_db = {
            accountKey = function() return state.account end,
            pendingOfflineBook = function(_, with_time, with_annotations)
                if with_time or with_annotations then return state.queued end
            end,
        },
        isNetworkConnected = function() return state.online end,
        progress_sync = {
            capture_for_reconnect = function() state.captures = state.captures + 1 end,
            has_pending = function()
                return state.pending_positions > 0,
                    { actionable = state.pending_positions, book_id = state.position_book }
            end,
            awaiting_choice = function(_, book) return state.conflict == book end,
            reconcile_pending = function(_, done, options)
                state.positions = state.positions + 1
                state.options = options
                if state.hold then state.finish = done else done({ status = "idle" }) end
            end,
        },
        read_report = { drain = function() state.times = state.times + 1 end },
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
print("offline_coordinator_spec: passive checks, replay gates, account and screen transitions passed")
