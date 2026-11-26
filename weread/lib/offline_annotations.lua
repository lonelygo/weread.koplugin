-- Durable, account-scoped upload coordinator for native KOReader annotations.
-- Coordinate extraction happens while the document is open. Network writes run
-- in BackgroundWorker and are never retried blindly after an ambiguous result.
local LibraryDB = require("weread.lib.library_db")
local WorkerSettings = require("weread.lib.worker_settings")
local logger_module = require("weread.lib.logger")
local logger = type(logger_module.scoped) == "function"
    and logger_module.scoped("OfflineAnnotations") or logger_module

local OfflineAnnotations = {}
OfflineAnnotations.__index = OfflineAnnotations

-- These tasks process one annotation or one chapter and share the existing
-- serial worker slot. Keep the 64 MiB default for downloads and larger jobs.
local ANNOTATION_MIN_AVAILABLE_KB = 32 * 1024
local SOURCE_REPAIR_CHAPTER_LIMIT = 1

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
        gate = options.gate,
        request_sync = options.request_sync or function() end,
        has_request_sync = type(options.request_sync) == "function",
        get_document = options.get_document or function() return nil end,
        get_book = options.get_book or function() return nil end,
        get_store = options.get_store or function() return nil end,
        get_annotations = options.get_annotations or function() return nil end,
        get_session = options.get_session or function() return nil end,
        now = options.now or os.time,
    }, self)
    if type(object.library_db.recoverLocalAnnotationInflight) == "function" then
        object.library_db:recoverLocalAnnotationInflight(object.now() - 90)
    end
    return object
end

local function source_repairable(reason)
    return reason == "missing_source" or reason == "missing_source_version"
end

function OfflineAnnotations:_source_repair_context(repair)
    if not repair or self.settings:get("sync", {}).upload_annotations == false
        or self.library_db:accountKey() ~= repair.account_key
        or self.library_db.data_dir ~= repair.data_dir
        or self.get_session() ~= repair.session then return false end
    local document = self.get_document()
    local annotations = self.get_annotations()
    if not document or document.file ~= repair.path
        or type(annotations) ~= "table" then return false end
    return true, document, annotations
end

local function retry_delay(repair, reason)
    repair.attempts = (tonumber(repair.attempts) or 0) + 1
    local base = tostring(reason or ""):find("low_memory", 1, true) and 120 or 60
    return math.min(600, base * (2 ^ math.min(3, repair.attempts - 1)))
end

