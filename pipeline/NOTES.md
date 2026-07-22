# Data Recon Notes — AusTender

Module 1. Findings from the OCDS API docs, the publisher's own example code,
and the Open Contracting Partnership's field-level review of this dataset.

Status of each finding is marked:
- **[verified]** — confirmed from an authoritative source
- **[measure]** — must be confirmed against live sample data (see `sample_cn.py`)

---

## 0. The API

**Base URL:** `https://api.tenders.gov.au/ocds/`

| Endpoint | Purpose |
|---|---|
| `findById/{CN_ID}` | One contract notice by ID |
| `findByDates/contractPublished/{from}/{to}` | Published in window |
| `findByDates/contractStart/{from}/{to}` | Contract start date in window |
| `findByDates/contractEnd/{from}/{to}` | **Contract end date in window** |
| `findByDates/contractLastModified/{from}/{to}` | Changed in window |

Dates are ISO 8601: `yyyy-mm-ddThh:mm:ssZ`.

**[verified] No API key required.** The publisher's own AngularJS example
(`examples/angularjs/js/apiSearch.js`) issues a plain `GET` with no auth header,
and the OCDS Kingfisher Collect scraper crawls it unauthenticated. An older 2020
OCP blog post claims a token is needed — that appears to be out of date.

**[verified] Response is an OCDS *release package*:** `{ "releases": [ ... ] }`.
Kingfisher declares `data_type = "release_package"`.

**[verified] Pagination is cursor-based** via a `cursor` query parameter, with the
next page URL supplied in the response's `links.next`. Kingfisher chunks requests
into **7-day windows** (`step = 7`) — worth copying, it's a hint that wide date
ranges are unfriendly to the endpoint.

**[verified] License: CC BY 3.0 AU.** Attribution required. We must credit
AusTender / Department of Finance on the site.

**[verified] OCID prefix: `prod-fffffb`.**

### The single most important structural fact

**One contract notice returns *multiple* releases.** The original contract is one
release tagged `["contract"]`; every subsequent amendment is a *separate release*
tagged `["contractAmendment"]`, sharing the same `ocid`.

There are 851,985 contracts but 317,661 amendments in the dataset — roughly 1 in
3 contracts has been amended. Ignoring this would double-count badly.

---

## 1a. Contract end date — YES, it exists

**Field path:** `releases[].contracts[0].period.endDate`
(with `period.startDate` alongside it)

**[verified]** Confirmed two ways: the publisher's example UI binds directly to
`release.contracts[0].period.endDate`, and there is a dedicated
`findByDates/contractEnd/` search endpoint — the API is built to be queried by
this field, which is exactly what the recompete radar needs.

**Format:** ISO 8601 datetime string. **[measure]** — check whether it carries a
real time component and offset, or is always midnight.

**[measure] Null rate — unmeasured.** This is the single biggest risk to
feature 2. If `endDate` is frequently null, the recompete radar has no input.
`sample_cn.py` reports this directly.

### Known quirk — amendments overwrite dates

Per OCP's review: *the status, period and value of contracts with cancelled
amendments are overwritten with those of the cancelled amendment.* Consequence:
some contracts that are live on the AusTender website show as `cancelled` in
OCDS, with the wrong end date. We will surface `status` in the UI rather than
silently filtering on it, and link every row back to the AusTender page so a user
can check the source of truth.

---

## 1b. Incumbent, agency, value, category

### Value
`releases[].contracts[0].value.amount` and `.currency`. **[verified]**

Total-of-life, **not** annual spend. The UI must label this explicitly or it
misleads. Threshold for mandatory reporting is $10,000 for non-corporate
Commonwealth entities (higher for prescribed corporate entities: $400k general,
$7.5m construction) — so this is not a complete picture of government spend.

### Agency (buyer) and Supplier — both live in `parties[]`
**[verified]** and this is the awkward part.

OCP's review states plainly: *buyer information is not provided in either the
`parties` section or the `buyer` field, and procuring entity information is not
referenced from `tender/procuringEntity`. However, you can use the `parties.roles`
field to identify the procuring entity.*

So: **iterate `parties[]` and switch on `roles[]`** — expect `procuringEntity`
for the agency and `supplier` for the incumbent. Do not trust top-level
`buyer` / `awards[].suppliers`. **[measure]** — confirm the exact role strings.

Party fields available: `name`, `address.{locality, region, postalCode, countryName}`.

**Identifiers:** *not* in `parties[].identifier` — use
`parties[].additionalIdentifiers[]` instead (expected to carry the ABN).
**[verified]** Some organisations have no identifier at all, so name-matching is
the necessary fallback. This means agency and supplier de-duplication will be
imperfect; that is a data-quality property of the source, not a bug in our code.

