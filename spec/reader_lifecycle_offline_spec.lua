package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.annotation_chapters"] = function()
    return { recoverDescriptor = function() return nil, false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return value end,
        T = function(value) return value end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")
local saved
local requests = {}
local annotations = { { id = "local", note = "draft" } }
local host = {
    _current_weread_book_id = "book",
    ui = {
        document = { file = "/books/book.epub" },
        annotation = { annotations = annotations },
    },
    library_db = {
        putLocalAnnotationSnapshot = function(_self, book_id, path, value)
            saved = { book_id, path, value }
            return true
        end,
    },
    detectWeReadBook = function() return "book" end,
    offline_sync = {
        request = function(_self, reason) requests[#requests + 1] = reason end,
        disconnected = function() requests[#requests + 1] = "disconnected" end,
    },
}
for key, value in pairs(Lifecycle) do host[key] = value end

host:onAnnotationsModified({ annotations[1] })
assert(saved and saved[1] == "book" and saved[2] == "/books/book.epub"
    and saved[3] == annotations,
    "KOReader annotation event did not persist the full native snapshot")
host:onNetworkConnected()
host:onNetworkDisconnected()
assert(#requests == 2 and requests[1] == "network_connected" and requests[2] == "disconnected",
    "connection changes must go through the common coordinator")

local page, percent
host.ui.rolling = {
    onGotoPage = function(_, value) page = value end,
    onGotoPercent = function(_, value) percent = value end,
}
local path = host.ui.document.file
local book = { incremental_reader_file = path, chapters = { { chapterUid = 3 }, { chapterUid = 4 } },
    annotation_documents = { [path] = { chapters = { { chapterUid = 3 }, { chapterUid = 4 } } } } }
host.ui.document.getCurrentPage = function() return 9 end
host.ui.document.getPageCount = function() return 20 end
host.ui.document.getToc = function() return { { page = 8 }, { page = 11 } } end
host.ui.toc = { getTocIndexByPage = function() return 1 end }
assert(host:gotoProgressFraction(1500 / 1800, { book = book, path = path }) and page == 10)
assert(host:gotoProgressFraction(1, { book = book, path = path }) and page == 10)
assert(host:gotoProgressFraction(0, { book = book, path = path }) and page == 8)
assert(host:gotoProgressFraction(0.1265, {}) and math.abs(percent - 12.65) < 0.001)

local activations = 0
package.loaded["apps/filemanager/filemanager"] = {
    instance = { weread = { offline_sync = { activate = function() activations = activations + 1 end } } },
}
local function noop() end
local close_host = setmetatable({
    progress_sync = { on_close_document = noop }, _captureLocalAnnotationSnapshot = noop,
    read_report = { on_close_document = noop }, downloader = { cancelPrefetch = noop },
    _teardownThoughtInterception = noop, _teardownXPointerOverlayPrototype = noop,
    _removeReaderHighlightTapGuard = noop, _removeNativeAnnotationGuard = noop,
    offline_sync = { deactivate = function() return true end }, ui = {},
}, { __index = Lifecycle })
close_host:onCloseDocument()
assert(activations == 1, "returning to a live file manager must resume its offline queue")
close_host.offline_sync.deactivate = function() return false end
close_host:onCloseDocument()
assert(activations == 1, "closing an old reader must not replace a newer active instance")
print("reader_lifecycle_offline_spec: annotation events and network restoration are wired")
