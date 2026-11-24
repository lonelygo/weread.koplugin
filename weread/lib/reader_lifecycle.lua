-- KOReader event lifecycle and reader-state orchestration.
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger").scoped("Prefetch")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")
local _ = PluginUtil.tr
local T = PluginUtil.T
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists
local log_error = PluginUtil.log_error

local M = {}

-- KOReader v2026.03 assumes ReaderHighlight's visible box cache has already
-- been populated when a tap arrives. During a fast document switch there is a
-- short window after ReaderReady where the cache is still nil, and the native
-- handler crashes while taking its length. Keep the compatibility guard local
-- to the reader instance and leave KOReader's normal handler unchanged once
-- the cache has been initialized.
function M:_installReaderHighlightTapGuard()
    local highlight = self.ui and self.ui.highlight
    if not highlight or type(highlight.onTap) ~= "function" then
        return false
    end
    if self._reader_highlight_guard_target == highlight then
        return true
    end
    self:_removeReaderHighlightTapGuard()

    local original = highlight.onTap
    self._reader_highlight_guard_target = highlight
    self._reader_highlight_original_on_tap = original
    highlight.onTap = function(highlight_self, arg, ges)
        local view_highlight = highlight_self.view and highlight_self.view.highlight
        if ges and view_highlight and type(view_highlight.visible_boxes) ~= "table" then
            view_highlight.visible_boxes = {}
        end
        return original(highlight_self, arg, ges)
    end
    return true
end

function M:_removeReaderHighlightTapGuard()
    local highlight = self._reader_highlight_guard_target
    local original = self._reader_highlight_original_on_tap
    if highlight and original and highlight.onTap ~= original then
        highlight.onTap = original
    end
    self._reader_highlight_guard_target = nil
    self._reader_highlight_original_on_tap = nil
end

function M:_installNativeAnnotationGuard()
    local annotation = self.ui and self.ui.annotation
    if not annotation or type(annotation.onAnnotationsModified) ~= "function" then
        return false
    end
    if self._native_annotation_guard_target == annotation then return true end
    self:_removeNativeAnnotationGuard()
    local original = annotation.onAnnotationsModified
    self._native_annotation_guard_target = annotation
    self._native_annotation_original = original
    annotation.onAnnotationsModified = function(annotation_self, items)
        local results = { original(annotation_self, items) }
        self:_captureLocalAnnotationSnapshot(items)
        return unpack(results)
    end
    return true
end

function M:_removeNativeAnnotationGuard()
    local annotation = self._native_annotation_guard_target
    local original = self._native_annotation_original
    if annotation and original and annotation.onAnnotationsModified ~= original then
        annotation.onAnnotationsModified = original
    end
    self._native_annotation_guard_target = nil
    self._native_annotation_original = nil
end

function M:onShowWeRead()
    self:showAccountStatus()
end

function M:onWeReadSyncProgress()
    local book_id = self:detectWeReadBook()
    if not book_id or WeRead.is_mp_book(book_id) then
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
        return false
    end
    if not self:requireLogin(true, false) then
        return false
    end
    self.progress_sync:sync_now()
    return true
end

function M:handleEndOfBook(status_self)
    local action = G_reader_settings and G_reader_settings:readSetting("end_document_action") or "pop-up"
    local book_id = self:detectWeReadBook()
    if not book_id then
        return self._orig_onEndOfBook(status_self)
    end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    local current_idx, current_ch, is_full_book = self:getChapterInfoFromFile(book, file)
    local next_ch = (not is_full_book) and current_idx and book.chapters[current_idx + 1]

    -- Automatic prefetch means the user's forward page turn is enough to keep
    -- reading. A ready cache is activated behind the stable reader path; an
    -- in-flight prefetch is promoted and opens as soon as its worker finishes.
    local next_uid = next_ch and tostring(
        next_ch.chapterUid or next_ch.chapterId or "") or nil
    local next_cached = next_uid and book.cached_chapters
        and book.cached_chapters[next_uid]
    if next_ch and (file_exists(next_cached)
        or self.downloader:isPrefetching(book, next_ch)) then
        self:openChapter(book, next_ch)
        return true
    end

    if action == "next_file" then
        if next_ch then
            self:openChapter(book, next_ch)
        else
            self:showInfo(_("You have reached the last chapter."))
        end
        return true
    end

    -- For every other end-of-document action, prefer our WeRead navigation
    -- dialog. This intentionally overrides the global end_document_action
    -- (pop-up, book_status, …) for WeRead books; fall back to the native
    -- handler only when the dialog cannot be built.
    if self:showEndOfBookDialog(book_id) then
        return true
    end

    return self._orig_onEndOfBook(status_self)
