-- Главное окно со списком сделок и всплывающее окно настроек (кнопка «Настройки»).

local _, ns = ...

local ROW_HEIGHT = 22
local CELL_GAP = 8
local FIRST_CELL_X = 28 -- место под иконку
local COLUMNS = { -- ключ, ширина, выравнивание, заголовок на вкладке «Скидки», на вкладке «Торговцы»
  { "name", 240, "LEFT", "Предмет", "Предмет" },
  { "lots", 50, "RIGHT", "Лотов", "На ауке" },
  { "cost", 85, "RIGHT", "Выкуп", "Закупка" },
  { "ref", 85, "RIGHT", "Опорная", "Аукцион" },
  { "discount", 60, "RIGHT", "Скидка", "Скидка" },
  { "profit", 85, "RIGHT", "Прибыль", "Прибыль" },
  { "reason", 110, "LEFT", "Причина", "Торговец" },
}
local TABS = { "Скидки", "Торговцы" }
local VENDOR_TAB = 2
local REASON = { neighbors = "соседи", history = "история" }
local tab = 1

local function currentDeals()
  return tab == VENDOR_TAB and ns.db.vendorDeals or ns.db.lastDeals
end

local function createCells(parent, font)
  local cells, x = {}, FIRST_CELL_X
  for _, column in ipairs(COLUMNS) do
    local cell = parent:CreateFontString(nil, "OVERLAY", font)
    cell:SetPoint("LEFT", parent, "LEFT", x, 0)
    cell:SetWidth(column[2])
    cell:SetJustifyH(column[3])
    cell:SetWordWrap(false)
    cells[column[1]] = cell
    x = x + column[2] + CELL_GAP
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
      local deal = self.deal
      GameTooltip:SetHyperlink(deal.link)
      local min, median, lots, variants = ns.variantStats(deal.key)
      if deal.price then -- сделка режима «торговцы»
        GameTooltip:AddLine(" ")
        local seller = deal.reason .. (deal.zone ~= "" and ", " .. deal.zone or "")
        if (deal.others or 0) > 0 then seller = seller .. (" и ещё %d"):format(deal.others) end
        GameTooltip:AddDoubleLine("Продаёт", seller, 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Цена за штуку", ns.money(deal.price), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Купить штук", deal.units .. (deal.limited and " (запас ограничен)" or ""), 1, 1, 1, 1, 1, 1)
        if deal.seed then
          GameTooltip:AddLine("Цена и торговец из базы, у торговца не проверены: запас может быть ограничен.", 1, 0.5, 0.25, true)
        end
        if not deal.min then
          GameTooltip:AddLine("На аукционе сейчас нет, цена взята из истории.")
        elseif deal.ref < deal.min then
          GameTooltip:AddDoubleLine("Минимум на аукционе", ns.money(deal.min), 1, 1, 1, 1, 1, 1)
          GameTooltip:AddLine("Обычно дешевле: цена взята из истории.")
        end
      elseif min then
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
  cells.reason:SetText(REASON[deal.reason] or deal.reason) -- у торговцев здесь имя NPC
end

-- Сортировка списка: клик по заголовку колонки, повторный клик меняет направление.
local sortKey, sortDesc = "profit", true

local function sortValue(deal)
  -- ponytail: названия сравниваются побайтно (в UTF-8 «ё» окажется после «я»)
  if sortKey == "name" then return deal.link:match("%[(.-)%]") or "" end
  return deal[sortKey]
end

local function sortDeals(deals)
  table.sort(deals, function(a, b)
    local x, y = sortValue(a), sortValue(b)
    if x == y then return a.profit > b.profit end
    if sortDesc then return x > y end
    return x < y
  end)
end

