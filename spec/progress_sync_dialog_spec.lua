package.path = "./?.lua;" .. package.path

local shown
local closed
package.preload["ui/widget/confirmbox"] = function()
    return {
        new = function(_, options) return options end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown = widget end,
        close = function(_self, widget) closed = widget end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end

local Dialog = require("weread.ui.progress_sync_dialog")
local actions = {}
local dialog = Dialog.show_choice({
    book_title = "Book",
    local_position = { percent = 23.04, chapter_idx = 2, chapter_offset = 90 },
    remote_position = { percent = 23.49, chapter_idx = 3, chapter_offset = 12 },
    keep_local = function() actions[#actions + 1] = "local" end,
    use_remote = function() actions[#actions + 1] = "remote" end,
    later = function() actions[#actions + 1] = "later" end,
})

assert(dialog == shown, "dialog was not shown")
assert(dialog.ok_text == "Keep KOReader progress"
    and dialog.cancel_text == "Use WeRead progress",
    "local choice is not the primary action")
assert(dialog.other_buttons[1][1].text == "Later",
    "explicit Later action is missing")
assert(dialog.text:find("23.0%% · chapter 2 · position 90")
    and dialog.text:find("23.5%% · chapter 3 · position 12"),
    "same rounded progress did not expose chapter and location")

dialog:onClose()
assert(actions[1] == "later" and #actions == 1,
    "Back/outside close selected a progress position")
assert(closed == dialog, "safe close did not dismiss the dialog")

actions = {}
dialog.cancel_callback()
assert(actions[1] == "remote" and #actions == 1,
    "explicit cloud button did not choose WeRead")
actions = {}
dialog.ok_callback()
assert(actions[1] == "local" and #actions == 1,
    "primary button did not keep KOReader")
actions = {}
dialog.other_buttons[1][1].callback()
assert(actions[1] == "later" and #actions == 1,
    "explicit Later button did not defer")

print("progress_sync_dialog_spec: primary, cloud, Later and safe close passed")
