local PositionMapper = require("weread.lib.position_mapper")
local RemoteProgress = require("weread.lib.remote_progress")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local RECONCILE_RETRY_SECONDS = 15
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

local function position_identity(account_id, book_id, position)
    position = type(position) == "table" and position or {}
    return table.concat({
        tostring(account_id or ""),
        tostring(book_id or position.book_id or ""),
        tostring(position.captured_at or ""),
        tostring(position.chapter_uid or ""),
        tostring(position.chapter_index or ""),
        tostring(position.chapter_offset or ""),
        tostring(position.percent or ""),
    }, "|")
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        library_db = options.library_db,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        request_sync_callback = options.request_sync,
        upload_position = options.upload_position,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
        sync_request_token = 0,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_account_id()
    local account = self.settings:get("account", {})
    return type(account) == "table" and tostring(account.user_vid or "") or ""
end

function ProgressSync:_pending_identity(book_id, book)
    if type(book) ~= "table" or type(book.pending_upload_position) ~= "table" then
        return nil
    end
    return tostring(book.pending_upload_id or position_identity(
        book.pending_upload_account,
        book_id,
        book.pending_upload_position
    ))
end

function ProgressSync:_pending_matches(book_id, identity)
    local books = self.settings:get("books", {})
    local book = type(books) == "table" and books[tostring(book_id)] or nil
    return type(book) == "table"
        and tostring(book.pending_upload_account or "") == self:_account_id()
        and self:_pending_identity(book_id, book) == tostring(identity or "")
end

function ProgressSync:_clear_pending_if_matches(book_id, identity, patch)
    if not self:_pending_matches(book_id, identity) then return false end
    patch = copy(patch or {})
    patch.pending_upload_position = false
    patch.pending_upload_reason = false
    patch.pending_upload_account = false
    patch.pending_upload_id = false
    patch.pending_upload_blocked = false
    patch.pending_upload_remote = false
    patch.pending_upload_conflict_id = false
    patch.pending_upload_prompted = false
    patch.pending_upload_decision = false
    patch.pending_upload_retry_after = false
    return self:_persist(book_id, patch)
end

function ProgressSync:_note_sync_ack()
    require("weread.lib.sync_status").noteAck({
        settings = self.settings,
        library_db = self.library_db,
    }, self.now())
end

function ProgressSync:_save_pending(position, reason)
    if type(position) ~= "table" then return nil end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    local account_id = self:_account_id()
    if book_id == "" or account_id == "" then return nil end
    local identity = position_identity(account_id, book_id, position)
    local books = self.settings:get("books", {})
    local previous = type(books) == "table" and books[book_id] or nil
    local previous_identity = self:_pending_identity(book_id, previous)
    if previous_identity
        and PositionMapper.same_position(previous.pending_upload_position, position) then
        return previous_identity, book_id
    end
    local patch = {
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
        pending_upload_account = account_id,
        pending_upload_id = identity,
    }
    if previous_identity ~= identity then
        if self.awaiting_choice_book_id == book_id then
            self.awaiting_choice_book_id = nil
        end
        patch.pending_upload_blocked = false
        patch.pending_upload_remote = false
        patch.pending_upload_conflict_id = false
        patch.pending_upload_prompted = false
        patch.pending_upload_decision = false
        patch.pending_upload_retry_after = false
        patch.last_sync_error = false
    end
    self:_persist(book_id, patch)
    return identity, book_id
end

