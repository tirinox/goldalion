-- lua tests/goldalion_test.lua
-- 1) правила режимов 1 и 2 на цифрах из docs/requirements.md; 2) сквозной прогон скана на заглушках API.

local ns = {}
assert(loadfile("Goldalion/VendorPrices.lua"))("Goldalion", ns)
assert(loadfile("Goldalion/Deals.lua"))("Goldalion", ns)
local opts = ns.opts

-- Сгенерированные цены: грубая нить 10 м, пустой флакон 20 м за пять штук, стак 20.
assert(ns.vendorPrice[2320] == 10 and ns.vendorPrice[3371] == 4 and ns.vendorStack[3371] == 20)
assert(ns.vendorStack[6217] == nil, "предметы со стаком 1 в таблицу стаков не попадают")

local function lots(...)
  local list = {}
  for i, price in ipairs({ ... }) do list[i] = { price = price, count = 1 } end
  return list
end

---------------------------------------------------------------- правила

-- Пример из требований: 20 с и 25 с, дальше два лота по 1 з.
local d = ns.findDeal(lots(2000, 2500, 10000, 10000), nil, opts)
assert(d.lots == 2 and d.cost == 4500 and d.ref == 10000 and d.reason == "neighbors")
assert(d.profit == 2 * 10000 * 0.95 - 4500)
assert(math.abs(d.discount - 0.775) < 1e-9)

-- Пара «10 с и 1 з» без истории — не сделка; с историей — сделка по меньшей из цен.
assert(ns.findDeal(lots(1000, 10000), nil, opts) == nil)
d = ns.findDeal(lots(1000, 10000), 9000, opts)
assert(d.ref == 9000 and d.reason == "history" and d.lots == 1)

-- Единственный лот оценивается по истории: ожерелье за 50 с при обычных 2 з.
d = ns.findDeal(lots(5000), 20000, opts)
assert(d.lots == 1 and d.profit == 20000 * 0.95 - 5000)
assert(ns.findDeal(lots(5000), nil, opts) == nil)

-- Завышенный лот дороже 5 медиан не становится опорной ценой.
assert(ns.findDeal(lots(2000, 2500, 3000, 50000), nil, opts) == nil)

-- Сумма выкупа всей группы больше лимита 2 з.
assert(ns.findDeal(lots(15000, 15000, 100000, 100000), nil, opts) == nil)

-- Из нескольких разрывов берётся самый прибыльный: группа из трёх лотов против 1 з.
d = ns.findDeal(lots(100, 2000, 2200, 10000, 10000), nil, opts)
assert(d.lots == 3 and d.cost == 4300 and d.ref == 10000)

-- В дешёвой группе больше 10 лотов: 11 дешёвых против 12 дорогих — не сделка, 10 дешёвых — сделка.
local function group(cheap)
  local prices = {}
  for i = 1, cheap do prices[i] = 100 end
  for i = 1, 12 do prices[cheap + i] = 10000 end
  return lots(table.unpack(prices))
end
assert(ns.findDeal(group(11), nil, opts) == nil)
assert(ns.findDeal(group(10), nil, opts).lots == 10)

-- Прибыль меньше 50 с.
assert(ns.findDeal(lots(100, 300, 300), nil, opts) == nil)

-- Стак: цена за штуку, а выкуп и прибыль считаются за весь стак.
d = ns.findDeal({ { price = 1000, count = 20 }, { price = 5000, count = 1 }, { price = 5000, count = 1 } }, nil, opts)
assert(d.units == 20 and d.cost == 20000 and d.profit == 20 * 5000 * 0.95 - 20000)

-- Историческая медиана требует минимум трёх дней.
assert(ns.historyMedian({ [1] = 100, [2] = 300 }, 3) == nil)
assert(ns.historyMedian({ [1] = 100, [2] = 300, [5] = 200 }, 3) == 200)
assert(ns.historyMedian(nil, 3) == nil)

---------------------------------------------------------------- режим «торговцы»

-- Пример из требований: нить по 10 м у торговца, на аукционе от 1 с, стак 20.
local thread = { price = 10, stack = 20 }
d = ns.findVendorDeal({ { price = 100, count = 5 }, { price = 150, count = 1 } }, nil, thread, opts)
assert(d.units == 20 and d.cost == 200 and d.ref == 100 and d.min == 100 and d.lots == 6)
assert(d.profit == 20 * 100 * 0.95 - 200 and math.abs(d.discount - 0.9) < 1e-9)

