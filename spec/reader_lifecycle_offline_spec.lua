package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
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
local progress_wakes = 0
local report_wakes = 0
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
    progress_sync = {
        on_network_connected = function() progress_wakes = progress_wakes + 1 end,
    },
    read_report = {
        on_network_connected = function() report_wakes = report_wakes + 1 end,
    },
}
for key, value in pairs(Lifecycle) do host[key] = value end

host:onAnnotationsModified({ annotations[1] })
assert(saved and saved[1] == "book" and saved[2] == "/books/book.epub"
    and saved[3] == annotations,
    "KOReader annotation event did not persist the full native snapshot")
host:onNetworkConnected()
assert(progress_wakes == 1 and report_wakes == 1,
    "network restoration did not wake progress and reading-time queues")

print("reader_lifecycle_offline_spec: annotation events and network restoration are wired")
