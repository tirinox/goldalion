-- Главное окно со списком сделок и панель настроек (Esc → Настройки → Модификации → Goldalion).

local _, ns = ...

local ROW_HEIGHT = 22
local CELL_GAP = 8
local FIRST_CELL_X = 28 -- место под иконку
local COLUMNS = { -- ключ, заголовок, ширина, выравнивание
  { "name", "Предмет", 240, "LEFT" },
  { "lots", "Лотов", 50, "RIGHT" },
  { "cost", "Выкуп", 85, "RIGHT" },
  { "ref", "Опорная", 85, "RIGHT" },
  { "discount", "Скидка", 60, "RIGHT" },
  { "profit", "Прибыль", 85, "RIGHT" },
  { "reason", "Причина", 80, "LEFT" },
}
local REASON = { neighbors = "соседи", history = "история" }

local function createCells(parent, font)
  local cells, x = {}, FIRST_CELL_X
  for _, column in ipairs(COLUMNS) do
    local cell = parent:CreateFontString(nil, "OVERLAY", font)
    cell:SetPoint("LEFT", parent, "LEFT", x, 0)
    cell:SetWidth(column[3])
    cell:SetJustifyH(column[4])
    cell:SetWordWrap(false)
    cells[column[1]] = cell
    x = x + column[3] + CELL_GAP
  end
  return cells
end

-- Ищет предмет в штатном окне аукциона, чтобы его можно было купить.
local function searchAuction(name)
  local auction = AuctionHouseFrame
  if not (name and auction and auction:IsShown()) then return end
  auction.SearchBar.SearchBox:SetText(name)
  auction.SearchBar:StartSearch()
end

local function initRow(row, deal)
  if not row.created then
    row.created = true
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 4, 0)
    row.cells = createCells(row, "GameFontHighlightSmall")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.deal.link)
      local min, median, lots, variants = ns.variantStats(self.deal.key)
      if min then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("С другими суффиксами: лотов %d, вариантов %d"):format(lots, variants))
        GameTooltip:AddDoubleLine("Минимум", ns.money(min), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Медиана", ns.money(median), 1, 1, 1, 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      -- shift-клик вставляет ссылку в чат, обычный клик ищет предмет на аукционе
      if not HandleModifiedItemClick(self.deal.link) then
        searchAuction(self.deal.link:match("%[(.-)%]"))
      end
    end)
  end
  row.deal = deal
  row.icon:SetTexture((select(5, C_Item.GetItemInfoInstant(deal.link))))
  local cells = row.cells
  cells.name:SetText(deal.link)
  cells.lots:SetText(deal.lots)
  cells.cost:SetText(ns.money(deal.cost))
  cells.ref:SetText(ns.money(deal.ref))
  cells.discount:SetText(("%.0f%%"):format(deal.discount * 100))
  cells.profit:SetText(ns.money(deal.profit))
  cells.reason:SetText(REASON[deal.reason])
end

