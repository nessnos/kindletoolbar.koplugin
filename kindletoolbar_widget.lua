--[[--
The overlay shown by the Kindle-style toolbar plugin.

It is a transparent full-screen InputContainer that only paints two panels:
  * a top panel (status row, toolbar buttons, book title),
  * a bottom panel (chapter, page/time/percent line, progress slider).
Taps outside the panels close it, like on a stock Kindle.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local datetime = require("datetime")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext
local RenderImage = require("ui/renderimage")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local function S(v) return Screen:scaleBySize(v) end

-- ---------------------------------------------------------------------------
-- Small drawing widgets
-- ---------------------------------------------------------------------------

-- Anything that just needs "tap me -> callback".
local Tappable = InputContainer:extend{
    callback = nil,
}

function Tappable:init()
    self.ges_events = {
        TapTappable = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        },
    }
end

function Tappable:onTapTappable()
    if self.callback then self.callback() end
    return true
end

-- Wide, shallow chevron pointing down (the "pull down" hint on Kindle).
local Chevron = Widget:extend{
    width = nil,
    height = nil,
    thickness = nil,
}

function Chevron:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Chevron:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- A wide, shallow "V" with a thick stroke and rounded ends, like KindleOS'
    local w, t = self.width, self.thickness
    local r = math.floor(t / 2)
    local half = (w - 1) / 2
    local drop = self.height - t -- how far the tip sits below the ends
    for i = r, w - 1 - r do
        local d = half - math.abs(i - half) -- 0 at the ends, half at the tip
        local yy = y + math.floor(drop * (d - r) / (half - r) + 0.5)
        bb:paintRect(x + i, yy, 1, t, BLACK)
    end
    -- round caps
    bb:paintRoundedRect(x, y, t, t, BLACK, r)
    bb:paintRoundedRect(x + w - t, y, t, t, BLACK, r)
end

-- Three vertical dots (overflow menu).
local Dots = Widget:extend{
    size = nil,
}

function Dots:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function Dots:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local r = math.max(2, math.floor(self.size / 10))
    local d = 2 * r
    local gap = math.floor(self.size / 3)
    local cx = x + math.floor((self.size - d) / 2)
    local cy = y + math.floor((self.size - d) / 2)
    for i = -1, 1 do
        bb:paintRoundedRect(cx, cy + i * gap, d, d, BLACK, r)
    end
end

-- |◀ and ▶| icons for previous / next chapter.
local SkipIcon = Widget:extend{
    size = nil,
    direction = "next", -- or "prev"
}

function SkipIcon:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function SkipIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local h = math.floor(self.size * 0.7)
    local top = y + math.floor((self.size - h) / 2)
    local bar_w = math.max(2, math.floor(self.size / 9))
    local tri_w = math.floor(h * 0.8)
    local total = bar_w + tri_w
    local left = x + math.floor((self.size - total) / 2)
    local half = h / 2
    if self.direction == "prev" then
        bb:paintRect(left, top, bar_w, h, BLACK)
        local tip = left + bar_w
        for row = 0, h - 1 do
            local dist = math.abs(row + 0.5 - half) -- 0 at middle row
            local w = math.floor(tri_w * (1 - dist / half) + 0.5)
            if w > 0 then
                bb:paintRect(tip + tri_w - w, top + row, w, 1, BLACK)
            end
        end
    else
        for row = 0, h - 1 do
            local dist = math.abs(row + 0.5 - half)
            local w = math.floor(tri_w * (1 - dist / half) + 0.5)
            if w > 0 then
                bb:paintRect(left, top + row, w, 1, BLACK)
            end
        end
        bb:paintRect(left + tri_w, top, bar_w, h, BLACK)
    end
end

-- The Kindle-looking slider: thin track, thick filled part, round knob,
-- plus an optional marker for the page you started from.
local Slider = Widget:extend{
    width = nil,
    height = nil,
    percentage = 0,
    origin_percentage = nil,
    ticks = nil,        -- list of percentages
    dragging = false,
}

function Slider:init()
    self.knob_d = S(24)
    self.knob_r = math.floor(self.knob_d / 2)
end

function Slider:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Slider:_xFor(pct)
    local usable = self.width - 2 * self.knob_r
    return math.floor(self.knob_r + usable * math.max(0, math.min(1, pct)) + 0.5)
end

--- Screen x -> percentage (0..1), clamped.
function Slider:percentageAt(screen_x)
    if not self.dimen then return nil end
    local usable = self.width - 2 * self.knob_r
    if usable <= 0 then return 0 end
    local pct = (screen_x - self.dimen.x - self.knob_r) / usable
    return math.max(0, math.min(1, pct))
end

function Slider:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local cy = y + math.floor(self.height / 2)
    local track_t = math.max(1, Size.line.medium)
    local fill_t = S(5)
    -- Track
    bb:paintRect(x + self.knob_r, cy - math.floor(track_t / 2), self.width - 2 * self.knob_r, track_t, GRAY)
    -- Chapter ticks
    if self.ticks then
        local tick_h = S(10)
        local tick_w = math.max(1, Size.line.medium)
        for _, pct in ipairs(self.ticks) do
            bb:paintRect(x + self._xFor(self, pct), cy - math.floor(tick_h / 2), tick_w, tick_h, GRAY)
        end
    end
    -- Filled part
    local kx = x + self:_xFor(self.percentage)
    if kx > x + self.knob_r then
        bb:paintRect(x + self.knob_r, cy - math.floor(fill_t / 2), kx - x - self.knob_r, fill_t, BLACK)
    end
    -- Origin marker: a small pin
    if self.origin_percentage then
        local ox = x + self:_xFor(self.origin_percentage)
        local pin_w = math.max(2, Size.line.thick)
        local pin_h = self.knob_d + S(8)
        bb:paintRect(ox - math.floor(pin_w / 2), cy - math.floor(pin_h / 2), pin_w, pin_h, BLACK)
        local cap = S(9)
        bb:paintRoundedRect(ox - math.floor(cap / 2), cy - math.floor(pin_h / 2) - cap + 2, cap, cap, BLACK, math.floor(cap / 2))
    end
    -- Knob
    local r = self.knob_r
    if self.dragging then
        bb:paintRoundedRect(kx - r, cy - r, self.knob_d, self.knob_d, BLACK, r)
    else
        bb:paintRoundedRect(kx - r, cy - r, self.knob_d, self.knob_d, WHITE, r)
        bb:paintBorder(kx - r, cy - r, self.knob_d, self.knob_d, math.max(2, Size.border.thick), BLACK, r)
    end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function formatDuration(seconds)
    local mins = math.floor(seconds / 60 + 0.5)
    if mins < 1 then
        return _("less than a min")
    end
    if mins < 60 then
        return T(N_("1 min", "%1 mins", mins), mins)
    end
    local h = math.floor(mins / 60)
    local m = mins % 60
    local hs = T(N_("1 hr", "%1 hrs", h), h)
    if m == 0 then return hs end
    return hs .. " " .. T(N_("1 min", "%1 mins", m), m)
end

-- ---------------------------------------------------------------------------
-- KindleOS-style dropdown (the ⋮ menu): a plain white box with a thin dark
-- border, left-aligned regular-weight items with roomy rows,
-- and thin rules between groups. Tap outside to close.
-- ---------------------------------------------------------------------------

local DropdownItem = InputContainer:extend{
    text = nil,
    width = nil,
    height = nil,
    enabled = true,
    callback = nil,
    face = nil,
    pad_left = nil,
    show_parent = nil,
}

function DropdownItem:init()
    self.label = TextWidget:new{
        text = self.text,
        face = self.face,
        fgcolor = self.enabled and BLACK or GRAY,
        max_width = self.width - 2 * self.pad_left,
    }
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_left = self.pad_left,
        background = WHITE,
        LeftContainer:new{
            dimen = Geom:new{ w = self.width - self.pad_left, h = self.height },
            self.label,
        },
    }
    self.ges_events = {
        TapItem = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function DropdownItem:onTapItem()
    if not self.enabled or not self.callback then return true end
    if G_reader_settings:nilOrTrue("flash_ui") and self.dimen then
        -- Kindle-like press feedback: invert the row briefly
        self[1].invert = true
        UIManager:widgetInvert(self[1], self.dimen.x, self.dimen.y)
        UIManager:setDirty(nil, "fast", self.dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
    end
    self.callback()
    return true
end

local KindleDropdown = InputContainer:extend{
    items = nil,   -- { { text=, callback=, enabled=, separator= }, ... }
    right = nil,   -- right edge x
    top = nil,     -- top y
    covers_fullscreen = false,
}

function KindleDropdown:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local face = Font:getFace("cfont", 21)
    local pad_left = S(28)
    local row_h = S(54)
    local border = math.max(2, Size.border.window)
    self.shadow = 0

    -- width: widest label + padding, within sensible bounds
    local widest = 0
    for _, it in ipairs(self.items) do
        local tw = TextWidget:new{ text = it.text, face = face }
        widest = math.max(widest, tw:getSize().w)
        tw:free()
    end
    local width = math.max(math.floor(sw * 0.42), widest + 2 * pad_left + S(24))
    width = math.min(width, sw - 2 * S(10))

    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, VerticalSpan:new{ width = S(10) })
    for i, it in ipairs(self.items) do
        table.insert(vg, DropdownItem:new{
            text = it.text, width = width - 2 * border, height = row_h,
            enabled = it.enabled ~= false, face = face, pad_left = pad_left,
            show_parent = self,
            callback = it.callback,
        })
        if it.separator and i < #self.items then
            table.insert(vg, VerticalSpan:new{ width = S(6) })
            table.insert(vg, LineWidget:new{ background = BLACK,
                dimen = Geom:new{ w = width - 2 * border, h = math.max(1, Size.line.medium) } })
            table.insert(vg, VerticalSpan:new{ width = S(6) })
        end
    end
    table.insert(vg, VerticalSpan:new{ width = S(10) })

    self.box = FrameContainer:new{
        bordersize = border, margin = 0, padding = 0, radius = 0,
        color = BLACK, background = WHITE,
        vg,
    }
    local size = self.box:getSize()
    local x = math.max(0, (self.right or sw) - size.w)
    local y = math.min(self.top or 0, sh - size.h - self.shadow)
    self.box_dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self.box.overlap_offset = { x, y }
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = sw, h = sh },
        allow_mirroring = false,
        self.box,
    }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        AnyGesture = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function KindleDropdown:refreshRegion()
    local d = self.box_dimen
    return Geom:new{ x = d.x, y = d.y, w = d.w + self.shadow, h = d.h + self.shadow }
