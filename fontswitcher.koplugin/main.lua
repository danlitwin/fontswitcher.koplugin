local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local TouchMenu = require("ui/widget/touchmenu")
local CreDocument = require("document/credocument")
local Device = require("device")
local Screen = Device.screen

local FontSwitcher = WidgetContainer:extend{
    name = "fontswitcher",
    is_doc_only = true,
}

function FontSwitcher:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function FontSwitcher:onDispatcherRegisterActions()
    -- Clean up old actions to prevent duplicates
    Dispatcher:removeAction("font_switcher_next")
    Dispatcher:removeAction("font_switcher_prev")
    Dispatcher:removeAction("font_switcher_list")

    -- Register with general = true to target the General category specifically
    Dispatcher:registerAction("font_switcher_next", {
        category = "none",
        event = "FontSwitcherNext",
        title = _("Font Switcher: Next Font"),
        general = true,
    })
    Dispatcher:registerAction("font_switcher_prev", {
        category = "none",
        event = "FontSwitcherPrev",
        title = _("Font Switcher: Previous Font"),
        general = true,
    })
    Dispatcher:registerAction("font_switcher_list", {
        category = "none",
        event = "FontSwitcherList",
        title = _("Font Switcher: Font List"),
        general = true,
    })
end

function FontSwitcher:isReflowable()
    if not self.ui.document then return false end
    
    local has_font_method = self.ui.document.setFontFace ~= nil
    local is_cre = self.ui.document.provider == "cre"
    local has_configurable_font = self.ui.document.configurable and self.ui.document.configurable.font_face ~= nil
               
    return is_cre or has_font_method or has_configurable_font
end

function FontSwitcher:addToMainMenu(menu_items)
    menu_items.plugin_font_switcher = {
        text = _("Font Switcher"),
        sorting_hint = "typeset",
        icon = "font",
        sub_item_table = {
            {
                text = _("Next Font"),
                callback = function() self:onFontSwitcherNext() end,
            },
            {
                text = _("Previous Font"),
                callback = function() self:onFontSwitcherPrev() end,
            },
            {
                text = _("Select Font List..."),
                callback = function() self:onFontSwitcherList() end,
            },
        }
    }
end

function FontSwitcher:onFontSwitcherNext()
    if self:isReflowable() then
        self:switchFont(1)
    else
        self:showNotReflowableMessage()
    end
    return true
end

function FontSwitcher:onFontSwitcherPrev()
    if self:isReflowable() then
        self:switchFont(-1)
    else
        self:showNotReflowableMessage()
    end
    return true
end

function FontSwitcher:onFontSwitcherList()
    if self:isReflowable() then
        self:showFontMenu()
    else
        self:showNotReflowableMessage()
    end
    return true
end

function FontSwitcher:showNotReflowableMessage()
    local provider = (self.ui.document and self.ui.document.provider) or "none"
    UIManager:show(InfoMessage:new{
        text = _("Font switching only available for reflowable documents.\nCurrent provider: ") .. provider,
        timeout = 3,
    })
end

function FontSwitcher:getFontList()
    local success, cre_instance = pcall(CreDocument.engineInit, CreDocument)
    if not success or not cre_instance then
        logger.warn("FontSwitcher: Failed to initialize CRE engine for fonts.")
        return {}
    end
    
    local fonts = cre_instance.getFontFaces()
    if not fonts then return {} end
    table.sort(fonts)
    return fonts
end

function FontSwitcher:switchFont(direction)
    local fonts = self:getFontList()
    if #fonts == 0 then
        UIManager:show(InfoMessage:new{ text = _("No fonts found in system.") })
        return
    end

    local current_font = self.ui.doc_settings:readSetting("font_face")
                  or G_reader_settings:readSetting("cre_font")
                  or (self.ui.document and self.ui.document.default_font)
                  or "Spleen"
                  
    local idx = 0
    for i, name in ipairs(fonts) do
        if name == current_font then
            idx = i
            break
        end
    end

    if idx == 0 then idx = 1 end

    local new_idx = idx + direction
    if new_idx > #fonts then
        new_idx = 1
    elseif new_idx < 1 then
        new_idx = #fonts
    end

    local new_font_name = fonts[new_idx]
    self:applyFont(new_font_name)
end

function FontSwitcher:showFontMenu()
    local fonts = self:getFontList()
    if #fonts == 0 then
        UIManager:show(InfoMessage:new{ text = _("No fonts available.") })
        return 
    end

    local current_font = self.ui.doc_settings:readSetting("font_face")
                  or G_reader_settings:readSetting("cre_font")
                  or (self.ui.document and self.ui.document.default_font)

    local menu_items = {}

    for _, font_name in ipairs(fonts) do
        table.insert(menu_items, {
            text = font_name,
            checked_func = function() return font_name == current_font end,
            callback = function()
                self:applyFont(font_name)
            end,
            -- Using full appbar names for certainty
            icon = (font_name == current_font) and "check" or "appbar.textsize",
        })
    end

    -- Setting tab icon to the full name to ensure it maps correctly
    menu_items.icon = "appbar.typeset"

    local menu = TouchMenu:new{
        title = _("Select Font"),
        tab_item_table = { menu_items },
        width = Screen:getWidth(),
    }
    UIManager:show(menu)
end

function FontSwitcher:applyFont(font_name)
    logger.info("FontSwitcher: Setting font to", font_name)
    self.ui.doc_settings:saveSetting("font_face", font_name)
    if self.ui.document and self.ui.document.setFontFace then
        self.ui.document:setFontFace(font_name)
    end
    self.ui:handleEvent(Event:new("SetFont", font_name))
    self.ui:handleEvent(Event:new("UpdatePos"))
    
    UIManager:show(InfoMessage:new{
        text = font_name,
        timeout = 1,
    })
end

return FontSwitcher
