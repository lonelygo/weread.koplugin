-- Real KOReader scheduler, subprocess, SQLite and HTTP acceptance for
-- continuous historical replay. The clock is never replaced and product
-- internals are not called to advance the queue.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
load_plugin("weread.koplugin")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path

local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local json = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")
local root = assert(home:match("^(.*)/profile$"))
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

local function wait_for(label, timeout, predicate)
    local deadline = socket.gettime() + timeout
    repeat
        UIManager:handleInput()
        if predicate() then return end
        socket.sleep(0.02)
    until socket.gettime() > deadline
    error("timeout: " .. label)
end

FileManager:showFiles(root .. "/books")
wait_for("file manager plugin", 20, function()
    return FileManager.instance and FileManager.instance.weread
end)
local plugin = FileManager.instance.weread
plugin.offline_sync:pause()
local NetworkMgr = require("ui/network/manager")
NetworkMgr.isConnected = function() return true end

local endpoint = assert(plugin.settings.mock_endpoint)
local function api(path, payload)
    local response = {}
    local body = payload and json.encode(payload)
    local _, code = require("socket.http").request{
        url = endpoint .. path,
        method = body and "POST" or "GET",
        headers = body and {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        } or {},
        source = body and ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    assert(code == 200, path .. " returned " .. tostring(code))
    return json.decode(table.concat(response))
end

local Content = require("weread.lib.content")
local book = plugin.client:get_book_info("900001")
Content.ensure_reader_state(plugin.client, book)
book.chapters = Content.fetch_catalog(plugin.client, book)
assert(Content.save_catalog_cache(
    plugin.client, plugin.settings, book, book.chapters))
plugin.settings:set("books", { ["900001"] = book })
plugin.library_db:putChapters("900001", book.chapters)
local read_report = plugin.settings:get("read_report")
read_report.enabled = true
read_report.mode = "auto"
read_report.interval_seconds = 30
plugin.settings:set("read_report", read_report)
plugin.settings:flush()

local position = {
    book_id = "900001", chapter_uid = 1, chapter_idx = 1,
    chapter_offset = 0, percent = 0, summary = "",
}
local function enqueue_each(durations)
    for _, seconds in ipairs(durations) do
        assert(plugin.library_db:enqueueReadTime(
            "900001", seconds, position, { max_chunk_seconds = 30 }))
    end
end
local function positive_events(after_request_id)
    local events = {}
    for _, event in ipairs(api("/__state").requests) do
        if event.path == "/web/book/read" and (tonumber(event.rt) or 0) > 0
            and (tonumber(event.request_id) or 0) > after_request_id then
            events[#events + 1] = event
        end
    end
    table.sort(events, function(left, right)
        return left.request_id < right.request_id
    end)
    return events
end
local function last_request_id()
    local requests = api("/__state").requests
    local last = 0
    for _, event in ipairs(requests) do
        last = math.max(last, tonumber(event.request_id) or 0)
    end
    return last
end
local function sum(values)
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return total
end
local function assert_serial_pacing(events, label)
    local start_intervals = {}
    local gaps_after_ack = {}
    for index, event in ipairs(events) do
        assert(event.duration_ms >= 200,
            label .. " did not wait for the delayed response")
        assert(event.read_write_concurrency == 1,
            label .. " overlapped reading-time requests")
        if index > 1 then
            local previous = events[index - 1]
            local start_interval = event.started_at - previous.started_at
            local ack_gap = event.started_at - previous.completed_at
            start_intervals[#start_intervals + 1] = start_interval
            gaps_after_ack[#gaps_after_ack + 1] = ack_gap
            assert(start_interval >= 0.85,
                label .. " started faster than one request per second: "
                    .. tostring(start_interval))
            assert(ack_gap >= 0,
                label .. " started before the previous response completed")
            assert(ack_gap < 6,
                label .. " fell back to slow polling after ACK: " .. tostring(ack_gap))
        end
    end
    return start_intervals, gaps_after_ack
end

-- This mirrors a fragmented device queue. Each row is retained independently,
-- including short tails produced by close/suspend/manual-capture boundaries.
local full_scale = os.getenv("WEREAD_REPLAY_SCALE") == "190"
local first_durations
if full_scale then
    first_durations = {}
    for _ = 1, 35 do first_durations[#first_durations + 1] = 30 end
    for _ = 1, 120 do first_durations[#first_durations + 1] = 6 end
    for _ = 1, 35 do first_durations[#first_durations + 1] = 5 end
else
    first_durations = { 30, 5, 30, 7, 30, 2, 30, 11, 30, 3, 30, 17 }
end
local first_seconds = sum(first_durations)
if full_scale then
    assert(#first_durations == 190 and first_seconds == 1945,
        "full-scale fixture does not match the Kindle snapshot")
end
enqueue_each(first_durations)
local first_request_id = last_request_id()
api("/__control", {
    delay = 0.25, match = "/web/book/read",
})
local started_at = socket.gettime()
plugin.offline_sync:resume()
assert(plugin:syncOfflineNow(), "manual sync did not start")
wait_for("continuous fragmented replay", full_scale and 280 or 45, function()
    return plugin.library_db:readTimeStatus().pending == 0
        and plugin.library_db:readTimeReceipts().seconds == first_seconds
end)
local first_elapsed = socket.gettime() - started_at
local first_events = positive_events(first_request_id)
assert(#first_events == #first_durations,
    "fragmented queue did not issue exactly one request per durable row")
for index, event in ipairs(first_events) do
    assert(event.rt == first_durations[index],
        "fragment order or short tail changed at " .. tostring(index))
end
local first_start_intervals, first_ack_gaps = assert_serial_pacing(
    first_events, "continuous replay")
assert(first_elapsed < (full_scale and 250 or 35),
    "fragmented queue still drains at the former 30-second cadence")

-- When the service itself takes longer than the one-second launch interval,
-- the next row waits for that response and then continues without another
-- fixed pacing sleep.
local slow_before = plugin.library_db:readTimeReceipts()
local slow_durations = { 8, 12 }
enqueue_each(slow_durations)
local slow_request_id = last_request_id()
api("/__control", {
    delay = 1.25, match = "/web/book/read", read_replies = { "ok", "ok" },
})
assert(plugin:syncOfflineNow(), "slow-response manual sync did not start")
wait_for("slow ACK replay", 15, function()
    return plugin.library_db:readTimeStatus().pending == 0
        and plugin.library_db:readTimeReceipts().seconds
            == slow_before.seconds + sum(slow_durations)
end)
local slow_events = positive_events(slow_request_id)
assert(#slow_events == #slow_durations,
    "slow responses changed the replay row count")
local slow_start_intervals, slow_ack_gaps = assert_serial_pacing(
    slow_events, "slow ACK replay")
assert(slow_ack_gaps[1] < 3,
    "a slow ACK incurred an additional long replay sleep")

-- A definitive refusal is isolated. The same user action must continue with
-- the following rows without a second tap or direct report_once call.
local receipts_before_reject = plugin.library_db:readTimeReceipts()
local rejected_before = plugin.library_db:readTimeStatus().rejected
local second_durations = { 9, 30, 4 }
enqueue_each(second_durations)
local second_request_id = last_request_id()
api("/__control", {
    delay = 0.25, match = "/web/book/read",
    read_replies = { "reject", "ok", "ok" },
})
assert(plugin:syncOfflineNow(), "second manual sync did not start")
wait_for("rejected row isolation", 20, function()
    local queue = plugin.library_db:readTimeStatus()
    local receipts = plugin.library_db:readTimeReceipts()
    return queue.pending == 0
        and queue.rejected == rejected_before + second_durations[1]
        and receipts.seconds == receipts_before_reject.seconds
            + second_durations[2] + second_durations[3]
end)
local second_events = positive_events(second_request_id)
assert(#second_events == #second_durations,
    "a rejected row starved later replay rows")
for index, event in ipairs(second_events) do
    assert(event.rt == second_durations[index],
        "rejection phase changed row order at " .. tostring(index))
end
local second_start_intervals, second_ack_gaps = assert_serial_pacing(
    second_events, "rejection recovery")

-- A 429 is replayable because the service definitely refused the write. The
-- coordinator must honor Retry-After account-wide, retry the same row once,
-- and then continue without another user action.
local limited_before = plugin.library_db:readTimeReceipts()
local limited_durations = { 10, 13 }
enqueue_each(limited_durations)
local limited_request_id = last_request_id()
api("/__control", {
    delay = 0.25, match = "/web/book/read", retry_after = 2,
    read_replies = { "rate_limited", "ok", "ok" },
})
assert(plugin:syncOfflineNow(), "rate-limited manual sync did not start")
wait_for("Retry-After automatic recovery", 20, function()
    local queue = plugin.library_db:readTimeStatus()
    return queue.pending == 0
        and plugin.library_db:readTimeReceipts().seconds
            == limited_before.seconds + sum(limited_durations)
end)
local limited_events = positive_events(limited_request_id)
assert(#limited_events == 3
        and limited_events[1].status == 429
        and limited_events[1].rt == limited_durations[1]
        and limited_events[2].status == 200
        and limited_events[2].rt == limited_durations[1]
        and limited_events[3].status == 200
        and limited_events[3].rt == limited_durations[2],
    "rate limit did not retry exactly the refused row before continuing")
local limited_start_intervals, limited_ack_gaps = assert_serial_pacing(
    limited_events, "rate-limit recovery")
assert(limited_start_intervals[1] >= 0.9
        and limited_start_intervals[1] < 8,
    "Retry-After was not honored with a bounded automatic recovery")
assert(limited_ack_gaps[1] >= 1.9,
    "Retry-After did not wait two seconds after the 429 response")
local state = api("/__state")
assert(state.max_read_write_concurrency == 1
        and state.active_read_writes == 0,
    "server observed concurrent or unfinished reading-time writes")

local output = assert(io.open(
    root .. "/evidence/replay-pacing-result.json", "wb"))
output:write(json.encode({
    first = {
        durations = first_durations, seconds = first_seconds,
        elapsed_seconds = first_elapsed,
        start_intervals = first_start_intervals,
        gaps_after_ack = first_ack_gaps,
    },
    slow_ack = {
        durations = slow_durations,
        start_intervals = slow_start_intervals,
        gaps_after_ack = slow_ack_gaps,
    },
    rejection = {
        durations = second_durations,
        start_intervals = second_start_intervals,
        gaps_after_ack = second_ack_gaps,
        rejected_seconds = second_durations[1],
        confirmed_after_rejection = second_durations[2] + second_durations[3],
    },
    rate_limit = {
        durations = limited_durations,
        statuses = {
            limited_events[1].status,
            limited_events[2].status,
            limited_events[3].status,
        },
        start_intervals = limited_start_intervals,
        gaps_after_ack = limited_ack_gaps,
    },
    max_read_write_concurrency = state.max_read_write_concurrency,
    receipts = plugin.library_db:readTimeReceipts(),
    queue = plugin.library_db:readTimeStatus(),
}))
output:close()
FileManager.instance:onClose()
UIManager:quit()
print("PASS: historical replay drains continuously after ACK, preserves short rows, isolates rejection, and recovers from Retry-After")
