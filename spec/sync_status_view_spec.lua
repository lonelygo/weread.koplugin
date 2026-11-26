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
local review_books = {}
package.loaded["weread.lib.sync_status"] = {
    get = function() return status end,
    invalidateOffline = function() end,
    reviewBooks = function() return review_books end,
}
local opened
local windows = {}
package.loaded["ui/uimanager"] = {
    show = function(_, viewer)
        windows[#windows + 1] = viewer
        opened = viewer
    end,
    close = function(_, viewer)
        local found
        for index = #windows, 1, -1 do
            if windows[index] == viewer then found = index; break end
        end
        assert(found, "closing a dialog outside the window stack")
        table.remove(windows, found)
        opened = windows[#windows]
    end,
}
package.loaded.device = { screen = { getHeight = function() return 800 end } }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/widget/buttondialog"] = {
    new = function(_, options)
        options.getAddedWidgetAvailableWidth = function() return 450 end
        options.addWidget = function(dialog, body) dialog.body = body end
        return options
    end,
}
package.loaded["ui/widget/confirmbox"] = package.loaded["ui/widget/buttondialog"]
package.loaded["ui/widget/textboxwidget"] = {
    new = function(_, options)
        options.getSize = function() return { h = 120 } end
        return options
    end,
}
local view = require("weread.ui.sync_status")
local uploads = 0
local shown_message
view.settings = { get = function(_self, _key, default) return default end }
local retry_ids, handled_ids = {}, {}
view.library_db = {
    readTimeReceipts = function() return { count = 0 } end,
    retryReadTimeReview = function(_self, record)
        local id = record.id
        retry_ids[#retry_ids + 1] = id
        return true
    end,
    dismissReadTimeReview = function(_self, record)
        local id = record.id
        handled_ids[#handled_ids + 1] = id
        for index, row in ipairs(status.review_records) do
            if row.id == id then table.remove(status.review_records, index); break end
        end
        status.review_time_count = #status.review_records
        return true
    end,
}
view.safeCallback = function(_, _label, callback) return callback end
view.showInfo = function(_, message) shown_message = message end
view.syncOfflineNow = function()
    assert(not opened, "dismiss details before opening any progress choice")
    uploads = uploads + 1
end

status = { state = "signed_out", signed_in = false }
assert(view:getOfflineSyncStatusText() == "微信读书　未登录")
view:showOfflineSyncStatus()
assert(opened.buttons[1][2].enabled == false)
status = { state = "unavailable", signed_in = true }
view:showOfflineSyncStatus()
assert(opened.body.text == "暂时无法读取同步状态")

status = {
    state = "pending", available = true, signed_in = true, pending_seconds = 480, pending_annotations = 2,
    pending_progress = 0, conflicts = {}, unknown_seconds = 0, unknown_annotations = 0,
}
windows, opened = {}, nil
assert(view:getOfflineSyncStatusText() == "微信读书　待传 8 分钟 · 2 条标注")
view:showOfflineSyncStatus()
assert(opened.title == "微信读书同步状态" and opened.body.text:find("480 秒", 1, true))
assert(opened.body.text:find("待传划线和笔记：2 条", 1, true))
assert(opened.buttons[1][1].text == "核对记录" and opened.buttons[2][1].text == "关闭"
    and opened.buttons[2][2].text == "立即上传" and #opened.buttons == 2)
opened.buttons[2][1].callback()
assert(not opened and uploads == 0)
view:showOfflineSyncStatus()
assert(opened.buttons[2][2].enabled)
opened.buttons[2][2].callback()
assert(not opened and uploads == 1)

status.pending_seconds, status.pending_progress, status.unlocated_annotations = 1930, 1, 2
review_books = {{ title = "山谷来信", seconds = 1930, segments = 65, annotations = 2, progress = true,
    issues = {{ count = 2, reason = "missing_source", document_path = "/books/one/offline.epub" }} }}
view.library_db.lastManualSyncResult = function()
    return { at = os.time(), reason = "authentication_required" }
end
view.library_db.readTimeReceipts = function() return { count = 2, last_time = os.time() } end
view:showOfflineSyncStatus()
assert(opened.body.text:find("最近一次时长回执", 1, true))
assert(opened.body.text:find("上次手动同步", 1, true) and opened.body.text:find("登录凭据未获接受", 1, true))
opened.buttons[1][1].callback()
assert(opened.title == "待传记录明细" and opened.body.text:find("1930 秒，共 65 段", 1, true))
assert(opened.body.text:find("山谷来信", 1, true) and opened.body.text:find("原文索引", 1, true)
    and opened.body.text:find("offline.epub", 1, true) and not opened.body.text:find("/books", 1, true))
assert(#opened.buttons[1] == 1, "pending or unlocated items must not offer discard or blind resend")
opened.buttons[1][1].callback()

status.pending_seconds, status.pending_annotations, status.pending_progress = 0, 0, 1
assert(view:getOfflineSyncStatusText() == "微信读书　待传 1 本书的进度")
status.pending_seconds = 25
assert(view:getOfflineSyncStatusText():find("25 秒", 1, true))
status.state, status.conflict_count = "conflict", 1
status.conflicts = { { title = "山谷来信" } }
status.unknown_seconds, status.unknown_annotations = 30, 2
status.rejected_seconds, status.review_time_count = 14, 2
status.review_records = {
    { id = 1, book_id = "a", title = "山谷来信", elapsed_seconds = 30,
        created_at = os.time(), state = "unknown", reason = "lost_reply" },
    { id = 2, book_id = "b", title = "海边的夜晚", elapsed_seconds = 14,
        created_at = os.time(), state = "rejected", reason = "server_rejected" },
}
assert(view:getOfflineSyncStatusText() == "微信读书　1 本书需选择进度")
view:showOfflineSyncStatus()
assert(opened.body.text:find("《山谷来信》", 1, true) and opened.body.text:find("30 秒时长，2 条标注", 1, true))
assert(opened.body.text:find("点「立即上传」选择要保留的进度", 1, true))
assert(opened.body.text:find("已拒绝的时长：14 秒", 1, true))
package.loaded["ui/uimanager"]:close(opened)
status.state = "unknown"
assert(view:getOfflineSyncStatusText() == "微信读书　有记录待核对")
view:showOfflineSyncStatus()
assert(opened.buttons[1][1].text == "核对记录" and #opened.buttons == 2)
opened.buttons[1][1].callback()
assert(opened.title == "待传记录明细")
opened.buttons[1][2].callback()
assert(opened.title == "阅读时长记录核对"
    and opened.body.text:find("书籍：山谷来信", 1, true)
    and opened.body.text:find("30 秒", 1, true))
assert(opened.buttons[2][2].text == "标记已处理"
    and opened.buttons[2][3].text == "仍然重试")
opened.buttons[2][3].callback()
assert(opened.text:find("可能重复增加阅读时长", 1, true))
opened.ok_callback()
assert(retry_ids[1] == 1 and uploads == 2,
    "explicit ambiguous retry did not schedule the selected record")
view:showOfflineSyncStatus()
opened.buttons[1][1].callback()
opened.buttons[1][2].callback()
opened.buttons[2][2].callback()
assert(opened.text:find("不会上传", 1, true))
opened.ok_callback()
assert(handled_ids[1] == 1 and status.review_records[1].id == 2,
    "mark handled removed the wrong review record")
view:showManualSyncResult("uploaded_with_review", status)
assert(shown_message:find("新记录已上传", 1, true)
    and shown_message:find("待核对记录：3 条", 1, true),
    "mixed manual result hid confirmed or held work")
status.newly_confirmed_seconds = 30
view:showManualSyncResult("partial", status)
assert(shown_message:find("已确认部分记录", 1, true) and shown_message:find("新确认时长　30 秒", 1, true))
status.state, status.pending_seconds, status.pending_annotations = "review", 0, 0
status.pending_progress, status.unknown_seconds, status.unknown_annotations = 0, 0, 0
assert(view:getOfflineSyncStatusText() == "微信读书　有记录需处理")
status.state = "idle"
assert(view:getOfflineSyncStatusText() == "微信读书　暂无待传记录")
status.state, status.last_confirmed_at = "synced", os.time()
assert(view:getOfflineSyncStatusText():find("已同步 · 今天 ", 1, true))
status.last_confirmed_at = os.time{year = 2017, month = 3, day = 6, hour = 12, min = 15}
assert(view:getOfflineSyncStatusText():find("2017-03-06 12:15", 1, true))
print("sync_status_view_spec: account summary, seconds, progress, conflicts, receipts and details passed")
