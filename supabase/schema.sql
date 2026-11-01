-- =============================================================================
-- OpenStore Digital — complete database schema (digital products, worldwide)
-- =============================================================================
--
-- THIS IS THE ONLY DATABASE FILE. There are no migrations.
--
-- Install by pasting it once into the Supabase SQL editor, or:
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
-- or, against a local Supabase CLI database:
--     docker exec -i supabase_db_<project_id> psql -U postgres -v ON_ERROR_STOP=1 < schema.sql
--
-- The whole file runs in ONE transaction. If any statement fails, nothing is
-- applied, and while it runs the storefront never sees half-revoked grants.
-- Every object is created idempotently, so re-running is safe.
--
-- Design rules this file must not break:
--
--   1. Every table has RLS AND an explicit GRANT. All grants live in section 10,
--      after every object exists, so a table added later cannot be forgotten.
--   2. Every policy has WITH CHECK, not only USING.
--   3. Prices are never trusted from the browser. Totals and tax are recomputed
--      in the database from the price list, in the order's own currency.
--   4. Money is INTEGER minor units (cents). USD 29.00 is 2900; CLP 27900 is 27900 (no minor unit).
--      `currencies.minor_digits` says how many decimals a currency has.
--   5. A browser can never mark an order paid. Only mark_order_paid(), which is
--      executable by service_role alone, can do it, and it checks that the amount
--      and currency match the order.
--   6. Files live in a PRIVATE bucket. The database never hands out a file path
--      to a browser; authorize_download() (service_role only) returns it to your
--      server, which signs a short-lived URL.
--
-- HOW THE PIECES TALK TO EACH OTHER (you write the three small server parts):
--
--   Browser      rpc place_order(customer, items)  -> { token, status, total, currency }
--   Server (1)   reads the order by token with the service key, opens a payment
--                session (Stripe, Paddle, ...) for exactly that total and currency,
--                and puts the order id in the provider's metadata.
--   Server (2)   payment webhook: verify the signature, insert into payment_events
--                (unique per provider+event, so retries are harmless), then call
--                mark_order_paid(order_id, provider, reference, amount, currency).
--   Server (3)   reads `outbox` for unprocessed rows ('order_paid', ...) and sends
--                the e-mail linking to your /order/<token> page.
--   Download     browser asks your server -> server calls authorize_download(token,
--                file_id) -> gets a storage path -> createSignedUrl(path, 60).
--
-- WHO THIS SHOP SELLS TO
--
-- Seeded for LATIN AMERICA, and NOT for Algeria. store_settings.allowed_countries
-- lists the countries served and blocked_countries carries DZ, so place_order()
-- refuses a buyer in Algeria ('country_blocked') and in any country outside the
-- list ('country_not_served'), whatever the front-end sends. Empty
-- allowed_countries to sell worldwide; edit either list in the dashboard (owner
-- only). Venezuela and Cuba are left out of the seed because of sanctions and
-- payment restrictions: check that before adding them.
--
-- HOW BUYERS PAY, one table: payment_methods (all seeded SWITCHED OFF)
--
--   card      ONLINE. Bank cards through a provider. Your server opens the session
--             and a webhook calls mark_order_paid().
--   paypal    ONLINE, USD only. Same webhook path.
--   transfer  MANUAL. Bank transfer, PIX, SPEI ...: the buyer pays your account in
--             that country, uploads the receipt and types its number. The order
--             goes pending -> verifying; an admin confirms with
--             confirm_manual_payment() or rejects with reject_payment_proof() and
--             the buyer may try again. Only useful if you hold an account where
--             the buyer pays; the details in the seed are placeholders.
--
-- Cards alone leave many Latin American buyers out: PIX in Brazil, OXXO in Mexico
-- and PSE in Colombia are how a lot of people pay online. Add one row per method
-- you can really accept, as kind 'online' with the provider that settles it, or as
-- a manual transfer. Each method says which currencies and countries it takes.
-- `details` is shown to buyers: never put a secret in it. Provider keys belong in
-- your server's environment, not here.
--
-- TAX. The database computes tax from `tax_rates` for the buyer's country, and
-- seeds NO rates: they change, and being wrong is your liability. Several Latin
-- American countries tax digital goods sold by a foreign seller (Chile and
-- Colombia from the first sale; Mexico, Peru and Uruguay too; Brazil is phasing in
-- a new VAT), so selling yourself can mean registering with each tax authority.
-- The usual way out is a merchant of record: it is the legal seller and remits the
-- tax. In that case keep collect_tax OFF here and let the provider charge it.
--
-- =============================================================================

begin;

-- =============================================================================
-- 0. Preflight
-- =============================================================================
--
-- This file builds a NEW shop. It is safe to re-run on a database it created, but
-- it cannot upgrade a database created from a different schema. `create table if
-- not exists` skips a table that already exists, so an older `orders` table would
-- stay as it was and the first statement that used a new column would fail with
-- a confusing "column does not exist". Stop here instead, with the reason.
--
-- The check looks for the physical-goods OpenStore DZ schema (product_variants,
-- delivery_zones), or an `orders` table that is not this file's.
do $$
begin
  if to_regclass('public.product_variants') is not null
     or to_regclass('public.delivery_zones') is not null
     or (
       to_regclass('public.orders') is not null
       and not exists (
         select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'orders' and column_name = 'payment_method'
       )
     )
  then
    raise exception
      'This database already holds a different shop schema (the physical-goods OpenStore DZ tables, or an older version of this file). Run this file on a NEW, empty Supabase project, or empty the public schema first. Nothing was changed.'
      using errcode = 'check_violation';
  end if;
end $$;

-- =============================================================================
-- 1. Types
-- =============================================================================

