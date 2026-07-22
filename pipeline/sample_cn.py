"""
Module 1, task 2: pull a sample of real Contract Notices and report field quality.

This is a throwaway recon script, not pipeline code. Standard library only, so
there is nothing to install. Run it, read the report, paste the numbers into
NOTES.md, then move on.

    python3 sample_cn.py

Output:
    samples.json   raw releases, for eyeballing actual payloads
    a report printed to the terminal
"""

import json
import time
import urllib.request
from collections import Counter
from datetime import date, timedelta

BASE = "https://api.tenders.gov.au/ocds/findByDates/contractPublished"
UA = "tender-radar/0.1 (recon; +https://github.com/YOURNAME/tender-radar)"

WINDOW_DAYS = 7      # match Kingfisher's step; wide ranges are unfriendly
MAX_PAGES = 3        # keep the sample small and the load light
DELAY_SECONDS = 2    # be a polite client


def get(url):
    """One GET, identified and JSON-decoded."""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def fetch_sample():
    """Walk a recent 7-day window, following links.next for a few pages."""
    end = date.today()
    start = end - timedelta(days=WINDOW_DAYS)
    url = f"{BASE}/{start}T00:00:00Z/{end}T00:00:00Z"

    releases = []
    for page in range(MAX_PAGES):
        print(f"  page {page + 1}: {url}")
        payload = get(url)
        releases.extend(payload.get("releases", []))

        url = (payload.get("links") or {}).get("next")
        if not url:
            break
        time.sleep(DELAY_SECONDS)

    return releases


def dig(obj, *path):
    """Follow a path of dict keys / list indexes, returning None if it breaks."""
    for step in path:
        if obj is None:
            return None
        try:
            obj = obj[step]
        except (KeyError, IndexError, TypeError):
            return None
    return obj


def report(releases):
    total = len(releases)
    if total == 0:
        print("\nNo releases returned. Try widening the window.")
        return

    print(f"\n{'=' * 60}\n{total} releases\n{'=' * 60}")

    # --- 1a: how often is the end date actually there? -------------------
    fields = {
        "ocid": lambda r: r.get("ocid"),
        "contracts[0].id": lambda r: dig(r, "contracts", 0, "id"),
        "contracts[0].period.startDate": lambda r: dig(r, "contracts", 0, "period", "startDate"),
        "contracts[0].period.endDate": lambda r: dig(r, "contracts", 0, "period", "endDate"),
        "contracts[0].value.amount": lambda r: dig(r, "contracts", 0, "value", "amount"),
        "contracts[0].status": lambda r: dig(r, "contracts", 0, "status"),
        "contracts[0].items": lambda r: dig(r, "contracts", 0, "items"),
        "tender.procurementMethodDetails": lambda r: dig(r, "tender", "procurementMethodDetails"),
    }

    print("\nFIELD PRESENCE")
    for name, fn in fields.items():
        present = sum(1 for r in releases if fn(r) not in (None, "", []))
        pct = 100 * present / total
        flag = "  <-- PROBLEM" if pct < 90 else ""
        print(f"  {pct:5.1f}%  {present:4}/{total}  {name}{flag}")

    # --- structure: how many releases are amendments? --------------------
    tags = Counter(t for r in releases for t in r.get("tag", []))
    print(f"\nRELEASE TAGS  {dict(tags)}")

    ocids = Counter(r.get("ocid") for r in releases)
    repeats = sum(1 for c in ocids.values() if c > 1)
    print(f"  {len(ocids)} distinct ocids; {repeats} appear more than once")

    # --- 1b: what roles actually appear, and how many suppliers? ---------
    roles = Counter(
        role
        for r in releases
        for p in (r.get("parties") or [])
        for role in (p.get("roles") or [])
    )
    print(f"\nPARTY ROLES  {dict(roles)}")

    multi_supplier = 0
    no_ids = 0
    for r in releases:
        parties = r.get("parties") or []
        suppliers = [p for p in parties if "supplier" in (p.get("roles") or [])]
        if len(suppliers) > 1:
            multi_supplier += 1
        for p in parties:
            if not p.get("identifier") and not p.get("additionalIdentifiers"):
                no_ids += 1
    print(f"  releases with >1 supplier party: {multi_supplier}")
    print(f"  parties with no identifier at all: {no_ids}")

    # --- date format: what do these strings actually look like? ----------
    print("\nSAMPLE DATE VALUES (check for time + offset)")
    for r in releases[:5]:
        print(f"  start={dig(r, 'contracts', 0, 'period', 'startDate')}  "
              f"end={dig(r, 'contracts', 0, 'period', 'endDate')}")

    # --- one full record, pretty printed ---------------------------------
    print(f"\n{'=' * 60}\nONE FULL RELEASE\n{'=' * 60}")
    print(json.dumps(releases[0], indent=2)[:3000])


if __name__ == "__main__":
    print("Fetching...")
    releases = fetch_sample()
    with open("samples.json", "w") as f:
        json.dump(releases, f, indent=2)
    print(f"Wrote samples.json ({len(releases)} releases)")
    report(releases)