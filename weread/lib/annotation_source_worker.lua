-- Rebuild only the source indexes required to locate native KOReader marks.
-- It does not modify the visible EPUB or upload annotations.
local Content = require("weread.lib.content")
local Chapters = require("weread.lib.annotation_chapters")
local Source = require("weread.lib.annotation_source")
local WorkerSettings = require("weread.lib.worker_settings")

local M = {}

-- Fetch source without mutating the shared annotation database. The parent
-- applies the staged result only after revalidating account, document and
-- reader-session identity.
local function fetch_source(client, settings, book, chapter)
    Content.refresh_reader_state(client, book, chapter)
    if book._content_format == "txt" then
        local t0 = Content.fetch_chapter_shard(
            client, settings, book, chapter, "/web/book/chapter/t_0")
        local ok_t1, t1 = pcall(Content.fetch_chapter_shard,
            client, settings, book, chapter, "/web/book/chapter/t_1")
        if not ok_t1 then t1 = "" end
        local plain = Content.decode_content_shards(t0, t1, "")
        return Source.plain(plain), true
    end

    local ok, e0 = pcall(Content.fetch_chapter_shard,
        client, settings, book, chapter, "/web/book/chapter/e_0")
    if ok and e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
        book._content_format = "txt"
        return fetch_source(client, settings, book, chapter)
    end
    if not ok then error(e0, 0) end
    book._content_format = "epub"
    local xhtml = Content.decode_content_shards(
        e0,
        Content.fetch_chapter_shard(
            client, settings, book, chapter, "/web/book/chapter/e_1"),
        Content.fetch_chapter_shard(
            client, settings, book, chapter, "/web/book/chapter/e_3"))
    return Source.index(xhtml), false
end

function M.run(settings, client, book, chapters, context)
    local auth_result = WorkerSettings.capture(settings)
    local current_catalog = Content.fetch_catalog(client, book)
    local current_by_uid = {}
    for _, chapter in ipairs(current_catalog or {}) do
        current_by_uid[Chapters.uid(chapter)] = chapter
    end
    local repaired, sources = {}, {}
    for _, chapter in ipairs(chapters or {}) do
        context.checkCancelled()
        local requested_uid = Chapters.uid(chapter)
        chapter = current_by_uid[requested_uid]
        if not chapter then
            error("annotation chapter is absent from the current edition: "
                .. requested_uid, 0)
        end
        local spans, plain = fetch_source(client, settings, book, chapter)
        local uid = Chapters.uid(chapter)
        local version = tonumber(
            book.book_version or book.bookVersion or book.version)
        sources[#sources + 1] = {
            chapter_uid = uid,
            spans = spans,
            version = version or (plain and 0 or nil),
        }
        repaired[#repaired + 1] = {
            chapterUid = chapter.chapterUid or chapter.chapterId,
            chapterIdx = chapter.chapterIdx,
            title = chapter.title,
        }
        context.emit {
            stage = "annotation_source",
            chapter_uid = uid,
        }
    end
    return {
        auth = auth_result(), repaired = repaired,
        catalog = current_catalog, sources = sources,
        book_version = book.book_version or book.bookVersion or book.version,
    }
end

return M
