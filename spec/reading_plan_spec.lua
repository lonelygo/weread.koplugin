local Plan = require("weread.lib.reading_plan")
local catalog = { { chapterUid = 0, title = "封面" } }
for i, uid in ipairs({ 10, 50, 12, 77, 21, 88, 13, 99 }) do
    catalog[#catalog + 1] = { chapterUid = uid, chapterIdx = i }
end
local function plan(record, data, history, live)
    return Plan.build(record, catalog, record.cached_full_book or record.cached_file,
        "stable", data or {}, history or {}, live, function(path) return path ~= "deleted" end)
end
local function ids(list)
    local result = {}
    for _, chapter in ipairs(list) do result[#result + 1] = chapter.chapterUid end
    return table.concat(result, ",")
end
local b = { progress = 90, chapter_uid = 99, cached_chapters = { ["21"] = "deleted" } }
local state = plan(b, { 10, 12, 77, 88 })
assert(not state.started and state.index == 1 and state.last == 1)
assert(ids(Plan.missing(state, 5)) == "50,21")
b.last_local_position = { current_chapter_uid = 12, captured_at = 10 }
state = plan(b, { 10, 12, 77, 88 }, { { file = "unrelated" }, { file = "stable" } })
assert(state.started and state.index == 3 and state.last == 4 and state.resume_path == "stable")
assert(ids(Plan.missing(state, 5)) == "21,13,99")
assert(ids(Plan.missing(state)) == "50,21,13,99")
b.pending_upload_position = { chapter_uid = 99, captured_at = 11 }
state = plan(b, { 99 })
assert(state.forward_count == 0 and state.last == 8 and #Plan.missing(state) == 7)
assert(plan(b, { 10 }, nil, { chapter_uid = 10 }).index == 1)
b = { cached_file = "batch", cached_chapters = { ["10"] = "batch", ["50"] = "batch" } }
state = plan(b)
assert(not state.complete and state.last == 2)
b = { cached_full_book = "full" }
assert(plan(b).complete and not plan(b).started)
assert(plan(b, nil, { { file = "full" } }).resume_path == "full")
print("reading_plan_spec: catalog windows, sparse UIDs, history, full and legacy caches passed")
