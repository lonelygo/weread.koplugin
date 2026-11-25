local Content = require("weread.lib.content")
local Footnotes = require("weread.lib.footnotes")
local WorkerSettings = require("weread.lib.worker_settings")

local M = {}

function M.run(settings, client, book, chapter, context)
    local auth_result = WorkerSettings.capture(settings)
    local workspace
    local ok, result = xpcall(function()
        context.emit { stage = "reader" }
        Content.ensure_reader_state(client, book)
        context.emit { stage = "cover" }
        Content.ensure_book_cover(client, settings, book)
        context.checkCancelled()
        local chapters, catalog_err = Content.ensure_catalog(
            client, settings, book)
        if not chapters then error(catalog_err or "chapter catalog is unavailable") end
        context.checkCancelled()

        local cache = settings:get("cache", {})
        local state = {}
        if cache.download_book_images and Content.create_download_workspace then
            workspace = Content.create_download_workspace(settings, book)
            state.workspace = workspace
        end

        local xhtml
        for attempt = 1, 3 do
            context.emit { stage = "source", attempt = attempt }
            local fetched, value = pcall(Content.fetch_single_chapter_source,
                client, settings, book, chapter, state)
            if fetched then xhtml = value; break end
            if attempt == 3 then error(value, 0) end
            context.sleep(0.8 * attempt)
        end
        context.checkCancelled()

        local uid = tostring(chapter.chapterUid or chapter.chapterId or "1")
        local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
        context.emit { stage = cache.download_book_images and "images" or "process" }
        state.image_progress = function(current, total)
            context.checkCancelled()
            context.emit { stage = "images", current = current, count = total }
        end
        local finalized, assets = Content.finalize_single_chapter_content(
            client, settings, book, chapter, xhtml, state)
        context.checkCancelled()

        context.emit { stage = "footnotes" }
        local stats
        finalized, state.css, stats = Footnotes.prepare_single(
            finalized, scan_ok and scan, chapter, state.css)
        context.checkCancelled()

        context.emit { stage = "epub" }
        local cache_path = Content.save_chapter_epub(settings, book, chapter,
            finalized, assets, state.css)
        book.cached_chapters = book.cached_chapters or {}
        book.cached_chapters[uid] = cache_path
        local path, included = Content.save_incremental_book_epub(settings, book)
        if not path then error(included or "could not build incremental EPUB") end
        local descriptor = book.annotation_documents
            and book.annotation_documents[path] or nil
        return {
            path = path,
            cache_path = cache_path,
            incremental_chapter_uids = included,
            chapter_uid = uid,
            cache_dir = book.cache_dir,
            reader_url = book.reader_url,
            annotation_document = descriptor,
            footnote_stats = stats,
            auth = auth_result(),
        }
    end, debug.traceback)
    if workspace then Content.cleanup_download_workspace(workspace) end
    if not ok then error(result, 0) end
    return result
end

return M