end

-- The physical spine is append-only: CREngine XPointers refer to fragment
-- numbers. When a hole is filled, turn across that boundary in catalog order.
function M:_installCatalogPageTurns(book_id)
    local ui, book = self.ui, self.settings:get("books", {})[book_id]
    local rolling, path = ui.rolling, ui.document and ui.document.file
    if not rolling or not path or not book or path ~= book.incremental_reader_file
        or self._original_page_turn then return end
    local desc = (book.annotation_documents or {})[path]
    local spine = desc and desc.chapters
    if not spine or #spine < 2 then return end
    local catalog = self:ensureChaptersLoaded(book)
    if not catalog then return end
    local indexes, logical, physical = {}, {}, {}
    for index, ch in ipairs(catalog) do indexes[tostring(ch.chapterUid or ch.chapterId)] = index end
    local sparse = false
    for slot, ch in ipairs(spine) do
        local index = indexes[tostring(ch.chapterUid or ch.chapterId)]
        if not index then return end
        logical[slot], physical[index] = index, slot
        if slot > 1 and logical[slot - 1] + 1 ~= index then sparse = true end
    end
    if not sparse then return end
    local original = rolling.onGotoViewRel
    self._original_page_turn = original
    rolling.onGotoViewRel = function(module, direction)
        if (direction ~= 1 and direction ~= -1) or not ui.toc or not ui.document then
            return original(module, direction)
        end
        local page = ui.document:getCurrentPage()
        local slot = ui.toc:getTocIndexByPage(page)
        local index = logical[slot]
        if not index then return original(module, direction) end
        local target = index + direction
        if module.view.view_mode == "page" then
            local destination = page + direction * ui.document:getVisiblePageNumberCount()
            if ui.document:hasHiddenFlows() then
                destination = direction == 1 and ui.document:getNextPage(page) or ui.document:getPrevPage(page)
            end
            if destination >= 1 and destination <= ui.document:getPageCount() then
                local next_slot = ui.toc:getTocIndexByPage(destination)
                if next_slot == slot or logical[next_slot] == target then
                    return original(module, direction)
                end
            elseif not logical[slot + direction] and not physical[target] then
                return original(module, direction)
            end
        else
            -- Scrolling accounts for overlap and footers in the native method.
            local result = original(module, direction)
            if not ui.document then return result end
            local next_slot = ui.toc:getTocIndexByPage(ui.document:getCurrentPage())
            if next_slot == slot or logical[next_slot] == target then return result end
        end
        local toc = ui.document:getToc()
        local dest_slot = physical[target]
        if dest_slot and toc[dest_slot] then
            if direction > 0 then
                module:onGotoXPointer(toc[dest_slot].xpointer)
            else
                local after = toc[dest_slot + 1]
                module:onGotoPage(after and math.max(toc[dest_slot].page, after.page - 1)
                    or ui.document:getPageCount())
            end
        elseif catalog[target] then
            self:openChapter(self.settings:get("books", {})[book_id] or book, catalog[target])
        elseif direction > 0 then
            self:handleEndOfBook(ui.status)
        end
        return true
    end
end