do $$ begin
  create type public.admin_role as enum ('owner', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.order_status as enum (
    'pending',    -- placed, awaiting payment
    'verifying',  -- manual payment: the buyer sent a receipt, an admin must check it
    'paid',       -- payment confirmed, goods delivered
    'cancelled',  -- abandoned by an admin
    'expired',    -- never paid within the window (see expire_pending_orders)
    'refunded',   -- money returned, access revoked
    'disputed'    -- chargeback open, access suspended
  );
exception when duplicate_object then null; end $$;


-- =============================================================================
-- 2. Tables
-- =============================================================================

create table if not exists public.currencies (
  code          text primary key check (code ~ '^[A-Z]{3}$'),     -- ISO 4217
  name          text not null,
  minor_digits  smallint not null default 2 check (minor_digits between 0 and 3),
  is_active     boolean not null default true,
  sort_order    int not null default 0
);

-- Store profile. Singleton: the CHECK on id makes a second row impossible.
create table if not exists public.store_settings (
  id                  smallint primary key default 1 check (id = 1),

  name                text not null default 'My Digital Shop',
  tagline             text,
  description         text,
  logo_url            text,
  banner_url          text,
  brand_color         text check (brand_color ~ '^#[0-9a-fA-F]{6}$'),

  -- Legal disclosures most jurisdictions expect an online seller to publish.
  legal_name          text,
  tax_id              text,          -- VAT / EIN / company tax number
  company_number      text,
  support_email       text,
  address             text,
  country             text check (country ~ '^[A-Z]{2}$'),   -- where the seller is
  terms_url           text,
  privacy_url         text,

  default_locale      text not null default 'en',
  default_currency    text not null default 'USD' references public.currencies(code),
  is_open             boolean not null default true,        -- false stops all new orders

  -- Tax. Off until the owner sets rates. When prices_include_tax is true the
  -- shelf price is what the buyer pays and tax is the portion inside it.
  collect_tax         boolean not null default false,
  prices_include_tax  boolean not null default false,

  -- Where you sell. Empty allowed list means "everywhere not blocked".
  allowed_countries   text[] not null default '{}'
                      check (array_to_string(allowed_countries, '') ~ '^([A-Z]{2})*$'),
  blocked_countries   text[] not null default '{}'
                      check (array_to_string(blocked_countries, '') ~ '^([A-Z]{2})*$'),

  refund_days         int not null default 14 check (refund_days >= 0),
  refund_policy       text,

  -- Delivery defaults. NULL download limit / expiry means unlimited / lifetime.
  default_download_limit int check (default_download_limit is null or default_download_limit >= 1) default 10,
  default_access_days    int check (default_access_days is null or default_access_days >= 1),

  announcement          text,
  announcement_enabled  boolean not null default false,
  x_url                 text,
  instagram_url         text,
  youtube_url           text,
  tiktok_url            text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Admin accounts. Roles live here, never on the user object itself.
create table if not exists public.admin_users (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  role        public.admin_role not null default 'staff',
  created_at  timestamptz not null default now()
);

create table if not exists public.categories (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  -- {"fr": {"name": "...", "description": "..."}, "ar": {...}}: any language,
  -- no schema change to add one.
  translations  jsonb not null default '{}'::jsonb check (jsonb_typeof(translations) = 'object'),
  description   text,
  image_url     text,
  sort_order    int not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.products (
  id              uuid primary key default gen_random_uuid(),
  slug            text not null unique,
  name            text not null,
  description     text,
  translations    jsonb not null default '{}'::jsonb check (jsonb_typeof(translations) = 'object'),
  status          text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  category_id     uuid references public.categories(id) on delete set null,
  cover_image_url text,
  version         text,

  -- What a purchase delivers, besides any files attached in product_files:
  --   none       nothing extra
  --   pool       a key from keys the owner uploaded to license_keys
  --   generated  a random key minted at purchase time
  license_mode    text not null default 'none' check (license_mode in ('none', 'pool', 'generated')),
  -- Seats / copies per order. 1 means a buyer cannot order two of the same product.
  max_quantity    int not null default 1 check (max_quantity between 1 and 50),
  -- Per-product overrides of the store defaults.
  download_limit  int check (download_limit is null or download_limit >= 1),
  access_days     int check (access_days is null or access_days >= 1),

  published_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- One row per product per currency. A product with no row for a currency cannot
-- be bought in that currency: the database never converts exchange rates.
create table if not exists public.product_prices (
  product_id        uuid not null references public.products(id) on delete cascade,
  currency          text not null references public.currencies(code),
  amount            int not null check (amount >= 0),
  -- Original price while on sale. Display only.
  compare_at_amount int check (compare_at_amount is null or compare_at_amount > amount),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (product_id, currency)
);

create table if not exists public.product_images (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products(id) on delete cascade,
  url         text not null,
  alt         text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- What is in the box. This table is PUBLIC metadata (the product page lists it).
-- The storage path is in product_file_paths, which no browser can read.
create table if not exists public.product_files (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  name          text not null,
  size_bytes    bigint check (size_bytes is null or size_bytes >= 0),
  content_type  text,
  version       text,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

-- Where a file really lives. Exactly one of the two columns is set:
--   storage_path  a file in the private 'digital-files' bucket (limited, signed,
--                 revocable: the recommended way)
--   external_url  an https link on another host (Google Drive, Mega, your own
--                 server) for a seller who keeps files elsewhere. It stays secret
--                 like the path: it leaves the database only after payment, only
--                 to your server, and each release is counted. But once released,
--                 anyone holding the link can share it, and a link outside your
--                 bucket cannot be limited or revoked afterwards.
create table if not exists public.product_file_paths (
  file_id       uuid primary key references public.product_files(id) on delete cascade,
  storage_path  text unique check (storage_path !~ '^/' and storage_path !~ '\.\.'),
  external_url  text check (external_url ~ '^https://[^[:space:]]+$' and length(external_url) <= 2000),
  check (num_nonnulls(storage_path, external_url) = 1)
);

-- Pre-loaded keys (license_mode = 'pool') and minted keys ('generated').
-- Never readable by a browser; buyers get theirs through track_order().
create table if not exists public.license_keys (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references public.products(id) on delete restrict,
  key            text not null check (length(key) between 4 and 200),
  order_item_id  uuid,                      -- set when sold (FK added below)
  assigned_at    timestamptz,
  revoked_at     timestamptz,               -- refund or chargeback
  created_at     timestamptz not null default now(),
  unique (product_id, key)
);

create table if not exists public.tax_rates (
  country     text primary key check (country ~ '^[A-Z]{2}$'),
  name        text not null default 'VAT',
  rate_bps    int not null check (rate_bps between 0 and 10000),   -- 2000 = 20.00%
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.blocked_emails (
  email       text primary key check (email = lower(btrim(email))),
  reason      text,
  created_at  timestamptz not null default now()
);

-- How a buyer can pay. `manual` methods (bank transfer, PIX, SPEI) are confirmed by a person; `online`
-- methods name a provider whose webhook confirms them.
create table if not exists public.payment_methods (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  kind          text not null check (kind in ('manual', 'online')),
  provider      text check (provider is null or provider ~ '^[a-z][a-z0-9_]*$'),
  label         text not null,
  translations  jsonb not null default '{}'::jsonb check (jsonb_typeof(translations) = 'object'),
  -- Shown to the buyer while the order is unpaid (how to pay, what to send).
  instructions  text,
  -- PUBLIC payee details for a manual method (account holder, bank, account
  -- number, PIX key, CLABE ...). The buyer must see them to pay. Never store a
  -- secret here.
  details       jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  -- Empty list means "any". Example: a PIX method would be {BRL} / {BR}.
  currencies    text[] not null default '{}'
                check (array_to_string(currencies, '') ~ '^([A-Z]{3})*$'),
  countries     text[] not null default '{}'
                check (array_to_string(countries, '') ~ '^([A-Z]{2})*$'),
  -- How long an unpaid order is held before it expires. A transfer takes longer
  -- than a card, so a transfer gets days and the online methods get hours.
  hold_hours    int not null default 24 check (hold_hours between 1 and 720),
  is_active     boolean not null default false,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((kind = 'online' and provider is not null) or (kind = 'manual' and provider is null))
);

create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  -- Unguessable token for the buyer's order page. Never expose the id.
  public_token   uuid not null unique default gen_random_uuid(),

  customer_name  text not null,
  email          text not null check (email = lower(btrim(email))),
  country        text not null check (country ~ '^[A-Z]{2}$'),   -- billing country, drives tax
  currency       text not null references public.currencies(code),
  locale         text check (locale ~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$'),
  -- Optional contact number (WhatsApp or phone). Required for a manual payment
  -- such as a bank transfer, where an admin may need to reach the buyer about the receipt.
  phone          text check (phone ~ '^[0-9+()\s\-]{6,24}$'),
  payment_method text references public.payment_methods(code),

  -- Recomputed by trigger. Anything supplied by a browser is ignored.
  subtotal       int not null default 0 check (subtotal >= 0),
  tax_amount     int not null default 0 check (tax_amount >= 0),
  total          int not null default 0 check (total >= 0),
  -- Tax snapshot taken when the order was placed, so later rate edits never
  -- change what was charged.
  tax_rate_bps        int not null default 0 check (tax_rate_bps between 0 and 10000),
  tax_name            text,
  prices_include_tax  boolean not null default false,

  status         public.order_status not null default 'pending',

  payment_provider  text,
  payment_ref       text,
  paid_at           timestamptz,
  refunded_at       timestamptz,
  -- The admin who confirmed a manual payment. Null for online payments.
  confirmed_by      uuid references auth.users(id) on delete set null,

  -- Consent evidence. Selling digital content to EU consumers needs the buyer to
  -- agree to immediate delivery and the loss of the withdrawal right; keep proof.
  terms_accepted_at     timestamptz not null default now(),
  withdrawal_waived_at  timestamptz,

  internal_note  text,
  client_key     text,    -- salted hash of the caller's IP, for rate limiting only

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create unique index if not exists orders_payment_ref_key
  on public.orders (payment_provider, payment_ref) where payment_ref is not null;

-- Snapshots what was bought, at the price it was bought for.
create table if not exists public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  product_id     uuid references public.products(id) on delete set null,
  product_name   text not null,
  quantity       int not null check (quantity > 0),
  unit_price     int not null check (unit_price >= 0),
  created_at     timestamptz not null default now(),
  unique (order_id, product_id)
);

alter table public.license_keys
  drop constraint if exists license_keys_order_item_fk;
alter table public.license_keys
  add constraint license_keys_order_item_fk
  foreign key (order_item_id) references public.order_items(id) on delete set null;

-- The right to download, one per purchased product that has files.
-- products.id is ON DELETE RESTRICT: a product that has been sold cannot be
-- deleted out from under its buyers. Archive it instead.
create table if not exists public.entitlements (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders(id) on delete cascade,
  order_item_id   uuid not null unique references public.order_items(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete restrict,
  download_limit  int check (download_limit is null or download_limit >= 1),
  downloads_used  int not null default 0 check (downloads_used >= 0),
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz not null default now(),
  unique (order_id, product_id)
);

create table if not exists public.download_log (
  id              bigserial primary key,
  entitlement_id  uuid not null references public.entitlements(id) on delete cascade,
  file_id         uuid references public.product_files(id) on delete set null,
  client_key      text,
  created_at      timestamptz not null default now()
);

-- Reviews are written only through submit_review(), which proves the reviewer
-- bought the product. There is no way to insert one directly.
create table if not exists public.reviews (
  id                 uuid primary key default gen_random_uuid(),
  product_id         uuid not null references public.products(id) on delete cascade,
  order_id           uuid references public.orders(id) on delete set null,
  customer_name      text not null check (length(btrim(customer_name)) between 2 and 120),
  rating             int not null check (rating between 1 and 5),
  comment            text not null check (length(btrim(comment)) between 3 and 2000),
  verified_purchase  boolean not null default false,
  is_approved        boolean not null default false,
  created_at         timestamptz not null default now()
);

create unique index if not exists reviews_one_per_purchase
  on public.reviews (order_id, product_id) where order_id is not null;

-- Receipts for manual payments (bank transfer). One order may collect several attempts: an
-- admin can reject a receipt and the buyer sends another. The same receipt number
-- cannot back two orders (see payment_proofs_ref_key), which is the classic way
-- to claim goods twice with one transfer.
create table if not exists public.payment_proofs (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  method        text not null references public.payment_methods(code),
  sender_name   text not null check (length(btrim(sender_name)) between 2 and 120),
  -- The number printed on the transfer receipt or confirmation.
  reference     text not null check (length(btrim(reference)) between 3 and 100),
  -- Path in the private 'payment-proofs' bucket: <order public_token>/<file>.
  storage_path  text check (storage_path is null or (storage_path !~ '^/' and storage_path !~ '\.\.'
                                                      and length(storage_path) <= 300)),
  note          text check (note is null or length(note) <= 1000),
  status        text not null default 'submitted' check (status in ('submitted', 'accepted', 'rejected')),
  reject_reason text,
  reviewed_by   uuid references auth.users(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);

-- Payment provider webhook audit. Unique per provider+event: a retry is a no-op.
create table if not exists public.payment_events (
  id            uuid primary key default gen_random_uuid(),
  provider      text not null,
  event_id      text not null,
  type          text not null,
  data          jsonb not null default '{}'::jsonb,
  processed_at  timestamptz,
  note          text,
  created_at    timestamptz not null default now(),
  unique (provider, event_id)
);

-- Work for your server to do after the transaction commits (send an e-mail,
-- warn the owner). A table instead of an HTTP call from inside a trigger: a
-- dead endpoint can never slow or fail a checkout, and nothing is lost.
create table if not exists public.outbox (
  id            bigserial primary key,
  kind          text not null check (kind in
                  ('order_paid', 'order_refunded', 'order_disputed', 'license_shortage',
                   'payment_submitted', 'payment_rejected')),
  order_id      uuid references public.orders(id) on delete cascade,
  payload       jsonb not null default '{}'::jsonb,
  attempts      int not null default 0,
  last_error    text,
  processed_at  timestamptz,
  created_at    timestamptz not null default now()
);


-- =============================================================================
-- 3. Indexes
-- Only on columns a known query filters or sorts by.
-- =============================================================================

create index if not exists products_status_category_idx on public.products (status, category_id);
create index if not exists product_images_product_idx   on public.product_images (product_id);
create index if not exists product_files_product_idx    on public.product_files (product_id);
create index if not exists license_keys_free_idx
  on public.license_keys (product_id, created_at) where order_item_id is null and revoked_at is null;
create index if not exists license_keys_item_idx        on public.license_keys (order_item_id);

create index if not exists orders_created_at_idx   on public.orders (created_at desc);
create index if not exists orders_status_idx       on public.orders (status, created_at desc);
create index if not exists orders_client_key_idx   on public.orders (client_key, created_at desc);
create index if not exists orders_email_idx        on public.orders (email, created_at desc);
create index if not exists order_items_product_idx on public.order_items (product_id);
create index if not exists entitlements_product_idx on public.entitlements (product_id);
create index if not exists download_log_ent_idx    on public.download_log (entitlement_id);
create index if not exists reviews_product_idx     on public.reviews (product_id) where is_approved;
create index if not exists outbox_pending_idx      on public.outbox (created_at) where processed_at is null;
create index if not exists payment_proofs_order_idx on public.payment_proofs (order_id, created_at);
create index if not exists orders_verifying_idx
  on public.orders (created_at) where status = 'verifying';
-- A receipt number backs one order only. A rejected one frees the number again.
create unique index if not exists payment_proofs_ref_key
  on public.payment_proofs (method, lower(btrim(reference))) where status <> 'rejected';


-- =============================================================================
-- 4. Functions
-- =============================================================================

-- Is this user an admin, and of what role? SECURITY DEFINER so a policy can read
-- admin_users without recursing; search_path pinned and names schema-qualified.
create or replace function public.has_admin_role(_user_id uuid, _roles public.admin_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_users
    where user_id = _user_id and role = any(_roles)
  );
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.normalize_email(raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(btrim(coalesce(raw, '')));
$$;

create or replace function public.is_valid_email(e text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select e is not null
     and length(e) <= 254
     and e ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$';
$$;

-- A random key like 7F3A-91C0-5B2E-D84A (64 random bits, no extension needed).
create or replace function public.generate_license_key()
returns text
language sql
volatile
set search_path = ''
as $$
  select concat_ws('-', substr(h, 1, 4), substr(h, 5, 4), substr(h, 9, 4), substr(h, 13, 4))
  from (select upper(replace(gen_random_uuid()::text, '-', '')) as h) x;
$$;

/*
 * Text normalisation for search, in two parts:
 *   Arabic: hamza forms collapse to bare alef, alef maqsura to ya, taa marbuta
 *           to ha, waw-hamza to waw, ya-hamza to ya; diacritics and tatweel go.
 *           These are the equivalences people really type on a phone.
 *   Latin:  common accents are stripped (cafe finds café) without an extension.
 * Both lists below must stay the same length; translate() silently ignores extra
 * characters in the second list, which would shift every mapping after them.
 */
create or replace function public.normalize_search(input text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
    regexp_replace(
      regexp_replace(
        translate(
          lower(coalesce(input, '')),
          'أإآٱىةؤئàáâãäåçèéêëìíîïñòóôõöùúûüýÿ',
          'اااايهويaaaaaaceeeeiiiinooooouuuuyy'
        ),
        '[\u064B-\u0652\u0670\u0640]', '', 'g'
      ),
      '\s+', ' ', 'g'
    )
  );
$$;

-- Recompute an order's money from its lines. Only while the order is pending:
-- once paid, the amounts are what the buyer was charged and nothing here may
-- touch them.
create or replace function public.recalculate_order(p_order_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  with calc as (
    select o.id,
           l.sub,
           (case when o.prices_include_tax
                 then round(l.sub::numeric * o.tax_rate_bps / (10000 + o.tax_rate_bps))
                 else round(l.sub::numeric * o.tax_rate_bps / 10000)
            end)::int as tax,
           o.prices_include_tax as incl
      from public.orders o
     cross join (
       select coalesce(sum(oi.quantity * oi.unit_price), 0)::int as sub
         from public.order_items oi where oi.order_id = p_order_id
     ) l
     where o.id = p_order_id and o.status = 'pending'
  )
  update public.orders o
     set subtotal   = c.sub,
         tax_amount = c.tax,
         total      = case when c.incl then c.sub else c.sub + c.tax end
    from calc c
   where o.id = c.id;
$$;

create or replace function public.recalculate_order_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recalculate_order(old.order_id);
    return old;
  end if;
  perform public.recalculate_order(new.order_id);
  return new;
end;
$$;

-- Field validation and the owner's selling rules. The browser validates for the
-- user's benefit; this is the actual control.
create or replace function public.validate_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s record;
  r record;
  pm record;
begin
  if length(btrim(coalesce(new.customer_name, ''))) < 2 or length(new.customer_name) > 120 then
    raise exception 'Invalid customer_name' using errcode = 'check_violation';
  end if;

  new.email := public.normalize_email(new.email);
  if not public.is_valid_email(new.email) then
    raise exception 'Invalid email' using errcode = 'check_violation', hint = 'invalid_email';
  end if;

  new.country  := upper(btrim(coalesce(new.country, '')));
  new.currency := upper(btrim(coalesce(new.currency, '')));
  if new.country !~ '^[A-Z]{2}$' then
    raise exception 'Invalid country' using errcode = 'check_violation', hint = 'invalid_country';
  end if;
  if not exists (select 1 from public.currencies c where c.code = new.currency and c.is_active) then
    raise exception 'Currency not supported' using errcode = 'check_violation', hint = 'invalid_currency';
  end if;

  select * into s from public.store_settings where id = 1;
  if not found or s.is_open is not true then
    raise exception 'The shop is not accepting orders right now' using errcode = 'check_violation', hint = 'shop_closed';
  end if;

  if new.country = any(s.blocked_countries) then
    raise exception 'We cannot sell to this country' using errcode = 'check_violation', hint = 'country_blocked';
  end if;
  if coalesce(array_length(s.allowed_countries, 1), 0) > 0 and not (new.country = any(s.allowed_countries)) then
    raise exception 'We do not sell to this country yet' using errcode = 'check_violation', hint = 'country_not_served';
  end if;

  if exists (select 1 from public.blocked_emails b where b.email = new.email) then
    raise exception 'This e-mail address cannot place orders' using errcode = 'check_violation', hint = 'email_blocked';
  end if;

  -- Tax snapshot. No row for the country, or tax switched off, means no tax.
  new.tax_rate_bps := 0;
  new.tax_name := null;
  new.prices_include_tax := s.prices_include_tax;
  if s.collect_tax then
    select tr.rate_bps, tr.name into r
      from public.tax_rates tr where tr.country = new.country and tr.is_active;
    if found then
      new.tax_rate_bps := r.rate_bps;
      new.tax_name := r.name;
    end if;
  end if;

  -- Phone: optional, tidied, and checked.
  new.phone := nullif(btrim(coalesce(new.phone, '')), '');
  if new.phone is not null and new.phone !~ '^[0-9+()\s\-]{6,24}$' then
    raise exception 'Invalid phone number' using errcode = 'check_violation', hint = 'invalid_phone';
  end if;

  -- Payment method: it must exist, be switched on, and accept this currency and
  -- country. (A free order needs none; place_order() requires one when total > 0.)
  if new.payment_method is not null then
    select * into pm from public.payment_methods m where m.code = new.payment_method and m.is_active;
    if not found then
      raise exception 'This payment method is not available'
        using errcode = 'check_violation', hint = 'payment_method_unavailable';
    end if;
    if coalesce(array_length(pm.currencies, 1), 0) > 0 and not (new.currency = any(pm.currencies)) then
      raise exception 'This payment method does not accept %', new.currency
        using errcode = 'check_violation', hint = 'payment_method_currency';
    end if;
    if coalesce(array_length(pm.countries, 1), 0) > 0 and not (new.country = any(pm.countries)) then
      raise exception 'This payment method is not available in your country'
        using errcode = 'check_violation', hint = 'payment_method_country';
    end if;
    if pm.kind = 'manual' and new.phone is null then
      raise exception 'A phone number is required for this payment method'
        using errcode = 'check_violation', hint = 'phone_required';
    end if;
  end if;

  -- A new order always opens pending and unpaid, whatever the caller sent.
  new.status := 'pending';
  new.subtotal := 0;
  new.tax_amount := 0;
  new.total := 0;
  new.paid_at := null;
  new.refunded_at := null;
  new.confirmed_by := null;
  new.payment_provider := null;
  new.payment_ref := null;
  return new;
end;
$$;

-- The line's price and name come from the price list, in the order's currency.
-- The browser sends only a product id and a quantity.
create or replace function public.validate_order_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_currency text;
  v_status   public.order_status;
  v_name     text;
  v_max      int;
  v_mode     text;
  v_amount   int;
begin
  select o.currency, o.status into v_currency, v_status
    from public.orders o where o.id = new.order_id;
  if not found then
    raise exception 'Order does not exist' using errcode = 'check_violation';
  end if;
  if v_status <> 'pending' then
    raise exception 'Order is no longer open' using errcode = 'check_violation';
  end if;
  if new.product_id is null then
    raise exception 'Missing product' using errcode = 'check_violation';
  end if;

  -- Published only: a draft or archived product cannot be bought even by someone
  -- who knows its id.
  select p.name, p.max_quantity, p.license_mode, pp.amount
    into v_name, v_max, v_mode, v_amount
    from public.products p
    join public.product_prices pp on pp.product_id = p.id and pp.currency = v_currency
   where p.id = new.product_id and p.status = 'published';
  if not found then
    raise exception 'Product unavailable in this currency'
      using errcode = 'check_violation', hint = 'product_unavailable';
  end if;

  if new.quantity is null or new.quantity < 1 or new.quantity > v_max then
    raise exception 'Invalid quantity' using errcode = 'check_violation', hint = 'invalid_quantity';
  end if;

  -- Best effort: pending orders do not reserve keys. A genuine shortage at
  -- payment time is reported through the outbox instead of failing a paid order.
  if v_mode = 'pool' and (
    select count(*) from public.license_keys k
     where k.product_id = new.product_id and k.order_item_id is null and k.revoked_at is null
  ) < new.quantity then
    raise exception 'Out of stock' using errcode = 'check_violation', hint = 'out_of_stock';
  end if;

  new.product_name := v_name;
  new.unit_price   := v_amount;
  return new;
end;
$$;

/*
 * Deliver an order: create download rights and assign license keys. Called once,
 * at the moment an order becomes paid, from mark_order_paid() or from
 * place_order() for a zero-total order. Not callable by any API role.
 */
create or replace function public.fulfil_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  o       record;
  v_got   int;
begin
  select email, total, currency into o from public.orders where id = p_order_id;

  for r in
    select oi.id as item_id, oi.product_id, oi.quantity, p.license_mode,
           coalesce(p.download_limit,
                    (select s.default_download_limit from public.store_settings s where s.id = 1)) as dl_limit,
           coalesce(p.access_days,
                    (select s.default_access_days from public.store_settings s where s.id = 1)) as days,
           exists (select 1 from public.product_files f where f.product_id = p.id) as has_files
      from public.order_items oi
      join public.products p on p.id = oi.product_id
     where oi.order_id = p_order_id
  loop
    if r.has_files then
      insert into public.entitlements (order_id, order_item_id, product_id, download_limit, expires_at)
      values (p_order_id, r.item_id, r.product_id, r.dl_limit,
              case when r.days is null then null else now() + make_interval(days => r.days) end)
      on conflict (order_item_id) do nothing;
    end if;

    if r.license_mode = 'pool' then
      with picked as (
        select k.id from public.license_keys k
         where k.product_id = r.product_id and k.order_item_id is null and k.revoked_at is null
         order by k.created_at, k.id
         limit r.quantity
         for update skip locked
      )
      update public.license_keys k
         set order_item_id = r.item_id, assigned_at = now()
        from picked where k.id = picked.id;
      get diagnostics v_got = row_count;
      if v_got < r.quantity then
        insert into public.outbox (kind, order_id, payload)
        values ('license_shortage', p_order_id,
                jsonb_build_object('product_id', r.product_id, 'missing', r.quantity - v_got));
      end if;
    elsif r.license_mode = 'generated' then
      insert into public.license_keys (product_id, key, order_item_id, assigned_at)
      select r.product_id, public.generate_license_key(), r.item_id, now()
        from generate_series(1, r.quantity);
    end if;
  end loop;

  insert into public.outbox (kind, order_id, payload)
  values ('order_paid', p_order_id,
          jsonb_build_object('email', o.email, 'total', o.total, 'currency', o.currency));
end;
$$;

-- Order status rules. Legal moves only, and a human can never move an order to
-- paid by hand: that would hand over files with no payment and no delivery.
create or replace function public.guard_order_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if not (
       (old.status = 'pending'   and new.status in ('paid', 'verifying', 'cancelled', 'expired'))
    or (old.status = 'verifying' and new.status in ('paid', 'pending', 'cancelled'))
    or (old.status = 'expired'   and new.status in ('paid', 'cancelled'))
    or (old.status = 'paid'     and new.status in ('refunded', 'disputed'))
    or (old.status = 'disputed' and new.status in ('paid', 'refunded'))
  ) then
    raise exception 'Invalid order status change: % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  -- current_user is the API role for a direct dashboard UPDATE, and the function
  -- owner inside mark_order_paid(), so this separates the two.
  if current_user in ('anon', 'authenticated')
     and new.status = 'paid' and old.status in ('pending', 'verifying', 'expired') then
    raise exception 'An order becomes paid through a payment, not by hand'
      using errcode = 'check_violation';
  end if;

  if new.status = 'refunded' then
    new.refunded_at := coalesce(new.refunded_at, now());
  end if;
  return new;
end;
$$;

-- What a status change does to what the buyer holds.
create or replace function public.on_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('refunded', 'disputed') and old.status = 'paid' then
    update public.entitlements set revoked_at = now()
     where order_id = new.id and revoked_at is null;
    update public.license_keys k set revoked_at = now()
      from public.order_items oi
     where k.order_item_id = oi.id and oi.order_id = new.id and k.revoked_at is null;
    insert into public.outbox (kind, order_id)
    values (case when new.status = 'refunded' then 'order_refunded' else 'order_disputed' end, new.id);

  elsif new.status = 'refunded' and old.status = 'disputed' then
    insert into public.outbox (kind, order_id) values ('order_refunded', new.id);

  elsif new.status = 'paid' and old.status = 'disputed' then
    -- Dispute won: give access back.
    update public.entitlements set revoked_at = null where order_id = new.id;
    update public.license_keys k set revoked_at = null
      from public.order_items oi
     where k.order_item_id = oi.id and oi.order_id = new.id;
  end if;
  return new;
end;
$$;

-- Place an order and return what the checkout needs next.
--
-- One transaction, one round trip, no half-written orders. The caller sends
-- customer details and a list of {product_id, quantity}; never a price.
create or replace function public.place_order(
  p_customer jsonb,
  p_items    jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_token    uuid;
  v_item     record;
  v_units    int;
  v_headers  json;
  v_ip       text;
  v_client   text;
  v_email    text;
  v_order    public.orders%rowtype;
begin
  if p_customer is null or p_items is null
     or jsonb_typeof(p_customer) <> 'object' or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Missing order details' using errcode = 'check_violation';
  end if;

  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 20 then
    raise exception 'Order must contain between 1 and 20 items' using errcode = 'check_violation';
  end if;

  select coalesce(sum(greatest(coalesce((e->>'quantity')::int, 1), 1)), 0)
    into v_units from jsonb_array_elements(p_items) e;
  if v_units > 50 then
    raise exception 'Too many items in one order'
      using errcode = 'check_violation', hint = 'too_many_items';
  end if;

  if coalesce((p_customer->>'accepted_terms')::boolean, false) is not true then
    raise exception 'The terms must be accepted'
      using errcode = 'check_violation', hint = 'terms_not_accepted';
  end if;

  -- One connection may place ten orders an hour; one e-mail may hold five unpaid
  -- orders. The IP is stored only as a salted hash.
  --
  -- IMPORTANT: cf-connecting-ip is trustworthy only when requests reach the API
  -- through Cloudflare, as on hosted Supabase. If you self-host without it, a
  -- caller can send that header themselves, so treat the per-IP limit as
  -- best-effort there. The per-e-mail limit does not depend on it.
  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_ip := coalesce(
    nullif(btrim(v_headers->>'cf-connecting-ip'), ''),
    nullif(btrim(regexp_replace(coalesce(v_headers->>'x-forwarded-for', ''), '^.*,', '')), '')
  );
  if v_ip is not null then
    v_client := md5('openstore-order:' || v_ip);
    perform pg_advisory_xact_lock(hashtext(v_client));
    if (select count(*) from public.orders o
         where o.client_key = v_client and o.created_at > now() - interval '1 hour') >= 10 then
      raise exception 'Too many orders from this connection, please try again later'
        using errcode = 'check_violation', hint = 'too_many_orders';
    end if;
  end if;

  v_email := public.normalize_email(p_customer->>'email');
  if v_email <> '' then
    perform pg_advisory_xact_lock(hashtext('openstore-email:' || v_email));
    if (select count(*) from public.orders o
         where o.email = v_email and o.status = 'pending'
           and o.created_at > now() - interval '1 hour') >= 5 then
      raise exception 'Too many unpaid orders for this e-mail address'
        using errcode = 'check_violation', hint = 'too_many_pending';
    end if;
  end if;

  -- validate_order() runs as the BEFORE INSERT trigger and does the field checks,
  -- the selling rules and the tax snapshot. This function only decides the rows.
  insert into public.orders (customer_name, email, country, currency, locale, phone,
                             payment_method, terms_accepted_at, withdrawal_waived_at, client_key)
  values (
    coalesce(p_customer->>'customer_name', ''),
    v_email,
    coalesce(p_customer->>'country', ''),
    coalesce(nullif(p_customer->>'currency', ''),
             (select s.default_currency from public.store_settings s where s.id = 1)),
    nullif(p_customer->>'locale', ''),
    nullif(p_customer->>'phone', ''),
    nullif(p_customer->>'payment_method', ''),
    now(),
    case when coalesce((p_customer->>'waive_withdrawal')::boolean, false) then now() end,
    v_client
  )
  returning id, public_token into v_order_id, v_token;

  -- The same product listed twice becomes one line with the summed quantity.
  for v_item in
    select (e->>'product_id')::uuid as product_id,
           sum(greatest(coalesce((e->>'quantity')::int, 1), 1))::int as quantity
      from jsonb_array_elements(p_items) e
     group by 1
  loop
    insert into public.order_items (order_id, product_id, quantity)
    values (v_order_id, v_item.product_id, v_item.quantity);
  end loop;

  perform public.recalculate_order(v_order_id);
  select * into v_order from public.orders where id = v_order_id;

  if v_order.total > 0 and v_order.payment_method is null then
    raise exception 'Choose a payment method'
      using errcode = 'check_violation', hint = 'payment_method_required';
  end if;

  -- A free order has nothing to charge, so it is paid and delivered right here.
  if v_order.total = 0 then
    update public.orders
       set status = 'paid', paid_at = now(), payment_provider = 'free'
     where id = v_order_id;
    perform public.fulfil_order(v_order_id);
    v_order.status := 'paid';
  end if;

  -- payment_kind tells the checkout what to do next: 'manual' shows the transfer
  -- instructions and the receipt form, 'online' sends the buyer to the provider
  -- (your server opens the session), 'free' needs nothing.
  return jsonb_build_object(
    'token',          v_token,
    'status',         v_order.status,
    'total',          v_order.total,
    'currency',       v_order.currency,
    'payment_method', v_order.payment_method,
    'payment_kind',   case when v_order.total = 0 then 'free'
                           else (select pm.kind from public.payment_methods pm
                                  where pm.code = v_order.payment_method) end,
    'provider',       (select pm.provider from public.payment_methods pm
                        where pm.code = v_order.payment_method)
  );
end;
$$;

-- The one place an order becomes paid and gets delivered. Internal: reached only
-- from mark_order_paid() (online) and confirm_manual_payment() (a person), both of
-- which have already checked the money. No API role may call it.
create or replace function public.settle_order(
  p_order_id  uuid,
  p_provider  text,
  p_reference text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.orders
     set status = 'paid', paid_at = now(),
         payment_provider = p_provider, payment_ref = p_reference
   where id = p_order_id;

  perform public.fulfil_order(p_order_id);
end;
$$;

-- Called by YOUR payment webhook, with the service key. Never by a browser.
--
-- Returns true when this call is the one that marked the order paid, false for a
-- retry of the same payment. Raises when the money does not match the order:
-- the amount and currency are checked here, not trusted from the caller.
create or replace function public.mark_order_paid(
  p_order_id  uuid,
  p_provider  text,
  p_reference text,
  p_amount    int,
  p_currency  text
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.orders%rowtype;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found' using errcode = 'no_data_found';
  end if;

  if o.status = 'paid' then
    if o.payment_provider = p_provider and o.payment_ref = p_reference then
      return false;      -- webhook retry
    end if;
    raise exception 'Order already paid by a different payment'
      using errcode = 'check_violation', hint = 'duplicate_payment';
  end if;

  if o.status not in ('pending', 'expired') then
    raise exception 'Order cannot be paid in status %', o.status
      using errcode = 'check_violation', hint = 'bad_status';
  end if;

  if upper(p_currency) is distinct from o.currency or p_amount is distinct from o.total then
    raise exception 'Payment does not match the order'
      using errcode = 'check_violation', hint = 'amount_mismatch';
  end if;

  perform public.settle_order(p_order_id, p_provider, p_reference);
  return true;
end;
$$;

-- ── Manual payments (bank transfer) ──────────────────────────────────────────────────

-- May this storage path receive a receipt? Used by the storage policy below, so a
-- buyer can upload straight from the browser without a server round trip, yet
-- only into the folder named after THEIR order's secret token, only while that
-- order is an unpaid manual-payment order, and only five files per order.
create or replace function public.can_upload_proof(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with f as (select storage.foldername(p_name) as parts)
  select coalesce((
    select array_length(f.parts, 1) = 1
       and exists (
         select 1
           from public.orders o
           join public.payment_methods pm on pm.code = o.payment_method
          where o.public_token::text = f.parts[1]
            and o.status = 'pending'
            and pm.kind = 'manual')
       and (select count(*) from storage.objects so
             where so.bucket_id = 'payment-proofs'
               and (storage.foldername(so.name))[1] = f.parts[1]) < 5
    from f
  ), false);
$$;

-- The buyer reports a manual payment: who sent it, the receipt number, and
-- (usually) a photo already uploaded to 'payment-proofs/<token>/...'. The order
-- moves to 'verifying' and the outbox tells the owner there is something to check.
create or replace function public.submit_payment_proof(
  p_token        uuid,
  p_sender_name  text,
  p_reference    text,
  p_storage_path text default null,
  p_note         text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o      public.orders%rowtype;
  v_kind text;
  v_path text := nullif(btrim(coalesce(p_storage_path, '')), '');
begin
  select * into o from public.orders where public_token = p_token for update;
  if not found then
    raise exception 'Order not found' using errcode = 'check_violation', hint = 'not_found';
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.code = o.payment_method;
  if v_kind is distinct from 'manual' then
    raise exception 'This order is not paid by transfer' using errcode = 'check_violation', hint = 'not_manual';
  end if;

  if o.status <> 'pending' then
    raise exception 'A receipt cannot be sent for this order now'
      using errcode = 'check_violation', hint = 'bad_status';
  end if;

  if (select count(*) from public.payment_proofs pr where pr.order_id = o.id) >= 5 then
    raise exception 'Too many attempts for this order, please contact support'
      using errcode = 'check_violation', hint = 'too_many_proofs';
  end if;

  if v_path is not null then
    if v_path not like (p_token::text || '/%') or v_path ~ '\.\.' then
      raise exception 'Invalid file' using errcode = 'check_violation', hint = 'invalid_file';
    end if;
    if not exists (select 1 from storage.objects so
                    where so.bucket_id = 'payment-proofs' and so.name = v_path) then
      raise exception 'File not found: upload it first' using errcode = 'check_violation', hint = 'file_not_found';
    end if;
  end if;

  begin
    insert into public.payment_proofs (order_id, method, sender_name, reference, storage_path, note)
    values (o.id, o.payment_method, btrim(coalesce(p_sender_name, '')),
            btrim(coalesce(p_reference, '')), v_path, nullif(btrim(coalesce(p_note, '')), ''));
  exception when unique_violation then
    raise exception 'This receipt number has already been used'
      using errcode = 'check_violation', hint = 'reference_used';
  end;

  update public.orders set status = 'verifying' where id = o.id;

  insert into public.outbox (kind, order_id, payload)
  values ('payment_submitted', o.id,
          jsonb_build_object('method', o.payment_method, 'total', o.total, 'currency', o.currency));

  return jsonb_build_object('status', 'verifying');
end;
$$;

-- An admin has checked the receipt against the account and the money is there.
-- p_received is the amount the admin saw arrive, in the order's currency; it must
-- equal the order total, so a typo cannot release goods for the wrong sum. Returns
-- false when the order was already paid (a double click), true when this call did it.
create or replace function public.confirm_manual_payment(
  p_order_id uuid,
  p_received int
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  o      public.orders%rowtype;
  v_uid  uuid := auth.uid();
  v_kind text;
  v_ref  text;
begin
  if (select public.has_admin_role(v_uid, array['owner','staff']::public.admin_role[])) is not true then
    raise exception 'Only the shop''s administrators can confirm a payment'
      using errcode = 'insufficient_privilege';
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found' using errcode = 'no_data_found';
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.code = o.payment_method;
  if v_kind is distinct from 'manual' then
    raise exception 'This order is paid online and is confirmed by the provider'
      using errcode = 'check_violation', hint = 'not_manual';
  end if;

  if o.status = 'paid' then
    return false;
  end if;
  if o.status not in ('pending', 'verifying', 'expired') then
    raise exception 'Order cannot be paid in status %', o.status
      using errcode = 'check_violation', hint = 'bad_status';
  end if;

  if p_received is distinct from o.total then
    raise exception 'The amount received does not match the order total'
      using errcode = 'check_violation', hint = 'amount_mismatch';
  end if;

  select pr.reference into v_ref
    from public.payment_proofs pr
   where pr.order_id = o.id and pr.status = 'submitted'
   order by pr.created_at desc limit 1;

  update public.payment_proofs
     set status = 'accepted', reviewed_by = v_uid, reviewed_at = now()
   where order_id = o.id and status = 'submitted';

  update public.orders set confirmed_by = v_uid where id = o.id;
  perform public.settle_order(o.id, o.payment_method, v_ref);
  return true;
end;
$$;

-- The receipt is wrong, unreadable, or the money is not there. The order goes back
-- to 'pending' so the buyer can send another, and the outbox carries the reason so
-- your server can e-mail it.
create or replace function public.reject_payment_proof(
  p_proof_id uuid,
  p_reason   text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pr         public.payment_proofs%rowtype;
  v_uid      uuid := auth.uid();
  v_order_id uuid;
  v_reason   text := btrim(coalesce(p_reason, ''));
begin
  if (select public.has_admin_role(v_uid, array['owner','staff']::public.admin_role[])) is not true then
    raise exception 'Only the shop''s administrators can review a receipt'
      using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Give the buyer a reason' using errcode = 'check_violation', hint = 'reason_required';
  end if;

  select order_id into v_order_id from public.payment_proofs where id = p_proof_id;
  if not found then
    raise exception 'Receipt not found' using errcode = 'no_data_found';
  end if;

  -- Order first, then receipt: confirm_manual_payment() takes them in this order too.
  perform 1 from public.orders where id = v_order_id for update;
  select * into pr from public.payment_proofs where id = p_proof_id for update;
  if pr.status <> 'submitted' then
    raise exception 'This receipt was already reviewed' using errcode = 'check_violation', hint = 'already_reviewed';
  end if;

  update public.payment_proofs
     set status = 'rejected', reject_reason = v_reason, reviewed_by = v_uid, reviewed_at = now()
   where id = p_proof_id;

  update public.orders set status = 'pending' where id = v_order_id and status = 'verifying';

  insert into public.outbox (kind, order_id, payload)
  values ('payment_rejected', v_order_id, jsonb_build_object('reason', v_reason));
end;
$$;

-- Close orders nobody paid. Schedule it (pg_cron, or a cron-triggered function).
-- Each order is held for ITS payment method's hold_hours: days for a bank transfer,
-- hours for a card. An order in 'verifying' never expires; a person decides it.
create or replace function public.expire_pending_orders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with u as (
    update public.orders o
       set status = 'expired'
     where o.status = 'pending'
       and o.created_at < now() - make_interval(hours => coalesce(
             (select pm.hold_hours from public.payment_methods pm where pm.code = o.payment_method), 24))
    returning 1
  )
  select count(*) into v_n from u;
  return v_n;
end;
$$;

-- Check a download and spend one of its uses. Returns to YOUR server either a
-- private storage_path (sign a short-lived URL for it) or an external_url
-- (redirect to it); exactly one of the two is non-null. A use is spent when the
-- answer is issued, not when the transfer finishes.
create or replace function public.authorize_download(
  p_token     uuid,
  p_file_id   uuid,
  p_client_key text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order  record;
  v_file   record;
  v_ent    public.entitlements%rowtype;
  v_path   text;
  v_url    text;
begin
  select o.id, o.status into v_order from public.orders o where o.public_token = p_token;
  if not found or v_order.status <> 'paid' then
    raise exception 'Download not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  select f.id, f.name, f.product_id into v_file from public.product_files f where f.id = p_file_id;
  if not found then
    raise exception 'Download not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  -- Row lock: two parallel requests cannot both spend the last download.
  select * into v_ent from public.entitlements e
   where e.order_id = v_order.id and e.product_id = v_file.product_id
   for update;
  if not found then
    raise exception 'Download not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  if v_ent.revoked_at is not null then
    raise exception 'Access has been revoked' using errcode = 'check_violation', hint = 'revoked';
  end if;
  if v_ent.expires_at is not null and v_ent.expires_at <= now() then
    raise exception 'Access has expired' using errcode = 'check_violation', hint = 'expired';
  end if;
  if v_ent.download_limit is not null and v_ent.downloads_used >= v_ent.download_limit then
    raise exception 'Download limit reached' using errcode = 'check_violation', hint = 'limit_reached';
  end if;

  select fp.storage_path, fp.external_url into v_path, v_url
    from public.product_file_paths fp where fp.file_id = v_file.id;
  if not found or (v_path is null and v_url is null) then
    raise exception 'File is not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  update public.entitlements set downloads_used = downloads_used + 1 where id = v_ent.id;
  insert into public.download_log (entitlement_id, file_id, client_key)
  values (v_ent.id, v_file.id, p_client_key);

  return jsonb_build_object('storage_path', v_path, 'external_url', v_url, 'file_name', v_file.name);
end;
$$;

-- The buyer's order page, by token. The only way an anonymous visitor learns
-- anything about an order. Keys and files appear only while the order is paid.
create or replace function public.track_order(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_token is null then
    return null;
  end if;

  select * into v_order from public.orders where public_token = p_token;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'token',               v_order.public_token,
    'customer_name',       v_order.customer_name,
    'email',               v_order.email,
    'country',             v_order.country,
    'currency',            v_order.currency,
    'subtotal',            v_order.subtotal,
    'tax_amount',          v_order.tax_amount,
    'tax_rate_bps',        v_order.tax_rate_bps,
    'tax_name',            v_order.tax_name,
    'prices_include_tax',  v_order.prices_include_tax,
    'total',               v_order.total,
    'status',              v_order.status,
    'paid_at',             v_order.paid_at,
    'payment_method',      v_order.payment_method,
    -- How to pay, and where a manual payment stands. The payee details and the
    -- instructions are shown only while the order is still waiting for money.
    'payment', (
      select jsonb_build_object(
        'kind',         pm.kind,
        'label',        pm.label,
        'translations', pm.translations,
        'instructions', case when pm.kind = 'manual' and v_order.status in ('pending', 'verifying')
                             then pm.instructions end,
        'details',      case when pm.kind = 'manual' and v_order.status in ('pending', 'verifying')
                             then pm.details end,
        'proofs', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'status', pr.status, 'reference', pr.reference,
                   'reject_reason', pr.reject_reason, 'created_at', pr.created_at)
                 order by pr.created_at)
            from public.payment_proofs pr where pr.order_id = v_order.id
        ), '[]'::jsonb)
      )
      from public.payment_methods pm where pm.code = v_order.payment_method
    ),
    'created_at',          v_order.created_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id',   oi.product_id,
        'product_name', oi.product_name,
        'quantity',     oi.quantity,
        'unit_price',   oi.unit_price,
        'licenses', case when v_order.status = 'paid' then coalesce((
            select jsonb_agg(k.key order by k.assigned_at, k.id)
              from public.license_keys k where k.order_item_id = oi.id
          ), '[]'::jsonb) else '[]'::jsonb end,
        'files', case
          when v_order.status = 'paid' and e.id is not null and e.revoked_at is null
               and (e.expires_at is null or e.expires_at > now())
          then coalesce((
            select jsonb_agg(jsonb_build_object(
                     'id', f.id, 'name', f.name, 'size_bytes', f.size_bytes, 'version', f.version)
                   order by f.sort_order, f.name)
              from public.product_files f where f.product_id = oi.product_id
          ), '[]'::jsonb)
          else '[]'::jsonb end,
        'access', case when e.id is null then null else jsonb_build_object(
          'downloads_remaining', case when e.download_limit is null then null
                                      else greatest(e.download_limit - e.downloads_used, 0) end,
          'expires_at', e.expires_at,
          'revoked',    e.revoked_at is not null) end
      ) order by oi.created_at, oi.id)
      from public.order_items oi
      left join public.entitlements e on e.order_item_id = oi.id
      where oi.order_id = v_order.id
    ), '[]'::jsonb)
  );
end;
$$;

-- A review, from someone who paid for the product. The token proves it.
create or replace function public.submit_review(
  p_token      uuid,
  p_product_id uuid,
  p_name       text,
  p_rating     int,
  p_comment    text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order uuid;
begin
  select o.id into v_order
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
   where o.public_token = p_token and o.status = 'paid' and oi.product_id = p_product_id;
  if v_order is null then
    raise exception 'Only buyers can review this product'
      using errcode = 'check_violation', hint = 'not_a_buyer';
  end if;

  if exists (select 1 from public.reviews r where r.order_id = v_order and r.product_id = p_product_id) then
    raise exception 'You have already reviewed this product'
      using errcode = 'check_violation', hint = 'already_reviewed';
  end if;

  -- Nobody self-approves: it always lands in the moderation queue.
  insert into public.reviews (product_id, order_id, customer_name, rating, comment,
                              verified_purchase, is_approved)
  values (p_product_id, v_order, btrim(coalesce(p_name, '')), p_rating,
          btrim(coalesce(p_comment, '')), true, false);
end;
$$;

-- Published product count per category, so the storefront counts in SQL.
create or replace function public.category_product_counts()
returns table (category_id uuid, product_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select p.category_id, count(*)::bigint
  from public.products p
  where p.status = 'published' and p.category_id is not null
  group by p.category_id;
$$;

/*
 * One page of the published catalogue in ONE currency, plus the total and facets.
 *
 * Only products with a price in the requested currency are returned, because a
 * product the visitor cannot buy in their currency should not look buyable. Price
 * your products in every active currency. Every word of the query must match, so
 * a second word narrows the results.
 */
create or replace function public.catalogue_page(
  p_category_slug text default null,
  p_query         text default null,
  p_currency      text default null,
  p_min_price     int  default null,
  p_max_price     int  default null,
  p_sort          text default 'newest',
  p_limit         int  default 12,
  p_offset        int  default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with cfg as (
  select coalesce(
           upper(nullif(btrim(p_currency), '')),
           (select s.default_currency from public.store_settings s where s.id = 1),
           'USD') as cur
),
matched as (
  select p.id, p.name, p.published_at, pp.amount
  from public.products p
  cross join cfg
  join public.product_prices pp on pp.product_id = p.id and pp.currency = cfg.cur
  left join public.categories c on c.id = p.category_id
  where p.status = 'published'
    and (p_category_slug is null or c.slug = p_category_slug)
    and (
      coalesce(btrim(p_query), '') = ''
      or not exists (
        select 1
        from unnest(string_to_array(public.normalize_search(p_query), ' ')) as word
        where word <> ''
          and public.normalize_search(
                p.name || ' ' || coalesce(p.description, '') || ' ' || p.slug
                || ' ' || p.translations::text
              ) not like '%' || word || '%'
      )
    )
    and (p_min_price is null or pp.amount >= p_min_price)
    and (p_max_price is null or pp.amount <= p_max_price)
),
ranked as (
  select m.id,
         row_number() over (
           order by
             case when p_sort = 'price-asc'  then m.amount end asc nulls last,
             case when p_sort = 'price-desc' then m.amount end desc nulls last,
             case when p_sort = 'name'       then m.name end asc,
             case when p_sort not in ('price-asc', 'price-desc', 'name') then m.published_at end desc nulls last,
             m.id
         ) as ord
  from matched m
),
page as (
  select r.id, r.ord from ranked r
  order by r.ord
  limit greatest(coalesce(p_limit, 12), 1)
  offset greatest(coalesce(p_offset, 0), 0)
)
select jsonb_build_object(
  'currency', (select cur from cfg),
  'total',    (select count(*) from matched),
  'products', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'slug', p.slug,
        'name', p.name,
        'description', p.description,
        'translations', p.translations,
        'version', p.version,
        'cover_image_url', p.cover_image_url,
        'published_at', p.published_at,
        'price', pp.amount,
        'compare_at_price', pp.compare_at_amount,
        'category', case when c.id is null then null else jsonb_build_object(
          'slug', c.slug, 'name', c.name, 'translations', c.translations) end,
        'rating_avg', (select round(avg(r.rating)::numeric, 2) from public.reviews r
                        where r.product_id = p.id and r.is_approved),
        'rating_count', (select count(*) from public.reviews r
                          where r.product_id = p.id and r.is_approved)
      )
      order by page.ord
    )
    from page
    join public.products p on p.id = page.id
    join public.product_prices pp on pp.product_id = p.id and pp.currency = (select cur from cfg)
    left join public.categories c on c.id = p.category_id
  ), '[]'::jsonb),
  -- Facets span the whole published catalogue, so the filter does not empty
  -- itself as the buyer narrows.
  'facets', jsonb_build_object(
    'priceMin', coalesce((
      select min(pp.amount) from public.product_prices pp
      join public.products p on p.id = pp.product_id
      where p.status = 'published' and pp.currency = (select cur from cfg)), 0),
    'priceMax', coalesce((
      select max(pp.amount) from public.product_prices pp
      join public.products p on p.id = pp.product_id
      where p.status = 'published' and pp.currency = (select cur from cfg)), 0)
  )
);
$$;

/*
 * Dashboard analytics: one function, one round trip, over every order created in
 * the window. Money is never added across currencies, so revenue comes back per
 * currency. "Revenue" counts paid orders only; refunded and disputed ones are
 * counted separately.
 */
create or replace function public.admin_analytics(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days  int := greatest(1, least(coalesce(p_days, 30), 366));
  v_since timestamptz;
begin
  if (select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is not true then
    raise exception 'Only the shop''s administrators can read its analytics'
      using errcode = 'insufficient_privilege';
  end if;

  v_since := date_trunc('day', now()) - make_interval(days => v_days - 1);

  return (
    with win as (
      select * from public.orders where created_at >= v_since
    )
    select jsonb_build_object(
      'days', v_days,
      'funnel', (
        select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
        from (select status::text as status, count(*) as n from win group by 1) f
      ),
      'revenueByCurrency', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'currency', currency, 'orders', n, 'gross', gross, 'tax', tax,
                 'net', gross - tax) order by gross desc), '[]'::jsonb)
        from (select currency, count(*) as n, sum(total) as gross, sum(tax_amount) as tax
                from win where status = 'paid' group by currency) r
      ),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'day', to_char(day, 'YYYY-MM-DD'), 'currency', currency,
                 'orders', n, 'value', v) order by day, currency), '[]'::jsonb)
        from (select date_trunc('day', created_at) as day, currency,
                     count(*) as n, sum(total) as v
                from win where status = 'paid' group by 1, 2) d
      ),
      -- All time, not windowed: a receipt waiting for a person never goes stale.
      'awaitingVerification', (select count(*) from public.orders where status = 'verifying'),
      'byMethod', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'method', method, 'currency', currency, 'orders', n, 'gross', gross)
               order by gross desc), '[]'::jsonb)
        from (select coalesce(payment_method, 'free') as method, currency,
                     count(*) as n, sum(total) as gross
                from win where status = 'paid' group by 1, 2) m
      ),
      'refunds', (
        select jsonb_build_object(
                 'refunded', count(*) filter (where status = 'refunded'),
                 'disputed', count(*) filter (where status = 'disputed'))
        from win
      ),
      'topProducts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', name, 'currency', currency, 'units', units, 'value', value)
               order by units desc, value desc), '[]'::jsonb)
        from (
          select oi.product_name as name, o.currency,
                 sum(oi.quantity) as units, sum(oi.quantity * oi.unit_price) as value
          from public.order_items oi
          join win o on o.id = oi.order_id
          where o.status = 'paid'
          group by oi.product_name, o.currency
          order by units desc, value desc
          limit 5
        ) t
      ),
      'byCountry', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'country', country, 'orders', n, 'paid', paid)
               order by paid desc, n desc), '[]'::jsonb)
        from (
          select country, count(*) as n, count(*) filter (where status = 'paid') as paid
          from win group by country order by 3 desc, 2 desc limit 10
        ) c
      ),
      'lowKeys', (
        select coalesce(jsonb_agg(jsonb_build_object('product', product, 'available', available)
               order by available, product), '[]'::jsonb)
        from (
          select p.name as product,
                 count(k.id) filter (where k.order_item_id is null and k.revoked_at is null) as available
          from public.products p
          left join public.license_keys k on k.product_id = p.id
          where p.license_mode = 'pool' and p.status = 'published'
          group by p.id, p.name
          having count(k.id) filter (where k.order_item_id is null and k.revoked_at is null) <= 5
          order by 2, 1
          limit 10
        ) l
      )
    )
  );
