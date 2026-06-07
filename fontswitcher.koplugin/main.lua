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

-- Add this plugin's directory to the Lua search path so that bundled files
-- (fontchooser_local.lua) can be loaded without shadowing KOReader's own
-- system modules (which would happen if we just used "fontchooser").
local _plugin_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = _plugin_dir .. "?.lua;" .. package.path

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

-- ── Font-chooser helpers ──────────────────────────────────────────────────────
--
-- FontChooser (ui/widget/fontchooser) operates on .ttf/.otf *filenames*
-- (e.g. "NotoSans-Regular.ttf"), while CREngine's font API works with *face
-- names* (e.g. "Noto Sans Regular") returned by getFontFaces().
--
-- We bridge the two worlds by scanning KOReader's font directories and
-- comparing normalised strings:
--
--   face "Noto Sans Regular"    → norm → "notosansregular"
--   file "NotoSans-Regular.ttf" → base → "NotoSans-Regular" → norm → "notosansregular"
--
-- Normalisation: lower-case, drop spaces / hyphens / underscores.
-- This handles the most common font-naming conventions.  The mapping is built
-- once per plugin instance and reused.

local function _normName(s)
    return (s or ""):lower():gsub("[%s%-%_]+", "")
end

--- Scan font directories and return two lookup tables:
---   file_to_face[filename]  → face name
---   face_to_file[face_name] → filename
local function _buildFontMap(face_list)
    local face_to_file = {}
    local file_to_face = {}

    local ok_lfs, lfs = pcall(require, "lfs")
    if not ok_lfs then return face_to_file, file_to_face end

    -- Collect candidate directories.
    local dirs = {}
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds then
        table.insert(dirs, DataStorage:getDataDir() .. "/fonts")
        if type(DataStorage.getFullDataDir) == "function" then
            local full = DataStorage:getFullDataDir()
            if full then table.insert(dirs, full .. "/fonts") end
        end
    end
    table.insert(dirs, "fonts")                     -- KOReader bundled fonts
    table.insert(dirs, "/system/fonts")             -- Android system
    table.insert(dirs, "/system/product/fonts")     -- Android product partition
    table.insert(dirs, "/usr/share/fonts/truetype") -- Debian / Ubuntu
    table.insert(dirs, "/usr/share/fonts")

    -- Pre-index normalised face names for O(1) lookup in pass 1.
    local norm_to_face = {}
    for _, face in ipairs(face_list) do
        local n = _normName(face)
        if not norm_to_face[n] then norm_to_face[n] = face end
    end

    -- Scan helper.
    local function scanDir(dir, cb)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for file in lfs.dir(dir) do
            if file:match("%.[to][tf][f]$") or file:match("%.ttc$") then
                cb(file)
            end
        end
    end

    -- Pass 1: exact normalised match.
    local visited = {}
    for _, dir in ipairs(dirs) do
        if not visited[dir] then
            visited[dir] = true
            scanDir(dir, function(file)
                local base   = file:match("^(.+)%.[^%.]+$") or file
                local face   = norm_to_face[_normName(base)]
                if face and not face_to_file[face] then
                    face_to_file[face] = file
                    file_to_face[file] = face
                end
            end)
        end
    end

    -- Pass 2: substring / prefix match for still-unmatched faces.
    for _, face in ipairs(face_list) do
        if not face_to_file[face] then
            local face_n = _normName(face)
            for _, dir in ipairs(dirs) do
                if not face_to_file[face] then
                    scanDir(dir, function(file)
                        if face_to_file[face] then return end
                        local base   = file:match("^(.+)%.[^%.]+$") or file
                        local base_n = _normName(base)
                        if base_n:find(face_n, 1, true)
                          or face_n:find(base_n, 1, true) then
                            face_to_file[face] = file
                            if not file_to_face[file] then
                                file_to_face[file] = face
                            end
                        end
                    end)
                end
            end
        end
    end

    return face_to_file, file_to_face
end

--- Lazy getter: builds the map once, then returns the cached tables.
function FontSwitcher:_getFontMap(fonts)
    if not self._face_to_file then
        self._face_to_file, self._file_to_face = _buildFontMap(fonts)
    end
    return self._face_to_file, self._file_to_face
end

--- Given a filename from FontChooser, resolve the best-matching face name.
--- Returns nil when no match can be determined.
function FontSwitcher:_fileToFaceName(selected_file, fonts)
    local _, file_to_face = self:_getFontMap(fonts)

    -- 1. Direct cache hit.
    if file_to_face[selected_file] then return file_to_face[selected_file] end

    -- 2. Exact normalised match against the live face list.
    local base_n = _normName(selected_file:match("^(.+)%.[^%.]+$") or selected_file)
    for _, face in ipairs(fonts) do
        if _normName(face) == base_n then return face end
    end

    -- 3. Substring / prefix match (last resort).
    for _, face in ipairs(fonts) do
        local fn = _normName(face)
        if fn:find(base_n, 1, true) or base_n:find(fn, 1, true) then
            return face
        end
    end

    return nil
end

-- ── showFontMenu: routes to FontChooser or falls back to the original TouchMenu

function FontSwitcher:showFontMenu()
    local fonts = self:getFontList()
    if #fonts == 0 then
        UIManager:show(InfoMessage:new{ text = _("No fonts available.") })
        return
    end

    -- Try our bundled font chooser first (fontchooser_local.lua ships with
    -- the plugin and shows only serif fonts). Fall back to the system widget
    -- if the local file is absent, then to the original TouchMenu.
    local ok_fc, FontChooser = pcall(require, "fontchooser_local")
    if not ok_fc then
        ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
    end
    if ok_fc and FontChooser then
        self:_showWithFontChooser(FontChooser, fonts)
    else
        self:_showTouchMenu(fonts)
    end
end

--- Primary path: FontChooser dialog, mirroring the Zen UI plugin pattern.
function FontSwitcher:_showWithFontChooser(FontChooser, fonts)
    -- Read current face name the same way the original code does.
    local current_face = self.ui.doc_settings:readSetting("font_face")
                      or G_reader_settings:readSetting("cre_font")
                      or (self.ui.document and self.ui.document.default_font)

    local face_to_file, file_to_face = self:_getFontMap(fonts)

    -- Resolve the .ttf file that corresponds to the active face so
    -- FontChooser can pre-highlight it.
    local current_file = current_face and face_to_file[current_face]

    -- Default file fallback — mirrors Zen UI: prefer the footer/status-bar
    -- UI font setting, then the resolved current file, then a hard-coded safe
    -- value.
    local footer_cfg   = G_reader_settings:readSetting("footer") or {}
    local default_file = footer_cfg.text_font_face
                      or current_file
                      or "NotoSans-Regular.ttf"

    UIManager:show(FontChooser:new{
        title             = _("Select Font"),
        font_file         = current_file or default_file,
        default_font_file = default_file,
        callback = function(selected_file)
            -- Map the filename back to a CREngine face name.
            local face = self:_fileToFaceName(selected_file, fonts)
            if face then
                -- Warm the cache so subsequent opens skip the scan.
                file_to_face[selected_file] = face
                face_to_file[face]          = selected_file
                self:applyFont(face)
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Could not match "%s" to a known font.\n\n"
                       .. "If this font was recently added, restart KOReader "
                       .. "so it is registered, then try again."),
                        selected_file
                    ),
                    timeout = 5,
                })
            end
        end,
    })
end

--- Fallback path: original TouchMenu-based font list (unchanged from v1.0).
function FontSwitcher:_showTouchMenu(fonts)
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