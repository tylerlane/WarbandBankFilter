local WarbandBankFilter = CreateFrame("Frame")
local filterEnabled = true
local initialized = false
local watcher = nil        -- Store reference to the watcher frame
local itemFilterCache = {} -- Cache filter results to avoid repeated calculations
local lastSearchText = ""  -- Track search changes
local debugMode = false    -- Debug mode setting

local classArmor = {
    MAGE = "Cloth",
    PRIEST = "Cloth",
    WARLOCK = "Cloth",
    ROGUE = "Leather",
    DRUID = "Leather",
    MONK = "Leather",
    DEMONHUNTER = "Leather",
    HUNTER = "Mail",
    SHAMAN = "Mail",
    EVOKER = "Mail",
    WARRIOR = "Plate",
    PALADIN = "Plate",
    DEATHKNIGHT = "Plate"
}

local classWeapons = {
    MAGE = { "Daggers", "One-Handed Swords", "Staves", "Wands" },
    PRIEST = { "Daggers", "One-Handed Maces", "Staves", "Wands" },
    WARLOCK = { "Daggers", "One-Handed Swords", "Staves", "Wands" },
    ROGUE = { "Daggers", "One-Handed Swords", "Fist Weapons", "One-Handed Maces", "Bows", "Crossbows", "Guns" },
    DRUID = { "Daggers", "Fist Weapons", "One-Handed Maces", "Polearms", "Staves", "Two-Handed Maces" },
    MONK = { "Fist Weapons", "One-Handed Maces", "One-Handed Swords", "Polearms", "Staves" },
    DEMONHUNTER = { "Fist Weapons", "One-Handed Swords", "Warglaives" },
    HUNTER = { "Daggers", "Fist Weapons", "One-Handed Swords", "One-Handed Axes", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Staves", "Bows", "Crossbows", "Guns" },
    SHAMAN = { "Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Axes", "Staves", "Shields" },
    EVOKER = { "Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Staves" },
    WARRIOR = { "Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Staves", "Bows", "Crossbows", "Guns", "Shields" },
    PALADIN = { "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Shields" },
    DEATHKNIGHT = { "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms" }
}

local classPrimaryStats = {
    MAGE = { "Intellect" },
    PRIEST = { "Intellect" },
    WARLOCK = { "Intellect" },
    ROGUE = { "Agility" },
    DRUID = { "Intellect", "Agility" }, -- Hybrid class
    MONK = { "Agility", "Intellect" },  -- Hybrid class
    DEMONHUNTER = { "Agility" },
    HUNTER = { "Agility" },
    SHAMAN = { "Intellect", "Agility" }, -- Hybrid class
    EVOKER = { "Intellect" },
    WARRIOR = { "Strength" },
    PALADIN = { "Strength", "Intellect" }, -- Hybrid class
    DEATHKNIGHT = { "Strength" }
}

local _, class = UnitClass("player")
local myArmorType = classArmor[class]
local myWeapons = classWeapons[class] or {}
local myPrimaryStats = classPrimaryStats[class] or {}

-- Clear cache when needed (e.g., when items change or addon reloads)
local function ClearFilterCache()
    itemFilterCache = {}
end

local function HasPrimaryStat(itemID)
    local stats = C_Item.GetItemStats(itemID)
    if not stats then return false end

    -- For trinkets, be more permissive - if it has any main stat, show it
    -- This handles items like Funhouse Lens that have multiple stats
    local hasMainStat = false
    for statKey, statValue in pairs(stats) do
        local upperKey = statKey:upper()
        -- Look for any of the three main stats with more precise matching
        if upperKey == "ITEM_MOD_STRENGTH_SHORT" or upperKey == "STRENGTH" or string.find(upperKey, "^ITEM_MOD_STRENGTH_") or
            upperKey == "ITEM_MOD_AGILITY_SHORT" or upperKey == "AGILITY" or string.find(upperKey, "^ITEM_MOD_AGILITY_") or
            upperKey == "ITEM_MOD_INTELLECT_SHORT" or upperKey == "INTELLECT" or string.find(upperKey, "^ITEM_MOD_INTELLECT_") then
            hasMainStat = true
            break
        end
    end

    return hasMainStat
end

local function HasClassRestriction(itemID)
    if not itemID then return false, false end

    local itemName = GetItemInfo(itemID)
    if not itemName then return false, false end

    -- Use a simple shared tooltip to avoid creating too many tooltip frames
    local tooltip = _G["WarbandBankFilterSharedTooltip"]
    if not tooltip then
        tooltip = CreateFrame("GameTooltip", "WarbandBankFilterSharedTooltip", UIParent, "GameTooltipTemplate")
    end

    tooltip:SetOwner(UIParent, "ANCHOR_NONE")

    -- Safety check
    if not tooltip.SetItemByID then
        tooltip:Hide()
        return false, false
    end

    -- Clear any previous content
    tooltip:ClearLines()

    local success, error = pcall(function()
        tooltip:SetItemByID(itemID)
    end)

    if not success then
        tooltip:Hide()
        if debugMode then
            print("WarbandBankFilter Debug: Error setting tooltip for item " .. itemID .. ": " .. tostring(error))
        end
        return false, false
    end

    local classFound = false
    local hasClassesLine = false

    -- Debug mode for testing
    if debugMode then
        print("WarbandBankFilter Debug: Checking item " .. (itemName or "unknown") .. " (ID: " .. itemID .. ")")
        print("  Player class: " .. class)
    end

    -- Safety check for tooltip lines
    if tooltip.NumLines and tooltip:NumLines() then
        for i = 1, tooltip:NumLines() do
            local lineName = "WarbandBankFilterSharedTooltipTextLeft" .. i
            local line = _G[lineName]
            if line then
                local text = line:GetText()
                if text then
                    local lowerText = text:lower()

                    if debugMode then
                        print("  Line " .. i .. ": " .. text)
                    end

                    -- Look for "Classes:" line specifically
                    if lowerText:find("classes:") then
                        hasClassesLine = true
                        local lowerClass = class:lower()

                        if debugMode then
                            print("  Found Classes line: " .. text)
                            print("  Looking for class: " .. lowerClass)
                        end

                        -- Handle class name variations and be more flexible with matching
                        local classVariations = {
                            deathknight = { "death knight", "deathknight", "dk" },
                            demonhunter = { "demon hunter", "demonhunter", "dh" }
                        }

                        -- Check for class name in the text
                        if classVariations[lowerClass] then
                            for _, variation in ipairs(classVariations[lowerClass]) do
                                if lowerText:find(variation) then
                                    classFound = true
                                    if debugMode then
                                        print("  Found class match with variation: " .. variation)
                                    end
                                    break
                                end
                            end
                        else
                            -- For regular classes, look for the class name as a whole word
                            local pattern = "%f[%a]" .. lowerClass .. "%f[%A]"
                            if lowerText:find(pattern) then
                                classFound = true
                                if debugMode then
                                    print("  Found direct class match: " .. lowerClass)
                                end
                            end
                        end

                        break -- We found the Classes line, no need to check further
                    end
                end
            end
        end
    end

    -- IMPORTANT: Properly cleanup the tooltip to prevent memory leaks and UI issues
    tooltip:Hide()
    tooltip:ClearLines()
    -- Don't call SetOwner(nil) as it causes errors - just hide and clear

    if debugMode then
        print("  Has Classes line: " .. tostring(hasClassesLine))
        print("  Class found: " .. tostring(classFound))
        print("  Should show item: " .. tostring(not hasClassesLine or classFound))
    end

    return hasClassesLine, classFound
end

local function IsMatchingArmor(itemID)
    if not itemID then return false end

    -- Check cache first
    if itemFilterCache[itemID] ~= nil then
        return itemFilterCache[itemID]
    end

    local result = false -- Default to false

    -- Get item info - if it's not loaded yet, show the item (don't hide it)
    local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)

    -- If item info isn't loaded yet, don't cache and show the item by default
    if not itemType or not itemSubType then
        return true
    end

    -- Always show crafting reagents (Trade Goods)
    if itemType == "Trade Goods" then
        result = true
        itemFilterCache[itemID] = result
        return result
    end

    -- Check for class restrictions on equipment items
    local hasClassesLine, classFound = HasClassRestriction(itemID)
    if hasClassesLine then
        -- If item has "Classes:" line, only show if our class is listed
        result = classFound
        itemFilterCache[itemID] = result
        return result
    end

    -- Special handling for trinkets and miscellaneous items - show if they have our primary stat OR no primary stats at all
    if itemSubType == "Trinket" or itemSubType == "Miscellaneous" then
        local stats = C_Item.GetItemStats(itemID)
        if not stats then
            result = true -- No stats available, show it
        else
            -- Check if trinket has any primary stats
            local hasAnyPrimaryStat = false
            local hasMyPrimaryStat = false

            for statKey, statValue in pairs(stats) do
                local upperKey = statKey:upper()

                -- Check if it has any primary stat
                if upperKey == "ITEM_MOD_STRENGTH_SHORT" or upperKey == "STRENGTH" or string.find(upperKey, "^ITEM_MOD_STRENGTH_") or
                    upperKey == "ITEM_MOD_AGILITY_SHORT" or upperKey == "AGILITY" or string.find(upperKey, "^ITEM_MOD_AGILITY_") or
                    upperKey == "ITEM_MOD_INTELLECT_SHORT" or upperKey == "INTELLECT" or string.find(upperKey, "^ITEM_MOD_INTELLECT_") then
                    hasAnyPrimaryStat = true

                    -- Check if it has our specific primary stat(s)
                    for _, primaryStat in ipairs(myPrimaryStats) do
                        local primaryStatUpper = primaryStat:upper()
                        if upperKey == "ITEM_MOD_" .. primaryStatUpper .. "_SHORT" or
                            upperKey == primaryStatUpper or
                            string.find(upperKey, "^ITEM_MOD_" .. primaryStatUpper .. "_") then
                            hasMyPrimaryStat = true
                            break
                        end
                    end

                    if hasMyPrimaryStat then
                        break
                    end
                end
            end

            -- Show trinket/miscellaneous if it has our primary stat OR if it has no primary stats at all (only secondary stats)
            result = hasMyPrimaryStat or not hasAnyPrimaryStat
        end

        itemFilterCache[itemID] = result
        return result
    end

    -- Apply normal armor/weapon filtering
    if itemType == "Armor" then
        -- Handle shields separately - they're armor type but need weapon-like checking
        if itemSubType == "Shields" then
            for _, weaponType in ipairs(myWeapons) do
                if weaponType == "Shields" then
                    result = true
                    break
                end
            end
        else
            result = itemSubType == myArmorType
        end
    elseif itemType == "Weapon" then
        -- Check if weapon type is in our class's allowed weapons
        local isAllowedWeapon = false
        for _, weaponType in ipairs(myWeapons) do
            if itemSubType == weaponType then
                isAllowedWeapon = true
                break
            end
        end

        if not isAllowedWeapon then
            result = false
        else
            -- For allowed weapons, check primary stats
            local stats = C_Item.GetItemStats(itemID)
            if not stats then
                -- If no stats available, show the weapon (it might be a leveling weapon or special item)
                result = true
            else
                -- Check if weapon has our primary stat(s)
                local hasMyPrimaryStat = false
                local hasAnyPrimaryStat = false

                for statKey, statValue in pairs(stats) do
                    local upperKey = statKey:upper()

                    -- Check if it has any primary stat
                    if upperKey == "ITEM_MOD_STRENGTH_SHORT" or upperKey == "STRENGTH" or string.find(upperKey, "^ITEM_MOD_STRENGTH_") or
                        upperKey == "ITEM_MOD_AGILITY_SHORT" or upperKey == "AGILITY" or string.find(upperKey, "^ITEM_MOD_AGILITY_") or
                        upperKey == "ITEM_MOD_INTELLECT_SHORT" or upperKey == "INTELLECT" or string.find(upperKey, "^ITEM_MOD_INTELLECT_") then
                        hasAnyPrimaryStat = true

                        -- Check if it has our specific primary stat(s)
                        for _, primaryStat in ipairs(myPrimaryStats) do
                            local primaryStatUpper = primaryStat:upper()
                            if upperKey == "ITEM_MOD_" .. primaryStatUpper .. "_SHORT" or
                                upperKey == primaryStatUpper or
                                string.find(upperKey, "^ITEM_MOD_" .. primaryStatUpper .. "_") then
                                hasMyPrimaryStat = true
                                break
                            end
                        end

                        if hasMyPrimaryStat then
                            break
                        end
                    end
                end

                -- Show weapon if it has our primary stat OR if it has no primary stats at all (like some special weapons)
                result = hasMyPrimaryStat or not hasAnyPrimaryStat
            end
        end
    else
        -- All other items (jewelry, consumables, etc.) are always shown
        result = true
    end

    -- Cache the result
    itemFilterCache[itemID] = result
    return result
