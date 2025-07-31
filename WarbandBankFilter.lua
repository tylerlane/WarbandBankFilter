local WarbandBankFilter = CreateFrame("Frame")
local filterEnabled = true
local initialized = false
local watcher = nil -- Store reference to the watcher frame
local itemFilterCache = {} -- Cache filter results to avoid repeated calculations
local lastSearchText = "" -- Track search changes

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
    MAGE = {"Daggers", "One-Handed Swords", "Staves", "Wands"},
    PRIEST = {"Daggers", "One-Handed Maces", "Staves", "Wands"},
    WARLOCK = {"Daggers", "One-Handed Swords", "Staves", "Wands"},
    ROGUE = {"Daggers", "One-Handed Swords", "Fist Weapons", "One-Handed Maces", "Bows", "Crossbows", "Guns"},
    DRUID = {"Daggers", "Fist Weapons", "One-Handed Maces", "Polearms", "Staves", "Two-Handed Maces"},
    MONK = {"Fist Weapons", "One-Handed Maces", "One-Handed Swords", "Polearms", "Staves"},
    DEMONHUNTER = {"Fist Weapons", "One-Handed Swords", "Warglaives"},
    HUNTER = {"Daggers", "Fist Weapons", "One-Handed Swords", "One-Handed Axes", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Staves", "Bows", "Crossbows", "Guns"},
    SHAMAN = {"Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Axes", "Staves", "Shields"},
    EVOKER = {"Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Staves"},
    WARRIOR = {"Daggers", "Fist Weapons", "One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Staves", "Bows", "Crossbows", "Guns", "Shields"},
    PALADIN = {"One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms", "Shields"},
    DEATHKNIGHT = {"One-Handed Maces", "One-Handed Swords", "One-Handed Axes", "Two-Handed Maces", "Two-Handed Swords", "Two-Handed Axes", "Polearms"}
}

local classPrimaryStats = {
    MAGE = {"Intellect"},
    PRIEST = {"Intellect"},
    WARLOCK = {"Intellect"},
    ROGUE = {"Agility"},
    DRUID = {"Intellect", "Agility"}, -- Hybrid class
    MONK = {"Agility", "Intellect"}, -- Hybrid class  
    DEMONHUNTER = {"Agility"},
    HUNTER = {"Agility"},
    SHAMAN = {"Intellect", "Agility"}, -- Hybrid class
    EVOKER = {"Intellect"},
    WARRIOR = {"Strength"},
    PALADIN = {"Strength", "Intellect"}, -- Hybrid class
    DEATHKNIGHT = {"Strength"}
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
    
    -- Create tooltip to check for class restrictions
    local tooltip = CreateFrame("GameTooltip", "WarbandBankFilterTooltip", UIParent, "GameTooltipTemplate")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:SetItemByID(itemID)
    
    local classFound = false
    local hasClassesLine = false
    
    -- Debug mode for testing
    local debugMode = false
    if debugMode then
        print("WarbandBankFilter Debug: Checking item " .. (itemName or "unknown") .. " (ID: " .. itemID .. ")")
        print("  Player class: " .. class)
    end
    
    for i = 1, tooltip:NumLines() do
        local line = _G["WarbandBankFilterTooltipTextLeft" .. i]
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
                    end
                    
                    -- Handle class name variations
                    local classVariations = {
                        deathknight = {"death knight", "deathknight", "dk"},
                        demonhunter = {"demon hunter", "demonhunter", "dh"}
                    }
                    
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
                        if lowerText:find(lowerClass) then
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
    
    tooltip:Hide()
    
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
    
    -- First check for class restrictions on ALL items
    local hasClassesLine, classFound = HasClassRestriction(itemID)
    if hasClassesLine then
        -- If item has "Classes:" line, only show if our class is listed
        result = classFound
        itemFilterCache[itemID] = result
        return result
    end
    
    -- Get item info - if it's not loaded yet, show the item (don't hide it)
    local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
    
    -- If item info isn't loaded yet, don't cache and show the item by default
    if not itemType or not itemSubType then
        return true
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
                        local properLocation = ItemLocation:CreateFromBagAndSlot(itemLocation.bagID, itemLocation.slotIndex)
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
    checkbox.text:SetText("Usable Only")
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
    f:SetScript("OnUpdate", function(self)
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
                
                -- Hook search functionality to detect changes
                if frame.SearchBox then
                    frame.SearchBox:HookScript("OnTextChanged", function()
                        -- Delay filtering slightly to avoid excessive calls while typing
                        C_Timer.After(0.3, function()
                            if frame:IsVisible() then
                                FilterItems(frame)
                            end
                        end)
                    end)
                end
                
                -- Also hook when the frame is shown for initial filtering
                frame:HookScript("OnShow", function()
                    C_Timer.After(0.1, function()
                        FilterItems(frame)
                    end)
                end)
                
                -- Hook when the frame is hidden to cleanup
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
                        watcher:SetScript("OnUpdate", function(self)
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
                
                -- Apply initial filter
                FilterItems(frame)
                
                self:SetScript("OnUpdate", nil)
            end
        end
    end)
end

WarbandBankFilter:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == "WarbandBankFilter" then
        print("WarbandBankFilter loaded - waiting for warband bank")
        WarbandBankFilterDB = WarbandBankFilterDB or {}
        filterEnabled = WarbandBankFilterDB.enabled ~= false
        
        -- Start watching for warband bank to open
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnUpdate", function(self)
            local frame = _G["AccountBankPanel"]
            if frame and frame:IsVisible() and not initialized then
                initialized = true
                print("WarbandBankFilter: Warband bank detected, initializing...")
                TryInitWarbandBankFrame()
                self:SetScript("OnUpdate", nil) -- Stop watching
            end
        end)
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
WarbandBankFilter:RegisterEvent("BAG_UPDATE")
WarbandBankFilter:RegisterEvent("PLAYERBANKSLOTS_CHANGED")

