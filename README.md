# tender-radar

Capture-intelligence for small-to-medium Australian businesses that sell to government.
A distilled, affordable slice of the enterprise "capture" tooling, built on open
Commonwealth procurement data (AusTender).

**What a supplier gets:**
- A saved filter set (categories, agencies, value range).
- A **dashboard** of matching open tenders (ATM — Approach to Market).
- A **recompete radar**: active contracts (CN — Contract Notice) expiring in 6–12
  months, with incumbent supplier and contract value.
- A **pipeline board** to move opportunities from Watching → Submitted.

## Repo layout

```
tender-radar/
├── pipeline/   # Data ingestion: AusTender → Supabase. Runs on a GitHub Actions cron.
└── web/        # The dashboard the supplier sees. Reads from Supabase.
```

## Phase 0 — done when

- [ ] Public repo exists with `pipeline/` and `web/`.
- [ ] Supabase project created.
- [ ] `.env` created locally from `.env.example`, filled with real values, and gitignored.
- [ ] Comfortable with SELECT / WHERE / JOIN / GROUP BY in the Supabase SQL editor.

## Environment

Copy the template and fill it with real values. `.env` is gitignored — the connection
string and secret key never get committed.

```bash
cp .env.example .env
```

## Security note

`pipeline/` uses the Supabase **secret** key (server-side, bypasses row-level security).
`web/` uses the **publishable** key only. The secret key must never appear in any
client bundle or any variable prefixed `NEXT_PUBLIC_` / `VITE_` — those get inlined into
the browser build. GitHub push protection and Supabase scanning auto-revoke leaked keys,
so treat a leak as a real incident.
