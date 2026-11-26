local addonName = ...

local RU = GetLocale() == "ruRU"

local function L(ru, en)
    if RU then return ru end
    return en
end

local FACE = "Interface\\AddOns\\Holop\\face.png"

local running = false
local plan = {}
local planIndex = 1
local DB
local BuildPlan
local RefreshMoney
local current = nil
local bar = nil
local lastCast = 0
local flashTicker = nil

local function Print(text)
    print("|cffc6a36a" .. L("Холоп", "Holop") .. "|r: " .. text)
end

local function Page()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage
end

local function ProfessionOpen()
    local page = Page()
    return ProfessionsFrame and ProfessionsFrame:IsShown() and page and page:IsShown()
end

local function OwnProfession()
    local api = C_TradeSkillUI
    if not api or not ProfessionOpen() then return false end
    if api.IsTradeSkillLinked and api.IsTradeSkillLinked() then return false end
    if api.IsNPCCrafting and api.IsNPCCrafting() then return false end
    if api.IsTradeSkillGuild and api.IsTradeSkillGuild() then return false end
    return true
end

local function CraftableCount(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetCraftableCount) then return 0 end
    local ok, count = pcall(api.GetCraftableCount, recipeID)
    if ok and type(count) == "number" and count > 0 then
        return count
    end
    return 0
end

local function CastSeconds(recipeID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, recipeID)
        if ok and type(info) == "table" and type(info.castTime) == "number" and info.castTime > 0 then
            return info.castTime / 1000
        end
    end
    if GetSpellInfo then
        local ok, _, _, _, castTime = pcall(GetSpellInfo, recipeID)
        if ok and type(castTime) == "number" and castTime > 0 then
            return castTime / 1000
        end
    end
end

local function FormatDuration(seconds)
    seconds = math.floor((seconds or 0) + 0.5)
    if seconds < 0 then seconds = 0 end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%d ч %d мин", hours, minutes)
    end
    if minutes > 0 then
        return string.format("%d мин %d сек", minutes, secs)
    end
    return string.format("%d сек", secs)
end

local function UsesReagents(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeSchematic) then return false end
    local ok, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
    if not ok or not schematic then return false end
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if (slot.quantityRequired or 0) > 0 then
            return true
        end
    end
    return false
end

local function SetStatus(text)
    if bar and bar.status then
        bar.status:SetText(text)
    end
end

local function SilenceMaster()
    if flashTicker then
        flashTicker:Cancel()
        flashTicker = nil
    end
end

local function PingMaster()
    pcall(PlaySound, 8959, "Master")
    if FlashClientIcon then
        pcall(FlashClientIcon)
    end
end

local YELL = "Хозяиииииин"

local function OnCraftList(itemID)
    local craft = DB().craft
    if type(craft) ~= "table" or not itemID then return false end
    return craft[itemID] or craft[tostring(itemID)]
end

local function RecipeOutput(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeSchematic and recipeID) then return end
    local ok, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
    if ok and schematic and schematic.outputItemID then
        return schematic.outputItemID
    end
end

local function RefreshQueuePanel()
    if not bar or not bar.queueLines then return end
    if running then
        bar.status:SetText(L("Сейчас делается", "Making now"))
    else
        bar.status:SetText(L("Жми «Начать» в этом окне.", "Press Start in this window."))
    end
    local total = 0
    local known = true
    local line = 1
    local hidden = 0
    for i = math.max(planIndex, 1), #plan do
        local step = plan[i]
        if step then
            local count = CraftableCount(step.id)
            if running and current and step.id == current.id and current.left then
                count = math.max((current.left or 0) - (current.done or 0), 0)
            end
            if count > 0 then
                local cast = step.cast
                if not cast or cast <= 0 then
                    known = false
                    cast = 0
                end
                total = total + cast * count
                if line <= #bar.queueLines then
                    local timeText = (step.cast and step.cast > 0) and FormatDuration(step.cast * count) or "?"
                    bar.queueLines[line]:SetText(line .. ". " .. step.name .. "  ×" .. count .. "  " .. timeText)
                    bar.queueLines[line]:Show()
                    line = line + 1
                else
                    hidden = hidden + 1
                end
            end
        end
    end
    for i = line, #bar.queueLines do
        bar.queueLines[i]:SetText("")
        bar.queueLines[i]:Hide()
    end
    if line == 1 then
        bar.queueLines[1]:SetText(L("Из списка «всегда» сейчас нечего делать.", "Nothing on the always-craft list can be made now."))
        bar.queueLines[1]:Show()
    end
    local totalText = known and FormatDuration(total) or "?"
    if hidden > 0 then
        totalText = totalText .. "  +" .. hidden
    end
    bar.total:SetText(L("Всего: ", "Total: ") .. totalText)
    if RefreshMoney then
        pcall(RefreshMoney)
    end
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

local function ReadSellPrice(fn, itemID)
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(fn, itemID)
    if ok and name and type(sellPrice) == "number" then
        return sellPrice
    end
end

local function VendorPays(itemID)
    local id = tonumber(itemID)
    if not id then return end
    if C_Item and C_Item.GetItemInfo then
        local price = ReadSellPrice(C_Item.GetItemInfo, id)
        if price then return price end
    end
    if GetItemInfo then
        local price = ReadSellPrice(GetItemInfo, id)
        if price then return price end
    end
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
end

local function MoneyText(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then copper = 0 end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local left = copper % 100
    local text = ""
    if gold > 0 then
        text = gold .. " " .. GOLD_ICON .. " "
    end
    if gold > 0 or silver > 0 then
        text = text .. silver .. " " .. SILVER_ICON .. " "
    end
    return text .. left .. " " .. COPPER_ICON
end

local function ShowQueue()
    if running then
        RefreshQueuePanel()
        return
    end
    if not OwnProfession() then return end
    BuildPlan()
    planIndex = 1
    RefreshQueuePanel()
end

local function CallMaster()
    RefreshQueuePanel()
    Print(YELL)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
        RaidNotice_AddMessage(RaidWarningFrame, YELL, ChatTypeInfo.RAID_WARNING)
    end
    PingMaster()
    if flashTicker then
        flashTicker:Cancel()
    end
    local ticks = 0
    flashTicker = C_Timer.NewTicker(0.8, function()
        ticks = ticks + 1
        if FlashClientIcon then
            pcall(FlashClientIcon)
        end
        if ticks % 4 == 0 then
            pcall(PlaySound, 8959, "Master")
            if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
                RaidNotice_AddMessage(RaidWarningFrame, YELL, ChatTypeInfo.RAID_WARNING)
            end
        end
    end)
end

local function StopRun(line)
    SilenceMaster()
    running = false
    current = nil
    if line then
        SetStatus(line)
        Print(line)
    end
end

-- The profession window's own "Create all" ends in transaction:CraftRecipe.
-- Calling that directly skips SetOverrideCastBarActive, which the client blocks for addons.
local function CraftOpenRecipe()
    local page = Page()
    local form = page and page.SchematicForm
    if not (form and form.GetRecipeInfo and form.GetTransaction) then return end
    local info = form:GetRecipeInfo()
    local tx = form:GetTransaction()
    if not (info and info.recipeID and tx and tx.CraftRecipe) then return end
    local count = CraftableCount(info.recipeID)
    if page.GetCraftableCount then
        local ok, n = pcall(page.GetCraftableCount, page)
        if ok and type(n) == "number" and n > 0 and n < 100000 then
            count = n
        end
    end
    if count < 1 then return end
    local level = form.GetCurrentRecipeLevel and form:GetCurrentRecipeLevel() or nil
    tx:CraftRecipe(info.recipeID, count, level)
    return info, count
end

function BuildPlan()
    wipe(plan)
    local api = C_TradeSkillUI
    if not (OwnProfession() and api and api.GetAllRecipeIDs) then return end
    local ok, ids = pcall(api.GetAllRecipeIDs)
    if not ok or not ids then return end
    local seen = {}
    local page = Page()
    local shown = page and page.SchematicForm and page.SchematicForm.GetRecipeInfo and page.SchematicForm:GetRecipeInfo()
    local function Add(recipeID, info)
        if seen[recipeID] or not info or not info.learned or not info.name then return end
        if not UsesReagents(recipeID) then return end
        local output = RecipeOutput(recipeID)
        if not output or not OnCraftList(output) then return end
        local count = CraftableCount(recipeID)
        if count < 1 then return end
        seen[recipeID] = true
        plan[#plan + 1] = { id = recipeID, name = info.name, count = count, cast = CastSeconds(recipeID) }
    end
    if shown and shown.recipeID then
        local infoOk, info = pcall(api.GetRecipeInfo, shown.recipeID)
        if infoOk then Add(shown.recipeID, info) end
    end
    for _, recipeID in ipairs(ids) do
        local infoOk, info = pcall(api.GetRecipeInfo, recipeID)
        if infoOk then Add(recipeID, info) end
    end
end

local function BeginStep(step, skipSelect)
    local page = Page()
    if not skipSelect and page and page.SelectRecipe and step then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, step.id)
        if ok and info then
            pcall(page.SelectRecipe, page, info)
        end
    end
    local info, count = CraftOpenRecipe()
    if not info then
        return false
    end
    current = { id = info.recipeID, name = info.name, left = count, done = 0, initial = count }
    lastCast = GetTime()
    running = true
    SetStatus(info.name .. "  x" .. count)
    RefreshQueuePanel()
    return true
end

local function HandOff()
    running = false
    current = nil
    while planIndex <= #plan and CraftableCount(plan[planIndex].id) < 1 do
        planIndex = planIndex + 1
    end
    if planIndex > #plan then
        StopRun(L("Больше не из чего.", "Nothing left to craft."))
        return
    end
    local step = plan[planIndex]
    local page = Page()
    if page and page.SelectRecipe then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, step.id)
        if ok and info then
            pcall(page.SelectRecipe, page, info)
        end
    end
    CallMaster()