end

local function FilterItems(frame)
    if not frame then return end

    -- Only handle warband bank
    local itemButtons = {}

    if frame:GetName() == "AccountBankPanel" then
        -- Special handling for warband bank - buttons are direct children
        for i = 1, frame:GetNumChildren() do
            local child = select(i, frame:GetChildren())
            if child and child:GetObjectType() and string.find(child:GetObjectType(), "Button") then
                table.insert(itemButtons, child)
            end
        end
    else
        -- Not a warband bank, do nothing
        return
    end

    -- Check if search text has changed
    local searchBox = frame.SearchBox
    local currentSearchText = ""
    if searchBox and searchBox:GetText() then
        currentSearchText = searchBox:GetText()
    end

    local searchChanged = currentSearchText ~= lastSearchText
    lastSearchText = currentSearchText

    -- If search changed, clear cache to force re-evaluation
    if searchChanged then
        ClearFilterCache()
    end

    -- Apply filter to all found item buttons
    for _, button in pairs(itemButtons) do
        if button then
            local itemID = nil

            -- Try different methods to get the item ID
            if button.GetItemLocation then
                local itemLocation = button:GetItemLocation()
                if itemLocation then
                    -- Check if it's already a proper ItemLocation object
                    if type(itemLocation) == "table" and itemLocation.bagID and itemLocation.slotIndex then
                        -- It's a table with bagID/slotIndex, create proper ItemLocation
                        local properLocation = ItemLocation:CreateFromBagAndSlot(itemLocation.bagID,
                            itemLocation.slotIndex)
                        if properLocation and properLocation:IsValid() then
                            itemID = C_Item.GetItemID(properLocation)
                        end
                    else
                        -- It's already a proper ItemLocation object
                        itemID = C_Item.GetItemID(itemLocation)
                    end
                end
            elseif button.GetBagID and button.GetID then
                -- For warband bank buttons, create ItemLocation manually
                local bagID = button:GetBagID()
                local slotIndex = button:GetID()
                if bagID and slotIndex then
                    local itemLocation = ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)
                    if itemLocation and itemLocation:IsValid() then
                        itemID = C_Item.GetItemID(itemLocation)
                    end
                end
            end

            if itemID then
                -- Force load item info if not already cached
                local itemName = GetItemInfo(itemID)
                if not itemName then
                    -- Try to force load the item data
                    C_Item.RequestLoadItemDataByID(itemID)
                    -- If item info isn't loaded, show the item (don't hide it)
                    button:SetAlpha((not filterEnabled) and 0.25 or 1)
                else
                    local match = IsMatchingArmor(itemID)
                    button:SetAlpha((not filterEnabled or match) and 1 or 0.25)
                end
            end
        end
    end