end;
$$;

-- ── Admin bootstrap ────────────────────────────────────────────────────────
-- admin_users has no INSERT policy, or any signed-in user could promote
-- themselves. This adds exactly one route in: the first signed-in user may claim
-- the store, only while it has no administrator. The advisory lock stops two
-- simultaneous claims both reading a count of zero.
--
-- RISK: whoever signs in first owns the shop. Claim it right after installing, or
-- turn off public sign-ups in Supabase Auth until you have.
create or replace function public.admin_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admin_users);
$$;

create or replace function public.claim_store()
returns public.admin_role
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_taken int;
begin
  if v_uid is null then
    raise exception 'Sign in before claiming the store' using errcode = 'insufficient_privilege';
  end if;

  perform pg_advisory_xact_lock(hashtext('openstore_claim_store'));

  select count(*) into v_taken from public.admin_users;
  if v_taken > 0 then
    raise exception 'This store already has an administrator' using errcode = 'check_violation';
  end if;

  insert into public.admin_users (user_id, role) values (v_uid, 'owner');
  return 'owner';
end;
$$;

-- Which schema.sql this database last ran. The dashboard compares it with the
-- code and asks the owner to re-run the file when the code is newer.
create or replace function public.openstore_schema_version()
returns int
language sql
immutable
set search_path = ''
as $$
  select 1;