end

local function StartRun()
    if running and (UnitCastingInfo("player") or UnitChannelInfo("player")) then
        return
    end
    running = false
    current = nil
    if not OwnProfession() then
        Print(L("Открой кулинарию или другую профессию.", "Open cooking or another profession."))
        return
    end
    BuildPlan()
    if #plan == 0 then
        RefreshQueuePanel()
        Print(L("Из списка «всегда» сейчас нечего делать.", "Nothing on the always-craft list can be made now."))
        return
    end
    planIndex = 1
    local page = Page()
    local shown = page and page.SchematicForm and page.SchematicForm.GetRecipeInfo and page.SchematicForm:GetRecipeInfo()
    local alreadyOpen = shown and shown.recipeID == plan[1].id
    if not BeginStep(plan[1], alreadyOpen) then
        CallMaster()
        return
    end
    SilenceMaster()
    Print(L("Делаю из списка «всегда».", "Crafting from the always-craft list."))
end

local function NoteCast(spellID)
    if not (running and current) then return end
    lastCast = GetTime()
    if spellID and spellID ~= 0 and spellID ~= current.id then
        return
    end
    current.done = current.done + 1
    RefreshQueuePanel()
end

local function WatchCraft()
    if not (running and current) then return end
    if UnitCastingInfo("player") or UnitChannelInfo("player") then
        lastCast = GetTime()
        return
    end
    if GetTime() - lastCast < 0.8 then
        return
    end
    local leftNow = CraftableCount(current.id)
    if current.done >= current.left or leftNow <= 0 then
        planIndex = planIndex + 1
        HandOff()
        return
    end
    if current.done == 0 and GetTime() - lastCast > 1.5 then
        CallMaster()
        running = false
        current = nil
    end
end

local listFrame
local listRows = { craft = {}, restock = {}, sell = {} }

function DB()
    HolopDB = HolopDB or {}
    if type(HolopDB.craft) ~= "table" then HolopDB.craft = {} end
    if type(HolopDB.restock) ~= "table" then HolopDB.restock = {} end
    if type(HolopDB.sell) ~= "table" then HolopDB.sell = {} end
    if type(HolopDB.buyPrice) ~= "table" then HolopDB.buyPrice = {} end
    if type(HolopDB.recipeBook) ~= "table" then HolopDB.recipeBook = {} end
    return HolopDB
end

local function ItemName(itemID)
    local id = tonumber(itemID)
    if not id then
        return tostring(itemID)
    end
    if C_Item and C_Item.GetItemNameByID then
        local ok, name = pcall(C_Item.GetItemNameByID, id)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    if GetItemInfo then
        local ok, name = pcall(GetItemInfo, id)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "#" .. id
end

local function ItemCount(itemID)
    local id = tonumber(itemID)
    if not id then return 0 end
    if C_Item and C_Item.GetItemCount then
        local ok, count = pcall(C_Item.GetItemCount, id)
        if ok and type(count) == "number" then
            return count
        end
    end
    if GetItemCount then
        local ok, count = pcall(GetItemCount, id)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 0
end

-- Master Chef (Шеф-повар), Legacy tree Professions. Each rank is a 10% chance
-- of one extra portion. Spell 1225457, node 110289, five ranks.
local CHEF_NODE = 110289
local CHEF_SPELL = 1225457
local chefRank, chefKnown

local function ForgetChef()
    chefRank, chefKnown = nil, false
end

local function ChefNodeSpell(configID, info)
    if not (C_Traits and C_Traits.GetEntryInfo and C_Traits.GetDefinitionInfo) then return end
    local entryID
    if type(info.activeEntry) == "table" then
        entryID = info.activeEntry.entryID
    end
    if type(entryID) ~= "number" and type(info.entryIDs) == "table" then
        entryID = info.entryIDs[1]
    end
    if type(entryID) ~= "number" then return end
    local okEntry, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
    if not okEntry or type(entry) ~= "table" or type(entry.definitionID) ~= "number" then return end
    local okDef, definition = pcall(C_Traits.GetDefinitionInfo, entry.definitionID)
    if not okDef or type(definition) ~= "table" then return end
    return definition.spellID or definition.overriddenSpellID
end

local function ChefRankFromInfo(info)
    local rank = info.ranksPurchased
    if type(rank) ~= "number" then rank = info.currentRank end
    if type(rank) ~= "number" then rank = info.activeRank end
    if type(rank) ~= "number" then return end
    if rank < 0 then rank = 0 end
    if rank > 5 then rank = 5 end
    return rank
end

local function ChefFromConfig(configID)
    if not (C_Traits and C_Traits.GetNodeInfo) or type(configID) ~= "number" then return end
    local ok, info = pcall(C_Traits.GetNodeInfo, configID, CHEF_NODE)
    if ok and type(info) == "table" and (info.ID == nil or info.ID == CHEF_NODE) then
        local spellID = ChefNodeSpell(configID, info)
        if spellID == CHEF_SPELL then
            local rank = ChefRankFromInfo(info)
            if rank then
                return rank, true
            end
        end
    end
    for nodeID = 110284, 110319 do
        if nodeID ~= CHEF_NODE then
            local nodeOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nodeOk and type(node) == "table" and ChefNodeSpell(configID, node) == CHEF_SPELL then
                local rank = ChefRankFromInfo(node)
                if rank then
                    return rank, true
                end
            end
        end
    end
end

local function ChefFromTalents()
    if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return end
    local okTabs, tabs = pcall(GetNumTalentTabs)
    if not okTabs or type(tabs) ~= "number" then return end
    for tab = 1, tabs do
        local okCount, count = pcall(GetNumTalents, tab)
        if okCount and type(count) == "number" then
            for index = 1, count do
                local okInfo, name, _, _, _, rank = pcall(GetTalentInfo, tab, index)
                if okInfo and type(name) == "string" then
                    if name == "Шеф-повар" or name:lower() == "master chef" then
                        rank = tonumber(rank) or 0
                        if rank < 0 then rank = 0 end
                        if rank > 5 then rank = 5 end
                        return rank, true
                    end
                end
            end
        end
    end
end

local function AddChefConfig(configs, configID)
    if type(configID) == "number" and configID > 0 then
        configs[configID] = true
    end
end

