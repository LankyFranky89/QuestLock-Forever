-- QuestLock: protects quest-needed trade items from being deleted or sold.
local ADDON = "QuestLockForever"
local PREFIX = "|cff33ccffQuestLock:|r "

-- No built-in quest list: quest items come from your quest log only.
local BUILTIN = {}

-- Profession tools: never sell or delete these by accident.
local TOOLS = {
  [7005]  = "Skinning Knife",
  [2901]  = "Mining Pick",
  [5956]  = "Blacksmith Hammer",
  [6219]  = "Arclight Spanner",
  [10498] = "Gyromatic Micro-Adjustor",
  [6218]  = "Runed Copper Rod",
  [6339]  = "Runed Silver Rod",
  [11130] = "Runed Golden Rod",
  [11145] = "Runed Truesilver Rod",
  [16207] = "Runed Arcanite Rod",
  [6256]  = "Fishing Pole",
  [6365]  = "Strong Fishing Pole",
  [6366]  = "Darkwood Fishing Pole",
  [6367]  = "Big Iron Fishing Pole",
  [12225] = "Blump Family Fishing Pole",
  [19022] = "Nat Pagle's Extreme Angler FC-5000",
  [19970] = "Arcanite Fishing Pole",
}

local db
local function GetInfo(id) return ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(id) end
local allowUntil = 0
local lockFrame
local UpdateAllBags
local redrawQueued = false
local UpdateMerchantRef

QuestLockNS = {}
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function IDFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

-- Items asked for by quests currently in your quest log: [item name] = quest title
local questNeeds = {}

local scanning = false
local ignoreQuestEventsUntil = 0
local function NumEntries()
  return (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries())
         or GetNumQuestLogEntries()
end

-- Pull the item name out of an objective line, in either format:
--   "Chunk of Boar Meat: 3/4"   (old)
--   "3/4 Chunk of Boar Meat"    (new)
local function ObjectiveName(text)
  if not text then return nil end
  local name = text:match("^(.-):%s*%d+%s*/%s*%d+")
            or text:match("^%d+%s*/%s*%d+%s+(.+)$")
            or text
  name = strtrim((name:gsub("%s*%(.-%)%s*$", "")))
  return name ~= "" and name or nil
end

-- Returns title, isHeader, isCollapsed, questID for quest log line i (old or new API)
local function EntryInfo(i)
  if C_QuestLog and C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(i)
    if info then return info.title, info.isHeader, info.isCollapsed, info.questID end
  end
  if GetQuestLogTitle then
    local title, _, _, isHeader, isCollapsed, _, _, questID = GetQuestLogTitle(i)
    return title, isHeader, isCollapsed, questID
  end
end

-- Calls fn(text, isItem, done) for each objective of quest log line i
local function ForEachObjective(i, questID, fn)
  if questID and C_QuestLog and C_QuestLog.GetQuestObjectives then
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if objs and #objs > 0 then
      for _, o in ipairs(objs) do fn(o.text, o.type == "item", o.finished) end
      return
    end
  end
  if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
    for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
      local text, kind, done = GetQuestLogLeaderBoard(j, i)
      fn(text, kind == "item", done)
    end
  end
end

local function DoScan(collapsed)
  for i = 1, NumEntries() do
    local title, isHeader, _, questID = EntryInfo(i)
    if title and not isHeader then
      ForEachObjective(i, questID, function(text, isItem, done)
        local name = isItem and ObjectiveName(text)
        if name then
          questNeeds[name] = done and (title .. " - done, turn in!") or title
        end
      end)
    end
  end
end

