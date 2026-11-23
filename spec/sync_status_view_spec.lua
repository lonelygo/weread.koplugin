package.path = "./?.lua;" .. package.path

package.loaded.gettext = { current_lang = "zh_CN" }
local I18n = require("weread.lib.i18n")
package.loaded["weread.lib.plugin_util"] = {
    tr = I18n.tr,
    T = function(template, ...)
        local values = { ... }
        return (template:gsub("%%(%d+)", function(n) return tostring(values[tonumber(n)]) end))
    end,
}
local status
package.loaded["weread.lib.sync_status"] = { get = function() return status end }
local opened
package.loaded["ui/uimanager"] = {
    show = function(_, viewer) opened = viewer end,
    close = function(_, viewer)
        assert(viewer == opened)
        opened = nil
    end,
}
package.loaded["ui/widget/textviewer"] = { new = function(_, options) return options end }
local view = require("weread.ui.sync_status")

status = { state = "signed_out" }
assert(view:getOfflineSyncStatusText() == "微信读书　未登录")
status = { state = "unavailable" }
view:showOfflineSyncStatus()
assert(opened.text == "暂时无法读取同步状态")

status = {
    state = "pending", available = true, pending_seconds = 480, pending_annotations = 2,
    pending_progress = 0, conflicts = {}, unknown_seconds = 0, unknown_annotations = 0,
}
assert(view:getOfflineSyncStatusText() == "微信读书　待传 8 分钟 · 2 条标注")
view:showOfflineSyncStatus()
assert(opened.title == "微信读书同步状态" and opened.text:find("480 秒", 1, true))
assert(opened.text:find("待传划线和笔记：2 条", 1, true))
opened.buttons_table[1][1].callback()
assert(not opened)

status.pending_seconds, status.pending_annotations, status.pending_progress = 0, 0, 1
assert(view:getOfflineSyncStatusText() == "微信读书　待传 1 本书的进度")
status.pending_seconds = 25
assert(view:getOfflineSyncStatusText():find("25 秒", 1, true))
status.state, status.conflict_count = "conflict", 1
status.conflicts = { { title = "山谷来信" } }
status.unknown_seconds, status.unknown_annotations = 30, 2
assert(view:getOfflineSyncStatusText() == "微信读书　1 本书需选择进度")
view:showOfflineSyncStatus()
assert(opened.text:find("《山谷来信》", 1, true) and opened.text:find("30 秒时长，2 条标注", 1, true))
status.state = "unknown"
assert(view:getOfflineSyncStatusText() == "微信读书　有记录待核对")
status.state = "idle"
assert(view:getOfflineSyncStatusText() == "微信读书　暂无待传记录")
status.state, status.last_confirmed_at = "synced", os.time()
assert(view:getOfflineSyncStatusText():find("已同步 · 今天 ", 1, true))
status.last_confirmed_at = os.time{year = 2017, month = 3, day = 6, hour = 12, min = 15}
assert(view:getOfflineSyncStatusText():find("2017-03-06 12:15", 1, true))
print("sync_status_view_spec: account summary, seconds, progress, conflicts, receipts and details passed")