local function ChefRank()
    if chefKnown then
        return chefRank or 0, true
    end
    if C_Traits then
        local configs = {}
        if C_Traits.GetConfigIDBySystemID then
            local ok, configID = pcall(C_Traits.GetConfigIDBySystemID, 45)
            if ok then AddChefConfig(configs, configID) end
            if Enum and type(Enum.TraitSystem) == "table" then
                for _, systemID in pairs(Enum.TraitSystem) do
                    if type(systemID) == "number" then
                        local okSystem, found = pcall(C_Traits.GetConfigIDBySystemID, systemID)
                        if okSystem then AddChefConfig(configs, found) end
                    end
                end
            end
        end
        if C_Traits.GetConfigIDByTreeID then
            for treeID = 1187, 1189 do
                local ok, configID = pcall(C_Traits.GetConfigIDByTreeID, treeID)
                if ok then AddChefConfig(configs, configID) end
            end
        end
        for configID in pairs(configs) do
            local rank, known = ChefFromConfig(configID)
            if known then
                chefRank, chefKnown = rank, true
                return rank, true
            end
        end
    end
    local rank, known = ChefFromTalents()
    if known then
        chefRank, chefKnown = rank, true
        return rank, true
    end
    return 0, false
end

local function IsCooking()
    local api = C_TradeSkillUI
    if api and api.GetBaseProfessionInfo then
        local ok, info = pcall(api.GetBaseProfessionInfo)
        if ok and type(info) == "table" then
            if info.professionID == 185 or info.profession == 185 then return true end
            if type(info.professionName) == "string" then
                local name = info.professionName:lower()
                if name == "cooking" or name == "кулинария" then return true end
            end
        end
    end
    if GetTradeSkillLine then
        local ok, name = pcall(GetTradeSkillLine)
        if ok and type(name) == "string" then
            local lower = name:lower()
            if lower == "cooking" or lower == "кулинария" then return true end
        end
    end
    return false
end

local function RecipeYield(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeSchematic and recipeID) then return 1 end
    local ok, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
    if not ok or type(schematic) ~= "table" then return 1 end
    local low = tonumber(schematic.quantityMin) or tonumber(schematic.quantity) or 1
    local high = tonumber(schematic.quantityMax) or low
    if low < 1 then low = 1 end
    if high < low then high = low end
    return (low + high) / 2, schematic.outputItemID
end

local function QueueValue()
    local copper = 0
    local unknown = false
    local cooking = IsCooking()
    local extra = 0
    local rank, known = 0, false
    if cooking then
        rank, known = ChefRank()
        extra = (rank or 0) * 0.10
    end
    for i = math.max(planIndex or 1, 1), #plan do
        local step = plan[i]
        if step then
            local crafts = CraftableCount(step.id)
            if running and current and step.id == current.id and current.left then
                crafts = math.max((current.left or 0) - (current.done or 0), 0)
            end
            if crafts > 0 then
                local yield, itemID = RecipeYield(step.id)
                if not itemID then
                    itemID = RecipeOutput(step.id)
                end
                local price = itemID and VendorPays(itemID)
                if type(price) == "number" then
                    copper = copper + price * (crafts * yield + crafts * extra)
                else
                    unknown = true
                end
            end
        end
    end
    return copper, unknown, cooking, rank or 0, known
end

function RefreshMoney()
    if not bar or not bar.sellLines then return end
    local earn = 0
    local earnUnknown = false
    local rows = {}
    for key in pairs(DB().sell or {}) do
        local id = tonumber(key)
        if id then
            local have = ItemCount(id)
            if have > 0 then
                local each = VendorPays(id)
                local priced = type(each) == "number"
                rows[#rows + 1] = { id = id, have = have, value = priced and (each * have) or 0, priced = priced }
                if priced then
                    earn = earn + each * have
                else
                    earnUnknown = true
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.value == b.value then
            return a.id < b.id
        end
        return a.value > b.value
    end)
    local hidden = math.max(0, #rows - #bar.sellLines)
    for index, line in ipairs(bar.sellLines) do
        local row = rows[index]
        if row then
            local money = row.priced and MoneyText(row.value) or "?"
            line:SetText(ItemName(row.id) .. "  ×" .. row.have .. "  " .. money)
            line:Show()
        else
            line:SetText("")
            line:Hide()
        end
    end
    if #rows == 0 then
        bar.sellLines[1]:SetText(L("На продажу ничего не лежит.", "Nothing is waiting to be sold."))
        bar.sellLines[1]:Show()
    end
    if bar.sellHead then
        local head = L("На продажу", "For sale")
        if hidden > 0 then
            head = head .. "  +" .. hidden
        end
        bar.sellHead:SetText(head)
    end
    local earnText = MoneyText(earn)
    if earnUnknown then
        earnText = earnText .. " + ?"
    end
    bar.earn:SetText(L("Заработаю: ", "I'll earn: ") .. earnText)
    local cost = 0
    local unknown = false
    local prices = DB().buyPrice or {}
    for key, amount in pairs(DB().restock or {}) do
        local id = tonumber(key)
        local want = tonumber(amount) or 0
        if id and want > 0 then
            local need = want - ItemCount(id)
            if need > 0 then
                local price = prices[id] or prices[tostring(id)]
                if type(price) == "number" and price > 0 then
                    cost = cost + price * need
                else
                    unknown = true
                end
            end
        end
    end
    local costText = MoneyText(cost)
    if unknown then
        costText = costText .. " + ?"
    end
    bar.spend:SetText(L("Закуплю: ", "I'll buy: ") .. costText)
    local queued, queueUnknown, cooking, rank, chefRead = QueueValue()
    local forecastText = MoneyText(earn + queued)
    if earnUnknown or queueUnknown then
        forecastText = forecastText .. " + ?"
    end
    if cooking then
        if chefRead then
            forecastText = forecastText .. "  шеф " .. rank
        else
            forecastText = forecastText .. "  шеф ?"
        end
    end
    if bar.forecast then
        bar.forecast:SetText(L("Прогноз: ", "Forecast: ") .. forecastText)
    end
end

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    return GetItemIcon and GetItemIcon(itemID)
end

local function SortedIDs(map)
    local ids = {}
    for itemID in pairs(map) do
        ids[#ids + 1] = tonumber(itemID) or itemID
    end
    table.sort(ids, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return ids
end

local function RefreshLists()
    if not listFrame or not listFrame:IsShown() or listFrame.mode == "economy" then return end
    local db = DB()
    local function Fill(kind, map)
        local box = listFrame.columns[kind]
        local ids = SortedIDs(map)
        box.ids = ids
        local visible = #box.rows
        local maxOff = math.max(0, #ids - visible)
        local offset = box.offset or 0
        if offset > maxOff then offset = maxOff end
        if offset < 0 then offset = 0 end
        box.offset = offset
        for index, row in ipairs(box.rows) do
            local itemID = ids[index + offset]
            row.itemID = itemID
            if itemID then
                row:SetFrameStrata("TOOLTIP")
                row:SetFrameLevel(box:GetFrameLevel() + 30 + index)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -46 - ((index - 1) * 26))
                row:Show()
                row.icon:SetTexture(ItemIcon(itemID))
                row.name:SetText(index + offset .. ". " .. ItemName(itemID))
                if row.amount and not row.amount:HasFocus() then
                    row.amount:SetText(tostring(db.restock[itemID] or db.restock[tostring(itemID)] or 1))
                end
            else
                row:Hide()
            end
        end
        if box.title then
            local caption = L("Продавать", "Sell")
            if kind == "craft" then
                caption = L("Производить", "Produce")
            elseif kind == "restock" then
                caption = L("Закупать", "Buy")
            end
            box.title:SetText(caption .. " (" .. #ids .. ")")
        end
    end
    Fill("craft", db.craft)
    Fill("restock", db.restock)
    Fill("sell", db.sell)
    if bar and bar:IsShown() then
        pcall(RefreshMoney)
    end
end

local function ItemIDFromCursorValue(value)
    if type(value) == "number" and value > 0 then
        return value
    end
    if type(value) ~= "string" or value == "" then
        return
    end
    local fromLink = tonumber(value) or tonumber(value:match("item:(%d+)"))
    if fromLink then
        return fromLink
    end
    local _, link = GetItemInfo(value)
    if type(link) == "string" then
        local id = tonumber(link:match("item:(%d+)"))
        if id then return id end
    end
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then
        return
    end
    for bag = 0, 5 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local name = GetItemInfo(info.itemID)
                if name == value then
                    return info.itemID
                end
            end
        end
    end
end

-- Same read as Restocker's addCursorItem: the item link or name is the third return.
local function CursorItemID()
    if not GetCursorInfo then return end
    local infoType, skipped, info2 = GetCursorInfo()
    if infoType ~= "item" then return end
    return ItemIDFromCursorValue(info2) or ItemIDFromCursorValue(skipped)
end

local function AddDrop(kind)
    local itemID = CursorItemID()
    if not itemID then return end
    local db = DB()
    if kind == "craft" then
        db.craft[itemID] = true
    elseif kind == "restock" then
        if db.restock[itemID] == nil and db.restock[tostring(itemID)] == nil then
            db.restock[itemID] = 1
        end
    else
        db.sell[itemID] = true
    end
    if listFrame and listFrame.columns and listFrame.columns[kind] then
        listFrame.columns[kind].offset = 0
    end
    ClearCursor()
    RefreshLists()
    Print(ItemName(itemID))
end

local function MakeDropRow(parent, kind)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(210, 24)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0.16, 0.12, 0.09, 1)
    row.icon = row:CreateTexture(nil, "OVERLAY")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 2, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetWidth(kind == "restock" and 110 or 150)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    if kind == "restock" then
        row.amount = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.amount:SetSize(36, 18)
        row.amount:SetPoint("RIGHT", -22, 0)
        row.amount:SetAutoFocus(false)
        row.amount:SetNumeric(true)
        row.amount:SetMaxLetters(4)
        row.amount:SetScript("OnEnterPressed", function(self)
            local n = tonumber(self:GetText())
            if row.itemID and n and n >= 0 then
                DB().restock[row.itemID] = n
                DB().restock[tostring(row.itemID)] = nil
            end
            self:ClearFocus()
        end)
        row.amount:SetScript("OnEditFocusLost", function(self)
            local n = tonumber(self:GetText())
            if row.itemID and n and n >= 0 then
                DB().restock[row.itemID] = n
                DB().restock[tostring(row.itemID)] = nil
            end
        end)
        row.amount:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        row.amount:SetScript("OnReceiveDrag", function()
            AddDrop(kind)
        end)
        row.amount:HookScript("OnMouseUp", function()
            AddDrop(kind)
        end)
    end
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnReceiveDrag", function()
        AddDrop(kind)
    end)
    row:SetScript("OnClick", function()
        AddDrop(kind)
    end)
    row:Hide()
    local remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    remove:SetSize(18, 18)
    remove:SetPoint("RIGHT", 0, 0)
    remove:SetText("x")
    remove:SetScript("OnClick", function()
        if not row.itemID then return end
        local db = DB()
        if kind == "craft" then
            db.craft[row.itemID] = nil
            db.craft[tostring(row.itemID)] = nil
        elseif kind == "restock" then
            db.restock[row.itemID] = nil
            db.restock[tostring(row.itemID)] = nil
        else
            db.sell[row.itemID] = nil
            db.sell[tostring(row.itemID)] = nil
        end
        RefreshLists()
    end)
    return row
end

local function MakeColumn(parent, kind, title, anchor)
    local box = CreateFrame("Button", nil, parent, "BackdropTemplate")
    box:RegisterForClicks("LeftButtonUp")
    box:SetSize(244, 280)
    if anchor == "TOPLEFT" then
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -36)
    elseif anchor == "TOP" then
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", 268, -36)
    else
        box:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, -36)
    end
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    box:SetBackdropColor(0.08, 0.06, 0.05, 0.9)
    local head = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 8, -8)
    head:SetText(title)
    box.title = head
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 8, -26)
    hint:SetText(L("Перетащи предмет сюда", "Drop an item here"))
    box:EnableMouse(true)
    box:EnableMouseWheel(true)
    box:SetScript("OnReceiveDrag", function()
        AddDrop(kind)
    end)
    box:SetScript("OnClick", function()
        AddDrop(kind)
    end)
    box:HookScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            AddDrop(kind)
        end
    end)
    box:SetScript("OnMouseWheel", function(self, delta)
        self.offset = (self.offset or 0) - delta
        RefreshLists()
    end)
    box.rows = {}
    for i = 1, 8 do
        local row = MakeDropRow(parent, kind)
        row:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -46 - ((i - 1) * 26))
        row:SetFrameStrata("TOOLTIP")
        row:SetFrameLevel(200)
        box.rows[i] = row
    end
    listRows[kind] = box.rows
    return box