function ProgressSync:capture_for_reconnect()
    if self:_config().upload_on_close ~= true then
        return false, "upload_disabled"
    end
    if not self.dirty then return false, "unchanged" end
    local position, reason = self:capture_local()
    if not position then return false, reason end
    local book_id = tostring(position.book_id or "")
    local books = self.settings:get("books", {})
    local book = type(books) == "table" and books[book_id] or nil
    if type(book) == "table" then
        if type(book.pending_upload_position) == "table"
            and PositionMapper.same_position(book.pending_upload_position, position) then
            return true, "already_pending"
        end
        if type(book.last_uploaded_position) == "table"
            and PositionMapper.same_position(book.last_uploaded_position, position) then
            self.dirty = false
            return false, "already_synced"
        end
    end
    local identity = self:_save_pending(position, "network_reconnect")
    if not identity then return false, "snapshot_not_saved" end
    return true, "captured"
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books, book_id)
    self.settings:flush()
    for key in pairs(patch) do
        if tostring(key):match("^pending_upload_") then
            require("weread.lib.sync_status").invalidateProgress(self.settings)
            break
        end
    end
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    local file_context
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
        file_context = cached.file_context
        if file_context and file_context.incremental then
            local _index
            _index, current_chapter, is_full_book, file_context =
                self.get_file_context(book, path)
            cached.current_chapter = current_chapter
            cached.is_full_book = is_full_book == true
            cached.file_context = file_context
        end
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book, file_context =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            position_catalog = PositionMapper.catalog(chapters),
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            file_context = file_context,
            path = path,
        }
        cached = self.document_context
    end
    local fraction = file_context and file_context.chapter_fraction
        or self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            catalog = cached.position_catalog,
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters)
    return RemoteProgress.fetch(
        self.client, self.settings, book_id, chapters)
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            account_id = self:_account_id(),
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self.goto_fraction(target.fraction, context)
    if not ok then return false, err or "jump_failed" end
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        remote,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self.dirty = false
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

