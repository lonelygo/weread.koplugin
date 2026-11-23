local PluginUtil = require("weread.lib.plugin_util")
local SyncStatus = require("weread.lib.sync_status")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

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

function M:showOfflineSyncStatus()
    local status = SyncStatus.get(self)
    local lines = { summary(status) }
    if status.available then
        lines[#lines + 1] = ""
        lines[#lines + 1] = T(_("Reading time pending: %1 s"), status.pending_seconds)
        lines[#lines + 1] = T(_("Highlights and notes pending: %1"), status.pending_annotations)
        lines[#lines + 1] = T(_("Books with progress pending: %1"), status.pending_progress)
        for _i, book in ipairs(status.conflicts) do
            lines[#lines + 1] = T(_("Progress conflict: %1. Select Sync now to review."), book.title or book.book_id)
        end
        if status.unknown_seconds > 0 or status.unknown_annotations > 0 then
            lines[#lines + 1] = T(_("Unconfirmed by WeRead: %1 s, %2 annotations"),
                status.unknown_seconds, status.unknown_annotations)
            lines[#lines + 1] = _("Check these records in WeRead.")
        end
        if status.last_confirmed_at and status.state ~= "synced" then
            lines[#lines + 1] = T(_("Last fully confirmed: %1"), confirmedTime(status.last_confirmed_at))
        end
    end
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = _("WeRead sync status"), text = table.concat(lines, "\n"),
        show_menu = false, auto_para_direction = true,
        buttons_table = {{{
            text = _("Close"),
            callback = function() UIManager:close(viewer) end,
        }}},
    }
    UIManager:show(viewer)
end

return M
