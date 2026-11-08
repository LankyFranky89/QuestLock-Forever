-- QuestLock Forever options panel (Options -> AddOns -> QuestLock Forever)
local QK = QuestLockNS
local panel = CreateFrame("Frame")
panel.name = "QuestLock Forever"
local category

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("QuestLock Forever")
local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
sub:SetText("Protects items you need for quests from being deleted or sold.")

local checks = {}
local y = -64
local function AddCheck(key, label, tip)
  local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", 16, y)
  local text = cb.Text or cb.text
  if not text then text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); text:SetPoint("LEFT", cb, "RIGHT", 2, 0) end
  text:SetText(label)
  local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 30, 4)
  note:SetText(tip)
  cb:SetScript("OnClick", function(self)
    QK.db[key] = self:GetChecked() and true or false
    QK.Refresh()
  end)
  cb.key = key
  checks[#checks + 1] = cb
  y = y - 44
end

AddCheck("bagIcon", "Show icons on items", "\"!\" for quest items, lock for tools and items you added. Bags, Baganator, vendors and loot.")
AddCheck("tooltip", "Show tooltip line", "Adds \"[QuestLock] Needed for quest\" to item tooltips.")
AddCheck("autoBuyback", "Buy back quest items you sell", "Instantly buys protected items back from the vendor.")
AddCheck("vendorWarning", "Chat warning at vendors", "Lists protected items in your bags when you open a vendor.")
AddCheck("activeOnly", "Only items for quests in my log", "Ignores \"Quest\" type items not in your log. Tools and items you add still count.")
AddCheck("protectTools", "Protect profession tools", "Skinning knife, mining pick, fishing poles, enchanting rods and more.")
AddCheck("protectQuestClass", "Protect all \"Quest\" type items", "Items the game itself marks as Quest Item.")

-- Delete delay: - value +
local delayLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
delayLabel:SetPoint("TOPLEFT", 20, y - 6)
delayLabel:SetText("Lock the delete button for:")
local minus = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
minus:SetSize(26, 22); minus:SetPoint("LEFT", delayLabel, "RIGHT", 10, 0); minus:SetText("-")
local delayValue = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
delayValue:SetPoint("LEFT", minus, "RIGHT", 8, 0); delayValue:SetWidth(50)
local plus = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
plus:SetSize(26, 22); plus:SetPoint("LEFT", delayValue, "RIGHT", 8, 0); plus:SetText("+")
local function SetDelay(v)
  QK.db.deleteDelay = math.max(0, math.min(10, v))
  delayValue:SetText(QK.db.deleteDelay == 0 and "off" or (QK.db.deleteDelay .. " sec"))
end
minus:SetScript("OnClick", function() SetDelay(QK.db.deleteDelay - 1) end)
plus:SetScript("OnClick", function() SetDelay(QK.db.deleteDelay + 1) end)
y = y - 44

-- Drop zone + list of items you added
local listTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
listTitle:SetPoint("TOPLEFT", 16, y)
listTitle:SetText("Your protected items")

local drop = CreateFrame("Button", nil, panel, "BackdropTemplate")
drop:SetSize(300, 40)
drop:SetPoint("TOPLEFT", 16, y - 20)
drop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                   edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
drop:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
drop:SetBackdropBorderColor(1, 0.82, 0)
local dropText = drop:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
dropText:SetPoint("CENTER")
dropText:SetText("Drag an item here to protect it")

local rows = {}
local function RefreshList()
  local ids = {}
  for id in pairs(QK.db.custom) do ids[#ids + 1] = id end
  table.sort(ids)
  for i = 1, math.max(#ids, #rows) do
    local row = rows[i]
    if not row and ids[i] then
      row = CreateFrame("Frame", nil, panel)
      row:SetSize(300, 20)
      row:SetPoint("TOPLEFT", drop, "BOTTOMLEFT", 0, -6 - (i - 1) * 22)
      row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT")
      row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
      row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton"); row.del:SetSize(22, 22); row.del:SetPoint("RIGHT")
      row.del:SetScript("OnClick", function(self)
        local id = self:GetParent().itemID
        QK.db.custom[id] = nil
        RefreshList(); QK.Refresh()
      end)
      rows[i] = row
    end
    if row then
      local id = ids[i]
      if id and i <= 10 then
        local name, link, _, _, _, _, _, _, _, icon = QK.GetInfo(id)
        row.itemID = id
        row.icon:SetTexture(icon or C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400)
        row.text:SetText(link or name or ("item " .. id))
        row:Show()
      else
        row:Hide()
      end
    end
  end
  if #ids > 10 then dropText:SetText("Drag an item here (" .. #ids .. " items, showing 10)") 
  else dropText:SetText("Drag an item here to protect it") end
end

local function TakeCursorItem()
  local kind, id = GetCursorInfo()
  if kind == "item" and id then
    QK.db.custom[id] = "Added by you"
    QK.db.ignored[id] = nil
    ClearCursor()
    RefreshList(); QK.Refresh()
  end
end
drop:SetScript("OnReceiveDrag", TakeCursorItem)
drop:SetScript("OnClick", TakeCursorItem)

local function Load()
  for _, cb in ipairs(checks) do cb:SetChecked(QK.db[cb.key] and true or false) end
  SetDelay(QK.db.deleteDelay or 3)
  RefreshList()
end
panel:SetScript("OnShow", Load)
panel.refresh = Load

function QK.OpenOptions()
  if Settings and Settings.OpenToCategory and category then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel); InterfaceOptionsFrame_OpenToCategory(panel)
  end
end

if Settings and Settings.RegisterCanvasLayoutCategory then
  category = Settings.RegisterCanvasLayoutCategory(panel, "QuestLock Forever")
  Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(panel)
end
