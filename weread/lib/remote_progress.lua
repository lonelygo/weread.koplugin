local WeRead = require("weread.lib.protocol")

local RemoteProgress = {}

local function response_error(value)
    if type(value) ~= "table" then return nil end
    return WeRead.classify_response_error(value)
end

function RemoteProgress.response_error(value, depth)
    if type(value) ~= "table" or (depth or 0) > 7 then return nil end
    local kind, code = response_error(value)
    if kind then return kind, code end
    for _key, child in pairs(value) do
        if type(child) == "table" then
            kind, code = RemoteProgress.response_error(child, (depth or 0) + 1)
            if kind then return kind, code end
        end
    end
end

function RemoteProgress.percent(value)
    for _, name in ipairs({ "progress", "readingProgress", "bookProgress" }) do
        local field = value[name]
        if field ~= nil and type(field) ~= "table" then
            local percent = tonumber(field)
            if percent and percent >= 0 and percent <= 100 then return percent end
            return nil, "progress_invalid"
        end
    end
end

local function find_node(value, book_id, depth, inherited_book_id)
    if type(value) ~= "table" or (depth or 0) > 7 then
        return nil, "progress_not_found"
    end
    local own_book_id = value.bookId or value.book_id
    local scoped_book_id = own_book_id or inherited_book_id
    if own_book_id ~= nil
        and tostring(own_book_id) ~= tostring(book_id) then
        return nil, "book_mismatch"
    end
    local percent, invalid = RemoteProgress.percent(value)
    if invalid then return nil, invalid end
    if percent ~= nil then return value end
    local retained_reason
    for _key, child in pairs(value) do
        if type(child) == "table" then
            local found, reason = find_node(
                child, book_id, (depth or 0) + 1, scoped_book_id)
            if found then return found end
            if reason ~= "book_mismatch" and reason ~= "progress_not_found" then
                retained_reason = retained_reason or reason
            end
        end
    end
    return nil, retained_reason or "progress_not_found"
end

function RemoteProgress.find_node(value, book_id)
    local kind = RemoteProgress.response_error(value)
    if kind == "authentication" then return nil, "authentication_required" end
    if kind then return nil, "response_rejected" end
    return find_node(value, tostring(book_id or ""), 0, nil)
end

function RemoteProgress.location(value)
    local chapter = value.chapterUid or value.chapterId or value.chapter_uid
    if type(chapter) ~= "number" and (type(chapter) ~= "string" or not chapter:find("%S")) then
        chapter = nil
    elseif tonumber(chapter) and tonumber(chapter) < 0 then
        chapter = nil
    end
    local offset = tonumber(value.chapterOffset or value.chapterPos
        or value.offset or value.chapter_offset)
    if offset and offset >= 0 and offset < math.huge then return chapter, offset end
    return chapter, nil
end

local function find_location(value, book_id, depth, inherited_book_id)
    if type(value) ~= "table" or (depth or 0) > 7 then return nil end
    local own_book_id = value.bookId or value.book_id
    local scoped_book_id = own_book_id or inherited_book_id
    if own_book_id ~= nil
        and tostring(own_book_id) ~= tostring(book_id) then return nil end
    local chapter, offset = RemoteProgress.location(value)
    if chapter ~= nil and offset ~= nil
        and (scoped_book_id == nil
            or tostring(scoped_book_id) == tostring(book_id)) then
        return value
    end
    for _key, child in pairs(value) do
        local found = type(child) == "table" and find_location(
            child, book_id, (depth or 0) + 1, scoped_book_id) or nil
        if found then return found end
    end
end

function RemoteProgress.verify_response(value, book_id)
    local kind = RemoteProgress.response_error(value)
    if kind == "authentication" then return false, "authentication_required" end
    if kind then return false, "response_rejected" end
    if find_node(value, tostring(book_id or ""), 0, nil)
        or find_location(value, tostring(book_id or ""), 0, nil) then
        return true, "verified"
    end
    return false, "response_unrecognized"
end

function RemoteProgress.request_reason(value)
    local text = tostring(value or "")
    if text:match("HTTP%s+401%f[^%d]")
        or text:match("HTTP%s+403%f[^%d]") then
        return "authentication_required"
    end
    local status = tonumber(text:match("HTTP%s+(%d%d%d)%f[^%d]"))
    if status == 429 or (status and status >= 500) then
        return "service_busy"
    end
    if text:find("invalid_json_response:", 1, true) then
        return "response_unrecognized"
    end
    if status then return "response_rejected" end
    return "service_unreachable"
end

function RemoteProgress.fetch(client, settings, book_id, chapters, options)
    options = options or {}
    local Mapper = require("weread.lib.position_mapper")
    local gateway
    local web
    local web_verified = false
    local gateway_error
    local web_error
    if settings:is_api_configured() then
        local ok, result = pcall(client.get_progress, client, book_id)
        if ok then
            gateway, gateway_error = Mapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = RemoteProgress.request_reason(result)
        end
    end
    if settings:is_cookie_configured() then
        local ok, result = pcall(client.get_web_progress, client, book_id)
        if ok then
            local verified_reason
            web_verified, verified_reason = RemoteProgress.verify_response(
                result, book_id)
            web, web_error = Mapper.normalize_remote(
                result, book_id, "web", chapters)
            if not web_verified then web_error = verified_reason end
        else
            web_error = RemoteProgress.request_reason(result)
        end
    end
    if options.require_web and not web_verified then
        return nil, web_error or "web_progress_unavailable"
    end
    local selected = Mapper.choose_remote(web, gateway, 2)
    if selected then return selected end
    if gateway_error == "authentication_required"
        or web_error == "authentication_required" then
        return nil, "authentication_required"
    end
    return nil, web_error or gateway_error or "remote_unavailable"
end

function RemoteProgress.probe(value, book_id)
    return RemoteProgress.verify_response(value, book_id)
end

return RemoteProgress
