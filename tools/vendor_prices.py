#!/usr/bin/env python3
"""Собирает Goldalion/VendorPrices.lua из выгрузки ItemSparse с wago.tools.

  curl -o ItemSparse.csv 'https://wago.tools/db2/ItemSparse/csv?build=1.60.1.70938'
  python3 tools/vendor_prices.py ItemSparse.csv 1.60.1.70938 > Goldalion/VendorPrices.lua

В таблице цена покупки есть почти у всех предметов, а не только у тех, что продаются:
кто что продаёт, аддон узнаёт в игре (окно торговца или база Questie).
"""
import csv
import sys

path, build = sys.argv[1], sys.argv[2]
prices, stacks = [], []
with open(path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        buy, bundle = int(row["BuyPrice"]), int(row["VendorStackCount"]) or 1
        # персональные (1), квестовые (4, 5) предметы на аукцион не выставить
        if buy <= 0 or row["Bonding"] not in ("0", "2", "3"):
            continue
        item = int(row["ID"])
        prices.append(f"[{item}]={buy / bundle:.6g}")
        if int(row["Stackable"]) > 1:
            stacks.append(f"[{item}]={row['Stackable']}")


def table(name, comment, entries):
    print(f"-- {comment}")
    print(f"ns.{name} = {{")
    for i in range(0, len(entries), 12):
        print("  " + ",".join(entries[i:i + 12]) + ",")
    print("}")


print(f"-- СГЕНЕРИРОВАНО tools/vendor_prices.py из ItemSparse билда {build} (wago.tools). Руками не править.")
print("local _, ns = ...")
table("vendorPrice", "itemID → цена покупки у торговца за штуку, в меди, без скидки за репутацию", prices)
table("vendorStack", "itemID → размер стака; предметов со стаком 1 здесь нет", stacks)