$$;


-- =============================================================================
-- 5. Triggers
-- =============================================================================

drop trigger if exists touch_store_settings on public.store_settings;
create trigger touch_store_settings before update on public.store_settings
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_categories on public.categories;
create trigger touch_categories before update on public.categories
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_product_prices on public.product_prices;
create trigger touch_product_prices before update on public.product_prices
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_tax_rates on public.tax_rates;
create trigger touch_tax_rates before update on public.tax_rates
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_payment_methods on public.payment_methods;
create trigger touch_payment_methods before update on public.payment_methods
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_orders on public.orders;
create trigger touch_orders before update on public.orders
  for each row execute function public.touch_updated_at();

drop trigger if exists validate_order_trigger on public.orders;
create trigger validate_order_trigger before insert on public.orders
  for each row execute function public.validate_order();

drop trigger if exists guard_order_status_trigger on public.orders;
create trigger guard_order_status_trigger before update on public.orders
  for each row execute function public.guard_order_status();

drop trigger if exists on_order_status_change_trigger on public.orders;
create trigger on_order_status_change_trigger after update of status on public.orders
  for each row execute function public.on_order_status_change();

drop trigger if exists validate_order_item_trigger on public.order_items;
create trigger validate_order_item_trigger before insert on public.order_items
  for each row execute function public.validate_order_item();