local function idleStatus()
  local last = ns.db.lastScan
  if not last then return "Открой аукцион и нажми «Сканировать»." end
  local text = ("Скан %d мин назад: лотов %d, сделок %d."):format(
    math.floor((time() - last.time) / 60), last.lots, #currentDeals())
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

local function text(format)
  return function(value) return format:format(value) end
end

local function scaled(scale)
  return function(value) return math.floor(value / scale + 0.5) end, function(value) return value * scale end
end

local function anyLevel(value)
  return value == 0 and "любой" or tostring(value)
end

-- key → { get, set } в единицах элемента (проценты, серебро, ступени); через них же работают тесты.
local controls = {}
ns.settingControls = controls

local function setOption(key, value)
  ns.opts[key] = value
  ns.optionsChanged()
end

local function tip(region, label, tooltip)
  region:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(label)
    GameTooltip:AddLine(tooltip, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  region:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Элементы складываются на странице сверху вниз, page.y — отступ следующего.
local function title(page, label)
  local fs = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", 0, page.y)
  fs:SetText(label)
  return fs
end

-- toUI переводит значение из ns.opts (медь, доли) в единицы ползунка, fromUI — обратно.
local function slider(page, key, label, tooltip, min, max, step, formatter, toUI, fromUI)
  toUI, fromUI = toUI or same, fromUI or same
  local s = CreateFrame("Frame", nil, page, "MinimalSliderWithSteppersTemplate")
  s:SetPoint("TOPLEFT", title(page, label), "BOTTOMLEFT", 0, -2)
  s:SetSize(200, 26)
  s:Init(toUI(ns.opts[key]), min, max, (max - min) / step, { [MinimalSliderWithSteppersMixin.Label.Right] = formatter })
  controls[key] = {
    get = function() return toUI(ns.opts[key]) end,
    set = function(value) setOption(key, fromUI(value)) end,
  }
  s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
    controls[key].set(math.floor(value + 0.5)) -- все шкалы целочисленные
  end, s)
  tip(s.Slider, label, tooltip)
  page.y = page.y - 46
end

local function checkbox(page, key, label, tooltip)
  local c = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
  c:SetPoint("TOPLEFT", -6, page.y + 4)
  c.Text:SetText(label)
  c:SetChecked(ns.opts[key])
  controls[key] = { get = function() return ns.opts[key] end, set = function(value) setOption(key, value) end }
  c:SetScript("OnClick", function(self) controls[key].set(self:GetChecked()) end)
  tip(c, label, tooltip)
  page.y = page.y - 30
end

-- values: { { значение, текст }, ... }
local function dropdown(page, key, label, tooltip, values)
  local d = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
  d:SetPoint("TOPLEFT", title(page, label), "BOTTOMLEFT", 0, -4)
  d:SetWidth(200)
  controls[key] = { get = function() return ns.opts[key] end, set = function(value) setOption(key, value) end }
  d:SetupMenu(function(_, root)
    for _, item in ipairs(values) do
      root:CreateRadio(item[2], function() return ns.opts[key] == item[1] end, function() controls[key].set(item[1]) end)
    end
  end)
  tip(d, label, tooltip)
  page.y = page.y - 50
end

local function levelSlider(page, key)
  slider(page, key, "Минимальный требуемый уровень",
    "Предметы, для которых нужен уровень ниже этого, не показываются. 0 — без ограничения.", 0, 60, 1, anyLevel)
end

local SETTINGS_PAGES = {
  function(page) -- «Скидки»
    slider(page, "minDiscount", "Минимальная скидка",
      "Лот должен быть дешевле опорной цены минимум на столько процентов.", 10, 90, 5, text("%d%%"), scaled(0.01))
    slider(page, "minProfit", "Минимальная прибыль",
      "Сделки с ожидаемой прибылью меньше этой суммы не показываются.", 0, 500, 10, text("%d с"), scaled(100))
    slider(page, "maxCost", "Максимальная сумма выкупа",
      "Лимит на выкуп всей дешёвой группы лотов одного предмета.", 1, #COST_STEPS, 1,
      function(step)
        local copper = stepToCost(step)
        if copper >= 10000 then return ("%d з"):format(copper / 10000) end
        return ("%d с"):format(copper / 100)
      end, costToStep, stepToCost)
    slider(page, "maxLots", "Максимум лотов под выкуп",
      "Сделки, где дешёвая группа больше стольких лотов, не показываются.", 1, 50, 1, text("%d"))
    slider(page, "outlierFactor", "Отсечение дорогих лотов",
      "Лоты дороже стольких медиан не считаются конкурентами.", 2, 20, 1, text("×%d"))
    levelSlider(page, "minLevel")
    local qualities = {}
    for quality = 1, 4 do qualities[quality] = { quality, _G["ITEM_QUALITY" .. quality .. "_DESC"] } end
    dropdown(page, "minQuality", "Минимальное качество", "Предметы ниже этого качества не показываются.", qualities)
  end,
  function(page) -- «Торговцы»
    slider(page, "vendorMinProfit", "Минимальная прибыль",
      "Прибыль с одной закупки (стака) не меньше этой суммы.", 0, 200, 5, text("%d с"), scaled(100))
    levelSlider(page, "vendorMinLevel")
    checkbox(page, "vendorOnlyZone", "Только текущая зона",
      "Показывать только товары торговцев из зоны, где сейчас персонаж.")
  end,
}

-- Всплывающее окно справа от главного: настройки текущей вкладки и общие внизу.
local function createSettings(f)
  local p = CreateFrame("Frame", "GoldalionSettingsFrame", f, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(p)
  ButtonFrameTemplate_HideButtonBar(p)
  p:SetSize(260, 460)
  p:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, 0)
  p:EnableMouse(true)
  p:Hide()
  tinsert(UISpecialFrames, "GoldalionSettingsFrame")

  local function page()
    local frame = CreateFrame("Frame", nil, p)
    frame:SetPoint("TOPLEFT", p.Inset, "TOPLEFT", 14, -12)
    frame:SetPoint("BOTTOMRIGHT", p.Inset, "BOTTOMRIGHT", -8, 8)
    frame.y = 0
    return frame
  end

  local pages = {}
  for id, build in ipairs(SETTINGS_PAGES) do
    pages[id] = page()
    build(pages[id])
  end
  local common = page()
  common:ClearAllPoints()
  common:SetPoint("BOTTOMLEFT", p.Inset, "BOTTOMLEFT", 14, 8)
  common:SetSize(220, 26)
  checkbox(common, "openWithAuction", "Открывать вместе с аукционом", "Показывать окно Goldalion при открытии аукциона.")

  function p.showPage(id)
    p:SetTitle("Настройки: " .. TABS[id])
    for i, frame in ipairs(pages) do frame:SetShown(i == id) end
  end
  return p
end

---------------------------------------------------------------- окно

function ns.initUI()
  local width = FIRST_CELL_X + 60 -- отступы и полоса прокрутки
  for _, column in ipairs(COLUMNS) do width = width + column[2] + CELL_GAP end

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
  local settings = createSettings(f)
  settingsButton:SetScript("OnClick", function() settings:SetShown(not settings:IsShown()) end)

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
  local arrow = header:CreateTexture(nil, "OVERLAY")
  arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
  local headerTexts = {}

  local function showArrow()
    local text = headerTexts[sortKey]
    arrow:ClearAllPoints()
    if text:GetJustifyH() == "RIGHT" then
      arrow:SetPoint("RIGHT", text, "LEFT", -3, 0)
    else
      arrow:SetPoint("LEFT", text, "RIGHT", 3, 0)
    end
    if sortDesc then arrow:SetTexCoord(0, 1, 0, 1) else arrow:SetTexCoord(0, 1, 1, 0) end
  end

  -- Новая колонка сортируется по убыванию, текстовая — по возрастанию.
  function ns.sortBy(key)
    if key == sortKey then
      sortDesc = not sortDesc
    else
      sortKey, sortDesc = key, key ~= "name" and key ~= "reason"
    end
    showArrow()
    ns.refresh(true)
  end

  local x = FIRST_CELL_X
  for _, column in ipairs(COLUMNS) do
    local key, align = column[1], column[3]
    local button = CreateFrame("Button", nil, header)
    button:SetSize(column[2], 18)
    button:SetPoint("LEFT", x, 0)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint(align) -- без ширины: стрелка прижимается к самому тексту
    text:SetJustifyH(align)
    button:SetScript("OnClick", function() ns.sortBy(key) end)
    headerTexts[key] = text
    x = x + column[2] + CELL_GAP
  end

  local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", f.Inset)

  function ns.refresh(dealsChanged)
    if not f:IsShown() then return end
    status:SetText(ns.status or idleStatus())
    scanButton:SetEnabled(ns.auctionOpen == true and ns.scanning == nil)
    if dealsChanged then
      local deals = currentDeals()
      sortDeals(deals)
      scrollBox:SetDataProvider(CreateDataProvider(deals))
      empty:SetShown(#deals == 0)
      empty:SetText(tab == VENDOR_TAB and not next(ns.db.vendor) and not LibQuestieDB
        and "Открой окно любого торговца: аддон запомнит его товары и цены." or "Сделок нет")
    end
  end

  -- Вкладки под окном: у каждой свой список сделок и свои заголовки колонок.
  for id, title in ipairs(TABS) do
    local button = CreateFrame("Button", "GoldalionFrameTab" .. id, f, "PanelTabButtonTemplate", id)
    button:SetText(title)
    button:SetScript("OnClick", function() ns.selectTab(id) end)
    if id == 1 then button:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 2) end
  end
  PanelTemplates_SetNumTabs(f, #TABS)

  function ns.selectTab(id)
    tab, ns.db.tab = id, id
    PanelTemplates_SetTab(f, id)
    settings.showPage(id)
    for _, column in ipairs(COLUMNS) do headerTexts[column[1]]:SetText(column[3 + id]) end
    showArrow()
    ns.refresh(true)
  end
  ns.selectTab(ns.db.tab or 1)

  function ns.toggleUI(show)
    if show == nil then show = not f:IsShown() end
    f:SetShown(show)
  end

  f:SetScript("OnShow", function() ns.refresh(true) end)
end
