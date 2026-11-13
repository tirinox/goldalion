# API аукциона WoW Forever: сводка и план

Собрано 2026-11-13. Кода аддона ещё нет, это справка и план.

Метки достоверности:

- **[SRC]** — прочитано в исходниках UI Blizzard для билда 1.60.1 (70938), то есть ровно для установленного клиента.
- **[WIKI]** — warcraft.wiki.gg; страницы описывают retail, но в блоке Game Types указан и Forever.
- **[3P]** — сторонние гайды и новости, сами помечают многое как наблюдения из беты.
- **[?]** — не подтверждено, надо проверить в игре (раздел 7).

## 1. Целевая платформа

| Что | Значение | Откуда |
|---|---|---|
| Продукт | WoW Forever, код продукта `wowf`, папка `_forever_` | локальный `.build.info` |
| Версия клиента | 1.60.1.70938 (EU, ruRU) | локальный `.build.info` |
| `## Interface:` для TOC | `16001` | [WIKI] GetBuildInfo, TOC установленных аддонов |
| Тип игры для условий в TOC | `camelot` (`[AllowLoadGameType camelot]`) | [SRC] `Blizzard_AuctionHouseUI.toc` |
| Интерфейс аукциона | современный `C_AuctionHouse` (как retail 8.3+), не старый `QueryAuctionItems` | [SRC] |
| Запуск | 4 ноября 2026, кап 60 уровня, наборы правил Normal / PvP / RP / RP-PvP, Hardcore позже | [3P] |
| Папка аддонов | `/Applications/World of Warcraft/_forever_/Interface/AddOns/` | локально |

Клиент Forever — гибрид: движок и UI-фреймворк от современного WoW (семейство файлов `Mainline`), а данные и категории предметов ванильные (есть классы Quiver, Projectile, случайные суффиксы «of the Bear»). [SRC]

## 2. Устройство аукциона в Forever

- Реалмов нет, но регионы остались. Один аукцион на набор правил в регионе; PvP и RP отдельно. [3P, со ссылкой на Q&A Blizzard]
- Аукционы фракций раздельные. [3P] Про нейтральный аукцион для Forever ничего не заявлено. [?]
- Складываемые товары — commodities: цена за единицу, покупатель вводит количество и получает самые дешёвые. Экипировка — один предмет на лот. [3P], согласуется с API [SRC]
- Длительность лота: 2, 8 или 24 часа — подтверждено зондом в игре (раздел 7). Гайд с 12/24/48 устарел.
- Комиссия 5% (15% на нейтральном) и депозит от вендорной цены и длительности — «как в Classic», Blizzard для Forever не подтверждала. На форуме есть баг-треды про депозит; изменения аукциона якобы временно откатили до обслуживания 17 ноября. [3P] [?]
- Имя персонажа состоит из двух частей и уникально в регионе. Как выглядят имена продавцов в API — неизвестно. [?]

Следствие для сканера: рынок размером с весь регион (на фракцию и набор правил), лотов может быть на порядок больше, чем на одном классическом сервере. Объём данных и время скана — главный технический риск.

## 3. Справочник API (`C_AuctionHouse`, билд 70938)

Полный список — 88 функций и 47 событий в `Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua` ветки `forever`. Ниже то, что нужно для сканирования и анализа цен. Всё в этом разделе — [SRC], если не указано иное.

### 3.1 Полный скан одним запросом (replicate)

```
ReplicateItems()                      -- «использовать вместо allItem QueryAuctionItems для запроса всего аукциона»
GetNumReplicateItems() -> number
GetReplicateItemInfo(index) -> name?, texture?, count, qualityID, usable?, level, levelType?,
    minBid, minIncrement, buyoutPrice, bidAmount, highBidder?, bidderFullName?,
    owner?, ownerFullName?, saleStatus, itemID, hasAllInfo?
GetReplicateItemLink(index) -> itemLink?
GetReplicateItemTimeLeft(index) -> timeLeft
событие REPLICATE_ITEM_LIST_UPDATE()
```

Известное поведение в retail [WIKI]:

