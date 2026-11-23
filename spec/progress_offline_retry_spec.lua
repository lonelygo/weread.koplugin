package.path = "./?.lua;" .. package.path

package.preload["weread.lib.position_mapper"] = function()
    return {
        same_position = function(a, b)
            return a and b and a.percent == b.percent
        end,
        compare = function(local_position, remote)
            if local_position.chapter_uid ~= remote.chapter_uid
                and math.abs(local_position.percent - remote.percent) <= 2 then
                return "different"
            end
            if math.abs(local_position.percent - remote.percent) <= 2 then
                return "same"
            end
            return local_position.percent > remote.percent
                and "local_ahead" or "remote_ahead"
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

local function coordinator_fixture(initial_books, remotes, options)
    options = options or {}
    local values = {
        account = { user_vid = "100" },
        books = initial_books,
        sync = { upload_on_close = true },
    }
    local queue = {}
    local callbacks = {}
    local choices = {}
    local sent = {}
    local opens = 0
    local local_settings = {
        get = function(_self, key, default) return values[key] or default end,
        set = function(_self, key, value) values[key] = value end,
        flush = function() end,
    }
    local service = setmetatable({
        settings = local_settings,
        scheduler = {
            scheduleIn = function(_self, _delay, fn) queue[#queue + 1] = fn end,
        },
        is_online = function() return true end,
        run_online = options.run_online or function(_kind, fn) fn(); return true end,
        upload_position = function(book_id, snapshot)
            sent[#sent + 1] = { book_id = book_id, percent = snapshot.percent }
            return true, { accepted = true }
        end,
        get_book = function(book_id)
            return { book_id = book_id, title = "Title " .. book_id }
        end,
        get_chapters = function() return { { chapterUid = 1 } } end,
        detect_book = options.detect_book or function() return nil end,
        get_document = options.get_document or function() return nil end,
        open_chapter = function() opens = opens + 1; return true end,
        goto_fraction = function() return true end,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function() end,
        now = function() return 1000 end,
        state = "idle",
    }, ProgressSync)
    if options.without_ui then service.on_choice = nil end
    service._fetch_remote = function(_self, book_id)
        return remotes[book_id]
    end
    local function drain(limit)
        limit = limit or 20
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count <= limit, "coordinator scheduler did not quiesce")
            table.remove(queue, 1)()
        end
    end
    return service, values, choices, sent, queue, drain,
        function() return opens end, callbacks
end

do
    local service, values, choices, sent, _, drain, open_count =
        coordinator_fixture({
            a = {
                book_id = "a",
                pending_upload_position = {
                    book_id = "a", chapter_uid = 1, percent = 20, captured_at = 1,
                },
                pending_upload_account = "100",
            },
            b = {
                book_id = "b",
                pending_upload_position = {
                    book_id = "b", chapter_uid = 1, percent = 80, captured_at = 2,
                },
                pending_upload_account = "100",
            },
        }, {
            a = { chapter_uid = 1, percent = 40 },
            b = { chapter_uid = 1, percent = 10 },
        })
    local pending, summary = service:has_pending()
    assert(pending and summary.pending == 2 and summary.book_id == "a",
        "has_pending did not expose the oldest owned book")
    assert(service:reconcile_pending() and #choices == 1,
        "remote-ahead offline progress did not request one choice")
    assert(service:awaiting_choice("a"),
        "visible conflict was not exposed to the same-book gate")
    assert(values.books.a.pending_upload_blocked == true,
        "conflict was not persisted")
    service:on_network_connected()
    assert(#choices == 1, "the same conflict prompted more than once")
    drain()
    assert(#sent == 1 and sent[1].book_id == "b",
        "a deferred conflict prevented an unrelated snapshot from uploading")
    assert(choices[1].use_remote(), "closed-book cloud choice was rejected")
    drain()
    assert(not service:awaiting_choice("a"),
        "resolved conflict kept the same-book gate closed")
    assert(values.books.a.pending_upload_position == nil,
        "cloud choice did not clear the exact closed-book snapshot")
    assert(values.books.a.pending_remote_position.percent == 40
        and values.books.a.pending_remote_account == "100",
        "closed-book cloud choice was not saved for the next open")
    assert(open_count() == 0,
        "cloud choice force-opened a closed book")
end

do
    local service, values, choices, _, _, drain = coordinator_fixture({
        a = {
            book_id = "a",
            pending_upload_position = {
                book_id = "a", chapter_uid = 1, percent = 10, captured_at = 1,
            },
            pending_upload_account = "100",
        },
        b = {
            book_id = "b",
            pending_upload_position = {
                book_id = "b", chapter_uid = 1, percent = 20, captured_at = 2,
            },
            pending_upload_account = "100",
        },
    }, {
        a = { chapter_uid = 1, percent = 40 },
        b = { chapter_uid = 1, percent = 50 },
    })
    service:reconcile_pending()
    drain()
    assert(#choices == 1 and service:awaiting_choice("a"),
        "a second book stacked another progress dialog")
    assert(values.books.b.pending_upload_blocked == true,
        "the hidden second conflict was not persisted")
    assert(choices[1].use_remote(), "first queued cloud choice failed")
    drain()
    assert(#choices == 2 and service:awaiting_choice("b"),
        "the next persisted conflict was not shown after the first resolved")
end


do
    local service, values, choices, sent, _, drain = coordinator_fixture({
        a = {
            book_id = "a",
            pending_upload_position = {
                book_id = "a", chapter_uid = 1, percent = 20, captured_at = 1,
            },
            pending_upload_account = "100",
        },
    }, { a = { chapter_uid = 1, percent = 40 } })
    service:reconcile_pending()
    assert(choices[1].later() and not service:awaiting_choice("a"),
        "Later did not release the live choice gate")
    drain()
    assert(#choices == 1 and values.books.a.pending_upload_blocked == true,
        "automatic retry reopened a deferred conflict")
    service:reconcile_pending(nil, { manual = true })
    assert(#choices == 2,
        "manual reconciliation could not reopen a persisted conflict")
    assert(choices[2].keep_local(), "manual local choice was rejected")
    drain()
    assert(#sent == 1 and values.books.a.pending_upload_position == nil,
        "local choice did not upload and clear its snapshot")
end

do
    local service, values, choices, sent = coordinator_fixture({
        a = {
            book_id = "a",
            pending_upload_position = {
                book_id = "a", chapter_uid = 1, percent = 20, captured_at = 1,
            },
            pending_upload_account = "100",
        },
    }, { a = { chapter_uid = 1, percent = 40 } }, { without_ui = true })
    service:reconcile_pending()
    assert(#choices == 0 and #sent == 0
        and values.books.a.pending_upload_position.percent == 20,
        "headless conflict silently selected or discarded a position")
end

do
    local service, values, choices, sent, _, drain = coordinator_fixture({
        a = { book_id = "a", pending_upload_account = "100",
            pending_upload_position = { book_id = "a", chapter_uid = 1, percent = 20, captured_at = 1 } },
    }, { a = { chapter_uid = 1, percent = 80 } })
    values.sync.ask_on_conflict = false
    service:reconcile_pending()
    drain()
    assert(#choices == 0 and #sent == 1 and values.books.a.pending_upload_position == nil,
        "automatic keep-local preference was ignored after an offline conflict")
end

do
    local online_callbacks = {}
    local service, values = coordinator_fixture({
        a = {
            book_id = "a",
            pending_upload_position = {
                book_id = "a", chapter_uid = 1, percent = 80, captured_at = 1,
            },
            pending_upload_account = "100",
        },
    }, { a = { chapter_uid = 1, percent = 10 } }, {
        run_online = function(_kind, fn)
            online_callbacks[#online_callbacks + 1] = fn
            return true
        end,
    })
    assert(service:reconcile_pending(), "delayed reconcile did not start")
    service:_save_pending({
        book_id = "a", chapter_uid = 1, percent = 90, captured_at = 2,
    }, "newer_close")
    online_callbacks[1]()
    assert(values.books.a.pending_upload_position.percent == 90,
        "an old comparison callback cleared a newer snapshot")
end

do
    local online_callbacks = {}
    local service, values = coordinator_fixture({
        a = {
            book_id = "a",
            pending_upload_position = {
                book_id = "a", chapter_uid = 1, percent = 80, captured_at = 1,
            },
            pending_upload_account = "100",
            pending_upload_decision = "local",
        },
    }, { a = { chapter_uid = 1, percent = 10 } }, {
        run_online = function(_kind, fn)
            online_callbacks[#online_callbacks + 1] = fn
            return true
        end,
    })
    assert(service:reconcile_pending(), "delayed confirmed upload did not start")
    service:_save_pending({
        book_id = "a", chapter_uid = 1, percent = 95, captured_at = 3,
    }, "latest_close")
    online_callbacks[1]()
    assert(values.books.a.pending_upload_position.percent == 95,
        "an accepted old upload cleared a newer snapshot")
end

print("progress_offline_retry_spec: offline persistence, account isolation and reconnect upload passed")
