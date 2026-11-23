-- Optional SimpleUI 3.1+ Home module showing WeRead's offline sync state.

local logger = require("weread.lib.logger")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local MODULE_ID = "weread_sync_status"
local LAYOUT_MARKER = "simpleui_weread_sync_status_layout_v1"
local ENABLED_KEY = "simpleui_hs_weread_sync_status_enabled"

local function unavailableText()
    if type(T) == "function" then
        return T(_("WeRead  %1"), _("Sync status unavailable"))
    end
    return _("WeRead") .. "  " .. _("Sync status unavailable")
end

local Integration = {
    name = "simpleui",
    registered = false,
    -- The Home widget tree owns each row. A closed page can release both
    -- the row and the dirty callback that refers back to its screen.
    mounts = setmetatable({}, { __mode = "kv" }),
}

local Module = {
    id = MODULE_ID,
    name = _("WeRead sync status"),
    label = nil,
    category = "extras",
    default_on = false,
    enabled_key = "weread_sync_status_enabled",
}

function Integration:livePlugin()
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    local fm = file_manager and file_manager.instance
    if fm and type(fm.weread) == "table" then return fm.weread end
end

function Integration:_readStatus()
    local plugin = self:livePlugin()
    if plugin and type(plugin.getOfflineSyncStatusText) == "function" then
        local ok, text = pcall(plugin.getOfflineSyncStatusText, plugin)
        if ok and type(text) == "string" and text ~= "" then return text end
        if not ok then
            logger.warn("weread: SimpleUI sync status read failed:", tostring(text))
        end
    end
    return unavailableText()
end

function Integration:openStatus()
    local plugin = self:livePlugin()
    if not plugin or type(plugin.showOfflineSyncStatus) ~= "function" then return false end
    plugin:showOfflineSyncStatus()
    return true
end

local function mountIsVisible(owner)
    if not owner._navbar_container then return false end
    if owner.isActive and not owner:isActive() then return false end
    local Home = package.loaded["screens/sui_homescreen"]
    if Home and type(Home.getInstance) == "function" and owner._id
        and Home.getInstance(owner._id) ~= owner then return false end
    if type(owner._isModOnVisiblePage) == "function" then
        local ok, visible = pcall(owner._isModOnVisiblePage, owner, MODULE_ID)
        if not ok or not visible then return false end
    end
    return true
end

function Integration:refresh()
    if not self.registered then return false end
    local text
    local changed = false
    for owner, row in pairs(self.mounts) do
        if mountIsVisible(owner) then
            text = text or self:_readStatus()
            if row.status_label.text ~= text then
                row.status_label:setText(text)
                row.dirty_region_fn(row.dimen)
                changed = true
            end
        end
    end
    return changed
end

function Module.getHeight()
    local Screen = require("device").screen
    return Screen:scaleBySize(44)
end

function Module.build(width, ctx)
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = Device.screen

    local height = Module.getHeight()
    local edge_gap = Screen:scaleBySize(5)
    local chevron = TextWidget:new{
        text = "›",
        face = Font:getFace("cfont", 22),
    }
    local chevron_size = chevron:getSize()
    local chevron_space = chevron_size.w + edge_gap * 2
    local status = TextWidget:new{
        text = Integration:_readStatus(),
        face = Font:getFace("cfont", 18),
        max_width = math.max(1, width - chevron_space),
    }
    local body = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height },
        allow_mirroring = false,
        LeftContainer:new{
            dimen = Geom:new{ w = width - chevron_space, h = height },
            status,
        },
        chevron,
    }
    chevron.overlap_offset = {
        width - chevron_size.w - edge_gap,
        math.floor((height - chevron_size.h) / 2),
    }

    local button = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        body,
    }
    button.ges_events = {
        TapWeReadSyncStatus = {
            GestureRange:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }
    function button:onTapWeReadSyncStatus()
        return Integration:openStatus()
    end

    if ctx and ctx.kbStops then
        local ok, UI = pcall(require, "infra/sui_core")
        if ok and type(UI.makeFocusable) == "function" then
            UI.makeFocusable(button, function() return Integration:openStatus() end)
            ctx.kbStops(MODULE_ID, { { id = "sync_status", widget = button } })
        end
    end

    if ctx and ctx._screen_widget and ctx.dirty_region_fn then
        button.status_label = status
        button.dirty_region_fn = ctx.dirty_region_fn
        Integration.mounts[ctx._screen_widget] = button
    end
    return button
end

function Integration:_markLayoutPlaced(Store)
    if Store:get(ENABLED_KEY) == nil then Store:set(ENABLED_KEY, true) end
    Store:set(LAYOUT_MARKER, true)
end

function Integration:_placeAfterCurrently()
    local ok, Layout = pcall(require, "infra/sui_layout")
    if not ok or type(Layout.load) ~= "function"
        or type(Layout.findPage) ~= "function" or type(Layout.pageRows) ~= "function"
        or type(Layout.entryId) ~= "function" or type(Layout.save) ~= "function" then
        return false
    end
    local store_ok, Store = pcall(require, "infra/sui_store")
    if not store_ok or type(Store.get) ~= "function" or type(Store.set) ~= "function"
        or Store:get(LAYOUT_MARKER, false) == true then return false end
    if Store:get("simpleui_hs_currently_enabled") == false then return false end

    local layout = Layout.load("simpleui_hs_", "simpleui_layout")
    if type(layout) ~= "table" or type(layout.pages) ~= "table" then return false end
    if Layout.findPage(layout, MODULE_ID) then
        self:_markLayoutPlaced(Store)
        return true
    end

    local page = Layout.findPage(layout, "currently")
    if not page or page.hidden or type(page.modules) ~= "table" then return false end
    local rows = Layout.pageRows(page, "simpleui_hs_")
    if type(rows) ~= "table" then return false end
    local last_in_row
    for _, row in ipairs(rows) do
        for _, id in ipairs(row.ids or {}) do
            if id == "currently" then
                last_in_row = (row.order or row.ids)[#(row.order or row.ids)]
                break
            end
        end
        if last_in_row then break end
    end
    if not last_in_row then return false end
    local insert_at
    for i, entry in ipairs(page.modules) do
        if Layout.entryId(entry) == last_in_row then
            insert_at = i + 1
            break
        end
    end
    if not insert_at then return false end

    table.insert(page.modules, insert_at, MODULE_ID)
    Store:set(ENABLED_KEY, true)
    Layout.save(layout, "simpleui_hs_", "simpleui_layout", "hs")
    Store:set(LAYOUT_MARKER, true)
    logger.info("weread: added SimpleUI sync status below Currently Reading")
    return true
end

function Integration:register(plugin)
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not ok or type(Registry.register) ~= "function" then
        self.registered = false
        return false
    end
    Registry.register(Module)
    self.registered = true
    local placed_ok, placed_err = pcall(function()
        self:_placeAfterCurrently()
    end)
    if not placed_ok then
        logger.warn("weread: SimpleUI sync status placement failed:", tostring(placed_err))
    end
    return true
end

Integration.module = Module

return Integration
