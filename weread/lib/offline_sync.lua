-- KOReader constructs a new plugin for both ReaderUI and FileManager. Only the
-- visible instance may start work; a write already sent keeps its lease until
-- its own completion, even across a screen change.
local Sync = {}
Sync.__index = Sync
local WorkerSettings = require("weread.lib.worker_settings")

local active
local read_writer
local annotation_writer
-- FileManager and ReaderUI can trade places while an acknowledged write is
-- returning. Only an explicit tap subscribes the current login to a result.
local manual
local last_probe_renewal
local BOOK_RETRY_SECONDS = 15
local PROBE_RENEWAL_COOLDOWN_SECONDS = 10 * 60

local connection_checks = {
    heartbeat = true, network_connected = true, resume = true, manual_sync = true,
}

local function probe_with_optional_renewal(client, book_id, allow_renewal,
        capture_auth)
    local verified, reason, auth_code = client:probe_sync(book_id)
    local value = {
        ok = verified == true,
        reason = reason,
        auth_code = auth_code,
    }
    if verified or reason ~= "authentication_required"
        or tonumber(auth_code) ~= -2012 or not allow_renewal then
        return value
    end

    local auth_result
    if capture_auth and client.settings then
        auth_result = WorkerSettings.capture(client.settings)
    end
    local renewed, renewed_reason, details = client:renew_probe_sync(book_id)
    details = type(details) == "table" and details or {}
    value.ok = renewed == true
    value.reason = renewed_reason
    value.auth_code = details.auth_code
    value.renew_attempted = details.renew_attempted == true
    value.auth_renewed = details.auth_renewed == true
    if auth_result then value.auth = auth_result() end
    return value
end

function Sync.new(class, plugin, scheduler, probe_worker, now)
    local self = setmetatable({
        plugin = plugin, scheduler = scheduler, worker = probe_worker,
        now = now or os.time, generation = 0,
    }, class)
    self.heartbeat = function()
        if active ~= self or self.paused then return end
        self:reschedule_heartbeat()
        self:request("heartbeat")
    end
    self.run = function()
        self.due = nil
        if active == self and not self.paused then self:_run() end
    end
    self.book_retry = function()
        self.book_retry_due = nil
        if active == self and not self.paused then self:_schedule() end
    end
    return self
end

function Sync:interval_seconds()
    local minutes = tonumber(self.plugin.settings:get("sync", {}).heartbeat_minutes) or 10
    return 60 * math.max(1, math.min(60, math.floor(minutes)))
end

function Sync:reschedule_heartbeat()
    self.scheduler:unschedule(self.heartbeat)
    if active == self and not self.paused then
        self.scheduler:scheduleIn(self:interval_seconds(), self.heartbeat)
    end
end

function Sync:_invalidate()
    self.generation = self.generation + 1
    self.verified_account, self.verified_until, self.probe_failed = nil, nil, nil
    self.allow_data = false
    self.stage, self.stage_account, self.rerun = nil, nil, nil
end

function Sync:pause()
    self.paused = true
    self:_invalidate()
    self.scheduler:unschedule(self.heartbeat)
    self.scheduler:unschedule(self.run)
    self.scheduler:unschedule(self.book_retry)
    self.due = nil
    self.book_retry_due = nil
end

function Sync:deactivate()
    self:pause()
    if active ~= self then return false end
    active = nil
    return true
end

function Sync:activate()
    if active == self then return true end
    -- KOReader may construct a FileManager behind a still-open ReaderUI.
    -- Only the reader's CloseDocument handoff transfers that active session.
    if active and active.plugin.ui and active.plugin.ui.document
        and self.plugin.ui and not self.plugin.ui.document then return false end
    if active then active:deactivate() end
    active = self
    self.paused = false
    self:reschedule_heartbeat()
    self:request("startup", { delay = 1 })
    return true
end

function Sync:resume()
    if active ~= self then return end
    self.paused = false
    self:reschedule_heartbeat()
    self:request("resume")
end

function Sync:disconnected()
    self:_invalidate()
    if self:_manualAttempt() then
        manual.failure = "offline"
        self:_schedule()
    end
end

function Sync:_manualAttempt()
    if active ~= self or not manual then return end
    local db = self.plugin.library_db
    if manual.account ~= db:accountKey() or manual.data_dir ~= db.data_dir then
        manual = nil
    end
    return manual
end