function M:onReaderReady()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    local perf = PluginUtil.reader_open_perf
    local opened = perf("reader_ready_begin", nil, "session=", self._reader_session_gen)
    self:_teardownThoughtInterception()
    self:_installReaderHighlightTapGuard()
    self:_installNativeAnnotationGuard()

    local weread_book_id = self:detectWeReadBook()
    -- Cache it so the per-tap handler (_onThoughtTap) does not have to re-scan
    -- the whole book table on every screen tap.
    self._current_weread_book_id = weread_book_id
    if weread_book_id then
        -- Always register the tap interception: even when annotations are hidden
        -- we must intercept taps on thought links to suppress the native footnote
        -- popup. Visibility is decided inside _onThoughtTap / applyAnnotationVisibility.
        self:_setupThoughtInterception()
        if self.settings:get("cache").show_annotations ~= false
            and not (self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations()) then
            local db_session_gen = self._reader_session_gen
            UIManager:scheduleIn(0.1, function()
                if db_session_gen ~= self._reader_session_gen
                    or self._current_weread_book_id ~= weread_book_id then
                    return
                end
                self:_ensureThoughtDB(weread_book_id)
            end)
        end
        self:_installCatalogPageTurns(weread_book_id)
        if not self._orig_onEndOfBook and self.ui.status and type(self.ui.status.onEndOfBook) == "function" then
            self._orig_onEndOfBook = self.ui.status.onEndOfBook
            self.ui.status.onEndOfBook = function(status_self)
                return self:handleEndOfBook(status_self)
            end
        end
    else
        if self._orig_onEndOfBook and self.ui.status then
            self.ui.status.onEndOfBook = self._orig_onEndOfBook
            self._orig_onEndOfBook = nil
        end
    end

    -- Register the EPUB-safe external annotation prototype for any CREngine
    -- document. The view module remains empty until the user adds a prototype
    -- range, so unsupported/non-participating books pay only an empty module
    -- function call during paint.
    local prepared = perf("reader_setup", opened, "book_id=", weread_book_id or "local")
    self:_setupXPointerOverlayPrototype()
    perf("overlay_setup", prepared)
    if self.onUnifiedAnnotationsReady then self:onUnifiedAnnotationsReady() end

    local annotations_ready = perf("annotations_ready", opened)
    local jump = self.takeRequestedChapter and self:takeRequestedChapter(self.ui.document.file)
    if weread_book_id and jump then
        local pending_book = self.settings:get("books", {})[tostring(weread_book_id)]
        if pending_book then self:_gotoIncrementalChapter(pending_book, jump, self.ui) end
    end
    self.progress_sync:on_reader_ready()
    if weread_book_id then
        local baseline_session = self._reader_session_gen
        UIManager:scheduleIn(0.3, function()
            if baseline_session == self._reader_session_gen then
                self:_captureLocalAnnotationSnapshot(nil)
            end
        end)
    end
    local prefetch_session_gen = self._reader_session_gen
    UIManager:scheduleIn(0.2, function()
        if prefetch_session_gen ~= self._reader_session_gen then return end
        self:maybePrefetchNextChapter(weread_book_id)
    end)
    local _started, _title, reason = self.read_report:on_reader_ready()
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
    perf("reader_services", annotations_ready)
    perf("reader_ready_total", opened)
end

function M:onPageUpdate()
    self.progress_sync:on_page_update()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:_offlineAnnotationCoordinator()
    if self.offline_annotations then return self.offline_annotations end
    if not self.library_db or not self.client or not self.prefetch_worker then
        return nil
    end
    local ok_position, UploadPosition = pcall(
        require, "weread.lib.annotation_upload_position")
    if not ok_position then return nil end
    local OfflineAnnotations = require("weread.lib.offline_annotations")
    self.offline_annotations = OfflineAnnotations:new {
        library_db = self.library_db,
        settings = self.settings,
        client = self.client,
        worker = self.prefetch_worker,
        scheduler = UIManager,
        resolver = UploadPosition,
        gate = function(kind, context) return self.offline_sync:gate(kind, context) end,
        request_sync = function(reason, context) return self.offline_sync:request(reason, context) end,
        is_online = function() return self:isNetworkConnected() end,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_book = function(book_id)
            return self.settings:get("books", {})[tostring(book_id)]
        end,
        get_store = function()
            return self._annotationStore and self:_annotationStore() or nil
        end,
    }
    return self.offline_annotations
end

function M:_captureLocalAnnotationSnapshot(modified_items)
    local book_id = self._current_weread_book_id or self:detectWeReadBook()
    local document = self.ui and self.ui.document
    local path = document and document.file
    local annotations = self.ui and self.ui.annotation
        and self.ui.annotation.annotations
    if not book_id or not path or type(annotations) ~= "table" then
        return false
    end
    local coordinator = self:_offlineAnnotationCoordinator()
    if coordinator then
        return coordinator:capture(
            tostring(book_id), tostring(path), annotations, modified_items)
    end
    if self.library_db
        and type(self.library_db.putLocalAnnotationSnapshot) == "function" then
        return self.library_db:putLocalAnnotationSnapshot(
            tostring(book_id), tostring(path), annotations)
    end
    return false