end

local function CountKeys(map)
    local count = 0
    if type(map) == "table" then
        for _ in pairs(map) do
            count = count + 1
        end
    end
    return count
end

local function DumpOne(title, map, withAmount)
    Print(title .. " " .. CountKeys(map))
    if type(map) ~= "table" then
        Print("  " .. L("нет таблицы", "no table"))
        return
    end
    local count = 0
    for itemID, amount in pairs(map) do
        count = count + 1
        local id = tonumber(itemID) or itemID
        local ok, name = pcall(ItemName, id)
        if not ok then
            name = "?"
        end
        if withAmount then
            Print("  " .. count .. ". " .. tostring(itemID) .. "  " .. name .. "  x" .. tostring(amount))
        else
            Print("  " .. count .. ". " .. tostring(itemID) .. "  " .. name)
        end
    end
    if count == 0 then
        Print("  " .. L("пусто", "empty"))
    end
end

local function DumpLists()
    local db = DB()
    DumpOne(L("Производить:", "Produce:"), db.craft, false)
    DumpOne(L("Закупать:", "Buy:"), db.restock, true)
    DumpOne(L("Продавать:", "Sell:"), db.sell, false)
end

local function ClearLists()
    local db = DB()
    wipe(db.craft)
    wipe(db.restock)
    wipe(db.sell)
    if listFrame and listFrame.columns then
        if listFrame.columns.craft then listFrame.columns.craft.offset = 0 end
        if listFrame.columns.restock then listFrame.columns.restock.offset = 0 end
        if listFrame.columns.sell then listFrame.columns.sell.offset = 0 end
    end
    RefreshLists()
    Print(L("Списки очищены.", "Lists cleared."))
end

local function AuctionUnit(itemID)
    if not (Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID) then
        return
    end
    local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "Holop", itemID)
    if ok and type(price) == "number" and price > 0 then
        return price
    end
end

local function VendorUnit(itemID)
    local prices = DB().buyPrice or {}
    local saved = prices[itemID] or prices[tostring(itemID)]
    if type(saved) == "number" and saved > 0 then
        return saved
    end
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetVendorPriceByItemID then
        local ok, price = pcall(Auctionator.API.v1.GetVendorPriceByItemID, "Holop", itemID)
        if ok and type(price) == "number" and price > 0 then
            return price
        end
    end
end