function Sync:startManual(book_id)
    local db = self.plugin.library_db
    local account = db:accountKey()
    if not account then return false end
    -- SimpleUI's Home card belongs to FileManager even if ReaderUI currently
    -- holds the coordinator. Forward only the explicit tap for the same login.
    if active ~= self then
        local other = active and active.plugin.library_db
        if other and other.data_dir == db.data_dir and other:accountKey() == account then
            return active:startManual(book_id)
        end
        return false
    end
    if self.paused then return false end
    if self:_manualAttempt() then return true end
    manual = { account = account, data_dir = db.data_dir }
    if db.readTimeReceipts then
        manual.start_seconds = db:readTimeReceipts().seconds
    end
    self.plugin.read_report:capture_for_manual()
    if self.plugin:isNetworkConnected() then self.plugin:showManualSyncResult("started") end
    return self:request("manual_sync", {
        manual = true, pull_current = book_id ~= nil, book_id = book_id,
    })
end

-- A position comparison or an old last-confirmed timestamp is not a receipt
-- for this tap. Only the write lease below records an accepted HTTP mutation.
function Sync:_finishManual(reason)
    local attempt = self:_manualAttempt()
    if not attempt or self.paused or read_writer or annotation_writer then return end
    local progress = self.plugin.progress_sync
    if progress.pulling or progress.uploading or progress.reconciling or progress:awaiting_choice() then return end
    local snapshot = require("weread.lib.sync_status").get(self.plugin)
    local db = self.plugin.library_db
    if attempt.start_seconds and db.readTimeReceipts then
        snapshot.newly_confirmed_seconds = math.max(0, (db:readTimeReceipts().seconds or 0) - attempt.start_seconds)
    end
    reason = reason or attempt.failure
    local held = (snapshot.unknown_seconds or 0) > 0 or (snapshot.unknown_annotations or 0) > 0
        or (snapshot.rejected_seconds or 0) > 0
    if not snapshot.available then reason = "unavailable"
    elseif not reason then
        if snapshot.state == "conflict" then reason = "conflict"
        elseif held and attempt.accepted then reason = "uploaded_with_review"
        elseif snapshot.state == "pending" and (snapshot.unlocated_annotations or 0) > 0
            and snapshot.pending_annotations == snapshot.unlocated_annotations
            and (snapshot.pending_seconds or 0) == 0 and (snapshot.pending_progress or 0) == 0 then
            reason = "locate_annotations"
        elseif snapshot.state == "pending" then reason = attempt.row_reason or (attempt.accepted and "partial" or "pending")
        elseif (snapshot.rejected_seconds or 0) > 0 then reason = "review"
        elseif held then reason = "unknown"
        elseif attempt.accepted then reason = "uploaded"
        elseif attempt.matched then reason = "matched"
        else reason = "empty" end
    end
    manual = nil
    if self.explicit and self.explicit.manual then self.explicit = nil end
    if db.saveManualSyncResult then db:saveManualSyncResult(reason, os.time()) end
    self.plugin:showManualSyncResult(reason, snapshot)
end

-- Keep the progress choice interactive. Its ordinary per-position result is
-- superseded by the account-wide result while a manual sync is in progress.
function Sync:handlesProgressNotice(code)
    local attempt = self:_manualAttempt()
    if not attempt then return false end
    if code == "already_synced" or code == "remote_applied" then
        attempt.matched = true
    elseif code ~= "upload_success" and code ~= "local_kept" then
        attempt.failure = code == "offline" and "offline" or "progress_failed"
    end
    self:_schedule()
    return true
end

function Sync:_schedule(delay)
    if active ~= self or self.paused then return end
    delay = math.max(0, tonumber(delay) or 0.1)
    local due = self.now() + delay
    if self.due and self.due <= due then return end
    self.scheduler:unschedule(self.run)
    self.due = due
    self.scheduler:scheduleIn(delay, self.run)
end

function Sync:_schedule_book_retry(delay)
    if active ~= self or self.paused then return end
    delay = math.max(0, tonumber(delay) or BOOK_RETRY_SECONDS)
    local due = self.now() + delay
    if self.book_retry_due and self.book_retry_due <= due then return end
    self.scheduler:unschedule(self.book_retry)
    self.book_retry_due = due
    self.scheduler:scheduleIn(delay, self.book_retry)
end