end

-- KOReader emits this event for highlight creation, note edits and removals.
-- An empty snapshot records the removal of the last managed annotation too.
function M:onAnnotationsModified(items)
    self:_captureLocalAnnotationSnapshot(items)
end

function M:onPosUpdate()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
end

function M:onCloseDocument()
    -- Capture the immutable local position while the document is still alive.
    -- The network upload is scheduled; stopping ReadReport below also frees any
    -- in-flight report slot before that scheduled upload begins.
    self.progress_sync:on_close_document()
    self:_captureLocalAnnotationSnapshot()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self.downloader:cancelPrefetch("document_closed")
    if self._cancelUnifiedAnnotationSync then self:_cancelUnifiedAnnotationSync() end
    self._annotation_pending_prefetch = nil
    self._annotation_context = nil
    self._current_weread_book_id = nil
    self:_teardownThoughtInterception()
    self:_teardownXPointerOverlayPrototype()
    self:_removeReaderHighlightTapGuard()
    self:_removeNativeAnnotationGuard()

    if self._original_page_turn and self.ui.rolling then
        self.ui.rolling.onGotoViewRel = self._original_page_turn
        self._original_page_turn = nil
    end
    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    self.read_report:on_close_document()
    if self.offline_sync:deactivate() then
        -- ReaderUI:showFileManager may reuse an existing manager.
        local module = package.loaded["apps/filemanager/filemanager"]
        local manager = type(module) == "table" and module.instance
        if manager and manager.weread and manager.weread.offline_sync then
            manager.weread.offline_sync:activate()
        end
    end
end

function M:onNetworkConnected()
    self:_captureLocalAnnotationSnapshot(nil)
    self.offline_sync:request("network_connected")
end

function M:onNetworkDisconnected()
    self.offline_sync:disconnected()
end

function M:showPrefetchNotice(text, timeout)
    if self.settings:get("cache").show_prefetch_notifications == false then
        return
    end
    self:showTransientInfo(text, timeout or 1)
end