local function RememberRecipes()
    local api = C_TradeSkillUI
    if not (api and api.GetAllRecipeIDs and api.GetRecipeInfo and api.GetRecipeSchematic) then return end
    if not ProfessionOpen() then return end
    local ok, ids = pcall(api.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return end
    local profession = 0
    if api.GetBaseProfessionInfo then
        local infoOk, info = pcall(api.GetBaseProfessionInfo)
        if infoOk and type(info) == "table" then
            profession = info.professionID or info.profession or 0
        end
    end
    local book = DB().recipeBook
    for _, recipeID in ipairs(ids) do
        local infoOk, info = pcall(api.GetRecipeInfo, recipeID)
        local schematicOk, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
        if infoOk and info and info.learned and schematicOk and type(schematic) == "table" and schematic.outputItemID then
            local reagents = {}
            for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                local required = slot.reagentType == nil or slot.reagentType == 1
                local first = slot.reagents and slot.reagents[1]
                local qty = tonumber(slot.quantityRequired) or 0
                if required and first and first.itemID and qty > 0 then
                    reagents[#reagents + 1] = { id = first.itemID, qty = qty }
                end
            end
            if #reagents > 0 then
                local low = tonumber(schematic.quantityMin) or tonumber(schematic.quantity) or 1
                local high = tonumber(schematic.quantityMax) or low
                if low < 1 then low = 1 end
                if high < low then high = low end
                book[recipeID] = {
                    output = schematic.outputItemID,
                    name = info.name,
                    yield = (low + high) / 2,
                    profession = profession,
                    reagents = reagents,
                }
            end
        end
    end
end

local function RecipeForOutput(itemID)
    local found
    for _, recipe in pairs(DB().recipeBook or {}) do
        if type(recipe) == "table" and tonumber(recipe.output) == itemID then
            if not found or (tonumber(recipe.yield) or 0) > (tonumber(found.yield) or 0) then
                found = recipe
            end
        end
    end
    return found
end

local function RentAt(revenue, others, price, qty)
    local cost = others + price * qty
    if cost <= 0 then
        return revenue > 0 and 100 or 0
    end
    return (revenue - cost) / cost
end

-- Highest whole copper price at which profitability is still above minRent.
-- Profitability is profit divided by what the craft costs.
local function MaxPriceAbove(revenue, others, qty, minRent)
    local denom = qty * (1 + minRent)
    if denom <= 0 then return end
    local price = math.floor((revenue - others * (1 + minRent)) / denom - 0.0000001)
    if price < 0 then return end
    while price > 0 and RentAt(revenue, others, price, qty) <= minRent do
        price = price - 1
    end
    if RentAt(revenue, others, price, qty) <= minRent then return end
    return price
end

local function EconomyEntries()
    local entries = {}
    local function Push(entry)
        entries[#entries + 1] = entry
    end
    local ids = SortedIDs(DB().craft or {})
    if #ids == 0 then
        Push({ kind = "note", title = L("В «Производить» пусто. Перетащи туда готовую вещь.", "Produce is empty. Drop a finished item there.") })
        return entries
    end
    for _, itemID in ipairs(ids) do
        local recipe = RecipeForOutput(itemID)
        local craftName = ItemName(itemID)
        if not recipe then
            Push({
                kind = "note",
                itemID = itemID,
                title = craftName,
                detail = L("Рецепт ещё не запомнен. Открой профессию.", "Recipe is not saved yet. Open the profession."),
            })
        else
            local yield = tonumber(recipe.yield) or 1
            local chefNote = ""
            if tonumber(recipe.profession) == 185 then
                local rank, known = ChefRank()
                if known then
                    yield = yield + rank * 0.10
                    chefNote = L("шеф ", "chef ") .. rank .. "  "
                else
                    chefNote = L("шеф ?  ", "chef ?  ")
                end
            end
            local sell = VendorPays(itemID)
            if type(sell) ~= "number" then
                Push({
                    kind = "note",
                    itemID = itemID,
                    title = craftName,
                    detail = L("Цена торговца ещё не известна.", "Vendor price is not known yet."),
                })
            else
                local revenue = sell * yield
                local yieldText = yield == math.floor(yield) and tostring(yield) or string.format("%.1f", yield)
                Push({
                    kind = "craft",
                    itemID = itemID,
                    title = craftName,
                    detail = chefNote .. L("выход ", "yield ") .. yieldText .. "  " .. L("торговцу ", "to the vendor ") .. MoneyText(revenue),
                })
                local vendorCost = 0
                local ah = {}
                for _, reagent in ipairs(recipe.reagents or {}) do
                    local id = tonumber(reagent.id)
                    local qty = tonumber(reagent.qty) or 0
                    if id and qty > 0 then
                        local vendor = VendorUnit(id)
                        if vendor then
                            vendorCost = vendorCost + vendor * qty
                        else
                            ah[#ah + 1] = { id = id, qty = qty, auction = AuctionUnit(id) }
                        end
                    end
                end
                if #ah == 0 then
                    local profit = revenue - vendorCost
                    local detail
                    if profit > 0 then
                        detail = L("Аукцион не нужен. Профит ", "No auction buy. Profit ") .. MoneyText(profit)
                    else
                        detail = L("Убыток ", "Loss ") .. MoneyText(-profit)
                    end
                    Push({ kind = "note", title = craftName, detail = detail })
                else
                    for _, row in ipairs(ah) do
                        local others = vendorCost
                        local othersKnown = true
                        for _, other in ipairs(ah) do
                            if other ~= row then
                                if other.auction then
                                    others = others + other.auction * other.qty
                                else
                                    othersKnown = false
                                end
                            end
                        end
                        local entry = {
                            kind = "buy",
                            itemID = row.id,
                            title = ItemName(row.id),
                            detail = "×" .. row.qty .. "  " .. L("для ", "for ") .. craftName,
                            auction = row.auction,
                        }
                        if othersKnown then
                            entry.ready = true
                            entry.green = MaxPriceAbove(revenue, others, row.qty, 0.20)
                            entry.yellow = MaxPriceAbove(revenue, others, row.qty, 0)
                            if entry.yellow then
                                entry.redFrom = entry.yellow + 1
                            end
                            if row.auction then
                                if entry.green and row.auction <= entry.green then
                                    entry.zone = "green"
                                elseif entry.yellow and row.auction <= entry.yellow then
                                    entry.zone = "yellow"
                                else
                                    entry.zone = "red"
                                end
                            end
                        else
                            entry.detail = entry.detail .. L("  · цена остальных ещё неизвестна", "  · other prices are still unknown")
                        end
                        Push(entry)
                    end
                end
            end
        end
    end
    return entries
end

local function FillZone(box, caption, priceText)
    box.caption:SetText(caption)
    box.price:SetText(priceText)
    box:Show()
end

local function RefreshEconomy()
    if not listFrame or not listFrame.economy or listFrame.mode ~= "economy" then return end
    local entries = EconomyEntries()
    local view = listFrame.economy.rows
    local offset = listFrame.economyOffset or 0
    local maxOff = math.max(0, #entries - #view)
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end
    listFrame.economyOffset = offset
    for index, row in ipairs(view) do
        local entry = entries[index + offset]
        if not entry then
            row:Hide()
        else
            row.itemID = entry.itemID
            row:Show()
            local icon = entry.itemID and ItemIcon(entry.itemID)
            if icon then
                row.icon:SetTexture(icon)
                row.icon:Show()
            else
                row.icon:Hide()
            end
            row.title:SetText(entry.title or "")
            local detail = entry.detail or ""
            if entry.auction then
                detail = detail .. "   " .. L("сейчас ", "now ") .. MoneyText(entry.auction)
            end
            row.detail:SetText(detail)
            if entry.zone == "green" then
                row.detail:SetTextColor(0.45, 0.95, 0.45)
            elseif entry.zone == "yellow" then
                row.detail:SetTextColor(1, 0.85, 0.3)
            elseif entry.zone == "red" then
                row.detail:SetTextColor(1, 0.4, 0.32)
            else
                row.detail:SetTextColor(0.8, 0.75, 0.6)
            end
            if entry.kind == "buy" and (entry.green or entry.yellow or entry.redFrom or not entry.zone) then
                local greenText = entry.green and (L("до ", "up to ") .. MoneyText(entry.green)) or L("нет", "none")
                local yellowText = entry.yellow and (L("до ", "up to ") .. MoneyText(entry.yellow)) or L("нет", "none")
                local redText = entry.redFrom and (L("от ", "from ") .. MoneyText(entry.redFrom)) or L("любая цена", "any price")
                if not entry.green and not entry.yellow and not entry.redFrom then
                    if entry.ready then
                        greenText = L("нет", "none")
                        yellowText = L("нет", "none")
                        redText = L("не покупать", "do not buy")
                    else
                        greenText = "—"
                        yellowText = "—"
                        redText = L("жду цену", "need a price")
                    end
                end
                FillZone(row.green, L("выше 20%", "above 20%"), greenText)
                FillZone(row.yellow, "0–20%", yellowText)
                FillZone(row.red, L("убыток", "loss"), redText)
                if entry.zone == "green" then
                    row.bar:SetColorTexture(0.2, 0.65, 0.25, 1)
                elseif entry.zone == "yellow" then
                    row.bar:SetColorTexture(0.75, 0.6, 0.1, 1)
                elseif entry.zone == "red" then
                    row.bar:SetColorTexture(0.7, 0.15, 0.12, 1)
                else
                    row.bar:SetColorTexture(0.35, 0.28, 0.16, 1)
                end
                row.now:Hide()
            else
                row.green:Hide()
                row.yellow:Hide()
                row.red:Hide()
                row.now:Hide()
                row.bar:SetColorTexture(0.55, 0.43, 0.25, 1)
            end
        end
    end
end

local function ShowListsMode(mode)
    if not listFrame then return end
    listFrame.mode = mode
    local economy = mode == "economy"
    listFrame:SetHeight(economy and 560 or 380)
    listFrame:SetWidth(economy and 860 or 780)
    if listFrame.columns then
        for _, box in pairs(listFrame.columns) do
            box:SetShown(not economy)
        end
    end
    if economy then
        for _, rows in pairs(listRows) do
            for _, row in ipairs(rows) do
                row:Hide()
            end
        end
    end
    if listFrame.economy then
        listFrame.economy:SetShown(economy)
    end
    if listFrame.economyNote then
        listFrame.economyNote:SetShown(economy)
    end
    if listFrame.dump then
        listFrame.dump:SetShown(not economy)
    end
    if listFrame.tabLists then
        listFrame.tabLists:SetText((economy and "" or "|cffffd100") .. L("Списки", "Lists") .. (economy and "" or "|r"))
        listFrame.tabEconomy:SetText((economy and "|cffffd100" or "") .. L("Экономика", "Economy") .. (economy and "|r" or ""))
    end
    if economy then
        RememberRecipes()
        RefreshEconomy()
    else
        RefreshLists()
    end
end

local function ToggleLists()
    if not listFrame then return end
    if listFrame:IsShown() then
        listFrame:Hide()
    else
        listFrame:Show()
        listFrame:Raise()
        ShowListsMode(listFrame.mode or "lists")
    end
end

local function EnsureLists()
    if listFrame then return end
    DB()
    listFrame = CreateFrame("Frame", "HolopLists", UIParent, "BackdropTemplate")
    listFrame:SetSize(780, 380)
    listFrame:SetPoint("CENTER")
    listFrame:SetFrameStrata("TOOLTIP")
    listFrame:SetToplevel(true)
    local heldID
    local wasDown = false
    listFrame:SetScript("OnUpdate", function(self)
        if not self:IsShown() or not self.columns or self.mode == "economy" then return end
        local down = IsMouseButtonDown("LeftButton")
        local id = CursorItemID()
        if id then
            heldID = id
            self:Raise()
        end
        if wasDown and not down then
            if heldID then
                local kind
                if self.columns.craft and self.columns.craft:IsMouseOver() then
                    kind = "craft"
                elseif self.columns.sell and self.columns.sell:IsMouseOver() then
                    kind = "sell"
                elseif self.columns.restock and self.columns.restock:IsMouseOver() then
                    kind = "restock"
                end
                if kind then
                    local db = DB()
                    if kind == "craft" then
                        db.craft[heldID] = true
                    elseif kind == "restock" then
                        if db.restock[heldID] == nil and db.restock[tostring(heldID)] == nil then
                            db.restock[heldID] = 1
                        end
                    else
                        db.sell[heldID] = true
                    end
                    if self.columns[kind] then
                        self.columns[kind].offset = 0
                    end
                    if ClearCursor then ClearCursor() end
                    RefreshLists()
                end
            end
            heldID = nil
        end
        wasDown = down and true or false
    end)
    listFrame.columns = {}
    listFrame:SetMovable(true)
    listFrame:EnableMouse(true)
    listFrame:RegisterForDrag("LeftButton")
    listFrame:SetScript("OnDragStart", listFrame.StartMoving)
    listFrame:SetScript("OnDragStop", listFrame.StopMovingOrSizing)
    listFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listFrame:SetBackdropColor(0.09, 0.07, 0.05, 0.96)
    listFrame:SetBackdropBorderColor(0.55, 0.43, 0.25, 1)
    listFrame:Hide()
    listFrame.mode = "lists"
    tinsert(UISpecialFrames, "HolopLists")
    local title = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText(L("Холоп", "Holop"))
    local close = CreateFrame("Button", nil, listFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local tabEconomy = CreateFrame("Button", nil, listFrame, "UIPanelButtonTemplate")
    tabEconomy:SetSize(120, 22)
    tabEconomy:SetPoint("TOPRIGHT", -36, -8)
    tabEconomy:SetFrameLevel(300)
    tabEconomy:SetText(L("Экономика", "Economy"))
    tabEconomy:SetScript("OnClick", function()
        ShowListsMode("economy")
    end)
    listFrame.tabEconomy = tabEconomy
    local tabLists = CreateFrame("Button", nil, listFrame, "UIPanelButtonTemplate")
    tabLists:SetSize(100, 22)
    tabLists:SetPoint("RIGHT", tabEconomy, "LEFT", -6, 0)
    tabLists:SetFrameLevel(300)
    tabLists:SetText("|cffffd100" .. L("Списки", "Lists") .. "|r")
    tabLists:SetScript("OnClick", function()
        ShowListsMode("lists")
    end)
    listFrame.tabLists = tabLists
    local economy = CreateFrame("Frame", nil, listFrame)
    economy:SetPoint("TOPLEFT", 16, -40)
    economy:SetPoint("BOTTOMRIGHT", -16, 40)
    economy:EnableMouseWheel(true)
    economy:SetScript("OnMouseWheel", function(_, delta)
        listFrame.economyOffset = (listFrame.economyOffset or 0) - delta
        RefreshEconomy()
    end)
    local function ZoneBox(parent, r, g, b)
        local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        box:SetSize(168, 40)
        box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        box:SetBackdropColor(r, g, b, 0.95)
        box.caption = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        box.caption:SetPoint("TOP", 0, -4)
        box.caption:SetTextColor(1, 1, 1)
        box.price = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        box.price:SetPoint("BOTTOM", 0, 4)
        box.price:SetTextColor(1, 0.95, 0.8)
        return box
    end
    economy.rows = {}
    for i = 1, 8 do
        local row = CreateFrame("Frame", nil, economy)
        row:SetSize(820, 56)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 58))
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(0.08, 0.06, 0.05, 0.85)
        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT", 0, 0)
        row.bar:SetPoint("BOTTOMLEFT", 0, 0)
        row.bar:SetWidth(6)
        row.bar:SetColorTexture(0.55, 0.43, 0.25, 1)
        row.icon = row:CreateTexture(nil, "OVERLAY")
        row.icon:SetSize(36, 36)
        row.icon:SetPoint("LEFT", 12, 0)
        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.title:SetPoint("TOPLEFT", 56, -6)
        row.title:SetWidth(210)
        row.title:SetJustifyH("LEFT")
        row.title:SetWordWrap(false)
        row.title:SetTextColor(0.95, 0.9, 0.75)
        row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.detail:SetPoint("BOTTOMLEFT", 56, 8)
        row.detail:SetWidth(210)
        row.detail:SetJustifyH("LEFT")
        row.detail:SetWordWrap(false)
        row.now = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.now:SetPoint("TOPLEFT", 56, -22)
        row.now:SetWidth(210)
        row.now:SetJustifyH("LEFT")
        row.green = ZoneBox(row, 0.12, 0.42, 0.16)
        row.green:SetPoint("LEFT", 280, 0)
        row.yellow = ZoneBox(row, 0.48, 0.38, 0.08)
        row.yellow:SetPoint("LEFT", row.green, "RIGHT", 6, 0)
        row.red = ZoneBox(row, 0.48, 0.12, 0.1)
        row.red:SetPoint("LEFT", row.yellow, "RIGHT", 6, 0)
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if not (self.itemID and GameTooltip and GameTooltip.SetItemByID) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            pcall(GameTooltip.SetItemByID, GameTooltip, self.itemID)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
        row:Hide()
        economy.rows[i] = row
    end
    economy:Hide()
    listFrame.economy = economy
    local economyNote = listFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    economyNote:SetPoint("BOTTOMLEFT", 14, 14)
    economyNote:SetPoint("RIGHT", listFrame, "RIGHT", -14, 0)
    economyNote:SetJustifyH("LEFT")
    economyNote:SetWordWrap(false)
    economyNote:SetText(L("Зелёная — выше 20%. Жёлтая — от 0 до 20%. Красная — 0 и ниже. Шеф-повар уже в выходе. «Сейчас» — Auctionator.", "Green is above 20%. Yellow is 0 to 20%. Red is 0 or less. Chef is already in the yield. “Now” is Auctionator."))
    economyNote:Hide()
    listFrame.economyNote = economyNote
    listFrame.columns.craft = MakeColumn(listFrame, "craft", L("Производить", "Produce"), "TOPLEFT")
    listFrame.columns.restock = MakeColumn(listFrame, "restock", L("Закупать", "Buy"), "TOP")
    listFrame.columns.sell = MakeColumn(listFrame, "sell", L("Продавать", "Sell"), "TOPRIGHT")
    local dump = CreateFrame("Button", nil, listFrame, "UIPanelButtonTemplate")
    dump:SetSize(140, 22)
    dump:SetPoint("BOTTOMLEFT", 14, 12)
    dump:SetFrameLevel(300)
    dump:SetText(L("В чат", "To chat"))
    listFrame.dump = dump
    dump:SetScript("OnClick", DumpLists)
end

local function LinkItemID(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function MerchantItem(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        return C_MerchantFrame.GetItemInfo(index)
    end
end

local function RestockAmount(itemID)
    local db = DB().restock
    local n = db[itemID]
    if n == nil then n = db[tostring(itemID)] end
    return tonumber(n)
end

local function OnSellList(itemID)
    local db = DB().sell
    return db[itemID] or db[tostring(itemID)]
end

local function ContainerSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    end
    return 0
end

local function ContainerItemID(bag, slot)
    if not (C_Container and C_Container.GetContainerItemInfo) then return end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if type(info) == "table" then
        return info.itemID, info.isLocked
    end
end

local MERCHANT_GAP = 0.4
local merchantJob
local merchantTicker
local merchantPlanned

local function StackSize(itemID, merchantStack)
    if C_Item and C_Item.GetItemMaxStackSizeByID then
        local ok, size = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
        if ok and type(size) == "number" and size > 0 then
            return size
        end
    end
    if type(merchantStack) == "number" and merchantStack > 1 then
        return merchantStack
    end
    return 20
end

local function BuyChunk(itemID, sale)
    local stack = StackSize(itemID, sale)
    local chunk = math.floor(stack / sale) * sale
    if chunk < sale then
        chunk = sale
    end
    return chunk
end

local function Remember(itemID)
    local db = DB()
    db.names = db.names or {}
    local name = ItemName(itemID)
    if type(name) == "string" and not name:match("^#%d+$") then
        db.names[tostring(itemID)] = name
    end
end

local function MerchantLink(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemLink then
        local ok, link = pcall(C_MerchantFrame.GetItemLink, index)
        if ok and type(link) == "string" then
            return link
        end
    end
    if GetMerchantItemLink then
        return GetMerchantItemLink(index)
    end
end

local function MerchantItemID(index, info, link)
    link = link or MerchantLink(index)
    if link and C_Item and C_Item.GetItemInfoInstant then
        local ok, itemID = pcall(C_Item.GetItemInfoInstant, link)
        if ok and type(itemID) == "number" then
            return itemID
        end
    end
    local fromLink = LinkItemID(link)
    if fromLink then
        return fromLink
    end
    if info and info.name then
        local names = DB().names or {}
        for key, saved in pairs(names) do
            if saved == info.name then
                return tonumber(key)
            end
        end
        for key in pairs(DB().restock) do
            local id = tonumber(key)
            if id and ItemName(id) == info.name then
                return id
            end
        end
    end
end

local function BuyFromMerchant(index, count)
    if count < 1 then return false end
    if BuyMerchantItem then
        local ok, err = pcall(BuyMerchantItem, index, count)
        if ok then return true end
        Print("BuyMerchantItem " .. index .. " x" .. count .. " " .. tostring(err))
    end
    if C_MerchantFrame and C_MerchantFrame.BuyItem then
        local ok, err = pcall(C_MerchantFrame.BuyItem, index, count)
        if not ok then
            Print("BuyItem " .. index .. " x" .. count .. " " .. tostring(err))
        end
        return ok
    end
    Print("функции покупки нет")
    return false
end

local debugAt = 0

local function DebugMerchant()
    if GetTime() - debugAt < 2 then return end
    debugAt = GetTime()
    local num = GetMerchantNumItems and GetMerchantNumItems() or 0
    Print("отладка: позиций " .. tostring(num) .. ", BuyMerchantItem=" .. tostring(type(BuyMerchantItem)) .. ", BuyItem=" .. tostring(C_MerchantFrame and type(C_MerchantFrame.BuyItem)))
    local listed = 0
    for key, amount in pairs(DB().restock) do
        listed = listed + 1
        local id = tonumber(key) or key
        local have = ItemCount(id)
        Print("список " .. tostring(id) .. " " .. ItemName(id) .. " хочу " .. tostring(amount) .. " есть " .. tostring(have))
    end
    if listed == 0 then
        Print("список закупки пуст")
    end
    for index = 1, math.min(num, 10) do
        local info = MerchantItem(index)
        local link = MerchantLink(index)
        local itemID = MerchantItemID(index, info, link)
        local name = info and info.name or "?"
        Print(tostring(index) .. " " .. tostring(name)
            .. " id=" .. tostring(itemID)
            .. " пачка=" .. tostring(info and info.stackCount)
            .. " запас=" .. tostring(info and info.numAvailable)
            .. " можно=" .. tostring(info and info.isPurchasable)
            .. " цена=" .. tostring(info and info.price)
            .. " ссылка=" .. (link and "да" or "нет"))
    end
end

local function MerchantIsOpen()
    if MerchantFrame and MerchantFrame.IsShown then
        local ok, shown = pcall(MerchantFrame.IsShown, MerchantFrame)
        if ok then return shown and true or false end
    end
    local num = GetMerchantNumItems and GetMerchantNumItems() or 0
    return type(num) == "number" and num > 0
end

local function StopMerchant(silent)
    if merchantTicker then
        merchantTicker:Cancel()
        merchantTicker = nil
    end
    local job = merchantJob
    merchantJob = nil
    if not job then return end
    if not silent then
        if job.missed and #job.missed > 0 then
            Print(L("У торговца нет: ", "Not on this vendor: ") .. table.concat(job.missed, ", "))
        elseif job.sold > 0 or job.bought > 0 then
            Print(L("Продал " .. job.sold .. ", докупил " .. job.bought .. ".", "Sold " .. job.sold .. ", bought " .. job.bought .. "."))
        end
    end
    pcall(RefreshMoney)
end

local function NextSell(job)
    local use = C_Container and C_Container.UseContainerItem
    if not use then return false end
    for bag = 0, 5 do
        for slot = 1, ContainerSlots(bag) do
            local itemID, locked = ContainerItemID(bag, slot)
            local key = bag .. ":" .. slot
            if itemID and not locked and OnSellList(itemID) and job.touched[key] ~= itemID then
                if pcall(use, bag, slot) then
                    job.touched[key] = itemID
                    job.sold = job.sold + 1
                end
                return true
            end
        end
    end
    return false
end

local function BuildBuyPlan()
    local num = GetMerchantNumItems and GetMerchantNumItems() or 0
    local wanted = {}
    for key, amount in pairs(DB().restock or {}) do
        local id = tonumber(key)
        local n = tonumber(amount)
        if id and n and n > 0 then
            wanted[id] = n
        end
    end
    local plans = {}
    for index = 1, num do
        local info = MerchantItem(index)
        local itemID = MerchantItemID(index, info)
        if itemID and info and type(info.price) == "number" and info.price > 0 then
            local sale = info.stackCount
            if type(sale) ~= "number" or sale < 1 then sale = 1 end
            DB().buyPrice = DB().buyPrice or {}
            DB().buyPrice[itemID] = math.floor(info.price / sale)
        end
        local want = itemID and wanted[itemID]
        if itemID and want and want > 0 and info and info.isPurchasable ~= false then
            local currencyOnly = (info.hasExtendedCost or info.extendedCost) and (not info.price or info.price == 0)
            local have = ItemCount(itemID)
            local need = want - have
            if not currencyOnly and need > 0 then
                local sale = info.stackCount
                if type(sale) ~= "number" or sale < 1 then sale = 1 end
                plans[#plans + 1] = {
                    index = index,
                    sale = sale,
                    chunk = BuyChunk(itemID, sale),
                    left = math.ceil(need / sale) * sale,
                    name = ItemName(itemID),
                }
            end
            wanted[itemID] = nil
        end
    end
    local missed = {}
    for itemID in pairs(wanted) do
        missed[#missed + 1] = ItemName(itemID)
    end
    return plans, missed
end

local function StepMerchant()
    local job = merchantJob
    if not job then return end
    if not MerchantIsOpen() then
        merchantPlanned = false
        StopMerchant(true)
        return
    end
    if job.phase == "sell" then
        if NextSell(job) then return end
        job.phase = "settle"
        job.settle = 3
        return
    end
    if job.phase == "settle" then
        job.settle = job.settle - 1
        if job.settle > 0 then return end
        job.plans, job.missed = BuildBuyPlan()
        job.planIndex = 1
        job.phase = "buy"
    end
    local plan = job.plans and job.plans[job.planIndex]
    if not plan then
        StopMerchant(false)
        return
    end
    if plan.left <= 0 then
        if plan.ordered and plan.ordered > 0 then
            Print(plan.name .. " +" .. plan.ordered)
        end
        job.planIndex = job.planIndex + 1
        return
    end
    local batch = math.min(plan.left, plan.chunk or plan.sale)
    if BuyFromMerchant(plan.index, batch) then
        plan.fails = 0
        plan.left = plan.left - batch
        plan.ordered = (plan.ordered or 0) + batch
        job.bought = job.bought + batch
    else
        plan.fails = (plan.fails or 0) + 1
        if plan.fails >= 3 then
            Print(plan.name .. " " .. L("не купилось", "was not bought"))
            plan.left = 0
        end
    end
end

local function StartMerchantWork()
    if merchantJob or merchantPlanned then return end
    local num = GetMerchantNumItems and GetMerchantNumItems() or 0
    if type(num) ~= "number" or num < 1 then return end
    merchantPlanned = true
    merchantJob = { phase = "sell", touched = {}, sold = 0, bought = 0 }
    merchantTicker = C_Timer.NewTicker(MERCHANT_GAP, StepMerchant)
    StepMerchant()
end

local function EnsureBar()
    if bar or not ProfessionsFrame then return end
    bar = CreateFrame("Frame", "HolopBar", ProfessionsFrame, "BackdropTemplate")
    bar:SetSize(380, 400)
    bar:SetClampedToScreen(true)
    bar:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 56, -8)
    bar:SetFrameStrata("MEDIUM")
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bar:SetBackdropColor(0.09, 0.07, 0.05, 0.94)
    bar:SetBackdropBorderColor(0.55, 0.43, 0.25, 1)

    local portrait = bar:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(32, 32)
    portrait:SetPoint("TOPLEFT", 14, -14)
    portrait:SetTexture(FACE)

    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 10, -1)
    title:SetText(L("Холоп", "Holop"))
    title:SetTextColor(0.88, 0.75, 0.48)

    local status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    status:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
    status:SetHeight(16)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("TOP")
    status:SetWordWrap(false)
    status:SetText(L("Жми «Начать» в этом окне.", "Press Start in this window."))
    bar.status = status

    bar.queueLines = {}
    for i = 1, 5 do
        local line = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", 14, -54 - ((i - 1) * 16))
        line:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
        line:SetJustifyH("LEFT")
        line:SetWordWrap(false)
        line:SetText("")
        bar.queueLines[i] = line
    end

    local sellHead = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellHead:SetPoint("TOPLEFT", 14, -142)
    sellHead:SetText(L("На продажу", "For sale"))
    sellHead:SetTextColor(0.88, 0.75, 0.48)
    bar.sellHead = sellHead

    bar.sellLines = {}
    for i = 1, 6 do
        local line = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", 14, -160 - ((i - 1) * 16))
        line:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
        line:SetJustifyH("LEFT")
        line:SetWordWrap(false)
        line:SetText("")
        bar.sellLines[i] = line
    end

    local total = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    total:SetPoint("BOTTOMLEFT", 14, 104)
    total:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
    total:SetJustifyH("LEFT")
    total:SetText(L("Всего: ", "Total: ") .. "0 сек")
    bar.total = total

    local earn = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    earn:SetPoint("BOTTOMLEFT", 14, 84)
    earn:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
    earn:SetJustifyH("LEFT")
    earn:SetText(L("Заработаю: ", "I'll earn: ") .. "0")
    bar.earn = earn

    local spend = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spend:SetPoint("BOTTOMLEFT", 14, 64)
    spend:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
    spend:SetJustifyH("LEFT")
    spend:SetText(L("Закуплю: ", "I'll buy: ") .. "0")
    bar.spend = spend

    local forecast = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    forecast:SetPoint("BOTTOMLEFT", 14, 44)
    forecast:SetPoint("RIGHT", bar, "RIGHT", -14, 0)
    forecast:SetJustifyH("LEFT")
    forecast:SetText(L("Прогноз: ", "Forecast: ") .. MoneyText(0))
    forecast:SetTextColor(0.88, 0.75, 0.48)
    bar.forecast = forecast

    local start = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    start:SetSize(84, 22)
    start:SetPoint("BOTTOMLEFT", 14, 12)
    start:SetText(L("Начать", "Start"))
    start:SetScript("OnClick", function()
        StartRun()
    end)
    bar.start = start

    local stop = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    stop:SetSize(84, 22)
    stop:SetPoint("LEFT", start, "RIGHT", 8, 0)
    stop:SetText(L("Стоп", "Stop"))
    stop:SetScript("OnClick", function()
        StopRun(L("Остановился.", "Stopped."))
    end)

    local lists = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    lists:SetSize(84, 22)
    lists:SetPoint("LEFT", stop, "RIGHT", 8, 0)
    lists:SetText(L("Списки", "Lists"))
    lists:SetScript("OnClick", ToggleLists)

    bar:SetShown(ProfessionOpen())
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
events:RegisterEvent("TRADE_SKILL_CLOSE")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_UPDATE")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:RegisterEvent("BAG_UPDATE")
pcall(events.RegisterEvent, events, "TRAIT_CONFIG_UPDATED")
pcall(events.RegisterEvent, events, "TRAIT_NODE_CHANGED")
events:SetScript("OnEvent", function(_, event, arg1, _, spellID)
    if event == "ADDON_LOADED" and arg1 == addonName then
        DB()
        EnsureLists()
        EnsureBar()
    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_Professions" then
        EnsureBar()
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        C_Timer.After(0.3, StartMerchantWork)
    elseif event == "MERCHANT_CLOSED" then
        merchantPlanned = false
        if merchantTicker then
            merchantTicker:Cancel()
            merchantTicker = nil
        end
        merchantJob = nil
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        RefreshLists()
        if listFrame and listFrame:IsShown() and listFrame.mode == "economy" then
            RefreshEconomy()
        end
        if bar and bar:IsShown() and RefreshMoney then
            pcall(RefreshMoney)
        end
    elseif event == "BAG_UPDATE" then
        if bar and bar:IsShown() then
            RefreshMoney()
        end
        if not running and ProfessionOpen() then
            ShowQueue()
        end
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "TRAIT_NODE_CHANGED" then
        ForgetChef()
        if bar and bar:IsShown() and RefreshMoney then
            pcall(RefreshMoney)
        end
        if listFrame and listFrame:IsShown() and listFrame.mode == "economy" then
            RefreshEconomy()
        end
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        if event == "TRADE_SKILL_SHOW" then
            ForgetChef()
        end
        RememberRecipes()
        if listFrame and listFrame:IsShown() and listFrame.mode == "economy" then
            RefreshEconomy()
        end
        EnsureBar()
        if event == "TRADE_SKILL_SHOW" and bar then
            bar:Show()
            if not running then
                ShowQueue()
            end
        end
    elseif event == "TRADE_SKILL_CLOSE" then
        if running then
            StopRun(L("Окно закрыто. Я встал.", "Window closed. I stopped."))
        else
            SilenceMaster()
        end
        if bar then
            bar:Hide()
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        NoteCast(spellID)
    elseif event == "PLAYER_REGEN_DISABLED" and running then
        StopRun(L("Бой. Я встал.", "Combat. I stopped."))
    end
end)

C_Timer.NewTicker(0.4, WatchCraft)

SLASH_HOLOP1 = "/holop"
SlashCmdList.HOLOP = function(msg)
    msg = (msg or ""):lower()
    if msg == "debug" or msg == "dump" then
        DumpLists()
        return
    end
    if msg == "clear" then
        ClearLists()
        return
    end
    if msg == "list" or msg == "lists" or msg == "stock" then
        EnsureLists()
        ToggleLists()
        return
    end
    if msg == "eco" or msg == "economy" or msg == "econ" then
        EnsureLists()
        if not listFrame:IsShown() then
            listFrame:Show()
            listFrame:Raise()
        end
        ShowListsMode("economy")
        return
    end
    if running then
        StopRun(L("Остановился.", "Stopped."))
    else
        StartRun()
    end
end
