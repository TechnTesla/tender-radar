# web/

The dashboard a supplier sees: saved filters, open-tender list, recompete radar,
and the Watching → Submitted pipeline board.

- **Reads from:** Supabase, using `SUPABASE_PUBLISHABLE_KEY` only.
- **Never uses** the secret key — anything that ships to the browser stays publishable.

_Not built yet — this is a Phase 0 placeholder._