end

function KindleDropdown:onShow()
    UIManager:setDirty(self, function() return "ui", self:refreshRegion() end)
    return true
end

function KindleDropdown:onCloseWidget()
    local r = self:refreshRegion()
    UIManager:setDirty(nil, function() return "ui", r end)
end

function KindleDropdown:onTapOutside(_, ges)
    if not ges.pos:intersectWith(self.box_dimen) then
        UIManager:close(self)
    end
    return true
end

function KindleDropdown:onAnyGesture()
    return true
end

function KindleDropdown:onClose()
    UIManager:close(self)
    return true
end

local INFO_MODES = { "chapter_time", "book_time", "chapter_pages", "book_pages" }

-- ---------------------------------------------------------------------------
-- The overlay
-- ---------------------------------------------------------------------------

local KindleToolbarWidget = InputContainer:extend{
    name = "kindletoolbar",
    ui = nil,
    plugin = nil,
}

function KindleToolbarWidget:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.pad = S(14)
    self.inner_w = self.screen_w - 2 * self.pad

    local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {}
    for _, g in ipairs{ "tap", "touch", "pan", "hold", "hold_pan", "pan_release", "hold_release", "swipe", "double_tap" } do
        self.ges_events["Hud_" .. g] = { GestureRange:new{ ges = g, range = full }, event = "HudGesture" }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.page_count = self.ui.document:getPageCount()
    self.zoom = self.plugin.settings.zoom_pages ~= false
    self.images = {}      -- page -> scaled blitbuffer we own
    self.pending = {}     -- page -> true while a thumbnail is being generated
    self.batch_id = "kindletoolbar" .. tostring(os.time()) .. tostring(math.random(1000))
    self:buildTop()
    self:buildBottom()
    self:assemble()
    if self.zoom then
        -- The page is on screen right now: take it as the current page's picture.
        self:takeSnapshot()
        self:ensureImages()
    end