function OfflineAnnotations:_start_source_repair()
    local repair = self.source_repair_pending
    if not repair then
        self:_cancel_source_retry()
        return false
    end
    if self.source_repair_request then return false end
    local context_valid = self:_source_repair_context(repair)
    if not context_valid then
        if self.source_repair_pending == repair then self.source_repair_pending = nil end
        self:_cancel_source_retry()
        return false
    end
    if not self.is_online() then
        return false
    end
    local retry_after = (repair.next_attempt_at or 0) - self.now()
    if retry_after > 0 then
        self:_schedule_source_retry(retry_after)
        return false
    end
    if self.worker:busy() then
        self:_schedule_source_retry(2)
        return true
    end
    self:_cancel_source_retry()
    local fingerprint = WorkerSettings.fingerprint(self.settings)
    local request_state = { repair = repair }
    self.source_repair_pending = nil
    self.source_repair_request = request_state
    local started, request_or_error = self.worker:start {
        kind = "annotation_source_repair",
        queue = false,
        timeout = 90,
        min_available_kb = ANNOTATION_MIN_AVAILABLE_KB,
        task = function(context)
            return require("weread.lib.annotation_source_worker").run(
                self.settings, self.client, repair.book, repair.chapters, context)
        end,
        on_done = function(result)
            if self.source_repair_request ~= request_state then return end
            self.source_repair_request = nil
            local valid, document, annotations = self:_source_repair_context(repair)
            if valid and result and result.ok and type(result.value) == "table" then
                local applied, apply_error = pcall(function()
                    local value = result.value
                    if type(value.catalog) == "table" then
                        local Content = require("weread.lib.content")
                        local saved, save_error = Content.save_catalog_cache(
                            self.client, self.settings, repair.book, value.catalog)
                        if not saved then
                            error(save_error or "could not save current chapter catalog", 0)
                        end
                    end
                    if type(value.sources) == "table" then
                        local changes = {}
                        for _, source in ipairs(value.sources) do
                            local uid = tostring(source.chapter_uid or "")
                            if uid == "" or type(source.spans) ~= "table"
                                or source.version == nil then
                                error("invalid staged annotation source", 0)
                            end
                            changes[#changes + 1] = {
                                kind = "original", key = uid, uid = uid,
                                value = source.spans,
                            }
                            changes[#changes + 1] = {
                                kind = "original_version", key = uid, uid = uid,
                                value = source.version,
                            }
                        end
                        if #changes > 0 then
                            require("weread.lib.annotation_store"):new(
                                self.settings):write(repair.book_id, changes)
                        end
                    end
                end)
                if not applied then
                    result = { ok = false, error = tostring(apply_error) }
                end
            end
            if valid and result and result.ok and type(result.value) == "table" then
                if result.value.auth and not WorkerSettings.merge(
                    self.settings, fingerprint, result.value.auth) then
                    logger.info("skip annotation source auth write-back: parent auth changed")
                end
                local pending_before = self.source_repair_pending
                if document and type(annotations) == "table" then
                    local books = self.settings:get("books", {})
                    local current = books[repair.book_id]
                    local descriptor = current and current.annotation_documents
                        and current.annotation_documents[repair.path]
                    if descriptor and type(result.value.repaired) == "table" then
                        local repaired = {}
                        for _, chapter in ipairs(result.value.repaired) do
                            repaired[tostring(chapter.chapterUid or chapter.chapterId)] = chapter
                        end
                        for index, chapter in ipairs(descriptor.chapters or {}) do
                            local updated = repaired[tostring(
                                chapter.chapterUid or chapter.chapterId)]
                            if updated then descriptor.chapters[index] = updated end
                        end
                        current.book_version = tonumber(result.value.book_version)
                            or current.book_version
                        books[repair.book_id] = current
                        if type(self.settings.set) == "function" then
                            self.settings:set("books", books)
                            self.settings:flush()
                        end
                    end
                    self:capture(repair.book_id, repair.path, annotations, nil)
                    -- A capture that still needs source data installs a fresh
                    -- pending object. Otherwise any edit queued while the old
                    -- worker ran has now been resolved by the same source.
                    if self.source_repair_pending == pending_before then
                        self.source_repair_pending = nil
                    end
                end
                self:_start_source_repair()
                return
            end
            if valid and not self.source_repair_pending then
                local reason = result and result.error or "worker_no_result"
                local delay = retry_delay(repair, reason)
                repair.next_attempt_at = self.now() + delay
                self.source_repair_pending = repair
                logger.warn("annotation source repair failed:", tostring(reason))
                self:_schedule_source_retry(delay)
            else
                self:_start_source_repair()
            end
        end,
    }
    request_state.handle = request_or_error
    if not started then
        -- BackgroundWorker reports low-memory and launch failures through
        -- on_done synchronously. Custom/legacy runners may only return false.
        if self.source_repair_request == request_state then
            self.source_repair_request = nil
            if self:_source_repair_context(repair) and not self.source_repair_pending then
                local delay = retry_delay(repair, request_or_error)
                repair.next_attempt_at = self.now() + delay
                self.source_repair_pending = repair
                self:_schedule_source_retry(delay)
            end
        end
        logger.info("annotation source repair worker unavailable:", tostring(request_or_error))
        return false
    end
    return true
end

function OfflineAnnotations:_request_sync(reason, context)
    local ok, err = pcall(self.request_sync, reason, context or {})
    if not ok then logger.warn("annotation sync request failed:", tostring(err)) end
end

function OfflineAnnotations:_acquire_gate(book_id, live)
    if self.network_lease ~= nil then return false, "annotation_inflight" end
    local context = {
        source = "offline_annotations",
        operation = live and "live_annotation" or "annotation",
        book_id = tostring(book_id or ""),
    }
    local allowed, lease_or_reason
    if type(self.gate) == "function" then
        local ok, first, second = pcall(self.gate, "annotation_write", context)
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
        local denial = tostring(book_id or "") .. ":" .. tostring(reason)
        if self.last_gate_denial ~= denial then
            self.last_gate_denial = denial
            self:_request_sync(reason, context)
        end
        return false, reason
    end
    self.last_gate_denial = nil
    self.network_lease = lease_or_reason or true
    return true, self.network_lease
end