- Троттл 15 минут **на аккаунт** между успешными вызовами.
- Индексы от `0` до `GetNumReplicateItems()-1`.
- Если `hasAllInfo == false`, данные предмета ещё не загружены: `Item:CreateFromItemID(id):ContinueOnItemLoad(...)`, затем перечитать запись.
- `REPLICATE_ITEM_LIST_UPDATE` приходит и после вызова, и на каждую докешированную запись; клиент обрабатывает около 2000 таких событий за кадр.
- `owner` и `ownerFullName` с 9.0.2 равны nil для чужих лотов.
- На серверах с 80k+ лотов скан приводил к дисконнектам. Пример с вики: 81 338 лотов прочитаны за 2,6 с.

На живых серверах Forever `ReplicateItems` работает — проверено зондом, цифры в разделе 7. Кулдаун на Forever не измерен; сторонний гайд пишет «раз в 15 минут, как в retail» с пометкой «бета».

### 3.2 Обзор по категориям (browse)

```
SendBrowseQuery(query)                -- query: AuctionHouseBrowseQuery
RequestMoreBrowseResults()
GetBrowseResults() -> BrowseResultInfo[]
HasFullBrowseResults() -> bool
события: AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
         AUCTION_HOUSE_BROWSE_RESULTS_ADDED(addedBrowseResults)
         AUCTION_HOUSE_BROWSE_FAILURE()

AuctionHouseBrowseQuery { searchString, sorts: AuctionHouseSortType[], minLevel?, maxLevel?,
                          filters: AuctionHouseFilter[]?, itemClassFilters: AuctionHouseItemClassFilter[]? }
AuctionHouseItemClassFilter { classID, subClassID?, inventoryType? }
AuctionHouseSortType { sortOrder: Enum.AuctionHouseSortOrder, reverseSort: bool }
BrowseResultInfo { itemKey, appearanceLink?, totalQuantity, minPrice, containsOwnerItem }
```

- Результат — одна строка на `itemKey`: минимальная цена и суммарное количество. Отдельных лотов и «лестницы» цен здесь нет.
- Результаты приходят порциями. Штатный UI зовёт `RequestMoreBrowseResults()`, когда до конца списка остаётся меньше 30 строк, и останавливается по `HasFullBrowseResults()`. Размер порции в исходниках не указан. [?]
- `filters` должен содержать хотя бы один фильтр, иначе результат пустой; `sorts` ожидает осмысленную комбинацию, например цена + имя. [WIKI]
- Категории Forever: Weapons, Armor, Containers, Consumables, Trade Goods, Projectile, Recipes, Quest Items, Miscellaneous, WoW Token. Подкатегории строятся из `Enum.ItemClass` / подклассов (`Camelot/Blizzard_AuctionData.lua`).

### 3.3 Поиск по конкретному предмету (search)

```
SendSearchQuery(itemKey, sorts, separateOwnerItems, minLevelFilter=0, maxLevelFilter=0)
SendSellSearchQuery(itemKey, sorts, separateOwnerItems)   -- itemKey без ilvl и суффикса

-- commodities, ключ itemID
GetNumCommoditySearchResults(itemID), GetCommoditySearchResultInfo(itemID, index)
GetCommoditySearchResultsQuantity(itemID), HasFullCommoditySearchResults(itemID)
RequestMoreCommoditySearchResults(itemID) -> hasFullResults
RefreshCommoditySearchResults(itemID)
события: COMMODITY_SEARCH_RESULTS_UPDATED(itemID), COMMODITY_SEARCH_RESULTS_ADDED(itemID)

-- предметы, ключ itemKey
GetNumItemSearchResults(itemKey), GetItemSearchResultInfo(itemKey, index)
GetItemSearchResultsQuantity(itemKey), HasFullItemSearchResults(itemKey)
RequestMoreItemSearchResults(itemKey) -> hasFullResults
RefreshItemSearchResults(itemKey, minLevelFilter?, maxLevelFilter?)
события: ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID?), ITEM_SEARCH_RESULTS_ADDED(itemKey)

CommoditySearchResultInfo { itemID, quantity, unitPrice, auctionID, owners: string[], totalNumberOfOwners,
                            timeLeftSeconds?, numOwnerItems, containsOwnerItem, containsAccountItem }
ItemSearchResultInfo { itemKey, owners: string[], totalNumberOfOwners, timeLeft: AuctionHouseTimeLeftBand,
                       auctionID, quantity, itemLink?, containsOwnerItem, containsAccountItem,
                       containsSocketedItem, bidder?, minBid?, bidAmount?, buyoutAmount?, timeLeftSeconds? }
```