function Sync:request(reason, context)
    if active ~= self or self.paused then return false end
    context = context or {}
    if self.stage and self.stage_account ~= self.plugin.library_db:accountKey() then
        self:_invalidate()
    end
    if reason == "login_completed" then
        self:_invalidate()
        self.recheck = true
    end
    if reason == "annotation_captured" and context.live and self.plugin:isNetworkConnected() then
        -- A newly edited note uses its own endpoint and is independent of
        -- read-time receipts and cloud-position choices. Keep its durable row
        -- until the normal writer returns the remote mark or review ID.
        local annotations = self.plugin:_offlineAnnotationCoordinator()
        if annotations then annotations:drain(context.book_id) end
    end
    if reason == "progress_pull_failed" then
        self.verified_until = nil
        self.allow_data = false
        self.probe_failed = self.plugin.library_db:accountKey()
    end
    if reason == "remote_choice_finished" and self:_manualAttempt() then manual.matched = true end
    if connection_checks[reason] then
        self.recheck = true
        self.probe_failed = nil
        if not self.stage then self.verified_until = nil end
        self.capture_current = true
    end
    if context.manual or context.pull_current or context.resume_conflicts then
        self.explicit = {
            manual = context.manual, pull_current = context.pull_current,
            resume_conflicts = context.resume_conflicts,
            book_id = context.book_id, account = self.plugin.library_db:accountKey(),
        }
    end
    if self.stage then self.rerun = true else self:_schedule(context.delay) end
    return true
end

function Sync:_verified(account)
    return account and account == self.verified_account and self.verified_until
        and self.now() < self.verified_until
end

function Sync:_probeRenewalAllowed(account, fingerprint)
    local last = last_probe_renewal
    return not last or last.account ~= account or last.fingerprint ~= fingerprint
        or last.data_dir ~= self.plugin.library_db.data_dir
        or self.now() - last.at >= PROBE_RENEWAL_COOLDOWN_SECONDS
end

function Sync:_noteProbeRenewal(account, fingerprint)
    last_probe_renewal = {
        at = self.now(), account = account, fingerprint = fingerprint,
        data_dir = self.plugin.library_db.data_dir,
    }
end

function Sync:_finish()
    self.stage = nil
    if self.rerun then
        self.rerun = nil
        self:_schedule()
    end
end

function Sync:_run()
    if self.stage then return end
    local plugin = self.plugin
    local account = plugin.library_db:accountKey()
    local attempt = self:_manualAttempt()
    if not account then self.explicit = nil; return end
    if self.explicit and self.explicit.account ~= account then self.explicit = nil end
    local progress = plugin.progress_sync
    if self.capture_current then
        self.capture_current = nil
        if progress.capture_for_reconnect then progress:capture_for_reconnect() end
    end
    if not plugin:isNetworkConnected() then
        self:_invalidate()
        self.explicit = nil
        self:_finishManual("offline")
        return
    end
    if attempt and attempt.failure then
        self:_finishManual()
        if self:_manualAttempt() or self.probe_failed == account then return end
    end
    local settings = plugin.settings
    local with_time = settings:get("read_report", {}).enabled == true
    local with_annotations = settings:get("sync", {}).upload_annotations ~= false
    local explicit = self.explicit or {}
    explicit.retry_now = self.recheck
    local _, summary = progress:has_pending(explicit)
    local queued_book = plugin.library_db:pendingOfflineBook(with_time, with_annotations)
    local position_book
    if summary.actionable > 0 or explicit.manual or explicit.resume_conflicts then
        position_book = summary.book_id
    end
    local book_id = explicit.book_id or position_book or queued_book
    if not book_id or book_id == "" then
        self.explicit, self.recheck = nil, nil
        self:_finishManual()
        return
    end
    if not self:_verified(account) then
        if self.probe_failed ~= account then self:_probe(account, book_id) end
        return
    end

    self.stage, self.stage_account = "progress", account
    self.explicit, self.recheck = nil, nil
    self.allow_data = false
    local generation = self.generation
    progress:reconcile_pending(function(result)
        if active ~= self or self.paused or generation ~= self.generation then return end
        if plugin.library_db:accountKey() ~= account then
            self:_invalidate()
            self:_schedule()
            return
        end
        self:_finish()
        -- A position write uses the same endpoint as a time report. Wait for
        -- its completion (which requests another pass) before starting time.
        local status = result and result.status
        local current = self:_manualAttempt()
        if current and status == "synced" then current.matched = true end
        if status == "error" or (status == "deferred" and result.reason == "online_task_unavailable") then
            local failed_book = tostring(result and result.book_id or book_id or "")
            if failed_book ~= ""
                and type(plugin.library_db.deferPendingReadTimeForBook) == "function" then
                plugin.library_db:deferPendingReadTimeForBook(
                    failed_book, BOOK_RETRY_SECONDS)
            end
            if current then
                current.failure = "progress_failed"
            end
            -- The service probe was already confirmed. A catalog or
            -- book-position failure must not revoke the whole account.
            -- Located annotations use an independent endpoint and may proceed;
            -- this book's time remains delayed until progress is safe.
            self.allow_data = true
            local annotations = plugin:_offlineAnnotationCoordinator()
            local scheduled = with_annotations and annotations
                and annotations:drain() or false
            if current and not scheduled then self:_finishManual() end
            -- The immediate rerun may still process another book. Keep a
            -- separate delayed wakeup for this row's retry window rather
            -- than letting that earlier pass consume the only timer.
            self:_schedule()
            self:_schedule_book_retry(BOOK_RETRY_SECONDS)
            return
        end
        if status == "uploading" or status == "pulling" or status == "stale"
            or (status == "deferred" and result.reason == "busy") then return end
        self.allow_data = true
        local scheduled
        if with_time and queued_book then
            scheduled = plugin.read_report:drain(current ~= nil)
        end
        if with_annotations and queued_book then
            local annotations = plugin:_offlineAnnotationCoordinator()
            if annotations then scheduled = annotations:drain() or scheduled end
        end
        if current and not scheduled and not self.due then self:_finishManual() end
    end, explicit)
