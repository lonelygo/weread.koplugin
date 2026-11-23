-- SQLite-backed offline index for shelf entries, book details, and catalogs.
-- Downloaded EPUB/HTML files remain in the ordinary cache directory; this
-- database only stores small, queryable metadata needed to browse offline.

local logger = require("weread.lib.logger")
local Crypto = require("weread.lib.crypto")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local LibraryDB = {}
LibraryDB.__index = LibraryDB

local function status_changed(self)
    local ok, SyncStatus = pcall(require, "weread.lib.sync_status")
    if ok then SyncStatus.invalidateOffline(self.settings) end
end

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil, "JSON module is not available" end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    return ok and result or nil, ok and nil or result
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

local function changed_rows(db)
    local stmt = db:prepare("SELECT changes()")
    local row = stmt:reset():step()
    close_statement(stmt)
    return row and tonumber(row[1]) or 0
end

function LibraryDB:new(settings)
    local data_dir = settings.data_dir or settings.cache_dir or "."
    return setmetatable({
        settings = settings,
        data_dir = data_dir,
    }, self)
end

-- The hash keeps the user VID out of filenames while giving each login a
-- stable database that can be reused when the user switches back.
function LibraryDB:accountKey()
    local account = self.settings:get("account", {})
    local user_vid = type(account) == "table" and account.user_vid or nil
    if user_vid == nil or tostring(user_vid) == "" then return nil end
    return string.sub(Crypto.sha256_hex("weread-library:" .. tostring(user_vid)), 1, 20)
end

function LibraryDB:databasePath()
    local account_key = self:accountKey()
    if not account_key then return nil end
    return self.data_dir .. "/library-" .. account_key .. ".db"
end