function ProgressSync:_upload_snapshot(position, reason, show_result, options)
    options = options or {}
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" then return false end
    local identity = options.identity
    if not identity then
        identity, book_id = self:_save_pending(position, reason)
    end
    if not identity then return false end
    if options.confirmed_local and self:_pending_matches(book_id, identity) then
        self:_persist(book_id, { pending_upload_decision = "local" })
    end
    local function finish(result)
        if type(options.done) == "function" then options.done(result) end
    end
    if self.uploading then
        self:request_sync("upload_busy")
        finish({ status = "deferred", book_id = book_id, reason = "busy" })
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        finish({ status = "deferred", book_id = book_id, reason = "offline" })
        return false
    end
    local fresh_snapshot = self.request_sync_callback and not options.confirmed_local
    if (fresh_snapshot or not self.verified) and reason ~= "network_restored" then
        self.state = "pending_reconcile"
        self:request_sync("snapshot_saved")
        finish({ status = "deferred", book_id = book_id,
            reason = "needs_reconcile" })
        return false
    end
    self.uploading = true
    self.state = "uploading"
    local attempt
    attempt = function()
        if not self:_pending_matches(book_id, identity) then
            self.uploading = false
            finish({ status = "stale", book_id = book_id })
            self:request_sync("stale_upload")
            return
        end
        local ok, accepted, outcome = pcall(
            self.upload_position,
            book_id,
            copy(position),
            0
        )
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy" then
            self.uploading = false
            self.state = "pending_reconcile"
            finish({ status = "deferred", book_id = book_id, reason = "busy" })
            self:request_sync("progress_endpoint_busy", {
                delay = RECONCILE_RETRY_SECONDS,
            })
            return
        end
        self.uploading = false
        if ok and accepted then
            local cleared = self:_clear_pending_if_matches(book_id, identity, {
                last_local_position = position,
                last_uploaded_position = position,
                last_upload_at = self.now(),
                last_sync_error = false,
            })
            if cleared then
                self.state = "verified"
                self.dirty = false
                self.last_uploaded_position = copy(position)
                self:_note_sync_ack()
            else
                self.state = "pending_reconcile"
            end
            log("info", "upload accepted:",
                "book=", book_id,
                "percent=", tostring(position.percent),
                "reason=", tostring(reason))
            if show_result and cleared then
                self.notify("upload_success", { position = position })
            end
            finish({ status = cleared and "uploaded" or "stale",
                book_id = book_id })
            self:request_sync("upload_finished")
            return
        end
        local error_message = ok and type(outcome) == "table"
            and outcome.error or outcome
        self.state = "error"
        if self:_pending_matches(book_id, identity) then
            self:_persist(book_id, {
                last_sync_error = tostring(error_message or "upload_failed"),
            })
        end
        log("warn", "upload failed:", tostring(error_message))
        if show_result then
            self.notify("upload_failed", {
                error = tostring(error_message or "upload_failed"),
            })
        end
        finish({ status = "error", book_id = book_id,
            error = tostring(error_message or "upload_failed") })
        if self.is_online() then
            self:request_sync("upload_failed", { delay = 30 })
        end
    end
    local started
    if options.inside_online then
        attempt()
        started = true
    else
        started = self.run_online("progress_upload", attempt)
    end
    if not started then
        self.uploading = false
        self.state = "offline"
        finish({ status = "deferred", book_id = book_id,
            reason = "online_task_unavailable" })
        self:request_sync("upload_start_failed", {
            delay = RECONCILE_RETRY_SECONDS,
        })
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true, {
            confirmed_local = true,
        })
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local conflict = remote.conflict == true
        or comparison == "remote_ahead"
        or comparison == "different"
    if conflict and self:_config().ask_on_conflict ~= false then
        local identity, book_id = self:_save_pending(
            local_position,
            options.manual and "manual_conflict" or "open_conflict"
        )
        if identity then
            self:_present_pending_conflict({
                book_id = book_id,
                position = copy(local_position),
                identity = identity,
            }, remote, comparison)
        end
        return
    end

    self:_keep_local(local_position, remote, {
        manual = options.manual,
        upload_now = true,
        reason = conflict and "default_local_choice" or "local_ahead",
    })
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and type(self.refresh_catalog) == "function") then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if options.known_offline == true or not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation = self.generation
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        if not local_position then
            local book_id = tostring(self.detect_book() or "")
            local refresh_ok, refreshed, refresh_error = pcall(
                self.refresh_catalog, book_id)
            if not refresh_ok then
                refresh_error = refreshed
                refreshed = nil
            end
            self.document_context = nil
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.pulling = false
                self.state = "error"
                self.notify("local_unavailable", {
                    error = refresh_error or reason,
                })
                return
            end
            if type(refreshed) ~= "table" or #refreshed == 0 then
                log("warn", "catalog refresh returned no chapters for:", book_id)
            end
        end
        local remote, pull_error = self:_fetch_remote(
            context.book_id,
            context.chapters
        )
        self.pulling = false
        if generation ~= self.generation
            or tostring(self.detect_book() or "") ~= context.book_id then
            return
        end
        if not remote then
            self.state = "error"
            self:_persist(context.book_id, {
                last_pull_at = self.now(),
                last_sync_error = tostring(pull_error),
            })
            if options.manual then
                self.notify("pull_failed", { error = tostring(pull_error) })
            end
            self:request_sync("progress_pull_failed", {
                book_id = context.book_id,
            })
            return
        end
        self:_persist(context.book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(),
            last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
        self:request_sync("progress_pull_finished", {
            book_id = context.book_id,
        })
    end, { silent_offline = true })
    if not started then
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    if tostring(pending.account_id or "") ~= self:_account_id() then
        self.pending_jump = nil
        return false
    end
    local _, _, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    local ok, err = self.goto_fraction(pending.fraction, context)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        pending.remote,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    self:_persist(book_id, {
        pending_remote_position = false,
        pending_remote_account = false,
        pending_remote_selected_at = false,
    })
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:_apply_saved_remote(context)
    if type(context) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local state = type(books) == "table" and books[context.book_id] or nil
    local remote = type(state) == "table" and state.pending_remote_position or nil
    if type(remote) ~= "table"
        or tostring(state.pending_remote_account or "") ~= self:_account_id() then
        return false
    end
    local ok, reason = self:_apply_remote(remote, context, { manual = false })
    if not ok then
        self:_persist(context.book_id, {
            last_sync_error = tostring(reason or "jump_failed"),
        })
        return false
    end
    if not self.pending_jump then
        self:_persist(context.book_id, {
            pending_remote_position = false,
            pending_remote_account = false,
            pending_remote_selected_at = false,
            last_sync_error = false,
        })
    end
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    -- Establish a position baseline as soon as ReaderReady fires. Without
    -- this, a quick first page turn inside OPEN_DELAY_SECONDS becomes the
    -- delayed baseline and is never marked dirty.
    local immediate_book_id = self.detect_book()
    if immediate_book_id and not is_mp_book(immediate_book_id) then
        self.current_book_id = tostring(immediate_book_id)
        local initial_position = self:capture_local()
        if initial_position then
            self.local_position = initial_position
            self:_persist(self.current_book_id, {
                last_local_position = initial_position,
            })
        end
    end

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason, context = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        if self.local_position
            and not PositionMapper.same_position(local_position, self.local_position) then
            self.dirty = true
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        if self:_apply_saved_remote(context) then return end
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:request_sync("book_open", {
            book_id = book_id,
            pull_current = true,
            immediate = true,
        })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:on_close_document()
    local position = self:capture_local() or self.local_position
    if position and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        -- Always preserve a dirty close snapshot. Unverified snapshots are
        -- reconciled against the cloud before upload, even if link state still
        -- appears online while the document is closing.
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    if position and self:_config().upload_on_close ~= true then
        self:_persist(position.book_id, { last_local_position = position })
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
end

