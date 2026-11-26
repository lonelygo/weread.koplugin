-- Real KOReader menu consistency check. The HTTP fixture supplies synthetic
-- book data; menu construction itself performs no network access.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("language", "zh_CN")
require("gettext").changeLang("zh_CN")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
load_plugin("weread.koplugin")

local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
local Registry = require("document/documentregistry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local socket = require("socket")
local root = assert(home:match("^(.*)/profile$"))
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

local function wait_for(label, predicate)
    local deadline = socket.gettime() + 45
    repeat
        UIManager:handleInput()
        if predicate() then return end
        socket.sleep(0.02)
    until socket.gettime() > deadline
    error("timeout: " .. label)
end

local function menu_text(item)
    return item.text or (item.text_func and item.text_func()) or ""
end

local function common_text(items)
    local texts = {}
    for index = 1, 8 do texts[index] = menu_text(assert(items[index])) end
    return table.concat(texts, "|")
end

FileManager:showFiles(root .. "/books")
wait_for("file manager plugin", function()
    return FileManager.instance and FileManager.instance.weread
end)
local home_plugin = FileManager.instance.weread
local home_items = home_plugin:getMainMenuItems()
assert(menu_text(home_items[2]):find("无需扫码", 1, true))
local expected = table.concat({
    "书架", menu_text(home_items[2]), "离线同步", "weread收藏夹",
    "搜索", "阅读时间上报", "阅读统计", "设置",
}, "|")
assert(#home_items == 8 and common_text(home_items) == expected,
    "FileManager common menu changed: " .. common_text(home_items))

-- A saved QR account must have a recovery route even after the server has
-- expired the login. Render the real account dialog without making a request.
local account_settings = setmetatable({
    mock_endpoint = false,
    get = function(_settings, key, default)
        if key == "account" then
            return { login_method = "qr", login_time = 1, name = "测试账号" }
        end
        return home_plugin.settings:get(key, default)
    end,
}, { __index = home_plugin.settings })
local account_view = setmetatable({ settings = account_settings }, { __index = home_plugin })
local saved_account = account_view:getMainMenuItems()[2]
assert(menu_text(saved_account) == "本机账号 · 测试账号")
saved_account.callback()
local account_dialog = UIManager._window_stack[#UIManager._window_stack].widget
assert(account_dialog.ok_text == "重新扫码登录" and account_dialog.cancel_text == "关闭")
UIManager:close(account_dialog)

local local_reader = ReaderUI:new{
    dimen = Screen:getSize(),
    document = Registry:openDocument(root .. "/books/开始测试.html"),
}
UIManager:show(local_reader)
wait_for("local reader plugin", function() return local_reader.weread ~= nil end)
local local_items = local_reader.weread:getMainMenuItems()
assert(#local_items == 8 and common_text(local_items) == expected,
    "local document changed the common menu: " .. common_text(local_items))

local plugin = local_reader.weread
local Content = require("weread.lib.content")
local book = plugin.client:get_book_info("900001")
Content.ensure_reader_state(plugin.client, book)
book.chapters = Content.fetch_catalog(plugin.client, book)
assert(Content.save_catalog_cache(plugin.client, plugin.settings, book, book.chapters))
plugin.settings:set("books", { ["900001"] = book })
plugin:openChapter(book, book.chapters[1])
for _, entry in ipairs(UIManager._window_stack) do
    local widget = entry.widget
    if widget.ok_callback then
        UIManager:close(widget)
        widget.ok_callback()
        break
    end
end
local downloaded_path
wait_for("WeRead reader ready", function()
    local saved = plugin.settings:get("books", {})["900001"]
    downloaded_path = saved and saved.incremental_reader_file
    if downloaded_path then
        local file = io.open(downloaded_path, "rb")
        if file then
            file:close()
            for _, entry in ipairs(UIManager._window_stack) do
                local widget = entry.widget
                if widget.ok_callback then
                    UIManager:close(widget)
                    widget.ok_callback()
                    break
                end
            end
        end
    end
    return ReaderUI.instance
        and ReaderUI.instance.document.file == downloaded_path
        and ReaderUI.instance.weread
        and ReaderUI.instance.weread:detectWeReadBook() == "900001"
end)
local weread_reader = ReaderUI.instance

local reader_items = weread_reader.weread:getMainMenuItems()
assert(#reader_items == 9 and common_text(reader_items) == expected,
    "WeRead reader moved common actions: " .. common_text(reader_items))
local current = reader_items[9]
assert(menu_text(current) == require("weread.lib.i18n").tr("Current book"))
local actions = current.sub_item_table_func()
assert(menu_text(actions[1]) == "立即同步进度")
assert(menu_text(actions[2]) == "书籍详情")
assert(menu_text(actions[3]) == "显示划线和想法")
assert(menu_text(actions[4]) == "划线和想法管理")

UIManager:quit()
print("PASS: FileManager, local ReaderUI and WeRead ReaderUI keep one common menu order")
