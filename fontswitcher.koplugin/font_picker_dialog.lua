--[[--
FontPickerDialog — purpose-built font selection dialog for the Font Switcher plugin.

Design contract:
  • Receives face names and pre-built metadata from the caller (main.lua).
    No filename bridge, no system-widget dependency.
  • Applies the selected font immediately on each tap so the user sees a live
    preview in the document behind the dialog.
  • Stays open until the user explicitly closes it.
  • Filter checkboxes (B / I / Sans / Mono / Deco) persist across sessions via
    G_reader_settings and are applied to the list on every open.
  • Toggling a filter closes and immediately reopens the dialog; the currently
    applied face is preserved as the pre-selection in the new instance.
--]]--

local Blitbuffer       = require("ffi/blitbuffer")
local ButtonTable      = require("ui/widget/buttontable")
local CenterContainer  = require("ui/widget/container/centercontainer")
local FocusManager     = require("ui/widget/focusmanager")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local InfoMessage      = require("ui/widget/infomessage")
local MovableContainer = require("ui/widget/container/movablecontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size             = require("ui/size")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local _                = require("gettext")
local Device           = require("device")
local Screen           = Device.screen

-- ── Persistent filter state ───────────────────────────────────────────────────
-- Initialised once when the module is first required (Lua caches the result).
-- true  = that category IS shown in the list.
-- Defaults: Bold, Italic, and Deco shown; Sans and Mono hidden —
--           the most useful starting point for a reading-font picker.

local _saved = G_reader_settings:readSetting("fontswitcher_filters") or {}
local _filters = {
    bold   = _saved.bold   ~= nil and _saved.bold   or true,
    italic = _saved.italic ~= nil and _saved.italic or true,
    sans   = _saved.sans   ~= nil and _saved.sans   or false,
    mono   = _saved.mono   ~= nil and _saved.mono   or false,
    deco   = _saved.deco   ~= nil and _saved.deco   or true,
}

-- ── Dialog ────────────────────────────────────────────────────────────────────

local FontPickerDialog = FocusManager:extend{
    title        = "",
    face_list    = nil,   -- { "Noto Serif Regular", … } from cre.getFontFaces()
    face_meta    = nil,   -- { [face] = { bold, italic, sans, mono, deco } }
                          --   built by buildFaceMeta() in main.lua and cached there
    current_face = nil,   -- face name to pre-select (current book font)
    on_select    = nil,   -- function(face_name) — called on each selection change
}

function FontPickerDialog:init()
    local s = Screen:getSize()
    local screen_w, screen_h = s.w, s.h
    self.layout = {}

    -- Tap outside the frame → close.
    self.ges_events.TapClose = {
        GestureRange:new{
            ges   = "tap",
            range = Geom:new{ w = screen_w, h = screen_h },
        },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Track the most-recently applied face separately from current_face so
    -- that filter-toggles can reopen the dialog with the right pre-selection
    -- even after the user has browsed away from the original font.
    self.selected_face = self.current_face

    local width = math.floor(math.min(screen_w, screen_h) * 0.8)

    -- ── Title bar ─────────────────────────────────────────────────────────────

    local title_bar = TitleBar:new{
        width            = width,
        title            = self.title,
        align            = "left",
        with_bottom_line = true,
        bottom_v_padding = 0,
        show_parent      = self,
    }

    -- ── Font list ─────────────────────────────────────────────────────────────
    -- Each item applies the font immediately when tapped and records the choice
    -- in self.selected_face so filter-reopens restore the right pre-selection.
    -- Long-pressing an item shows its classification attributes.

    local radio_buttons = {}
    for _, face in ipairs(self.face_list or {}) do
        local meta = (self.face_meta and self.face_meta[face]) or {}
        if not _filters.bold   and meta.bold   then goto continue end
        if not _filters.italic and meta.italic then goto continue end
        if not _filters.sans   and meta.sans   then goto continue end
        if not _filters.mono   and meta.mono   then goto continue end
        if not _filters.deco   and meta.deco   then goto continue end

        local face_ref = face   -- explicit capture for the closures below
        table.insert(radio_buttons, {{
            text     = face,
            name     = face,
            checked  = (face == self.selected_face),
            provider = face,
            face     = meta.file and Font:getFace(meta.file, 22, meta.index) or nil,
            hold_callback = function()
                -- Show classification details on long-press.
                local attrs = {}
                for _, k in ipairs({ "bold", "italic", "sans", "mono", "deco" }) do
                    if meta[k] then table.insert(attrs, k) end
                end
                UIManager:show(InfoMessage:new{
                    text      = face_ref
                               .. (#attrs > 0
                                   and ("\n[" .. table.concat(attrs, ", ") .. "]")
                                   or  ""),
                    show_icon = false,
                })
            end,
        }})
        ::continue::
    end

    -- Guard: RadioButtonTable must receive at least one entry.
    if #radio_buttons == 0 then
        table.insert(radio_buttons, {{
            text     = _("No fonts match the current filters"),
            name     = "",
            checked  = true,
            provider = nil,
        }})
    end

    local scroll_inner_w = width - ScrollableContainer:getScrollbarWidth()
    local dialog_ref = self
    local radio_button_table = RadioButtonTable:new{
        radio_buttons      = radio_buttons,
        width              = scroll_inner_w - 2 * Size.padding.large,
        button_single_line = true,
        no_sep             = true,
        focused            = true,
        parent             = self,
        show_parent        = self,
    }

    -- RadioButtonWidget calls self.parent:onTapSelect(self) directly when
    -- tapped.  Wrapping the method on the instance (not the class) lets us
    -- intercept every selection without modifying RadioButtonTable itself.
    local _orig_onTapSelect = radio_button_table.onTapSelect
    radio_button_table.onTapSelect = function(rbt, radio_button)
        _orig_onTapSelect(rbt, radio_button)          -- original selection logic
        local face = radio_button and radio_button.provider
        if face then
            dialog_ref.selected_face = face
            if dialog_ref.on_select then dialog_ref.on_select(face) end
        end
    end

    self:mergeLayoutInVertical(radio_button_table)

    -- ── Filter row ────────────────────────────────────────────────────────────
    -- One row of buttons, one per category.  Checked state is shown with a
    -- ☑/☐ prefix so no special parent-interface is required.  Tapping a
    -- button toggles the filter, saves to settings, and reopens the dialog.

    local filter_defs = {
        { key = "bold",   label = "B"    },
        { key = "italic", label = "I"    },
        { key = "sans",   label = "Sans" },
        { key = "mono",   label = "Mono" },
        { key = "deco",   label = "Deco" },
    }

    local filter_buttons = {{}}
    for _, f in ipairs(filter_defs) do
        local key        = f.key
        local dialog_ref = self
        table.insert(filter_buttons[1], {
            text     = (_filters[key] and "☑ " or "☐ ") .. f.label,
            callback = function()
                _filters[key] = not _filters[key]
                G_reader_settings:saveSetting("fontswitcher_filters", _filters)
                UIManager:close(dialog_ref)
                UIManager:show(FontPickerDialog:new{
                    title        = dialog_ref.title,
                    face_list    = dialog_ref.face_list,
                    face_meta    = dialog_ref.face_meta,
                    current_face = dialog_ref.selected_face,
                    on_select    = dialog_ref.on_select,
                })
            end,
        })
    end

    local filter_button_table = ButtonTable:new{
        width       = width - 2 * Size.padding.default,
        buttons     = filter_buttons,
        zero_sep    = true,
        show_parent = self,
    }

    -- ── Close button ──────────────────────────────────────────────────────────
    -- "Set font" is removed: selection applies immediately, so only Close is
    -- needed.  The last-applied font persists when the dialog is dismissed.

    local button_table = ButtonTable:new{
        width    = width - 2 * Size.padding.default,
        buttons  = {{
            {
                text     = _("Close"),
                id       = "close",
                callback = function() UIManager:close(self) end,
            },
        }},
        zero_sep    = true,
        show_parent = self,
    }
    self:mergeLayoutInVertical(button_table)

    -- ── Height calculation ────────────────────────────────────────────────────
    -- Cap the scrollable list so the dialog fits within 80 % of screen height.
    -- Span accounting: 2× above list, 1× below list, 1× above button row = 4
    -- vertical_large units; doubled for the two VerticalSpan widgets that
    -- bracket the filter row → 6 total.

    self.radio_button_table_height = radio_button_table:getSize().h
    local max_list_h = math.floor(screen_h * 0.8
        - title_bar:getHeight()
        - Size.span.vertical_large * 6
        - filter_button_table:getSize().h
        - button_table:getSize().h)

    if self.radio_button_table_height > max_list_h then
        self.is_scrollable = true
        local checked = radio_button_table.checked_button
        if checked then
            -- Snap container height to a whole number of button rows.
            local item_h = checked:getSize().h
            self.radio_buttons_per_page        = math.floor(max_list_h / item_h)
            self.radio_button_container_height = self.radio_buttons_per_page * item_h
        else
            -- Current face not in filtered list — no pre-selection.
            -- Skip the snap; scroll still works, just without row alignment.
            self.radio_button_container_height = max_list_h
        end
    else
        self.radio_button_container_height = self.radio_button_table_height
    end

    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = self.radio_button_container_height },
        show_parent = self,
        CenterContainer:new{
            dimen = Geom:new{ w = scroll_inner_w, h = self.radio_button_table_height },
            radio_button_table,
        },
    }
    self:scrollToChecked()

    -- ── Assemble ──────────────────────────────────────────────────────────────

    local dialog_frame = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ width = Size.span.vertical_large * 2 },
            self.cropping_widget,
            VerticalSpan:new{ width = Size.span.vertical_large },
            filter_button_table,
            VerticalSpan:new{ width = Size.span.vertical_large },
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = button_table:getSize().h },
                button_table,
            },
        },
    }

    self.movable = MovableContainer:new{ dialog_frame }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        self.movable,
    }
end

-- ── Scroll helpers ────────────────────────────────────────────────────────────

function FontPickerDialog:scrollToChecked()
    if not self.is_scrollable then return end
    local rbt = self.cropping_widget[1][1]
    if not (rbt and rbt.checked_button) then return end
    local prev_pages = math.floor(
        (rbt.checked_button.row - 1) / self.radio_buttons_per_page
    )
    local offset     = prev_pages * self.radio_button_container_height
    local max_offset = self.radio_button_table_height - self.radio_button_container_height
    self.cropping_widget:setScrolledOffset({ x = 0, y = math.min(offset, max_offset) })
end

-- ── Widget lifecycle ──────────────────────────────────────────────────────────

function FontPickerDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
    return true
end

function FontPickerDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.movable.dimen
    end)
end

function FontPickerDialog:onTapClose(arg, ges_ev)
    if ges_ev.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
    end
    return true
end

function FontPickerDialog:onClose()
    UIManager:close(self)
    return true
end

return FontPickerDialog
