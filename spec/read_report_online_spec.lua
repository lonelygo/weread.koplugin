package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.sync_status"] = function()
    return { noteAck = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_success_response = function(value) return value and value.succ == 1 end }
end

local ReadReport = require("weread.lib.read_report")

local clock = 130
local wall_clock = 1000
local rows = {
    [1] = { id = 1, book_id = "old", elapsed_seconds = 14,
        position = { chapter_uid = 1 }, database_path = "/test" },
}
local claims, gates, acked, rejected, quarantined, released = {}, {}, {}, {}, {}, {}
local enqueues = {}
local receipts = { count = 7, seconds = 210, last_time = 900 }
local next_id = 2
local interval = 30
local function first_row_id()
    local selected
    for id in pairs(rows) do
        if not selected or id < selected then selected = id end
    end
    return selected
end
local db = {
    enqueueReadTime = function(_self, book_id, seconds, position, options)
        local first
        local chunk = tonumber(options and options.max_chunk_seconds) or 30
        enqueues[#enqueues + 1] = { seconds = seconds, position = position,
            max_chunk_seconds = chunk }
        while seconds > 0 do
            local id = next_id
            next_id = next_id + 1
            first = first or id
            rows[id] = { id = id, book_id = book_id,
                elapsed_seconds = math.min(chunk, seconds),
                position = position, database_path = "/test" }
            seconds = seconds - chunk
        end
        return true, first
    end,
    hasPendingOfflineWork = function() return next(rows) ~= nil end,
    pendingOfflineBook = function()
        local id = first_row_id()
        return id and rows[id].book_id or "book"
    end,
    recoverStaleReadTimeClaims = function() end,
    claimReadTime = function(_self, _owner, exact_id)
        local id = exact_id or first_row_id()
        local row = rows[id]
        claims[#claims + 1] = { exact_id = exact_id, claimed_id = row and row.id }
        if row then row.claim_token = "claim:" .. id end
        return row
    end,
    ackReadTime = function(_self, item)
        acked[#acked + 1] = item.id
        rows[item.id] = nil
        return true
    end,
    rejectReadTime = function(_self, item, reason)
        rejected[#rejected + 1] = { item.id, reason }
        rows[item.id] = nil
        return true
    end,
    quarantineReadTime = function(_self, item, reason)
        quarantined[#quarantined + 1] = { item.id, reason }
        rows[item.id] = nil
        return true
    end,
    releaseReadTimeClaim = function(_self, item)
        released[#released + 1] = item.id
        return true
    end,
    readTimeReceipts = function() return receipts end,
}
local settings = {
    get = function(_self, key)
        if key == "read_report" then
            return { enabled = true, mode = "auto", interval_seconds = interval }
        end
        if key == "books" then return { book = { title = "Book" } } end
        return {}
    end,
    is_cookie_configured = function() return true end,
}
local scheduled = {}
local scheduler = {
    scheduleIn = function(_self, delay, callback)
        scheduled[#scheduled + 1] = { delay = delay, callback = callback }
    end,
    unschedule = function(_self, callback)
        for index = #scheduled, 1, -1 do
            if scheduled[index].callback == callback then table.remove(scheduled, index) end
        end
    end,
}
local live_position = { book_id = "book", chapter_uid = 9, percent = 42 }
local report = ReadReport:new{
    settings = settings,
    client = {},
    library_db = db,
    scheduler = scheduler,
    get_document = function() return { file = "/book.epub" } end,
    detect_book = function() return "book" end,
    position_provider = function() return live_position, nil, true end,
    is_online = function() return true end,
    gate = function(_kind, context)
        gates[#gates + 1] = context
        return true, function() end
    end,
    subprocess = false,
    now = function() return wall_clock end,
    active_now = function() return clock end,
}
report.current_book_id = "book"
report.current_book_source = "current_document"
report.last_accounted_at = 100

local proceed, book_id, position, fresh = report:_precheck()
assert(proceed and book_id == "book" and fresh.id == 2)
assert(claims[1].exact_id == 2 and gates[1].operation == "live_reading_time")
assert(gates[1].position == live_position and gates[1].position_verified,
    "live gate did not receive the verified local position")
assert(position == live_position and fresh._fresh_online,
    "fresh online row lost its verified live position")

local pipeline_options
local original_pipeline = report._run_pipeline
report._run_pipeline = function(_self, _book_id, options)
    pipeline_options = options
    return { accepted = true }
end
report:_apply_queued_outcome(fresh, report:_run_pipeline(book_id, {
    position = position, elapsed_seconds = fresh.elapsed_seconds,
    force_context = not fresh._fresh_online,
}))
assert(acked[1] == 2 and rows[1], "fresh online row did not bypass old work")
assert(pipeline_options.position == live_position and not pipeline_options.force_context)
report.task = function() end
assert(report:_schedule_replay(report.generation),
    "fresh success did not reserve a separate replay slot")
assert(#scheduled == 1 and scheduled[1].delay >= 0.2,
    "historic replay was not independently paced")
scheduled[1].callback()
assert(acked[2] == 1 and not rows[1], "separate replay did not shrink old backlog")
assert(claims[2].exact_id == nil and gates[2].operation == "reading_time",
    "historic replay was routed as a live period")
assert(pipeline_options.position == nil and pipeline_options.force_context,
    "historic replay reused a stale persisted position")

clock, wall_clock = 160, 1030
local next_ok, _, next_position, next_live = report:_precheck()
assert(next_ok and next_live.id == 3 and next_position == live_position,
    "next normal tick was skipped or reordered behind replay")
assert(enqueues[2].seconds == 30 and enqueues[2].position == live_position)
report:_apply_queued_outcome(next_live, { accepted = true })

local refused = { id = 4, book_id = "book", claim_token = "claim:4",
    database_path = "/test" }
report:_apply_queued_outcome(refused, {
    accepted = false, error_kind = "rejected", error = "duration rejected",
    write_attempted = true,
})
assert(rejected[1][1] == 4 and #released == 0 and #quarantined == 0,
    "explicit row rejection remained at the queue head")
report._run_pipeline = original_pipeline

local ambiguous = { id = 3, book_id = "book", claim_token = "claim:3",
    database_path = "/test" }
report:_apply_queued_outcome(ambiguous, {
    accepted = false, error_kind = "unknown", error = "empty receipt",
    write_attempted = true,
})
assert(quarantined[1][1] == 3, "ambiguous post-write result was replayable")

local status = report:status()
assert(status.count == 7 and status.confirmed_seconds == 210
    and status.last_time == 900,
    "persisted receipts were not shown across plugin instances")

-- A connected 60-second interval is one exact live row. Historic replay owns
-- a separate bounded slot and cannot consume, reorder or recapture a live
-- period.
rows = {
    [9] = { id = 9, book_id = "old", elapsed_seconds = 14,
        position = {}, database_path = "/test" },
}
next_id, interval, clock, wall_clock = 10, 60, 260, 2000
local scheduled60 = {}
local scheduler60 = {
    scheduleIn = function(_self, delay, callback)
        scheduled60[#scheduled60 + 1] = { delay = delay, callback = callback }
    end,
    unschedule = function() end,
}
local report60 = ReadReport:new{
    settings = settings, client = {}, library_db = db,
    scheduler = scheduler60,
    get_document = function() return { file = "/book.epub" } end,
    detect_book = function() return "book" end,
    position_provider = function() return live_position, nil, true end,
    is_online = function() return true end,
    gate = function(_kind, context)
        gates[#gates + 1] = context
        return true, function() end
    end,
    subprocess = false,
    now = function() return wall_clock end,
    active_now = function() return clock end,
}
report60.current_book_id = "book"
report60.current_book_source = "current_document"
report60.last_accounted_at = 200
local live_ok, _, _, live_row = report60:_precheck()
assert(live_ok and live_row.id == 10 and live_row.elapsed_seconds == 60
    and not rows[11] and enqueues[#enqueues].max_chunk_seconds == 60,
    "connected 60-second live period was split or truncated")
report60:_apply_queued_outcome(live_row, { accepted = true })
report60.task = function() end
local replay_options
report60._run_pipeline = function(_self, _book_id, options)
    replay_options = options
    return { accepted = true }
end
assert(report60:_schedule_replay(report60.generation))
scheduled60[1].callback()
assert(not rows[9] and next_id == 11 and replay_options.position == nil
    and replay_options.force_context,
    "historic slot failed to shrink backlog or recaptured live time")
wall_clock, clock = 2060, 320
local next_live_ok, _, _, next_live_row = report60:_precheck()
assert(next_live_ok and next_live_row.id == 11
    and next_live_row.elapsed_seconds == 60,
    "next configured live tick was skipped behind replay")
report60:_apply_queued_outcome(next_live_row, { accepted = true })
assert(not next(rows), "live rows were charged twice or left behind")
rows[12] = { id = 12, book_id = "old", elapsed_seconds = 30,
    position = {}, database_path = "/test" }
next_id = 13
scheduled60 = {}
assert(report60:_schedule_replay(report60.generation))
assert(scheduled60[1].delay >= 0.2,
    "historic replay ignored its bounded replay slot")
scheduled60[1].callback()
assert(not rows[12], "old backlog did not shrink across live periods")
interval, clock, wall_clock = 30, 350, 2090
rows, next_id = {}, 14
report60.position_provider = function() return nil, "position unavailable", true end
report60.last_accounted_at = 320
local time_only_ok, _, time_only_position, time_only = report60:_precheck()
assert(time_only_ok and time_only_position == nil and time_only._force_context,
    "time-only live row could reuse stale cached progress context")

report.ensure_context = function()
    return { book_id = "book", chapter_uid = 9 }
end
local replies
local send_calls = 0
local renewals = 0
report.client.renew_cookie = function()
    renewals = renewals + 1
    return { succ = 1 }
end
report._send = function(_self, _book_id, _book, _position, _elapsed, on_write)
    on_write()
    send_calls = send_calls + 1
    local reply = table.remove(replies, 1)
    return reply[1], reply[2]
end
replies = { { { succ = 0, code = 14, synckey = "ignored" }, 200 } }
local denied = report:_run_pipeline("book", { allow_renewal = true })
assert(denied.error_kind == "rejected" and denied.write_attempted,
    "explicit business denial was not definitive: "
        .. tostring(denied.error_kind) .. " / " .. tostring(denied.error))
assert(send_calls == 1, "explicit refusal triggered a second elapsed-time POST")

send_calls = 0
replies = { { {}, 200 } }
local unknown = report:_run_pipeline("book", { allow_renewal = true })
assert(unknown.error_kind == "unknown" and unknown.write_attempted,
    "unrecognized post-write response was treated as retryable")
assert(send_calls == 1, "blank 200 triggered a context refresh or second POST")

replies = { { nil, 429 } }
assert(report:_run_pipeline("book", { allow_renewal = true }).error_kind == "rate_limited")
assert(renewals == 0, "an ambiguous, rejected or rate-limited report renewed the login")

replies = { { { succ = 0 }, 401 } }
send_calls = 0
local renewed = report:_run_pipeline("book", { allow_renewal = true })
assert(renewed.auth_renewed and renewed.renew_attempted and not renewed.accepted)
local expired_row = { id = 20, book_id = "book", claim_token = "auth" }
report:_apply_queued_outcome(expired_row, renewed)
assert(send_calls == 1 and renewals == 1 and released[#released] == 20,
    "the refused row must stay pending until a separate delivery with the new login")
assert(not report:_renewal_allowed(), "the renewal cooldown was lost")

report._send = function(_self, _book_id, _book, _position, _elapsed, on_write)
    on_write()
    error("HTTP 401, error_code=-202, error_message=login expired")
end
local expired = report:_run_pipeline("book", { allow_renewal = false })
assert(expired.error_kind == "authentication" and expired.write_attempted,
    "definitive authentication refusal was quarantined as an unknown write")
assert(renewals == 1 and not expired.renew_attempted)

print("read_report_online_spec: fresh exact delivery, replay isolation and receipts passed")