function LibraryDB:open()
    local path = self:databasePath()
    if not path then
        logger.info("library_db skipped without an identified account")
        return nil
    end
    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("library_db lua-ljsqlite3 unavailable")
        return nil
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then
        logger.warn("library_db open failed:", path, db)
        return nil
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS books (
                book_id           TEXT PRIMARY KEY,
                kind              TEXT NOT NULL DEFAULT 'book',
                payload           TEXT NOT NULL,
                on_shelf          INTEGER NOT NULL DEFAULT 0,
                shelf_position    INTEGER,
                shelf_updated_at  INTEGER,
                detail_updated_at INTEGER,
                detail_payload    TEXT
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS chapters (
                book_id      TEXT NOT NULL,
                chapter_uid  TEXT NOT NULL,
                position     INTEGER NOT NULL,
                payload      TEXT NOT NULL,
                updated_at   INTEGER NOT NULL,
                PRIMARY KEY (book_id, chapter_uid)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS shelf_state (
                name TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS read_time_outbox (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id         TEXT NOT NULL,
                elapsed_seconds INTEGER NOT NULL,
                position_payload TEXT,
                created_at      INTEGER NOT NULL,
                state           TEXT NOT NULL DEFAULT 'pending',
                last_error      TEXT,
                claim_token     TEXT NOT NULL DEFAULT '',
                claimed_at      INTEGER NOT NULL DEFAULT 0
            )
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS local_annotation_snapshots (
                book_id       TEXT NOT NULL,
                document_path TEXT NOT NULL,
                payload       TEXT NOT NULL,
                updated_at    INTEGER NOT NULL,
                sync_state    TEXT NOT NULL DEFAULT 'local_pending',
                PRIMARY KEY (book_id, document_path)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS local_annotation_outbox (
                local_id        TEXT PRIMARY KEY,
                book_id         TEXT NOT NULL,
                document_path   TEXT NOT NULL,
                kind            TEXT NOT NULL,
                payload         TEXT NOT NULL,
                upload_payload  TEXT,
                present         INTEGER NOT NULL DEFAULT 1,
                sync_state      TEXT NOT NULL DEFAULT 'local_only',
                remote_id       TEXT NOT NULL DEFAULT '',
                remote_kind     TEXT NOT NULL DEFAULT '',
                replacement_id  TEXT NOT NULL DEFAULT '',
                created_at      INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL,
                last_attempt_at INTEGER NOT NULL DEFAULT 0,
                last_error      TEXT
                , claim_token   TEXT NOT NULL DEFAULT ''
                , claimed_at    INTEGER NOT NULL DEFAULT 0
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS sync_status_meta (
                name TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            ) WITHOUT ROWID
        ]])
        pcall(function()
            db:exec("ALTER TABLE local_annotation_outbox ADD COLUMN replacement_id TEXT NOT NULL DEFAULT ''")
        end)
        pcall(function() db:exec("ALTER TABLE read_time_outbox ADD COLUMN claim_token TEXT NOT NULL DEFAULT ''") end)
        pcall(function() db:exec("ALTER TABLE read_time_outbox ADD COLUMN claimed_at INTEGER NOT NULL DEFAULT 0") end)
        pcall(function() db:exec("ALTER TABLE local_annotation_outbox ADD COLUMN claim_token TEXT NOT NULL DEFAULT ''") end)
        pcall(function() db:exec("ALTER TABLE local_annotation_outbox ADD COLUMN claimed_at INTEGER NOT NULL DEFAULT 0") end)
        -- Adds the richer detail snapshot for databases created by an early
        -- development build. Duplicate-column errors are intentionally ignored.
        pcall(function() db:exec("ALTER TABLE books ADD COLUMN detail_payload TEXT") end)
        db:exec("CREATE INDEX IF NOT EXISTS chapters_position ON chapters(book_id, position)")
        db:exec("CREATE INDEX IF NOT EXISTS read_time_pending ON read_time_outbox(state, id)")
        db:exec([[
            CREATE INDEX IF NOT EXISTS local_annotation_pending
                ON local_annotation_outbox(sync_state, updated_at)
        ]])
    end)
    if not schema_ok then
        logger.warn("library_db schema init failed:", schema_err)
        pcall(function() db:close() end)
        return nil
    end
    return db
end

-- Persist active reading in server-compatible chunks. The Web reader accepts
-- at most 30 seconds per report, so longer local intervals are split here and
-- replayed in order after connectivity returns.
function LibraryDB:enqueueReadTime(book_id, elapsed_seconds, position)
    book_id = tostring(book_id or "")
    local remaining = math.floor(tonumber(elapsed_seconds) or 0)
    if book_id == "" or remaining <= 0 then return false end
    local position_payload, encode_err = encode(position or {})
    if not position_payload then
        logger.warn("library_db read time encode failed:", encode_err)
        return false
    end
    local db = self:open()
    if not db then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        stmt = db:prepare([[
            INSERT INTO read_time_outbox
                (book_id, elapsed_seconds, position_payload, created_at, state)
            VALUES (?, ?, ?, ?, 'pending')
        ]])
        local created_at = os.time()
        while remaining > 0 do
            local seconds = math.min(30, remaining)
            stmt:reset():bind(book_id, seconds, position_payload, created_at):step()
            remaining = remaining - seconds
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db read time write failed:", err)
    else status_changed(self) end
    return ok
end

function LibraryDB:nextReadTime()
    local db = self:open()
    if not db then return nil end
    local stmt
    local item
    local ok, err = pcall(function()
        stmt = db:prepare([[
            SELECT id, book_id, elapsed_seconds, position_payload, created_at
              FROM read_time_outbox
             WHERE state='pending'
             ORDER BY id LIMIT 1
        ]])
        local row = stmt:reset():step()
        if row then
            item = {
                id = tonumber(row[1]),
                book_id = tostring(row[2]),
                elapsed_seconds = tonumber(row[3]) or 0,
                position = decode(row[4]) or {},
                created_at = tonumber(row[5]) or 0,
            }
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db read time read failed:", err) end
    return ok and item or nil
end

function LibraryDB:claimReadTime(owner)
    local path = self:databasePath()
    local db = self:open()
    if not db then return nil end
    local token = table.concat({ tostring(owner or "reader"), tostring(os.time()),
        tostring(math.random(100000, 999999)) }, ":")
    local stmt
    local item
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        transaction_open = true
        stmt = db:prepare([[
            SELECT id, book_id, elapsed_seconds, position_payload, created_at
              FROM read_time_outbox
             WHERE state='pending' ORDER BY id LIMIT 1
        ]])
        local row = stmt:reset():step()
        close_statement(stmt)
        stmt = nil
        if row then
            stmt = db:prepare([[
                UPDATE read_time_outbox
                   SET state='claimed', claim_token=?, claimed_at=?
                 WHERE id=? AND state='pending'
            ]])
            stmt:reset():bind(token, os.time(), tonumber(row[1])):step()
            item = {
                id = tonumber(row[1]), book_id = tostring(row[2]),
                elapsed_seconds = tonumber(row[3]) or 0,
                position = decode(row[4]) or {}, created_at = tonumber(row[5]) or 0,
                claim_token = token, database_path = path,
            }
        end
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db read time claim failed:", err) end
    return ok and item or nil
end

local function claim_database(self, item)
    if type(item) ~= "table" or item.database_path ~= self:databasePath() then
        return nil
    end
    return self:open()
end

function LibraryDB:ackReadTime(item)
    local db = claim_database(self, item)
    if not db then return false end
    local stmt
    local transaction_open = false
    local affected = 0
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        transaction_open = true
        stmt = db:prepare([[
            DELETE FROM read_time_outbox
             WHERE id=? AND state='claimed' AND claim_token=?
        ]])
        stmt:reset():bind(tonumber(item.id), tostring(item.claim_token)):step()
        close_statement(stmt)
        stmt = nil
        affected = changed_rows(db)
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db read time ack failed:", err)
    elseif affected == 1 then status_changed(self) end
    return ok and affected == 1
end

-- An ambiguous write may already have reached the server. Quarantine it rather
-- than replaying blindly and double-counting reading time.
function LibraryDB:quarantineReadTime(item, err)
    local db = claim_database(self, item)
    if not db then return false end
    local stmt
    local affected = 0
    local ok, write_err = pcall(function()
        stmt = db:prepare([[
            UPDATE read_time_outbox
               SET state='unknown', last_error=?, claim_token='', claimed_at=0
             WHERE id=? AND state='claimed' AND claim_token=?
        ]])
        stmt:reset():bind(tostring(err or "unknown"), tonumber(item.id),
            tostring(item.claim_token)):step()
        close_statement(stmt)
        stmt = nil
        affected = changed_rows(db)
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db read time quarantine failed:", write_err)
    elseif affected == 1 then status_changed(self) end
    return ok and affected == 1
end

function LibraryDB:releaseReadTimeClaim(item)
    local db = claim_database(self, item)
    if not db then return false end
    local stmt
    local affected = 0
    local ok = pcall(function()
        stmt = db:prepare([[
            UPDATE read_time_outbox
               SET state='pending', claim_token='', claimed_at=0
             WHERE id=? AND state='claimed' AND claim_token=?
        ]])
        stmt:reset():bind(tonumber(item.id), tostring(item.claim_token)):step()
        close_statement(stmt)
        stmt = nil
        affected = changed_rows(db)
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if ok and affected == 1 then status_changed(self) end
    return ok and affected == 1
end

function LibraryDB:offlineStatus()
    local db = self:open()
    if not db then return { available = false, annotations = {} } end
    local result = {
        available = true, pending_seconds = 0, unknown_seconds = 0,
        annotations = {}, last_confirmed_at = nil,
    }
    local time_stmt, annotation_stmt, meta_stmt
    local ok, err = pcall(function()
        time_stmt = db:prepare([[
            SELECT state, COALESCE(SUM(elapsed_seconds), 0)
              FROM read_time_outbox GROUP BY state
        ]])
        local row = time_stmt:reset():step()
        while row do
            local state, seconds = tostring(row[1]), tonumber(row[2]) or 0
            if state == "pending" or state == "claimed" then
                result.pending_seconds = result.pending_seconds + seconds
            elseif state == "unknown" then
                result.unknown_seconds = result.unknown_seconds + seconds
            end
            row = time_stmt:step()
        end
        annotation_stmt = db:prepare([[
            SELECT sync_state, COUNT(*) FROM local_annotation_outbox
             GROUP BY sync_state
        ]])
        row = annotation_stmt:reset():step()
        while row do
            result.annotations[tostring(row[1])] = tonumber(row[2]) or 0
            row = annotation_stmt:step()
        end
        meta_stmt = db:prepare([[
            SELECT value FROM sync_status_meta WHERE name='last_confirmed_at'
        ]])
        row = meta_stmt:reset():step()
        result.last_confirmed_at = row and tonumber(row[1]) or nil
    end)
    close_statement(time_stmt)
    close_statement(annotation_stmt)
    close_statement(meta_stmt)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("library_db offline status read failed:", err)
        return { available = false, annotations = {} }
    end
    return result
end

function LibraryDB:setSyncLastConfirmedAt(timestamp)
    local db = self:open()
    if not db then return false end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO sync_status_meta (name, value)
            VALUES ('last_confirmed_at', ?)
            ON CONFLICT(name) DO UPDATE SET value=excluded.value
        ]])
        stmt:reset():bind(math.floor(tonumber(timestamp) or os.time())):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db sync timestamp write failed:", err)
    else status_changed(self) end
    return ok
end

function LibraryDB:recoverStaleReadTimeClaims(cutoff)
    local db = self:open()
    if not db then return false end
    local stmt
    local affected = 0
    local ok = pcall(function()
        stmt = db:prepare([[
            UPDATE read_time_outbox
               SET state='unknown', last_error='interrupted_claim',
                   claim_token='', claimed_at=0
             WHERE state='claimed' AND claimed_at<=?
        ]])
        stmt:reset():bind(tonumber(cutoff) or 0):step()
        close_statement(stmt)
        stmt = nil
        affected = changed_rows(db)
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if ok and affected > 0 then status_changed(self) end
    return ok
end

function LibraryDB:readTimeStatus()
    local db = self:open()
    if not db then return { pending = 0, unknown = 0 } end
    local stmt
    local status = { pending = 0, unknown = 0 }
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT state, COALESCE(SUM(elapsed_seconds), 0)
              FROM read_time_outbox GROUP BY state
        ]])
        local row = stmt:reset():step()
        while row do
            local state = tostring(row[1])
            local seconds = tonumber(row[2]) or 0
            if state == "pending" or state == "claimed" then
                status.pending = status.pending + seconds
            elseif state == "unknown" then
                status.unknown = status.unknown + seconds
            end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and status or { pending = 0, unknown = 0 }