-- Прибыль со стака меньше 10 с.
assert(ns.findVendorDeal(lots(50), nil, thread, opts) == nil)

-- На аукционе нет: без истории цена неизвестна, с историей берётся она.
assert(ns.findVendorDeal({}, nil, thread, opts) == nil)
d = ns.findVendorDeal({}, 200, thread, opts)
assert(d.ref == 200 and d.min == nil and d.lots == 0)

-- Единственный завышенный лот: история ниже, берётся она.
d = ns.findVendorDeal(lots(1000), 100, thread, opts)
assert(d.ref == 100 and d.min == 1000)

-- Ограниченный запас: считается одна штука, даже если предмет складывается.
d = ns.findVendorDeal(lots(50000), nil, { price = 2000, stack = 20, limited = true }, opts)
assert(d.units == 1 and d.limited and d.profit == 50000 * 0.95 - 2000)

---------------------------------------------------------------- сквозной скан и окно

-- День skipDay в исторической медиане не учитывается.
assert(ns.historyMedian({ [1] = 100, [2] = 300, [5] = 200 }, 3, 5) == nil)

-- Заглушка виджета: любое поле — такая же заглушка, любой вызов возвращает заглушку.
local dummyMeta = {}
local function dummy() return setmetatable({}, dummyMeta) end
dummyMeta.__index = function(t, k)
  if k == "created" then return nil end -- флаг одноразовой инициализации строки
  local v = dummy()
  rawset(t, k, v)
  return v
end
dummyMeta.__call = function() return dummy() end

local handler, timers, loaded = nil, {}, false
local rowInit, shown, provider = nil, false, nil
local MONKEY, WHALE = "Перчатки обезьяны", "Перчатки кита"
-- { название, количество, качество, выкуп, itemID, данные загружены сразу }
local AUCTIONS = {
  { MONKEY, 1, 2, 2000, 100, true },
  { MONKEY, 1, 2, 2500, 100, true },
  { MONKEY, 1, 2, 10000, 100, true },
  { MONKEY, 1, 2, 10000, 100, false }, -- второй конкурент появится только после догрузки
  { WHALE, 1, 2, 9000, 100, true },    -- тот же itemID, другой суффикс: отдельный предмет
  { WHALE, 1, 2, 9500, 100, true },
  { "Ткань", 1, 1, 200, 500, true },   -- белое: хранится, но скрыто настройкой качества
  { "Ткань", 1, 1, 9000, 500, true },
  { "Ткань", 1, 1, 9000, 500, true },
  { "Хлам", 1, 0, 1, 300, true },      -- серое не хранится
  { "Без выкупа", 1, 2, 0, 400, true },
  { "Нить", 5, 1, 500, 600, true },    -- товар торговца: 1 с за штуку
  { "Нить", 1, 1, 120, 600, true },
  { "Мука", 2, 1, 400, 700, true },    -- у торговца игрок её не видел: цена и продавец из баз
  { "Мука", 1, 1, 200, 700, true },
}
ns.vendorPrice[700], ns.vendorStack[700] = 25, 20
ns.vendorPrice[500] = 1 -- у ткани есть цена покупки, но Questie не знает её торговцев
-- Заглушка Questie: муку продают три NPC, первый — только Альянсу.
LibQuestieDB = {
  RequireContract = function(version) return version == 4 end,
  Item = { vendors = function(id) return id == 700 and { 11, 12, 13 } or nil end },
  Npc = {
    friendlyToFaction = function(id) return ({ [11] = "A", [12] = "AH", [13] = "H" })[id] end,
    name = function(id) return "Пекарь " .. id end,
    zoneID = function() return 1637 end,
  },
}
C_Map = { GetAreaInfo = function(area) return "Зона " .. area end }
-- { название, itemID, цена за пачку, штук в пачке, запас (−1 — без ограничения), стак, цена не только в деньгах }
local MERCHANT = {
  { "Нить", 600, 50, 5, -1, 20 },
  { "Рецепт", 601, 2000, 1, 1, 1 },    -- на аукционе его нет и не было: цена неизвестна
  { "За жетоны", 602, 100, 1, -1, 1, true },
}
local npcName = "Лавочник"
function UnitName() return npcName end
local zoneName = "Оргриммар"
function GetRealZoneText() return zoneName end
function GetMerchantNumItems() return #MERCHANT end
function GetMerchantItemID(i) return MERCHANT[i][2] end
function GetMerchantItemLink(i) return "|cnIQ1:|Hitem:1|h[" .. MERCHANT[i][1] .. "]|h|r" end
function GetMerchantItemMaxStack(i) return MERCHANT[i][6] end
C_MerchantFrame = {
  GetItemInfo = function(i)
    local m = MERCHANT[i]
    return { name = m[1], price = m[3], stackCount = m[4], numAvailable = m[5], hasExtendedCost = m[7] or false }
  end,
}
function PanelTemplates_SetNumTabs() end
function PanelTemplates_SetTab() end

