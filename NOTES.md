# Font Switcher Plugin — Design Notes

## File layout

```
fontswitcher.koplugin/
├── _meta.lua
├── main.lua
├── fontchooser_local.lua
└── NOTES.md
```

## Why fontchooser_local.lua is named that way

KOReader does not add the plugin directory to `package.path` automatically.
`main.lua` prepends it at startup:

```lua
local _plugin_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = _plugin_dir .. "?.lua;" .. package.path
```

The file is named `fontchooser_local` (not `fontchooser`) deliberately.
If it were named `fontchooser`, prepending the plugin dir would shadow
`ui/widget/fontchooser` for every other module in the session — the status
bar font picker, any other plugin that uses it, etc.  The unique name keeps
the override scoped to this plugin's own require call.

## Require fallback chain (showFontMenu)

```
fontchooser_local   ← bundled, serif-only filter
      ↓ (if missing or fails to load)
ui/widget/fontchooser  ← system widget, all fonts
      ↓ (if KOReader too old to have it)
TouchMenu              ← original fontswitcher behaviour, unchanged
```

## Face-name ↔ filename mapping

FontChooser speaks filenames ("NotoSerif-Regular.ttf").
CREngine's font API speaks face names ("Noto Serif Regular").

`_buildFontMap()` bridges them by scanning font directories in two passes:

1. **Exact normalised match** — lower-case, strip spaces/hyphens/underscores,
   compare basename to face name.  Covers the vast majority of fonts.
2. **Substring / prefix match** — for fonts where the filename and face name
   diverge more significantly.

The result is cached on the plugin instance so the scan only happens once
per session.

## Serif-only filter in fontchooser_local.lua

Uses `FontList.fontinfo` metadata populated by KOReader's font scanner —
no heuristic name matching.

### Monospace (`isMonospace`)

FreeType sets `fontinfo[1].mono = true` when the face carries
`FT_FACE_FLAG_FIXED_WIDTH`.  This is exact.

### Sans-serif (`isSansSerif`)

Reads OS/2 panose bytes stored in `fontinfo[1]`:

| field      | meaning                                        |
|------------|------------------------------------------------|
| `panose_1` | Family kind. `2` = Latin text font.            |
| `panose_2` | Serif style (only meaningful when `panose_1 == 2`). |

`panose_2` values for sans-serif:

| value | variant             |
|-------|---------------------|
| 9     | normal sans         |
| 10    | obtuse sans         |
| 11    | perpendicular sans  |
| 12    | flared              |
| 13    | rounded             |

Values 2–8 are serif variants.  Value 0 means "not set by the font author"
— these fonts **pass through** (shown in the list) rather than being hidden,
so poorly-tagged fonts are not silently lost.

## FontChooser dialog size

Both dimensions are calculated internally in `fontchooser_local.lua` and
are not exposed as constructor parameters:

```lua
-- width
local width = math.floor(math.min(screen_w, screen_h) * 0.8)

-- maximum height of the scrollable list area
local max_radio_button_container_height = math.floor(screen_h * 0.8
    - title_bar:getHeight()
    - Size.span.vertical_large * 4
    - button_table:getSize().h)
```

To resize the dialog, change the `0.8` multipliers in `fontchooser_local.lua`
directly.