end

local function CreateFilterCheckbox(frame)
    if frame.WarbandBankFilterCheckbox then return end

    local checkbox = CreateFrame("CheckButton", "WarbandBankFilterCheckbox", frame, "UICheckButtonTemplate")
    -- Position the checkbox below the warband icon, more to the right
    checkbox:SetPoint("TOPLEFT", frame, "TOPLEFT", 80, -30)
    checkbox.text:SetText("Show     \nUsable Only")
    checkbox:SetChecked(filterEnabled)
    checkbox:SetScript("OnClick", function(self)
        filterEnabled = self:GetChecked()
        WarbandBankFilterDB = WarbandBankFilterDB or {}
        WarbandBankFilterDB.enabled = filterEnabled
        -- Clear cache when filter is toggled to ensure immediate visual update
        ClearFilterCache()
        FilterItems(frame)
    end)

    frame.WarbandBankFilterCheckbox = checkbox
end

local function TryInitWarbandBankFrame()
    local f = CreateFrame("Frame")
    local checkCount = 0
    local maxChecks = 300 -- Stop after 10 seconds (300 * 1/30 fps)

    f:SetScript("OnUpdate", function(self)
        checkCount = checkCount + 1

        -- Safety: Stop checking after 10 seconds to prevent infinite loops
        if checkCount > maxChecks then
            print("WarbandBankFilter: Stopped checking for warband bank after timeout")
            self:SetScript("OnUpdate", nil)
            return
        end

        local frame = _G["AccountBankPanel"]

        if frame and frame:IsVisible() then
            -- Count button children to confirm we found the right structure
            local buttonCount = 0
            for i = 1, frame:GetNumChildren() do
                local child = select(i, frame:GetChildren())
                if child and child:GetObjectType() and string.find(child:GetObjectType(), "Button") then
                    buttonCount = buttonCount + 1
                end
            end

            if buttonCount > 50 then -- Should be around 98 buttons for warband bank
                print("WarbandBankFilter: Found warband bank with " .. buttonCount .. " item buttons")
                CreateFilterCheckbox(frame)

                -- Hook search functionality to detect changes - but only once
                if frame.SearchBox and not frame.SearchBox.WarbandBankFilterHooked then
                    frame.SearchBox:HookScript("OnTextChanged", function()
                        -- Delay filtering slightly to avoid excessive calls while typing
                        C_Timer.After(0.3, function()
                            if frame and frame:IsVisible() then
                                FilterItems(frame)
                            end
                        end)
                    end)
                    frame.SearchBox.WarbandBankFilterHooked = true
                end

                -- Also hook when the frame is shown for initial filtering - but only once
                if not frame.WarbandBankFilterShowHooked then
                    frame:HookScript("OnShow", function()
                        C_Timer.After(0.1, function()
                            if frame and frame:IsVisible() then
                                FilterItems(frame)
                            end
                        end)
                    end)
                    frame.WarbandBankFilterShowHooked = true
                end

                -- Hook when the frame is hidden to cleanup - but only once
                if not frame.WarbandBankFilterHideHooked then
                    frame:HookScript("OnHide", function()
                        print("WarbandBankFilter: Warband bank closed, cleaning up...")
                        if frame.WarbandBankFilterCheckbox then
                            frame.WarbandBankFilterCheckbox:Hide()
                            frame.WarbandBankFilterCheckbox = nil
                        end
                        -- Clear cache when closing to free memory
                        ClearFilterCache()
                        initialized = false -- Reset so it can reinitialize next time

                        -- Restart the watcher to detect when warband bank opens again
                        if watcher then
                            watcher:SetScript("OnUpdate", nil) -- Clear any existing script first
                            local watcherCheckCount = 0
                            local maxWatcherChecks = 900       -- 30 seconds max
                            watcher:SetScript("OnUpdate", function(self)
                                watcherCheckCount = watcherCheckCount + 1
                                if watcherCheckCount > maxWatcherChecks then
                                    self:SetScript("OnUpdate", nil)
                                    return
                                end

                                local frame = _G["AccountBankPanel"]
                                if frame and frame:IsVisible() and not initialized then
                                    initialized = true
                                    print("WarbandBankFilter: Warband bank detected, initializing...")
                                    TryInitWarbandBankFrame()
                                    self:SetScript("OnUpdate", nil) -- Stop watching
                                end
                            end)
                        end
                    end)
                    frame.WarbandBankFilterHideHooked = true
                end

                -- Apply initial filter
                FilterItems(frame)

                self:SetScript("OnUpdate", nil) -- IMPORTANT: Stop the OnUpdate loop
            end
        end
    end)