print = function() end
SlashCmdList, UISpecialFrames, UIParent = {}, {}, dummy()
tinsert, time, GetTime = table.insert, os.time, os.clock
GameTooltip = dummy()
function HandleModifiedItemClick() return false end
function ButtonFrameTemplate_HidePortrait() end
function ButtonFrameTemplate_HideButtonBar() end
function CreateDataProvider(list) return list end
MinimalSliderWithSteppersMixin = dummy()
ScrollUtil = dummy()
function CreateScrollBoxListLinearView()
  local view = dummy()
  view.SetElementInitializer = function(_, _, init) rowInit = init end
  return view
end
function CreateFrame(_, name, _, template)
  local f = dummy()
  f.SetScript = function(_, script, fn) if script == "OnEvent" then handler = fn end end
  if name == "GoldalionFrame" then
    f.IsShown = function() return shown end
    f.SetShown = function(_, value) shown = value end
  elseif template == "WowScrollBoxList" then
    f.SetDataProvider = function(_, list) provider = list end
  end
  return f
end
function UnitFactionGroup() return "Horde" end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Item = {
  RequestLoadItemDataByID = function() end,
  GetItemInfoInstant = function() return 1, "", "", "", 134400, 4, 0 end,
  -- требуемый уровень: перчатки 20-го, остальное без ограничения
  GetItemInfo = function(id) return "", "", 1, 1, id == 100 and 20 or 0 end,
}
C_AuctionHouse = {
  ReplicateItems = function() end,
  GetNumReplicateItems = function() return #AUCTIONS end,
  GetReplicateItemInfo = function(i)
    local a = AUCTIONS[i + 1]
    return a[1], 1, a[2], a[3], true, 1, "", 0, 0, a[4], 0, nil, nil, nil, nil, 0, a[5], a[6] or loaded
  end,
  GetReplicateItemLink = function(i) return "|cnIQ2:|Hitem:1|h[" .. AUCTIONS[i + 1][1] .. "]|h|r" end,
}

assert(loadfile("Goldalion/Scan.lua"))("Goldalion", ns)
assert(loadfile("Goldalion/UI.lua"))("Goldalion", ns)
local function fire(event, ...) handler(nil, event, ...) end
local function runTimers()
  while #timers > 0 do table.remove(timers, 1)() end
end

fire("ADDON_LOADED", "Goldalion")
local db = GoldalionDB
local controls = ns.settingControls
assert(ns.opts == db.opts and ns.opts.minDiscount == 0.5, "настройки по умолчанию видны через сохранённые")
assert(controls.minDiscount.get() == 50)
assert(controls.minProfit.get() == 50 and controls.maxLots.get() == 10)
-- Сумма выкупа: 13 ступеней от 10 с до 1000 з, 2 з — пятая.
assert(controls.maxCost.get() == 5)
controls.maxCost.set(1)
assert(ns.opts.maxCost == 1000)
controls.maxCost.set(13)
assert(ns.opts.maxCost == 10000000 and controls.maxCost.get() == 13)
controls.maxCost.set(5)
assert(ns.opts.maxCost == 20000)

-- Окно торговца: товары за деньги запоминаются с ценой за штуку, товар за жетоны — нет.
fire("MERCHANT_SHOW")
local known = db.vendor[600]
assert(known.price == 10 and known.stack == 20 and known.limited == nil and known.npc == "Лавочник")
assert(db.vendor[601].limited == true and db.vendor[602] == nil)
-- Другой торговец продаёт дороже: остаётся дешёвый. Тот же торговец поднял цену: запись обновляется.
npcName, MERCHANT[1][3] = "Барыга", 100
fire("MERCHANT_UPDATE")
assert(db.vendor[600].price == 10 and db.vendor[600].npc == "Лавочник")
npcName = "Лавочник"
fire("MERCHANT_SHOW")
assert(db.vendor[600].price == 20)
MERCHANT[1][3] = 50
fire("MERCHANT_SHOW")
assert(db.vendor[600].price == 10)
runTimers()