function M:maybePrefetchNextChapter(book_id)
    local cache = self.settings:get("cache")
    if cache.auto_prefetch_next_chapter ~= true or not book_id then
        self.downloader:cancelPrefetch("prefetch_not_applicable")
        return false
    end

    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    local chapters = self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    if not book or not chapters or not file then
        self.downloader:cancelPrefetch("prefetch_context_missing")
        return false
    end
    local chapter_info = { self:getChapterInfoFromFile(book, file) }
    local current_index, is_full_book = chapter_info[1], chapter_info[3]
    local next_chapter = not is_full_book and current_index
        and chapters[current_index + 1] or nil
    if not next_chapter then
        self.downloader:cancelPrefetch("no_next_chapter")
        return false
    end

    local next_uid = tostring(next_chapter.chapterUid or next_chapter.chapterId or "")
    local cached = book.cached_chapters and book.cached_chapters[next_uid]
    if file_exists(cached) then
        if self.prefetchChapterAnnotations then self:prefetchChapterAnnotations(book, next_chapter) end
        if not self.downloader:isPrefetching(book, next_chapter) then
            self.downloader:cancelPrefetch("next_chapter_cached")
        end
        return true
    end
    if self.downloader:isPrefetching(book, next_chapter) then
        return true
    end

    local title = next_chapter.title or T(_("Chapter %1"), next_uid)
    return self.downloader:start(book, { next_chapter }, "chapter", {
        single_chapter = true,
        include_annotations = false,
        prefetch = true,
        start_delay = cache.show_prefetch_notifications == false and 0.1 or 0.7,
        silent_completion = true,
        offer_read = false,
        on_start = function()
            logger.info("started:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title)
            self:showPrefetchNotice(
                T(_("Prefetching next chapter: %1"), title), 0.5)
        end,
        on_complete = function(ok, value)
            if ok then
                -- A promoted prefetch opens the new file immediately. Its
                -- ReaderReady path can download source data for that file
                -- when both prefetch switches are enabled, so
                -- do not fork an annotation worker only to cancel it during
                -- the document switch.
                if self.prefetchChapterAnnotations
                    and not self.downloader:isPromotedPrefetch(book, next_chapter) then
                    self:prefetchChapterAnnotations(book, next_chapter)
                end
                logger.info("succeeded:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title)
                self:showPrefetchNotice(T(_("Next chapter prefetched: %1"), title))
                return
            end
            local retry_requested = self.downloader:isPromotedPrefetch(
                book, next_chapter)
            if value == "cancelled" or value == "document_closed"
                or value == "replaced" or value == "manual_download"
                or value == "setting_disabled" or value == "prefetch_not_applicable"
                or value == "prefetch_context_missing" or value == "no_next_chapter"
                or value == "next_chapter_cached" then
                logger.info("ended without completion:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title,
                    "reason=", tostring(value))
                return
            end
            local reason = value == "offline" and _("Network is not connected")
                or value == "low_memory" and _("Not enough free memory; prefetch skipped")
                or value == "worker_unavailable" and _("Background prefetch is unavailable")
                or value == "worker_timeout" and _("Background prefetch timed out")
                or display_error(value)
            logger.warn("failed:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title,
                "reason=", log_error(value))
            self:showPrefetchNotice(T(_("Next chapter prefetch failed: %1"), reason))
            if retry_requested then
                local source_file = file
                local retry_cache = self.settings:get("cache")
                local retry_delay = retry_cache.show_prefetch_notifications == false
                    and 0.1 or 1.1
                UIManager:scheduleIn(retry_delay, function()
                    if self.ui.document and self.ui.document.file == source_file then
                        self:downloadChapterAndRead(book, next_chapter)
                    end
                end)
            end
        end,
    })
end

function M:maybeStartReadReport()
    return self.read_report:maybe_start("menu")
end

function M:stopReadReport(reason)
    self.read_report:stop(reason or "explicit_stop")
end

function M:onSuspend()
    self.offline_sync:pause()
    if self._cancelUnifiedAnnotationSync then self:_cancelUnifiedAnnotationSync() end
    self._annotation_pending_prefetch = nil
    self.progress_sync:on_suspend()
    self.read_report:on_suspend()
end

function M:onResume()
    self.offline_sync:resume()
    self.progress_sync:on_resume()
    self.read_report:on_resume()
end

function M:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local dir = Content.book_resolved_dir(
                self.settings, book_id, book):gsub("/+$", "") .. "/"
            if file == book.cached_file or file:sub(1, #dir) == dir then
                return book_id
            end
        end
    end

    -- Require a path boundary after the cache directory.
    local prefix = self.settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        return rest:match("^([^/]+)")
    end
    return nil
end

function M:ensureChaptersLoaded(book)
    if not book then return nil end
    if type(book.chapters) == "table" and #book.chapters > 0 then
        local book_id = book.book_id or book.bookId
        if self.library_db and book_id then
            self.library_db:putChapters(book_id, book.chapters)
        end
        local catalog_path = Content.catalog_cache_path(self.settings, book)
        if catalog_path and not file_exists(catalog_path) then
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, book.chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    log_error(cache_err))
            end
        end
        return book.chapters
    end

    local book_id = book.book_id or book.bookId
    local chapters = Content.load_catalog_cache(
        self.client, self.settings, book)
    if type(chapters) == "table" and #chapters > 0 then
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
        return chapters
    end

    chapters = self.library_db and self.library_db:getChapters(book_id) or nil
    if type(chapters) == "table" and #chapters > 0 then
        book.chapters = chapters
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:",
                log_error(cache_err))
        end
        return chapters
    end
    return nil
end

-- cached_file historically pointed at either a full-book EPUB or the most
-- recently downloaded single chapter. Treat it as a legacy full-book path only
-- when it does not map to exactly one chapter; new downloads use the explicit
-- cached_full_book field.
function M:getFullBookCachePath(book)
    if type(book) ~= "table" then return nil end
    if type(book.cached_full_book) == "string"
        and book.cached_full_book ~= "" and file_exists(book.cached_full_book) then
        return book.cached_full_book
    end
    local legacy = book.cached_file
    if type(legacy) ~= "string" or legacy == "" then return nil end
    if legacy == book.incremental_reader_file then return nil end
    local mapped_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if path == legacy then mapped_count = mapped_count + 1 end
    end
    if mapped_count == 1 then return nil end
    return legacy
end

-- An incremental EPUB can contain several cached chapters. Its progress
-- fraction is relative to the current chapter's TOC interval.
function M:gotoProgressFraction(fraction, context)
    local ui = self.ui
    local document = ui and ui.document
    if not document then return false, "document_unavailable" end
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local book = context and context.book
    if book and context.path and book.incremental_reader_file == context.path then
        if document.file ~= context.path then return false, "document_changed" end
        local _, _, _, bounds = self:getChapterInfoFromFile(book, context.path)
        if not bounds or not bounds.start_page or not bounds.stop_page
            or bounds.stop_page <= bounds.start_page then
            return false, "chapter_pages_unavailable"
        end
        local page = math.min(bounds.stop_page - 1, bounds.start_page
            + math.floor(fraction * (bounds.stop_page - bounds.start_page)))
        if not ui.rolling or not ui.rolling.onGotoPage then return false, "reader_unavailable" end
        return pcall(ui.rolling.onGotoPage, ui.rolling, page)
    end
    if ui.rolling and ui.rolling.onGotoPercent then
        return pcall(ui.rolling.onGotoPercent, ui.rolling, fraction * 100)
    end
    return pcall(function()
        ui:handleEvent(require("ui/event"):new("GotoPercent", fraction * 100))
    end)
end

-- Retrieves chapter information for the given file path.
--
-- Parameters:
--   book: The book object from settings containing chapters and cached_chapters.
--   file_path: The absolute path of the currently open document.
--
-- Returns:
--   current_idx (number or nil): The index of the current chapter within book.chapters, if it's a single chapter file.
--   current_ch (table or nil): The chapter object of the current chapter, if it's a single chapter file.
--   is_full_book (boolean): True if the file maps to multiple chapters (e.g. a combined EPUB), false otherwise.
function M:getChapterInfoFromFile(book, file_path)
    if not book or not file_path or not book.chapters then
        return nil, nil, false
    end

    local descriptor = book.annotation_documents and book.annotation_documents[file_path]
    local subset = descriptor and descriptor.chapters and #descriptor.chapters > 1
        and #descriptor.chapters < #book.chapters
    if file_path == book.incremental_reader_file or subset then
        local document = self.ui and self.ui.document
        local page = document and document.getCurrentPage
            and document:getCurrentPage() or nil
        local toc_index = self.ui and self.ui.toc and page
            and self.ui.toc.getTocIndexByPage
            and self.ui.toc:getTocIndexByPage(page) or nil
        local item = toc_index and descriptor and descriptor.chapters
            and descriptor.chapters[toc_index] or nil
        local active_uid = item and (item.chapterUid or item.chapterId)
            or book.active_chapter_uid
        for index, chapter in ipairs(book.chapters) do
            if tostring(chapter.chapterUid or chapter.chapterId)
                == tostring(active_uid) then
                local toc = document and document.getToc
                    and document:getToc() or nil
                local start_page = toc_index and toc and toc[toc_index]
                    and tonumber(toc[toc_index].page) or nil
                local stop_page = toc_index and toc and toc[toc_index + 1]
                    and tonumber(toc[toc_index + 1].page) or nil
                if not stop_page and document and document.getPageCount then
                    stop_page = tonumber(document:getPageCount()) and
                        tonumber(document:getPageCount()) + 1 or nil
                end
                local chapter_fraction
                if page and start_page and stop_page and stop_page > start_page then
                    chapter_fraction = math.max(0, math.min(1,
                        (page - start_page) / (stop_page - start_page)))
                end
                return index, chapter, false, {
                    incremental = true,
                    chapter_fraction = chapter_fraction,
                    start_page = start_page,
                    stop_page = stop_page,
                }
            end
        end
    end

    local mapped_count = 0
    local current_uid = nil
    for uid, path in pairs(book.cached_chapters or {}) do
        if path == file_path then
            mapped_count = mapped_count + 1
            current_uid = uid
        end
    end

    local full_book_path = self:getFullBookCachePath(book)
    if full_book_path == file_path then
        return nil, nil, true
    end

    local is_full_book = (mapped_count > 1)

    if mapped_count == 1 and current_uid then
        for i, ch in ipairs(book.chapters) do
            if tostring(ch.chapterUid) == tostring(current_uid) then
                return i, ch, is_full_book
            end
        end
    end

    return nil, nil, is_full_book
end

function M:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return M