-- Debug slash command to help identify warband bank frame
SLASH_WARBANDBANKFILTER1 = "/wbf"
SLASH_WARBANDBANKFILTER2 = "/warbandbankfilter"
SlashCmdList["WARBANDBANKFILTER"] = function(msg)
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
    elseif msg == "retry" then
        -- print("ArmorFilter: Retrying warband bank initialization...")
        TryInitWarbandBankFrame()
    elseif msg == "toggledebug" then
        -- Toggle debug mode for armor tokens
        local found = false
        for line in string.gmatch(GetAddOnMetadata("ArmorFilter", "Notes") or "", "[^\r\n]+") do
            if line:find("debugMode = ") then
                found = true
                break
            end
        end
        print("WarbandBankFilter: Use '/reload' after editing the .lua file to change debug mode")
        print("  Look for 'local debugMode = true' in IsArmorTokenForMyClass function")
 
    elseif msg == "zenith" then
        print("WarbandBankFilter: Testing Zenith Hand Module specifically...")
        local hasClassesLine, classFound = HasClassRestriction(224069) -- Zenith Hand Module item ID
        print("  Has Classes line: " .. tostring(hasClassesLine))
        print("  Player class found: " .. tostring(classFound))
        local finalResult = IsMatchingArmor(224069)
        print("  Final filtering result: " .. tostring(finalResult))
        print("  Player class: " .. class)
        print("  Expected: Should be filtered out if not for this class")
    elseif msg == "funhouse" then
        print("WarbandBankFilter: Testing Funhouse Lens specifically...")
        local itemID = 234217 -- Funhouse Lens item ID
        print("  Using item ID: " .. itemID)
        
        -- More aggressive item loading attempts
        print("  Attempting to load item data...")
        C_Item.RequestLoadItemDataByID(itemID)
        
        -- Create a temporary tooltip to force load the item
        local tooltip = CreateFrame("GameTooltip", "FunhouseTestTooltip", UIParent, "GameTooltipTemplate")
        tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        tooltip:SetItemByID(itemID)
        tooltip:Hide()
        
        -- Also try these loading methods
        C_TooltipInfo.GetItemByID(itemID)
        GetItemInfo(itemID)
        
        -- Try multiple times with increasing delays
        local function tryLoadItem(attempt)
            local itemName = GetItemInfo(itemID)
            print("  Attempt " .. attempt .. " - Item name: " .. (itemName or "nil - not loaded"))
            
            if itemName then
                -- Test class restrictions first
                local hasClassesLine, classFound = HasClassRestriction(itemID)
                print("  Has Classes line: " .. tostring(hasClassesLine))
                print("  Player class found: " .. tostring(classFound))
                
                -- Get item info to debug
                local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
                print("  Item type: " .. (itemType or "nil"))
                print("  Item subtype: " .. (itemSubType or "nil"))
                
                -- Test stats
                local stats = C_Item.GetItemStats(itemID)
                if stats then
                    print("  Item stats:")
                    for statKey, statValue in pairs(stats) do
                        print("    " .. statKey .. " = " .. statValue)
                    end
                    
                    -- Test primary stat detection
                    print("  Player primary stats: " .. table.concat(myPrimaryStats, ", "))
                    
                    local hasAnyPrimaryStat = false
                    local hasMyPrimaryStat = false
                    
                    for statKey, statValue in pairs(stats) do
                        local upperKey = statKey:upper()
                        
                        -- Check if it has any primary stat
                        if upperKey == "ITEM_MOD_STRENGTH_SHORT" or upperKey == "STRENGTH" or string.find(upperKey, "^ITEM_MOD_STRENGTH_") or
                           upperKey == "ITEM_MOD_AGILITY_SHORT" or upperKey == "AGILITY" or string.find(upperKey, "^ITEM_MOD_AGILITY_") or
                           upperKey == "ITEM_MOD_INTELLECT_SHORT" or upperKey == "INTELLECT" or string.find(upperKey, "^ITEM_MOD_INTELLECT_") then
                            hasAnyPrimaryStat = true
                            print("  Found primary stat: " .. upperKey)
                            
                            -- Check if it has our specific primary stat(s)
                            for _, primaryStat in ipairs(myPrimaryStats) do
                                local primaryStatUpper = primaryStat:upper()
                                if upperKey == "ITEM_MOD_" .. primaryStatUpper .. "_SHORT" or
                                   upperKey == primaryStatUpper or
                                   string.find(upperKey, "^ITEM_MOD_" .. primaryStatUpper .. "_") then
                                    hasMyPrimaryStat = true
                                    print("  Matches our primary stat: " .. primaryStat)
                                    break
                                end
                            end
                        end
                    end
                    
                    print("  Has any primary stat: " .. tostring(hasAnyPrimaryStat))
                    print("  Has my primary stat: " .. tostring(hasMyPrimaryStat))
                    print("  Trinket logic result: " .. tostring(hasMyPrimaryStat or not hasAnyPrimaryStat))
                else
                    print("  No stats found")
                end
                
                local finalResult = IsMatchingArmor(itemID)
                print("  Final filtering result: " .. tostring(finalResult))
                print("  Player class: " .. class)
            else
                print("  Item data still not loaded on attempt " .. attempt)
                if attempt < 5 then
                    -- Try again with longer delay
                    C_Timer.After(0.5 * attempt, function()
                        tryLoadItem(attempt + 1)
                    end)
                else
                    print("  FAILED: Item data could not be loaded after 5 attempts")
                    print("  This usually means:")
                    print("    1. You need to see the item in-game first (hover over it)")
                    print("    2. The item ID might be wrong")
                    print("    3. You're not connected to the server")
                end
            end
        end
        
        -- Start the loading attempts
        tryLoadItem(1)
    elseif msg == "staff" then
        print("WarbandBankFilter: Testing staff detection...")
        local frame = _G["AccountBankPanel"]
        if frame and frame:IsVisible() then
            local staffCount = 0
            for i = 1, frame:GetNumChildren() do
                local child = select(i, frame:GetChildren())
                if child and child:GetObjectType() and string.find(child:GetObjectType(), "Button") then
                    local itemID = nil
                    if child.GetBagID and child.GetID then
                        local bagID = child:GetBagID()
                        local slotIndex = child:GetID()
                        if bagID and slotIndex then
                            local itemLocation = ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)
                            if itemLocation and itemLocation:IsValid() then
                                itemID = C_Item.GetItemID(itemLocation)
                            end
                        end
                    end
                    
                    if itemID then
                        local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
                        if itemType == "Weapon" and itemSubType == "Staves" then
                            staffCount = staffCount + 1
                            local itemName = GetItemInfo(itemID)
                            print("  Found staff: " .. (itemName or "Unknown") .. " (ID: " .. itemID .. ")")
                            
                            -- Test if it would be filtered
                            local shouldShow = IsMatchingArmor(itemID)
                            print("    Should show: " .. tostring(shouldShow))
                            print("    Player class: " .. class)
                            
                            -- Test class restrictions
                            local hasClassesLine, classFound = HasClassRestriction(itemID)
                            if hasClassesLine then
                                print("    Has class restriction: " .. tostring(classFound))
                            end
                            
                            -- Test stats
                            local stats = C_Item.GetItemStats(itemID)
                            if stats then
                                print("    Has stats - checking primary stats...")
                                for statKey, statValue in pairs(stats) do
                                    local upperKey = statKey:upper()
                                    if upperKey == "ITEM_MOD_STRENGTH_SHORT" or upperKey == "STRENGTH" or string.find(upperKey, "^ITEM_MOD_STRENGTH_") or
                                       upperKey == "ITEM_MOD_AGILITY_SHORT" or upperKey == "AGILITY" or string.find(upperKey, "^ITEM_MOD_AGILITY_") or
                                       upperKey == "ITEM_MOD_INTELLECT_SHORT" or upperKey == "INTELLECT" or string.find(upperKey, "^ITEM_MOD_INTELLECT_") then
                                        print("      Primary stat found: " .. statKey .. " = " .. statValue)
                                    end
                                end
                            else
                                print("    No stats available")
                            end
                        end
                    end
                end
            end
            print("  Total staves found: " .. staffCount)
        else
            print("  Warband bank not open")
        end
        print("WarbandBankFilter: Testing Dalaran Defender's Battlestaff specifically...")
        local itemName = "Dalaran Defender's Battlestaff"
        
        -- Find item by name
        local itemID = nil
        for i = 1, 300000 do
            local name = GetItemInfo(i)
            if name and name:lower() == itemName:lower() then
                itemID = i
                break
            end
        end
        
        if itemID then
            print("  Found item ID: " .. itemID)
            local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
            print("  Item type: " .. (itemType or "nil"))
            print("  Item subtype: " .. (itemSubType or "nil"))
            print("  Player class: " .. class)
            print("  Player weapons: " .. table.concat(myWeapons, ", "))
            
            local hasClassesLine, classFound = HasClassRestriction(itemID)
            print("  Has Classes line: " .. tostring(hasClassesLine))
            print("  Player class found: " .. tostring(classFound))
            
            local finalResult = IsMatchingArmor(itemID)
            print("  Final filtering result: " .. tostring(finalResult))
        else
            print("  Item not found")
        end
    elseif msg == "scanitems" then
        print("WarbandBankFilter: Scanning for Funhouse Lens in warband bank...")
        local frame = _G["AccountBankPanel"]
        if not frame or not frame:IsVisible() then
            print("  Error: Warband bank is not open!")
            return
        end
        
        -- Scan all item buttons in the warband bank
        local foundItems = {}
        for i = 1, frame:GetNumChildren() do
            local child = select(i, frame:GetChildren())
            if child and child:GetObjectType() and string.find(child:GetObjectType(), "Button") then
                local itemID = nil
                
                -- Try to get item ID from the button
                if child.GetItemLocation then
                    local itemLocation = child:GetItemLocation()
                    if itemLocation then
                        itemID = C_Item.GetItemID(itemLocation)
                    end
                elseif child.GetBagID and child.GetID then
                    local bagID = child:GetBagID()
                    local slotIndex = child:GetID()
                    if bagID and slotIndex then
                        local itemLocation = ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)
                        if itemLocation and itemLocation:IsValid() then
                            itemID = C_Item.GetItemID(itemLocation)
                        end
                    end
                end
                
                if itemID then
                    local itemName = GetItemInfo(itemID)
                    if itemName and string.find(itemName:lower(), "funhouse") then
                        table.insert(foundItems, {id = itemID, name = itemName})
                        print("  FOUND: " .. itemName .. " (ID: " .. itemID .. ")")
                    end
                end
            end
        end
        
        if #foundItems == 0 then
            print("  No Funhouse items found in warband bank")
            print("  Make sure you have a Funhouse Lens in your warband bank")
        else
            print("  Found " .. #foundItems .. " Funhouse item(s)")
            print("  Now run: /wbf testitem " .. foundItems[1].id)
        end
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
    elseif msg == "inspect" then
        local frame = _G["AccountBankPanel"]
        if frame then
            -- print("ArmorFilter: Inspecting AccountBankPanel structure...")
            -- print("  Frame name: " .. (frame:GetName() or "unnamed"))
            -- print("  Frame type: " .. frame:GetObjectType())
            -- print("  Is visible: " .. tostring(frame:IsVisible()))
            -- print("  Number of children: " .. frame:GetNumChildren())
            
            -- Only show non-button children and summarize buttons
            print("  Important children:")
            local buttonCount = 0
            for i = 1, frame:GetNumChildren() do
                local child = select(i, frame:GetChildren())
                if child then
                    local childName = child:GetName() or ("Child" .. i)
                    local childType = child:GetObjectType()
                    
                    if not string.find(childType, "Button") then
                        print("    " .. childName .. ": " .. childType)
                        
                        -- Check if this child has items
                        if child.items or child.Items then
                            print("      -> HAS ITEMS!")
                        end
                        
                        -- Check if this child has many button children (likely the item container)
                        if child:GetNumChildren() > 10 then
                            local childButtonCount = 0
                            for j = 1, child:GetNumChildren() do
                                local grandchild = select(j, child:GetChildren())
                                if grandchild and string.find(grandchild:GetObjectType(), "Button") then
                                    childButtonCount = childButtonCount + 1
                                end
                            end
                            if childButtonCount > 0 then
                                print("      -> Contains " .. childButtonCount .. " buttons (likely item slots)")
                            end
                        end
                    else
                        buttonCount = buttonCount + 1
                    end
                end
            end
            
            if buttonCount > 0 then
                print("  + " .. buttonCount .. " direct button children (not detailed)")
            end
        else
            print("WarbandBankFilter: AccountBankPanel not found")
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
    else
        print("WarbandBankFilter commands:")
        print("/wbf debug - List all bank-related frames")
        print("/wbf test <itemname> - Test class restriction checking for an item")
        print("/wbf zenith - Test Zenith Hand Module filtering specifically")
        print("/wbf funhouse - Test Funhouse Lens filtering specifically")
        print("/wbf scanitems - Find Funhouse items in warband bank")
        print("/wbf testitem <itemid> - Test filtering for a specific item ID")
        print("/wbf staff - Test Dalaran Defender's Battlestaff specifically")
        print("/wbf retry - Retry hooking warband bank")
        print("/wbf inspect - Detailed inspection of AccountBankPanel")
        print("/wbf cache - Show cache status and sample items")
        print("/wbf clearcache - Clear the filter cache")
        print("/wbf toggledebug - Info on how to toggle debug mode for armor tokens")
    end
end