end

-- Return the first book that has replayable offline work.  This intentionally
-- excludes unknown writes: they may already have reached WeRead and must not
-- be used to trigger a blind retry.  The query only reads indexed queue
-- columns and does not decode payloads, so the coordinator can call it before
-- deciding whether a network probe is worthwhile.
function LibraryDB:pendingOfflineBook(include_time, include_annotations)
    include_time = include_time ~= false
    include_annotations = include_annotations ~= false
    if not include_time and not include_annotations then return nil end

    local queries = {}
    if include_time then
        queries[#queries + 1] = [[
            SELECT book_id, 0 AS work_order, id AS item_order
              FROM read_time_outbox
             WHERE state='pending'
        ]]
    end
    if include_annotations then
        queries[#queries + 1] = [[
            SELECT book_id, 1 AS work_order, updated_at AS item_order
              FROM local_annotation_outbox
             WHERE sync_state IN (
                    'local_only','update_pending','delete_pending',
                    'replace_delete_pending'
                  )
               AND upload_payload IS NOT NULL AND upload_payload<>''
               AND (last_attempt_at=0 OR last_attempt_at<=strftime('%s','now')-60)
        ]]
    end

    local db = self:open()
    if not db then return nil end
    local stmt
    local book_id
    local ok, err = pcall(function()
        stmt = db:prepare("SELECT book_id FROM ("
            .. table.concat(queries, " UNION ALL ")
            .. ") ORDER BY work_order, item_order LIMIT 1")
        local row = stmt:reset():step()
        if row then book_id = tostring(row[1]) end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db pending work query failed:", err) end
    return ok and book_id or nil
end

function LibraryDB:hasPendingOfflineWork(include_time, include_annotations)
    return self:pendingOfflineBook(include_time, include_annotations) ~= nil
end

local function annotation_scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
end

local function annotation_copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = annotation_copy(item) end
    return result
end

local function canonical(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(key) .. "=" .. canonical(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function annotation_semantic(value)
    local result = {}
    for key, item in pairs(type(value) == "table" and value or {}) do
        if key ~= "upload" and key ~= "upload_error" then
            result[key] = item
        end
    end
    return result
end

local function annotation_kind(item)
    if item.drawer ~= nil and item.drawer ~= false then
        return tostring(item.note or ""):match("^%s*$")
            and "highlight" or "thought"
    end
    return "bookmark"
end

local function annotation_local_id(book_id, document_path, item)
    for _, key in ipairs({ "id", "uuid", "annotation_id", "annotationId" }) do
        local value = annotation_scalar(item[key])
        if value ~= nil and tostring(value) ~= "" then
            return "ko:" .. tostring(value)
        end
    end
    local base = table.concat({
        tostring(book_id or ""),
        tostring(document_path or ""),
        tostring(item.page or item.pageno or ""),
        tostring(item.pos0 or item.start or ""),
        tostring(item.pos1 or item["end"] or ""),
        tostring(item.xpointer or ""),
        tostring(item.datetime or item.date or ""),
    }, "\31")
    return "ko:" .. Crypto.sha256_hex(base):sub(1, 32)
end

local function compact_annotations(book_id, document_path, annotations)
    local output = {}
    for _, item in ipairs(type(annotations) == "table" and annotations or {}) do
        if type(item) == "table" then
            local row = {}
            for _, key in ipairs({
                "id", "uuid", "page", "pageno", "pos0", "pos1", "xpointer",
                "text", "text_orig", "note", "datetime", "datetime_updated",
                "drawer", "color",
            }) do
                local value = annotation_scalar(item[key])
                if value ~= nil then row[key] = value end
            end
            row.local_id = annotation_local_id(book_id, document_path, item)
            row.kind = annotation_kind(item)
            if type(item._weread_upload) == "table" then
                row.upload = annotation_copy(item._weread_upload)
            end
            if item._weread_upload_error ~= nil then
                row.upload_error = tostring(item._weread_upload_error)
            end
            output[#output + 1] = row
        end
    end
    return output
end

LibraryDB.annotationLocalId = annotation_local_id
LibraryDB.compactLocalAnnotations = compact_annotations

-- Save the complete native KOReader annotation snapshot. An empty snapshot is
-- meaningful because it records deletion of the last local mark. Upload stays
-- pending until a private WeRead write contract can be verified.
function LibraryDB:putLocalAnnotationSnapshot(book_id, document_path, annotations, options)
    options = type(options) == "table" and options or {}
    book_id = tostring(book_id or "")
    document_path = tostring(document_path or "")
    if book_id == "" or document_path == "" then return false end
    local compact = compact_annotations(book_id, document_path, annotations)
    local payload, encode_err = encode(compact)
    if not payload then
        logger.warn("library_db annotation snapshot encode failed:", encode_err)
        return false
    end
    local db = self:open()
    if not db then return false end
    local stmt
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        stmt = db:prepare([[
            INSERT INTO local_annotation_snapshots
                (book_id, document_path, payload, updated_at, sync_state)
            VALUES (?, ?, ?, ?, 'local_pending')
            ON CONFLICT(book_id, document_path) DO UPDATE SET
                payload=excluded.payload,
                updated_at=excluded.updated_at,
                sync_state='local_pending'
        ]])
        stmt:reset():bind(book_id, document_path, payload, os.time()):step()
        close_statement(stmt)
        stmt = nil

        local existing = {}
        stmt = db:prepare([[
            SELECT local_id, kind, payload, upload_payload, present,
                   sync_state, remote_id, remote_kind, created_at
              FROM local_annotation_outbox
             WHERE book_id=? AND document_path=?
        ]])
        local row = stmt:reset():bind(book_id, document_path):step()
        while row do
            existing[tostring(row[1])] = {
                kind = tostring(row[2]),
                payload = tostring(row[3]),
                upload_payload = row[4] and tostring(row[4]) or nil,
                present = tonumber(row[5]) == 1,
                sync_state = tostring(row[6]),
                remote_id = tostring(row[7] or ""),
                remote_kind = tostring(row[8] or ""),
                created_at = tonumber(row[9]) or os.time(),
            }
            row = stmt:step()
        end
        close_statement(stmt)
        stmt = nil

        local seen = {}
        local upsert = db:prepare([[
            INSERT INTO local_annotation_outbox
                (local_id, book_id, document_path, kind, payload,
                 upload_payload, present, sync_state, remote_id, remote_kind,
                 created_at, updated_at, last_error)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
                book_id=excluded.book_id,
                document_path=excluded.document_path,
                kind=excluded.kind,
                payload=excluded.payload,
                upload_payload=CASE
                    WHEN excluded.upload_payload <> '' THEN excluded.upload_payload
                    ELSE local_annotation_outbox.upload_payload
                END,
                present=1,
                sync_state=excluded.sync_state,
                remote_id=excluded.remote_id,
                remote_kind=excluded.remote_kind,
                updated_at=excluded.updated_at,
                last_attempt_at=CASE
                    WHEN excluded.sync_state <> local_annotation_outbox.sync_state THEN 0
                    ELSE local_annotation_outbox.last_attempt_at
                END,
                last_error=excluded.last_error
        ]])
        local now = os.time()
        for _, annotation in ipairs(compact) do
            local local_id = annotation.local_id
            local previous = existing[local_id]
            local item_payload, item_err = encode(annotation)
            if not item_payload then error(item_err) end
            local upload_payload = annotation.upload and encode(annotation.upload) or ""
            local changed = type(options.changed) == "table"
                and options.changed[local_id] == true
            local state = previous and previous.sync_state
                or (changed and "local_only" or "local_existing")
            local remote_id = previous and previous.remote_id or ""
            local remote_kind = previous and previous.remote_kind or ""
            local last_error = annotation.upload_error

            if previous then
                if remote_id ~= "" and remote_kind ~= ""
                    and remote_kind ~= annotation.kind then
                    state = "delete_pending"
                elseif canonical(annotation_semantic(decode(previous.payload)))
                    ~= canonical(annotation_semantic(annotation)) then
                    if state == "local_existing" and changed then
                        state = "local_only"
                    elseif state == "synced" then
                        state = "update_pending"
                    elseif state == "delete_pending" or state == "delete_unknown" then
                        state = remote_id ~= "" and "update_pending" or "local_only"
                    end
                elseif state == "delete_pending" then
                    state = remote_id ~= "" and "synced" or "local_only"
                end
            end
            if not upload_payload and state == "local_only" then
                last_error = last_error or "position_pending"
            end
            upsert:reset():bind(
                local_id, book_id, document_path, annotation.kind,
                item_payload, upload_payload, state, remote_id, remote_kind,
                previous and previous.created_at or now, now,
                tostring(last_error or "")
            ):step()
            seen[local_id] = true
        end
        close_statement(upsert)

        local update_missing = db:prepare([[
            UPDATE local_annotation_outbox
               SET present=0, sync_state=?, updated_at=?, last_attempt_at=0
             WHERE local_id=?
        ]])
        local delete_local = db:prepare([[
            DELETE FROM local_annotation_outbox WHERE local_id=?
        ]])
        for local_id, previous in pairs(existing) do
            if not seen[local_id] then
                if previous.remote_id == ""
                    and previous.sync_state ~= "unknown"
                    and previous.sync_state ~= "delete_unknown" then
                    delete_local:reset():bind(local_id):step()
                else
                    local state = previous.sync_state == "unknown"
                        and "delete_unknown" or "delete_pending"
                    update_missing:reset():bind(state, now, local_id):step()
                end
            end
        end
        close_statement(update_missing)
        close_statement(delete_local)
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db annotation snapshot write failed:", err)
    else status_changed(self) end
    return ok
end

function LibraryDB:getLocalAnnotationSnapshot(book_id, document_path)
    local db = self:open()
    if not db then return nil end
    local stmt
    local snapshot
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT payload, updated_at, sync_state
              FROM local_annotation_snapshots
             WHERE book_id=? AND document_path=?
        ]])
        local row = stmt:reset():bind(tostring(book_id or ""),
            tostring(document_path or "")):step()
        if row then
            snapshot = {
                annotations = decode(row[1]) or {},
                updated_at = tonumber(row[2]) or 0,
                sync_state = tostring(row[3] or ""),
            }
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and snapshot or nil
end

local function annotation_outbox_row(row)
    if not row then return nil end
    return {
        local_id = tostring(row[1]),
        book_id = tostring(row[2]),
        document_path = tostring(row[3]),
        kind = tostring(row[4]),
        annotation = decode(row[5]) or {},
        upload = decode(row[6]),
        present = tonumber(row[7]) == 1,
        sync_state = tostring(row[8]),
        remote_id = tostring(row[9] or ""),
        remote_kind = tostring(row[10] or ""),
        replacement_id = tostring(row[11] or ""),
        updated_at = tonumber(row[12]) or 0,
        last_attempt_at = tonumber(row[13]) or 0,
        last_error = tostring(row[14] or ""),
        claim_token = tostring(row[15] or ""),
        claimed_at = tonumber(row[16]) or 0,
    }
end

local ANNOTATION_OUTBOX_COLUMNS = [[
    local_id, book_id, document_path, kind, payload, upload_payload,
    present, sync_state, remote_id, remote_kind, replacement_id,
    updated_at, last_attempt_at, last_error, claim_token, claimed_at
]]

function LibraryDB:nextLocalAnnotationWork()
    local db = self:open()
    if not db then return nil end
    local stmt
    local item
    local ok, err = pcall(function()
        stmt = db:prepare("SELECT " .. ANNOTATION_OUTBOX_COLUMNS .. [[
            FROM local_annotation_outbox
            WHERE sync_state IN (
                'local_only','update_pending','delete_pending',
                'replace_delete_pending'
            )
              AND upload_payload IS NOT NULL AND upload_payload<>''
              AND (last_attempt_at=0 OR last_attempt_at<=?)
            ORDER BY updated_at, local_id LIMIT 1
        ]])
        item = annotation_outbox_row(
            stmt:reset():bind(os.time() - 60):step())
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db annotation outbox read failed:", err) end
    return ok and item or nil
end

function LibraryDB:claimLocalAnnotationWork(owner)
    local path = self:databasePath()
    local db = self:open()
    if not db then return nil end
    local token = table.concat({ tostring(owner or "annotations"), tostring(os.time()),
        tostring(math.random(100000, 999999)) }, ":")
    local stmt
    local item
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        transaction_open = true
        stmt = db:prepare("SELECT " .. ANNOTATION_OUTBOX_COLUMNS .. [[
            FROM local_annotation_outbox
            WHERE sync_state IN (
                'local_only','update_pending','delete_pending',
                'replace_delete_pending'
            )
              AND upload_payload IS NOT NULL AND upload_payload<>''
              AND (last_attempt_at=0 OR last_attempt_at<=?)
            ORDER BY updated_at, local_id LIMIT 1
        ]])
        item = annotation_outbox_row(
            stmt:reset():bind(os.time() - 60):step())
        close_statement(stmt)
        stmt = nil
        if item then
            item.original_state = item.sync_state
            item.claim_token = token
            item.database_path = path
            local now = os.time()
            stmt = db:prepare([[
                UPDATE local_annotation_outbox
                   SET sync_state='inflight', claim_token=?, claimed_at=?,
                       last_attempt_at=?
                 WHERE local_id=? AND sync_state=?
            ]])
            stmt:reset():bind(token, now, now, item.local_id,
                item.original_state):step()
        end
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db annotation claim failed:", err) end
    return ok and item or nil
end

function LibraryDB:recoverLocalAnnotationInflight(cutoff)
    local db = self:open()
    if not db then return false end
    local affected = 0
    local ok, err = pcall(function()
        local stmt = db:prepare([[
            UPDATE local_annotation_outbox
               SET sync_state='unknown', last_error='interrupted_inflight',
                   claim_token='', claimed_at=0
             WHERE sync_state='inflight' AND claimed_at<=?
        ]])
        stmt:reset():bind(tonumber(cutoff) or 0):step()
        stmt:close()
        affected = changed_rows(db)
    end)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db annotation inflight recovery failed:", err)
    elseif affected > 0 then status_changed(self) end
    return ok
end

function LibraryDB:updateLocalAnnotationWork(local_id, patch)
    patch = type(patch) == "table" and patch or {}
    local claim = type(local_id) == "table" and local_id or nil
    local id = claim and claim.local_id or local_id
    local db = claim and claim_database(self, claim) or self:open()
    if not db then return false end
    local current_stmt
    local write_stmt
    local transaction_open = false
    local updated = false
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        transaction_open = true
        current_stmt = db:prepare("SELECT " .. ANNOTATION_OUTBOX_COLUMNS
            .. " FROM local_annotation_outbox WHERE local_id=?")
        local current = annotation_outbox_row(
            current_stmt:reset():bind(tostring(id or "")):step())
        close_statement(current_stmt)
        current_stmt = nil
        if not current then
            db:exec("COMMIT")
            transaction_open = false
            return
        end
        if claim and (current.sync_state ~= "inflight"
            or current.claim_token ~= claim.claim_token) then
            db:exec("COMMIT")
            transaction_open = false
            return
        end
        local state = patch.sync_state or current.sync_state
        local remote_id = patch.remote_id
        if remote_id == nil then remote_id = current.remote_id end
        local remote_kind = patch.remote_kind
        if remote_kind == nil then remote_kind = current.remote_kind end
        local replacement_id = patch.replacement_id
        if replacement_id == nil then replacement_id = current.replacement_id end
        local present = patch.present
        if present == nil then present = current.present end
        if patch.delete == true then
            if claim then
                write_stmt = db:prepare([[
                    DELETE FROM local_annotation_outbox
                     WHERE local_id=? AND claim_token=? AND sync_state='inflight'
                ]])
                write_stmt:reset():bind(current.local_id, claim.claim_token):step()
            else
                write_stmt = db:prepare([[
                    DELETE FROM local_annotation_outbox WHERE local_id=?
                ]])
                write_stmt:reset():bind(current.local_id):step()
            end
            close_statement(write_stmt)
            write_stmt = nil
            updated = changed_rows(db) == 1
        else
            local sql = [[
                UPDATE local_annotation_outbox
                   SET present=?, sync_state=?, remote_id=?, remote_kind=?,
                       replacement_id=?, last_attempt_at=?, last_error=?,
                       claim_token='', claimed_at=0
                 WHERE local_id=?
            ]]
            if claim then
                sql = sql .. " AND claim_token=? AND sync_state='inflight'"
            end
            write_stmt = db:prepare(sql)
            if claim then
                write_stmt:reset():bind(
                    present and 1 or 0,
                    tostring(state), tostring(remote_id or ""),
                    tostring(remote_kind or ""),
                    tostring(replacement_id or ""),
                    tonumber(patch.last_attempt_at) or os.time(),
                    tostring(patch.last_error or ""), current.local_id,
                    claim.claim_token
                ):step()
            else
                write_stmt:reset():bind(
                    present and 1 or 0,
                    tostring(state), tostring(remote_id or ""),
                    tostring(remote_kind or ""),
                    tostring(replacement_id or ""),
                    tonumber(patch.last_attempt_at) or os.time(),
                    tostring(patch.last_error or ""), current.local_id
                ):step()
            end
            close_statement(write_stmt)
            write_stmt = nil
            updated = changed_rows(db) == 1
        end
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(current_stmt)
    close_statement(write_stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db annotation outbox update failed:", err)
    elseif updated then status_changed(self) end
    return ok and updated
end

function LibraryDB:localAnnotationStatus()
    local db = self:open()
    if not db then return {} end
    local stmt
    local counts = {}
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT sync_state, COUNT(*) FROM local_annotation_outbox
             GROUP BY sync_state
        ]])
        local row = stmt:reset():step()
        while row do
            counts[tostring(row[1])] = tonumber(row[2]) or 0
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and counts or {}
end