local function idleStatus()
  local last = ns.db.lastScan
  if not last then return "Открой аукцион и нажми «Сканировать»." end
  local text = ("Скан %d мин назад: лотов %d, сделок %d."):format(
    math.floor((time() - last.time) / 60), last.lots, #ns.db.lastDeals)
  if not ns.scan then text = text .. " Список сохранён с прошлого сеанса." end
  return text
end

---------------------------------------------------------------- настройки

-- Сумма выкупа выбирается по логарифмической шкале: 10с, 20с, 50с, 1з … 500з, 1000з.
local COST_STEPS = {}
for _, unit in ipairs({ 1000, 10000, 100000, 1000000 }) do
  for _, factor in ipairs({ 1, 2, 5 }) do COST_STEPS[#COST_STEPS + 1] = unit * factor end
end
COST_STEPS[#COST_STEPS + 1] = 10000000

local function costToStep(copper)
  for step, value in ipairs(COST_STEPS) do
    if value >= copper then return step end
  end
  return #COST_STEPS
end

local function stepToCost(step)
  return COST_STEPS[math.floor(step + 0.5)]
end

local function same(value) return value end

local function registerSettings()
  local category = Settings.RegisterVerticalLayoutCategory("Goldalion")

  -- toSetting переводит значение из ns.opts (медь, доли) в единицы панели настроек, fromSetting — обратно.
  local function proxy(key, label, toSetting, fromSetting)
    toSetting, fromSetting = toSetting or same, fromSetting or same
    local default = toSetting(ns.defaults[key])
    return Settings.RegisterProxySetting(category, "GOLDALION_" .. key, type(default), label, default,
      function() return toSetting(ns.opts[key]) end,
      function(value)
        ns.opts[key] = fromSetting(value)
        ns.optionsChanged()
      end)
  end

  local function slider(key, label, tooltip, min, max, step, formatter, toSetting, fromSetting)
    local options = Settings.CreateSliderOptions(min, max, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
    Settings.CreateSlider(category, proxy(key, label, toSetting, fromSetting), options, tooltip)
  end

  local function text(format)
    return function(value) return format:format(value) end
  end

  local function scaled(scale)
    return function(value) return math.floor(value / scale + 0.5) end, function(value) return value * scale end
  end

  slider("minDiscount", "Минимальная скидка",
    "Лот должен быть дешевле опорной цены минимум на столько процентов.", 10, 90, 5, text("%d%%"), scaled(0.01))
  slider("minProfit", "Минимальная прибыль",
    "Сделки с ожидаемой прибылью меньше этой суммы не показываются.", 0, 500, 10, text("%d с"), scaled(100))
  slider("maxCost", "Максимальная сумма выкупа",
    "Лимит на выкуп всей дешёвой группы лотов одного предмета.", 1, #COST_STEPS, 1,
    function(step)
      local copper = stepToCost(step)
      if copper >= 10000 then return ("%d з"):format(copper / 10000) end
      return ("%d с"):format(copper / 100)
    end, costToStep, stepToCost)
  slider("maxLots", "Максимум лотов под выкуп",
    "Сделки, где дешёвая группа больше стольких лотов, не показываются.", 1, 50, 1, text("%d"))
  slider("outlierFactor", "Отсечение дорогих лотов",
    "Лоты дороже стольких медиан не считаются конкурентами.", 2, 20, 1, text("×%d"))

  Settings.CreateDropdown(category, proxy("minQuality", "Минимальное качество"), function()
    local container = Settings.CreateControlTextContainer()
    for quality = 1, 4 do
      container:Add(quality, _G["ITEM_QUALITY" .. quality .. "_DESC"])
    end
    return container:GetData()
  end, "Предметы ниже этого качества не показываются.")

  Settings.CreateCheckbox(category, proxy("openWithAuction", "Открывать вместе с аукционом"),
    "Показывать окно Goldalion при открытии аукциона.")

  Settings.RegisterAddOnCategory(category)
  return category
end

---------------------------------------------------------------- окно

function ns.initUI()
  local category = registerSettings()

  local width = FIRST_CELL_X + 60 -- отступы и полоса прокрутки
  for _, column in ipairs(COLUMNS) do width = width + column[3] + CELL_GAP end

  local f = CreateFrame("Frame", "GoldalionFrame", UIParent, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(f)
  ButtonFrameTemplate_HideButtonBar(f)
  f:SetTitle("Goldalion — выгодные лоты")
  f:SetSize(width, 460)
  f:SetPoint("CENTER")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  tinsert(UISpecialFrames, "GoldalionFrame") -- закрытие по Esc

  f.Inset:ClearAllPoints()
  f.Inset:SetPoint("TOPLEFT", 4, -76)
  f.Inset:SetPoint("BOTTOMRIGHT", -6, 6)

  local scanButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  scanButton:SetSize(120, 22)
  scanButton:SetPoint("TOPLEFT", 12, -28)
  scanButton:SetText("Сканировать")
  scanButton:SetScript("OnClick", function() ns.startScan() end)

  local settingsButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  settingsButton:SetSize(100, 22)
  settingsButton:SetPoint("TOPRIGHT", -12, -28)
  settingsButton:SetText("Настройки")
  settingsButton:SetScript("OnClick", function() Settings.OpenToCategory(category:GetID()) end)

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", scanButton, "RIGHT", 10, 0)
  status:SetPoint("RIGHT", settingsButton, "LEFT", -10, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  local scrollBox = CreateFrame("Frame", nil, f, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 4, -4)
  scrollBox:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -22, 4)
  local scrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", initRow)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

  local header = CreateFrame("Frame", nil, f)
  header:SetHeight(18)
  header:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 6)
  header:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 6)
  local headerCells = createCells(header, "GameFontNormalSmall")
  for _, column in ipairs(COLUMNS) do headerCells[column[1]]:SetText(column[2]) end

  local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", f.Inset)
  empty:SetText("Сделок нет")

  function ns.refresh(dealsChanged)
    if not f:IsShown() then return end
    status:SetText(ns.status or idleStatus())
    scanButton:SetEnabled(ns.auctionOpen == true and ns.scanning == nil)
    if dealsChanged then
      scrollBox:SetDataProvider(CreateDataProvider(ns.db.lastDeals))
      empty:SetShown(#ns.db.lastDeals == 0)
    end
  end

  function ns.toggleUI(show)
    if show == nil then show = not f:IsShown() end
    f:SetShown(show)
  end

  f:SetScript("OnShow", function() ns.refresh(true) end)
end
