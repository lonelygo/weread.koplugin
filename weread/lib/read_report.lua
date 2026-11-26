local Content = require("weread.lib.content")
local WeRead = require("weread.lib.protocol")
local PositionMapper = require("weread.lib.position_mapper")
local RemoteProgress = require("weread.lib.remote_progress")

local logger = require("weread.lib.logger").scoped("ReadReport")

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then
    ffiutil = nil
end

local ok_time, monotonic_time = pcall(require, "ui/time")

local function default_active_now()
    if ok_time and monotonic_time and type(monotonic_time.now) == "function" then
        return tonumber(monotonic_time.now()) / 1000000
    end
    return os.clock()
end

local DEFAULT_INTERVAL_SECONDS = 30
local MIN_INTERVAL_SECONDS = 10
local CONTEXT_TTL_SECONDS = 15 * 60
local RENEWAL_COOLDOWN_SECONDS = 10 * 60
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180
local JOB_COLLECT_INTERVAL_SECONDS = 2
-- Pace historical elapsed-time POSTs by their start time. The write lease
-- stays held through the response and the local receipt transaction.
local REPLAY_START_INTERVAL = 1

-- Context fields that the subprocess sends back for the parent to persist.
-- Mirrors the scalar reading-state fields stored by BookStore; the chapter
-- catalog itself stays in the on-disk catalog cache written by the child.
local CONTEXT_FIELDS = {
    "title", "reader_url", "app_id", "psvts", "pclts", "token",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "read_context_updated_at", "read_session_entered_at", "read_session_id",
}

local ReadReport = {}
ReadReport.__index = ReadReport

local WRITE_STARTED_MARKER = "reading-time-write-started\n"

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function remove_file(path)
    if type(path) == "string" and path ~= "" then
        os.remove(path)
    end
end

local function write_started_marker(path)
    local file, open_error = io.open(path, "wb")
    if not file then
        error("could not create reading-time write marker: "
            .. tostring(open_error))
    end
    file:setvbuf("no")
    local written, write_error = file:write(WRITE_STARTED_MARKER)
    local flushed, flush_error = file:flush()
    local closed, close_error = file:close()
    if not written or not flushed or not closed then
        remove_file(path)
        error("could not persist reading-time write marker: "
            .. tostring(write_error or flush_error or close_error))
    end
end

local function write_started(path)
    local file = type(path) == "string" and io.open(path, "rb") or nil
    if not file then return false end
    local value = file:read("*a")
    file:close()
    return value == WRITE_STARTED_MARKER
end

local function make_subprocess_runner()
    if not ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        return nil
    end
    return {
        -- Returns pid, parent_read_fd on success; false, error message on failure.
        run = function(child_func)
            return ffiutil.runInSubProcess(child_func, true)
        end,
        -- Blocking write from inside the child; closes the fd when done.
        write_all = function(fd, data)
            return ffiutil.writeToFD(fd, data, true)
        end,
        -- Non-blocking waitpid; also reaps the child once it has exited.
        is_done = function(pid)
            return ffiutil.isSubProcessDone(pid)
        end,
        terminate = function(pid)
            ffiutil.terminateSubProcess(pid)
        end,
        -- Non-blocking readable-size probe (0 when nothing is buffered).
        read_size = function(fd)
            return ffiutil.getNonBlockingReadSize(fd)
        end,
        -- Reads until EOF and closes the fd.
        read_all = function(fd)
            return ffiutil.readAllFromFD(fd)
        end,
    }
end

local function book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local function response_body(result)
    if type(result) ~= "table" then
        return result
    end
    if result.succ ~= nil or result.synckey ~= nil then
        return result
    end
    if type(result.data) == "table" then
        return result.data
    end
    if type(result.result) == "table" then
        return result.result
    end
    return result
end

local function table_keys(value)
    if type(value) ~= "table" then
        return ""
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

local function rejected(node)
    return RemoteProgress.response_error(node) ~= nil
end

local function response_accepted(result, http_code)
    local body = response_body(result)
    local status = tonumber(http_code)
    if type(body) ~= "table" or (status and (status < 200 or status >= 300)) then
        return false, body
    end
    if rejected(result) or rejected(result.data) or rejected(result.result) then
        return false, body
    end
    local key_type = type(body.synckey)
    return WeRead.is_success_response(body)
        or ((key_type == "string" or key_type == "number") and tostring(body.synckey) ~= ""), body
end

-- A 2xx JSON response that explicitly carries a failed business result is a
-- definitive refusal of this row. Other non-success replies are not receipts:
-- the elapsed-time POST may have reached the service even when its response
-- was lost or replaced, so callers must keep treating those as ambiguous.
local function response_rejected(result, http_code)
    local status = tonumber(http_code)
    local carries_refusal = status and ((status >= 200 and status < 300)
        or status == 400 or status == 422)
    if type(result) ~= "table" or not carries_refusal then return false end
    return rejected(result) or rejected(result.data) or rejected(result.result)
end

local function response_failure_kind(result, http_code)
    local status = tonumber(http_code)
    if status == 401 or status == 403 then return "authentication" end
    if not status or not ((status >= 200 and status < 300)
        or status == 400 or status == 422) then return nil end
    return RemoteProgress.response_error(result)
end

local function request_error_kind(err)
    local text = tostring(err)
    if text:match("HTTP%s+401%f[^%d]") or text:match("HTTP%s+403%f[^%d]") then
        return "authentication"
    end
    return "transport"
end

local function context_error_kind(message)
    local reason = message:match("remote progress unavailable: ([%w_]+)")
    if not reason and message:match("HTTP%s+[%w]+") then
        reason = RemoteProgress.request_reason(message)
    end
    if reason == "authentication_required" then return "authentication" end
    if reason == "service_unreachable" then return "transport" end
    if reason == "service_busy" then return "rate_limited" end
    return "context"
end

local function full_response_body(client, result)
    if type(result) == "table" and client and type(client.json_encode) == "function" then
        local ok, encoded = pcall(function()
            return client:json_encode(result)
        end)
        if ok then
            return encoded
        end
    end
    return tostring(result)
end

