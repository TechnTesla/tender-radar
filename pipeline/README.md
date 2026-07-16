# pipeline/

Pulls open procurement data from AusTender and writes it into Supabase.

- **Sources:** AusTender publishes Approach to Market (ATM) and Contract Notice (CN)
  records. CN records carry the value + expiry that power the recompete radar.
- **Runs on:** a GitHub Actions cron (public repo = free unlimited Actions minutes).
- **Auth:** uses `SUPABASE_SECRET_KEY` / `DATABASE_URL` from the environment. In CI these
  come from GitHub Actions **repository secrets**, never from a committed file.

_Not built yet — this is a Phase 0 placeholder._