end

function Sync:_probe(account, book_id)
    self.allow_data = false
    self.stage, self.stage_account = "probe", account
    local generation = self.generation
    local complete = false
    local inline_fallback_attempted = false
    local client = self.plugin.client
    local auth_fingerprint = WorkerSettings.fingerprint(
        self.plugin.settings)
    local allow_renewal = self:_probeRenewalAllowed(
        account, auth_fingerprint)
    local function inline_probe(can_renew)
        return probe_with_optional_renewal(
            client, book_id, can_renew == true, false)
    end
    local function local_failure_reason(reason)
        if reason == "low_memory" then return "probe_low_memory" end
        if reason == "worker_timeout" then return "probe_timeout" end
        if reason == "worker_unavailable" or reason == "worker_no_result" then
            return "probe_worker_unavailable"
        end
        return "probe_worker_failed"
    end
    local function finish(result)
        if complete then return end
        -- A late callback belongs to the account and generation captured when
        -- the worker started. Never run its inline fallback (especially
        -- renewal) against a newly logged-in account or a replacement UI.
        if active ~= self or self.paused or self.generation ~= generation then
            return
        end
        if self.plugin.library_db:accountKey() ~= account then
            complete = true
            self:_invalidate()
            self:_schedule()
            return
        end
        if not (result and result.ok)
            and self:_manualAttempt()
            and self.plugin:isNetworkConnected()
            and not inline_fallback_attempted then
            -- A timed-out/no-result child may already have sent renewal or be
            -- waiting on its verification GET. The bounded fallback remains
            -- read-only in that case. Renewal is safe only when no child ever
            -- started (low memory, unavailable runner, launch failure).
            local error_code = result and result.error
            local child_never_started = result and result.not_started == true
                or error_code == "low_memory"
                or error_code == "worker_unavailable"
            inline_fallback_attempted = true
            local ok, value = pcall(inline_probe,
                allow_renewal and child_never_started)
            result = {
                ok = ok,
                value = ok and value or {
                    ok = false,
                    reason = local_failure_reason(result and result.error),
                },
            }
        end
        complete = true
        self.stage = nil
        local value = result and result.ok and result.value or nil
        local renew_attempted = type(value) == "table"
            and value.renew_attempted == true
        local verified = value == true
            or (type(value) == "table" and value.ok == true)
        local failure_reason = type(value) == "table" and value.reason or nil
        local auth_merge_failed = false
        if type(value) == "table" and type(value.auth) == "table" then
            if not WorkerSettings.merge(
                self.plugin.settings, auth_fingerprint, value.auth) then
                verified = false
                failure_reason = "authentication_required"
                auth_merge_failed = true
            end
            value.auth = nil
        end
        if renew_attempted then
            self:_noteProbeRenewal(account,
                auth_merge_failed and auth_fingerprint
                    or WorkerSettings.fingerprint(self.plugin.settings))
        end
        if verified and self.plugin:isNetworkConnected() then
            self.verified_account = account
            self.verified_until = self.now() + math.min(60, self:interval_seconds())
            self.rerun = nil
            self:_schedule(0)
        else
            self.verified_account = nil
            self.probe_failed = account
            local attempt = self:_manualAttempt()
            if attempt then
                if not self.plugin:isNetworkConnected() then
                    attempt.failure = "offline"
                elseif failure_reason then
                    attempt.failure = failure_reason
                elseif result and result.ok then
                    attempt.failure = "response_unrecognized"
                else
                    attempt.failure = local_failure_reason(
                        result and result.error)
                end
                self:_finishManual()
            end
        end
    end
    if not self.worker:available() then
        -- Some ports have no subprocess runner. Use the same bounded read.
        local ok, value = pcall(inline_probe, allow_renewal)
        finish({ ok = ok, value = ok and value or {
            ok = false, reason = "service_unreachable",
        } })
        return
    end
    local started, reason = self.worker:start{
        -- At most three bounded requests: initial GET, renewal POST, and the
        -- mandatory verification GET (6 s each plus fork/file overhead).
        kind = "sync_probe", timeout = 24,
        task = function(context)
            context.checkCancelled()
            return probe_with_optional_renewal(
                client, book_id, allow_renewal, true)
        end,
        on_done = finish,
    }
    if not started and not complete then
        if reason == "worker_busy" then
            self.stage = nil
            self:_schedule(1)
        else
            finish({ ok = false, error = reason, not_started = true })
        end
    end