local function response_summary(client, result, http_code)
    if type(result) ~= "table" then
        return "non_table_response, http=" .. tostring(http_code)
            .. ", response_body=" .. full_response_body(client, result)
    end
    local body = response_body(result)
    local parts = {
        "http=" .. tostring(http_code),
        "keys=" .. table_keys(result),
        "body_keys=" .. table_keys(body),
        "succ=" .. tostring(type(body) == "table" and body.succ or nil),
        "has_synckey=" .. tostring(type(body) == "table" and body.synckey ~= nil or false),
    }
    local code = type(body) == "table" and (body.errCode or body.errcode or body.code)
        or result.errCode or result.errcode or result.code
    local message = type(body) == "table" and (body.errMsg or body.errmsg or body.message or body.msg)
        or result.errMsg or result.errmsg or result.message or result.msg
    if code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(code)
    end
    if message ~= nil then
        parts[#parts + 1] = "error_message="
            .. tostring(message):gsub("[%c]+", " "):sub(1, 160)
    end
    -- Only rejected reading reports call this function. Keep the complete
    -- decoded response in the failure log so unexpected server replies can be
    -- diagnosed without enabling verbose logging for successful reports.
    parts[#parts + 1] = "response_body=" .. full_response_body(client, result)
    return table.concat(parts, ", ")
end

function ReadReport:new(options)
    options = options or {}
    assert(options.settings, "read report settings are required")
    assert(options.client, "read report client is required")
    assert(options.scheduler, "read report scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        library_db = options.library_db,
        scheduler = options.scheduler,
        get_document = options.get_document,
        detect_book = options.detect_book,
        position_provider = options.position_provider,
        is_online = options.is_online or function() return true end,
        gate = options.gate,
        request_sync = options.request_sync or function() end,
        now = options.now or os.time,
        active_now = options.active_now or options.now or default_active_now,
        session_id = tostring({}) .. ":" .. tostring((options.now or os.time)()),
        subprocess = options.subprocess or make_subprocess_runner(),
        state = "stopped",
        generation = 0,
        count = 0,
        failure_count = 0,
        consecutive_failures = 0,
    }
    if object.library_db
        and type(object.library_db.recoverStaleReadTimeClaims) == "function" then
        object.library_db:recoverStaleReadTimeClaims(
            object.now() - JOB_TIMEOUT_SECONDS - 30)
    end
    return setmetatable(object, self)
end

function ReadReport:_config()
    return self.settings:get("read_report")
end

function ReadReport:_interval()
    local interval = tonumber(self:_config().interval_seconds) or DEFAULT_INTERVAL_SECONDS
    return math.max(MIN_INTERVAL_SECONDS, interval)
end

function ReadReport:status()
    local persisted
    if self.library_db and type(self.library_db.readTimeReceipts) == "function" then
        persisted = self.library_db:readTimeReceipts()
    end
    local confirmed_count = self.count or 0
    local confirmed_seconds = 0
    local confirmed_last = self.last_time
    if persisted then
        confirmed_count = tonumber(persisted.count) or 0
        confirmed_seconds = tonumber(persisted.seconds) or 0
        confirmed_last = tonumber(persisted.last_time)
    end
    return {
        running = self.task ~= nil,
        state = self.state,
        count = confirmed_count,
        confirmed_seconds = confirmed_seconds,
        failure_count = self.failure_count or 0,
        consecutive_failures = self.consecutive_failures or 0,
        last_time = confirmed_last,
        last_error = self.last_error,
        last_error_kind = self.last_error_kind,
        stop_reason = self.stop_reason,
        target_book_id = self.current_book_id,
        target_book_title = self.current_book_title,
        target_source = self.current_book_source,
        network_busy = self.network_lease ~= nil,
        read_time_inflight = self.job ~= nil or self.network_lease ~= nil,
    }
end

function ReadReport:_request_sync(reason, context)
    local ok, err = pcall(self.request_sync, reason, context or {})
    if not ok then log("warn", "read report sync request failed:", tostring(err)) end
end

local function release_network_lease(lease, outcome)
    if type(lease) == "function" then
        pcall(lease, outcome)
    elseif type(lease) == "table" and type(lease.release) == "function" then
        pcall(lease.release, lease, outcome)
    end
end

function ReadReport:_acquire_network_gate(operation, book_id, details)
    if self.network_lease ~= nil then return false, "read_report_busy" end
    local context = {
        source = "read_report",
        operation = operation,
        book_id = tostring(book_id or ""),
    }
    for key, value in pairs(details or {}) do context[key] = value end
    local allowed, lease_or_reason
    if type(self.gate) == "function" then
        local ok, first, second = pcall(self.gate, "weread_read_write", context)
        if not ok then
            local denial = "gate_error:" .. tostring(first)
            if self.last_gate_denial ~= denial then
                self.last_gate_denial = denial
                self:_request_sync("gate_error", context)
            end
            return false, tostring(first)
        end
        allowed, lease_or_reason = first == true, second
    else
        allowed = self.is_online() == true
        lease_or_reason = allowed and true or "offline"
    end
    if not allowed then
        local reason = lease_or_reason or "gate_denied"
        local denial = operation .. ":" .. tostring(book_id or "")
            .. ":" .. tostring(reason)
        if self.last_gate_denial ~= denial then
            self.last_gate_denial = denial
            self:_request_sync(reason, context)
        end
        return false, reason
    end
    self.last_gate_denial = nil
    -- Re-enter the web reader if login changes between two slices.
    local auth = self:_auth_fingerprint()
    if self.session_auth and self.session_auth ~= auth then
        self.session_id = tostring({}) .. ":" .. tostring(self.active_now())
    end
    self.session_auth = auth
    self.network_lease = lease_or_reason or true
    return true, self.network_lease
end

function ReadReport:_release_network_gate(lease, outcome)
    if lease == nil then return end
    if self.network_lease == lease then self.network_lease = nil end
    release_network_lease(lease, outcome)
end

function ReadReport:resolve_target()
    local config = self:_config()
    local has_document = self.get_document() ~= nil
    if config.mode == "manual"
        and tostring(config.book_id or "") ~= ""
        and (has_document or config.report_on_open == false) then
        return tostring(config.book_id),
            tostring(config.book_title or "") ~= "" and config.book_title or tostring(config.book_id),
            "manual"
    end

    local detected_id = has_document and self.detect_book()
    if detected_id then
        detected_id = tostring(detected_id)
        -- Avoid reloading every book record from disk on each tick just for
        -- the title; reuse the cached one while the target stays the same.
        if detected_id == self.current_book_id
            and tostring(self.current_book_title or "") ~= "" then
            return detected_id, self.current_book_title, "current_document"
        end
        local book = book_record(self.settings:get("books", {}), detected_id)
        return detected_id,
            type(book) == "table" and book.title or detected_id,
            "current_document"
    end
    local queued = self.library_db and self.library_db.nextReadTime and self.library_db:nextReadTime()
    if queued then
        local book = book_record(self.settings:get("books", {}), queued.book_id)
        return tostring(queued.book_id),
            type(book) == "table" and book.title or tostring(queued.book_id), "offline_queue"
    end
    return nil, nil, has_document and "document_not_weread" or "no_document"
end

function ReadReport:_set_error(err, kind, prefix)
    local message = tostring(err)
    self.last_error = message
    self.last_error_kind = kind or "error"
    self.failure_count = (self.failure_count or 0) + 1
    self.consecutive_failures = (self.consecutive_failures or 0) + 1
    self.state = "error"
    if self.logged_error ~= message then
        log("warn", prefix or "read report error:", message)
        self.logged_error = message
    end
end

function ReadReport:_record_success(result)
    local recovered = self.last_error ~= nil
    self.count = (self.count or 0) + 1
    self.last_time = self.now()
    self.last_error = nil
    self.last_error_kind = nil
    self.logged_error = nil
    self.last_skip = nil
    self.consecutive_failures = 0
    self.state = "active"
    if recovered or self.count == 1 or self.count % 20 == 0 then
        log("info", "read report success:",
            "count=", self.count,
            "has_synckey=", type(result) == "table" and result.synckey ~= nil or false)
    end
end

function ReadReport:_log_skip(reason)
    if self.last_skip ~= reason then
        log("info", "read report skipped:", reason)
        self.last_skip = reason
    end
end

function ReadReport:maybe_start(reason)
    local config = self:_config()
    if not config.enabled then
        self:_log_skip("disabled")
        return false, nil, "disabled"
    end
    if self.suspended then
        self.state = "suspended"
        self:_log_skip("suspended")
        return false, nil, "suspended"
    end
    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        self:_log_skip(source)
        return false, nil, source
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    if self.task then
        return true, title, source
    end
    return self:start(reason), title, source
end

function ReadReport:start(reason)
    if self.task then
        return true
    end
    local book_id, title, source = self:resolve_target()
    if not self:_config().enabled or self.suspended or not book_id then
        return false
    end

    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    self.state = "waiting"
    self.stop_reason = nil
    self.last_skip = nil
    if self.get_document() ~= nil then
        self.last_accounted_at = self.active_now()
    end

    local task
    task = function()
        if self.generation ~= generation or self.task ~= task then
            return
        end
        self:_tick(generation, task)
    end
    self.task = task
    self.scheduler:scheduleIn(self:_interval(), task)
    log("info", "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source)
    return true
end

function ReadReport:stop(reason)
    reason = reason or "unspecified"
    self.manual_replay_tick = nil
    self.live_tick_due = nil
    local had_task = self.task ~= nil
    self.generation = self.generation + 1
    if self.task then
        self.scheduler:unschedule(self.task)
        self.task = nil
    end
    if self.replay_task then
        self.scheduler:unschedule(self.replay_task)
        self.replay_task = nil
    end
    if self.job then
        self:_abandon_job(self.job)
    end
    self.state = reason == "suspend" and "suspended"
        or "stopped"
    self.stop_reason = reason
    self.last_accounted_at = nil
    if had_task then
        log("info", "reading time report stopped:",
            "reason=", reason,
            "success_count=", self.count or 0,
            "failure_count=", self.failure_count or 0)
    end
end

-- Apply an interval change to a running session without interrupting it.
-- An in-flight job is left alone: the poller reschedules once it finishes, so
-- its result (including any renewed credentials) is still written back.
-- Otherwise only the pending tick is re-armed, right away, with the new
-- interval.
function ReadReport:reschedule(reason)
    if not self.task or self.job then
        return false
    end
    self.scheduler:unschedule(self.task)
    self.scheduler:scheduleIn(self:_interval(), self.task)
    log("info", "reading time report rescheduled:",
        "reason=", reason or "unspecified",
        "interval=", self:_interval())
    return true
end

function ReadReport:on_reader_ready()
    self.suspended = false
    return self:maybe_start("reader_ready")
end

function ReadReport:on_suspend()
    self:_capture_active_time()
    self.suspended = true
    self:stop("suspend")
end

function ReadReport:on_resume()
    self.suspended = false
    self.last_accounted_at = self.get_document() and self.active_now() or nil
    return self:maybe_start("resume")
end

function ReadReport:on_close_document()
    self:_capture_active_time()
    local config = self:_config()
    if config.report_on_open ~= false or config.mode == "auto" then
        self:stop("document_closed")
        self.current_book_id = nil
        self.current_book_title = nil
        self.current_book_source = nil
        if self.library_db
            and type(self.library_db.nextReadTime) == "function"
            and self.library_db:nextReadTime() then
            self:maybe_start("offline_queue")
        end
        return
    end
    self:maybe_start("document_closed_background")
end

function ReadReport:_capture_active_time(position)
    if self.suspended or self.current_book_source == "offline_queue"
        or self.get_document() == nil or not self.last_accounted_at then
        return 0
    end
    local now = self.active_now()
    local elapsed = math.max(0, math.floor(now - self.last_accounted_at))
    if elapsed <= 0 then return 0 end
    if not position and type(self.position_provider) == "function"
        and self.current_book_id then
        position = self.position_provider(self.current_book_id)
    end
    local first_id
    if self.library_db and type(self.library_db.enqueueReadTime) == "function"
        and self.current_book_id then
        local queued
        local enqueue_options
        if self.is_online() then
            enqueue_options = {
                max_chunk_seconds = math.min(60, self:_interval()),
            }
        end
        queued, first_id = self.library_db:enqueueReadTime(
            self.current_book_id, elapsed, position, enqueue_options)
        if not queued then
            return 0
        end
        self:_request_sync("read_time_captured", {
            source = "read_report",
            book_id = tostring(self.current_book_id),
            elapsed_seconds = elapsed,
        })
    end
    self.last_accounted_at = self.last_accounted_at + elapsed
    return elapsed, first_id
end

function ReadReport:capture_for_manual()
    if self.task then self:_capture_active_time() end
end

-- ------------------------------------------------------------------
-- Scheduled tick: cheap parent-side checks, then hand the network
-- pipeline to a subprocess (or run it inline as a fallback).
-- ------------------------------------------------------------------

function ReadReport:_schedule_next(generation, task, delay)
    if self.generation == generation and self.task == task then
        self.scheduler:scheduleIn(delay or self:_interval(), task)
    end
end

function ReadReport:_schedule_replay(generation, delay)
    if self.generation ~= generation or not self.task
        or not self.library_db
        or (type(self.library_db.hasPendingOfflineWork) == "function"
            and not self.library_db:hasPendingOfflineWork(true, false)) then
        return false
    end
    if self.replay_task then return true end
    delay = math.max(delay or 0, (self.next_replay_at or 0) - self.active_now())
    local replay_task
    replay_task = function()
        if self.replay_task ~= replay_task then return end
        self.replay_task = nil
        if self.generation ~= generation or not self.task then return end
        if self.job or self.network_lease ~= nil or self.live_tick_due then
            self:_schedule_replay(generation, JOB_POLL_INITIAL_SECONDS)
            return
        end
        -- A device scheduler may fire just before its monotonic deadline.
        -- Keep the queue armed instead of falling back to the next live tick.
        if self.active_now() < (self.next_replay_at or 0) then
            self:_schedule_replay(generation, 0.01)
            return
        end
        local proceed, book_id, position, queued, lease = self:_precheck(true)
        if not proceed then return end
        queued._background_replay = true
        local spawned = self:_start_job(
            book_id, self:_renewal_allowed(), generation, self.task,
            position, queued.elapsed_seconds, queued, lease)
        if spawned then return end
        local ok, outcome = pcall(function()
            return self:_run_pipeline(book_id, {
                allow_renewal = self:_renewal_allowed(),
                position = nil,
                elapsed_seconds = queued.elapsed_seconds,
                force_context = true,
            })
        end)
        if not ok then
            outcome = { accepted = false, error = tostring(outcome),
                error_kind = "task", write_attempted = false }
        end
        self:_apply_queued_outcome(queued, outcome)
    end
    self.replay_task = replay_task
    self.scheduler:scheduleIn(delay, replay_task)
    return true
end

function ReadReport:_tick(generation, task)
    local claimed
    local ok, err = pcall(function()
        if self.job then
            -- A bounded replay can overlap the nominal live deadline. Retry
            -- the live tick promptly; its monotonic clock preserves all time.
            self.live_tick_due = self.current_book_source ~= "offline_queue"
            self:_schedule_next(generation, task, JOB_POLL_INITIAL_SECONDS)
            return
        end
        self.live_tick_due = nil
        local proceed, book_id, position, queued, lease = self:_precheck()
        if not proceed then
            self:_schedule_next(generation, task)
            return
        end
        claimed = queued
        local allow_renewal = self:_renewal_allowed()
        local spawned, spawn_err = self:_start_job(
            book_id, allow_renewal, generation, task,
            position,
            queued and queued.elapsed_seconds or nil, queued, lease)
        if spawned then
            return
        end
        if not self.logged_inline_fallback then
            log("warn", "read report subprocess unavailable, reporting inline:",
                tostring(spawn_err))
            self.logged_inline_fallback = true
        end
        local outcome = self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = queued and queued.elapsed_seconds or nil,
            force_context = queued ~= nil and (not queued._fresh_online
                or queued._force_context == true),
        })
        self:_apply_queued_outcome(queued, outcome)
        claimed = nil
        if not queued then self:_release_network_gate(lease, outcome) end
        self:_schedule_next(generation, task)
        if queued and queued._fresh_online then self:_schedule_replay(generation) end
    end)
    if not ok then
        if claimed and self.library_db
            and type(self.library_db.quarantineReadTime) == "function" then
            self.library_db:quarantineReadTime(claimed, tostring(err))
            claimed._network_lease = nil
            self.next_replay_at = self.active_now() + REPLAY_START_INTERVAL
        end
        if self.network_lease ~= nil and not self.job then
            self:_release_network_gate(self.network_lease, {
                accepted = false, error_kind = "task", error = tostring(err),
            })
        end
        self:_set_error(err, "task", "read report task failed:")
        self:_schedule_next(generation, task)
    end
end

-- Parent-side gate before any network work. Returns true, book_id when a
-- report should be attempted. Must stay cheap: it runs on the UI loop.
function ReadReport:_precheck(replay_only)
    replay_only = replay_only == true or self.manual_replay_tick == true
    self.manual_replay_tick = nil
    local config = self:_config()
    if not config.enabled then
        self:stop("disabled")
        return false
    end
    if self.suspended then
        self:stop("suspend")
        return false
    end

    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        return false
    end
    if self.current_book_id and self.current_book_id ~= book_id
        and not (source == "offline_queue" and self.current_book_source == source) then
        self:stop("document_changed")
        self:maybe_start("document_changed")
        return false
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source

    if not self.settings:is_cookie_configured() then
        self:_set_error("cookie not configured", "authentication", "read report skipped:")
        return false
    end
    local position
    local position_reason
    local position_applies
    if not replay_only and type(self.position_provider) == "function" then
        position, position_reason, position_applies = self.position_provider(book_id)
    end
    -- Replaying old rows must not capture new time on every ACK. The live
    -- tick, suspend and close continue to account for foreground reading.
    local elapsed, fresh_id = 0, nil
    if not replay_only or not self.is_online() then
        elapsed, fresh_id = self:_capture_active_time(position)
    end
    if self.library_db and type(self.library_db.claimReadTime) == "function" then
        if type(self.library_db.recoverStaleReadTimeClaims) == "function" then
            self.library_db:recoverStaleReadTimeClaims(
                self.now() - JOB_TIMEOUT_SECONDS - 30)
        end
        local fresh_online = fresh_id ~= nil and not replay_only
        if not fresh_online then
            local has_pending = type(self.library_db.hasPendingOfflineWork) ~= "function"
                or self.library_db:hasPendingOfflineWork(true, false)
            if not has_pending then
                self.state = "waiting"
                return false
            end
            if self.active_now() < (self.next_replay_at or 0) then
                self.state = "waiting"
                return false
            end
        end
        local pending_book_id = fresh_online and book_id
            or (type(self.library_db.pendingOfflineBook) == "function"
                and self.library_db:pendingOfflineBook(true, false) or book_id)
        local allowed, lease_or_reason = self:_acquire_network_gate(
            fresh_online and "live_reading_time" or "reading_time",
            pending_book_id,
            fresh_online and {
                position = position,
                position_verified = position ~= nil,
                position_reason = position_reason,
                position_applies = position_applies == true,
            } or nil)
        if not allowed then
            self.state = lease_or_reason == "offline" and "offline" or "waiting"
            self:_log_skip(lease_or_reason)
            return false
        end
        local queued = self.library_db:claimReadTime(
            self.session_id, fresh_online and fresh_id or nil)
        if queued then
            if (fresh_online and fresh_id
                    and tonumber(queued.id) ~= tonumber(fresh_id))
                or (pending_book_id
                    and tostring(queued.book_id) ~= tostring(pending_book_id)) then
                if type(self.library_db.releaseReadTimeClaim) == "function" then
                    self.library_db:releaseReadTimeClaim(queued)
                end
                self:_release_network_gate(lease_or_reason, {
                    accepted = false, write_attempted = false,
                    error_kind = "queue_changed",
                })
                self:_request_sync("queue_changed", {
                    source = "read_report", book_id = tostring(queued.book_id),
                })
                return false
            end
            queued._network_lease = lease_or_reason
            queued._fresh_online = fresh_online
            queued._force_context = fresh_online and position == nil or nil
            queued._background_replay = replay_only or nil
            return true, queued.book_id,
                fresh_online and position or nil, queued, lease_or_reason
        end
        self:_release_network_gate(lease_or_reason, {
            accepted = false, write_attempted = false,
            error_kind = "empty_queue",
        })
        self.state = "waiting"
        return false
    end
    if position_applies and not position then
            self.state = "waiting_for_progress"
            self:_log_skip(position_reason or "progress_unverified")
            return false
    end
    local allowed, lease_or_reason = self:_acquire_network_gate(
        "reading_time", book_id)
    if not allowed then
        self.state = lease_or_reason == "offline" and "offline" or "waiting"
        return false
    end
    local queued = elapsed > 0 and {
        elapsed_seconds = elapsed, _network_lease = lease_or_reason,
    } or nil
    return true, book_id, position, queued, lease_or_reason
end

function ReadReport:_renewal_allowed()
    return self.now() - (self.last_renew_attempt or 0) >= RENEWAL_COOLDOWN_SECONDS
end

function ReadReport:_auth_fingerprint()
    local cookies = self.settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _i, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(self.settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(self.settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

function ReadReport:_context_fingerprint(book_id)
    local book = book_record(self.settings:get("books", {}), book_id) or {}
    local parts = {}
    for _i, field in ipairs(CONTEXT_FIELDS) do
        parts[#parts + 1] = field .. "=" .. tostring(book[field])
    end
    return table.concat(parts, ";")
end

-- ------------------------------------------------------------------
-- Subprocess job management (parent side)
-- ------------------------------------------------------------------

function ReadReport:_start_job(book_id, allow_renewal, generation, task, position,
        elapsed_seconds, queued, gate_lease)
    local runner = self.subprocess
    if not runner then
        return false, "no subprocess support"
    end
    local write_marker = os.tmpname()
    remove_file(write_marker)
    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local outcome = self:_child_report(
            book_id, allow_renewal, position, elapsed_seconds,
            queued ~= nil and (not queued._fresh_online
                or queued._force_context == true),
            function() write_started_marker(write_marker) end)
        local ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not ok or type(encoded) ~= "string" then
            encoded = '{"accepted":false,"error":"failed to serialize report outcome",'
                .. '"error_kind":"job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then
        remove_file(write_marker)
        return false, tostring(read_fd)
    end

    local job = {
        pid = pid,
        read_fd = read_fd,
        book_id = book_id,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        auth_fingerprint = self:_auth_fingerprint(),
        context_fingerprint = self:_context_fingerprint(book_id),
        queued = queued,
        gate_lease = gate_lease,
        write_marker = write_marker,
    }
    job.poll = function()
        self:_poll_job(job, generation, task)
    end
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ReadReport:_poll_job(job, generation, task)
    if self.job ~= job then
        return
    end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.job = nil
        if not done then
            -- Output was read while the child was still exiting; reap it in
            -- the background so it does not linger as a zombie.
            self:_collect_pid(job.pid)
        end
        self:_apply_job_outcome(job, self:_decode_outcome(payload))
        remove_file(job.write_marker)
        if not job.queued then
            self:_release_network_gate(job.gate_lease, job.outcome)
        end
        if not (job.queued and job.queued._background_replay) then
            self:_schedule_next(generation, task)
        end
        if job.queued and job.queued._fresh_online then
            self:_schedule_replay(generation)
        end
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        log("warn", "read report job timed out, terminating:", "pid=", job.pid)
        self:_abandon_job(job)
        self:_set_error("report job timed out", "transport", "read report job failed:")
        if not (job.queued and job.queued._background_replay) then
            self:_schedule_next(generation, task)
        end
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

-- Kill a running job and keep reaping until the child is collected, so a
-- stopped or timed-out report can never leave a zombie behind.
function ReadReport:_abandon_job(job)
    job = job or self.job
    if not job then
        return
    end
    if self.job == job then
        self.job = nil
    end
    local runner = self.subprocess
    if job.poll then
        self.scheduler:unschedule(job.poll)
    end
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd) or 0
    if done or readable > 0 then
        local payload = job.read_fd and runner.read_all(job.read_fd) or nil
        job.read_fd = nil
        self:_apply_job_outcome(job, self:_decode_outcome(payload))
        remove_file(job.write_marker)
        if not job.queued then
            self:_release_network_gate(job.gate_lease, job.outcome)
        end
        if not done then self:_collect_pid(job.pid) end
        return true
    end
    runner.terminate(job.pid)
    local function finalize()
        local attempted = write_started(job.write_marker)
        remove_file(job.write_marker)
        if job.queued and not job.queued_finalized and self.library_db then
            if attempted
                and type(self.library_db.quarantineReadTime) == "function" then
                self.library_db:quarantineReadTime(
                    job.queued, "report_abandoned")
                self.next_replay_at = self.active_now() + REPLAY_START_INTERVAL
            elseif not attempted
                and type(self.library_db.releaseReadTimeClaim) == "function" then
                self.library_db:releaseReadTimeClaim(job.queued)
            end
            job.queued_finalized = true
        end
        self:_release_network_gate(job.gate_lease, {
            accepted = false, write_attempted = attempted,
            error_kind = attempted and "transport" or "context",
            error = "report_abandoned",
        })
        job.gate_lease = nil
    end
    local collect
    collect = function()
        if runner.is_done(job.pid) then
            if job.read_fd then
                runner.read_all(job.read_fd)
                job.read_fd = nil
            end
            finalize()
            return
        end
        if job.read_fd and (runner.read_size(job.read_fd) or 0) ~= 0 then
            -- Drain the pipe so a child blocked on write() can exit.
            runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
    end
    collect()
end

function ReadReport:_collect_pid(pid)
    local runner = self.subprocess
    local collect
    collect = function()
        if not runner.is_done(pid) then
            self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ReadReport:_decode_outcome(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- ------------------------------------------------------------------
-- Outcome application (parent side)
-- ------------------------------------------------------------------

function ReadReport:_apply_job_outcome(job, outcome)
    local book_id = job.book_id
    if type(outcome) == "table" then
        if type(outcome.auth) == "table" then
            if self:_auth_fingerprint() ~= job.auth_fingerprint then
                log("info", "skip renewed auth write-back: parent auth changed during job")
            else
                local ok, err = pcall(function()
                    self.settings:update_auth({
                        cookies = outcome.auth.cookies,
                        wr_ticket = outcome.auth.wr_ticket,
                        wr_wrpa = outcome.auth.wr_wrpa,
                    }, { replace_cookies = true })
                end)
                if not ok then
                    outcome.auth_renewed = false
                    log("warn", "persist renewed auth failed:", tostring(err))
                end
            end
        end
        if type(outcome.book) == "table" then
            if self:_context_fingerprint(book_id) ~= job.context_fingerprint then
                log("info", "skip report context write-back: parent record changed during job")
            else
                local ok, err = pcall(function()
                    self:_persist_context(book_id, outcome.book)
                end)
                if not ok then
                    log("warn", "persist report context failed:", tostring(err))
                end
            end
        end
    end
    local accepted = self:_apply_queued_outcome(job.queued, outcome)
    job.outcome = outcome
    job.queued_finalized = true
    return accepted
end

function ReadReport:_apply_queued_outcome(queued, outcome)
    local accepted = self:_apply_outcome(outcome)
    local settled
    if queued and not queued._fresh_online and type(outcome) == "table"
        and (accepted or outcome.write_attempted) then
        self.next_replay_at = (outcome.write_started_at or self.active_now()) + REPLAY_START_INTERVAL
    end
    if queued and self.library_db then
        if accepted and type(self.library_db.ackReadTime) == "function" then
            settled = self.library_db:ackReadTime(queued)
            if settled then
                require("weread.lib.sync_status").noteAck(self, self.now())
            end
        elseif type(outcome) == "table"
            and outcome.error_kind == "rejected"
            and type(self.library_db.rejectReadTime) == "function" then
            settled = self.library_db:rejectReadTime(queued, outcome.error)
        elseif (type(outcome) ~= "table"
                or outcome.error_kind == "transport"
                or outcome.error_kind == "unknown"
                or outcome.error_kind == "job"
                or outcome.error_kind == "task")
            and not (type(outcome) == "table"
                and outcome.write_attempted == false)
            and type(self.library_db.quarantineReadTime) == "function" then
            settled = self.library_db:quarantineReadTime(
                queued,
                type(outcome) == "table" and outcome.error or "missing_result")
        elseif type(self.library_db.releaseReadTimeClaim) == "function" then
            local kind = type(outcome) == "table" and outcome.error_kind
            local retry_delay = kind == "rate_limited" and (outcome.retry_after or 60)
                or kind == "context" and 60 or nil
            self.library_db:releaseReadTimeClaim(queued, retry_delay)
            if kind == "context" and outcome.write_attempted == false
                and not queued._fresh_online and self.library_db.deferPendingReadTimeForBook then
                self.library_db:deferPendingReadTimeForBook(queued.book_id, retry_delay)
            end
        end
    end
    local lease = queued and queued._network_lease or nil
    if lease ~= nil then
        queued._network_lease = nil
        self:_release_network_gate(lease, outcome)
    end
    if settled and not queued._fresh_online then
        self:_schedule_replay(self.generation)
    end
    return accepted
end

function ReadReport:_apply_outcome(outcome)
    if type(outcome) ~= "table" then
        self:_set_error("report job returned no result", "job", "read report job failed:")
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if outcome.accepted then
        self:_record_success({ synckey = outcome.has_synckey and true or nil })
        return true
    end
    self:_set_error(outcome.error or "unknown report failure",
        outcome.error_kind or "error",
        outcome.error_prefix)
    return false
end

function ReadReport:_context_snapshot(book)
    local snapshot = { book_id = book.book_id }
    for _i, field in ipairs(CONTEXT_FIELDS) do
        snapshot[field] = book[field]
    end
    return snapshot
end

function ReadReport:_persist_context(book_id, snapshot)
    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or { book_id = book_id }
    local changed = false
    -- Replace semantics, not merge: a refreshed context may legitimately
    -- clear session fields (notably pclts), and the old wholesale record
    -- overwrite dropped them too. JSON strips nils from the outcome, so a
    -- missing snapshot field means "cleared".
    for _i, field in ipairs(CONTEXT_FIELDS) do
        local value = snapshot[field]
        if book[field] ~= value then
            book[field] = value
            changed = true
        end
    end
    if not changed then
        return
    end
    book.book_id = book.book_id or book_id
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
end

-- ------------------------------------------------------------------
-- Report pipeline (runs in the subprocess, or inline as fallback)
-- ------------------------------------------------------------------

-- Child entry point. Neuters settings persistence inside the fork and
-- captures auth changes (Set-Cookie merges, cookie renewal) so the parent
-- can persist them from the outcome.
function ReadReport:_child_report(book_id, allow_renewal, position, elapsed_seconds,
        force_context, on_write)
    self._no_persist = true
    self.settings.flush = function() end
    local auth_changed = false
    local original_update_auth = self.settings.update_auth
    self.settings.update_auth = function(settings_obj, credentials, options)
        auth_changed = true
        options = options or {}
        options.flush = false
        return original_update_auth(settings_obj, credentials, options)
    end

    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = elapsed_seconds,
            force_context = force_context == true,
            on_write = on_write,
        })
    end)
    if not ok then
        outcome = {
            accepted = false,
            error = tostring(outcome),
            error_kind = "task",
            error_prefix = "read report task failed:",
        }
    end
    if auth_changed then
        outcome.auth = {
            cookies = self.settings:get("cookies", {}),
            wr_ticket = self.settings:get("wr_ticket", ""),
            wr_wrpa = self.settings:get("wr_wrpa", ""),
        }
    end
    return outcome
end

-- Full report attempt. Context is prepared before the elapsed-time POST. Once
-- that mutation starts, its single response is the only receipt we classify:
-- refreshing or retrying after an unclear reply could double-count time.
-- Pure with respect to the parent state machine: everything the caller needs
-- is described by the returned outcome table.
function ReadReport:_run_pipeline(book_id, opts)
    opts = opts or {}
    local outcome = {
        accepted = false, renew_attempted = false, write_attempted = false,
    }
    local function renew_if_allowed()
        if outcome.error_kind ~= "authentication" or not opts.allow_renewal then
            return
        end
        outcome.renew_attempted = true
        local renewed, result_body = pcall(
            self.client.renew_cookie, self.client)
        outcome.auth_renewed = renewed
            and WeRead.is_success_response(result_body) or false
    end

    local function send(book)
        return self:_send(
            book_id, book, opts.position, opts.elapsed_seconds,
            function()
                if type(opts.on_write) == "function" then opts.on_write() end
                outcome.write_attempted = true
                outcome.write_started_at = self.active_now()
            end)
    end

    if type(opts.position) == "table"
        and opts.position.book_id ~= nil
        and tostring(opts.position.book_id) ~= tostring(book_id) then
        outcome.error = "explicit position belongs to another book"
        outcome.error_kind = "context"
        outcome.error_prefix = "read report context initialization failed:"
        return outcome
    end

    local context_ok, book = pcall(function()
        return self:ensure_context(book_id, opts.force_context == true)
    end)
    if not context_ok then
        outcome.error = tostring(book)
        outcome.error_kind = context_error_kind(outcome.error)
        outcome.error_prefix = "read report context initialization failed:"
        renew_if_allowed()
        return outcome
    end
    local ok, result, http_code, _, retry_after = pcall(function()
        return send(book)
    end)
    outcome.book = self:_context_snapshot(book)
    local accepted, accepted_body = response_accepted(result, http_code)
    if ok and accepted then
        outcome.accepted = true
        outcome.has_synckey = type(accepted_body) == "table"
            and accepted_body.synckey ~= nil or false
        return outcome
    end
    if not ok then
        outcome.error = tostring(result)
        outcome.error_kind = request_error_kind(result)
        outcome.error_prefix = "read report request failed:"
    else
        local status = tonumber(http_code)
        outcome.error = response_summary(self.client, result, http_code)
        local business_failure = response_failure_kind(result, http_code)
        if status == 429 then
            outcome.error_kind = "rate_limited"
            outcome.error_prefix = "read report rate limited:"
            outcome.retry_after = retry_after
        elseif business_failure == "authentication" then
            outcome.error_kind = "authentication"
            outcome.error_prefix = "read report authentication failed:"
        elseif business_failure or response_rejected(result, http_code) then
            outcome.error_kind = outcome.write_attempted and "rejected" or "context"
            outcome.error_prefix = "read report server rejected:"
        else
            outcome.error_kind = "unknown"
            outcome.error_prefix = "read report returned no definitive receipt:"
        end
    end
    -- Renew only after a definite denial. The durable row is retried by a
    -- future delivery after the parent has received the new cookies.
    renew_if_allowed()
    return outcome
end

-- Inline (blocking) report used when subprocess support is unavailable.
function ReadReport:report_once()
    local proceed, book_id, position, queued, lease = self:_precheck()
    if not proceed then
        return false
    end
    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, {
            allow_renewal = self:_renewal_allowed(),
            position = position,
            elapsed_seconds = queued and queued.elapsed_seconds or nil,
            force_context = queued ~= nil and (not queued._fresh_online
                or queued._force_context == true),
        })
    end)
    if not ok then
        outcome = {
            accepted = false, error = tostring(outcome),
            error_kind = "task", error_prefix = "read report task failed:",
        }
    end
    local accepted = self:_apply_queued_outcome(queued, outcome)
    if not queued then self:_release_network_gate(lease, outcome) end
    return accepted
