-- Durable, account-scoped upload coordinator for native KOReader annotations.
-- Coordinate extraction happens while the document is open. Network writes run
-- in BackgroundWorker and are never retried blindly after an ambiguous result.
local LibraryDB = require("weread.lib.library_db")
local logger_module = require("weread.lib.logger")
local logger = type(logger_module.scoped) == "function"
    and logger_module.scoped("OfflineAnnotations") or logger_module

local OfflineAnnotations = {}
OfflineAnnotations.__index = OfflineAnnotations

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function changed_ids(book_id, path, items)
    local changed = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" then
            changed[LibraryDB.annotationLocalId(book_id, path, item)] = true
        end
    end
    return changed
end

function OfflineAnnotations:new(options)
    options = options or {}
    local object = setmetatable({
        library_db = assert(options.library_db, "offline annotation database required"),
        settings = assert(options.settings, "offline annotation settings required"),
        client = assert(options.client, "offline annotation client required"),
        worker = assert(options.worker, "offline annotation worker required"),
        scheduler = assert(options.scheduler, "offline annotation scheduler required"),
        resolver = assert(options.resolver, "offline annotation resolver required"),
        is_online = options.is_online or function() return false end,
        get_document = options.get_document or function() return nil end,
        get_book = options.get_book or function() return nil end,
        get_store = options.get_store or function() return nil end,
        now = options.now or os.time,
    }, self)
    if type(object.library_db.recoverLocalAnnotationInflight) == "function" then
        object.library_db:recoverLocalAnnotationInflight(object.now() - 90)
    end
    return object
end