local function ScanQuestLog()
  if scanning then return end
  scanning = true
  wipe(questNeeds)

  -- Quests under collapsed zone headers are invisible to addons,
  -- so open every header, scan, then close the ones that were closed.
  local collapsed = {}
  local expand = (C_QuestLog and C_QuestLog.Expand) and function() for i = 1, NumEntries() do C_QuestLog.Expand(i) end end
                 or (ExpandQuestHeader and function() ExpandQuestHeader(0) end)
  for i = 1, NumEntries() do
    local title, isHeader, isCollapsed = EntryInfo(i)
    if isHeader and isCollapsed and title then collapsed[title] = true end
  end
  if next(collapsed) and expand then
    ignoreQuestEventsUntil = GetTime() + 1  -- our own expand/collapse fires QUEST_LOG_UPDATE
    pcall(expand)
  end

  local ok, err = pcall(DoScan)
  if not ok then Print("Quest log scan error: " .. tostring(err)) end

  if next(collapsed) then
    local collapse = (C_QuestLog and C_QuestLog.Collapse) or CollapseQuestHeader
    for i = NumEntries(), 1, -1 do
      local title, isHeader = EntryInfo(i)
      if isHeader and title and collapsed[title] and collapse then pcall(collapse, i) end
    end
  end
  scanning = false
end