end

function ReadReport:on_network_connected()
    if self.library_db
        and type(self.library_db.hasPendingOfflineWork) == "function"
        and not self.library_db:hasPendingOfflineWork(true, false) then
        return false
    end
    if not self.task then
        if not self:maybe_start("network_connected") then return false end
    end
    return self:_schedule_replay(self.generation)
end

function ReadReport:drain(manual)
    return self:on_network_connected()
end

-- ------------------------------------------------------------------
-- Report context
-- ------------------------------------------------------------------

function ReadReport:_merge_remote_progress(book_id, book)
    local remote, remote_error = RemoteProgress.fetch(
        self.client, self.settings, book_id, book.chapters, {
            require_web = true,
        })
    if not remote then return nil, remote_error end
    if remote.chapter_uid == nil then
        return nil, "remote_chapter_unavailable"
    end
    if not remote.has_chapter_offset then
        return nil, "remote_offset_unavailable"
    end
    book.progress = remote.raw_percent
    book.chapter_uid = remote.chapter_uid
    book.chapter_idx = remote.chapter_idx
    book.chapter_offset = remote.chapter_offset
    book.summary = remote.summary or ""
    return remote
end

-- Build (and refresh when stale) the reader context on the given book
-- record. Performs network I/O; never persists settings.
function ReadReport:_build_context(book_id, force, book)
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = WeRead.reader_url(book_id)
    local updated = tonumber(book.read_context_updated_at)
    local age = updated and (self.now() - updated)
    local same_session = age and age >= 0 and age < CONTEXT_TTL_SECONDS
        and book.read_session_id == self.session_id and book.chapter_uid ~= nil
        and tostring(book.psvts or "") ~= ""

    -- BookStore never persists the chapter list, so a freshly loaded record
    -- has no chapters. Restore them from the on-disk catalog cache first;
    -- otherwise the TTL check below can never pass and every report would
    -- refetch the whole reader page.
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.load_catalog_cache(
            self.client, self.settings, book)
        if type(chapters) == "table" and #chapters > 0 then
            if self.library_db and not (same_session and book.read_session_entered_at) then
                self.library_db:putChapters(book_id, chapters)
            end
        else
            chapters = self.library_db
                and self.library_db:getChapters(book_id) or nil
            if type(chapters) == "table" and #chapters > 0 then
                book.chapters = chapters
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, chapters)
                if not cache_ok then
                    log("warn", "save chapter catalog cache failed:",
                        tostring(cache_err))
                end
            end
        end
    end

    if same_session and type(book.chapters) == "table" and #book.chapters > 0 then
        if not force then return book end
    else
        local catalog_version = tonumber(book.book_version or book.bookVersion or book.version)
        Content.ensure_reader_state(self.client, book)
        local reader_version = tonumber(book.book_version or book.bookVersion or book.version)
        if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
            book.pclts = WeRead.e(self.now())
        end
        book.read_session_entered_at = nil
        book.read_session_id = self.session_id
        book.read_context_updated_at = self.now()
        if (catalog_version and reader_version and catalog_version ~= reader_version)
            or type(book.chapters) ~= "table" or #book.chapters == 0 then
            local chapters = Content.fetch_catalog(self.client, book)
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, chapters)
            if not cache_ok then log("warn", "save chapter catalog cache failed:", tostring(cache_err)) end
            if self.library_db then self.library_db:putChapters(book_id, chapters) end
        end
    end
    -- Other devices can advance the book between any two receipts.
    -- The reader session is reusable, the position on a time POST is not.
    local remote
    local remote_error
    if force then
        remote, remote_error = self:_merge_remote_progress(book_id, book)
        if not remote then
            error("remote progress unavailable: " .. tostring(remote_error))
        end
    end

    local selected
    for _i, chapter in ipairs(book.chapters or {}) do
        if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid or "") then
            selected = chapter
            break
        end
    end
    if force and not selected then
        local chapters = Content.fetch_catalog(self.client, book)
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            log("warn", "save refreshed chapter catalog failed:",
                tostring(cache_err))
        end
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
        remote, remote_error = PositionMapper.normalize_remote(
            remote.raw_node, book_id, remote.source, chapters)
        if not remote or remote.chapter_uid == nil
            or not remote.has_chapter_offset then
            error("remote progress unavailable: "
                .. tostring(remote_error or "remote_location_invalid"))
        end
        book.progress = remote.raw_percent
        book.chapter_uid = remote.chapter_uid
        book.chapter_idx = remote.chapter_idx
        book.chapter_offset = remote.chapter_offset
        book.summary = remote.summary or ""
        for _i, chapter in ipairs(chapters) do
            if tostring(chapter.chapterUid or chapter.chapterId or "")
                == tostring(book.chapter_uid) then
                selected = chapter
                break
            end
        end
    end
    selected = selected or (not force
        and Content.first_readable_chapter(book.chapters) or nil)
    if not selected then
        error("remote chapter is absent from the current catalog")
    end
    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    if tostring(book.psvts or "") == "" or book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book
