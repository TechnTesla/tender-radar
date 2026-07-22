-- tender-radar production schema
-- Module 1. Designed against real AusTender OCDS payloads sampled 2026-07-22.
--
-- Run this in the Supabase SQL editor, top to bottom, once.
--
-- Design notes are inline. The short version:
--   * every table has a surrogate primary key (id) and, where one exists,
--     a unique natural key from the source data
--   * the natural key is what makes re-ingestion idempotent
--   * money is numeric, never float
--   * dates from AusTender are Australian local midnight expressed in UTC,
--     so they are stored as timestamptz and converted on read


-- ---------------------------------------------------------------------------
-- 0. Remove the disposable practice tables
-- ---------------------------------------------------------------------------
-- These were for learning SQL and hold no real data.
-- CASCADE also drops anything that depended on them.

drop table if exists contracts cascade;
drop table if exists tenders cascade;
drop table if exists agencies cascade;


-- ---------------------------------------------------------------------------
-- 1. agencies  -- the buyers (OCDS role: procuringEntity)
-- ---------------------------------------------------------------------------
create table agencies (
  id          bigint generated always as identity primary key,

  -- Natural key. ABN would be the better choice, but ~5% of parties in our
  -- sample had no ABN at all, and Postgres treats NULLs as distinct in a
  -- unique constraint -- so a nullable ABN would let duplicates through.
  -- Name is present 100% of the time, so name is the key and ABN is data.
  name        text not null unique,

  abn         text,
  created_at  timestamptz not null default now()
);

comment on column agencies.abn is
  'Australian Business Number, from parties[].additionalIdentifiers where scheme = AU-ABN. Nullable.';


-- ---------------------------------------------------------------------------
-- 2. suppliers  -- the incumbents (OCDS role: supplier)
-- ---------------------------------------------------------------------------
-- Same shape as agencies. Kept separate rather than one "parties" table
-- because the two are queried for different reasons and an agency is never
-- meaningfully a supplier in this product.

