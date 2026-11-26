local PluginUtil = require("weread.lib.plugin_util")
local SyncStatus = require("weread.lib.sync_status")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}
local addStatusText

local function confirmedTime(timestamp)
    local date = os.date("%Y-%m-%d", timestamp)
    if date == os.date("%Y-%m-%d") then
        return T(_("Today at %1"), os.date("%H:%M", timestamp))
    end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

local function summary(status)
    if status.state == "signed_out" then return _("Not logged in") end
    if status.state == "unavailable" then return _("Sync status unavailable") end
    if status.state == "conflict" then
        return T(_("Progress conflicts: %1"), status.conflict_count)
    end
    if status.state == "unknown" then return _("Records need verification") end
    if status.state == "review" then return _("Records need review") end
    if status.state == "pending" then
        local parts = {}
        if status.pending_seconds >= 60 then
            parts[#parts + 1] = T(_("%1 min"), math.floor(status.pending_seconds / 60))
        elseif status.pending_seconds > 0 then
            parts[#parts + 1] = T(_("%1 s"), status.pending_seconds)
        end
        if status.pending_annotations > 0 then
            parts[#parts + 1] = T(_("annotations: %1"), status.pending_annotations)
        end
        if status.pending_progress > 0 then
            parts[#parts + 1] = T(_("book progress: %1"), status.pending_progress)
        end
        if (status.review_time_count or 0) > 0 or (status.unknown_annotations or 0) > 0 then
            parts[#parts + 1] = T(_("to review: %1"),
                (status.review_time_count or 0) + (status.unknown_annotations or 0))
        end
        return T(_("Pending %1"), table.concat(parts, " · "))
    end
    if status.state == "synced" then
        return T(_("Synced · %1"), confirmedTime(status.last_confirmed_at))
    end
    return _("Nothing pending")
end

function M:getOfflineSyncStatusText()
    return T(_("WeRead  %1"), summary(SyncStatus.get(self)))
end

local result_messages = {
    uploaded = "Sync complete. WeRead confirmed the upload.",
    empty = "No records are waiting to upload.",
    matched = "Reading progress matches WeRead. Nothing to upload.",
    offline = "Offline. Pending records stay on this device.",
    unreachable = "Could not reach WeRead. Check your connection and login, then try again.",
    authentication_required = "WeRead declined this login. Open Saved account in the WeRead menu to scan again.",
    service_unreachable = "The WeRead connection failed or timed out. Your records are saved.",
    service_busy = "WeRead is temporarily unavailable or limiting requests. Your records are saved.",
    response_rejected = "WeRead responded but declined the progress request.",
    response_unrecognized = "WeRead responded without recognizable reading progress.",
    probe_low_memory = "KOReader had too little memory to run the connection check.",
    probe_timeout = "The background connection check timed out.",
    probe_worker_unavailable = "KOReader could not start the background connection check.",
    probe_worker_failed = "The background connection check did not finish.",
    unconfirmed = "WeRead did not confirm the upload.",
    progress_failed = "Could not sync reading progress with WeRead.",
    unknown = "The upload result is uncertain. Check these records in WeRead before retrying.",
    conflict = "Sync paused. Choose which reading progress to keep to continue.",
    pending = "Pending records are saved. Open Review records for details by book.",
    partial = "WeRead confirmed part of the upload. The remaining records are listed below.",
    locate_annotations = "The remaining annotations need a location. Review records shows the book and reason.",
    login_renewed = "WeRead renewed the login. Pending records will be tried again.",
    time_position_pending = "Reading time is saved. The book's current cloud position could not be confirmed.",
    uploaded_with_review = "New records were uploaded. Some earlier records still need review.",
    review = "Some records need review before they can be handled.",
    unavailable = "Sync status unavailable",
}

function M:showManualSyncResult(reason, status)
    if reason == "started" then
        local Notification = require("ui/widget/notification")
        Notification:notify(_("Syncing with WeRead…"), Notification.SOURCE_ALWAYS_SHOW)
        return
    end
    status = status or SyncStatus.get(self)
    local message = _(result_messages[reason] or result_messages.pending)
    if (status.newly_confirmed_seconds or 0) > 0 then
        message = message .. "\n" .. T(_("Reading time confirmed during this sync: %1 s"), status.newly_confirmed_seconds)
    end
    if status.available and (status.state == "pending" or status.state == "unknown" or status.state == "conflict") then
        if status.pending_seconds > 0 and self.settings:get("read_report", {}).enabled ~= true then
            message = message .. "\n" .. _("Reading time reporting is turned off.")
        end
        if status.pending_annotations > 0 and self.settings:get("sync", {}).upload_annotations == false then
            message = message .. "\n" .. _("Annotation uploading is turned off.")
        end
        if status.state == "pending" or status.state == "conflict" then
            message = message .. "\n" .. summary(status)
        end
    end
    if (status.review_time_count or 0) > 0 or (status.unknown_annotations or 0) > 0 then
        message = message .. "\n" .. T(_("Records waiting for review: %1"),
            (status.review_time_count or 0) + (status.unknown_annotations or 0))
    end
    if (status.unlocated_annotations or 0) > 0 then
        message = message .. "\n" .. T(_("%1 annotations need a location. Open the original book to locate them."), status.unlocated_annotations)
    end
    self:showInfo(message)
end

local function lastAttemptText(db)
    local last = db and db.lastManualSyncResult and db:lastManualSyncResult()
    if last and last.at and result_messages[last.reason] then
        return T(_("Last manual sync (%1): %2"), confirmedTime(last.at), _(result_messages[last.reason]))
    end
end

local function lastReceiptText(db)
    local receipts = db:readTimeReceipts()
    if receipts.last_time then
        return T(_("Last reading-time receipt: %1"), confirmedTime(receipts.last_time))
    end
end

local function details(status, db)
    if not status.available then return summary(status) end
    local lines = {}
    if status.state ~= "pending" then
        lines = { summary(status), "" }
    end
    lines[#lines + 1] = T(_("Reading time pending: %1 s"), status.pending_seconds)
    lines[#lines + 1] = T(_("Highlights and notes pending: %1"), status.pending_annotations)
    if (status.unlocated_annotations or 0) > 0 then
        lines[#lines + 1] = T(_("%1 annotations need a location. Open the original book to locate them."), status.unlocated_annotations)
    end
    lines[#lines + 1] = T(_("Books with progress pending: %1"), status.pending_progress)
    for _i, book in ipairs(status.conflicts) do
        lines[#lines + 1] = T(_("Progress conflict: %1"), book.title or book.book_id)
    end
    if #status.conflicts > 0 then
        lines[#lines + 1] = _("Select Upload now to choose which progress to keep.")
    end
    if status.unknown_seconds > 0 or status.unknown_annotations > 0 then
        lines[#lines + 1] = T(_("Unconfirmed by WeRead: %1 s, %2 annotations"),
            status.unknown_seconds, status.unknown_annotations)
        lines[#lines + 1] = _("Check these records in WeRead.")
    end
    if (status.rejected_seconds or 0) > 0 then
        lines[#lines + 1] = T(_("Rejected reading time: %1 s"), status.rejected_seconds)
        lines[#lines + 1] = _("Rejected records will not block newer uploads.")
    end
    if db and (status.pending_seconds or 0) > 0 then
        local receipt = lastReceiptText(db)
        if receipt then lines[#lines + 1] = receipt end
    end
    if status.last_confirmed_at and status.state ~= "synced" then
        lines[#lines + 1] = T(_("Last fully confirmed: %1"), confirmedTime(status.last_confirmed_at))
    end
    local last = lastAttemptText(db)
    if last then lines[#lines + 1] = last end
    return table.concat(lines, "\n")
end

local function reviewText(record, index, total)
    local state = record.state == "unknown"
        and _("WeRead reply was not received") or _("WeRead rejected this record")
    local when = record.created_at and record.created_at > 0
        and os.date("%Y-%m-%d %H:%M", record.created_at) or _("Unknown time")
    return table.concat({
        T(_("Record %1 of %2"), index, total),
        T(_("Book: %1"), record.title or record.book_id),
        T(_("Reading time: %1 s"), record.elapsed_seconds or 0),
        T(_("Recorded at: %1"), when),
        T(_("Status: %1"), state),
        T(_("Reason: %1"), record.reason or _("Unknown")),
    }, "\n")
end

function M:showReadTimeReview(records, index)
    records = records or SyncStatus.get(self).review_records or {}
    index = math.max(1, math.min(tonumber(index) or 1, #records))
    if #records == 0 then
        self:showInfo(_("No reading-time records need review."))
        return
    end
    local UIManager = require("ui/uimanager")
    local record = records[index]
    local dialog
    local function refresh()
        local latest = SyncStatus.get(self).review_records or {}
        self:showReadTimeReview(latest, math.min(index, #latest))
    end
    local function confirmAction(kind)
        local retry = kind == "retry"
        local warning = retry
            and _("Retrying may add the same reading time twice if WeRead received the earlier request. Continue only after checking WeRead.")
            or _("Marking this handled removes it from the local review list without uploading it. Continue?")
        local confirm
        confirm = require("ui/widget/confirmbox"):new{
            text = warning,
            ok_text = retry and _("Retry anyway") or _("Mark handled"),
            ok_callback = self:safeCallback(retry and _("Retry anyway") or _("Mark handled"), function()
                UIManager:close(confirm)
                local ok
                if retry then
                    ok = self.library_db:retryReadTimeReview(record)
                else
                    ok = self.library_db:dismissReadTimeReview(record)
                end
                if not ok then
                    self:showInfo(_("The record changed before it could be updated. Reopen sync status."))
                    return
                end
                UIManager:close(dialog)
                SyncStatus.invalidateOffline(self.settings)
                if retry then
                    self:syncOfflineNow()
                else
                    refresh()
                end
            end),
        }
        UIManager:show(confirm)
    end
    dialog = require("ui/widget/buttondialog"):new{
        title = _("Reading-time review"),
        use_info_style = false,
        width_factor = 0.86,
        buttons = {
            {
                { id = "previous", text = _("Previous"), enabled = index > 1,
                    callback = function() UIManager:close(dialog); self:showReadTimeReview(records, index - 1) end },
                { id = "next", text = _("Next"), enabled = index < #records,
                    callback = function() UIManager:close(dialog); self:showReadTimeReview(records, index + 1) end },
            },
            {
                { id = "close", text = _("Close"), callback = function() UIManager:close(dialog) end },
                { id = "handled", text = _("Mark handled"), callback = function() confirmAction("dismiss") end },
                { id = "retry", text = _("Retry anyway"), callback = function() confirmAction("retry") end },
            },
        },
    }
    addStatusText(dialog, reviewText(record, index, #records))
    UIManager:show(dialog)
end

local location_reasons = {
    missing_source = "The chapter source text is missing.",
    missing_source_version = "The source edition could not be verified.",
    unmapped_document = "The local file could not be matched to its WeRead edition.",
    unmapped_chapter = "The original chapter could not be identified.",
    ambiguous_chapter = "More than one chapter matches.",
    ambiguous_selection = "The selection could not be matched uniquely.",
    cross_chapter_selection = "The selection spans multiple chapters.",
    missing_selection = "The saved selection is incomplete.",
    position_pending = "A verified text location is not available yet.",
}

local function hasRecords(status)
    return status.state == "pending" or status.state == "conflict"
        or status.state == "unknown" or status.state == "review"
end

function M:showPendingSyncReview()
    local status = SyncStatus.get(self)
    if not hasRecords(status) then
        self:showInfo(summary(status))
        return
    end
    local held = status.review_time_count or 0
    if held > 0 and (status.pending_seconds or 0) == 0 and (status.pending_annotations or 0) == 0
        and (status.pending_progress or 0) == 0 and (status.unknown_annotations or 0) == 0 then
        self:showReadTimeReview(status.review_records, 1)
        return
    end
    local lines = {}
    for _i, book in ipairs(SyncStatus.reviewBooks(self, status)) do
        if #lines > 0 then lines[#lines + 1] = "" end
        lines[#lines + 1] = T(_("Book: %1"), book.title)
        if (book.seconds or 0) > 0 then
            lines[#lines + 1] = T(_("Reading time: %1 s in %2 queued segments"), book.seconds, book.segments)
        end
        if book.progress then lines[#lines + 1] = _("Reading progress is pending for this book.") end
        if (book.annotations or 0) > 0 then
            lines[#lines + 1] = T(_("Highlights and notes pending: %1"), book.annotations)
        end
        for _j, issue in ipairs(book.issues) do
            lines[#lines + 1] = T(_("%1 annotations without a location: %2"),
                issue.count, _(location_reasons[issue.reason] or location_reasons.position_pending))
            local file = issue.document_path and issue.document_path:match("([^/]+)$")
            if file then lines[#lines + 1] = T(_("Original file: %1"), file) end
        end
    end
    if (status.unknown_annotations or 0) > 0 then
        lines[#lines + 1] = T(_("WeRead has not confirmed %1 annotations. Check them in WeRead."), status.unknown_annotations)
    end
    if (status.pending_seconds or 0) > 0 then
        lines[#lines + 1] = lastReceiptText(self.library_db)
            or _("No reading-time receipt has been recorded for this account yet.")
    end
    if held > 0 then lines[#lines + 1] = T(_("Records waiting for review: %1"), held) end
    if #lines == 0 then lines[1] = summary(status) end
    local UIManager = require("ui/uimanager")
    local dialog
    local actions = {{ id = "close", text = _("Close"), callback = function() UIManager:close(dialog) end }}
    if held > 0 then
        actions[#actions + 1] = { id = "review_time", text = _("Review reading time"), callback = function()
            UIManager:close(dialog)
            self:showReadTimeReview()
        end }
    end
    dialog = require("ui/widget/buttondialog"):new{
        title = _("Pending sync records"), use_info_style = false, width_factor = 0.86, buttons = { actions },
    }
    addStatusText(dialog, table.concat(lines, "\n"))
    UIManager:show(dialog)
end

addStatusText = function(dialog, text)
    local width = dialog:getAddedWidgetAvailableWidth()
    local face = require("ui/font"):getFace("cfont", 20)
    local body = require("ui/widget/textboxwidget"):new{
        text = text, width = width, face = face, auto_para_direction = true,
    }
    -- Long book titles and multiple progress conflicts can wrap onto many lines.
    local limit = math.floor(require("device").screen:getHeight() * 0.45)
    if body:getSize().h > limit then
        body:free()
        body = require("ui/widget/scrolltextwidget"):new{
            text = text, width = width, face = face, auto_para_direction = true,
            height = limit, dialog = dialog,
        }
    end
    body.not_focusable = true
    dialog:addWidget(body)
end

function M:showOfflineSyncStatus()
    local UIManager = require("ui/uimanager")
    local status = SyncStatus.get(self)
    local dialog
    local buttons = {{
        {
            id = "close", text = _("Close"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            id = "upload", text = _("Upload now"), enabled = status.signed_in,
            callback = self:safeCallback(_("Upload now"), function()
                UIManager:close(dialog)
                self:syncOfflineNow()
            end),
        },
    }}
    if hasRecords(status) then
        table.insert(buttons, 1, {{
            id = "review", text = _("Review records"),
            callback = function()
                UIManager:close(dialog)
                self:showPendingSyncReview()
            end,
        }})
    end
    dialog = require("ui/widget/buttondialog"):new{
        title = _("WeRead sync status"),
        use_info_style = false,
        width_factor = 0.82,
        buttons = buttons,
    }
    addStatusText(dialog, details(status, self.library_db))
    UIManager:show(dialog)
end

return M