end

-- Page <-> slider percentage (page 1 at the far left, last page at the far right)
function KindleToolbarWidget:pctForPage(page)
    if self.page_count <= 1 then return 0 end
    return (page - 1) / (self.page_count - 1)
end

function KindleToolbarWidget:pageForPct(pct)
    local p = 1 + math.floor(pct * (self.page_count - 1) + 0.5)
    return math.max(1, math.min(self.page_count, p))
end

function KindleToolbarWidget:currentPage()
    return self.ui:getCurrentPage()
end

-- ---------------------------------------------------------------- top panel

function KindleToolbarWidget:buildTop()
    local pad_span = HorizontalSpan:new{ width = self.pad }
    local inner_w = self.inner_w

    -- Status row: clock | chevron | wifi battery%
    local status_h = S(34)
    local status_face = Font:getFace("cfont", 15)
    -- Same glyphs as KOReader's status bar and SimpleUI's top bar (Nerd Font symbols)
    local icon_face = Font:getFace("nerdfonts/symbols.ttf", 17)
    local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local right = HorizontalGroup:new{ align = "center" }
    if Device:hasWifiToggle() then
        local NetworkMgr = require("ui/network/manager")
        local ok, on = pcall(function() return NetworkMgr:isWifiOn() end)
        on = ok and on
        if on or not self.plugin.settings.hide_wifi_off then
            table.insert(right, TextWidget:new{ text = on and "\u{ECA8}" or "\u{ECA9}", face = icon_face })
            table.insert(right, HorizontalSpan:new{ width = S(12) })
        end
    end
    if Device:hasBattery() then
        pcall(function()
            local powerd = Device:getPowerDevice()
            local lvl = powerd:getCapacity()
            if type(lvl) ~= "number" then return end
            local sym = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), lvl) or ""
            table.insert(right, TextWidget:new{ text = sym, face = icon_face })
            table.insert(right, TextWidget:new{ text = lvl .. "%", face = status_face })
        end)
    end
    local status_dimen = Geom:new{ w = inner_w, h = status_h }
    local status_row = Tappable:new{
        callback = function() self:openMainMenu() end,
        OverlapGroup:new{
            dimen = status_dimen:copy(),
            allow_mirroring = false,
            LeftContainer:new{ dimen = status_dimen:copy(), TextWidget:new{ text = clock, face = status_face } },
            CenterContainer:new{ dimen = status_dimen:copy(), Chevron:new{ width = S(66), height = S(10), thickness = math.max(3, S(4)) } },
            RightContainer:new{ dimen = status_dimen:copy(), right },
        },
    }

    -- Toolbar row: ← Library  ...  Aa  ☰  notebook  search  ⋮
    local tb_h = S(56)
    local icon = S(30)
    local ipad = S(9)
    local target = self.plugin:getLibraryTarget()
    local library = Tappable:new{
        callback = function()
            self:closeAnd(function() self.plugin:goToLibraryTarget(target.id) end)
        end,
        HorizontalGroup:new{
            align = "center",
            IconWidget:new{ icon = "chevron.left", width = S(24), height = S(24) },
            HorizontalSpan:new{ width = S(6) },
            TextWidget:new{ text = target.label, face = Font:getFace("cfont", 20) },
        },
    }
    local function iconButton(name, cb)
        return IconButton:new{
            icon = name, width = icon, height = icon, padding = ipad,
            allow_flash = false, show_parent = self, callback = cb,
        }
    end
    local buttons = HorizontalGroup:new{
        align = "center",
        iconButton("appbar.textsize", function()
            self:closeAnd(function() self.ui:handleEvent(Event:new("ShowConfigMenu")) end)
        end),
        iconButton("appbar.menu", function()
            self:closeAnd(function() self.ui:handleEvent(Event:new("ShowToc")) end)
        end),
        iconButton("appbar.navigation", function()
            self:closeAnd(function() self.ui:handleEvent(Event:new("ShowBookmark")) end)
        end),
        iconButton("appbar.search", function()
            self:closeAnd(function() self.ui:handleEvent(Event:new("ShowFulltextSearchInput")) end)
        end),
        self:makeDots(ipad, icon),
    }
    local tb_dimen = Geom:new{ w = inner_w, h = tb_h }
    local toolbar_row = OverlapGroup:new{
        dimen = tb_dimen:copy(),
        allow_mirroring = false,
        LeftContainer:new{ dimen = tb_dimen:copy(), library },
        RightContainer:new{ dimen = tb_dimen:copy(), buttons },
    }

    -- Book title row
    local title_h = S(46)
    local title = self.ui.doc_props and self.ui.doc_props.display_title or ""
    local title_row = LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = title_h },
        TextWidget:new{
            text = title,
            face = Font:getFace("cfont", 18),
            bold = true,
            max_width = inner_w,
        },
    }

    self.top_panel = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = WHITE,
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{ pad_span, status_row },
            HorizontalGroup:new{ pad_span, toolbar_row },
            LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = self.screen_w, h = Size.line.medium } },
            HorizontalGroup:new{ pad_span, title_row },
            LineWidget:new{ background = BLACK, dimen = Geom:new{ w = self.screen_w, h = Size.line.thick } },
        },
    }
