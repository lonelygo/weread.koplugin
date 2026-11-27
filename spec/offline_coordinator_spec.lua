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
        -- KOReader may briefly keep reporting no interface address after the
        -- radio has associated. The coordinator treats this as an advisory
        -- hint and may perform one bounded WeRead probe on an explicit tap or
        -- scheduled reconnect check. `nil` models ports without this signal.
        isWifiEnabledForSync = function() return state.wifi_enabled end,
        showManualSyncResult = function(_, code) table.insert(state.notices, code) end,
        progress_sync = {
            has_offline_movement = function() return state.offline_movement == true end,
            has_pending_for_book = function(_, book) return state.pending_positions > 0 and state.position_book == book end,
            capture_for_reconnect = function()
                state.captures = state.captures + 1
                if state.offline_movement then
                    state.pending_positions, state.position_book = 1, "book"
                    state.offline_movement = false
                end
            end,
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

-- KOReader's local link flag is advisory for WeRead sync. An explicit tap
-- must ask WeRead directly, and a confirmed WeRead response authorizes only
-- this active account/profile for a short bounded interval.
local stale_link, stale_link_state, _, stale_link_step = fixture()
stale_link_state.online = false
stale_link_state.wifi_enabled = true
stale_link_state.queued, stale_link_state.probe_book = "book", "book"
stale_link:activate()
stale_link_step()
assert(stale_link_state.probes == 0,
    "startup trusted a stale local link flag and polled WeRead")
assert(stale_link:startManual(),
    "an explicit upload was rejected by the stale local link flag")
stale_link_step()
assert(stale_link_state.probes == 1,
    "an explicit upload did not perform one bounded WeRead probe")
stale_link_state.job.on_done({ ok = true, value = {
    ok = true, reason = "verified",
} })
assert(stale_link:_verified(stale_link_state.account)
    and stale_link:isConnected(),
    "a verified WeRead response did not override the stale local hint")
stale_link_step()
assert(stale_link_state.positions == 1 and stale_link_state.times == 1
    and stale_link_state.annotations == 1,
    "verified WeRead access did not release progress, time and annotations")

local verified_until = stale_link.verified_until
stale_link_state.time = verified_until
assert(not stale_link:isConnected(),
    "verified WeRead reachability survived its bounded TTL")
stale_link_state.time = verified_until - 1
assert(stale_link:isConnected(), "the WeRead reachability TTL expired early")
stale_link:disconnected()
assert(not stale_link:isConnected(),
    "an explicit disconnect retained verified WeRead reachability")
stale_link:deactivate()

-- A FileManager/Home tap is forwarded to the active reader under the same
-- account and storage profile, even while KOReader's local link hint is false.
local stale_reader, stale_reader_state, _, stale_reader_step = fixture()
stale_reader_state.online = false
stale_reader_state.wifi_enabled = true
stale_reader_state.queued, stale_reader_state.probe_book = "reader-book", "reader-book"
stale_reader.plugin.ui = { document = { file = "reader.epub" } }
stale_reader:activate()
stale_reader_step()
local stale_home, stale_home_state = fixture()
stale_home_state.online = false
stale_home_state.account = stale_reader_state.account
assert(stale_home:startManual(),
    "the Home upload tap did not reach the active reader under a stale link hint")
stale_reader_step()
assert(stale_reader_state.probes == 1,
    "the forwarded Home tap did not perform one WeRead probe")
stale_reader_state.job.on_done({ ok = true, value = true })
assert(stale_reader:isConnected(),
    "the reader did not retain its confirmed WeRead reachability")
stale_reader_step()
stale_reader:pause()
assert(not stale_reader:isConnected(),
    "suspend retained confirmed WeRead reachability")
stale_reader:deactivate()

-- A real service response must win over KOReader's stale local flag when
-- reporting the reason. Failed probes never authorize a queued mutation.
local stale_service, stale_service_state, _, stale_service_step = fixture()
stale_service_state.online = false
stale_service_state.wifi_enabled = true
stale_service_state.queued, stale_service_state.probe_book = "book", "book"
stale_service:activate()
stale_service_step()
stale_service:startManual()
stale_service_step()
stale_service_state.job.on_done({ ok = true, value = {
    ok = false, reason = "service_busy",
} })
assert(table.concat(stale_service_state.notices, ",")
        == "started,service_busy"
    and stale_service_state.positions == 0
    and stale_service_state.times == 0
    and stale_service_state.annotations == 0,
    "the stale link hint hid a definite WeRead service response")
stale_service:deactivate()

local stale_transport, stale_transport_state, _, stale_transport_step = fixture()
stale_transport_state.online = false
stale_transport_state.wifi_enabled = true
stale_transport_state.queued, stale_transport_state.probe_book = "book", "book"
stale_transport:activate()
stale_transport_step()
stale_transport:startManual()
stale_transport_step()
stale_transport_state.job.on_done({ ok = true, value = {
    ok = false, reason = "service_unreachable",
} })
assert(table.concat(stale_transport_state.notices, ",")
        == "started,service_unreachable",
    "a failed WeRead transport was mislabeled as a definite local disconnect")
stale_transport:deactivate()

-- Passive record capture never polls. A scheduled heartbeat or explicit
-- NetworkConnected event may perform one read-only check when the Wi-Fi radio
-- is known to be enabled, while a disabled radio remains completely quiet.
local passive, passive_state, _, passive_step = fixture()
passive_state.online = false
passive_state.wifi_enabled = false
passive_state.queued, passive_state.probe_book = "book", "book"
passive:activate()
passive_step()
passive:request("read_time_captured")
passive_step()
assert(passive_state.probes == 0,
    "capturing an offline record polled the network")
passive.heartbeat()
passive_step()
assert(passive_state.probes == 0,
    "a heartbeat polled WeRead while Wi-Fi was explicitly disabled")
passive_state.wifi_enabled = true
passive.heartbeat()
passive_step()
assert(passive_state.probes == 1,
    "a scheduled check did not probe once while Wi-Fi was enabled")
passive_state.job.on_done({ ok = true, value = {
    ok = false, reason = "service_unreachable",
} })
passive:request("read_time_captured")
passive_step()
assert(passive_state.probes == 1,
    "ordinary queue activity retried a failed passive probe")
passive:request("network_connected")
passive_step()
assert(passive_state.probes == 2,
    "an explicit reconnect event did not permit one fresh probe")
passive_state.job.on_done({ ok = true, value = {
    ok = false, reason = "service_unreachable",
} })
passive:deactivate()

-- Unlocated rows are absent from the uploadable queue. An open book with
-- missing source text still supplies a target for the heartbeat's probe.
local repair_sync, repair_state, _, repair_step = fixture()
repair_state.online, repair_state.wifi_enabled = false, true
repair_state.probe_book = "open-book"
repair_sync.plugin.offline_annotations = { pendingSourceBook = function() return "open-book" end }
repair_sync:activate()
repair_step()
repair_sync.heartbeat()
repair_step()
local repair_probe = repair_state.job.task({ checkCancelled = function() end })
repair_state.job.on_done({ ok = true, value = repair_probe })
repair_step()
assert(repair_state.probe_calls == 1 and repair_state.annotations == 1 and repair_state.times == 0,
    "a reachable service did not wake source repair for the open book")
repair_sync:deactivate()

-- A newer eligible connectivity signal is not lost behind an in-flight
-- failed probe. It permits one fresh read-only check; later queue captures do
-- not keep retrying that failure.
local signaled, signaled_state, _, signaled_step = fixture()
signaled_state.online = false
signaled_state.wifi_enabled = true
signaled_state.queued, signaled_state.probe_book = "book", "book"
signaled:activate()
signaled_step()
signaled.heartbeat()
signaled_step()
assert(signaled_state.probes == 1)
local first_signaled_job = signaled_state.job
signaled:request("network_connected")
signaled:request("read_time_captured")
first_signaled_job.on_done({ ok = true, value = {
    ok = false, reason = "service_unreachable",
} })
signaled_step()
assert(signaled_state.probes == 2,
    "a newer reconnect signal was lost behind the failed probe")
signaled_state.job.on_done({ ok = true, value = {
    ok = false, reason = "service_unreachable",
} })
signaled:request("read_time_captured")
signaled_step()
assert(signaled_state.probes == 2,
    "ordinary queue capture repeatedly retried a failed probe")
signaled:deactivate()

-- A receipt owned by the old UI may tell the replacement UI to recheck the
-- service, but it cannot directly grant that replacement permission to write.
local old_surface, _, _, old_surface_step = fixture()
old_surface:activate()
old_surface_step()
local old_allowed, old_ack = old_surface:gate(
    "weread_read_write", { operation = "live_reading_time", book_id = "book" })
assert(old_allowed)
local new_surface, new_surface_state, _, new_surface_step = fixture()
new_surface_state.online = false
new_surface_state.wifi_enabled = true
new_surface_state.queued, new_surface_state.probe_book = "book", "book"
new_surface:activate()
new_surface_step()
old_ack({ accepted = true })
assert(not new_surface:isConnected(),
    "an old surface receipt directly authorized its replacement")
new_surface_step()
assert(new_surface_state.probes == 1
    and not new_surface:gate("annotation_write", { operation = "annotation" }),
    "the replacement surface did not start exactly one fresh read-only probe")
new_surface_state.job.on_done({ ok = true, value = true })
assert(new_surface:isConnected(),
    "the replacement surface ignored its own verified WeRead response")
new_surface:deactivate()

-- Reachability is scoped to the active account, profile and generation. A
-- late successful write may settle its own row but must not reopen a session
-- after disconnect, suspend or a profile switch.
local scoped, scoped_state, _, scoped_step = fixture()
scoped_state.online = false
scoped_state.wifi_enabled = true
scoped_state.queued, scoped_state.probe_book = "book", "book"
scoped:activate()
scoped_step()
scoped:startManual()
scoped_step()
scoped_state.job.on_done({ ok = true, value = true })
scoped_step()
local scoped_allowed, scoped_release = scoped:gate(
    "weread_read_write", { operation = "reading_time", book_id = "book" })
assert(scoped_allowed)
scoped:disconnected()
scoped_release({ accepted = true })
assert(not scoped:isConnected(),
    "a late write receipt reauthorized a disconnected generation")

scoped:request("network_connected")
scoped_step()
scoped_state.job.on_done({ ok = true, value = true })
assert(scoped:isConnected())
scoped_state.account = "other-account"
assert(not scoped:isConnected(),
    "verified reachability leaked to another account")
scoped_state.account = "alice"
scoped.plugin.library_db.data_dir = "other-profile"
assert(not scoped:isConnected(),
    "verified reachability leaked to another storage profile")
scoped:deactivate()

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
live:disconnected()
assert(not live:gate("weread_read_write", live_ctx), "a disconnected reader must buffer locally")
assert(not live:gate("annotation_write", {operation = "live_annotation"}))
live:deactivate()

do
    local coordinator, s, _, run_check = fixture()
    coordinator:activate()
    run_check()
    local live_tick = { operation = "live_reading_time", book_id = "book" }
    local tick_allowed, acknowledge_tick = coordinator:gate("weread_read_write", live_tick)
    assert(tick_allowed)
    acknowledge_tick({ accepted = true })
    run_check()
    -- A temporarily stale OS link hint must not discard a fresh WeRead ACK
    -- or make normal page turns look like reconnects on an empty queue.
    s.online = false
    for _, event in ipairs({"heartbeat", "network_connected", "resume"}) do
        coordinator:request(event)
        run_check()
        assert(s.captures == 0 and s.probes == 0 and s.positions == 0 and coordinator:isConnected(),
            "idle connectivity check manufactured work or revoked the service receipt: " .. event)
    end
    coordinator:disconnected()
    assert(s.captures == 1 and not coordinator:isConnected())
    s.offline_movement, s.online = true, true
    local resumed, why = coordinator:gate("weread_read_write", live_tick)
    assert(not resumed and why == "progress_pending" and s.captures == 2 and s.position_book == "book",
        "a live tick overtook reconciliation of a genuinely offline page turn")
    s.probe_book = "book"
    run_check()
    assert(s.probes == 1, "reconcile was not scheduled after the missed reconnect event")
    s.job.on_done({ ok = true, value = true })
    run_check()
    local still_blocked = coordinator:gate("weread_read_write", live_tick)
    assert(not still_blocked, "a later tick ignored this book's pending decision")
    s.pending_positions, s.position_book = 0, nil
    local settled, finish_book = coordinator:gate("weread_read_write", live_tick)
    assert(settled, "settling the position must release normal online reporting")
    finish_book({ accepted = true })
    coordinator:deactivate()
end
print("offline_coordinator_spec: passive checks, replay gates, account and screen transitions passed")
