-- Режим 1 «большая скидка»: правила в docs/requirements.md.
-- Чистая логика без API игры, проверяется в tests/goldalion_test.lua.

local _, ns = ...

-- Значения по умолчанию, цены в меди. После загрузки ns.opts — сохранённые настройки
-- игрока, а эта таблица остаётся в ns.defaults.
ns.opts = {
  minDiscount = 0.5,     -- лот должен стоить не больше 50% опорной цены
  minProfit = 50 * 100,  -- 50 с
  maxCost = 2 * 10000,   -- 2 з за выкуп всей дешёвой группы
  maxLots = 10,          -- не больше стольких лотов в дешёвой группе
  minQuality = 2,        -- необычное
  outlierFactor = 5,     -- лоты дороже 5 медиан не считаются конкурентами
  confirmSpread = 1.2,   -- второй конкурент должен стоить не дороже 120% первого
  minHistoryDays = 3,
  historyDays = 14,
  -- ponytail: комиссия 5% взята из Classic и в Forever не проверена; сверить по первому письму о продаже
  cut = 0.05,
  openWithAuction = true, -- показывать окно при открытии аукциона
}

function ns.median(sorted)
  local n = #sorted
  if n % 2 == 1 then return sorted[(n + 1) / 2] end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- days: { [день] = минимальная цена }. День skipDay (сегодняшний) не учитывается.
-- nil, если дней меньше minDays.
function ns.historyMedian(days, minDays, skipDay)
  local prices = {}
  for day, price in pairs(days or {}) do
    if day ~= skipDay then prices[#prices + 1] = price end
  end
  if #prices < minDays then return nil end
  table.sort(prices)
  return ns.median(prices)
end

-- lots: массив { price = цена за штуку, count = количество } одного предмета; сортируется на месте.
-- hist: историческая медиана или nil.
-- Возвращает лучшую сделку { lots, units, cost, ref, reason, profit, discount } или nil.
function ns.findDeal(lots, hist, opts)
  if #lots == 0 then return nil end
  table.sort(lots, function(a, b) return a.price < b.price end)

  local prices = {}
  for i, lot in ipairs(lots) do prices[i] = lot.price end
  local cutoff = (hist or ns.median(prices)) * opts.outlierFactor
  local n = #lots
  while n > 0 and lots[n].price > cutoff do n = n - 1 end

  local maxRatio = 1 - opts.minDiscount
  local best

  local function try(ref, reason)
    local cost, units, count = 0, 0, 0
    for i = 1, n do
      local lot = lots[i]
      if lot.price > maxRatio * ref then break end
      cost, units, count = cost + lot.price * lot.count, units + lot.count, count + 1
    end
    if count == 0 or count > opts.maxLots or cost > opts.maxCost then return end
    local profit = units * ref * (1 - opts.cut) - cost
    if profit >= opts.minProfit and (not best or profit > best.profit) then
      best = { lots = count, units = units, cost = cost, ref = ref, reason = reason, profit = profit,
               discount = 1 - cost / units / ref }
    end
  end

  for k = 1, n - 1 do
    local nextPrice = lots[k + 1].price
    local confirmed = hist or (k + 2 <= n and lots[k + 2].price <= nextPrice * opts.confirmSpread)
    if lots[k].price <= maxRatio * nextPrice and confirmed then
      if hist and hist < nextPrice then try(hist, "history") else try(nextPrice, "neighbors") end
    end
  end
  if hist then try(hist, "history") end

  return best
end