create table suppliers (
  id           bigint generated always as identity primary key,
  name         text not null unique,
  abn          text,

  -- Address, flattened. Useful later for "suppliers near me" style filtering.
  locality     text,
  region       text,   -- state, e.g. TAS
  postal_code  text,
  country      text,

  created_at   timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 3. contracts  -- Contract Notices (CNs). Powers the recompete radar.
-- ---------------------------------------------------------------------------
create table contracts (
  id            bigint generated always as identity primary key,

  -- THE natural key. ocid identifies the whole contracting process and stays
  -- stable across every amendment, which cn_id does not reliably do.
  -- This unique constraint is what makes "on conflict do update" possible.
  ocid          text not null unique,

  -- Human-facing ID, e.g. CN4262815. For display and for linking back to
  -- the AusTender page. Not the key: display identifiers can be reissued.
  cn_id         text not null,

  agency_id     bigint references agencies(id),
  supplier_id   bigint references suppliers(id),

  -- description is the readable one ("Infrastructure Support infrasound
  -- station at Davis"). title is the agency's internal reference
  -- ("CON/GAUCON/CON009795/1") and is near-useless to a user. Show description.
  description   text,
  title         text,

  -- Arrives from the API as the STRING "27349.59". Cast on the way in.
  -- numeric(15,2) is exact; a float would not be.
  value_amount  numeric(15,2),
  value_currency text default 'AUD',

  -- TIMEZONE TRAP. The API returns e.g. 2026-06-29T14:00:00Z, which is
  -- midnight on 30 June in Sydney (UTC+10, or +11 during daylight saving).
  -- Casting these to a date in UTC shifts every contract back one day and
  -- makes financial-year contracts appear to end on 29 June.
  -- Store the true instant; convert with `at time zone 'Australia/Sydney'`
  -- whenever filtering or displaying.
  start_date    timestamptz,
  end_date      timestamptz,
  date_signed   timestamptz,

  -- 'active' / 'cancelled' etc. Note: OCP documents that a cancelled
  -- amendment can overwrite a live contract's status, so some rows read
  -- 'cancelled' while the AusTender site shows them active. Surface this
  -- to users rather than filtering on it silently.
  status        text,

  procurement_method text,  -- e.g. 'Limited tender'

  -- UNSPSC category code, e.g. 81150000. The API gives the code only --
  -- descriptions must come from the AusTender UNSPSC codeset.
  -- Contracts average ~1.4 items; we store the first. A contract_items
  -- table can come later if multi-category filtering proves necessary.
  unspsc_code   text,

  -- release.date from the payload: when AusTender last changed this record.
  -- Lets us skip re-processing records that have not moved.
  source_updated_at timestamptz,
  ingested_at   timestamptz not null default now()
);

-- Indexes exist so queries do not scan the whole table.
-- end_date first: it is the recompete radar's entire filter.
create index contracts_end_date_idx      on contracts (end_date);
create index contracts_agency_idx        on contracts (agency_id);
create index contracts_supplier_idx      on contracts (supplier_id);
create index contracts_unspsc_idx        on contracts (unspsc_code);
create index contracts_source_updated_idx on contracts (source_updated_at);


-- ---------------------------------------------------------------------------
-- 4. tenders  -- open ATMs. PROVISIONAL.
-- ---------------------------------------------------------------------------
-- ATMs are NOT in the OCDS API. They come from AusTender's Current ATM RSS
-- feed, which refreshes daily after business hours. We have not yet read the
-- feed, so these columns are an educated guess and WILL be revised before any
-- ATM ingestion code is written. Created now only so that RLS is enabled on
-- every table from day one.

create table tenders (
  id            bigint generated always as identity primary key,

  -- Natural key. AusTender shows both a human ID ("ATM 2025 2336") and a GUID
  -- in the detail URL. Whichever the RSS feed actually exposes becomes the key.
  atm_id        text not null unique,
  guid          text,

  title         text,
  description   text,
  agency_name   text,   -- plain text, not an FK: the feed may not match agencies cleanly

  publish_date  timestamptz,
  close_date    timestamptz,   -- same timezone trap as contracts
  atm_type      text,          -- RFT, RFQ, EOI, RFI, RFP
  unspsc_code   text,
  url           text,

  ingested_at   timestamptz not null default now()
);

create index tenders_close_date_idx on tenders (close_date);

comment on table tenders is
  'PROVISIONAL. Columns to be revised once the ATM RSS feed structure is confirmed.';


-- ---------------------------------------------------------------------------
-- 5. saved_filters  -- user-owned
-- ---------------------------------------------------------------------------
create table saved_filters (
  id          bigint generated always as identity primary key,

  -- Ties the row to a Supabase auth user. This column is the entire basis of
  -- the security policy below.
  user_id     uuid not null references auth.users(id) on delete cascade,

  name        text not null,

  -- jsonb because filter shapes will change as the UI evolves, and we do not
  -- want a migration every time someone adds a criterion.
  filters     jsonb not null default '{}'::jsonb,

  created_at  timestamptz not null default now()
);

create index saved_filters_user_idx on saved_filters (user_id);


-- ---------------------------------------------------------------------------
-- 6. pipeline_items  -- the Watching -> Submitted board
-- ---------------------------------------------------------------------------
create table pipeline_items (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,

  -- An item tracks either an open tender or a contract worth chasing,
  -- so both FKs are nullable and exactly one must be set.
  tender_id    bigint references tenders(id) on delete cascade,
  contract_id  bigint references contracts(id) on delete cascade,

  -- A check constraint is the database enforcing a rule your app might forget.
  constraint pipeline_items_one_target check (
    (tender_id is not null and contract_id is null) or
    (tender_id is null and contract_id is not null)
  ),

  status       text not null default 'watching'
               check (status in ('watching', 'submitted')),

  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index pipeline_items_user_idx on pipeline_items (user_id);


-- ---------------------------------------------------------------------------
-- 7. Row Level Security
-- ---------------------------------------------------------------------------
-- RLS means: rows are invisible unless a policy explicitly allows them.
-- Enabling it with NO policy denies everything -- which is the safe default,
-- and why we enable it before the app exists rather than after.
--
-- The publishable key used by the browser is subject to these policies.
-- The secret key used by the pipeline bypasses them entirely, which is
-- exactly why the secret key never reaches client-side code.

alter table agencies       enable row level security;
alter table suppliers      enable row level security;
alter table contracts      enable row level security;
alter table tenders        enable row level security;
alter table saved_filters  enable row level security;
alter table pipeline_items enable row level security;


-- Public data: readable by anyone, writable by no one through the API.
-- (The pipeline writes with the secret key, which ignores RLS.)
-- STUB -- to be tightened in Module 6.

create policy "public read" on agencies
  for select to anon, authenticated using (true);

create policy "public read" on suppliers
  for select to anon, authenticated using (true);

create policy "public read" on contracts
  for select to anon, authenticated using (true);

create policy "public read" on tenders
  for select to anon, authenticated using (true);


-- User data: you see and touch only your own rows.
-- auth.uid() is the ID of the logged-in user making the request. Postgres
-- evaluates it per row, so there is no way to ask for someone else's data.

create policy "own rows" on saved_filters
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "own rows" on pipeline_items
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- Sanity check -- run after the above and confirm rls_enabled is true for all 6
-- ---------------------------------------------------------------------------
-- select tablename, rowsecurity as rls_enabled
-- from pg_tables
-- where schemaname = 'public'
-- order by tablename;