function ProgressSync:on_suspend()
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.dirty
        and self:_config().upload_on_close == true then
        self:_upload_snapshot(position, "suspend", false)
    end
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true then
        self:_clear_verified("resume_recheck")
        self:request_sync("resume_recheck", {
            book_id = tostring(self.detect_book() or ""),
            pull_current = true,
            immediate = true,
        })
    end
end

function ProgressSync:_pending_candidates(options)
    options = options or {}
    local account_id = self:_account_id()
    local candidates = {}
    local summary = { pending = 0, conflicts = 0, actionable = 0 }
    if account_id == "" then return candidates, summary end
    for book_id, book in pairs(self.settings:get("books", {})) do
        local position = type(book) == "table" and book.pending_upload_position or nil
        if type(position) == "table"
            and tostring(book.pending_upload_account or "") == account_id
            and (not options.book_id
                or tostring(options.book_id) == tostring(book_id)) then
            summary.pending = summary.pending + 1
            local captured_at = tonumber(position.captured_at) or math.huge
            if not summary.book_id or captured_at < summary.captured_at then
                summary.book_id = tostring(book_id)
                summary.captured_at = captured_at
            end
            if book.pending_upload_blocked == true then
                summary.conflicts = summary.conflicts + 1
            end
            local unshown = not self.awaiting_choice_book_id and book.pending_upload_prompted ~= true
            if (book.pending_upload_blocked ~= true or options.manual or unshown)
                and (options.retry_now or (tonumber(book.pending_upload_retry_after) or 0) <= self.now()) then
                local candidate = {
                    book_id = tostring(book_id),
                    position = copy(position),
                    reason = book.pending_upload_reason,
                    decision = book.pending_upload_decision,
                    identity = self:_pending_identity(book_id, book),
                    captured_at = captured_at,
                }
                candidate.position.book_id = candidate.position.book_id
                    or candidate.book_id
                candidates[#candidates + 1] = candidate
                summary.actionable = summary.actionable + 1
            end
        end
    end
    table.sort(candidates, function(left, right)
        if left.captured_at == right.captured_at then
            return left.book_id < right.book_id
        end
        return left.captured_at < right.captured_at
    end)
    summary.book_id = candidates[1] and candidates[1].book_id or summary.book_id
    summary.captured_at = nil
    return candidates, summary
end

function ProgressSync:has_pending(options)
    local _, summary = self:_pending_candidates(options)
    return summary.pending > 0, summary
end

function ProgressSync:can_write_progress()
    if self.uploading or self.reconciling or self.pulling then
        return false, "busy"
    end
    if not self.is_online() then return false, "offline" end
    if self:_account_id() == "" then return false, "account_unavailable" end
    return true
end

function ProgressSync:awaiting_choice(book_id)
    if not self.awaiting_choice_book_id then return false end
    return book_id == nil
        or tostring(book_id) == tostring(self.awaiting_choice_book_id)
end

function ProgressSync:request_sync(reason, options, done)
    if type(options) == "function" then
        done, options = options, {}
    else
        options = type(options) == "table" and options or {}
    end
    if type(self.request_sync_callback) == "function" then
        local ok, result = pcall(
            self.request_sync_callback,
            tostring(reason or "progress_sync"),
            copy(options),
            done
        )
        if not ok then
            log("warn", "progress sync request callback failed:", tostring(result))
            return false
        end
        return result ~= false
    end
    if options.book_id or options.manual or options.pull_current
        or options.resume_conflicts then
        self.explicit_sync_request = {
            book_id = options.book_id and tostring(options.book_id) or nil,
            manual = options.manual == true,
            pull_current = options.pull_current == true,
            resume_conflicts = options.resume_conflicts == true,
        }
    end
    self.sync_callbacks = self.sync_callbacks or {}
    if type(done) == "function" then
        self.sync_callbacks[#self.sync_callbacks + 1] = done
    end
    self.sync_request_token = (self.sync_request_token or 0) + 1
    local token = self.sync_request_token
    local function run()
        if token ~= self.sync_request_token then return end
        local callbacks = self.sync_callbacks or {}
        self.sync_callbacks = {}
        local explicit = self.explicit_sync_request or {}
        self.explicit_sync_request = nil
        return self:reconcile_pending(function(result)
            for _, callback in ipairs(callbacks) do callback(result) end
        end, {
            reason = reason,
            book_id = explicit.book_id,
            manual = explicit.manual,
            pull_current = explicit.pull_current,
            resume_conflicts = explicit.resume_conflicts,
        })
    end
    if options.immediate then
        return run()
    else
        self.scheduler:scheduleIn(
            math.max(0, tonumber(options.delay) or 0), run)
    end
    return true
end

function ProgressSync:_present_pending_conflict(candidate, remote, relation)
    if not self:_pending_matches(candidate.book_id, candidate.identity) then
        return false
    end
    local book = self.get_book(candidate.book_id) or { book_id = candidate.book_id }
    if self:awaiting_choice(candidate.book_id) then return true, false end
    local can_show = type(self.on_choice) == "function" and not self.awaiting_choice_book_id
    self:_persist(candidate.book_id, {
        pending_upload_blocked = true,
        pending_upload_remote = remote,
        pending_upload_conflict_id = candidate.identity,
        pending_upload_prompted = can_show or type(self.on_choice) ~= "function",
        last_sync_error = "offline_progress_conflict",
    })
    self.state = "conflict"

    local resolved = false
    local function current()
        return not resolved
            and self:_pending_matches(candidate.book_id, candidate.identity)
    end
    local function continue_sync(reason, resume_conflicts)
        resolved = true
        if self.awaiting_choice_book_id == candidate.book_id then
            self.awaiting_choice_book_id = nil
        end
        self:request_sync(reason, {
            resume_conflicts = resume_conflicts == true,
        })
    end
    local context = {
        book_id = candidate.book_id,
        book_title = book.title or book.summary or candidate.book_id,
        local_position = copy(candidate.position),
        remote_position = copy(remote),
        source_conflict = remote.conflict == true,
        relation = relation,
        keep_local = function()
            if not current() then return false end
            self:_persist(candidate.book_id, {
                pending_upload_blocked = false,
                pending_upload_remote = false,
                pending_upload_conflict_id = false,
                pending_upload_prompted = false,
                pending_upload_decision = "local",
                last_sync_error = false,
            })
            resolved = true
            if self.awaiting_choice_book_id == candidate.book_id then
                self.awaiting_choice_book_id = nil
            end
            if tostring(self.detect_book() or "") == candidate.book_id then
                self.dirty = not PositionMapper.same_position(
                    candidate.position, remote)
                self:_mark_verified(
                    candidate.book_id,
                    "local_selected",
                    candidate.position,
                    remote
                )
            end
            self:_upload_snapshot(candidate.position, "network_restored", true, {
                identity = candidate.identity,
                confirmed_local = true,
                done = function()
                    self:request_sync("local_choice_finished", {
                        resume_conflicts = true,
                    })
                end,
            })
            return true
        end,
        use_remote = function()
            if not current() then return false end
            if not self.is_online() then
                self:request_sync("remote_choice_offline", {
                    delay = RECONCILE_RETRY_SECONDS,
                })
                return false
            end
            local current_book_id = tostring(self.detect_book() or "")
            local applied_to_open_book = false
            if current_book_id == candidate.book_id and self.get_document() then
                local _, _, open_context = self:capture_local()
                if not open_context then return false end
                local ok, apply_reason = self:_apply_remote(remote, open_context, {
                    manual = true,
                })
                if not ok then
                    self:_persist(candidate.book_id, {
                        last_sync_error = tostring(apply_reason or "jump_failed"),
                    })
                    return false
                end
                applied_to_open_book = self.pending_jump == nil
            end
            local remote_patch = {
                last_remote_position = remote,
                last_sync_error = false,
            }
            if applied_to_open_book then
                remote_patch.pending_remote_position = false
                remote_patch.pending_remote_account = false
                remote_patch.pending_remote_selected_at = false
            else
                remote_patch.pending_remote_position = remote
                remote_patch.pending_remote_account = self:_account_id()
                remote_patch.pending_remote_selected_at = self.now()
            end
            local cleared = self:_clear_pending_if_matches(
                candidate.book_id,
                candidate.identity,
                remote_patch
            )
            if not cleared then return false end
            self:_note_sync_ack()
            continue_sync("remote_choice_finished", true)
            return true
        end,
        later = function()
            if not current() then return false end
            continue_sync("conflict_deferred", false)
            return true
        end,
    }
    if can_show then
        self.awaiting_choice_book_id = candidate.book_id
        local ok, error_message = pcall(self.on_choice, context)
        if not ok then
            self.awaiting_choice_book_id = nil
            log("warn", "progress choice dialog failed:", tostring(error_message))
        end
    end
    log("warn", "offline progress held for conflict:",
        "book=", candidate.book_id,
        "relation=", relation)
    return true, can_show
end

function ProgressSync:reconcile_pending(done, options)
    options = options or {}
    local finished = false
    local function finish(result)
        if finished then return end
        finished = true
        self.reconciling = false
        self.reconnect_checking = false
        if type(done) == "function" then done(result) end
    end
    if self.uploading or self.reconciling or self.pulling then
        finish({ status = "deferred", reason = "busy" })
        return false
    end
    if not self.is_online() then
        local pending = self:has_pending({ book_id = options.book_id })
        if not pending and (options.manual == true or options.pull_current == true) then
            finish({ status = "deferred", reason = "offline" })
            return self:_pull({
                manual = options.manual == true,
                known_offline = true,
            })
        end
        finish({ status = "deferred", reason = "offline" })
        return false
    end
    local candidates, summary = self:_pending_candidates({
        book_id = options.book_id,
        manual = options.manual,
        retry_now = options.retry_now,
    })
    local selected = candidates[1]
    if not selected then
        local requested_book = tostring(options.book_id or "")
        local current_book = type(self.detect_book) == "function"
            and tostring(self.detect_book() or "") or ""
        if (options.manual == true or options.pull_current == true)
            and current_book ~= ""
            and (requested_book == "" or requested_book == current_book) then
            finish({ status = "pulling", book_id = current_book })
            return self:_pull({ manual = options.manual == true })
        end
        finish({ status = summary.pending > 0 and "deferred" or "idle",
            reason = summary.conflicts > 0 and "conflict_pending" or nil,
            summary = summary })
        return false
    end
    if selected.decision == "local" then
        self.reconciling = true
        self.reconnect_checking = true
        return self:_upload_snapshot(
            selected.position,
            "network_restored",
            false,
            {
                identity = selected.identity,
                confirmed_local = true,
                done = finish,
            }
        )
    end
    local book = self.get_book(selected.book_id)
    local chapters = type(book) == "table" and self.get_chapters(book) or nil
    if type(chapters) ~= "table" or #chapters == 0 then
        self:_persist(selected.book_id, {
            last_sync_error = "catalog_unavailable",
            pending_upload_retry_after = self.now() + RECONCILE_RETRY_SECONDS,
        })
        finish({ status = "error", book_id = selected.book_id,
            error = "catalog_unavailable" })
        self:request_sync("catalog_unavailable", {
            delay = RECONCILE_RETRY_SECONDS,
        })
        return false
    end

    self.reconciling = true
    self.reconnect_checking = true
    local started = self.run_online("progress_reconcile", function()
        local remote, fetch_error = self:_fetch_remote(selected.book_id, chapters)
        if not self:_pending_matches(selected.book_id, selected.identity) then
            finish({ status = "stale", book_id = selected.book_id })
            self:request_sync("stale_reconcile")
            return
        end
        if not remote then
            self:_persist(selected.book_id, {
                last_sync_error = tostring(fetch_error or "remote_unavailable"),
                pending_upload_retry_after = self.now() + RECONCILE_RETRY_SECONDS,
            })
            finish({ status = "error", book_id = selected.book_id,
                error = tostring(fetch_error or "remote_unavailable") })
            self:request_sync("remote_unavailable", {
                delay = RECONCILE_RETRY_SECONDS,
            })
            return
        end
        local relation = PositionMapper.compare(selected.position, remote,
            SOURCE_CONFLICT_THRESHOLD_PERCENT)
        if relation == "same" and remote.conflict ~= true then
            local cleared = self:_clear_pending_if_matches(selected.book_id, selected.identity, {
                last_local_position = selected.position,
                last_remote_position = remote,
                last_sync_error = false,
            })
            if cleared then self:_note_sync_ack() end
            self.state = "verified"
            finish({ status = "synced", book_id = selected.book_id })
            self:request_sync("matching_progress_finished")
            return
        end
        if (relation == "remote_ahead" or relation == "different" or remote.conflict == true)
            and self:_config().ask_on_conflict ~= false then
            local _, shown = self:_present_pending_conflict(
                selected, remote, relation)
            finish({ status = "conflict", book_id = selected.book_id,
                choice_required = shown == true })
            self:request_sync("continue_after_conflict")
            return
        end

        self:_persist(selected.book_id, {
            pending_upload_decision = "local",
            last_sync_error = false,
        })
        self:_upload_snapshot(selected.position, "network_restored", false, {
            identity = selected.identity,
            confirmed_local = true,
            inside_online = true,
            done = finish,
        })
    end)
    if not started then
        finish({ status = "deferred", book_id = selected.book_id,
            reason = "online_task_unavailable" })
        self:request_sync("reconcile_start_failed", {
            delay = RECONCILE_RETRY_SECONDS,
        })
    end
    return started == true
end

function ProgressSync:on_network_connected(done)
    return self:request_sync("network_connected", {
        immediate = true,
    }, done)
end

function ProgressSync:sync_now()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then return false end
    if not self.is_online() then
        self.state = "offline"
        self.notify("offline", {})
        return false
    end
    return self:request_sync("manual_sync", {
        book_id = tostring(book_id),
        manual = true,
        pull_current = true,
        immediate = true,
    })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