-- After, not before: totals can only be right once the line exists.
drop trigger if exists recalculate_order_totals_trigger on public.order_items;
create trigger recalculate_order_totals_trigger
  after insert or update or delete on public.order_items
  for each row execute function public.recalculate_order_totals();


-- =============================================================================
-- 6. Row Level Security
-- =============================================================================

alter table public.currencies          enable row level security;
alter table public.store_settings      enable row level security;
alter table public.admin_users         enable row level security;
alter table public.categories          enable row level security;
alter table public.products            enable row level security;
alter table public.product_prices      enable row level security;
alter table public.product_images      enable row level security;
alter table public.product_files       enable row level security;
alter table public.product_file_paths  enable row level security;
alter table public.license_keys        enable row level security;
alter table public.tax_rates           enable row level security;
alter table public.blocked_emails      enable row level security;
alter table public.orders              enable row level security;
alter table public.order_items         enable row level security;
alter table public.entitlements        enable row level security;
alter table public.download_log        enable row level security;
alter table public.reviews             enable row level security;
alter table public.payment_events      enable row level security;
alter table public.payment_methods     enable row level security;
alter table public.payment_proofs      enable row level security;
alter table public.outbox              enable row level security;   -- no policy: service_role only

-- --- Public reads. Each is a deliberate list of what a visitor may see.
drop policy if exists "Public reads active currencies" on public.currencies;
create policy "Public reads active currencies"
  on public.currencies for select to anon, authenticated using (is_active);