end

function Sync:gate(kind, context)
    if active ~= self or self.paused then return false, "inactive" end
    local account = self.plugin.library_db:accountKey()
    if not self.plugin:isNetworkConnected() then
        self:disconnected()
        return false, "offline"
    end
    if not account then return false, "authentication_required" end
    local is_read = kind == "weread_read_write"
    local live = (is_read and context.operation == "live_reading_time")
        or (not is_read and context.operation == "live_annotation")
    -- A fresh online mutation checks the service itself. Historical time
    -- shares the progress endpoint and still goes through reconnect comparison.
    if not live and not self:_verified(account) then return false, "probe_needed" end
    if not live and not (is_read and context.operation == "progress") and not self.allow_data then
        return false, "progress_pending"
    end
    if (is_read and read_writer) or (not is_read and annotation_writer) then
        return false, "writer_busy"
    end
    if is_read and context.operation ~= "progress" then
        local progress = self.plugin.progress_sync
        if self.stage == "progress" or progress.uploading or progress.reconciling or progress.pulling
            or (progress.awaiting_choice and progress:awaiting_choice(context.book_id)) then
            return false, "progress_pending"
        end
    end
    local token = {}
    if is_read then read_writer = token else annotation_writer = token end
    return true, function(outcome)
        if is_read and read_writer == token then read_writer = nil
        elseif not is_read and annotation_writer == token then annotation_writer = nil
        else return end
        local same_account = active and active.plugin.library_db:accountKey() == account
            and active.plugin.library_db.data_dir == self.plugin.library_db.data_dir
        if not same_account or not outcome then
            if active then active:_schedule() end
            return
        end
        local error_kind = outcome.error_kind
        local time_row = is_read and context.operation ~= "progress"
        local ambiguous = (time_row or not is_read) and outcome.write_attempted == true
            and (error_kind == "transport" or error_kind == "unknown" or error_kind == "job")
        local held_row = ambiguous or (time_row and (error_kind == "rejected" or error_kind == "context"))
        local attempt = active:_manualAttempt()
        if attempt then
            if outcome.accepted == true then
                attempt.accepted = true
            elseif time_row and error_kind == "context" then
                attempt.row_reason = "time_position_pending"
            elseif error_kind == "authentication" then
                attempt.failure = outcome.auth_renewed and "login_renewed" or "authentication_required"
            elseif error_kind == "rate_limited" then
                attempt.failure = "service_busy"
            elseif error_kind == "transport" and outcome.write_attempted == false then
                attempt.failure = "service_unreachable"
            elseif not held_row and error_kind ~= "empty_queue" and error_kind ~= "queue_changed" then
                attempt.failure = "unconfirmed"
            end
        end
        if outcome.accepted == true then
            active.verified_account = account
            active.verified_until = active.now() + math.min(60, active:interval_seconds())
            active.probe_failed = nil
        elseif error_kind == "transport" or error_kind == "authentication"
            or (not time_row and error_kind == "context") then
            active:_invalidate()
            -- An uncertain POST is held individually. Probe before replaying
            -- the next item, so a single lost reply doesn't stall the account.
            if not ambiguous and not outcome.auth_renewed then active.probe_failed = account end
        end
        if active then active:_schedule() end
    end
end

return Sync
