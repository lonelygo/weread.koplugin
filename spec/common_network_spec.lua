-- Unit tests for shared network task behavior.

package.path = "./?.lua;" .. package.path

local checks = 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(string.format("%s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local dialog
package.preload["ui/bidi"] = function() return { dirpath = function(path) return path end } end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        show = function(_self, widget) dialog = widget end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return false end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end

local Common = require("weread.ui.common")
local offline_notices = 0
local host = setmetatable({
    showOffline = function()
        offline_notices = offline_notices + 1
    end,
}, { __index = Common })

eq(host:runOnlineTask("automatic", function() end, nil, {
    silent_offline = true,
}), false, "silent offline task does not start")
eq(offline_notices, 0, "silent offline task does not show a notice")

eq(host:runOnlineTask("manual", function() end), false,
    "regular offline task does not start")
eq(offline_notices, 1, "regular offline task still shows a notice")

local network = require("ui/network/manager")
local dns_checks, ran = 0, 0
network.isConnected = function() return true end
network.isOnline = function() dns_checks = dns_checks + 1; return false end
eq(host:runOnlineTask("progress", function() ran = ran + 1 end, nil,
    { check_link_only = true }), true, "WeRead request runs when the third-party DNS test fails")
eq(dns_checks, 0, "WeRead progress does not depend on external DNS probes")
network.isConnected = function() return false end
eq(host:runOnlineTask("progress", function() ran = ran + 1 end, nil,
    { check_link_only = true, silent_offline = true }), false, "disconnected device defers")
eq(ran, 1, "only the connected operation ran")

host.settings = {
    get = function() return { login_method = "qr", name = "Example" } end,
    is_cookie_configured = function() return true end,
    is_api_configured = function() return true end,
}
local scans = 0
host.qr_login = { start = function() scans = scans + 1 end }
host:showAccountStatus()
eq(dialog.ok_text, "Scan again to sign in", "saved account has a direct login action")
eq(scans, 0, "opening account status keeps the existing session")
dialog.ok_callback()
eq(scans, 1, "saved account can sign in again without clearing its queue")

print(string.format("common_network_spec: %d checks", checks))