end

-- ------------------------------------------------------------- bottom panel

function KindleToolbarWidget:getInfoLine(page, previewing)
    local doc = self.ui.document
    local total = self.page_count
    local parts = {}

    -- Page X of Y (use publisher page labels for the current page when enabled)
    local pagemap = self.ui.pagemap
    if not previewing and pagemap and pagemap:wantsPageLabels() then
        local label = pagemap:getCurrentPageLabel(true)
        local last = pagemap:getLastPageLabel(true)
        table.insert(parts, T(_("Page %1 of %2"), label, last))
    else
        table.insert(parts, T(_("Page %1 of %2"), page, total))
    end

    -- Time / pages left
    local mode = self.plugin.settings.info_mode or "chapter_time"
    local chapter_left = self.ui.toc:getChapterPagesLeft(page, true)
    local book_left = doc:getTotalPagesLeft(page)
    if chapter_left == nil then chapter_left = book_left end
    local stats = self.ui.statistics
    local avg = stats and stats.settings and stats.settings.is_enabled and stats.avg_time
    if avg and (avg ~= avg or avg <= 0) then avg = nil end -- NaN / zero
    if (mode == "chapter_time" or mode == "book_time") and not avg then
        -- No reading statistics yet: fall back to page counts
        mode = mode == "chapter_time" and "chapter_pages" or "book_pages"
    end
    if mode == "chapter_time" then
        table.insert(parts, T(_("Time left in chapter: %1"), formatDuration((chapter_left + 1) * avg)))
    elseif mode == "book_time" then
        table.insert(parts, T(_("Time left in book: %1"), formatDuration((book_left + 1) * avg)))
    elseif mode == "chapter_pages" then
        table.insert(parts, T(N_("1 page left in chapter", "%1 pages left in chapter", chapter_left + 1), chapter_left + 1))
    elseif mode == "book_pages" then
        table.insert(parts, T(N_("1 page left in book", "%1 pages left in book", book_left + 1), book_left + 1))
    end

    table.insert(parts, math.floor(page / total * 100) .. "%")
    return table.concat(parts, " | ")
end

