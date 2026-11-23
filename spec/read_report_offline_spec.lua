package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_success_response = function(value) return value and value.succ == 1 end }
end

local ReadReport = require("weread.lib.read_report")
local online = false
local queued
local captures = {}
local acked
local quarantined
local released
local gate_releases = {}
local gate_contexts = {}
local sync_requests = {}
local scheduled_delays = {}
local library_db = {
    enqueueReadTime = function(_self, book_id, seconds, position)
        queued = { id = 1, book_id = book_id, elapsed_seconds = seconds,
            position = position, claim_token = "claim", database_path = "/test" }
        captures[#captures + 1] = queued
        return true
    end,
    nextReadTime = function()
        return online and queued or nil
    end,
    pendingOfflineBook = function() return queued and queued.book_id or nil end,
    claimReadTime = function() return online and queued or nil end,
    ackReadTime = function(_self, item) acked = item.id end,
    quarantineReadTime = function(_self, item, err)
        quarantined = { item.id, err }
    end,
    releaseReadTimeClaim = function(_self, item) released = item.id end,
}
local settings = {
    get = function(_self, key)
        if key == "read_report" then
            return { enabled = true, mode = "auto", interval_seconds = 60 }
        end
        if key == "books" then return { book = { title = "Book" } } end
        return {}
    end,
    is_cookie_configured = function() return true end,
}
local clock = 160
local wall_clock = 1000
local document = { file = "/book.epub" }
local report = ReadReport:new{
    settings = settings,
    client = {},
    library_db = library_db,
    scheduler = {
        scheduleIn = function(_self, delay)
            scheduled_delays[#scheduled_delays + 1] = delay
        end,
        unschedule = function() end,
    },
    get_document = function() return document end,
    detect_book = function() return "book" end,
    position_provider = function()
        return { book_id = "book", percent = 25 }, nil, true
    end,
    is_online = function() return online end,
    gate = function(kind, context)
        assert(kind == "weread_read_write", "unexpected read-report gate kind")
        gate_contexts[#gate_contexts + 1] = context
        if not online then return false, "offline" end
        return true, function(outcome)
            gate_releases[#gate_releases + 1] = {
                operation = context.operation, outcome = outcome,
            }
        end
    end,
    request_sync = function(reason, context)
        sync_requests[#sync_requests + 1] = {
            reason = reason, book_id = context.book_id,
        }
    end,
    subprocess = false,
    now = function() return wall_clock end,
    active_now = function() return clock end,
}
report.current_book_id = "book"
report.last_accounted_at = 100
wall_clock = 999999

assert(not report:_precheck(), "offline report precheck unexpectedly used the network")
assert(queued and queued.elapsed_seconds == 60 and queued.position.percent == 25,
    "monotonic reading interval was corrupted by a wall-clock jump")
assert(#sync_requests >= 1 and sync_requests[1].reason == "read_time_captured",
    "durable reading time did not request a coordinated replay")
local denied_request_count = #sync_requests
assert(not report:_precheck(), "repeated offline precheck unexpectedly passed")
assert(#sync_requests == denied_request_count,
    "unchanged gate denial created a coordinator wake loop")
document = nil
clock = 220
report.last_accounted_at = 160
assert(report:_capture_active_time() == 0 and #captures == 1,
    "file-manager offline replay accumulated fake reading time")
document = { file = "/book.epub" }
clock = 160

online = true
queued.book_id = "queued-book"
local proceed, book_id, position, item = report:_precheck()
assert(proceed and book_id == "queued-book" and position == nil
    and item.position.percent == 25 and item.elapsed_seconds == 60,
    "reconnect did not select the oldest persisted reading-time item")
assert(gate_contexts[#gate_contexts].book_id == "queued-book",
    "read-time gate used the unrelated foreground book instead of the claimed queue book")

assert(report:_apply_queued_outcome(item, { accepted = true }))
assert(acked == 1 and quarantined == nil,
    "accepted replay was not acknowledged exactly once")
assert(#gate_releases == 1 and gate_releases[1].operation == "reading_time",
    "read-time gate lease was not held through the completed request")
report.task = function() end
assert(report:drain())
assert(scheduled_delays[#scheduled_delays] == 30,
    "rapid drain bypassed the 30-second reading-time replay interval")
report.task = nil

acked = nil
assert(not report:_apply_queued_outcome(item, {
    accepted = false, error_kind = "transport", error = "connection reset",
}))
assert(acked == nil and quarantined[1] == 1,
    "ambiguous replay was deleted or left eligible for blind retry")

wall_clock = wall_clock + 31
local proceed_before_context = report:_precheck()
assert(proceed_before_context, "context-failure replay was not admitted")
assert(not report:_apply_queued_outcome(queued, {
    accepted = false, write_attempted = false,
    error_kind = "context", error = "reader init failed",
}))
assert(released == 1,
    "request that failed before its first write did not return to pending")

local saved_ensure_context = report.ensure_context
local saved_send = report._send
report.ensure_context = function()
    return { book_id = "queued-book", chapter_uid = 1 }
end
report._send = function()
    error("enter request failed")
end
local before_write = report:_run_pipeline("queued-book", { allow_renewal = false })
assert(before_write.error_kind == "transport"
    and before_write.write_attempted == false,
    "enter/init failure was misclassified as an ambiguous reading-time write")
report._send = function(_self, _book_id, _book, _position, _elapsed, on_write)
    on_write()
    error("time request failed")
end
local during_write = report:_run_pipeline("queued-book", { allow_renewal = false })
assert(during_write.error_kind == "transport"
    and during_write.write_attempted == true,
    "ambiguous reading-time request was incorrectly made replayable")
report.ensure_context = saved_ensure_context
report._send = saved_send

local pipeline_options
local saved_run_pipeline = report._run_pipeline
report._run_pipeline = function(_self, _book_id, options)
    pipeline_options = options
    return { accepted = true }
end
assert(report:report_once())
assert(pipeline_options.force_context == true and pipeline_options.position == nil,
    "reading-time replay reused an offline position that could regress cloud progress")
report._run_pipeline = saved_run_pipeline

local claims_before_busy = 0
library_db.claimReadTime = function()
    claims_before_busy = claims_before_busy + 1
    return queued
end
report.job = { pid = 1 }
report:_tick(report.generation, report.task)
assert(claims_before_busy == 0,
    "busy read report claimed another durable item before the active job finished")

-- A subprocess can be terminated while it is refreshing context or while the
-- elapsed-time POST is in flight. The parent must wait until the child is
-- reaped before inspecting the write marker, otherwise the child could start
-- the request after the claim had already been made replayable.
local original_ensure_context = report.ensure_context
local original_send = report._send
local original_flush = settings.flush
local original_update_auth = settings.update_auth
local original_scheduler = report.scheduler
local process
local finish_on_terminate = true
report.subprocess = {
    run = function(child)
        process = { done = false }
        process.coroutine = coroutine.create(function() child(77, 88) end)
        local ok, stage = coroutine.resume(process.coroutine)
        assert(ok, stage)
        process.stage = stage
        return 77, 88
    end,
    write_all = function() error("blocked child unexpectedly completed") end,
    is_done = function() return process.done end,
    terminate = function()
        process.terminate_requested = true
        process.done = finish_on_terminate
    end,
    read_size = function() return 0 end,
    read_all = function() return "" end,
}

released = nil
quarantined = nil
gate_releases = {}
report.ensure_context = function()
    coroutine.yield("context_pending")
end
report.task = function() end
assert(report:_start_job("queued-book", false, report.generation, report.task,
    nil, queued.elapsed_seconds, queued, function(outcome)
        gate_releases[#gate_releases + 1] = { outcome = outcome }
    end))
local before_write_job = report.job
assert(process.stage == "context_pending", "fixture did not stop before its write")
report:stop("suspend")
assert(released == queued.id and quarantined == nil,
    "terminated context refresh did not return its unsent claim to pending")
assert(gate_releases[#gate_releases].outcome.write_attempted == false,
    "terminated context refresh was reported as an attempted elapsed-time POST")
assert(io.open(before_write_job.write_marker, "rb") == nil,
    "pre-write subprocess marker was not cleaned up")

released = nil
quarantined = nil
gate_releases = {}
report.ensure_context = function()
    return { book_id = "queued-book", chapter_uid = 1 }
end
report._send = function(_self, _book_id, _book, _position, _elapsed, on_write)
    on_write()
    coroutine.yield("elapsed_post_pending")
end
report.task = function() end
assert(report:_start_job("queued-book", false, report.generation, report.task,
    nil, queued.elapsed_seconds, queued, function(outcome)
        gate_releases[#gate_releases + 1] = { outcome = outcome }
    end))
local during_write_job = report.job
assert(process.stage == "elapsed_post_pending",
    "fixture did not stop after starting its elapsed-time POST")
wall_clock = during_write_job.started_at + 181
report:_poll_job(during_write_job, report.generation, report.task)
assert(released == nil and quarantined
    and quarantined[1] == queued.id and quarantined[2] == "report_abandoned",
    "timed-out elapsed-time POST remained eligible for a blind retry")
assert(gate_releases[#gate_releases].outcome.write_attempted == true,
    "timed-out elapsed-time POST lost its durable started marker")
assert(io.open(during_write_job.write_marker, "rb") == nil,
    "post-write subprocess marker was not cleaned up")

-- A termination request is asynchronous. Simulate the child reaching the
-- write boundary after terminate() was called but before waitpid reports it
-- dead. The claim must remain untouched until that final state is known.
released = nil
quarantined = nil
gate_releases = {}
local collected = {}
report.scheduler = {
    scheduleIn = function(_self, _delay, callback)
        collected[#collected + 1] = callback
    end,
    unschedule = function() end,
}
report.ensure_context = function()
    return coroutine.yield("context_pending_during_termination")
end
report.task = function() end
finish_on_terminate = false
assert(report:_start_job("queued-book", false, report.generation, report.task,
    nil, queued.elapsed_seconds, queued, function(outcome)
        gate_releases[#gate_releases + 1] = { outcome = outcome }
    end))
local racing_job = report.job
collected = {}
report:_abandon_job(racing_job)
assert(process.terminate_requested and released == nil and quarantined == nil,
    "claim was finalized before the terminated child was reaped")
local resumed, stage = coroutine.resume(
    process.coroutine, { book_id = "queued-book", chapter_uid = 1 })
assert(resumed and stage == "elapsed_post_pending",
    "termination race did not reach the elapsed-time write boundary")
process.done = true
assert(#collected == 1, "terminated child was not scheduled for collection")
collected[1]()
assert(released == nil and quarantined and quarantined[1] == queued.id,
    "write started during termination race was incorrectly made replayable")
assert(gate_releases[#gate_releases].outcome.write_attempted == true,
    "termination race did not preserve its write-started evidence")
assert(io.open(racing_job.write_marker, "rb") == nil,
    "termination-race subprocess marker was not cleaned up")

report.ensure_context = original_ensure_context
report._send = original_send
report.scheduler = original_scheduler
settings.flush = original_flush
settings.update_auth = original_update_auth

print("read_report_offline_spec: offline capture, reconnect replay, ack and ambiguity quarantine passed")