- В документации самой Blizzard: «Search queries are restricted to 100 calls per minute. These should not be used to query the entire auction house. See ReplicateItems».
- Только здесь видна полная «лестница» цен: для commodities — ступени «цена за единицу × количество», для предметов — каждый лот.
- Универсальное событие для аддонов: `AUCTION_HOUSE_NEW_RESULTS_RECEIVED(itemKey?)`; для browse-запросов payload равен nil.

### 3.4 Ключи и данные предметов

```
ItemKey { itemID, itemLevel=0, itemSuffix=0, battlePetSpeciesID=0 }
MakeItemKey(itemID, itemLevel=0, itemSuffix=0, battlePetSpeciesID=0) -> ItemKey
GetItemKeyInfo(itemKey, restrictQualityToFilter=false) -> ItemKeyInfo?
ItemKeyInfo { itemID, itemName, quality, iconFileID, isCommodity, isEquipment, isPet, ... }
GetItemKeySampleLink(itemKey) -> string?
GetItemKeyRequiredLevel(itemKey) -> number        -- может ничего не вернуть
GetItemCommodityStatus(itemLocation) -> Enum.ItemCommodityStatus { Unknown, Item, Commodity }
события: ITEM_KEY_ITEM_INFO_RECEIVED(itemID), EXTRA_BROWSE_INFO_RECEIVED(itemID)
```

- `GetItemKeyInfo` возвращает nil, пока данные не подгружены; ждать `ITEM_KEY_ITEM_INFO_RECEIVED`.
- Для экипировки со случайными суффиксами ключ базы — `itemID + itemSuffix`. Для commodities хватает `itemID`.

### 3.5 Троттлинг

```
IsThrottledMessageSystemReady() -> bool    -- false: следующий запрос будет отложен или отброшен
события: AUCTION_HOUSE_THROTTLED_SYSTEM_READY, AUCTION_HOUSE_THROTTLED_MESSAGE_SENT,
         AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED, AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED,
         AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED
```

Правило для сканера: перед каждым запросом проверять `IsThrottledMessageSystemReady()`, при false ждать `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`. Таймеры-задержки не нужны. Штатный UI делает так же (`Blizzard_AuctionHouseSellFrame.lua:487`).

### 3.6 Ограничения на действия

| Функция | Ограничение |
|---|---|
| `PostItem`, `PostCommodity`, `ConfirmPostItem`, `ConfirmPostCommodity`, `PlaceBid`, `StartCommoditiesPurchase`, `CancelAuction` | `HasRestrictions = true` [SRC]; по вики — нужен аппаратный клик (`#hwevent`) |
| `SendBrowseQuery`, `SendSearchQuery` | `#noscript`: нельзя звать из `/run`, `/script` и `loadstring` — «иначе аукцион сломается до релога» [WIKI] |
| Все геттеры и запросы чтения | без ограничений [SRC] |

- Чтение и сканирование из кода аддона свободны. Покупка, выставление и отмена возможны только по одному действию на клик игрока.
- Запросы работают только при открытом окне аукциона, между `AUCTION_HOUSE_SHOW` и `AUCTION_HOUSE_CLOSED` (известное поведение retail, для Forever [?]).
- `SecretArguments = "AllowedWhenUntainted"` у большинства функций относится к системе «секретных значений» из 12.0; обычному аддону-сканеру не мешает.
- `SupportsCopperValues()` в Forever возвращает `true`: цены с точностью до меди, на аукционе есть лоты по 1 меди за единицу (зонд, раздел 7). В retail цены кратны серебру. [WIKI]

### 3.7 Прочее полезное