function KindleToolbarWidget:buildBottom()
    local pad_span = HorizontalSpan:new{ width = self.pad }
    local cur = self:currentPage()
    local page = self.preview_page or cur
    local previewing = self.preview_page ~= nil and self.preview_page ~= cur

    local vg = VerticalGroup:new{
        align = "center",
        LineWidget:new{ background = BLACK, dimen = Geom:new{ w = self.screen_w, h = Size.line.thick } },
        VerticalSpan:new{ width = S(10) },
    }

    -- Chapter title
    local chapter = self.ui.toc:getTocTitleByPage(page) or ""
    table.insert(vg, CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = S(34) },
        TextWidget:new{ text = chapter ~= "" and chapter or " ", face = Font:getFace("cfont", 19), max_width = self.inner_w },
    })

    -- Info line (tap to cycle what's shown)
    self.info_container = FrameContainer:new{
        bordersize = 0, padding = 0, padding_top = S(2), padding_bottom = S(4),
        TextWidget:new{
            text = self:getInfoLine(page, previewing),
            face = Font:getFace("cfont", 16),
            max_width = self.inner_w,
        },
    }
    table.insert(vg, CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.info_container:getSize().h },
        self.info_container,
    })

    -- "Back to page N" pill, only once you have moved away
    local origin_page = self.plugin:getOriginPage()
    -- The pill floats just above the bottom panel (see assemble), so the panel
    -- itself never changes height.
    local pill_h = S(44)
    self.pill = nil
    if origin_page and origin_page ~= page then
        local label = origin_page
        local pagemap = self.ui.pagemap
        if pagemap and pagemap:wantsPageLabels() and self.plugin.origin.label then
            label = self.plugin.origin.label
        end
        self.pill = CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = pill_h },
            Button:new{
                text = T(_("Back to page %1"), label),
                text_font_size = 16,
                radius = S(18),
                bordersize = Size.border.button,
                padding_h = S(14),
                show_parent = self,
                callback = function()
                    self.preview_page = nil
                    self.plugin:goToOrigin()
                    self:refresh()
                end,
            },
        }
    end
    table.insert(vg, VerticalSpan:new{ width = S(4) })

    -- Slider row: |◀  ━━━━━●────  ▶|
    local btn = S(30)
    local btn_pad = S(10)
    local btn_total = btn + 2 * btn_pad
    local slider_h = S(56)
    local ticks
    if self.plugin.settings.show_ticks ~= false then
        ticks = {}
        for _, p in ipairs(self.ui.toc:getTocTicksFlattened() or {}) do
            table.insert(ticks, self:pctForPage(p))
        end
    end
    -- The slider row always sits at the same place (it's the last row), so keep the
    -- previous geometry: gestures can arrive before the new slider gets painted.
    local old_slider_dimen = self.slider and self.slider.dimen
    self.slider = Slider:new{
        width = self.inner_w - 2 * btn_total,
        height = slider_h,
        percentage = self:pctForPage(page),
        origin_percentage = origin_page and origin_page ~= page and self:pctForPage(origin_page) or nil,
        ticks = ticks,
        dragging = self.dragging,
    }
    if old_slider_dimen then
        self.slider.dimen = old_slider_dimen:copy()
    end
    local function skip(direction, cb)
        return Tappable:new{
            callback = cb,
            FrameContainer:new{
                bordersize = 0, padding = btn_pad,
                SkipIcon:new{ size = btn, direction = direction },
            },
        }
    end
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        pad_span,
        skip("prev", function() self:gotoChapter(-1) end),
        self.slider,
        skip("next", function() self:gotoChapter(1) end),
    })
    table.insert(vg, VerticalSpan:new{ width = S(10) })

    self.bottom_panel = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = WHITE,
        vg,
    }
end

-- ------------------------------------------------------- zoomed-out pages

-- Paints the middle of the screen: the current page shrunk into a bordered card,
-- with the previous and next pages peeking in from the sides (like KindleOS).
local PageCards = Widget:extend{
    owner = nil,
    width = nil,
    height = nil,
}

function PageCards:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function PageCards:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local o = self.owner
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local bw = Size.border.thin
    for _, card in ipairs(o:cardLayout()) do
        local cx, cy, cw, ch = card.x, card.y, card.w, card.h
        -- clip the white card background to the screen
        local rx = math.max(0, cx)
        local rw = math.min(self.width, cx + cw) - rx
        if rw > 0 then
            bb:paintRect(rx, cy, rw, ch, WHITE)
        end
        local img = o.images[card.page]
        if img then
            local iw, ih = img:getWidth(), img:getHeight()
            bb:blitFrom(img, cx + math.floor((cw - iw) / 2), cy + math.floor((ch - ih) / 2), 0, 0, iw, ih)
        else
            -- Not rendered yet: show the page number
            local tw = TextWidget:new{ text = tostring(card.page), face = Font:getFace("cfont", 22), fgcolor = GRAY }
            local ts = tw:getSize()
            tw:paintTo(bb, cx + math.floor((cw - ts.w) / 2), cy + math.floor((ch - ts.h) / 2))
            tw:free()
        end
        local border = card.center and math.max(2, Size.border.thick) or bw
        -- paintBorder doesn't clip, so draw the four edges ourselves
        local function hline(yy)
            if rw > 0 then bb:paintRect(rx, yy, rw, border, BLACK) end
        end
        local function vline(xx)
            if xx >= 0 and xx + border <= self.width then
                bb:paintRect(xx, cy, border, ch, BLACK)
            end
        end
        hline(cy)
        hline(cy + ch - border)
        vline(cx)
        vline(cx + cw - border)
    end
end

function KindleToolbarWidget:computeCardGeometry()
    local top_h = self.top_panel:getSize().h
    local bottom_h = self.bottom_panel:getSize().h
    local mid_h = self.screen_h - top_h - bottom_h
    local margin = S(12)
    local card_h = math.max(S(60), mid_h - 2 * margin)
    local ratio = self.screen_w / self.screen_h
    local card_w = math.floor(card_h * ratio)
    local max_w = math.floor(self.screen_w * 0.72)
    if card_w > max_w then
        card_w = max_w
        card_h = math.floor(card_w / ratio)
    end
    self.card_w, self.card_h = card_w, card_h
    self.card_y = top_h + math.floor((mid_h - card_h) / 2)
    self.card_x = math.floor((self.screen_w - card_w) / 2)
    self.card_gap = S(22)
    self.mid_dimen = Geom:new{ x = 0, y = top_h, w = self.screen_w, h = mid_h }
