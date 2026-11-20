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
    claimReadTime = function() return online and queued or nil end,
    ackReadTime = function(_self, item) acked = item.id end,
    quarantineReadTime = function(_self, item, err)
        quarantined = { item.id, err }
    end,
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
    scheduler = { scheduleIn = function() end, unschedule = function() end },
    get_document = function() return document end,
    detect_book = function() return "book" end,
    position_provider = function()
        return { book_id = "book", percent = 25 }, nil, true
    end,
    is_online = function() return online end,
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
document = nil
clock = 220
report.last_accounted_at = 160
assert(report:_capture_active_time() == 0 and #captures == 1,
    "file-manager offline replay accumulated fake reading time")
document = { file = "/book.epub" }
clock = 160

online = true
local proceed, book_id, position, item = report:_precheck()
assert(proceed and book_id == "book" and position == nil
    and item.position.percent == 25 and item.elapsed_seconds == 60,
    "reconnect did not select the oldest persisted reading-time item")

assert(report:_apply_queued_outcome(item, { accepted = true }))
assert(acked == 1 and quarantined == nil,
    "accepted replay was not acknowledged exactly once")

acked = nil
assert(not report:_apply_queued_outcome(item, {
    accepted = false, error_kind = "transport", error = "connection reset",
}))
assert(acked == nil and quarantined[1] == 1,
    "ambiguous replay was deleted or left eligible for blind retry")

local pipeline_options
report._run_pipeline = function(_self, _book_id, options)
    pipeline_options = options
    return { accepted = true }
end
assert(report:report_once())
assert(pipeline_options.force_context == true and pipeline_options.position == nil,
    "reading-time replay reused an offline position that could regress cloud progress")

local claims_before_busy = 0
library_db.claimReadTime = function()
    claims_before_busy = claims_before_busy + 1
    return queued
end
report.job = { pid = 1 }
report:_tick(report.generation, report.task)
assert(claims_before_busy == 0,
    "busy read report claimed another durable item before the active job finished")

print("read_report_offline_spec: offline capture, reconnect replay, ack and ambiguity quarantine passed")
