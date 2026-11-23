-- KOReader constructs a new plugin for both ReaderUI and FileManager. Only the
-- visible instance may start work; a write already sent keeps its lease until
-- its own completion, even across a screen change.
local Sync = {}
Sync.__index = Sync

local active
local read_writer
local annotation_writer

local connection_checks = {
    heartbeat = true, network_connected = true, resume = true, manual_sync = true,
}

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
    self.due = nil
end

function Sync:deactivate()
    self:pause()
    if active ~= self then return false end
    active = nil
    return true
end

function Sync:activate()
    if active and active ~= self then active:deactivate() end
    active = self
    self.paused = false
    self:reschedule_heartbeat()
    self:request("startup", { delay = 1 })
end

function Sync:resume()
    if active ~= self then return end
    self.paused = false
    self:reschedule_heartbeat()
    self:request("resume")
end

function Sync:disconnected()
    self:_invalidate()
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

function Sync:request(reason, context)
    if active ~= self or self.paused then return false end
    context = context or {}
    if self.stage and self.stage_account ~= self.plugin.library_db:accountKey() then
        self:_invalidate()
    end
    if reason == "progress_pull_failed" then
        self.verified_until = nil
        self.allow_data = false
        self.probe_failed = self.plugin.library_db:accountKey()
    end
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
    if not account then self.explicit = nil; return end
    if self.explicit and self.explicit.account ~= account then self.explicit = nil end
    local progress = plugin.progress_sync
    if self.capture_current then
        self.capture_current = nil
        if progress.capture_for_reconnect then progress:capture_for_reconnect() end
    end
    if not plugin:isNetworkConnected() then self:disconnected(); return end
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
    if not book_id or book_id == "" then return end
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
        if status == "error" or (status == "deferred" and result.reason == "online_task_unavailable") then
            self.verified_until = nil
            self.probe_failed = account
            return
        end
        if status == "uploading" or status == "pulling" or status == "stale"
            or (status == "deferred" and result.reason == "busy") then return end
        self.allow_data = true
        if with_time and queued_book then
            plugin.read_report:drain()
        end
        if with_annotations and queued_book then
            local annotations = plugin:_offlineAnnotationCoordinator()
            if annotations then annotations:drain() end
        end
    end, explicit)
end

function Sync:_probe(account, book_id)
    self.allow_data = false
    self.stage, self.stage_account = "probe", account
    local generation = self.generation
    local complete = false
    local function finish(result)
        if complete then return end
        complete = true
        if active ~= self or self.paused or self.generation ~= generation then return end
        self.stage = nil
        if self.plugin.library_db:accountKey() ~= account then
            self:_schedule()
            return
        end
        if result and result.ok and result.value == true and self.plugin:isNetworkConnected() then
            self.verified_account = account
            self.verified_until = self.now() + math.min(60, self:interval_seconds())
            self.rerun = nil
            self:_schedule(0)
        else
            self.verified_account = nil
            self.probe_failed = account
        end
    end
    local client = self.plugin.client
    if not self.worker:available() then
        -- Some ports have no subprocess runner. Use the same bounded read.
        local ok, value = pcall(client.probe_sync, client, book_id)
        finish({ ok = ok, value = value })
        return
    end
    local started, reason = self.worker:start{
        kind = "sync_probe", timeout = 10,
        task = function(context)
            context.checkCancelled()
            return client:probe_sync(book_id)
        end,
        on_done = finish,
    }
    if not started and not complete then
        if reason == "worker_busy" then
            self.stage = nil
            self:_schedule(1)
        else
            finish({ ok = false })
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
    if not self:_verified(account) then return false, "probe_needed" end
    local is_read = kind == "weread_read_write"
    if not (is_read and context.operation == "progress") and not self.allow_data then
        return false, "progress_pending"
    end
    if (is_read and read_writer) or (not is_read and annotation_writer) then
        return false, "writer_busy"
    end
    if is_read and context.operation == "reading_time" then
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
        if active and active.plugin.library_db:accountKey() == account and outcome
            and (outcome.error_kind == "transport" or outcome.error_kind == "authentication"
                or outcome.error_kind == "context") then
            active:_invalidate()
            active.probe_failed = account
        end
        if active then active:_schedule() end
    end
end

return Sync