end

--- The cards to draw, in screen coordinates.
function KindleToolbarWidget:cardLayout()
    local c = self:centerPage()
    local cards = {}
    local step = self.card_w + self.card_gap
    if c > 1 then
        table.insert(cards, { page = c - 1, x = self.card_x - step, y = self.card_y, w = self.card_w, h = self.card_h })
    end
    if c < self.page_count then
        table.insert(cards, { page = c + 1, x = self.card_x + step, y = self.card_y, w = self.card_w, h = self.card_h })
    end
    table.insert(cards, { page = c, x = self.card_x, y = self.card_y, w = self.card_w, h = self.card_h, center = true })
    return cards
end

function KindleToolbarWidget:centerPage()
    return self.preview_page or self:currentPage()
end

--- Grab the page as painted on `bb` (full screen), shrink it into the card.
--- Render the current page into an offscreen buffer with only the book's content:
--- no KOReader status bar, no view modules (Bookends and the like), no corner icons,
--- and without the crengine top status bar.
function KindleToolbarWidget:renderCleanPage()
    local view = self.ui.view
    local W, H = Screen:getWidth(), Screen:getHeight()
    local bb = Blitbuffer.new(W, H, Screen.bb:getType())
    bb:fill(WHITE)
    local saved_footer = view.footer_visible
    local saved_modules = view.view_modules
    local flipping = view.flipping
    view.footer_visible = false
    view.view_modules = {}
    if flipping then flipping.paintTo = function() end end
    local ok, err = pcall(view.paintTo, view, bb, 0, 0)
    view.footer_visible = saved_footer
    view.view_modules = saved_modules
    if flipping then flipping.paintTo = nil end -- back to the class method
    if not ok then
        bb:free()
        error(err)
    end
    if self.ui.rolling and self.ui.document.getHeaderHeight then
        local hh = self.ui.document:getHeaderHeight() or 0
        if hh > 0 and hh < H then
            local cropped = Blitbuffer.new(W, H - hh, bb:getType())
            cropped:blitFrom(bb, 0, 0, 0, hh, W, H - hh)
            bb:free()
            bb = cropped
        end
    end
    return bb
end

--- Shrink the current page into the centre card.
function KindleToolbarWidget:takeSnapshot()
    if not self.zoom then return end
    local ok, err = pcall(function()
        local page = self:currentPage()
        local clean = self:renderCleanPage()
        local scaled = RenderImage:scaleBlitBuffer(clean, self.card_w - 2, self.card_h - 2, true)
        if self.images[page] then self.images[page]:free() end
        self.images[page] = scaled
        self.snapshot_page = page
    end)
    if not ok then
        require("logger").warn("kindletoolbar: snapshot failed:", err)
    end
end

--- Called (by the plugin) right after the reader painted itself, before we paint over it.
function KindleToolbarWidget:onReaderPainted(bb)
    if self.zoom and self.snapshot_page ~= self:currentPage() then
        self:takeSnapshot()
    end
end

--- Ask for thumbnails of the pages we're about to show, and drop the others.
function KindleToolbarWidget:ensureImages()
    if not self.zoom or self.closed then return end
    local wanted = {}
    for _, card in ipairs(self:cardLayout()) do
        wanted[card.page] = true
        -- (the current page's picture comes from the screen, see onReaderPainted)
        if not self.images[card.page] and card.page ~= self:currentPage() then
            self:requestThumbnail(card.page)
        end
    end
    -- keep the real current page picture too
    wanted[self:currentPage()] = true
    for page, img in pairs(self.images) do
        if not wanted[page] then
            img:free()
            self.images[page] = nil
        end
    end
end

function KindleToolbarWidget:requestThumbnail(page)
    local thumbnail = self.ui.thumbnail
    if not thumbnail or self.pending[page] then return end
    self.pending[page] = true
    local ok, err = pcall(thumbnail.getPageThumbnail, thumbnail, page, self.card_w - 2, self.card_h - 2, self.batch_id,
        function(tile, batch_id, async)
            self.pending[page] = nil
            if self.closed or batch_id ~= self.batch_id or not tile or not tile.bb then return end
            if self.images[page] then return end -- got a real snapshot meanwhile
            self.images[page] = tile.bb:copy()
            if async then
                UIManager:setDirty(self, function() return self.dragging and "fast" or "ui", self.mid_dimen end)
            end
        end)
    if not ok then
        self.pending[page] = nil
        require("logger").warn("kindletoolbar: thumbnail request failed:", err)
    end
end

function KindleToolbarWidget:freeImages()
    for page, img in pairs(self.images) do
        img:free()
        self.images[page] = nil
    end
    if self.ui.thumbnail then
        pcall(self.ui.thumbnail.cancelPageThumbnailRequests, self.ui.thumbnail, self.batch_id)
    end
end

-- ------------------------------------------------------------- assembling

function KindleToolbarWidget:assemble()
    local top_h = self.top_panel:getSize().h
    local bottom_h = self.bottom_panel:getSize().h
    self.top_dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = top_h }
    self.bottom_dimen = Geom:new{ x = 0, y = self.screen_h - bottom_h, w = self.screen_w, h = bottom_h }
    self.bottom_panel.overlap_offset = { 0, self.screen_h - bottom_h }
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = self.screen_w, h = self.screen_h },
        allow_mirroring = false,
    }
    if self.zoom then
        if not self.card_w then self:computeCardGeometry() end
        self.cards = self.cards or PageCards:new{ owner = self, width = self.screen_w, height = self.mid_dimen.h }
        self.cards.overlap_offset = { 0, self.mid_dimen.y }
        table.insert(group, self.cards)
    end
    self.pill_dimen = nil
    if self.pill then
        local ph = self.pill:getSize().h
        local py = self.bottom_dimen.y - ph - S(4)
        self.pill.overlap_offset = { 0, py }
        self.pill_dimen = Geom:new{ x = 0, y = py, w = self.screen_w, h = ph }
        table.insert(group, self.pill)
    end
    table.insert(group, self.top_panel)
    table.insert(group, self.bottom_panel)
    self[1] = group