function LibraryDB:cacheShelf(books, archives)
    local db = self:open()
    if not db or type(books) ~= "table" then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("UPDATE books SET on_shelf=0, shelf_position=NULL")
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, on_shelf, shelf_position, shelf_updated_at)
            VALUES (?, ?, ?, 1, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                payload=excluded.payload,
                on_shelf=1,
                shelf_position=excluded.shelf_position,
                shelf_updated_at=excluded.shelf_updated_at
        ]])
        local now = os.time()
        for position, book in ipairs(books) do
            local book_id = book.book_id or book.bookId
            local payload, encode_err = encode(book)
            if book_id and payload then
                local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
                stmt:reset():bind(tostring(book_id), kind, payload, position, now):step()
            elseif encode_err then
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        -- Keep groups and their membership in the same snapshot as the books.
        if archives ~= nil then
            local payload, encode_err = encode(archives)
            if not payload then error(encode_err) end
            stmt = db:prepare([[
                INSERT INTO shelf_state (name, payload) VALUES ('archives', ?)
                ON CONFLICT(name) DO UPDATE SET payload=excluded.payload
            ]])
            stmt:reset():bind(payload):step()
            close_statement(stmt)
            stmt = nil
        end
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db shelf write failed:", err) end
    return ok
end

function LibraryDB:getShelfArchives()
    local db = self:open()
    if not db then return nil end
    local stmt, archives
    local ok = pcall(function()
        stmt = db:prepare("SELECT payload FROM shelf_state WHERE name='archives'")
        local row = stmt:reset():step()
        archives = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and archives or nil
end

function LibraryDB:getShelf()
    local db = self:open()
    if not db then return nil end
    local books = {}
    local ok, stmt = pcall(function()
        return db:prepare([[
            SELECT payload FROM books
            WHERE on_shelf=1
            ORDER BY shelf_position, book_id
        ]])
    end)
    if ok and stmt then
        local row = stmt:reset():step()
        while row do
            local book = decode(row[1])
            if book then books[#books + 1] = book end
            row = stmt:step()
        end
    end
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and books or nil
end

function LibraryDB:putBook(book)
    if type(book) ~= "table" then return false end
    local book_id = book.book_id or book.bookId
    local payload = encode(book)
    if not book_id or not payload then return false end
    local db = self:open()
    if not db then return false end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, detail_payload, detail_updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                detail_payload=excluded.detail_payload,
                detail_updated_at=excluded.detail_updated_at
        ]])
        local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
        stmt:reset():bind(tostring(book_id), kind, payload, payload, os.time()):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db book write failed:", err) end
    return ok