- Депозит: `CalculateItemDeposit(itemLocation, duration, quantity)`, `CalculateCommodityDeposit(itemID, duration, quantity)`; `duration` — индекс 1..3.
- Свои лоты: `QueryOwnedAuctions(sorts)`, `GetOwnedAuctions()`, `OWNED_AUCTIONS_UPDATED`; продажи видны по `status = Enum.AuctionStatus.Sold`.
- Оставшееся время: `Enum.AuctionHouseTimeLeftBand { Short, Medium, Long, VeryLong }`, границы — `GetTimeLeftBandInfo(band)`.
- Константы: `MAXIMUM_BID_PRICE = 99999999999`, `AUCTION_CANCEL_COST = 5` (% от текущей ставки), `DEFAULT_AUCTION_PRICE_MULTIPLIER = 1.5`.

## 4. Три способа сканирования

| | A. Replicate | B. Browse по категориям | C. Search по предмету |
|---|---|---|---|
| Запросов на весь аукцион | 1 | десятки (категории × порции) | по одному на предмет |
| Что даёт | каждый лот: количество, выкуп, ставка, время, ссылка | на itemKey: мин. цена и суммарное количество | полная лестница цен одного предмета |
| Лимит | 15 мин на аккаунт [WIKI] | общий троттл сообщений | 100 запросов в минуту [SRC] |
| Риск | может быть выключен или рвать соединение на огромном региональном аукционе | нет распределения цен | на весь аукцион не годится |
| Для анализа цен | достаточно сам по себе | только минимальная цена | глубина по списку отслеживаемых |

Рекомендация (обновлена после разбора Auctionator, раздел 10): основной скан — B одним пустым запросом, он уже работает на Forever и занимает порядка десятка запросов. C — для списка отслеживаемых предметов, где нужна лестница цен. A на Forever работает (184 тысячи лотов примерно за минуту, раздел 7) и годится как «глубокий скан» для распределения цен по всему рынку, но не чаще кулдауна.

## 5. Анализ цен: что можно и чего нельзя посчитать

Можно из одного скана:

- минимальная цена выкупа за единицу;
- рыночная цена, устойчивая к выбросам: средневзвешенная по самым дешёвым N% количества;
- объём предложения и число лотов;
- маржа перепродажи и крафта с учётом комиссии и депозита (`Calculate*Deposit`).

Можно из серии сканов: дневные минимум и максимум, тренд, волатильность.

Нельзя напрямую: объём продаж. API не отдаёт чужие сделки; оценить можно только разницей снимков (исчезнувшие `auctionID` до истечения срока) или по своим продажам.

Хранение: SavedVariables целиком грузятся в память, поэтому хранить агрегаты по предмету и дню, а не сырые лоты.

## 6. Правила Blizzard для аддонов

Общая политика (2018, действует для всех клиентов): аддон бесплатный, код открыт и не обфусцирован, не создаёт лишней нагрузки на сервер и других игроков; Blizzard вправе отключить любую функциональность. Отдельного заявления про аукционные аддоны в Forever не найдено.

## 7. Результаты зонда в игре

Прогон `GoldalionProbe` 2026-11-13, билд 1.60.1.70938, EU, Орда, набор правил PvE. Всё в этом разделе измерено в игре.

### Клиент

- `WOW_PROJECT_ID = 18`, TOC `16001`.
- `GetRealmName()` возвращает техническое имя вида `CAMWOW EU5 Realm 1 PvE`. Ключ рынка для базы — набор правил + фракция, а не это имя.
- `UnitFullName("player")` отдаёт вторую часть имени персонажа вторым значением, там, где раньше был реалм.

### Правила аукциона

- Длительности: «2 ч.», «8 ч.», «24 ч.» (`AUCTION_DURATION_ONE/TWO/THREE`).
- Цены с медью поддерживаются: `SupportsCopperValues() == true`.
- Полосы оставшегося времени (`GetTimeLeftBandInfo`): Short до 30 мин, Medium 30 мин – 2 ч, Long 2–12 ч, VeryLong 12–24 ч.
- Депозит: для трёх дешёвых commodities (вендорная цена 0, 18 и 50 меди) `CalculateCommodityDeposit` за 1 штуку вернул 100 меди при любой длительности. Похоже на минимальный депозит в 1 серебро; формулу по этим данным вывести нельзя.