end

--- Everything below the top panel (the page cards and the bottom panel).
function KindleToolbarWidget:lowerRegion()
    if self.zoom then
        return Geom:new{ x = 0, y = self.top_dimen.h, w = self.screen_w, h = self.screen_h - self.top_dimen.h }
    end
    return self.bottom_dimen
end

--- Rebuild the bottom panel (page changed, preview moved, origin changed…)
function KindleToolbarWidget:refresh(refresh_type)
    local old_pill = self.pill_dimen
    self:buildBottom()
    self:assemble()
    self:ensureImages()
    if self.zoom then
        UIManager:setDirty(self, refresh_type or "ui", self:lowerRegion())
    else
        -- The pill floats over the page: include its area, and let the reader
        -- repaint underneath in case it just went away.
        local region = self.bottom_dimen
        local pill = self.pill_dimen or old_pill
        if pill then region = region:combine(pill) end
        UIManager:setDirty(old_pill and self.ui or self, refresh_type or "ui", region)
    end
end

-- ---------------------------------------------------------------- showing

function KindleToolbarWidget:onShow()
    if self.zoom then
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    else
        UIManager:setDirty(self, function() return "ui", self.top_dimen end)
        UIManager:setDirty(self, function() return "ui", self.bottom_dimen end)
    end
    return true
end

function KindleToolbarWidget:onCloseWidget()
    self.closed = true
    self:freeImages()
    if self.zoom then
        local full = self.dimen
        UIManager:setDirty(nil, function() return "ui", full end)
    else
        local top, bottom = self.top_dimen, self.bottom_dimen
        UIManager:setDirty(nil, function() return "ui", top end)
        UIManager:setDirty(nil, function() return "ui", bottom end)
    end
    if self.plugin then self.plugin:onToolbarClosed(self) end
end

function KindleToolbarWidget:onClose()
    UIManager:close(self)
    return true
end

function KindleToolbarWidget:closeAnd(fn)
    UIManager:close(self)
    if fn then fn() end
end

function KindleToolbarWidget:openMainMenu()
    self:closeAnd(function()
        if self.ui.menu then self.ui.menu:onShowMenu() end
    end)
end

-- Friendlier names for a few actions in the ⋮ menu
local ACTION_LABELS = {
    go_to = _("Go to Page…"),
    book_info = _("Book Information"),
    book_statistics = _("Reading Statistics"),
    show_menu = _("KOReader Menu"),
}

function KindleToolbarWidget:makeDots(ipad, icon)
    self.dots = Tappable:new{
        callback = function() self:showMoreMenu() end,
        FrameContainer:new{
            bordersize = 0, padding = ipad, padding_right = 0,
            Dots:new{ size = icon },
        },
    }
    return self.dots
end

function KindleToolbarWidget:showMoreMenu()
    local Dispatcher = require("dispatcher")
    local dropdown
    local actions = self.plugin:getMoreActions()
    local cfg = actions.settings or {}
    local separators = cfg.quickmenu_separators or {}
    local custom_names = cfg.quickmenu_action_names or {}
    local items = {}
    local unknown = _("Unknown item")
    for k, v in Dispatcher.iter_func(actions) do
        if type(k) == "number" then
            k = v
            v = actions[k]
        end
        if k ~= "settings" and v ~= nil then
            local label = custom_names[k]
            if not label then
                if k == "toggle_bookmark" then
                    local marked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
                    label = marked and _("Remove Bookmark") or _("Add Bookmark")
                else
                    label = ACTION_LABELS[k] or Dispatcher:getNameFromItem(k, actions)
                end
            end
            if label ~= unknown then
                local key, value = k, v
                table.insert(items, {
                    text = label,
                    separator = separators[k] and true or nil,
                    callback = function()
                        UIManager:close(dropdown)
                        self:closeAnd(function()
                            Dispatcher:execute({ [key] = value })
                        end)
                    end,
                })
            end
        end
    end
    if #items == 0 then
        table.insert(items, {
            text = _("KOReader menu"),
            callback = function()
                UIManager:close(dropdown)
                self:openMainMenu()
            end,
        })
    end
    -- Hang it from the ⋮ button, right-aligned with it, like KindleOS
    local d = self.dots and self.dots.dimen
    local right = d and (d.x + d.w + S(6)) or (self.screen_w - S(10))
    local top = d and (d.y + d.h - S(4)) or S(90)
    dropdown = KindleDropdown:new{ items = items, right = right, top = top }
    UIManager:show(dropdown)