ns.startScan()
assert(ns.scanning == nil, "без открытого аукциона скан не стартует")

fire("AUCTION_HOUSE_SHOW")
assert(shown == true, "окно открывается вместе с аукционом")
ns.startScan()
assert(ns.scanning == "wait" and ns.status)
fire("REPLICATE_ITEM_LIST_UPDATE")
fire("REPLICATE_ITEM_LIST_UPDATE") -- повторное событие не должно начать чтение заново
loaded = true                      -- данные предмета догрузились перед повторным проходом
runTimers()

assert(ns.scanning == nil and ns.status == nil)
assert(#db.lastDeals == 1, "ожидалась одна сделка, получено " .. #db.lastDeals)
local deal = db.lastDeals[1]
assert(deal.link:find(MONKEY, 1, true) and deal.lots == 2 and deal.cost == 4500 and deal.ref == 10000)
assert(db.lastScan.lots == #AUCTIONS and db.lastScan.items == 5 and db.lastScan.withoutItemData == 0)
assert(provider == db.lastDeals, "список в окне обновлён после скана")

-- Вкладка «Торговцы»: нить по 10 м у торговца против 1 с на аукционе; рецепт без цены не показан.
-- Мука по 25 м из таблицы цен против 2 с на аукционе; продавец из Questie, подходящий Орде.
assert(#db.vendorDeals == 2, "ожидались две сделки торговцев, получено " .. #db.vendorDeals)
local seedDeal, vendorDeal = db.vendorDeals[1], db.vendorDeals[2]
assert(seedDeal.link:find("Мука", 1, true) and seedDeal.seed == true and seedDeal.price == 25)
assert(seedDeal.reason == "Пекарь 12" and seedDeal.zone == "Зона 1637" and seedDeal.others == 1)
assert(seedDeal.units == 20 and seedDeal.cost == 500 and seedDeal.ref == 200 and seedDeal.lots == 3)
assert(vendorDeal.link:find("Нить", 1, true) and vendorDeal.reason == "Лавочник" and vendorDeal.zone == "Оргриммар")
assert(vendorDeal.units == 20 and vendorDeal.cost == 200 and vendorDeal.ref == 100 and vendorDeal.lots == 6)
assert(vendorDeal.seed == nil, "увиденный у торговца товар не помечается как непроверенный")
ns.selectTab(2)
assert(provider == db.vendorDeals and db.tab == 2, "вкладка показывает свой список")
local vendorRow = dummy()
rowInit(vendorRow, vendorDeal)
assert(vendorRow.deal == vendorDeal)
controls.vendorMinProfit.set(50)
runTimers()
assert(ns.opts.vendorMinProfit == 5000 and #db.vendorDeals == 0 and provider == db.vendorDeals)
controls.vendorMinProfit.set(10)
runTimers()
assert(#db.vendorDeals == 2)
-- Требуемый уровень: у нити и муки его нет, фильтр уровня их прячет.
controls.vendorMinLevel.set(1)
runTimers()
assert(#provider == 0 and #db.vendorDeals == 2, "фильтр уровня прячет строки, список не пересчитывается")
controls.vendorMinLevel.set(0)
-- Только текущая зона: в Оргриммаре — нить, в зоне пекарей — мука, оба пекаря-продавца Орды.
controls.vendorOnlyZone.set(true)
runTimers()
assert(#db.vendorDeals == 1 and db.vendorDeals[1].reason == "Лавочник")
zoneName = "Зона 1637"
fire("ZONE_CHANGED_NEW_AREA")
runTimers()
assert(#db.vendorDeals == 1 and db.vendorDeals[1].reason == "Пекарь 12" and db.vendorDeals[1].others == 1)
zoneName = "Оргриммар"
controls.vendorOnlyZone.set(false)
runTimers()
assert(#db.vendorDeals == 2)
fire("ZONE_CHANGED_NEW_AREA") -- фильтр выключен: пересчёта нет
assert(#timers == 0)
-- Игрок дошёл до торговца мукой: его цена заменяет стартовую.
MERCHANT[#MERCHANT + 1] = { "Мука", 700, 30, 1, -1, 20 }
fire("MERCHANT_SHOW")
runTimers()
seedDeal = db.vendorDeals[1]
assert(seedDeal.link:find("Мука", 1, true) and seedDeal.seed == nil and seedDeal.price == 30 and seedDeal.reason == "Лавочник")
-- Без Questie или при его ошибке стартовых данных нет, пересчёт не падает.
LibQuestieDB.Item.vendors = function() error("сломано") end
assert(ns.seedVendor(701) == false and ns.seedVendor(700).sellers[1].npc == "Пекарь 12", "ответ по предмету кешируется")
ns.selectTab(1)
assert(provider == db.lastDeals)

local day = math.floor(os.time() / 86400)
assert(db.history.Horde["100:" .. MONKEY][day] == 2000 and db.history.Horde["100:" .. WHALE][day] == 9000)
assert(db.history.Horde["500:Ткань"][day] == 200, "история пишется и для белых предметов")

-- Цены того же предмета с другими суффиксами: у «обезьяны» это два лота «кита».
local min, median, lotCount, variants = ns.variantStats(deal.key)
assert(min == 9000 and median == 9250 and lotCount == 2 and variants == 1)
assert(ns.variantStats("500:Ткань") == nil and ns.variantStats(nil) == nil, "вариант один — статистики нет")

-- Строка списка заполняется без ошибок.
local row = dummy()
rowInit(row, deal)
assert(row.deal == deal and row.created == true)
assert(ns.money(4500) == "45с 0м" and ns.money(14500) == "1з 45с" and ns.money(7) == "7м")

-- Смена настроек пересчитывает сделки без нового скана.
controls.minQuality.set(1)
runTimers()
assert(#db.lastDeals == 2 and rawget(db.opts, "minQuality") == 1, "белая ткань появилась в списке")
controls.minDiscount.set(99)
runTimers()
assert(ns.opts.minDiscount == 0.99 and #db.lastDeals == 0 and provider == db.lastDeals)
controls.minDiscount.set(50)
controls.openWithAuction.set(false)
runTimers()
assert(#db.lastDeals == 2 and ns.opts.openWithAuction == false)
-- Требуемый уровень: перчатки 20-го проходят фильтр 20 и отсекаются фильтром 21, ткань без уровня — нет.
-- Лотов в памяти нет, как после /reload: фильтр работает по сохранённому списку.
local scan = ns.scan
ns.scan = nil
controls.minLevel.set(20)
runTimers()
assert(#provider == 1 and provider[1].link:find(MONKEY, 1, true) and #db.lastDeals == 2)
controls.minLevel.set(21)
runTimers()
assert(#provider == 0)
controls.minLevel.set(0)
runTimers()
assert(provider == db.lastDeals and #provider == 2)
ns.scan = scan

-- Клик по заголовку сортирует список: новая колонка по убыванию, повторный клик — по возрастанию,
-- текстовая колонка сразу по возрастанию.
ns.sortBy("cost")
assert(db.lastDeals[1].cost == 4500 and db.lastDeals[2].cost == 200 and provider == db.lastDeals)
ns.sortBy("cost")
assert(db.lastDeals[1].cost == 200 and db.lastDeals[2].cost == 4500)
ns.sortBy("name")
assert(db.lastDeals[1].link:find(MONKEY, 1, true) and db.lastDeals[2].link:find("Ткань", 1, true))
ns.sortBy("name")
assert(db.lastDeals[1].link:find("Ткань", 1, true))
ns.sortBy("profit")
assert(db.lastDeals[1].profit >= db.lastDeals[2].profit)

-- Выключенная настройка не открывает окно; /gold переключает его.
shown = false
fire("AUCTION_HOUSE_CLOSED")
fire("AUCTION_HOUSE_SHOW")
assert(shown == false)
SlashCmdList.GOLDALION("")
assert(shown == true)

-- Устаревшие дни истории вычищаются при следующем скане, предметы без дней удаляются.
db.history.Horde["999:Старый"] = { [day - 30] = 5 }
ns.startScan()
fire("REPLICATE_ITEM_LIST_UPDATE")
runTimers()
assert(db.history.Horde["999:Старый"] == nil)

-- Закрытие аукциона посреди скана прерывает его.
ns.startScan()
fire("AUCTION_HOUSE_CLOSED")
assert(ns.scanning == nil and ns.status == nil)

io.write("ok\n")
