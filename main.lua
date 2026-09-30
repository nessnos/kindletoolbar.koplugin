--[[--
Kindle-style toolbar for KOReader.

Tap the middle of the page (while reading) to show a stock-Kindle-like
overlay: quick buttons at the top, chapter / page / time left and a
progress slider at the bottom. Skimming with the slider remembers the
page you started from and offers a "Back to page N" button.

Taps at the top and bottom of the page keep opening KOReader's own menus.

@module koplugin.KindleToolbar
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local ZONE_ID = "kindletoolbar_tap"
local TOP_TAP_ID = "kindletoolbar_top_tap"
local TOP_EXT_TAP_ID = "kindletoolbar_top_ext_tap"
local TOP_SWIPE_ID = "kindletoolbar_top_swipe"
local TOP_EXT_SWIPE_ID = "kindletoolbar_top_ext_swipe"
local TOP_PAN_ID = "kindletoolbar_top_pan"
local TOP_EXT_PAN_ID = "kindletoolbar_top_ext_pan"

-- Zones that must keep priority over ours (tapping a link or an existing highlight
-- should still do what it always did; so should corner taps you've set up in
-- Taps and gestures, e.g. the bookmark corner).
local ZONES_BEFORE_US = {
    "tap_link",
    "readerhighlight_tap",
    "readerhighlight_tap_select_mode",
}
local TOP_ZONES_BEFORE_US = {
    "tap_link",
    "readerhighlight_tap",
    "readerhighlight_tap_select_mode",
    "tap_top_left_corner",
    "tap_top_right_corner",
}
-- which "before us" list applies to each of our zones
local OUR_ZONES = {
    [ZONE_ID] = ZONES_BEFORE_US,
    [TOP_TAP_ID] = TOP_ZONES_BEFORE_US,
    [TOP_EXT_TAP_ID] = TOP_ZONES_BEFORE_US,
    [TOP_SWIPE_ID] = {},
    [TOP_EXT_SWIPE_ID] = {},
    [TOP_PAN_ID] = {},
    [TOP_EXT_PAN_ID] = {},
}

-- Tap area presets (screen ratios). They avoid the top/bottom 1/5 of the screen,
-- which belong to KOReader's menu / settings taps.
local ZONES = {
    small  = { x = 1/3, y = 1/3, w = 1/3, h = 1/3 },
    medium = { x = 1/4, y = 1/5, w = 1/2, h = 3/5 },
    large  = { x = 1/8, y = 1/5, w = 3/4, h = 3/5 },
}

local DEFAULTS = {
    enabled = true,
    zone = "medium",
    show_ticks = true,
    info_mode = "chapter_time",
    zoom_pages = true,
    hide_wifi_off = false,
    top_tap = true,     -- tapping the top of the page opens the toolbar (not KOReader's menu)
    top_swipe = true,   -- same for swiping down from the top
}

-- What the ⋮ menu offers out of the box (Dispatcher action ids, in order).
local DEFAULT_MORE_ACTIONS = { "go_to", "toggle_bookmark", "book_info", "book_statistics", "show_menu", "kindle_toolbar_settings" }

local function defaultMoreActions()
    -- show_as_quickmenu only makes "Arrange actions" offer group separators
    -- (we always run the picked action directly, never as a QuickMenu).
    local t = { settings = { order = {}, show_as_quickmenu = true, quickmenu_separators = { book_statistics = true } } }
    for _, id in ipairs(DEFAULT_MORE_ACTIONS) do
        t[id] = true
        table.insert(t.settings.order, id)
    end
    return t
end

-- Where the "‹ Library" button can take you. `available` decides whether the
-- choice can be used right now (other plugins may not be installed).
local LIBRARY_TARGETS = {
    { id = "filebrowser", label = _("Library"), menu = _("File browser (KOReader)"),
      available = function() return true end },
    { id = "simpleui_library", label = _("Library"), menu = _("Library (SimpleUI)"),
      available = function(ui) return ui.simpleui ~= nil end },
    { id = "simpleui_home", label = _("Home"), menu = _("Home screen (SimpleUI)"),
      available = function(ui) return ui.simpleui ~= nil end },
    { id = "simpleui_authors", label = _("Authors"), menu = _("Authors (SimpleUI)"),
      available = function(ui) return ui.simpleui ~= nil end },
    { id = "simpleui_series", label = _("Series"), menu = _("Series (SimpleUI)"),
      available = function(ui) return ui.simpleui ~= nil end },
    { id = "bookshelf", label = _("Bookshelf"), menu = _("Bookshelf"),
      available = function(ui) return ui.bookshelf ~= nil end },
}

local KindleToolbar = WidgetContainer:extend{
    name = "kindletoolbar",
    is_doc_only = true,
}

function KindleToolbar:init()
    self.settings = G_reader_settings:readSetting("kindle_toolbar") or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if self.settings.more_actions == nil then
        self.settings.more_actions = defaultMoreActions()
    end

    if Device:isTouchDevice() then
        self:hookZoneRegistration()
        self:registerZone()
    end
    self:hookReaderPaint()
    self:hookThumbnails()
end

-- Side-page thumbnails come from KOReader's page thumbnailer, which draws the page
-- the same way the reader does, overlays included. It runs in a throwaway
-- subprocess, so we can simply switch the view modules (Bookends…) off in there.
function KindleToolbar:hookThumbnails()
    local th = self.ui.thumbnail
    if not th or th._kindletoolbar_hooked or type(th._getPageImage) ~= "function" then return end
    th._kindletoolbar_hooked = true
    local plugin = self
    local orig = th._getPageImage
    th._getPageImage = function(this, page)
        if plugin.settings.zoom_pages ~= false then
            pcall(function() this.ui.view.view_modules = {} end)
        end
        return orig(this, page)
    end
end

-- ------------------------------------------------------------ Library button

function KindleToolbar:getLibraryTarget()
    local wanted = self.settings.library_target or "filebrowser"
    for _, t in ipairs(LIBRARY_TARGETS) do
        if t.id == wanted and t.available(self.ui) then return t end
    end
    return LIBRARY_TARGETS[1] -- plain KOReader file browser always works
end

local function liveFileManager()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

function KindleToolbar:goToLibraryTarget(id)
    local ui = self.ui
    local ok, err = pcall(function()
        if id == "simpleui_library" and ui.simpleui and ui.simpleui.onSimpleUIGoLibrary then
            ui.simpleui:onSimpleUIGoLibrary()
        elseif id == "simpleui_home" and ui.simpleui and ui.simpleui.onSimpleUIGoHomescreen then
            ui.simpleui:onSimpleUIGoHomescreen()
        elseif (id == "simpleui_authors" or id == "simpleui_series") and ui.simpleui and ui.simpleui.onSimpleUIGoLibrary then
            local action = id == "simpleui_authors" and "browse_authors" or "browse_series"
            ui.simpleui:onSimpleUIGoLibrary()
            -- Once the library is up, ask SimpleUI to switch to its Authors/Series view
            -- (same as tapping that tab on its bottom bar).
            local tries = 0
            local function go()
                tries = tries + 1
                local fm = liveFileManager()
                local sui = fm and (fm._simpleui_plugin or fm.simpleui)
                if fm and fm.file_chooser and sui and sui._navigate then
                    local ok2, err2 = pcall(sui._navigate, sui, action, fm, nil, false)
                    if not ok2 then logger.warn("kindletoolbar: SimpleUI navigate failed:", err2) end
                elseif tries < 20 then
                    UIManager:scheduleIn(0.1, go)
                end
            end
            UIManager:scheduleIn(0.15, go)
        elseif id == "bookshelf" and ui.bookshelf then
            ui:handleEvent(Event:new("SetBookshelf", true))
        else
            ui:handleEvent(Event:new("Home"))
        end
    end)
    if not ok then
        logger.warn("kindletoolbar: library button failed, using the file browser:", err)
        ui:handleEvent(Event:new("Home"))
    end
end

-- When the toolbar is up, the reader still repaints itself underneath it (e.g. after
-- a jump). That's the moment its page is on the screen buffer without our overlay:
-- let the toolbar grab it for the zoomed-out page card.
function KindleToolbar:hookReaderPaint()
    local ui = self.ui
    if ui._kindletoolbar_paint_hooked then return end
    ui._kindletoolbar_paint_hooked = true
    local plugin = self
    local orig_paint = ui.paintTo
    ui.paintTo = function(this, bb, x, y)
        orig_paint(this, bb, x, y)
        local hud = plugin.hud
        if hud and this == plugin.ui then
            local ok, err = pcall(hud.onReaderPainted, hud, bb)
            if not ok then logger.warn("kindletoolbar: onReaderPainted failed:", err) end
        end
    end
end

function KindleToolbar:getMoreActions()
    if type(self.settings.more_actions) ~= "table" then
        self.settings.more_actions = defaultMoreActions()
    end
    -- lets "Arrange actions" offer separators (v2 settings didn't have it)
    local cfg = self.settings.more_actions.settings
    if type(cfg) ~= "table" then
        cfg = {}
        self.settings.more_actions.settings = cfg
    end
    if cfg.show_as_quickmenu == nil and cfg.quickmenu_separators == nil
            and self.settings.more_actions.book_statistics and self.settings.more_actions.show_menu then
        -- first run after updating from v2: give the default list its KindleOS-like grouping
        cfg.quickmenu_separators = { book_statistics = true }
    end
    cfg.show_as_quickmenu = true
    if not self.settings.added_settings_entry then
        -- v3.2: offer the plugin's own settings in the ⋮ menu (once; removable)
        self.settings.added_settings_entry = true
        local actions = self.settings.more_actions
        if not actions.kindle_toolbar_settings then
            actions.kindle_toolbar_settings = true
            if type(cfg.order) == "table" then table.insert(cfg.order, "kindle_toolbar_settings") end
        end
        self:saveSettings()
    end
    if self.updated then -- changed through the Dispatcher menu
        self.updated = nil
        self:saveSettings()
    end
    return self.settings.more_actions
end

function KindleToolbar:onFlushSettings()
    if self.updated then
        self:saveSettings()
        self.updated = nil
    end
end

function KindleToolbar:saveSettings()
    G_reader_settings:saveSetting("kindle_toolbar", self.settings)
end

function KindleToolbar:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindle_toolbar_settings", {
        category = "none",
        event = "ShowKindleToolbarSettings",
        title = _("Kindle-style toolbar: settings"),
        reader = true,
    })
    Dispatcher:registerAction("kindle_toolbar_show", {
        category = "none",
        event = "ShowKindleToolbar",
        title = _("Kindle-style toolbar"),
        reader = true,
    })
end

-- ------------------------------------------------------------ touch zone

function KindleToolbar:registerZone()
    local z = ZONES[self.settings.zone] or ZONES.medium
    self.ui:registerTouchZones({
        {
            id = ZONE_ID,
            ges = "tap",
            screen_zone = { ratio_x = z.x, ratio_y = z.y, ratio_w = z.w, ratio_h = z.h },
            overrides = {
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges)
                if not self.settings.enabled then return false end
                self:showToolbar()
                return true
            end,
        },
    })
    self:registerTopZones()
end

-- The top of the page: the same areas KOReader uses to open its menu
-- (a strip along the top, and a taller one in the middle). When the option is on,
-- we answer first and open the toolbar; when it's off we step aside.
function KindleToolbar:registerTopZones()
    local menu_zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local menu_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local function sz(z) return { ratio_x = z.x, ratio_y = z.y, ratio_w = z.w, ratio_h = z.h } end
    local function onTap()
        if not self.settings.top_tap then return false end
        self:showToolbar()
        return true
    end
    local function onSwipe(ges)
        if not self.settings.top_swipe or ges.direction ~= "south" then return false end
        self:showToolbar()
        self.ui:handleEvent(Event:new("HandledAsSwipe")) -- cancel any pan scroll made
        return true
    end
    self.ui:registerTouchZones({
        { id = TOP_TAP_ID, ges = "tap", screen_zone = sz(menu_zone),
          overrides = { "readermenu_tap", "tap_forward", "tap_backward" }, handler = onTap },
        { id = TOP_EXT_TAP_ID, ges = "tap", screen_zone = sz(menu_ext),
          overrides = { "readermenu_ext_tap", "readermenu_tap", TOP_TAP_ID, "tap_forward", "tap_backward" }, handler = onTap },
        { id = TOP_SWIPE_ID, ges = "swipe", screen_zone = sz(menu_zone),
          overrides = { "readermenu_swipe", "rolling_swipe", "paging_swipe" }, handler = onSwipe },
        { id = TOP_EXT_SWIPE_ID, ges = "swipe", screen_zone = sz(menu_ext),
          overrides = { "readermenu_ext_swipe", "readermenu_swipe", TOP_SWIPE_ID, "rolling_swipe", "paging_swipe" }, handler = onSwipe },
        { id = TOP_PAN_ID, ges = "pan", screen_zone = sz(menu_zone),
          overrides = { "readermenu_pan", "rolling_pan", "paging_pan" }, handler = onSwipe },
        { id = TOP_EXT_PAN_ID, ges = "pan", screen_zone = sz(menu_ext),
          overrides = { "readermenu_ext_pan", "readermenu_pan", TOP_PAN_ID, "rolling_pan", "paging_pan" }, handler = onSwipe },
    })
end

-- Make sure link / highlight taps are checked before ours. Other modules re-register
-- their zones at times (which drops dependencies pointing at them), so we re-assert
-- the ordering after every (un)registration on this ReaderUI.
function KindleToolbar:fixZoneOrder()
    local ui = self.ui
    local dg = ui.touch_zone_dg
    if not dg then return end
    local changed = false
    for our_id, before in pairs(OUR_ZONES) do
        if dg:checkNode(our_id) then
            for _, id in ipairs(before) do
                if dg:checkNode(id) then
                    dg:addNodeDep(our_id, id)
                    changed = true
                end
            end
        end
    end
    if changed then
        local ordered = {}
        for _, zone_id in ipairs(dg:serialize()) do
            if ui._zones[zone_id] then
                table.insert(ordered, ui._zones[zone_id])
            end
        end
        ui._ordered_touch_zones = ordered
    end
end

function KindleToolbar:hookZoneRegistration()
    local ui = self.ui
    if ui._kindletoolbar_hooked then return end
    ui._kindletoolbar_hooked = true
    local plugin = self
    local orig_register = ui.registerTouchZones
    local orig_unregister = ui.unRegisterTouchZones
    ui.registerTouchZones = function(this, zones)
        orig_register(this, zones)
        local ok, err = pcall(plugin.fixZoneOrder, plugin)
        if not ok then logger.warn("kindletoolbar: fixZoneOrder failed:", err) end
    end
    ui.unRegisterTouchZones = function(this, zones)
        orig_unregister(this, zones)
        local ok, err = pcall(plugin.fixZoneOrder, plugin)
        if not ok then logger.warn("kindletoolbar: fixZoneOrder failed:", err) end
    end
end

function KindleToolbar:onSetDimensions()
    -- Screen rotated / resized: rebuild the zone with the new size, drop the overlay.
    self:closeToolbar()
    if Device:isTouchDevice() then
        UIManager:nextTick(function() self:registerZone() end)
    end
end

-- ------------------------------------------------------------ the overlay

function KindleToolbar:showToolbar()
    if self.hud then return end
    local ToolbarWidget = require("kindletoolbar_widget")
    self.hud = ToolbarWidget:new{
        ui = self.ui,
        plugin = self,
    }
    UIManager:show(self.hud)
end

function KindleToolbar:closeToolbar()
    if self.hud then
        UIManager:close(self.hud)
        self.hud = nil
    end
end

function KindleToolbar:onToolbarClosed(widget)
    if self.hud == widget then self.hud = nil end
    -- Forget the origin if we're back on it anyway.
    if self.origin and self:getOriginPage() == self.ui:getCurrentPage() then
        self:clearOrigin()
    end
end

function KindleToolbar:onShowKindleToolbar()
    if self.hud then
        self:closeToolbar()
    else
        self:showToolbar()
    end
    return true
end

-- ------------------------------------------------------------ origin ("where was I")

function KindleToolbar:setOriginIfNeeded()
    if self.origin then return end
    local ui = self.ui
    local location = ui.link:getCurrentLocation()
    local label
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        label = ui.pagemap:getCurrentPageLabel(true)
    end
    self.origin = {
        location = location,
        page = ui:getCurrentPage(),
        label = label,
    }
    -- Also put it in KOReader's own location history, so "Go back" works too.
    ui.link:addCurrentLocationToStack(location)
end

function KindleToolbar:clearOrigin()
    self.origin = nil
end

function KindleToolbar:getOriginPage()
    local o = self.origin
    if not o then return nil end
    if self.ui.rolling and o.location and o.location.xpointer then
        -- Stays correct if the book got re-laid out (font size change…)
        local ok, page = pcall(self.ui.document.getPageFromXPointer, self.ui.document, o.location.xpointer)
        if ok and page then return page end
    end
    return o.page
end

function KindleToolbar:goToPage(page)
    self:setOriginIfNeeded()
    self._navigating = true
    self.ui:handleEvent(Event:new("GotoPage", page))
    self._navigating = false
end

function KindleToolbar:turnPage(dir)
    self:setOriginIfNeeded()
    self._navigating = true
    self.ui:handleEvent(Event:new("GotoViewRel", dir))
    self._navigating = false
end

function KindleToolbar:goToOrigin()
    local o = self.origin
    if not o then return end
    self._navigating = true
    self.ui:handleEvent(Event:new("RestoreBookLocation", o.location))
    self._navigating = false
    -- Drop the history entry we added, if it's still the latest one.
    local stack = self.ui.link.location_stack
    if stack and stack[#stack] == o.location then
        table.remove(stack)
    end
    self:clearOrigin()
end

function KindleToolbar:onPageUpdate()
    if self.hud then
        self.hud:onReaderPageUpdate()
    elseif self.origin and not self._navigating then
        -- You turned a page yourself: you've settled on the new spot.
        self:clearOrigin()
    end
end

function KindleToolbar:onCloseDocument()
    self:closeToolbar()
    self:clearOrigin()
end

function KindleToolbar:onCloseWidget()
    self:closeToolbar()
end

-- ------------------------------------------------------------ menu

function KindleToolbar:addToMainMenu(menu_items)
    local zone_names = {
        small = _("Small"),
        medium = _("Medium"),
        large = _("Large"),
    }
    local mode_names = {
        chapter_time = _("Time left in chapter"),
        book_time = _("Time left in book"),
        chapter_pages = _("Pages left in chapter"),
        book_pages = _("Pages left in book"),
    }
    local zone_items = {}
    for _, key in ipairs{ "small", "medium", "large" } do
        table.insert(zone_items, {
            text = zone_names[key],
            radio = true,
            checked_func = function() return self.settings.zone == key end,
            callback = function()
                self.settings.zone = key
                self:saveSettings()
                self:registerZone()
            end,
        })
    end
    local mode_items = {}
    for _, key in ipairs{ "chapter_time", "book_time", "chapter_pages", "book_pages" } do
        table.insert(mode_items, {
            text = mode_names[key],
            radio = true,
            checked_func = function() return self.settings.info_mode == key end,
            callback = function()
                self.settings.info_mode = key
                self:saveSettings()
            end,
        })
    end

    menu_items.kindle_toolbar = {
        text = _("Kindle-style toolbar"),
        -- top level of the Settings (gear) tab, where it's easy to find
        sorting_hint = "setting",
        sub_item_table = self:buildSettingsItems(zone_names, zone_items, mode_names, mode_items),
    }
end

function KindleToolbar:buildSettingsItems(zone_names, zone_items, mode_names, mode_items)
    return {
            {
                text = _("Show toolbar when tapping the middle of the page"),
                checked_func = function() return self.settings.enabled end,
                callback = function()
                    self.settings.enabled = not self.settings.enabled
                    self:saveSettings()
                end,
            },
            {
                text_func = function()
                    return _("Middle tap area") .. ": " .. (zone_names[self.settings.zone] or "")
                end,
                sub_item_table = zone_items,
            },
            {
                text = _("Tapping the top of the page opens the toolbar"),
                help_text = _("Instead of KOReader's menu. Corner taps you've set up in Taps and gestures keep working. The toolbar's top row (clock, chevron) still opens KOReader's menu."),
                checked_func = function() return self.settings.top_tap end,
                callback = function()
                    self.settings.top_tap = not self.settings.top_tap
                    self:saveSettings()
                end,
            },
            {
                text = _("Swiping down from the top opens the toolbar"),
                help_text = _("Instead of KOReader's menu."),
                checked_func = function() return self.settings.top_swipe end,
                callback = function()
                    self.settings.top_swipe = not self.settings.top_swipe
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return _("Bottom line shows") .. ": " .. (mode_names[self.settings.info_mode] or "")
                end,
                help_text = _("You can also tap that line on the toolbar to switch."),
                sub_item_table = mode_items,
            },
            {
                text_func = function()
                    return _("‹ Library button opens") .. ": " .. self:getLibraryTarget().menu
                end,
                sub_item_table_func = function()
                    local sub = {}
                    for _, t in ipairs(LIBRARY_TARGETS) do
                        local target = t
                        table.insert(sub, {
                            text = target.menu,
                            radio = true,
                            enabled_func = function() return target.available(self.ui) end,
                            checked_func = function() return self:getLibraryTarget().id == target.id end,
                            callback = function()
                                self.settings.library_target = target.id
                                self:saveSettings()
                            end,
                        })
                    end
                    return sub
                end,
                help_text = _("Choices from SimpleUI or Bookshelf are only available when those plugins are installed and enabled. If a choice isn't available, the button opens KOReader's file browser. Authors and Series need SimpleUI's 'Browse by Author / Series / Tags' to be on."),
            },
            {
                text = _("Show the page zoomed out, with the pages around it"),
                help_text = _("Like KindleOS: the page shrinks into a card between the bars, with the previous and next pages on the sides. Tap or swipe them to flip pages."),
                checked_func = function() return self.settings.zoom_pages end,
                callback = function()
                    self.settings.zoom_pages = not self.settings.zoom_pages
                    self:saveSettings()
                end,
            },
            {
                text_func = function()
                    local Dispatcher = require("dispatcher")
                    return _("⋮ menu") .. ": " .. Dispatcher:menuTextFunc(self:getMoreActions())
                end,
                help_text = _("Pick any KOReader action to show in the ⋮ menu. Use 'Arrange actions' to change their order."),
                sub_item_table_func = function()
                    local Dispatcher = require("dispatcher")
                    self:getMoreActions()
                    local sub = {}
                    Dispatcher:addSubMenu(self, sub, self.settings, "more_actions")
                    -- Keep "Nothing", the action categories and "Arrange actions";
                    -- drop Execute / QuickMenu entries, which don't apply here.
                    local cut
                    for i, item in ipairs(sub) do
                        if item.text_func and i > 1 then cut = i break end
                    end
                    if cut then
                        for i = #sub, cut + 1, -1 do table.remove(sub, i) end
                        sub[cut].separator = nil
                    end
                    table.insert(sub, 1, {
                        text = _("Reset to default"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self.settings.more_actions = defaultMoreActions()
                            self:saveSettings()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        separator = true,
                    })
                    return sub
                end,
            },
            {
                text = _("Hide the Wi-Fi icon when Wi-Fi is off"),
                checked_func = function() return self.settings.hide_wifi_off end,
                callback = function()
                    self.settings.hide_wifi_off = not self.settings.hide_wifi_off
                    self:saveSettings()
                end,
            },
            {
                text = _("Show chapter marks on the progress bar"),
                checked_func = function() return self.settings.show_ticks end,
                callback = function()
                    self.settings.show_ticks = not self.settings.show_ticks
                    self:saveSettings()
                end,
            },
    }
end

--- Open just this plugin's settings, as a one-tab KOReader menu.
function KindleToolbar:onShowKindleToolbarSettings()
    local items = {}
    self:addToMainMenu(items)
    local tab = items.kindle_toolbar.sub_item_table
    tab.icon = "appbar.settings"
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local Screen = Device.screen
    local container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        tab_item_table = { tab },
        show_parent = container,
    }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
    return true
end

return KindleToolbar
