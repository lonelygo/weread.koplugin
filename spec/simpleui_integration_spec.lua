-- Focused tests for the optional SimpleUI Home sync-status module.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(template, value) return template:gsub("%%1", value) end,
    }
end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local SimpleUI = require("integrations.simpleui")
SimpleUI.registered = false

expect(SimpleUI:register({}) == false,
    "SimpleUI integration should remain optional when SimpleUI is absent")

local registered
package.preload["modules/moduleregistry"] = function()
    return {
        register = function(module) registered = module end,
    }
end

local layout = {
    pages = {
        { id = 1, modules = { "quote", "currently", "quick_actions" } },
        { id = 2, modules = { "recent" } },
    },
}
local saved = 0
package.preload["infra/sui_layout"] = function()
    local Layout = {}
    function Layout.entryId(entry)
        return type(entry) == "table" and entry.id or entry
    end
    function Layout.findPage(candidate, id)
        for _, page in ipairs(candidate.pages) do
            for _, entry in ipairs(page.modules) do
                if Layout.entryId(entry) == id then return page end
            end
        end
    end
    function Layout.load() return layout end
    function Layout.pageRows()
        return {
            { ids = { "quote" }, order = { "quote" } },
            { ids = { "currently", "quick_actions" },
                order = { "currently", "quick_actions" } },
        }
    end
    function Layout.save(candidate)
        expect(candidate == layout, "placement saved a different layout")
        saved = saved + 1
    end
    return Layout
end

local marker = false
local enabled = false
package.preload["infra/sui_store"] = function()
    return {
        get = function(_self, key, default)
            if key == "simpleui_weread_sync_status_layout_v1" then return marker end
            if key == "simpleui_hs_weread_sync_status_enabled" then return enabled end
            if key == "simpleui_hs_currently_enabled" then return true end
            return default
        end,
        set = function(_self, key, value)
            if key == "simpleui_weread_sync_status_layout_v1" then marker = value; return end
            if key == "simpleui_hs_weread_sync_status_enabled" then enabled = value; return end
            error("placement wrote an unexpected SimpleUI setting: " .. tostring(key))
        end,
    }
end
local settings = {
    get = function(_self, _key, default)
        return default
    end,
}
local status_opens = 0
local status_reads = 0
local current_status = "WeRead pending: 8 min"
local plugin = {
    settings = settings,
    getOfflineSyncStatusText = function()
        status_reads = status_reads + 1
        return current_status
    end,
    showOfflineSyncStatus = function() status_opens = status_opens + 1 end,
}
package.loaded["apps/filemanager/filemanager"] = { instance = { weread = plugin } }

expect(SimpleUI:register(plugin) == true and SimpleUI.registered,
    "SimpleUI module registration failed")
expect(registered.id == "weread_sync_status"
    and registered.enabled_key == "weread_sync_status_enabled"
    and registered.default_on == false,
    "SimpleUI module descriptor is incompatible")
expect(layout.pages[1].modules[4] == "weread_sync_status" and saved == 1,
    "sync status split an existing bento row instead of following it")
expect(marker and enabled,
    "successful first placement was not persisted")
expect(SimpleUI:refresh() == false and status_reads == 0,
    "an unmounted status module performed an unnecessary status read")
local dirty = 0
local page_visible = false
local owner = {
    _id = "hs",
    _navbar_container = true,
    isActive = function(self) return not (self._parked or self._suspended) end,
    _isModOnVisiblePage = function() return page_visible end,
}
package.loaded["screens/sui_homescreen"] = {
    getInstance = function() return owner end,
}
local row = {
    dimen = {},
    status_label = { setText = function(self, value) self.text = value end },
    dirty_region_fn = function() dirty = dirty + 1 end,
}
SimpleUI.mounts[owner] = row
expect(SimpleUI:refresh() == false and status_reads == 0,
    "a status row on another Home page performed a read")
page_visible = true
expect(SimpleUI:refresh() == true and row.status_label.text == "WeRead pending: 8 min"
    and status_reads == 1 and dirty == 1,
    "SimpleUI status snapshot did not use the live FileManager plugin")
expect(SimpleUI:openStatus() == true and status_opens == 1,
    "SimpleUI status entry did not open the stable detail action")

page_visible = false
expect(SimpleUI:refresh() == false and status_reads == 1 and dirty == 1,
    "a hidden-page status row was repainted over another Home page")
page_visible = true

owner._parked = true
current_status = "WeRead pending: 9 min"
expect(not SimpleUI:refresh() and status_reads == 1 and dirty == 1,
    "a Home parked under the reader was read or repainted")
owner._parked = nil
owner._suspended = true
expect(not SimpleUI:refresh() and status_reads == 1 and dirty == 1,
    "the suspended Home was read or repainted")
owner._suspended = nil
expect(SimpleUI:refresh() and row.status_label.text == current_status and dirty == 2,
    "the returning Home did not pick up the latest value")

marker = false
enabled = false
expect(SimpleUI:_placeAfterCurrently() == true and marker and not enabled and saved == 1,
    "adopting an existing disabled status module changed the user's setting")
table.remove(layout.pages[1].modules, 4)

expect(SimpleUI:register(plugin) == true and saved == 1,
    "a user-removed module was inserted again")
expect(layout.pages[1].modules[4] == nil,
    "the one-time placement marker did not preserve user removal")

package.loaded["apps/filemanager/filemanager"].instance = nil
expect(SimpleUI:openStatus() == false,
    "status action should be inert without a live FileManager plugin")
expect(SimpleUI:refresh() == true
    and row.status_label.text == "WeRead  Sync status unavailable",
    "missing FileManager state did not produce an unavailable snapshot")

package.loaded["apps/filemanager/filemanager"] = nil
package.loaded["modules/moduleregistry"] = nil
package.loaded["infra/sui_layout"] = nil
package.loaded["infra/sui_store"] = nil
package.loaded["screens/sui_homescreen"] = nil
print(("simpleui_integration_spec: %d checks"):format(checks))