function OfflineAnnotations:capture(book_id, path, annotations, modified_items)
    if self.settings:get("sync", {}).upload_annotations == false then
        return false
    end
    book_id = tostring(book_id or "")
    path = tostring(path or "")
    if book_id == "" or path == "" then return false end
    annotations = type(annotations) == "table" and annotations or {}
    local modified = changed_ids(book_id, path, modified_items)
    local resolve_all = modified_items == nil
    local document = self.get_document()
    local book = self.get_book(book_id)
    local store = self.get_store()
    local snapshot = {}

    for _, annotation in ipairs(annotations) do
        local item = copy(annotation)
        local local_id = LibraryDB.annotationLocalId(book_id, path, annotation)
        if document and book and (resolve_all or modified[local_id]) then
            local ok, payload, reason = pcall(
                self.resolver.resolve,
                document, book, annotation, store)
            if ok and type(payload) == "table" then
                item._weread_upload = payload
            else
                item._weread_upload_error = ok and reason or payload
            end
        end
        snapshot[#snapshot + 1] = item
    end

    local saved = self.library_db:putLocalAnnotationSnapshot(
        book_id, path, snapshot, { changed = modified })
    if saved then self:wake() end
    return saved
end

function OfflineAnnotations:status()
    local counts = self.library_db:localAnnotationStatus()
    return {
        counts = counts,
        busy = self.request ~= nil,
        unknown = (counts.unknown or 0)
            + (counts.delete_unknown or 0)
            + (counts.replace_delete_unknown or 0),
    }
end

function OfflineAnnotations:_cancel_retry()
    if not self.retry_task then return end
    if type(self.scheduler.unschedule) == "function" then
        self.scheduler:unschedule(self.retry_task)
    end
    self.retry_task = nil
end

function OfflineAnnotations:_schedule_retry(delay)
    if self.retry_task then return false end
    local task
    task = function()
        if self.retry_task ~= task then return end
        self.retry_task = nil
        if self.settings:get("sync", {}).upload_annotations ~= false
            and self.is_online() then
            self:wake()
        end
    end
    self.retry_task = task
    self.scheduler:scheduleIn(math.max(1, tonumber(delay) or 2), task)
    return true
end

function OfflineAnnotations:_has_pending()
    local counts = self.library_db:localAnnotationStatus()
    return (counts.local_only or 0) + (counts.update_pending or 0)
        + (counts.delete_pending or 0) + (counts.replace_delete_pending or 0) > 0
end

local function create_annotation(client, row)
    local payload = copy(row.upload or {})
    if row.kind == "thought" then
        payload.content = tostring(row.annotation.note or "")
        return client:add_private_review(payload)
    end
    return client:add_bookmark(payload)
end

local function remove_annotation(client, remote_kind, remote_id, payload)
    if remote_kind == "thought" then
        return client:remove_private_review(remote_id, payload)
    end
    return client:remove_bookmark(remote_id, payload)
end

local function perform(client, row)
    local replacing = row.sync_state == "update_pending"
        or (row.sync_state == "delete_pending" and row.present)
    if row.sync_state == "replace_delete_pending" then
        local removed, reason = remove_annotation(
            client, row.remote_kind, row.remote_id, row.upload)
        return {
            action = "replace_delete",
            accepted = removed == true,
            reason = reason,
            replacement_id = row.replacement_id,
        }
    end
    if replacing then
        local replacement_id, create_reason = create_annotation(client, row)
        if not replacement_id then
            return { action = "replace_create", reason = create_reason }
        end
        local removed, remove_reason = remove_annotation(
            client, row.remote_kind, row.remote_id, row.upload)
        return {
            action = "replace",
            accepted = removed == true,
            reason = remove_reason,
            replacement_id = tostring(replacement_id),
        }
    end
    if row.sync_state == "delete_pending" then
        local removed, reason = remove_annotation(
            client, row.remote_kind, row.remote_id, row.upload)
        return { action = "delete", accepted = removed == true, reason = reason }
    end
    local remote_id, reason = create_annotation(client, row)
    return {
        action = "create",
        accepted = remote_id ~= nil,
        remote_id = remote_id and tostring(remote_id) or nil,
        reason = reason,
    }
end

function OfflineAnnotations:_finish(row, result)
    self.request = nil
    local outcome = result and result.ok and result.value or nil
    if type(outcome) ~= "table" then
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = "unknown",
            last_error = result and result.error or "worker_no_result",
        })
        logger.warn("annotation upload result unknown:", "local_id=", row.local_id)
        return 1
    end

    if outcome.action == "create" and outcome.accepted and outcome.remote_id then
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = "synced",
            remote_id = outcome.remote_id,
            remote_kind = row.kind,
        })
    elseif outcome.action == "delete" and outcome.accepted then
        self.library_db:updateLocalAnnotationWork(row, { delete = true })
    elseif outcome.action == "replace" and outcome.replacement_id then
        if outcome.accepted then
            self.library_db:updateLocalAnnotationWork(row, {
                sync_state = "synced",
                remote_id = outcome.replacement_id,
                remote_kind = row.kind,
                replacement_id = "",
            })
        else
            self.library_db:updateLocalAnnotationWork(row, {
                sync_state = outcome.reason == "unknown"
                    and "replace_delete_unknown" or "replace_delete_pending",
                replacement_id = outcome.replacement_id,
                last_error = outcome.reason,
            })
        end
    elseif outcome.action == "replace_delete" and outcome.accepted then
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = "synced",
            remote_id = outcome.replacement_id,
            remote_kind = row.kind,
            replacement_id = "",
        })
    else
        local ambiguous = outcome.reason == "unknown"
        local state = ambiguous and "unknown" or row.sync_state
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = state,
            last_error = outcome.reason or "rejected",
        })
        if ambiguous then
            logger.warn("annotation upload result unknown:", "local_id=", row.local_id)
        end
        return ambiguous and 1 or 60
    end
    return 1
end

function OfflineAnnotations:wake()
    if self.settings:get("sync", {}).upload_annotations == false then
        self:_cancel_retry()
        return false
    end
    if self.request or not self.is_online() then
        return false
    end
    if self.worker:busy() then
        if self:_has_pending() then self:_schedule_retry(2) end
        return false
    end
    self.library_db:recoverLocalAnnotationInflight(self.now() - 90)
    local row = self.library_db:claimLocalAnnotationWork("offline-annotations")
    if not row then
        self:_cancel_retry()
        return false
    end
    self:_cancel_retry()
    local started, request_or_error = self.worker:start {
        kind = "offline_annotation_upload",
        queue = false,
        timeout = 60,
        task = function(context)
            context.checkCancelled()
            return perform(self.client, row)
        end,
        on_done = function(result)
            local delay = self:_finish(row, result)
            self:_schedule_retry(delay or 1)
        end,
    }
    if not started then
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = row.original_state,
            last_attempt_at = row.last_attempt_at,
            last_error = request_or_error,
        })
        logger.info("annotation upload worker unavailable:", tostring(request_or_error))
        self:_schedule_retry(5)
        return false
    end
    self.request = request_or_error
    return true
end

function OfflineAnnotations:on_network_connected()
    return self:wake()
end

return OfflineAnnotations