end

-- Create the settings panel for the AddOns interface
local function CreateSettingsPanel()
    print("WarbandBankFilter: Creating settings panel...")

    -- Check if panel already exists
    if _G["WarbandBankFilterSettingsPanel"] then
        print("WarbandBankFilter: Settings panel already exists")
        return _G["WarbandBankFilterSettingsPanel"]
    end

    -- Check if the interface is ready
    if not InterfaceOptions_AddCategory and not (Settings and Settings.RegisterCanvasLayoutCategory) then
        print("WarbandBankFilter: Interface not ready yet, panel creation will be retried later")
        return nil
    end

    local panel = CreateFrame("Frame", "WarbandBankFilterSettingsPanel")
    panel.name = "WarbandBankFilter"

    -- Add the addon icon
    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", 16, -16)

    -- Use the working path with .png extension
    local texturePath = "Interface/AddOns/WarbandBankFilter/WarbandBankFilter.png"
    icon:SetTexture(texturePath)

    -- Fallback if texture doesn't load - use a default color
    if not icon:GetTexture() then
        icon:SetColorTexture(0.2, 0.6, 1.0, 1.0) -- Blue color as fallback
        print("WarbandBankFilter: Icon texture not found, using blue fallback")
    else
        print("WarbandBankFilter: Icon texture loaded successfully")
    end -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("WarbandBankFilter")

    -- Version info
    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    version:SetText("Version: 1.0")

    -- Author info
    local author = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    author:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -4)
    author:SetText("Author: Tyler Lane")

    -- Description
    local description = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    description:SetPoint("TOPLEFT", author, "BOTTOMLEFT", 0, -16)
    description:SetText("Filters Warband Bank to only show items usable by your class.")
    description:SetWidth(500)
    description:SetJustifyH("LEFT")

    -- Settings section
    local settingsTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    settingsTitle:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -24)
    settingsTitle:SetText("Settings:")

    -- Debug mode checkbox
    local debugCheckbox = CreateFrame("CheckButton", "WarbandBankFilterDebugCheckbox", panel, "UICheckButtonTemplate")
    debugCheckbox:SetPoint("TOPLEFT", settingsTitle, "BOTTOMLEFT", 0, -8)
    debugCheckbox:SetSize(24, 24)

    local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 4, 0)
    debugLabel:SetText("Enable Debug Mode")

    -- Set initial state
    debugCheckbox:SetChecked(WarbandBankFilterDB and WarbandBankFilterDB.debugMode or false)

    -- Debug checkbox click handler
    debugCheckbox:SetScript("OnClick", function(self)
        WarbandBankFilterDB = WarbandBankFilterDB or {}
        WarbandBankFilterDB.debugMode = self:GetChecked()
        debugMode = WarbandBankFilterDB.debugMode
        if debugMode then
            print("WarbandBankFilter: Debug mode enabled")
        else
            print("WarbandBankFilter: Debug mode disabled")
        end
    end)

    -- Info section
    local infoTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    infoTitle:SetPoint("TOPLEFT", debugCheckbox, "BOTTOMLEFT", 0, -24)
    infoTitle:SetText("Information:")

    local infoText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    infoText:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -8)
    infoText:SetWidth(500)
    infoText:SetJustifyH("LEFT")
    infoText:SetText(
        [[This addon automatically filters the Warband Bank to show only items that are usable by your current character's class. It checks:

• Armor types your class can wear
• Weapons your class can use
• Primary stats that benefit your class
• Class restrictions on items

The filter also always shows:
• Crafting reagents and trade goods
• Items without class restrictions

Use debug mode to see detailed information about how items are being filtered.

Commands:
/wbf - Show available commands
/wbf debug - List bank-related frames
/wbf test <itemname> - Test filtering for an item]])

    -- Register the panel with multiple fallback methods
    local registered = false

    -- Try legacy interface first (most reliable)
    if InterfaceOptions_AddCategory then
        local success, err = pcall(InterfaceOptions_AddCategory, panel)
        if success then
            print("WarbandBankFilter: Settings panel registered with legacy interface")
            registered = true
        else
            print("WarbandBankFilter: Legacy interface registration failed: " .. tostring(err))
        end
    end

    -- Try modern interface if legacy failed
    if not registered and Settings and Settings.RegisterCanvasLayoutCategory then
        local success, err = pcall(function()
            local category, layout = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
            if category then
                category.ID = panel.name
                if Settings.RegisterAddOnCategory then
                    Settings.RegisterAddOnCategory(category)
                end
                return true
            end
            return false
        end)

        if success and err then
            print("WarbandBankFilter: Settings panel registered with modern interface")
            registered = true
        else
            print("WarbandBankFilter: Modern interface registration failed: " .. tostring(err))
        end
    end

    if not registered then
        print("WarbandBankFilter: Warning - Settings panel created but not registered with interface")
        print("WarbandBankFilter: You may need to access it manually or check WoW version compatibility")
    end

    return panel
