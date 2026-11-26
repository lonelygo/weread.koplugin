package.path = "./?.lua;" .. package.path

local Sync = require("weread.lib.offline_sync")
local WorkerSettings = require("weread.lib.worker_settings")
local function fixture()
    local state = { account = "alice", online = true, queued = nil, time = 1, probes = 0,
        positions = 0, times = 0, annotations = 0, captures = 0, pending_positions = 0, notices = {} }
    local prefs = { sync = { upload_annotations = true }, read_report = { enabled = true },
        cookies = { wr_skey = "old-cookie" }, wr_ticket = "old-ticket", wr_wrpa = "" }
    local tasks = {}
    local scheduler = {
        scheduleIn = function(_, delay, task) tasks[task] = delay end,
        unschedule = function(_, task) tasks[task] = nil end,
    }
    local settings = {
        get = function(_, key, default)
            if key == "account" then return { user_vid = state.account } end
            return prefs[key] or default
        end,
        update_auth = function(_, credentials)
            if type(credentials.cookies) == "table" then
                prefs.cookies = credentials.cookies
            end
            if type(credentials.wr_ticket) == "string" then
                prefs.wr_ticket = credentials.wr_ticket
            end
            if type(credentials.wr_wrpa) == "string" then
                prefs.wr_wrpa = credentials.wr_wrpa
            end
            return true
        end,
        flush = function() end,
    }
    local plugin = {
        settings = settings,
        library_db = {
            data_dir = "coordinator-spec",
            accountKey = function() return state.account end,
            offlineStatus = function()
                return { available = true, pending_seconds = state.seconds or 0, annotations = {},
                    unknown_seconds = state.unknown or 0, last_confirmed_at = 1 }
            end,
            pendingOfflineBook = function(_, with_time, with_annotations)
                return with_time and state.queued or with_annotations and state.annotation_book or nil
            end,
            deferPendingReadTimeForBook = function(_, book, delay)
                state.deferred_book, state.deferred_delay = book, delay
                return true, 1
            end,
            readWriteRetryAfter = function()
                return state.persisted_read_retry or 0
            end,
            setReadWriteRetryAfter = function(_, deadline)
                state.persisted_read_retry = math.max(
                    state.persisted_read_retry or 0, deadline)
                state.persisted_read_retry_writes =
                    (state.persisted_read_retry_writes or 0) + 1
                return true
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
                if state.hold then state.finish = done
                else done(state.progress_result or { status = "idle" }) end
            end,
        },
        read_report = { drain = function() state.times = state.times + 1; return state.scheduled end,
            capture_for_manual = function() end },
        _offlineAnnotationCoordinator = function()
            return { drain = function() state.annotations = state.annotations + 1 end }
        end,
        client = { settings = settings, probe_sync = function(_, book)
            assert(book == state.probe_book)
            state.probe_calls = (state.probe_calls or 0) + 1
            return state.probe_ok ~= false, state.probe_reason or "verified",
                state.probe_code
        end, renew_probe_sync = function()
            state.renew_calls = (state.renew_calls or 0) + 1
            if state.renew_ok == false then
                return false, "authentication_required", {
                    renew_attempted = true, auth_renewed = false,
                }
            end
            state.probe_calls = (state.probe_calls or 0) + 1
            return state.renew_verify_ok ~= false,
                state.renew_verify_reason or "verified", {
                    renew_attempted = true, auth_renewed = true,
                    auth_code = state.renew_verify_code,
                }
        end },
    }
    local worker = {
        available = function() return true end,
        start = function(_, job)
            state.probes = state.probes + 1
            state.job = job
            if state.worker_failure then
                return false, state.worker_failure
            end
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
local first_probe = state.job.task({ checkCancelled = function() end })
assert(state.probes == 1 and first_probe.ok)
assert(not sync:gate("weread_read_write", { operation = "progress" }))
state.job.on_done({ ok = true, value = {
    ok = false, reason = "response_unrecognized",
} })
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

local reasoned, reason_state, _, reason_step = fixture()
reasoned:activate()
reason_step()
reason_state.queued, reason_state.probe_book = "book", "book"
reason_state.probe_ok = false
reason_state.probe_reason = "authentication_required"
reason_state.probe_code = -2010
reasoned:startManual()
reason_step()
local reason_result = reason_state.job.task({ checkCancelled = function() end })
reason_state.job.on_done({ ok = true, value = reason_result })
assert(table.concat(reason_state.notices, ",") == "started,authentication_required",
    "the manual result hid a definite login failure")
assert(not reason_state.renew_calls,
    "the user-missing response attempted an unsafe cookie renewal")
reasoned:deactivate()

local renewable, renewable_state, _, renewable_step = fixture()
renewable:activate()
renewable_step()
renewable_state.queued, renewable_state.probe_book = "book", "book"
renewable_state.probe_ok = false
renewable_state.probe_reason = "authentication_required"
renewable_state.probe_code = -2012
renewable:request("network_connected")
renewable_step()
assert(renewable_state.job.timeout == 24,
    "the probe timeout cannot fit GET, renewal and verification GET")
local renewed_result = renewable_state.job.task({ checkCancelled = function() end })
assert(renewed_result.ok and renewed_result.renew_attempted
    and renewed_result.auth_renewed and renewable_state.renew_calls == 1
    and renewable_state.probe_calls == 2,
    "a confirmed -2012 renewal skipped the fresh read-only probe")
renewable_state.job.on_done({ ok = true, value = renewed_result })
renewable_step()
assert(renewable:_verified(renewable_state.account)
    and renewable_state.times == 1,
    "the freshly verified renewal did not release the queue")
renewable:deactivate()

local merged, merged_state, _, merged_step, merged_prefs = fixture()
merged:activate()
merged_step()
merged_state.queued, merged_state.probe_book = "book", "book"
merged:request("network_connected")
merged_step()
merged_state.job.on_done({ ok = true, value = {
    ok = true, reason = "verified", renew_attempted = true,
    auth_renewed = true, auth = {
        cookies = { wr_skey = "renewed-cookie" },
        wr_ticket = "renewed-ticket", wr_wrpa = "",
    },
} })
assert(merged:_verified(merged_state.account)
    and merged_prefs.cookies.wr_skey == "renewed-cookie"
    and merged_prefs.wr_ticket == "renewed-ticket",
    "the parent did not merge renewed credentials after verification")
merged:deactivate()

local guarded, guarded_state, _, guarded_step, guarded_prefs = fixture()
guarded:activate()
guarded_step()
guarded_state.queued, guarded_state.probe_book = "book", "book"
guarded:request("network_connected")
guarded_step()
guarded_prefs.cookies = { wr_skey = "manual-cookie" }
guarded_state.job.on_done({ ok = true, value = {
    ok = true, reason = "verified", renew_attempted = true,
    auth_renewed = true, auth = {
        cookies = { wr_skey = "stale-worker-cookie" },
        wr_ticket = "stale-worker-ticket", wr_wrpa = "",
    },
} })
assert(not guarded:_verified(guarded_state.account)
    and guarded_prefs.cookies.wr_skey == "manual-cookie"
    and guarded:_probeRenewalAllowed(guarded_state.account,
        WorkerSettings.fingerprint(guarded.plugin.settings)),
    "a stale worker overwrote newer parent credentials")
guarded:deactivate()

local renewal_rejected, rejected_state, _, rejected_step = fixture()
rejected_state.account = "expired-login"
renewal_rejected:activate()
rejected_step()
rejected_state.queued, rejected_state.probe_book = "book", "book"
rejected_state.probe_ok = false
rejected_state.probe_reason = "authentication_required"
rejected_state.probe_code = -2012
rejected_state.renew_ok = false
renewal_rejected:startManual()
rejected_step()
local rejected_result = rejected_state.job.task({ checkCancelled = function() end })
rejected_state.job.on_done({ ok = true, value = rejected_result })
assert(table.concat(rejected_state.notices, ",") == "started,authentication_required"
    and rejected_state.renew_calls == 1,
    "a rejected renewal did not request a fresh login")
renewal_rejected:heartbeat()
rejected_step()
local cooled_result = rejected_state.job.task({ checkCancelled = function() end })
assert(not cooled_result.ok and rejected_state.renew_calls == 1,
    "the next heartbeat repeated a rate-limited renewal")
renewal_rejected:deactivate()
local other_surface, other_state = fixture()
other_state.account = rejected_state.account
assert(not other_surface:_probeRenewalAllowed(other_state.account,
    WorkerSettings.fingerprint(other_surface.plugin.settings)),
    "moving from Home to the reader bypassed the renewal cooldown")

local busy_probe, busy_state, _, busy_step = fixture()
busy_probe:activate()
busy_step()
busy_state.queued, busy_state.probe_book = "book", "book"
busy_state.probe_ok = false
busy_state.probe_reason = "service_busy"
busy_probe:request("network_connected")
busy_step()
local busy_result = busy_state.job.task({ checkCancelled = function() end })
assert(not busy_result.ok and not busy_state.renew_calls,
    "a non-authentication probe failure attempted cookie renewal")
busy_probe:deactivate()

local rate_limited, limited_state, limited_tasks, limited_step = fixture()
limited_state.account = "rate-limit-account"
rate_limited:activate()
limited_step()
limited_state.queued, limited_state.probe_book = "book", "book"
limited_state.annotation_book = "book"
rate_limited:request("network_connected")
limited_step()
limited_state.job.on_done({ ok = true, value = true })
limited_step()
local allowed, limited_release = rate_limited:gate(
    "weread_read_write", { operation = "reading_time", book_id = "book" })
assert(allowed)
limited_release({
    accepted = false, write_attempted = false,
    error_kind = "rate_limited", retry_after = 7,
})
assert(limited_state.persisted_read_retry == limited_state.time + 7
    and limited_state.persisted_read_retry_writes == 1
    and limited_tasks[rate_limited.read_retry] == 7,
    "a reading-time rate limit was not persisted and scheduled once")
local progress_allowed, progress_reason = rate_limited:gate(
    "weread_read_write", { operation = "progress", book_id = "book" })
assert(not progress_allowed and progress_reason == "rate_limited",
    "a book/read rate limit did not pause progress writes")
local annotation_allowed, annotation_release = rate_limited:gate(
    "annotation_write", { operation = "annotation", book_id = "book" })
assert(annotation_allowed, "book/read throttling blocked the annotation endpoint")
annotation_release({ accepted = true })
assert(rate_limited:startManual())
limited_step()
assert(limited_state.probes == 2, "annotation work should verify its own connection during the throttle")
limited_state.job.on_done({ ok = true, value = true })
limited_step()
assert(limited_state.times == 1 and limited_state.annotations >= 2
    and limited_state.positions == 1,
    "a throttled pass retried read work or failed to drain annotations")
assert(table.concat(limited_state.notices, ",") == "started,service_busy",
    "a manual upload hid the active server throttle")

local switched, switched_state, switched_tasks, switched_step = fixture()
switched_state.account = limited_state.account
switched:activate()
switched_state.queued, switched_state.probe_book = "book", "book"
switched_step()
assert(switched_state.probes == 0
    and switched_tasks[switched.read_retry] == 7,
    "moving between Home and reader bypassed the account throttle")
switched_state.time = switched_state.time + 7
switched_tasks[switched.read_retry] = nil
switched.read_retry()
switched_step()
assert(switched_state.probes == 1,
    "the account throttle did not resume automatically at its deadline")
switched:deactivate()

local long_limit, long_state, long_tasks, long_step = fixture()
long_state.account = "long-rate-limit"
long_state.queued, long_state.probe_book = "book", "book"
long_limit:activate()
assert(long_limit:_setReadWriteRateLimit(long_state.account, 7200)
    == long_state.time + 7200
    and long_state.persisted_read_retry == long_state.time + 7200
    and long_tasks[long_limit.read_retry] == 3600,
    "a Retry-After over one hour was shortened")
long_step()
assert(long_state.probes == 0)
long_state.time = long_state.time + 3600
long_tasks[long_limit.read_retry] = nil
long_limit.read_retry()
long_step()
assert(long_state.probes == 0
    and long_tasks[long_limit.read_retry] == 3600,
    "the hourly timer resumed writes before the full Retry-After")
long_state.time = long_state.time + 3600
long_tasks[long_limit.read_retry] = nil
long_limit.read_retry()
long_step()
assert(long_state.probes == 1,
    "a long Retry-After did not resume at its true deadline")
long_limit:deactivate()

local restarted, restarted_state, restarted_tasks, restarted_step = fixture()
restarted_state.account = "persisted-rate-limit"
restarted_state.persisted_read_retry = restarted_state.time + 9
-- The single rate-limited row is still hidden by SQLite's retry_after.
restarted_state.probe_book = "book"
restarted:activate()
restarted_step()
assert(restarted_state.probes == 0
    and restarted_tasks[restarted.read_retry] == 9,
    "a restart ignored the persisted book/read throttle")
restarted:deactivate()

local context_retry, context_state, context_tasks, context_step = fixture()
context_state.account = "context-retry"
context_retry:activate()
context_step()
context_state.queued, context_state.probe_book = "book", "book"
context_retry:request("network_connected")
context_step()
context_state.job.on_done({ ok = true, value = true })
context_step()
local context_allowed, context_release = context_retry:gate(
    "weread_read_write", { operation = "reading_time", book_id = "book" })
assert(context_allowed)
context_release({
    accepted = false, write_attempted = false,
    error_kind = "context", retry_after = 23,
})
assert(context_tasks[context_retry.book_retry] == 23,
    "a pre-write context delay was left waiting for the heartbeat")
context_retry:deactivate()

local timed_out, timeout_state, _, timeout_step = fixture()
timed_out:activate()
timeout_step()
timeout_state.queued, timeout_state.probe_book = "book", "book"
timeout_state.probe_ok = false
timeout_state.probe_reason = "authentication_required"
timeout_state.probe_code = -2012
timed_out:startManual()
timeout_step()
timeout_state.job.on_done({ ok = false, error = "worker_timeout" })
assert(timeout_state.probe_calls == 1 and not timeout_state.renew_calls
    and table.concat(timeout_state.notices, ",")
        == "started,authentication_required",
    "a timeout fallback repeated a possibly in-flight renewal")
timed_out:deactivate()

local stale_probe, stale_state, _, stale_step = fixture()
stale_probe:activate()
stale_step()
stale_state.queued, stale_state.probe_book = "old-book", "old-book"
stale_probe:startManual()
stale_step()
stale_state.account = "new-account"
stale_state.job.on_done({ ok = false, error = "low_memory" })
assert(not stale_state.probe_calls and not stale_state.renew_calls,
    "a stale worker callback probed or renewed the replacement account")
stale_probe:deactivate()

local low_memory, low_state, _, low_step = fixture()
low_memory:activate()
low_step()
low_state.queued, low_state.probe_book = "book", "book"
low_state.worker_failure = "low_memory"
low_state.probe_ok = false
low_state.probe_reason = "authentication_required"
low_state.probe_code = -2012
low_memory:startManual()
low_step()
assert(low_memory:_verified(low_state.account),
    "an explicit tap did not use its one bounded low-memory fallback")
low_step()
assert(low_state.times == 1,
    "the verified fallback did not reach the historical writer")
assert(low_state.probe_calls == 2 and low_state.renew_calls == 1,
    "the never-started low-memory worker did not safely renew then re-probe")
low_memory:deactivate()

local isolated, isolated_state, isolated_tasks, isolated_step = fixture()
isolated:activate()
isolated_step()
isolated_state.queued, isolated_state.probe_book = "bad-book", "bad-book"
isolated_state.progress_result = {
    status = "error", book_id = "bad-book", error = "catalog_unavailable",
}
isolated:request("network_connected")
isolated_step()
isolated_state.job.on_done({
    ok = true, value = { ok = true, reason = "verified" },
})
isolated_step()
assert(isolated:_verified(isolated_state.account)
    and isolated_state.deferred_book == "bad-book"
    and isolated_state.deferred_delay == 15
    and isolated_tasks[isolated.book_retry] == 15,
    "a book-specific progress error revoked the account-wide service probe")
assert(isolated_state.annotations == 1,
    "safe annotation work was blocked by an unrelated progress failure")
isolated_state.queued = "next-book"
isolated_state.progress_result = { status = "idle" }
isolated_step()
assert(isolated_state.times == 1 and isolated_state.probes == 1,
    "one book's progress failure blocked a later book's reading time")
assert(isolated_tasks[isolated.book_retry] == 15,
    "the immediate pass consumed the failed book's delayed retry")
isolated:deactivate()

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