end

function ReadReport:ensure_context(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_cookie_configured() then
        error("cookie not configured")
    end

    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or {
        book_id = book_id,
        title = self.current_book_title or book_id,
    }
    self:_build_context(book_id, force, book)
    if self._no_persist then
        -- Forked child: the parent persists the context from the outcome.
        return book
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return book
end

local function apply_position(book, position)
    if type(position) ~= "table" then return book end
    book.chapter_uid = position.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or tonumber(book.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset)
        or tonumber(book.chapter_offset) or 0
    book.progress = tonumber(position.percent or position.progress)
        or tonumber(book.progress) or 0
    book.summary = position.summary or book.summary or ""
    return book
end

function ReadReport:build_payload(book_id, elapsed_seconds, book, position)
    book = book or self:ensure_context(book_id, false)
    apply_position(book, position)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid,
        chapter_idx = tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(book.chapter_offset) or 0,
        progress = tonumber(book.progress) or 0,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

function ReadReport:_send(book_id, book, position, elapsed_seconds, on_write)
    apply_position(book, position)
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        book.pclts = WeRead.e(self.now())
    end
    if book.read_session_id ~= self.session_id then
        book.read_session_id = self.session_id
        book.read_session_entered_at = nil
    end
    if not book.read_session_entered_at then
        local enter_payload = WeRead.make_enter_read_payload{
            book_id = book_id,
            chapter_uid = book.chapter_uid,
            chapter_idx = tonumber(book.chapter_idx) or 0,
            chapter_offset = tonumber(book.chapter_offset) or 0,
            progress = tonumber(book.progress) or 0,
            summary = book.summary or "",
            app_id = book.app_id or WeRead.web_app_id(),
            psvts = book.psvts,
            pclts = book.pclts,
        }
        local entered, enter_code, headers, retry_after = self.client:report_read(
            enter_payload,
            book.reader_url or WeRead.reader_url(book_id)
        )
        if (tonumber(enter_code) or 0) >= 400 or response_rejected(entered, enter_code) then
            return entered, enter_code, headers, retry_after
        end
        book.read_session_entered_at = self.now()
        book.read_session_id = self.session_id
    end
    local payload = self:build_payload(
        book_id,
        elapsed_seconds == nil and self:_interval() or elapsed_seconds,
        book,
        position
    )
    if type(on_write) == "function" then on_write() end
    return self.client:report_read(payload, book.reader_url or WeRead.reader_url(book_id))
end

function ReadReport:upload_position(book_id, position, elapsed_seconds)
    if self.job or self.network_lease ~= nil then
        return false, { error = "read_report_busy", error_kind = "busy" }
    end
    local allowed, lease_or_reason = self:_acquire_network_gate(
        "progress", book_id)
    if not allowed then
        return false, { error = tostring(lease_or_reason), error_kind = "busy" }
    end
    local outcome = self:_run_pipeline(tostring(book_id), {
        allow_renewal = self:_renewal_allowed(),
        position = position,
        elapsed_seconds = elapsed_seconds or 0,
    })
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if type(outcome.book) == "table" then
        local ok, err = pcall(function()
            self:_persist_context(tostring(book_id), outcome.book)
        end)
        if not ok then
            log("warn", "persist progress upload context failed:", tostring(err))
        end
    end
    self:_release_network_gate(lease_or_reason, outcome)
    return outcome.accepted == true, outcome
end

return ReadReport