end

WarbandBankFilter:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == "WarbandBankFilter" then
        print("WarbandBankFilter loaded - waiting for warband bank")
        WarbandBankFilterDB = WarbandBankFilterDB or {}
        WarbandBankFilterDB.debugMode = WarbandBankFilterDB.debugMode or false
        filterEnabled = WarbandBankFilterDB.enabled ~= false
        debugMode = WarbandBankFilterDB.debugMode

        -- Try to create settings panel immediately
        CreateSettingsPanel()

        -- Also try with delays as fallbacks
        C_Timer.After(0.5, function()
            CreateSettingsPanel()
        end)

        C_Timer.After(2, function()
            CreateSettingsPanel()
        end)

        -- Start watching for warband bank to open
        watcher = CreateFrame("Frame")
        local watcherCheckCount = 0
        local maxWatcherChecks = 1800 -- Stop after 60 seconds (1800 * 1/30 fps)

        watcher:SetScript("OnUpdate", function(self)
            watcherCheckCount = watcherCheckCount + 1

            -- Safety: Stop checking after 60 seconds to prevent infinite loops
            if watcherCheckCount > maxWatcherChecks then
                print("WarbandBankFilter: Stopped main watcher after timeout")
                self:SetScript("OnUpdate", nil)
                return
            end

            local frame = _G["AccountBankPanel"]
            if frame and frame:IsVisible() and not initialized then
                initialized = true
                print("WarbandBankFilter: Warband bank detected, initializing...")
                TryInitWarbandBankFrame()
                self:SetScript("OnUpdate", nil) -- Stop watching
            end
        end)
    elseif event == "PLAYER_LOGIN" then
        -- Try creating settings panel when player fully logs in
        print("WarbandBankFilter: Player login detected, ensuring settings panel exists...")
        CreateSettingsPanel()
    elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" then
        -- Clear cache when items change
        ClearFilterCache()

        -- Re-filter if warband bank is open
        local frame = _G["AccountBankPanel"]
        if frame and frame:IsVisible() then
            C_Timer.After(0.1, function()
                FilterItems(frame)
            end)
        end
    end
