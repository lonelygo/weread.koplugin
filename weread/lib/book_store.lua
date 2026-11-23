local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local BookStore = {}

local reading_fields = {
    app_id = true,
    chapter_idx = true,
    chapter_offset = true,
    chapter_uid = true,
    last_local_position = true,
    last_pull_at = true,
    last_remote_position = true,
    last_sync_error = true,
    last_upload_at = true,
    last_uploaded_position = true,
    pclts = true,
    progress = true,
    psvts = true,
    read_context_updated_at = true,
    read_session_entered_at = true,
    read_session_id = true,
    reader_url = true,
    summary = true,
    token = true,
    verified_at = true,
    verified_source = true,
}

local article_fields = {
    mp_articles = true,
    mp_articles_time = true,
}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function resolved_dir(settings, book_id, book)
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local dir = type(book) == "table"
        and dirname(book.cached_full_book or book.cached_file) or nil
    if not dir and type(book) == "table" and type(book.cached_chapters) == "table" then
        for _uid, path in pairs(book.cached_chapters) do
            dir = dirname(path)
            if dir then break end
        end
    end
    return dir or (settings.cache_dir .. "/" .. basename_safe(book_id))
end

local function encode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(value)
    end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(value)
    end
    return json:decode(value)
end

local function read_json(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(decode, content)
    return ok and type(value) == "table" and value or nil
end

local function write_json(path, value)
    local ok, content = pcall(encode, value)
    if not ok then return false, content end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    return true
end

local function merge(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
end

local function has_values(value)
    return next(value) ~= nil
end

-- Downloads are shared across logins. Pending choices and positions belong
-- to the account that created them, even when both accounts open the same book.
local function pending_owner_field(key)
    if key:match("^pending_upload_") then return "pending_upload_account" end
    if key:match("^pending_remote_") then return "pending_remote_account" end
end

local function current_account(settings)
    local account = settings.get and settings:get("account", {})
    return account and tostring(account.user_vid or "") or ""
end

local function collect_pending(accounts, book)
    for key, value in pairs(book) do
        local owner_field = pending_owner_field(key)
        local owner = owner_field and book[owner_field]
        if owner and tostring(owner) ~= "" then
            owner = tostring(owner)
            accounts[owner] = accounts[owner] or {}
            accounts[owner][key] = value
        end
    end
end

function BookStore.load(settings, book_id, index)
    local book = {}
    merge(book, index)
    local dir = resolved_dir(settings, book_id, index)
    merge(book, read_json(dir .. "/metadata.json"))
    merge(book, read_json(dir .. "/reading_state.json"))
    merge(book, read_json(dir .. "/articles.json"))
    local accounts = book.pending_by_account
    if type(accounts) ~= "table" then
        accounts = {}
        collect_pending(accounts, book)
    end
    book.pending_by_account = nil
    for key in pairs(book) do
        if pending_owner_field(key) then book[key] = nil end
    end
    merge(book, accounts[current_account(settings)])
    book.book_id = book.book_id or book.bookId or tostring(book_id)
    book.cache_dir = dir
    return book
end

function BookStore.save(settings, book_id, book, update_pending)
    book = type(book) == "table" and book or {}
    local dir = resolved_dir(settings, book_id, book)
    os.execute("mkdir -p " .. string.format("%q", dir))

    local previous = read_json(dir .. "/reading_state.json") or {}
    local accounts = previous.pending_by_account
    if type(accounts) ~= "table" then
        accounts = {}
        -- In v1.8.0 the position was in reading_state and its account in metadata.
        if previous.pending_upload_position or previous.pending_remote_position then
            local legacy = read_json(dir .. "/metadata.json") or {}
            merge(legacy, previous)
            collect_pending(accounts, legacy)
        end
        -- Migration from an unsplit legacy settings record.
        if (book.pending_upload_position or book.pending_remote_position)
            and not next(accounts) and not read_json(dir .. "/metadata.json") then
            collect_pending(accounts, book)
        end
    end
    if update_pending then
        local account = current_account(settings)
        if account ~= "" then
            accounts[account] = nil
            local incoming = {}
            collect_pending(incoming, book)
            accounts[account] = incoming[account]
        end
    end

    local metadata = { book_id = book.book_id or book.bookId or tostring(book_id) }
    local reading_state = {}
    if next(accounts) then reading_state.pending_by_account = accounts end
    local articles = {}
    for key, value in pairs(book) do
        if article_fields[key] then
            articles[key] = value
        elseif reading_fields[key] then
            reading_state[key] = value
        elseif key ~= "chapters" and key ~= "cache_dir" and key ~= "bookId"
            and key ~= "pending_by_account" and not pending_owner_field(key) then
            metadata[key] = value
        end
    end

    local ok, err
    if has_values(reading_state) then
        ok, err = write_json(dir .. "/reading_state.json", reading_state)
        if not ok then return false, err end
    else
        os.remove(dir .. "/reading_state.json")
    end
    ok, err = write_json(dir .. "/metadata.json", metadata)
    if not ok then return false, err end
    if has_values(articles) then
        ok, err = write_json(dir .. "/articles.json", articles)
        if not ok then return false, err end
    else
        os.remove(dir .. "/articles.json")
    end
    return true, { cache_dir = dir }
end

function BookStore.is_minimal_index(books)
    for _book_id, record in pairs(books or {}) do
        if type(record) ~= "table" then return false end
        for key in pairs(record) do
            if key ~= "cache_dir" then return false end
        end
    end
    return true
end

return BookStore
