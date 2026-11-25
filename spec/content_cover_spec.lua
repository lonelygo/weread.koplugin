package.path = "./?.lua;" .. package.path

package.preload["weread.lib.crypto"] = function()
    return { sha256_hex = function(data) return string.format("%x", #data) end }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(url)
            return tostring(url or ""):gsub("/t6_", "/t9_")
        end,
        reader_url = function() return "https://weread.qq.com/reader" end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local custom_covers = {}
package.preload["docsettings"] = function()
    local M = {}
    function M:findCustomCoverFile(path) return custom_covers[path] end
    function M:flushCustomCover(path, image_path)
        local ext = image_path:match("(%.[^./]+)$") or ".jpg"
        local dir = path:gsub("%.[^./]+$", "") .. ".sdr"
        assert(os.execute("mkdir -p " .. string.format("%q", dir)))
        local source = assert(io.open(image_path, "rb"))
        local target_path = dir .. "/cover" .. ext
        local target = assert(io.open(target_path, "wb"))
        target:write(source:read("*a"))
        source:close()
        target:close()
        custom_covers[path] = target_path
        return true
    end
    return M
end

local Content = require("weread.lib.content")
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local fallback_path = root .. "/fallback.jpg"
local fallback = "\255\216\255" .. string.rep("fallback", 16)
local source = "\137PNG\r\n\026\n" .. string.rep("source", 16)
local file = assert(io.open(fallback_path, "wb"))
file:write(fallback)
file:close()
Content.fallback_cover_path = function() return fallback_path end

local settings = { cache_dir = root }
local book = { book_id = "42", cover = "https://cdn.test/t6_cover" }
local requests = 0
local client = {
    get_binary = function(_self, url, options)
        requests = requests + 1
        assert(url == "https://cdn.test/t9_cover")
        assert(options.accept:find("image/", 1, true))
        error("temporary CDN failure")
    end,
}

local data, path, is_fallback = Content.ensure_book_cover(client, settings, book)
assert(data == fallback and is_fallback and path:match("cover%-fallback%.jpg$"))
assert(requests == 1, "first cover request was not attempted")
local cached = assert(io.open(path, "rb"))
assert(cached:read("*a") == fallback)
cached:close()

client.get_binary = function()
    requests = requests + 1
    return source
end
data, path, is_fallback = Content.ensure_book_cover(client, settings, book)
assert(data == source and not is_fallback and path:match("cover%-source%.png$"))
assert(requests == 2, "fallback prevented a later source-cover retry")

client.get_binary = function() requests = requests + 1; error("must not refetch") end
data, path, is_fallback = Content.ensure_book_cover(client, settings, book)
assert(data == source and path:match("cover%-source%.png$")
        and not is_fallback and requests == 2,
    "cached source cover was not reused")

local invalid_book = { book_id = "invalid", cover = "https://cdn.test/t6_bad" }
client.get_binary = function() requests = requests + 1; return string.rep("<html>", 20) end
data, path, is_fallback = Content.ensure_book_cover(client, settings, invalid_book)
assert(data == fallback and is_fallback and path:match("cover%-fallback%.jpg$"),
    "non-image response was accepted as a book cover")

local legacy_path = root .. "/legacy.epub"
local legacy_file = assert(io.open(legacy_path, "wb"))
legacy_file:write("legacy epub")
legacy_file:close()
local legacy = { book_id = "legacy", cache_dir = root .. "/legacy",
    incremental_reader_file = legacy_path, cover = "https://cdn.test/t6_legacy" }
local installed, custom = Content.install_legacy_custom_cover(
    settings, legacy, legacy_path)
assert(installed and custom == custom_covers[legacy_path])
local custom_file = assert(io.open(custom, "rb"))
assert(custom_file:read("*a") == fallback)
custom_file:close()

client.get_binary = function() return source end
assert(Content.ensure_book_cover(client, settings, legacy) == source)
custom = custom_covers[legacy_path]
custom_file = assert(io.open(custom, "rb"))
assert(custom_file:read("*a") == source,
    "managed fallback custom cover was not upgraded to the real source")
custom_file:close()

local user_cover = "\255\216\255" .. string.rep("user", 16)
custom_file = assert(io.open(custom, "wb"))
custom_file:write(user_cover)
custom_file:close()
assert(Content.ensure_book_cover(client, settings, legacy) == source)
custom_file = assert(io.open(custom, "rb"))
assert(custom_file:read("*a") == user_cover,
    "user-replaced custom cover was overwritten")
custom_file:close()

local embedded = { book_id = "embedded", cache_dir = root .. "/embedded",
    incremental_reader_file = root .. "/embedded.epub" }
assert(os.execute("mkdir -p " .. string.format("%q", embedded.cache_dir)))
local marker = assert(io.open(embedded.cache_dir .. "/incremental-cover-v1.meta", "wb"))
marker:write("cover=1\n")
marker:close()
assert(Content.install_legacy_custom_cover(settings, embedded,
    embedded.incremental_reader_file) == false,
    "embedded cover unexpectedly received a custom fallback")

local cached_source = { book_id = "cached-source",
    cache_dir = root .. "/cached-source",
    incremental_reader_file = root .. "/cached-source.epub" }
assert(os.execute("mkdir -p " .. string.format("%q", cached_source.cache_dir)))
local source_cache = assert(io.open(
    cached_source.cache_dir .. "/cover-source.png", "wb"))
source_cache:write(source)
source_cache:close()
local source_epub = assert(io.open(cached_source.incremental_reader_file, "wb"))
source_epub:write("legacy epub with separately cached source cover")
source_epub:close()
local source_installed, source_custom = Content.install_legacy_custom_cover(
    settings, cached_source, cached_source.incremental_reader_file)
assert(source_installed and source_custom == custom_covers[cached_source.incremental_reader_file])
source_cache = assert(io.open(source_custom, "rb"))
assert(source_cache:read("*a") == source,
    "legacy EPUB did not reuse its already cached source cover")
source_cache:close()

assert(os.execute("rm -rf " .. string.format("%q", root)))
print("content_cover_spec: source cache, fallback, retry and validation passed")