### Сводный скан

- Один пустой `SendBrowseQuery` + `RequestMoreBrowseResults`: **14 559 строк за 21,6 с**, 30 порций (29 по 500 и одна на 59), около 0,73 с на порцию.
- Суммарно 1 684 178 единиц товара.
- Троттл: 34 сообщения отправлено, 1 поставлено в очередь, 0 отброшено, ошибок обзора нет.
- `itemKey.itemLevel` заполнен у всех строк, в том числе у commodities.
- `itemKey.itemSuffix` ненулевой у 10 121 строки из 14 559 (70%): каждая комбинация «предмет + случайный суффикс» — отдельная строка, обычно с количеством 1.

### Поиск по предмету

Commodity (itemID 8067, 126 226 штук):

- Результат — ступени по цене, а не лоты: всего 2 строки. 119 626 штук по 1 меди от 147 продавцов и 6 600 штук по 10 меди от одного.
- `totalNumberOfOwners` заполнен, `owners` пуст, `timeLeftSeconds` заполнен с точностью до секунды, `auctionID` есть.

Предмет (itemID 3042, 40 лотов):

- Одна строка на лот: `buyoutAmount`, `auctionID`, `itemLink`, `timeLeft` только полосой; `timeLeftSeconds` для чужих лотов нет.
- `owners` пуст у четырёх строк из пяти; у одной заполнен именем из двух слов через пробел. Рассчитывать на имена продавцов нельзя.
- Ссылка нового формата: `|cnIQ2:|Hitem:3042::::::::30:1489:::::::::|h[...]|h|r`, у части лотов с дополнительными модификаторами в хвосте.
- `ITEM_KEY_ITEM_INFO_RECEIVED` пришёл 53 раза: данные ключей подгружаются асинхронно, ждать их перед поиском действительно нужно.
- События `*_SEARCH_RESULTS_UPDATED` приходят по два раза на запрос — обработчик должен быть идемпотентным.

### Полный скан (replicate)

Запущен один раз, через три минуты после сводного скана.

- `ReplicateItems()` на живом Forever **работает**: 184 068 лотов, соединение не разорвалось.
- Ответ сервера (первое `REPLICATE_ITEM_LIST_UPDATE`) пришёл через 29,9 с.
- Чтение первых 5000 записей пачками по 250 за кадр заняло 0,63 с; на все 184 тысячи в таком темпе уйдёт около 25 с. Скорость упирается в частоту кадров, пачку можно увеличить.
- `owner` пуст у всех 5000 записей.
- `hasAllInfo == false` у 1061 записи из 5000 (21%). У таких записей нет ссылки, но `itemID`, `count` и `buyoutPrice` уже есть.
- `buyoutPrice` — цена всего стака: например, 20 штук за 8980 меди.
- `minBid` и `bidAmount` равны 0 во всех пяти записях выборки; есть ли в Forever ставки вообще — по выборке не понять.
- Кулдаун между вызовами не проверен: вызов был один.

Сравнение на одном и том же рынке: сводный скан — 14 559 строк за 22 с; полный — 184 068 лотов примерно за минуту (30 с ожидания + чтение).

### Выводы для архитектуры

- Сводный скан укладывается в ~22 секунды, его можно запускать при каждом открытии аукциона.
- Полный скан даёт распределение цен сразу по всему рынку. Для товаров без суффикса достаточно `itemID`, `count` и `buyoutPrice`, то есть дозагрузку данных предметов можно не ждать; она нужна только экипировке, где суффикс берётся из ссылки.
- 184 тысячи лотов нельзя складывать в SavedVariables: сворачивать в агрегаты по предмету прямо во время чтения.
- Ключ базы: `itemID` + `itemSuffix`. Для запросов нужен полный `itemKey`, поэтому `itemLevel` храним рядом.
- 70% строк — штучная экипировка с суффиксами. Статистика по ним бедная; основная ценность анализа — в commodities и экипировке без суффикса.
- Лестница цен commodity очень короткая (ступени по цене), её дёшево хранить целиком для списка отслеживаемых.

