-- Полный скан аукциона, история цен, товары торговцев и пересчёт сделок обоих режимов.
--   /gold        показать или скрыть окно
--   /gold scan   полный скан (аукцион должен быть открыт)

local ADDON, ns = ...
local AH = C_AuctionHouse
local frame = CreateFrame("Frame")

local BATCH = 500           -- лотов за кадр
local RETRY_PASSES = 5      -- повторных проходов по лотам без данных предмета
local MIN_QUALITY_KEPT = 1  -- серое не храним вообще

local db
local t0, total, lotsByKey, infoByKey, deferred, requested

-- UI.lua подменяет: refresh(true) — изменился список сделок, refresh() — только статус.
ns.refresh = function() end
ns.toggleUI = function() end

local function say(...)
  print("|cffffd100Goldalion:|r", ...)
end

local function setStatus(text)
  ns.status = text
  ns.refresh()
end

function ns.money(copper)
  copper = math.floor(copper + 0.5)
  local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
  if gold > 0 then return ("%dз %dс"):format(gold, silver) end
  if silver > 0 then return ("%dс %dм"):format(silver, copper % 100) end
  return ("%dм"):format(copper)
end

-- Стартовые данные о товаре торговца, пока игрок сам к нему не зашёл: цена из VendorPrices.lua,
-- а кто продаёт — из базы Questie, если она установлена. Запас и скидка за репутацию неизвестны.
local QUESTIE_CONTRACT = 4
local seeds = {} -- itemID → запись или false