end

-- -------------------------------------------------------------- navigation

function KindleToolbarWidget:gotoChapter(dir)
    local cur = self:currentPage()
    local target
    if dir > 0 then
        target = self.ui.toc:getNextChapter(cur)
    else
        target = self.ui.toc:getPreviousChapter(cur)
    end
    if target and target ~= cur then
        self.preview_page = nil
        self.plugin:goToPage(target)
        self:refresh()
    end
end

function KindleToolbarWidget:turnPage(dir)
    self.preview_page = nil
    self.plugin:turnPage(dir)
    self:refresh()
end

function KindleToolbarWidget:previewAt(x)
    local pct = self.slider:percentageAt(x)
    if not pct then return end
    local page = self:pageForPct(pct)
    if page ~= self.preview_page then
        self.preview_page = page
        self:refresh("fast")
    end
end

function KindleToolbarWidget:commitAt(x)
    local pct = self.slider:percentageAt(x)
    self.dragging = false
    if not pct then return end
    local page = self:pageForPct(pct)
    self.preview_page = nil
    if page ~= self:currentPage() then
        self.plugin:goToPage(page)
    end
    self:refresh()
end

--- Called by the plugin whenever the reader's page changes while we're shown.
function KindleToolbarWidget:onReaderPageUpdate()
    if self.dragging then return end
    self.page_count = self.ui.document:getPageCount()
    self:refresh()
end

-- ---------------------------------------------------------------- gestures

local function inside(pos, dimen)
    return pos and dimen and pos:intersectWith(dimen)
end

function KindleToolbarWidget:inSlider(pos)
    local d = self.slider and self.slider.dimen
    if not d then return false end
    -- a bit more forgiving vertically than what's drawn
    local grow = S(10)
    return inside(pos, Geom:new{ x = d.x, y = d.y - grow, w = d.w, h = d.h + 2 * grow })
end

function KindleToolbarWidget:inPanels(pos)
    return inside(pos, self.top_dimen) or inside(pos, self.bottom_dimen)
end

--- Which card (if any) is under `pos`: -1 previous, 0 current, 1 next.
function KindleToolbarWidget:cardAt(pos)
    if not self.zoom or not self.card_w then return nil end
    for _, card in ipairs(self:cardLayout()) do
        if inside(pos, Geom:new{ x = card.x, y = card.y, w = card.w, h = card.h }) then
            return card.page - self:centerPage()
        end
    end
end

function KindleToolbarWidget:onHudGesture(_, ev)
    local g, pos = ev.ges, ev.pos
    if g == "touch" then
        if self:inSlider(pos) then
            self.dragging = true
            self:previewAt(pos.x)
        end
    elseif g == "pan" or g == "hold_pan" or g == "hold" then
        if not self.dragging and ev.start_pos and self:inSlider(ev.start_pos) then
            self.dragging = true
        end
        if self.dragging then self:previewAt(pos.x) end
    elseif g == "pan_release" or g == "hold_release" then
        if self.dragging then self:commitAt(pos.x) end
    elseif g == "swipe" then
        if self.dragging or self:inSlider(pos) then
            self:commitAt((ev.end_pos or pos).x)
        elseif not self:inPanels(pos) then
            if self.zoom then
                -- Swipe the cards: flip pages, toolbar stays up
                if ev.direction == "west" then
                    self:turnPage(1)
                elseif ev.direction == "east" then
                    self:turnPage(-1)
                end
            else
                -- Swipe on the page: close, and let the reader turn the page.
                local ui = self.ui
                UIManager:close(self)
                ui:handleEvent(Event:new("Gesture", ev))
            end
        end
    elseif g == "tap" or g == "double_tap" then
        if self.dragging or self:inSlider(pos) then
            self:commitAt(pos.x)
        elseif self.info_container and inside(pos, self.info_container.dimen) then
            self:cycleInfoMode()
        elseif not self:inPanels(pos) then
            local which = self:cardAt(pos)
            if which == -1 or which == 1 then
                self:turnPage(which)
            else
                UIManager:close(self)
            end
        end
    end
    return true -- never let anything leak to the page underneath
end

function KindleToolbarWidget:cycleInfoMode()
    local cur = self.plugin.settings.info_mode or "chapter_time"
    local idx = 1
    for i, m in ipairs(INFO_MODES) do
        if m == cur then idx = i break end
    end
    self.plugin.settings.info_mode = INFO_MODES[idx % #INFO_MODES + 1]
    self.plugin:saveSettings()
    self:refresh()
end

KindleToolbarWidget.INFO_MODES = INFO_MODES

return KindleToolbarWidget