-- Returns a reason string if the item is protected, otherwise nil.
local function GuardReason(itemID)
  if not itemID then return nil end
  if db.ignored[itemID] then return nil end
  if db.protectTools and TOOLS[itemID] then return "Profession tool" end
  local name = GetInfo(itemID)
  if not name and next(questNeeds) and C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)  -- GET_ITEM_INFO_RECEIVED will redraw
  end
  if name and questNeeds[name] then return "Quest: " .. questNeeds[name] end
  if db.custom[itemID] then return db.custom[itemID] end
  if db.activeOnly then return nil end
  if BUILTIN[itemID] then return BUILTIN[itemID] end
  if db.protectQuestClass then
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, _, _, classID = getInfo(itemID)
    if classID == 12 then return "Quest item" end -- LE_ITEM_CLASS_QUESTITEM
  end
  return nil
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_QUESTLOCK1 = "/ql"
SLASH_QUESTLOCK2 = "/questlock"
SLASH_QUESTLOCKDEBUG1 = "/qldebug"
SlashCmdList.QUESTLOCKDEBUG = function() SlashCmdList.QUESTLOCK("debug") end
SlashCmdList.QUESTLOCK = function(msg)
  if not db then Print("Not loaded yet."); return end
  local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local id = IDFromLink(rest) or tonumber(rest)
  if cmd == "" or cmd == "options" or cmd == "config" then
    if QuestLockNS.OpenOptions then QuestLockNS.OpenOptions() end
    return
  elseif cmd == "add" and id then
    db.custom[id] = "Added by you"; db.ignored[id] = nil
    UpdateAllBags()
    Print("Now protecting " .. (select(2, GetInfo(id)) or ("item " .. id)))
  elseif cmd == "remove" and id then
    db.custom[id] = nil; db.ignored[id] = true
    UpdateAllBags()
    Print("No longer protecting " .. (select(2, GetInfo(id)) or ("item " .. id)))
  elseif cmd == "allow" then
    allowUntil = GetTime() + 30
    Print("Selling protected items allowed for 30 seconds.")
  elseif cmd == "buyback" then
    db.autoBuyback = not db.autoBuyback
    Print("Auto-buyback " .. (db.autoBuyback and "ON" or "OFF"))
  elseif cmd == "tooltip" then
    db.tooltip = not db.tooltip
    Print("Tooltip marker " .. (db.tooltip and "ON" or "OFF"))
  elseif cmd == "questclass" then
    db.protectQuestClass = not db.protectQuestClass
    Print("Protect all 'Quest' type items " .. (db.protectQuestClass and "ON" or "OFF"))
  elseif cmd == "activeonly" then
    db.activeOnly = not db.activeOnly
    UpdateAllBags()
    Print("Active quests only: " .. (db.activeOnly and
      "ON (only items your current quests need, plus items you added)" or "OFF (built-in list + Quest items too)"))
  elseif cmd == "tools" then
    db.protectTools = not db.protectTools
    UpdateAllBags()
    Print("Protect profession tools " .. (db.protectTools and "ON" or "OFF"))
  elseif cmd == "vendorwarn" then
    db.vendorWarning = not db.vendorWarning
    Print("Chat warning at vendors " .. (db.vendorWarning and "ON" or "OFF"))
  elseif cmd == "icon" then
    db.bagIcon = not db.bagIcon
    UpdateAllBags()
    Print("Bag icon " .. (db.bagIcon and "ON" or "OFF"))
  elseif cmd == "delay" and tonumber(rest) then
    db.deleteDelay = math.max(0, tonumber(rest))
    Print("Delete button lock: " .. db.deleteDelay .. " sec")
  elseif cmd == "debug" then
    ScanQuestLog()
    local n = 0
    for name, q in pairs(questNeeds) do n = n + 1; Print("  [" .. name .. "] <- " .. q) end
    Print("Quest log lines: " .. NumEntries() .. ", items found: " .. n)
  elseif cmd == "list" then
    ScanQuestLog()
    Print("Needed by quests in your log:")
    for name, q in pairs(questNeeds) do Print("  " .. name .. " - " .. q) end
    Print("Always protected:")
    local all = {}
    for k, v in pairs(BUILTIN) do all[k] = v end
    for k, v in pairs(db.custom) do all[k] = v end
    for k, v in pairs(all) do
      if not db.ignored[k] then
        Print("  " .. (select(2, GetInfo(k)) or ("item " .. k)) .. " - " .. v)
      end
    end
  else
    Print("Version " .. ((C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"))
    Print("Commands: /ql (options), /ql debug, /ql add [item], /ql remove [item], /ql list, /ql allow, " ..
          "/ql buyback, /ql tooltip, /ql questclass, /ql activeonly, /ql icon, /ql vendorwarn, /ql tools, /ql delay <sec>")
  end
end

local function Alarm(text)
  PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
  RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
end

---------------------------------------------------------------------------
-- DELETE protection: add a warning to the delete popup and lock the button
---------------------------------------------------------------------------
local DELETE_POPUPS = { DELETE_ITEM = true, DELETE_GOOD_ITEM = true,
                        DELETE_QUEST_ITEM = true, DELETE_GOOD_QUEST_ITEM = true }

if StaticPopup_Show then hooksecurefunc("StaticPopup_Show", function(which)
  if not db or not DELETE_POPUPS[which] then return end
  local kind, itemID = GetCursorInfo()
  if kind ~= "item" then return end
  local reason = GuardReason(itemID)
  if not reason then return end

  local frame = StaticPopup_FindVisible(which)
  if not frame then return end
  local textObj = frame.text or _G[frame:GetName() .. "Text"]
  if textObj then
    local oldTextH = textObj:GetStringHeight() or 0
    local oldFrameH = frame:GetHeight()
    textObj:SetText(textObj:GetText() ..
      (reason == "Profession tool" and "\n\n|cffff2020WARNING: this is a profession tool!|r" or "\n\n|cffff2020WARNING: this item is needed for a quest!|r") .. "\n|cffffd100(" .. reason .. ")|r")
    -- Grow the popup so the extra lines don't overlap the buttons.
    if frame.Layout then pcall(frame.Layout, frame) end
    if StaticPopup_Resize then pcall(StaticPopup_Resize, frame, which) end
    local grow = (textObj:GetStringHeight() or 0) - oldTextH
    if grow > 0 and frame:GetHeight() < oldFrameH + grow then
      frame:SetHeight(oldFrameH + grow)
    end
  end
  Alarm("QuestLock: you are deleting a quest item!")

  -- Lock the confirm button for a few seconds so it can't be clicked by reflex.
  local btn = frame.button1 or frame.Button1
    or (frame.ButtonContainer and frame.ButtonContainer.Button1)
    or (frame.GetButton1 and frame:GetButton1())
    or _G[frame:GetName() .. "Button1"]
  if not btn or db.deleteDelay <= 0 then return end
  local label = btn:GetText() or YES
  local endTime = GetTime() + db.deleteDelay
  if not lockFrame then lockFrame = CreateFrame("Frame") end
  btn:Disable()
  lockFrame:SetScript("OnUpdate", function(self)
    if not frame:IsShown() then btn:SetText(label); self:SetScript("OnUpdate", nil); return end
    local left = math.ceil(endTime - GetTime())
    if left > 0 then
      btn:Disable()                       -- keep it locked even if the game re-enables it
      btn:SetText(label .. " (" .. left .. ")")
    else
      btn:SetText(label)
      local eb = frame.editBox or frame.EditBox or _G[frame:GetName() .. "EditBox"]
      if which == "DELETE_ITEM" or which == "DELETE_QUEST_ITEM" or not (eb and eb:IsShown()) then
        btn:Enable()
      elseif eb:GetText():upper() == DELETE_ITEM_CONFIRM_STRING:upper() then
        btn:Enable()
      end
      self:SetScript("OnUpdate", nil)
    end
  end)
end) end

---------------------------------------------------------------------------
-- SELL protection: warn at vendor and instantly buy back protected items
---------------------------------------------------------------------------
local atMerchant = false

local function ScanBagsForProtected()
  local found = {}
  for bag = 0, 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and GuardReason(info.itemID) and not found[info.itemID] then
        found[info.itemID] = info.hyperlink
      end
    end
  end
  return found
end

local function CheckBuyback()
  if not db.autoBuyback or GetTime() < allowUntil then return end
  for i = GetNumBuybackItems(), 1, -1 do
    local link = GetBuybackItemLink(i)
    local id = IDFromLink(link)
    local reason = GuardReason(id)
    if reason then
      BuybackItem(i)
      Alarm("QuestLock: bought back " .. (link or "quest item"))
      Print("You sold " .. (link or "?") .. " (" .. reason .. ") - bought it back. " ..
            "Use |cffffd100/ql allow|r to sell protected items for 30 sec.")
      return -- one per update; the next MERCHANT_UPDATE handles any others
    end
  end
end

---------------------------------------------------------------------------
-- Tooltip marker
---------------------------------------------------------------------------
local function OnTooltip(tt)
  if not db or not db.tooltip then return end
  local _, link = tt:GetItem()
  local reason = GuardReason(IDFromLink(link))
  if reason then
    tt:AddLine((reason == "Profession tool" and "|cffff8000[QuestLock] Protected:|r " or "|cffff8000[QuestLock] Needed for quest:|r ") .. reason, 1, 1, 1, true)
    tt:Show()
  end
end
if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
    if tt == GameTooltip or tt == ItemRefTooltip then OnTooltip(tt) end
  end)
else
  pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", OnTooltip)
  pcall(ItemRefTooltip.HookScript, ItemRefTooltip, "OnTooltipSetItem", OnTooltip)
end

---------------------------------------------------------------------------
-- Bag icon: yellow "!" on protected items in the default bags
---------------------------------------------------------------------------
local ICON_QUEST = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_LOCK  = "Interface\\AddOns\\QuestLockForever\\lock"

-- "!" for quest items, lock for everything else (tools, items you added)
local function IconFor(itemID)
  local reason = GuardReason(itemID)
  if not reason then return nil end
  if reason == "Profession tool" or reason == "Added by you" then return ICON_LOCK end
  return ICON_QUEST
end
QuestLockNS_IconFor = IconFor

local function SetMark(btn, icon)
  if not btn.qkMark then
    if not icon then return end
    local t = btn:CreateTexture(nil, "OVERLAY", nil, 7)
    t:SetSize(16, 16)
    t:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
    btn.qkMark = t
  end
  if icon then btn.qkMark:SetTexture(icon) end
  btn.qkMark:SetShown(icon and true or false)
end

local function MarkButton(btn, bag, slot)
  if not btn or not bag or not slot then return end
  local icon
  if db and db.bagIcon then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    icon = info and IconFor(info.itemID)
  end
  SetMark(btn, icon)
end

local function UpdateBagFrame(frame)
  if not frame or not frame:IsShown() then return end
  local bag = frame:GetID()
  local name = frame:GetName()
  if frame.EnumerateValidItems then
    for _, btn in frame:EnumerateValidItems() do
      MarkButton(btn, btn.GetBagID and btn:GetBagID() or bag, btn:GetID())
    end
  elseif name then
    for j = 1, (frame.size or 36) do
      local btn = _G[name .. "Item" .. j]
      if btn then MarkButton(btn, bag, btn:GetID()) end
    end
  end
end

local function RefreshBaganator()
  if Baganator and Baganator.API and Baganator.API.RequestItemButtonsRefresh then
    Baganator.API.RequestItemButtonsRefresh()
  end
end

local baganatorDone = false
local function RegisterBaganator()
  if baganatorDone or not (Baganator and Baganator.API and Baganator.API.RegisterCornerWidget) then return end
  baganatorDone = true
  Baganator.API.RegisterCornerWidget("QuestLock: protected item", "questlock_item",
    function(mark, details)
      if not db or not db.bagIcon then return false end
      local id = details.itemID or IDFromLink(details.itemLink)
      if not id then return false end  -- empty slot: never show
      local icon = QuestLockNS_IconFor(id)
      if icon then mark:SetTexture(icon) end
      return icon and true or false
    end,
    function(itemButton)
      local t = itemButton:CreateTexture(nil, "OVERLAY")
      t:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
      t:SetSize(16, 16)
      t.padding = 0
      return t
    end,
    { corner = "top_left", priority = 1 })
end

-- Baganator only shows corner icons that are switched on in its settings.
-- Switch ours on once, in the top-left corner.
local function EnsureBaganatorCorner()
  if not baganatorDone or not db or db.baganatorAdded then return end
  if Baganator.API.IsCornerWidgetActive and Baganator.API.IsCornerWidgetActive("questlock_item") then
    db.baganatorAdded = true; return
  end
  local cfg = BAGANATOR_CONFIG and BAGANATOR_CONFIG.Profiles
  local profile = cfg and cfg[BAGANATOR_CURRENT_PROFILE or "DEFAULT"]
  local arr = profile and profile.icon_top_left_corner_array
  if type(arr) == "table" then
    table.insert(arr, 1, "questlock_item")
    db.baganatorAdded = true
    if Baganator.API.RequestLayoutUpdate then Baganator.API.RequestLayoutUpdate() end
    RefreshBaganator()
    Print("Turned on the quest icon in Baganator (top-left corner). If you don't see it, type /reload once.")
  end
end

UpdateAllBags = function()
  RefreshBaganator()
  if UpdateMerchantRef then UpdateMerchantRef() end
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do UpdateBagFrame(_G["ContainerFrame" .. i]) end
  if ContainerFrameCombinedBags then UpdateBagFrame(ContainerFrameCombinedBags) end
end

if ContainerFrame_Update then hooksecurefunc("ContainerFrame_Update", UpdateBagFrame) end
for i = 1, (NUM_CONTAINER_FRAMES or 13) do
  local cf = _G["ContainerFrame" .. i]
  if cf then cf:HookScript("OnShow", function(self) C_Timer.After(0, function() UpdateBagFrame(self) end) end) end
end

---------------------------------------------------------------------------
-- Vendor window: "!" on items for sale (and in buyback) that a quest needs
---------------------------------------------------------------------------
local function UpdateMerchant()
  if not MerchantFrame or not MerchantFrame:IsShown() then return end
  local perPage = MERCHANT_ITEMS_PER_PAGE or 10
  local buyback = MerchantFrame.selectedTab == 2
  for i = 1, perPage do
    local btn = _G["MerchantItem" .. i .. "ItemButton"]
    if btn then
      local link
      if buyback then
        link = GetBuybackItemLink(i)
      else
        link = GetMerchantItemLink(((MerchantFrame.page or 1) - 1) * perPage + i)
      end
      SetMark(btn, (db and db.bagIcon) and IconFor(IDFromLink(link)) or nil)
    end
  end
end
UpdateMerchantRef = UpdateMerchant
if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateMerchant) end
if MerchantFrame_UpdateBuybackInfo then hooksecurefunc("MerchantFrame_UpdateBuybackInfo", UpdateMerchant) end
if MerchantFrame_Update then hooksecurefunc("MerchantFrame_Update", UpdateMerchant) end

QuestLockNS.GetInfo = GetInfo
QuestLockNS.Refresh = function() UpdateAllBags() end

---------------------------------------------------------------------------
-- Loot window: icons on loot that is a quest item / protected
---------------------------------------------------------------------------
local function UpdateLoot()
  if not LootFrame or not LootFrame:IsShown() then return end
  local show = db and db.bagIcon
  -- Old-style loot window: LootButton1..N with .slot
  for i = 1, (LOOTFRAME_NUMBUTTONS or 4) do
    local btn = _G["LootButton" .. i]
    if btn then
      local slot = btn.slot
      local link = slot and btn:IsShown() and GetLootSlotLink(slot)
      SetMark(btn, show and IconFor(IDFromLink(link)) or nil)
    end
  end
  -- Newer scrolling loot window
  if LootFrame.ScrollBox and LootFrame.ScrollBox.ForEachFrame then
    LootFrame.ScrollBox:ForEachFrame(function(frame)
      local slot = frame.GetSlotIndex and frame:GetSlotIndex()
      local target = frame.Item or frame
      local link = slot and GetLootSlotLink(slot)
      SetMark(target, show and IconFor(IDFromLink(link)) or nil)
    end)
  end
end
local function UpdateLootSoon() C_Timer.After(0, UpdateLoot) end
if LootFrame_Update then hooksecurefunc("LootFrame_Update", UpdateLoot) end
local lootEvents = CreateFrame("Frame")
lootEvents:RegisterEvent("LOOT_OPENED")
lootEvents:RegisterEvent("LOOT_SLOT_CLEARED")
lootEvents:SetScript("OnEvent", UpdateLootSoon)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
f:RegisterEvent("MERCHANT_UPDATE")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    QuestLockForeverDB = QuestLockForeverDB or {}
    db = QuestLockForeverDB
    db.custom = db.custom or {}
    db.ignored = db.ignored or {}
    if db.autoBuyback == nil then db.autoBuyback = true end
    if db.tooltip == nil then db.tooltip = true end
    if db.protectQuestClass == nil then db.protectQuestClass = true end
    if not db.migratedQuestClassOn then
      db.protectQuestClass = true
      db.migratedQuestClassOn = true
    end
    db.deleteDelay = db.deleteDelay or 3
    QuestLockNS.db = db
    if db.activeOnly == nil then db.activeOnly = false end
    if db.bagIcon == nil then db.bagIcon = true end
    if db.vendorWarning == nil then db.vendorWarning = false end
    if db.protectTools == nil then db.protectTools = true end
    RegisterBaganator()
  elseif event == "QUEST_LOG_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
    if event == "QUEST_LOG_UPDATE" and GetTime() < ignoreQuestEventsUntil then return end
    if event == "PLAYER_ENTERING_WORLD" then
      RegisterBaganator()
      C_Timer.After(2, EnsureBaganatorCorner)
      for _, t in ipairs({1, 3, 6}) do
        C_Timer.After(t, function() ScanQuestLog(); UpdateAllBags() end)
      end
    end
    ScanQuestLog()
    UpdateAllBags()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    -- item names arrived; redraw once shortly (many of these fire at login)
    if not redrawQueued then
      redrawQueued = true
      C_Timer.After(0.5, function() redrawQueued = false; UpdateAllBags() end)
    end
  elseif event == "BAG_UPDATE_DELAYED" then
    ScanQuestLog()
    UpdateAllBags()
  elseif event == "ADDON_LOADED" and arg1 == "Baganator" then
    RegisterBaganator()
  elseif event == "MERCHANT_SHOW" then
    ScanQuestLog()
    atMerchant = true
    local found = ScanBagsForProtected()
    local list = {}
    for _, link in pairs(found) do list[#list + 1] = link end
    if #list > 0 and db.vendorWarning then
      Print("Careful! Quest items in your bags: " .. table.concat(list, ", "))
    end
  elseif event == "MERCHANT_CLOSED" then
    atMerchant = false
  elseif event == "MERCHANT_UPDATE" and atMerchant then
    C_Timer.After(0.2, CheckBuyback)
  end
end)

