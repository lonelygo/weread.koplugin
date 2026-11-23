package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded_values = {}
local encoded_index = 0
local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = deepcopy(item) end
    return copy
end

package.preload["json"] = function()
    return {
        encode = function(value)
            encoded_index = encoded_index + 1
            local token = "json-fixture-" .. tostring(encoded_index)
            encoded_values[token] = deepcopy(value)
            return token
        end,
        decode = function(token)
            assert(encoded_values[token], "unknown JSON fixture token")
            return deepcopy(encoded_values[token])
        end,
    }
end

local BookStore = require("weread.lib.book_store")
local root = os.tmpname() .. "-weread-book-store"
os.remove(root)
local settings = { cache_dir = root }

local ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Fixture book",
    author = "Fixture author",
    progress = 37,
    chapter_uid = 9,
    mp_articles = { { title = "Fixture article" } },
    chapters = { { chapterUid = 9 } },
})
expect(ok == true, "split book save failed")
expect(index.cache_dir == root .. "/book_42",
    "book id was not sanitized for the cache directory")
expect(BookStore.is_minimal_index({ ["book/42"] = index }),
    "saved index was not minimal")
expect(not BookStore.is_minimal_index({
    ["book/42"] = { cache_dir = index.cache_dir, title = "legacy" },
}), "legacy inline metadata was accepted as a minimal index")

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

expect(exists(index.cache_dir .. "/metadata.json"),
    "metadata file was not written")
expect(exists(index.cache_dir .. "/reading_state.json"),
    "reading-state file was not written")
expect(exists(index.cache_dir .. "/articles.json"),
    "article file was not written")

local loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Fixture book" and loaded.author == "Fixture author",
    "metadata did not round-trip")
expect(loaded.progress == 37 and loaded.chapter_uid == 9,
    "reading state did not round-trip")
expect(loaded.mp_articles[1].title == "Fixture article",
    "article data did not round-trip")
expect(loaded.chapters == nil,
    "large chapter catalog should not be stored in the book record")
expect(loaded.cache_dir == index.cache_dir,
    "resolved cache directory did not round-trip")

ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Metadata only",
    cache_dir = index.cache_dir,
})
expect(ok == true, "metadata-only update failed")
expect(not exists(index.cache_dir .. "/reading_state.json")
    and not exists(index.cache_dir .. "/articles.json"),
    "stale split files were not removed")
loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Metadata only"
    and loaded.progress == nil and loaded.mp_articles == nil,
    "removed split state reappeared after reload")

-- A previously released version split the owner and position across files.
local account = "bob"
settings.get = function(_, key) if key == "account" then return { user_vid = account } end end
local fake_json = require("json")
local function write(path, value)
    local file = assert(io.open(index.cache_dir .. "/" .. path, "wb"))
    assert(file:write(fake_json.encode(value)))
    file:close()
end
write("metadata.json", { book_id = "book/42", pending_upload_account = "alice",
    pending_upload_id = "first", pending_upload_blocked = true })
write("reading_state.json", { pending_upload_position = { percent = 15 } })
loaded = BookStore.load(settings, "book/42", index)
expect(not loaded.pending_upload_position, "legacy pending position leaked across logins")
-- showBookRecord() retains only cache fields on account change.
expect(BookStore.save(settings, "book/42", { cache_dir = index.cache_dir }), "shelf update failed")
loaded = BookStore.load(settings, "book/42", index)
loaded.pending_upload_position, loaded.pending_upload_account = { percent = 8 }, account
expect(BookStore.save(settings, "book/42", loaded, true), "new account's position was not saved")
account = "alice"
loaded = BookStore.load(settings, "book/42", index)
expect(loaded.pending_upload_position.percent == 15 and loaded.pending_upload_id == "first"
    and loaded.pending_upload_blocked, "account switch lost original conflict identity or position")
local stale_shelf_book = deepcopy(loaded)
loaded.pending_upload_position, loaded.pending_upload_account = nil, nil
loaded.pending_upload_blocked, loaded.pending_upload_id = nil, nil
expect(BookStore.save(settings, "book/42", loaded, true), "ack failed")
expect(BookStore.save(settings, "book/42", stale_shelf_book), "ordinary shelf refresh failed")
expect(not BookStore.load(settings, "book/42", index).pending_upload_position,
    "stale library record resurrected acknowledged work")
account = "bob"
expect(BookStore.load(settings, "book/42", index).pending_upload_position.percent == 8,
    "acknowledging another account changed this account's position")
os.remove(index.cache_dir .. "/reading_state.json")

os.remove(index.cache_dir .. "/metadata.json")
os.remove(index.cache_dir)
os.remove(root)

print(("book_store_spec: %d checks"):format(checks))