drop policy if exists "Public reads store settings" on public.store_settings;
create policy "Public reads store settings"
  on public.store_settings for select to anon, authenticated using (true);

drop policy if exists "Public reads active categories" on public.categories;
create policy "Public reads active categories"
  on public.categories for select to anon, authenticated using (is_active);

drop policy if exists "Public reads published products" on public.products;
create policy "Public reads published products"
  on public.products for select to anon, authenticated using (status = 'published');

drop policy if exists "Public reads prices of published products" on public.product_prices;
create policy "Public reads prices of published products"
  on public.product_prices for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));

drop policy if exists "Public reads images of published products" on public.product_images;
create policy "Public reads images of published products"
  on public.product_images for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));

-- File names and sizes are public ("what's included"). Paths never are.
drop policy if exists "Public reads file list of published products" on public.product_files;
create policy "Public reads file list of published products"
  on public.product_files for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));

drop policy if exists "Public reads active tax rates" on public.tax_rates;
create policy "Public reads active tax rates"
  on public.tax_rates for select to anon, authenticated using (is_active);

-- Buyers need the list of methods, and the payee details of a manual one, to pay.
drop policy if exists "Public reads active payment methods" on public.payment_methods;
create policy "Public reads active payment methods"
  on public.payment_methods for select to anon, authenticated using (is_active);