function OfflineAnnotations:_release_gate(lease, outcome)
    if lease == nil then return end
    if self.network_lease == lease then self.network_lease = nil end
    if type(lease) == "function" then
        pcall(lease, outcome)
    elseif type(lease) == "table" and type(lease.release) == "function" then
        pcall(lease.release, lease, outcome)
    end
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
    local needs_repair = type(self.library_db.localAnnotationRepairIds) == "function"
        and self.library_db:localAnnotationRepairIds(book_id, path) or {}
    local resolve_all = modified_items == nil
    local document = self.get_document()
    local book = self.get_book(book_id)
    local store = self.get_store()
    local snapshot, repair_chapters, repair_seen = {}, {}, {}
    local active_document = document and document.file == path and document or nil

    for _, annotation in ipairs(annotations) do
        local item = copy(annotation)
        local local_id = LibraryDB.annotationLocalId(book_id, path, annotation)
        if active_document and book and (resolve_all or modified[local_id]) then
            local ok, payload, reason = pcall(
                self.resolver.resolve,
                active_document, book, annotation, store)
            if ok and type(payload) == "table" then
                item._weread_upload = payload
            else
                item._weread_upload_error = ok and reason or payload
                if ok and source_repairable(reason)
                    and (modified[local_id] or needs_repair[local_id])
                    and type(self.resolver.chapter) == "function" then
                    local chapter = self.resolver.chapter(
                        active_document, book, annotation)
                    local uid = chapter and tostring(
                        chapter.chapterUid or chapter.chapterId or "") or ""
                    if uid ~= "" and not repair_seen[uid]
                        and #repair_chapters < SOURCE_REPAIR_CHAPTER_LIMIT then
                        repair_seen[uid] = true
                        repair_chapters[#repair_chapters + 1] = chapter
                    end
                end
            end
        end
        snapshot[#snapshot + 1] = item
    end

    local saved = self.library_db:putLocalAnnotationSnapshot(
        book_id, path, snapshot, { changed = modified })
    if saved and #repair_chapters > 0 then
        self.source_repair_sequence = (self.source_repair_sequence or 0) + 1
        self.source_repair_pending = {
            book_id = book_id, path = path, book = copy(book),
            chapters = repair_chapters,
            account_key = self.library_db:accountKey(),
            data_dir = self.library_db.data_dir,
            session = self.get_session(),
            sequence = self.source_repair_sequence,
            attempts = 0, next_attempt_at = 0,
        }
        self:_start_source_repair()
    end
    if saved and self:_has_pending() then
        self:_request_sync("annotation_captured", {
            source = "offline_annotations", book_id = book_id, live = type(modified_items) == "table",
        })
        if not self.has_request_sync then self:wake() end
    end
    return saved
end

function OfflineAnnotations:status()
    local counts = self.library_db:localAnnotationStatus()
    return {
        counts = counts,
        busy = self.request ~= nil,
        network_busy = self.network_lease ~= nil,
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

function OfflineAnnotations:_cancel_source_retry()
    if not self.source_retry_task then return end
    if type(self.scheduler.unschedule) == "function" then
        self.scheduler:unschedule(self.source_retry_task)
    end
    self.source_retry_task = nil
end

function OfflineAnnotations:_schedule_source_retry(delay)
    if self.source_retry_task then return false end
    local task
    task = function()
        if self.source_retry_task ~= task then return end
        self.source_retry_task = nil
        if self.settings:get("sync", {}).upload_annotations ~= false then
            self:_start_source_repair()
        end
    end
    self.source_retry_task = task
    self.scheduler:scheduleIn(math.max(1, tonumber(delay) or 60), task)
    return true
end

function OfflineAnnotations:_schedule_retry(delay)
    if self.retry_task then return false end
    local task
    task = function()
        if self.retry_task ~= task then return end
        self.retry_task = nil
        if self.settings:get("sync", {}).upload_annotations ~= false then
            self:wake()
        end
    end
    self.retry_task = task
    self.scheduler:scheduleIn(math.max(1, tonumber(delay) or 2), task)
    return true
end

function OfflineAnnotations:_has_pending()
    if type(self.library_db.hasPendingOfflineWork) == "function" then
        return self.library_db:hasPendingOfflineWork(false, true)
    end
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

    local acknowledged = false
    if outcome.action == "create" and outcome.accepted and outcome.remote_id then
        acknowledged = self.library_db:updateLocalAnnotationWork(row, {
            sync_state = "synced",
            remote_id = outcome.remote_id,
            remote_kind = row.kind,
        })
    elseif outcome.action == "delete" and outcome.accepted then
        acknowledged = self.library_db:updateLocalAnnotationWork(row, { delete = true })
    elseif outcome.action == "replace" and outcome.replacement_id then
        if outcome.accepted then
            acknowledged = self.library_db:updateLocalAnnotationWork(row, {
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
        acknowledged = self.library_db:updateLocalAnnotationWork(row, {
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
    if acknowledged then
        require("weread.lib.sync_status").noteAck(self, self.now())
    end
    return 1
end

function OfflineAnnotations:wake(live_book_id)
    local account = self.library_db:accountKey()
    if not self.is_online() or self.live_account ~= account then self.live_book = nil end
    if live_book_id and account and self.is_online() then
        self.live_book, self.live_account = live_book_id, account
    end
    if self.settings:get("sync", {}).upload_annotations == false then
        self:_cancel_retry()
        self:_cancel_source_retry()
        return false
    end
    -- Reconnect and manual-sync both enter through wake(). Source repair must
    -- run first because its local-only rows have no upload payload yet.
    local source_working = self:_start_source_repair()
        or self.source_repair_request ~= nil
    if self.request or self.network_lease ~= nil then
        return source_working
    end
    self.library_db:recoverLocalAnnotationInflight(self.now() - 90)
    if not self:_has_pending() then
        self.live_book = nil
        self:_cancel_retry()
        return source_working
    end
    if self.worker:busy() then
        -- The prefetch worker is shared. This drain is still in progress
        -- while its retry waits for the other job to release the worker.
        self:_schedule_retry(2)
        return true
    end
    local book_id = self.live_book or (type(self.library_db.pendingOfflineBook) == "function"
        and self.library_db:pendingOfflineBook(false, true) or nil)
    local allowed, lease_or_reason = self:_acquire_gate(book_id, self.live_book ~= nil)
    if not allowed then return false end
    local row = self.library_db:claimLocalAnnotationWork("offline-annotations", self.live_book)
    if not row then
        self.live_book = nil
        self:_release_gate(lease_or_reason, {
            accepted = false, write_attempted = false,
            error_kind = "empty_queue",
        })
        self:_cancel_retry()
        return false
    end
    self:_cancel_retry()
    local launching, synchronous_result = true, nil
    local function finish_request(result)
        local delay = self:_finish(row, result)
        local value = result and result.ok and result.value or nil
        self:_release_gate(lease_or_reason, {
            accepted = type(value) == "table" and value.accepted == true,
            write_attempted = true,
            error_kind = not (result and result.ok) and "task"
                or (type(value) == "table" and value.reason == "unknown"
                    and "transport" or nil),
            error = not (result and result.ok) and result.error
                or (type(value) == "table" and value.reason or nil),
        })
        if self:_has_pending() then
            self:_request_sync("annotation_remaining", {
                source = "offline_annotations", book_id = row.book_id,
            })
        end
        self:_schedule_retry(delay or 1)
    end
    local started, request_or_error = self.worker:start {
        kind = "offline_annotation_upload",
        queue = false,
        timeout = 60,
        min_available_kb = ANNOTATION_MIN_AVAILABLE_KB,
        task = function(context)
            context.checkCancelled()
            return perform(self.client, row)
        end,
        on_done = function(result)
            if launching then
                synchronous_result = result
                return
            end
            finish_request(result)
        end,
    }
    launching = false
    if not started then
        self.library_db:updateLocalAnnotationWork(row, {
            sync_state = row.original_state,
            last_attempt_at = row.last_attempt_at,
            last_error = request_or_error,
        })
        logger.info("annotation upload worker unavailable:", tostring(request_or_error))
        self:_release_gate(lease_or_reason, {
            accepted = false, write_attempted = false,
            error_kind = "worker_unavailable", error = request_or_error,
        })
        local delay = tostring(request_or_error or ""):find(
            "low_memory", 1, true) and 120 or 5
        self:_schedule_retry(delay)
        return false
    end
    self.request = request_or_error
    if synchronous_result then finish_request(synchronous_result) end
    return true
end

function OfflineAnnotations:drain(live_book_id)
    return self:wake(live_book_id)
end

function OfflineAnnotations:on_network_connected()
    return self:wake()
end

return OfflineAnnotations