### Осталось непроверенным

1. Кулдаун `ReplicateItems()` на Forever (в retail 15 минут на аккаунт) и поведение при повторном вызове раньше срока.
2. Формула депозита для дорогих предметов и стаков, комиссия с продажи — сверить на реальном лоте.
3. Есть ли нейтральный аукцион и отдельный ли у него рынок.

## 8. План

1. ~~Отладочный аддон-зонд~~ — сделано, результаты в разделе 7.
2. **Сканер** — сводный скан (B) при открытии аукциона, очередь запросов через троттл-события, прогресс, запись агрегатов по ключу `itemID` + `itemSuffix`. Поиск (C) по списку отслеживаемых.
3. **Анализ цен** — рыночная цена, история по дням, цена в тултипе предмета.
4. **Интерфейс** — вкладка или окно со списком и поиском; что именно показывать, решим после шага 3.

## 9. Источники

- Исходники UI Blizzard, ветка `forever`, коммит «1.60.1 (70938)»: https://github.com/Gethe/wow-ui-source/tree/forever
  - `Interface/AddOns/Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua`
  - `Interface/AddOns/Blizzard_APIDocumentationGenerated/AuctionHouseEnumsDocumentation.lua`
  - `Interface/AddOns/Blizzard_AuctionHouseUI/` (`Shared/`, `Camelot/Blizzard_AuctionData.lua`)
- Вики: https://warcraft.wiki.gg/wiki/API_C_AuctionHouse.ReplicateItems , https://warcraft.wiki.gg/wiki/API_C_AuctionHouse.SendBrowseQuery , https://warcraft.wiki.gg/wiki/API_C_AuctionHouse.SendSearchQuery , https://warcraft.wiki.gg/wiki/API_C_AuctionHouse.IsThrottledMessageSystemReady , https://warcraft.wiki.gg/wiki/GetBuildInfo
- Аукцион Forever (сторонний гайд): https://hearthproof.com/economy/auction-house/
- Новости о запуске и безреалмовой структуре: https://www.warcrafttavern.com/forever/news/world-of-warcraft-forever-is-now-live/ , https://outof.games/news/9961-world-of-warcraft-forever-will-not-have-realms-big-changes-to-server-systems/
- Заметки чужого исследования клиента Forever: https://github.com/edloidas/wow-artisan/issues/1
- Политика аддонов Blizzard: https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534
- В игре: `/api C_AuctionHouse` показывает ту же документацию.

- Auctionator 345, установленная копия: прочитан для понимания метода (раздел 10). Лицензия «All Rights Reserved», в `AGENTS.md` автор просит ИИ-агентов не брать репозиторий за основу. Код не копируется; в разделе 10 описан только порядок вызовов API Blizzard.

## 10. Как сканирует Auctionator

Прочитано в установленной версии 345 по решению владельца проекта. Это описание метода своими словами, не код.

### Два режима

**Сводный скан (по умолчанию).** Способ B из раздела 4 в самом простом виде:

1. Один `SendBrowseQuery` с пустой строкой поиска, пустыми `sorts`, `filters` и `itemClassFilters` — то есть «весь аукцион», без обхода категорий. Вики утверждает, что нужен хотя бы один фильтр; на практике пустой запрос работает.
2. На `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` берётся первая порция из `GetBrowseResults()`, на `AUCTION_HOUSE_BROWSE_RESULTS_ADDED` — добавленные строки из payload события.
3. Пока `HasFullBrowseResults()` ложно, вызывается `RequestMoreBrowseResults()`. Порция — 500 строк.
4. Из каждой строки берутся только `minPrice` и `totalQuantity`; строки с нулевым количеством пропускаются.

Быстро это потому, что сервер отдаёт уже агрегированные данные: одна строка на предмет, а не на лот. Несколько тысяч предметов — это порядка десятка запросов.

**Полный скан (replicate, в настройках выключен по умолчанию).** Способ A:

