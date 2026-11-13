-- lua tests/goldalion_test.lua
-- 1) правила режима 1 на цифрах из docs/requirements.md; 2) сквозной прогон скана на заглушках API.

local ns = {}
assert(loadfile("Goldalion/Deals.lua"))("Goldalion", ns)
local opts = ns.opts

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
local proxies, rowInit, shown, provider = {}, nil, false, nil
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
}

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
Settings = setmetatable({
  RegisterProxySetting = function(_, variable, _, _, default, get, set)
    proxies[variable] = { default = default, get = get, set = set }
    return dummy()
  end,
}, dummyMeta)
function UnitFactionGroup() return "Horde" end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Item = {
  RequestLoadItemDataByID = function() end,
  GetItemInfoInstant = function() return 1, "", "", "", 134400, 4, 0 end,
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
assert(ns.opts == db.opts and ns.opts.minDiscount == 0.5, "настройки по умолчанию видны через сохранённые")
assert(proxies.GOLDALION_minDiscount.default == 50 and proxies.GOLDALION_minDiscount.get() == 50)
assert(proxies.GOLDALION_minProfit.get() == 50 and proxies.GOLDALION_maxLots.get() == 10)
-- Сумма выкупа: 13 ступеней от 10 с до 1000 з, 2 з — пятая.
assert(proxies.GOLDALION_maxCost.default == 5 and proxies.GOLDALION_maxCost.get() == 5)
proxies.GOLDALION_maxCost.set(1)
assert(ns.opts.maxCost == 1000)
proxies.GOLDALION_maxCost.set(13)
assert(ns.opts.maxCost == 10000000 and proxies.GOLDALION_maxCost.get() == 13)
proxies.GOLDALION_maxCost.set(5)
assert(ns.opts.maxCost == 20000)
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
assert(db.lastScan.lots == #AUCTIONS and db.lastScan.items == 3 and db.lastScan.withoutItemData == 0)
assert(provider == db.lastDeals, "список в окне обновлён после скана")

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
proxies.GOLDALION_minQuality.set(1)
runTimers()
assert(#db.lastDeals == 2 and rawget(db.opts, "minQuality") == 1, "белая ткань появилась в списке")
proxies.GOLDALION_minDiscount.set(99)
runTimers()
assert(ns.opts.minDiscount == 0.99 and #db.lastDeals == 0 and provider == db.lastDeals)
proxies.GOLDALION_minDiscount.set(50)
proxies.GOLDALION_openWithAuction.set(false)
runTimers()
assert(#db.lastDeals == 2 and ns.opts.openWithAuction == false)

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