end)

WarbandBankFilter:RegisterEvent("ADDON_LOADED")
WarbandBankFilter:RegisterEvent("PLAYER_LOGIN")
WarbandBankFilter:RegisterEvent("BAG_UPDATE")
WarbandBankFilter:RegisterEvent("PLAYERBANKSLOTS_CHANGED")

-- Debug slash command to help identify warband bank frame
SLASH_WARBANDBANKFILTER1 = "/wbf"
SLASH_WARBANDBANKFILTER2 = "/warbandbankfilter"
SlashCmdList["WARBANDBANKFILTER"] = function(msg)
    print("WarbandBankFilter: Received command: '" .. tostring(msg) .. "'")

    if msg == "debug" then
        print("WarbandBankFilter: Scanning for bank-related frames...")
        for name, frame in pairs(_G) do
            if type(frame) == "table" and frame.GetObjectType and
                (string.find(name:upper(), "BANK") or string.find(name:upper(), "WARBAND") or string.find(name:upper(), "ACCOUNT")) then
                local objType = ""
                if frame.GetObjectType then
                    objType = " (" .. frame:GetObjectType() .. ")"
                end
                print("  Found: " .. name .. objType)

                -- Check if it has items
                if frame.items or frame.Items or frame.ItemsFrame then
                    print("    -> Has items container")
                end
                if frame:IsVisible() then
                    print("    -> Currently visible")
                end
            end
        end
    elseif msg == "settings" then
        print("WarbandBankFilter: Matched 'settings' command")
        print("WarbandBankFilter: Creating settings panel manually...")
        print("WarbandBankFilter: Checking API availability...")
        print("  InterfaceOptions_AddCategory: " .. tostring(InterfaceOptions_AddCategory ~= nil))
        print("  Settings: " .. tostring(Settings ~= nil))
        if Settings then
            print("  Settings.RegisterCanvasLayoutCategory: " .. tostring(Settings.RegisterCanvasLayoutCategory ~= nil))
            print("  Settings.RegisterAddOnCategory: " .. tostring(Settings.RegisterAddOnCategory ~= nil))
        end

        local success, error = pcall(CreateSettingsPanel)
        if success then
            print("WarbandBankFilter: Settings panel created successfully")
        else
            print("WarbandBankFilter: Error creating settings panel: " .. tostring(error))
        end
    elseif msg:match("^test ") then
        local itemName = msg:sub(6) -- Remove "test "
        print("WarbandBankFilter: Testing item: " .. itemName)

        -- Find item by name
        local itemID = nil
        for i = 1, 200000 do
            local name = GetItemInfo(i)
            if name and name:lower() == itemName:lower() then
                itemID = i
                break
            end
        end

        if itemID then
            print("  Found item ID: " .. itemID)
            local hasClassesLine, classFound = HasClassRestriction(itemID)
            print("  Has Classes line: " .. tostring(hasClassesLine))
            print("  Player class found: " .. tostring(classFound))
            local finalResult = IsMatchingArmor(itemID)
            print("  Final filtering result: " .. tostring(finalResult))
            print("  Player class: " .. class)
        else
            print("  Item not found")
        end
    elseif msg == "toggledebug" then
        print("WarbandBankFilter: Debug mode toggle information:")
        print("  Current debug mode: " .. tostring(debugMode))
        print("  To toggle debug mode, use the settings panel or edit WarbandBankFilterDB.debugMode")
        print("  You can also use '/reload' after manually changing the debugMode variable in the .lua file")
    elseif msg == "class" then
        local localizedClass, classToken = UnitClass("player")
        print("WarbandBankFilter: Class detection debug")
        print("  Stored class variable: " .. (class or "nil"))
        print("  Current localized class: " .. (localizedClass or "nil"))
        print("  Current class token: " .. (classToken or "nil"))
        print("  Armor type: " .. (myArmorType or "nil"))
        print("  Primary stats: " .. table.concat(myPrimaryStats, ", "))
    elseif msg:match("^testitem ") then
        local itemID = tonumber(msg:sub(10)) -- Remove "testitem "
        if not itemID then
            print("WarbandBankFilter: Invalid item ID")
            return
        end

        print("WarbandBankFilter: Testing item ID " .. itemID .. "...")
        local itemName = GetItemInfo(itemID)
        if itemName then
            print("  Item name: " .. itemName)

            -- Test the filtering logic directly
            local finalResult = IsMatchingArmor(itemID)
            print("  Final filtering result: " .. tostring(finalResult))

            -- Get detailed info
            local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
            print("  Item type: " .. (itemType or "nil"))
            print("  Item subtype: " .. (itemSubType or "nil"))

            if itemSubType == "Trinket" or itemSubType == "Miscellaneous" then
                local stats = C_Item.GetItemStats(itemID)
                if stats then
                    print("  Stats:")
                    for statKey, statValue in pairs(stats) do
                        print("    " .. statKey .. " = " .. statValue)
                    end
                else
                    print("  No stats available")
                end
            end
        else
            print("  Item name not available - item not cached")
        end
    elseif msg == "cache" then
        print("WarbandBankFilter: Cache status")
        local count = 0
        for itemID, result in pairs(itemFilterCache) do
            count = count + 1
        end
        print("  Cached items: " .. count)
        print("  Last search text: '" .. lastSearchText .. "'")
        if count > 0 then
            print("  Sample cached items:")
            local shown = 0
            for itemID, result in pairs(itemFilterCache) do
                if shown < 5 then
                    local itemName = GetItemInfo(itemID)
                    print("    " .. (itemName or "Unknown") .. " (ID: " .. itemID .. ") = " .. tostring(result))
                    shown = shown + 1
                end
            end
        end
    elseif msg == "clearcache" then
        print("WarbandBankFilter: Clearing filter cache...")
        ClearFilterCache()
        print("  Cache cleared")
    elseif msg == "testicon" then
        print("WarbandBankFilter: Testing icon texture...")
        local panel = _G["WarbandBankFilterSettingsPanel"]
        if panel then
            local icon = panel:GetChildren()
            for i = 1, select("#", panel:GetRegions()) do
                local region = select(i, panel:GetRegions())
                if region and region:GetObjectType() == "Texture" then
                    local texture = region:GetTexture()
                    print("  Found texture: " .. tostring(texture))
                    break
                end
            end
        else
            print("  Settings panel not found")
        end

        -- Test different texture paths
        local testPaths = {
            "Interface/AddOns/WarbandBankFilter/WarbandBankFilter",
            "Interface\\AddOns\\WarbandBankFilter\\WarbandBankFilter",
            "Interface/AddOns/WarbandBankFilter/WarbandBankFilter.png",
            "Interface\\AddOns\\WarbandBankFilter\\WarbandBankFilter.png"
        }

        for _, path in ipairs(testPaths) do
            local testFrame = CreateFrame("Frame")
            local testTexture = testFrame:CreateTexture()
            testTexture:SetTexture(path)
            if testTexture:GetTexture() then
                print("  Path works: " .. path)
            else
                print("  Path failed: " .. path)
            end
            testFrame:Hide()
        end
    elseif msg == "cleanup" then
        print("WarbandBankFilter: Performing emergency cleanup...")

        -- Clear all OnUpdate scripts from potential problem frames
        if watcher then
            watcher:SetScript("OnUpdate", nil)
            print("  Cleared main watcher OnUpdate script")
        end

        -- Clear any lingering tooltips
        for i = 1, 300000 do -- Check a wider range of item IDs
            local tooltipName = "WarbandBankFilterTooltip" .. i
            local tooltip = _G[tooltipName]
            if tooltip then
                tooltip:Hide()
                tooltip:ClearLines()
                -- Don't use SetOwner(nil) as it causes errors
                _G[tooltipName] = nil -- Remove from global namespace
            end
        end
        print("  Cleared potential lingering tooltips")

        -- Clear cache
        ClearFilterCache()
        print("  Cleared filter cache")

        -- Reset initialized state
        initialized = false
        print("  Reset initialization state")

        print("WarbandBankFilter: Emergency cleanup complete. Try using the addon again.")
    elseif msg == "status" then
        print("WarbandBankFilter: Status check")
        print("  Filter enabled: " .. tostring(filterEnabled))
        print("  Initialized: " .. tostring(initialized))
        print("  Debug mode: " .. tostring(debugMode))
        print("  Watcher exists: " .. tostring(watcher ~= nil))

        if watcher then
            local hasScript = watcher:GetScript("OnUpdate") ~= nil
            print("  Watcher has OnUpdate script: " .. tostring(hasScript))
        end

        local frame = _G["AccountBankPanel"]
        if frame then
            print("  AccountBankPanel exists: true")
            print("  AccountBankPanel visible: " .. tostring(frame:IsVisible()))
            if frame.WarbandBankFilterCheckbox then
                print("  Filter checkbox exists: true")
            else
                print("  Filter checkbox exists: false")
            end
        else
            print("  AccountBankPanel exists: false")
        end
    else
        print("WarbandBankFilter commands:")
        print("/wbf debug - List all bank-related frames")
        print("/wbf test <itemname> - Test class restriction checking for an item")
        print("/wbf testitem <itemid> - Test filtering for a specific item ID")
        print("/wbf class - Show current class detection")
        print("/wbf cache - Show cache status and sample items")
        print("/wbf clearcache - Clear the filter cache")
        print("/wbf testicon - Test icon texture loading")
        print("/wbf cleanup - Emergency cleanup (use if addon causes mouse issues)")
        print("/wbf status - Show addon status and debug info")
        print("/wbf settings - Manually create settings panel")
        print("/wbf toggledebug - Info on how to toggle debug mode")
    end
end
