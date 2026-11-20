package.path = "./?.lua;" .. package.path

package.preload["weread.lib.position_mapper"] = function()
    return {
        same_position = function(a, b)
            return a and b and a.percent == b.percent
        end,
        compare = function(local_position, remote)
            return local_position.percent >= remote.percent and "local_ahead" or "remote_ahead"
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end

local ProgressSync = require("weread.lib.progress_sync")
local books = { book = { book_id = "book" } }
local account = { user_vid = "100" }
local online = false
local uploads = {}
local scheduled = {}
local settings = {
    get = function(_self, key, default)
        if key == "books" then return books end
        if key == "account" then return account end
        if key == "sync" then return { upload_on_close = true } end
        return default
    end,
    set = function(_self, key, value)
        if key == "books" then books = value end
    end,
    flush = function() end,
}

local sync = setmetatable({
    settings = settings,
    scheduler = {
        scheduleIn = function(_self, _delay, fn)
            scheduled[#scheduled + 1] = fn
        end,
    },
    is_online = function() return online end,
    run_online = function(_kind, fn) fn(); return true end,
    upload_position = function(book_id, position, elapsed)
        uploads[#uploads + 1] = { book_id, position.percent, elapsed }
        return true, {}
    end,
    now = function() return 100 end,
    get_book = function() return { book_id = "book" } end,
    get_chapters = function() return { { chapterUid = 1 } } end,
    state = "idle",
}, ProgressSync)
sync._fetch_remote = function() return { percent = 10, chapter_uid = 1 } end

local position = { book_id = "book", percent = 42, captured_at = 99 }
assert(not sync:_upload_snapshot(position, "offline_close", false))
assert(books.book.pending_upload_position.percent == 42
    and books.book.pending_upload_account == "100",
    "offline position was not persisted with account ownership")

account = { user_vid = "200" }
online = true
assert(not sync:on_network_connected() and #uploads == 0,
    "a different account uploaded the pending position")

account = { user_vid = "100" }
assert(sync:on_network_connected() and #uploads == 1,
    "network restoration did not upload the owned pending position")
assert(books.book.pending_upload_position == nil
    and books.book.pending_upload_account == nil,
    "accepted progress upload did not clear the pending record")

online = false
uploads = {}
local behind = { book_id = "book", percent = 20, captured_at = 101 }
assert(not sync:_upload_snapshot(behind, "offline_close", false))
sync._fetch_remote = function() return { percent = 30, chapter_uid = 1 } end
online = true
assert(sync:on_network_connected() and #uploads == 0,
    "reconnect overwrote a newer remote/mobile position")
assert(books.book.pending_upload_blocked == true
    and books.book.last_sync_error == "offline_progress_conflict",
    "newer remote position did not hold the offline snapshot for review")

print("progress_offline_retry_spec: offline persistence, account isolation and reconnect upload passed")