### Category (UNSPSC)
`releases[].contracts[0].items[].classification` — scheme UNSPSC.
1,169,631 items across 851,985 contracts, so **~1.4 items per contract**; most
have one, some have several.

**[verified] Code descriptions are NOT included** — only the numeric code. We
must join against the *AusTender Customised UNSPSC Codeset* (an .xlsx published
on data.gov.au, a curated subset of full UNSPSC) to render human-readable
category names.

### Supplier quirk — a contract can list several
Per OCP: *when a contract is amended to change the name of a supplier, a new
identifier is assigned and the previous supplier is not removed, resulting in
multiple suppliers being associated with the contract.*

Directly affects "who is the incumbent". Our rule: take the supplier party from
the **most recent** release for that ocid, and keep the raw payload so we can
revisit. **[measure]** — count how many contracts carry >1 supplier party.

### Item quirk — duplicates
Item identifiers differ between the original contract and each amendment, so
amended contracts carry duplicated items. Another reason to compile to
latest-state rather than accumulating every release.

---

## 1c. ATMs — NOT available via the OCDS API

**Decision: use the official ATM RSS feed. Confirm exact URL before coding.**

### Evidence they are absent from OCDS
- Every description of this API says *contract notice (CN) data* — never ATMs.
- OCP's counts for this publisher: **tenderers: 0, tender items: 0, planning
  activities: 0, documents: 0, milestones: 0.** The `tender` object that does
  appear (851,969 of them, ~1 per contract) is the *retrospective* description of
  the process that produced an awarded contract — procurement method, limited
  tender exemption reason. It is not an open opportunity.
- OCP's 2020 analysis: *Australia is not publishing much information on tender
  and award in OCDS* — the value is post-award.

**Conclusion: the OCDS API cannot power feature 1. Do not write ATM code
against it.**

### The actual ATM source
**[verified]** From AusTender's own help pages: *an RSS feed of all publicly
available ATMs currently out to the market has been implemented on AusTender's
Current ATM web page. The feed will be updated daily after business hours.*

This is the right source: officially provided, machine-readable, designed for
exactly this consumption, and it costs AusTender one cheap request per poll.

- Current ATM list (HTML): `https://www.tenders.gov.au/atm`
- ATM detail page: `https://www.tenders.gov.au/Atm/Show/{guid}`
- Search supports query params, e.g. `https://www.tenders.gov.au/Atm?filter=published&Keyword=...`
- The feed is also registered on data.gov.au as *"Latest Approaches to Markets
  listed on AusTender — AusTender approaches to market RSS feed"*.

**[measure] TODO — grab the exact feed URL.** The ATM page is JavaScript-rendered,
so the RSS `<link>` is not in the raw HTML text. Open
`https://www.tenders.gov.au/atm`, click the RSS icon at the top right (or check
devtools → Network), and record the URL here.

Note the identifier split: ATMs have a **human-facing ID** (`ATM 2025 2336`) and a
**GUID** in the detail URL. Record which one the RSS feed exposes before choosing
the natural key.

**[measure] TODO — record the RSS field list.** Likely a thin RSS 2.0 feed
(title / link / description / pubDate). If closing date, agency and UNSPSC are
*not* in the feed, we either parse them from the linked detail page (slowly,
politely, only for new ATMs) or accept a thinner ATM record. Decide once the feed
is in hand — do not guess the `tenders` schema before then.

### Rejected alternatives
- **Historical ATM CSVs on data.gov.au** (e.g. `atmdata1jan13-30jun14.csv`) —
  historical only, no current opportunities. Useless for feature 1.
- **Scraping the ATM search UI** — JS-rendered, needs a headless browser, and it
  is the impolite option when an RSS feed is offered. Violates our "respect the
  source" rule.
- **Weekly CN export files** — CN data, wrong side of the award.

### Cadence
The feed refreshes **daily after business hours**. Polling more than a few times
a day gains nothing. A once-daily scheduled job is the correct design, and it
keeps us inside GitHub Actions free-tier minutes.

---

## Client etiquette (applies to all fetching)

- Identify ourselves: `User-Agent: tender-radar/0.1 (+<repo URL>)`
- One request at a time, with a delay between requests
- 7-day windows for CN date searches, following `links.next` for pages
- Daily schedule for ATMs; incremental `contractLastModified` for CNs after backfill
- Never parallelise against tenders.gov.au

---

## Open items before Module 2

1. Run `sample_cn.py`, paste the null-rate table into this file.
2. Record the ATM RSS URL and its field list.
3. Confirm the exact `parties[].roles` strings.
4. Download the AusTender UNSPSC codeset for category names.