package.path = "./?.lua;" .. package.path

local RemoteProgress = require("weread.lib.remote_progress")

local chapters = {
    { chapterUid = 1, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 2, chapterIdx = 2, wordCount = 300 },
}

local zero, zero_reason = RemoteProgress.find_node({
    data = { reader = { bookId = "book", progress = 0,
        chapterUid = 1, chapterOffset = 0 } },
}, "book")
assert(zero and zero.progress == 0 and zero_reason == nil,
    "zero percent was not a valid remote position")

local nested = { reader = { progress = { book = {
    bookId = "book", progress = 42, chapterUid = 2, chapterOffset = 8,
} } } }
assert(RemoteProgress.find_node(nested, "book") == nested.reader.progress.book)
for _, location in ipairs({
    { chapterUid = "", chapterOffset = 1 },
    { chapterUid = 2, chapterOffset = -1 },
    { chapterUid = {}, chapterOffset = 0 },
}) do
    assert(not RemoteProgress.verify_response(location, "book"))
end
local invalid_offset = require("weread.lib.position_mapper").normalize_remote({
    bookId = "book", progress = 42, chapterUid = 2, chapterOffset = -1,
}, "book", "web", chapters)
assert(invalid_offset and invalid_offset.percent == 42
    and not invalid_offset.has_chapter_offset)

local wrong, wrong_reason = RemoteProgress.find_node({
    bookId = "other",
    reader = { progress = 40, chapterUid = 2, chapterOffset = 100 },
}, "book")
assert(wrong == nil and wrong_reason == "book_mismatch",
    "an anonymous position under another book was accepted")

for _, code in ipairs({ -2010, -2012 }) do
    local node, reason = RemoteProgress.find_node({
        errCode = code, errMsg = "login unavailable",
    }, "book")
    assert(node == nil and reason == "authentication_required",
        "an HTTP 200 login error was not classified")
end

local values = {
    gateway = { book = { bookId = "book", progress = 10,
        chapterUid = 1, chapterOffset = 40, updateTime = 1 } },
    web = { data = { book = { bookId = "book", progress = 50,
        chapterUid = 2, chapterOffset = 100, updateTime = 2 } } },
}
local client = {
    get_progress = function() return values.gateway end,
    get_web_progress = function() return values.web end,
}
local settings = {
    is_api_configured = function() return true end,
    is_cookie_configured = function() return true end,
}
local selected = assert(RemoteProgress.fetch(
    client, settings, "book", chapters, { require_web = true }))
assert(selected.source == "web" and selected.chapter_uid == 2
    and selected.chapter_offset == 100 and selected.percent == 50,
    "the newest normalized web position was not selected")

values.web = { errCode = -2012, errMsg = "login expired" }
local expired, expired_reason = RemoteProgress.fetch(
    client, settings, "book", chapters, { require_web = true })
assert(expired == nil and expired_reason == "authentication_required",
    "a gateway position bypassed an expired write login")

values.web = { book = {
    bookId = "book", chapterUid = 2, chapterOffset = 100,
} }
local gateway_with_cookie = assert(RemoteProgress.fetch(
    client, settings, "book", chapters, { require_web = true }))
assert(gateway_with_cookie.source == "gateway"
    and gateway_with_cookie.chapter_uid == 1,
    "a scoped cookie location did not verify a complete gateway position")

assert(RemoteProgress.request_reason(
    "HTTP 503, content_type=application/json") == "service_busy")
assert(RemoteProgress.request_reason(
    "invalid_json_response: unexpected character") == "response_unrecognized")
assert(RemoteProgress.request_reason(
    "timeout while connecting") == "service_unreachable")

print("remote_progress_spec: scoped nodes, zero progress, dual sources and errors passed")