1. `ReplicateItems()`, собственный кулдаун 15 минут по сохранённому времени последнего скана.
2. По первому `REPLICATE_ITEM_LIST_UPDATE` событие отписывается, читается `GetNumReplicateItems()`.
3. Записи читаются пачками по 250 с паузой 0,01 с через `C_Timer.After`, чтобы не подвешивать клиент: `GetReplicateItemInfo`, `GetReplicateItemLink`, `GetReplicateItemTimeLeft`.
4. Записи с несуществующим `itemID` (`C_Item.DoesItemExistByID`) отбрасываются. Для записей с `hasAllInfo == false` запрашивается загрузка данных (`C_Item.RequestLoadItemDataByID`, повтор каждые 0,4 с, ожидание `ITEM_DATA_LOAD_RESULT`), после чего запись перечитывается.
5. Цена за единицу = `buyoutPrice / count`; лоты без выкупа и с нулевым количеством игнорируются.
6. Закрытие окна аукциона во время скана = скан провален.

### Общее для обоих режимов

- **Троттлинг.** Все запросы идут через очередь. Готовность — `IsThrottledMessageSystemReady()`, перепроверяется на каждом из событий `AUCTION_HOUSE_THROTTLED_*` и на `AUCTION_HOUSE_BROWSE_FAILURE`. Фиксированных задержек нет.
- **Обработка без фризов.** Свёртка результатов в базу идёт кусками по 350–500 записей за кадр через `C_Timer.NewTicker(0, ...)`.
- **Автоскан** при открытии аукциона — опционально, с интервалом в минутах.

### Что он хранит

На предмет: `m` — минимальная цена последнего скана; по дням `h` и `l` — максимум и минимум этой минимальной цены за день; `a` — максимальное количество за день. История обрезается по числу дней (у тебя 21). Лестница цен и отдельные лоты не сохраняются, хотя полный скан их видит.

Ключи: `"<itemID>"` для обычных предметов, `"g:<itemID>:<ilvl>"` для экипировки выше порога уровня предмета, `"p:<speciesID>"` для питомцев.

База лежит в `AUCTIONATOR_PRICE_DATABASE` по ключу набора правил (у тебя `"PvE"`), на диске — CBOR-строкой, в игре текущий набор развёрнут в таблицу.

Локальное состояние на 2026-11-13: полный скан выключен, автоскан выключен, последний сводный скан 12 ноября 18:32, в базе несколько тысяч предметов. Значит, сводный скан на живом Forever работает; про replicate это ничего не говорит.

### Доступ к его данным

Поддерживаемый путь — публичный API, который автор обещает держать стабильным. В TOC нужен `## OptionalDeps: Auctionator`, первый аргумент — имя нашего аддона.

```
Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID)      -- цена в меди или nil
Auctionator.API.v1.GetAuctionPriceByItemLink(callerID, itemLink)
Auctionator.API.v1.GetAuctionAgeByItemID(callerID, itemID)        -- возраст цены в днях
Auctionator.API.v1.GetAuctionAgeByItemLink(callerID, itemLink)
Auctionator.API.v1.IsAuctionDataExactByItemID(callerID, itemID)
Auctionator.API.v1.IsAuctionDataExactByItemLink(callerID, itemLink)
Auctionator.API.v1.GetVendorPriceByItemID(callerID, itemID)
Auctionator.API.v1.GetVendorPriceByItemLink(callerID, itemLink)
Auctionator.API.v1.RegisterForDBUpdate(callerID, callback)        -- вызов после каждого скана
```

- Через API доступна только последняя минимальная цена и её возраст. История по дням и количество в стабильный API не входят; читать глобальную таблицу напрямую можно технически, но автор это не поддерживает и формат может поменяться.
- Аддон не может читать файлы с диска, поэтому SavedVariables Auctionator доступны только как глобальные переменные в игре, когда Auctionator загружен.

### Можно ли скопировать метод

- **Метод — да.** Это последовательность вызовов API Blizzard; так же устроен штатный UI аукциона. Своя реализация сводного скана — несколько десятков строк.
- **Код — нет.** Лицензия «All Rights Reserved»: копировать и переделывать его файлы нельзя.
- **Чего у Auctionator нет и что придётся делать самим:** лестница цен, устойчивая рыночная цена, оценка объёма продаж, учёт случайных суффиксов экипировки в ключе.