drop policy if exists "Public reads approved reviews" on public.reviews;
create policy "Public reads approved reviews"
  on public.reviews for select to anon, authenticated using (is_approved);

-- --- A user may read only their own admin row. No INSERT/UPDATE/DELETE policy:
-- staff accounts are created in the SQL editor by the owner.
drop policy if exists "Users read their own role" on public.admin_users;
create policy "Users read their own role"
  on public.admin_users for select to authenticated
  using ((select auth.uid()) = user_id);

-- --- Admin policies, generated so no table gets a different rule by accident.
-- orders, order_items, entitlements, download_log and payment_events get a
-- policy too, but the grants in section 10 keep them read-mostly: RLS decides
-- which ROWS an admin may touch, grants decide which OPERATIONS.
do $$
declare
  t       text;
  v_staff text := '(select public.has_admin_role((select auth.uid()), array[''owner'',''staff'']::public.admin_role[])) is true';
  v_owner text := '(select public.has_admin_role((select auth.uid()), array[''owner'']::public.admin_role[])) is true';
begin
  foreach t in array array[
    'categories', 'products', 'product_prices', 'product_images', 'product_files',
    'product_file_paths', 'license_keys', 'blocked_emails', 'reviews', 'orders',
    'order_items', 'entitlements', 'download_log', 'payment_events', 'payment_proofs'
  ] loop
    execute format('drop policy if exists %I on public.%I', 'Admins manage ' || t, t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (%s) with check (%s)',
      'Admins manage ' || t, t, v_staff, v_staff);
  end loop;

  -- Settings, currencies, tax rates and payment methods decide what buyers are
  -- charged and where their money goes: owner only.
  foreach t in array array['store_settings', 'currencies', 'tax_rates', 'payment_methods'] loop
    execute format('drop policy if exists %I on public.%I', 'Owner manages ' || t, t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (%s) with check (%s)',
      'Owner manages ' || t, t, v_owner, v_owner);
  end loop;
end $$;


-- =============================================================================
-- 7. Storage
-- =============================================================================
--
-- product-media  PUBLIC. Cover images and screenshots: an <img src> must resolve
--                without a session. A public bucket serves its files by URL with
--                no policy at all, so there is deliberately NO public SELECT
--                policy. That policy would let anyone LIST every object.
-- digital-files  PRIVATE. The products themselves. No public policy of any kind;
--                the only way out is a signed URL your server mints after
--                authorize_download() approves it.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-media', 'product-media', true,  8388608,
     array['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/gif']),
  ('digital-files', 'digital-files', false, 1073741824, null),
  ('payment-proofs', 'payment-proofs', false, 5242880,
     array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

do $$
declare
  b text;
  c text;
  v_admin text := 'public.has_admin_role((select auth.uid()), array[''owner'',''staff'']::public.admin_role[]) is true';
begin
  foreach b in array array['product-media', 'digital-files', 'payment-proofs'] loop
    foreach c in array array['select', 'insert', 'update', 'delete'] loop
      execute format('drop policy if exists %I on storage.objects', 'Admins ' || c || ' ' || b);
      if c = 'insert' then
        execute format(
          'create policy %I on storage.objects for insert to authenticated with check (bucket_id = %L and %s)',
          'Admins ' || c || ' ' || b, b, v_admin);
      elsif c = 'update' then
        execute format(
          'create policy %I on storage.objects for update to authenticated using (bucket_id = %L and %s) with check (bucket_id = %L and %s)',
          'Admins ' || c || ' ' || b, b, v_admin, b, v_admin);
      else
        execute format(
          'create policy %I on storage.objects for %s to authenticated using (bucket_id = %L and %s)',
          'Admins ' || c || ' ' || b, c, b, v_admin);
      end if;
    end loop;
  end loop;
end $$;


-- payment-proofs PRIVATE. Transfer receipts. A buyer may INSERT (never read, list,
--                overwrite or delete) a file into the folder named after their own
--                order's token, only while that order awaits a manual payment, and
--                at most five files per order: that is what can_upload_proof()
--                checks. Admins read receipts through signed URLs.
drop policy if exists "Buyers upload payment proofs" on storage.objects;
create policy "Buyers upload payment proofs"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'payment-proofs' and public.can_upload_proof(name));


-- =============================================================================
-- 8. Seed: a working demo shop
-- =============================================================================
--
-- A fresh install must show a shop, not an empty screen. Every insert is
-- idempotent, and demo content is added only to a shop nobody has claimed, so
-- re-running this file on a live shop never brings back products you deleted.

insert into public.currencies (code, name, minor_digits, sort_order) values
  ('USD', 'US Dollar',      2, 1),
  ('MXN', 'Mexican Peso',   2, 2),
  ('BRL', 'Brazilian Real', 2, 3),
  ('COP', 'Colombian Peso', 2, 4),
  -- CLP has no minor unit: 27900 means 27,900 pesos.
  ('CLP', 'Chilean Peso',   0, 5),
  ('PEN', 'Peruvian Sol',   2, 6)
on conflict (code) do nothing;

-- Served: Latin America. Not served: Algeria. Venezuela and Cuba are left out on
-- purpose (see the header). Change either list in the dashboard.
insert into public.store_settings (
  id, name, tagline, description, support_email, default_currency, default_locale,
  allowed_countries, blocked_countries
) values (
  1,
  'OpenStore Digital',
  'Entrega instantánea. Descarga en segundos.',
  'Esta es la tienda de demostración creada por schema.sql. Edítala en Ajustes, o borra los productos de ejemplo y agrega los tuyos.',
  'support@example.com',
  'USD',
  'es',
  array['AR','BO','BR','CL','CO','CR','DO','EC','SV','GT','HN','MX','NI','PA','PY','PE','PR','UY'],
  array['DZ']
)
on conflict (id) do nothing;

-- The payment methods, all OFF. Turn one on in the dashboard once it is ready:
-- `transfer` after you replace the placeholder account below with your own (a
-- buyer would otherwise pay a stranger), `card` and `paypal` after your server can
-- open sessions and receive their webhooks. Seeded regardless of demo content, and
-- never overwritten, so your edits survive a re-run.
insert into public.payment_methods
  (code, kind, provider, label, translations, instructions, details, currencies, countries,
   hold_hours, is_active, sort_order)