end

function LibraryDB:getBook(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local stmt
    local result
    local ok = pcall(function()
        stmt = db:prepare("SELECT COALESCE(detail_payload, payload) FROM books WHERE book_id=?")
        local row = stmt:reset():bind(tostring(book_id)):step()
        result = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and result or nil
end

function LibraryDB:putChapters(book_id, chapters)
    if not book_id or type(chapters) ~= "table" then return false end
    local db = self:open()
    if not db then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        local delete_stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        delete_stmt:reset():bind(tostring(book_id)):step()
        delete_stmt:close()
        stmt = db:prepare([[
            INSERT INTO chapters (book_id, chapter_uid, position, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
        ]])
        local now = os.time()
        for position, chapter in ipairs(chapters) do
            local uid = chapter.chapterUid or chapter.chapterId or position
            local payload, encode_err = encode(chapter)
            if payload then
                stmt:reset():bind(tostring(book_id), tostring(uid), position, payload, now):step()
            else
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db catalog write failed:", err) end
    return ok
end

function LibraryDB:getChapters(book_id)
    if not book_id then return nil end
    local db = self:open()
    if not db then return nil end
    local chapters = {}
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT payload FROM chapters WHERE book_id=? ORDER BY position
        ]])
        local row = stmt:reset():bind(tostring(book_id)):step()
        while row do
            local chapter = decode(row[1])
            if chapter then chapters[#chapters + 1] = chapter end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and #chapters > 0 and chapters or nil
end

return LibraryDB