local function lookupSeed(itemID)
  local price, questie = ns.vendorPrice[itemID], LibQuestieDB
  if not (price and questie and questie.RequireContract(QUESTIE_CONTRACT)) then return false end
  local faction = UnitFactionGroup("player") == "Horde" and "H" or "A"
  local sellers = {}
  for _, npcID in ipairs(questie.Item.vendors(itemID) or {}) do
    local friendly = questie.Npc.friendlyToFaction(npcID)
    if not friendly or friendly:find(faction, 1, true) then
      local area = questie.Npc.zoneID(npcID)
      sellers[#sellers + 1] = { npc = questie.Npc.name(npcID) or "?", zone = area and C_Map.GetAreaInfo(area) or "" }
    end
  end
  return #sellers > 0 and { price = price, stack = ns.vendorStack[itemID] or 1, seed = true, sellers = sellers }
end

function ns.seedVendor(itemID)
  if seeds[itemID] == nil then
    -- чужой аддон: его ошибка не должна ронять пересчёт
    local ok, seed = pcall(lookupSeed, itemID)
    seeds[itemID] = ok and seed or false
  end
  return seeds[itemID]
end

-- Требуемый уровень запоминается в сделке: фильтр по нему применяет окно, без пересчёта.
-- nil, если данных предмета нет в кеше.
local function requiredLevel(itemID)
  return (select(5, C_Item.GetItemInfo(itemID)))
end

-- Пересчитывает сделки по лотам последнего скана с текущими настройками.
function ns.evaluate()
  local scan = ns.scan
  if not scan then return end -- после /reload лотов в памяти нет: остаётся сохранённый список
  local opts, deals = ns.opts, {}
  for key, lots in pairs(scan.lots) do
    local info = scan.info[key]
    if info.quality >= opts.minQuality then
      local hist = ns.historyMedian(scan.history[key], opts.minHistoryDays, scan.day)
      local deal = ns.findDeal(lots, hist, opts)
      if deal then
        deal.key, deal.link, deal.level = key, info.link, requiredLevel(info.itemID)
        deals[#deals + 1] = deal
      end
    end
  end
  table.sort(deals, function(a, b) return a.profit > b.profit end)
  db.lastDeals = deals

  -- Режим «торговцы»: качество не фильтруется, предмет может отсутствовать на аукционе.
  local vendorDeals, here = {}, opts.vendorOnlyZone and GetRealZoneText()
  local function consider(key, itemID, vendor, link)
    -- у запомненного товара торговец один, у стартовых данных — все из базы
    local seller, count = nil, 0
    for _, s in ipairs(vendor.sellers or { vendor }) do
      if not here or s.zone == here then
        seller, count = seller or s, count + 1
      end
    end
    if not seller then return end
    local hist = ns.historyMedian(scan.history[key], opts.minHistoryDays, scan.day)
    local deal = ns.findVendorDeal(scan.lots[key] or {}, hist, vendor, opts)
    if deal then
      deal.key, deal.link, deal.reason, deal.zone = key, link, seller.npc, seller.zone
      deal.seed, deal.others, deal.level = vendor.seed, count - 1, requiredLevel(itemID)
      vendorDeals[#vendorDeals + 1] = deal
    end
  end
  for itemID, vendor in pairs(db.vendor) do
    consider(itemID .. ":" .. (vendor.link:match("%[(.-)%]") or ""), itemID, vendor, vendor.link)
  end
  -- Товары, которых игрок у торговцев ещё не видел. В истории есть и все предметы текущего скана.
  for key in pairs(scan.history) do
    local id, name = key:match("^(%d+):(.*)")
    local itemID = tonumber(id)
    local vendor = itemID and not db.vendor[itemID] and ns.seedVendor(itemID)
    if vendor then
      local info = scan.info[key]
      consider(key, itemID, vendor, info and info.link or ("|Hitem:%d|h[%s]|h"):format(itemID, name))
    end
  end
  table.sort(vendorDeals, function(a, b) return a.profit > b.profit end)
  db.vendorDeals = vendorDeals
end

-- Запоминает товары открытого торговца: только то, что продаётся за деньги.
-- Цена — та, что видит этот персонаж (со скидкой за репутацию).
local function recordMerchant()
  local npc, zone, added = UnitName("npc") or "?", GetRealZoneText() or "", 0
  for i = 1, GetMerchantNumItems() do
    local info, itemID, link = C_MerchantFrame.GetItemInfo(i), GetMerchantItemID(i), GetMerchantItemLink(i)
    if info and itemID and link and info.price > 0 and info.stackCount > 0 and not info.hasExtendedCost then
      local price, known = info.price / info.stackCount, db.vendor[itemID]
      -- у разных торговцев цена может отличаться: держим самого дешёвого
      if not known or price <= known.price or known.npc == npc then
        if not known then added = added + 1 end
        db.vendor[itemID] = { price = price, stack = GetMerchantItemMaxStack(i) or 1,
                              limited = info.numAvailable >= 0 or nil, -- −1 значит «без ограничения»
                              npc = npc, zone = zone, link = link }
      end
    end
  end
  if added > 0 then
    say(("запомнил новых товаров торговца: %d (%s)"):format(added, npc))
    ns.optionsChanged()
  end
end

-- Цены этого же предмета с другими суффиксами по последнему скану:
-- минимум, медиана, число лотов, число вариантов. nil, если других вариантов нет.
function ns.variantStats(key)
  local scan = ns.scan
  local info = scan and scan.info[key]
  if not info then return nil end
  local prices, variants = {}, 0
  for _, other in ipairs(scan.byItem[info.itemID]) do
    if other ~= key then
      variants = variants + 1
      for _, lot in ipairs(scan.lots[other]) do prices[#prices + 1] = lot.price end
    end
  end
  if variants == 0 then return nil end
  table.sort(prices)
  return prices[1], ns.median(prices), #prices, variants
end

-- Настройки меняются ползунком, поэтому пересчёт откладываем и склеиваем.
local evaluatePending
function ns.optionsChanged()
  if evaluatePending then return end
  evaluatePending = true
  C_Timer.After(0.3, function()
    evaluatePending = false
    ns.evaluate()
    ns.refresh(true)
  end)
end

-- false, если данные предмета ещё не загружены и лот надо перечитать позже.
local function addLot(index)
  local _, _, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo = AH.GetReplicateItemInfo(index)
  if not itemID then return true end
  if not hasAllInfo then
    if not requested[itemID] then
      requested[itemID] = true
      C_Item.RequestLoadItemDataByID(itemID)
    end
    return false
  end
  if buyout == 0 or count == 0 or quality < MIN_QUALITY_KEPT then return true end

  -- Вариант предмета (суффикс) различаем по названию из ссылки.
  local link = AH.GetReplicateItemLink(index)
  local name = link and link:match("%[(.-)%]")
  if not name then return true end
  local key = itemID .. ":" .. name

  local lots = lotsByKey[key]
  if not lots then
    lots = {}
    lotsByKey[key], infoByKey[key] = lots, { link = link, quality = quality, itemID = itemID }
  end
  lots[#lots + 1] = { price = buyout / count, count = count }
  return true
end

local function finishScan()
  local day = math.floor(time() / 86400)
  local faction = UnitFactionGroup("player")
  -- ponytail: история делится только по фракции; добавить набор правил в ключ, если играешь на нескольких
  db.history[faction] = db.history[faction] or {}
  local history = db.history[faction]

  local items, byItem = 0, {} -- byItem: itemID → ключи всех его вариантов (суффиксов)
  for key, lots in pairs(lotsByKey) do
    items = items + 1
    local itemID = infoByKey[key].itemID
    byItem[itemID] = byItem[itemID] or {}
    table.insert(byItem[itemID], key)
    local min = lots[1].price
    for i = 2, #lots do
      if lots[i].price < min then min = lots[i].price end
    end
    local days = history[key] or {}
    history[key] = days
    if not days[day] or min < days[day] then days[day] = min end
  end

  for key, days in pairs(history) do
    for d in pairs(days) do
      if d <= day - ns.opts.historyDays then days[d] = nil end
    end
    if not next(days) then history[key] = nil end
  end

  -- ponytail: лоты последнего скана остаются в памяти до следующего скана или /reload (десятки МБ
  -- на 180 тыс. лотов), чтобы настройки применялись без рескана; перейти на плоские массивы, если мешает
  ns.scan = { lots = lotsByKey, info = infoByKey, byItem = byItem, history = history, day = day }
  db.lastScan = { time = time(), lots = total, items = items, withoutItemData = #deferred, seconds = GetTime() - t0 }
  ns.scanning, ns.status = nil, nil
  lotsByKey, infoByKey, deferred, requested = nil, nil, nil, nil
  ns.evaluate()
  ns.refresh(true)
end

-- Читает лоты из списка индексов пачками по кадрам; лоты без данных предмета перечитывает позже.
local function read(list, pos, passes)
  if ns.scanning ~= "read" then return end
  local last = math.min(pos + BATCH - 1, #list)
  for i = pos, last do
    if not addLot(list[i]) then deferred[#deferred + 1] = list[i] end
  end
  if last < #list then
    if passes == RETRY_PASSES then
      setStatus(("Читаю лоты: %d%%"):format(math.floor(last / #list * 100)))
    end
    C_Timer.After(0, function() read(list, last + 1, passes) end)
  elseif #deferred > 0 and passes > 0 then
    local again = deferred
    deferred = {}
    setStatus(("Догружаю данные предметов, осталось лотов: %d"):format(#again))
    C_Timer.After(1, function() read(again, 1, passes - 1) end)
  else
    finishScan()
  end
end

function ns.startScan()
  if not ns.auctionOpen or ns.scanning then return end
  ns.scanning, t0 = "wait", GetTime()
  local started = t0
  AH.ReplicateItems()
  setStatus("Жду ответа сервера (около 30 с)…")
  C_Timer.After(90, function()
    if ns.scanning == "wait" and t0 == started then
      ns.scanning = nil
      setStatus(nil)
      say("нет ответа за 90 с — возможно, кулдаун полного скана (в retail 15 минут)")
    end
  end)
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_UPDATE") -- данные товаров догружаются уже после MERCHANT_SHOW
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA") -- для фильтра «только текущая зона»
frame:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" then
    if name == ADDON then
      GoldalionDB = GoldalionDB or {}
      db = GoldalionDB
      db.history = db.history or {}
      db.lastDeals = db.lastDeals or {}
      db.vendor = db.vendor or {}           -- itemID → товар торговца
      db.vendorDeals = db.vendorDeals or {}
      db.opts = db.opts or {}
      ns.db = db
      -- В db.opts лежит только то, что игрок поменял; остальное берётся из значений по умолчанию.
      ns.defaults = ns.opts
      ns.opts = setmetatable(db.opts, { __index = ns.defaults })
      if ns.initUI then ns.initUI() end
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    ns.auctionOpen = true
    if ns.opts.openWithAuction then ns.toggleUI(true) end
    ns.refresh()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ns.auctionOpen = false
    if ns.scanning then
      ns.scanning = nil
      say("аукцион закрыт, скан прерван")
    end
    setStatus(nil)
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    recordMerchant()
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    if ns.opts.vendorOnlyZone then ns.optionsChanged() end
  elseif ns.scanning == "wait" then -- первый REPLICATE_ITEM_LIST_UPDATE; дальше он сыплется на каждый догруженный предмет
    ns.scanning, total = "read", AH.GetNumReplicateItems()
    lotsByKey, infoByKey, deferred, requested = {}, {}, {}, {}
    local list = {}
    for i = 1, total do list[i] = i - 1 end -- индексы лотов с нуля
    read(list, 1, RETRY_PASSES)
  end
end)

SLASH_GOLDALION1 = "/gold"
SlashCmdList.GOLDALION = function(msg)
  if msg == "scan" then
    if not ns.auctionOpen then return say("сначала открой аукцион") end
    ns.toggleUI(true)
    ns.startScan()
  else
    ns.toggleUI()
  end
end
