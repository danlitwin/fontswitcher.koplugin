local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local CreDocument = require("document/credocument")
local Device = require("device")

-- Resolve the plugin directory so font_picker_dialog.lua (bundled alongside
-- this file) can be loaded with a plain require() without shadowing any
-- system module.
local _plugin_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = _plugin_dir .. "?.lua;" .. package.path

-- FontList provides per-file metadata (panose bytes, mono flag) used when
-- building the face→attribute cache.  Load defensively; some stripped builds
-- may not include it.
local ok_fl, FontList = pcall(require, "fontlist")
if not ok_fl then FontList = nil end

-- ── Face metadata helpers ─────────────────────────────────────────────────────
-- norm() collapses a name to a case-insensitive, punctuation-free token so
-- that family names and face names can be prefix-matched reliably.
-- e.g. "Noto Serif" → "notserif", "Noto Serif Regular" → "notoserifregular"

local function norm(s)
    return (s or ""):lower():gsub("[%s%-_]+", "")
end

-- buildFaceMeta() maps every face name returned by cre.getFontFaces() to a
-- small attribute record used by FontPickerDialog to apply the filter row.
--
-- Bold / italic are detected from the face name itself (weight words in the
-- name are more reliable than per-file fontinfo.bold for multi-weight families).
-- Sans, mono, and deco are detected from panose / FreeType metadata in FontList
-- (family-level properties shared by every weight of the same family).

local function buildFaceMeta(face_list)
    -- Index fontinfo by normalised family name; one entry per family suffices
    -- because panose and mono flag are the same for all weights of a family.
    local family_data = {}
    if FontList and FontList.fontinfo then
        for _, font_info in pairs(FontList.fontinfo) do
            local info = font_info and font_info[1]
            if info and info.name then
                local fn = norm(info.name)
                if fn ~= "" and not family_data[fn] then
                    family_data[fn] = info
                end
            end
        end
    end

    local meta = {}
    for _, face in ipairs(face_list) do
        local fl = face:lower()
        local fn = norm(face)

        -- Bold / italic from weight / style words in the face name.
        local is_bold   = fl:find("bold")    ~= nil
                       or fl:find("heavy")   ~= nil
                       or fl:find("black")   ~= nil
        local is_italic = fl:find("italic")  ~= nil
                       or fl:find("oblique") ~= nil

        -- Family-level classification: find the fontinfo entry whose normalised
        -- family name is the longest prefix of the normalised face name.
        -- Longest-match prevents "Noto" (sans) from shadowing "Noto Serif"
        -- when pairs() happens to visit the shorter key first.
        local fd, fd_len = nil, 0
        for family_n, info in pairs(family_data) do
            if fn:find(family_n, 1, true) == 1 and #family_n > fd_len then
                fd, fd_len = info, #family_n
            end
        end

        -- Mono: FreeType flag preferred; name-heuristic as fallback.
        local is_mono = (fd and fd.mono == true)
                     or fl:find("mono") ~= nil
                     or fl:find("code") ~= nil

        -- Sans / deco: panose byte 1 only (family-level; requires fontinfo).
        --   panose_1 == 2 → Latin text; panose_2 9–13 → sans-serif variants.
        --   panose_1 == 4 → decorative; panose_1 == 5 → symbol / pictorial.
        local is_sans, is_deco = false, false
        if fd then
            local p1 = fd.panose_1 or 0
            if p1 == 2 then
                local p2 = fd.panose_2 or 0
                is_sans = p2 >= 9 and p2 <= 13
            elseif p1 == 4 or p1 == 5 then
                is_deco = true
            end
        end

        meta[face] = {
            bold   = is_bold,
            italic = is_italic,
            mono   = is_mono,
            sans   = is_sans,
            deco   = is_deco,
        }
    end
    return meta
end

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

--- Lazily builds and caches a face-name → attribute table for the filter row.
--- The cache lives on the plugin instance for the document's lifetime.
function FontSwitcher:_getFaceMeta()
    if not self._face_meta_cache then
        -- Ensure the face list is also cached before building meta.
        if not self._face_list_cache then
            self._face_list_cache = self:getFontList()
        end
        self._face_meta_cache = buildFaceMeta(self._face_list_cache)
    end
    return self._face_meta_cache
end

--- Returns the face list with the current filter state applied, so that
--- Next / Previous Font cycle only through fonts visible in the dialog.
--- Filter state is read live from G_reader_settings so it always reflects
--- whatever the user last set in the dialog.
--- Note: defaults here must stay in sync with those in font_picker_dialog.lua.
function FontSwitcher:_getFilteredFaces()
    local face_list = self._face_list_cache or self:getFontList()
    local face_meta = self:_getFaceMeta()
    local saved = G_reader_settings:readSetting("fontswitcher_filters") or {}
    local f = {
        bold   = saved.bold   ~= nil and saved.bold   or true,
        italic = saved.italic ~= nil and saved.italic or true,
        sans   = saved.sans   ~= nil and saved.sans   or false,
        mono   = saved.mono   ~= nil and saved.mono   or false,
        deco   = saved.deco   ~= nil and saved.deco   or true,
    }
    local filtered = {}
    for _, face in ipairs(face_list) do
        local m = face_meta[face] or {}
        if  (f.bold   or not m.bold)
        and (f.italic or not m.italic)
        and (f.sans   or not m.sans)
        and (f.mono   or not m.mono)
        and (f.deco   or not m.deco) then
            table.insert(filtered, face)
        end
    end
    return filtered
end

--- Returns the face name currently set for the open document.
--- Mirrors the three-way fallback used by the original plugin.
function FontSwitcher:getCurrentFace()
    return self.ui.doc_settings:readSetting("font_face")
        or G_reader_settings:readSetting("cre_font")
        or (self.ui.document and self.ui.document.default_font)
end

function FontSwitcher:switchFont(direction)
    -- Use the filtered list so Next / Previous respect the same checkboxes
    -- as the dialog.  Meta and base list are cached; filter state is read
    -- live so it always reflects the user's most recent dialog settings.
    local fonts = self:_getFilteredFaces()
    if #fonts == 0 then
        UIManager:show(InfoMessage:new{ text = _("No fonts found in system.") })
        return
    end

    local current_font = self:getCurrentFace() or "Spleen"
                  
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
    -- Build and cache the face list on first open.
    if not self._face_list_cache then
        self._face_list_cache = self:getFontList()
    end
    if #self._face_list_cache == 0 then
        UIManager:show(InfoMessage:new{ text = _("No fonts available.") })
        return
    end

    local FontPickerDialog = require("font_picker_dialog")
    UIManager:show(FontPickerDialog:new{
        title        = _("Select Font"),
        face_list    = self._face_list_cache,
        face_meta    = self:_getFaceMeta(),
        current_face = self:getCurrentFace(),
        callback     = function(face) self:applyFont(face) end,
    })
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
