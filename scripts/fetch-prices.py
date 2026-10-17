#!/usr/bin/env python3
"""Snapshot the Azure list prices the cost model uses.

Usage: fetch-prices.py [--out analysis/prices-belgiumcentral-<date>.json]

Queries the public Azure Retail Prices API (no sign-in; it costs nothing and
reads nothing from the subscription) for the pay-as-you-go prices of every
resource on the database side of the four configurations, in belgiumcentral,
in USD, and saves the matching items with the time of retrieval. Prices
change, so the analysis reads this snapshot, never the live API: the numbers
in the thesis stay reproducible and dated.

Billing on the Azure for Students subscription cannot stand in for this: its
Cost Management data has no Azure Database for PostgreSQL line at all, and it
mixes in the test harness (client VM, public IPs).
"""
import argparse
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://prices.azure.com/api/retail/prices"
REGION = "belgiumcentral"
CURRENCY = "USD"

# (key, OData filter) — each must match exactly one pay-as-you-go item.
QUERIES = [
    ("vm_b2s_v2_linux",
     "serviceName eq 'Virtual Machines' and productName eq 'Virtual Machines Bsv2 Series' "
     "and skuName eq 'B2s v2' and priceType eq 'Consumption'"),
    ("disk_p20", "productName eq 'Premium SSD Managed Disks' and meterName eq 'P20 LRS Disk'"),
    ("disk_e20", "productName eq 'Standard SSD Managed Disks' and meterName eq 'E20 LRS Disk'"),
    ("disk_e20_operations", "productName eq 'Standard SSD Managed Disks' and meterName eq 'E20 LRS Disk Operations'"),
    ("disk_e4", "productName eq 'Standard SSD Managed Disks' and meterName eq 'E4 LRS Disk'"),
    ("pg_burstable_b1ms",
     "productName eq 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute' "
     "and meterName eq 'B1MS' and priceType eq 'Consumption'"),
    ("pg_gp_dsv3_vcore",
     "productName eq 'Azure Database for PostgreSQL Flexible Server General Purpose Dsv3 Series Compute' "
     "and skuName eq 'vCore' and priceType eq 'Consumption'"),
    ("pg_storage",
     "productName eq 'Azure Database for PostgreSQL Flex Server Storage' and meterName eq 'Storage Data Stored'"),
    ("pg_backup_storage",
     "productName eq 'Azure Database for PostgreSQL Flexible Server Backup Storage' "
     "and meterName eq 'Backup Storage LRS Data Stored'"),
]


def fetch(flt):
    url = f"{API}?currencyCode='{CURRENCY}'&$filter=" + urllib.parse.quote(f"armRegionName eq '{REGION}' and {flt}")
    items = []
    while url:
        with urllib.request.urlopen(url, timeout=60) as r:
            page = json.load(r)
        items += page["Items"]
        url = page.get("NextPageLink")
    return items


def main(argv):
    today = datetime.datetime.now(datetime.timezone.utc)
    default_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "analysis",
                               f"prices-{REGION}-{today:%Y%m%d}.json")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=default_out)
    args = ap.parse_args(argv)

    prices = {}
    for key, flt in QUERIES:
        items = [i for i in fetch(flt) if i.get("type") == "Consumption" and "Spot" not in i.get("skuName", "")]
        if len(items) != 1:
            sys.exit(f"{key}: expected exactly one price item, got {len(items)}: "
                     + "; ".join(f"{i['productName']} / {i['skuName']} / {i['meterName']}" for i in items))
        i = items[0]
        prices[key] = {k: i[k] for k in ("retailPrice", "unitOfMeasure", "currencyCode", "productName",
                                          "skuName", "meterName", "meterId", "effectiveStartDate")}
        print(f"{key:22} {i['retailPrice']:>10} {i['currencyCode']} per {i['unitOfMeasure']:12} {i['productName']} / {i['meterName']}")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"retrieved_at": today.strftime("%Y-%m-%dT%H:%M:%SZ"), "source": API, "region": REGION,
                   "currency": CURRENCY, "price_type": "pay-as-you-go (Consumption)", "prices": prices}, f, indent=2)
        f.write("\n")
    print(f"written: {os.path.normpath(args.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