values
  ('card', 'online', 'stripe', 'Credit / debit card',
   '{"es": {"label": "Tarjeta de crédito / débito"}, "pt": {"label": "Cartão de crédito / débito"}}'::jsonb,
   null, '{}'::jsonb,
   '{}', '{}', 24, false, 1),
  ('paypal', 'online', 'paypal', 'PayPal',
   '{"es": {"label": "PayPal"}, "pt": {"label": "PayPal"}}'::jsonb,
   null, '{}'::jsonb,
   array['USD'], '{}', 24, false, 2),
  ('transfer', 'manual', null, 'Bank transfer (SPEI / PIX)',
   '{"es": {"label": "Transferencia bancaria (SPEI)", "instructions": "Transfiere el monto exacto a la cuenta de abajo, luego sube la foto del comprobante e ingresa su número. Confirmamos tu pedido en 24 horas."},
     "pt": {"label": "Transferência bancária (Pix)", "instructions": "Transfira o valor exato para a conta abaixo, depois envie a foto do comprovante e informe o número. Confirmamos seu pedido em até 24 horas."}}'::jsonb,
   'Send the exact total to the account below, then upload a photo of the receipt and enter its number. We confirm your order within 24 hours.',
   '{"account_holder": "CHANGE ME", "bank": "CHANGE ME", "clabe": "", "pix_key": ""}'::jsonb,
   array['MXN', 'BRL'], array['MX', 'BR'], 72, false, 3)
on conflict (code) do nothing;

do $$
begin
  if exists (select 1 from public.admin_users) then
    return;
  end if;

  insert into public.categories (slug, name, translations, sort_order) values
    ('templates', 'Templates', '{"es": {"name": "Plantillas"}, "pt": {"name": "Modelos"}}'::jsonb, 1),
    ('software',  'Software',  '{"es": {"name": "Software"},  "pt": {"name": "Software"}}'::jsonb, 2)
  on conflict (slug) do nothing;

  -- Three products that between them exercise every delivery path:
  --   free-sampler   free + a file    -> place_order completes by itself, so you
  --                                      can test delivery with no payment provider
  --   starter-ui-kit paid + a file    -> goes through your payment webhook
  --   pro-app        paid + license   -> a generated key per purchase
  insert into public.products (id, slug, name, description, translations, status, category_id,
                               license_mode, version, published_at)
  values
    ('11111111-1111-4111-8111-111111111111', 'free-sampler',
     'Free Sampler Pack', 'A small free pack. Great for testing the whole delivery flow.',
     '{"es": {"name": "Paquete de muestra gratis", "description": "Un pequeño paquete gratuito. Ideal para probar todo el proceso de entrega."},
       "pt": {"name": "Pacote de amostra grátis", "description": "Um pequeno pacote gratuito. Ótimo para testar todo o processo de entrega."}}'::jsonb,
     'published', (select id from public.categories where slug = 'templates'), 'none', '1.0', now()),
    ('22222222-2222-4222-8222-222222222222', 'starter-ui-kit',
     'Starter UI Kit', 'A clean UI kit with components, icons and example screens.',
     '{"es": {"name": "Kit de interfaz inicial", "description": "Un kit de interfaz limpio con componentes, iconos y pantallas de ejemplo."},
       "pt": {"name": "Kit de interface inicial", "description": "Um kit de interface limpo com componentes, ícones e telas de exemplo."}}'::jsonb,
     'published', (select id from public.categories where slug = 'templates'), 'none', '2.1', now()),
    ('33333333-3333-4333-8333-333333333333', 'pro-app',
     'Pro App License', 'A lifetime license key for the Pro edition.',
     '{"es": {"name": "Licencia Pro App", "description": "Una clave de licencia de por vida para la edición Pro."},
       "pt": {"name": "Licença Pro App", "description": "Uma chave de licença vitalícia para a edição Pro."}}'::jsonb,
     'published', (select id from public.categories where slug = 'software'), 'generated', '5.0', now())
  on conflict (id) do nothing;

  -- Demo prices, roughly converted: set your own. Amounts are in minor units
  -- (USD 2900 = 29.00, CLP 27900 = 27,900 pesos).
  insert into public.product_prices (product_id, currency, amount, compare_at_amount) values
    ('11111111-1111-4111-8111-111111111111', 'USD', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'MXN', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'BRL', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'COP', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'CLP', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'PEN', 0, null),
    ('22222222-2222-4222-8222-222222222222', 'USD', 2900, null),
    ('22222222-2222-4222-8222-222222222222', 'MXN', 49900, null),
    ('22222222-2222-4222-8222-222222222222', 'BRL', 14900, null),
    ('22222222-2222-4222-8222-222222222222', 'COP', 11900000, null),
    ('22222222-2222-4222-8222-222222222222', 'CLP', 27900, null),
    ('22222222-2222-4222-8222-222222222222', 'PEN', 10900, null),
    ('33333333-3333-4333-8333-333333333333', 'USD', 4900, 5900),
    ('33333333-3333-4333-8333-333333333333', 'MXN', 84900, 99900),
    ('33333333-3333-4333-8333-333333333333', 'BRL', 24900, 29900),
    ('33333333-3333-4333-8333-333333333333', 'COP', 19900000, 23900000),
    ('33333333-3333-4333-8333-333333333333', 'CLP', 46900, 55900),
    ('33333333-3333-4333-8333-333333333333', 'PEN', 17900, 21900)
  on conflict (product_id, currency) do nothing;

  update public.products set cover_image_url = 'https://picsum.photos/seed/openstore-sampler/900/600'
   where id = '11111111-1111-4111-8111-111111111111' and cover_image_url is null;
  update public.products set cover_image_url = 'https://picsum.photos/seed/openstore-uikit/900/600'
   where id = '22222222-2222-4222-8222-222222222222' and cover_image_url is null;
  update public.products set cover_image_url = 'https://picsum.photos/seed/openstore-proapp/900/600'
   where id = '33333333-3333-4333-8333-333333333333' and cover_image_url is null;

  -- The two file rows point at paths that do not exist yet. Upload a file to the
  -- 'digital-files' bucket at exactly that path (Storage > digital-files), or the
  -- download will fail at the signing step.
  insert into public.product_files (id, product_id, name, size_bytes, content_type, version) values
    ('aaaaaaaa-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111',
     'free-sampler.zip', null, 'application/zip', '1.0'),
    ('aaaaaaaa-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222',
     'starter-ui-kit.zip', null, 'application/zip', '2.1')
  on conflict (id) do nothing;

  insert into public.product_file_paths (file_id, storage_path) values
    ('aaaaaaaa-1111-4111-8111-111111111111', 'demo/free-sampler.zip'),
    ('aaaaaaaa-2222-4222-8222-222222222222', 'demo/starter-ui-kit.zip')
  on conflict (file_id) do nothing;
end;
$$;

-- =============================================================================
-- 9. Upgrades
-- =============================================================================
--
-- When a later version adds a column to an existing table, put the matching
--     alter table ... add column if not exists ...
-- here (not only in the CREATE TABLE above), and bump openstore_schema_version().
-- A CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, so a
-- column declared only there never reaches a database installed before it.


-- =============================================================================
-- 10. Grants
-- =============================================================================
--
-- All grants live here, after every object exists. PostgREST checks grants BEFORE
-- RLS, so a missing grant looks exactly like a broken policy (a 401).
--
-- Policies do not remove grants, so start from nothing for the API roles and give
-- back exactly what each needs. This runs inside the file's transaction, so the
-- storefront never observes the gap between the revoke and the grants.

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- A table or function added later starts closed instead of open.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

grant usage on schema public to anon, authenticated;

-- The storefront.
grant select on
  public.currencies, public.store_settings, public.categories, public.products,
  public.product_prices, public.product_images, public.product_files,
  public.tax_rates, public.reviews, public.payment_methods
  to anon, authenticated;

-- The dashboard (the shop owner's signed-in browser). RLS limits these to admins.
grant select, insert, update, delete on
  public.categories, public.products, public.product_prices, public.product_images,
  public.product_files, public.product_file_paths, public.tax_rates, public.currencies,
  public.payment_methods
  to authenticated;
grant select, insert, update on public.store_settings to authenticated;   -- singleton: no delete
grant select, insert, delete on public.blocked_emails to authenticated;
grant select, insert, delete on public.license_keys to authenticated;
grant update (key, revoked_at) on public.license_keys to authenticated;
grant select, update, delete on public.reviews to authenticated;          -- no insert: see submit_review()
grant select on public.admin_users, public.order_items, public.download_log,
                public.payment_events, public.payment_proofs to authenticated;

-- Orders are financial records: no insert (place_order() is the only way in) and
-- no delete. Admins may change only the status (guarded by guard_order_status)
-- and an internal note. A table-level `grant update` would cover every column,
-- including the money, so it is never issued.
grant select on public.orders to authenticated;
grant update (status, internal_note) on public.orders to authenticated;

grant select on public.entitlements to authenticated;
grant update (download_limit, expires_at, revoked_at) on public.entitlements to authenticated;

grant usage, select on sequence public.download_log_id_seq, public.outbox_id_seq to authenticated;

-- Storage. RLS on storage.objects decides WHICH objects; these let the API roles
-- reach the table at all. Already the Supabase default, restated so the file does
-- not depend on it. Anonymous buyers may insert only (the receipt upload).
grant select, insert, update, delete on storage.objects to authenticated;
grant insert on storage.objects to anon;

-- Functions a browser may call.
grant execute on function public.has_admin_role(uuid, public.admin_role[]) to authenticated;
grant execute on function public.place_order(jsonb, jsonb)                 to anon, authenticated;
grant execute on function public.track_order(uuid)                         to anon, authenticated;
grant execute on function public.submit_review(uuid, uuid, text, int, text) to anon, authenticated;
grant execute on function public.catalogue_page(text, text, text, int, int, text, int, int) to anon, authenticated;
grant execute on function public.category_product_counts()                 to anon, authenticated;
grant execute on function public.admin_exists()                            to anon, authenticated;
grant execute on function public.openstore_schema_version()                to anon, authenticated;
grant execute on function public.claim_store()                             to authenticated;
grant execute on function public.admin_analytics(int)                      to authenticated;

grant execute on function public.submit_payment_proof(uuid, text, text, text, text) to anon, authenticated;
grant execute on function public.can_upload_proof(text)                     to anon, authenticated;
grant execute on function public.confirm_manual_payment(uuid, int)          to authenticated;
grant execute on function public.reject_payment_proof(uuid, text)           to authenticated;

-- Functions only YOUR SERVER may call, with the service key. Never a browser.
-- mark_order_paid() hands over files, so a browser able to call it could take
-- everything in the shop for free.
grant execute on function public.mark_order_paid(uuid, text, text, int, text) to service_role;
grant execute on function public.authorize_download(uuid, uuid, text)         to service_role;
grant execute on function public.expire_pending_orders()                      to service_role;

-- Everything else (settle_order, fulfil_order, recalculate_order, the trigger functions, the
-- normalisers) has no grant on purpose: it is reached only from inside the
-- functions and triggers above, which run as the owner.

-- Ask the API to pick up the new tables and functions straight away.
notify pgrst, 'reload schema';

commit;
