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
--   4. Money is INTEGER minor units (cents). USD 29.00 is 2900; DZD 2500 is 2500 (whole dinars).
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
-- THREE WAYS TO PAY, one table: payment_methods
--
--   ccp     MANUAL, for buyers in Algeria. The buyer pays the shop's CCP account
--           (Algerie Poste) in dinars, uploads the receipt and types its number.
--           The order goes pending -> verifying; an admin compares the receipt
--           with the account and confirms with confirm_manual_payment(), or
--           rejects it with reject_payment_proof() and the buyer may try again.
--   paypal  ONLINE, for everyone else. Your server opens a PayPal order and a
--           webhook calls mark_order_paid().
--   card    ONLINE, bank cards through Stripe. Same webhook path as PayPal.
--
-- Each method says which currencies and countries it accepts, so a CCP order can
-- only be in DZD from Algeria, and PayPal / card can never be offered in DZD.
-- All three are seeded SWITCHED OFF: ccp carries placeholder account details and
-- the online two need your server code, so none may take an order until you turn
-- it on in the dashboard (owner only). `details` is shown to buyers: never put a
-- secret in it. Provider keys belong in your server's environment, not here.
--
-- Tax: the database computes tax from `tax_rates` for the buyer's country. It
-- seeds NO rates, because rates change and being wrong is your liability. For
-- cross-border digital sales (EU VAT, UK VAT, US state tax) consider a merchant
-- of record (Paddle, Lemon Squeezy) or Stripe Tax instead of maintaining rates.
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

create table if not exists public.product_file_paths (
  file_id       uuid primary key references public.product_files(id) on delete cascade,
  -- Path inside the private 'digital-files' bucket.
  storage_path  text not null unique
                check (storage_path !~ '^/' and storage_path !~ '\.\.')
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

-- How a buyer can pay. `manual` methods (CCP) are confirmed by a person; `online`
-- methods name a provider whose webhook confirms them.
create table if not exists public.payment_methods (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  kind          text not null check (kind in ('manual', 'online')),
  provider      text check (provider is null or provider ~ '^[a-z][a-z0-9_]*$'),
  label         text not null,
  translations  jsonb not null default '{}'::jsonb check (jsonb_typeof(translations) = 'object'),
  -- Shown to the buyer while the order is unpaid (how to pay, what to send).
  instructions  text,
  -- PUBLIC payee details for a manual method (account holder, CCP number, key,
  -- RIP). The buyer must see them to pay. Never store a secret here.
  details       jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  -- Empty list means "any". ccp: {DZD} / {DZ}. paypal and card: no DZD.
  currencies    text[] not null default '{}'
                check (array_to_string(currencies, '') ~ '^([A-Z]{3})*$'),
  countries     text[] not null default '{}'
                check (array_to_string(countries, '') ~ '^([A-Z]{2})*$'),
  -- How long an unpaid order is held before it expires. A transfer takes longer
  -- than a card, so CCP gets days and the online methods get hours.
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
  -- such as CCP, where an admin may need to reach the buyer about the receipt.
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

-- Receipts for manual payments (CCP). One order may collect several attempts: an
-- admin can reject a receipt and the buyer sends another. The same receipt number
-- cannot back two orders (see payment_proofs_ref_key), which is the classic way
-- to claim goods twice with one transfer.
create table if not exists public.payment_proofs (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  method        text not null references public.payment_methods(code),
  sender_name   text not null check (length(btrim(sender_name)) between 2 and 120),
  -- The number printed on the CCP receipt or transfer confirmation.
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

  -- payment_kind tells the checkout what to do next: 'manual' shows the CCP
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

-- ── Manual payments (CCP) ──────────────────────────────────────────────────

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
-- Each order is held for ITS payment method's hold_hours: days for a CCP transfer,
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

-- Check a download and spend one of its uses. Returns the private storage path
-- to YOUR server, which then signs a short-lived URL. A use is spent when the
-- URL is issued, not when the transfer finishes.
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

  select fp.storage_path into v_path from public.product_file_paths fp where fp.file_id = v_file.id;
  if v_path is null then
    raise exception 'File is not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  update public.entitlements set downloads_used = downloads_used + 1 where id = v_ent.id;
  insert into public.download_log (entitlement_id, file_id, client_key)
  values (v_ent.id, v_file.id, p_client_key);

  return jsonb_build_object('storage_path', v_path, 'file_name', v_file.name);
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


-- payment-proofs PRIVATE. CCP receipts. A buyer may INSERT (never read, list,
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
  ('EUR', 'Euro',           2, 2),
  ('GBP', 'British Pound',  2, 3),
  -- DZD in whole dinars, as in OpenStore DZ: 2500 means 2500 DA. It is used with
  -- CCP only; PayPal and card cannot take it.
  ('DZD', 'Algerian Dinar',  0, 4)
on conflict (code) do nothing;

insert into public.store_settings (
  id, name, tagline, description, support_email, default_currency
) values (
  1,
  'OpenStore Digital',
  'Instant delivery. Download in seconds.',
  'This is the demo shop created by schema.sql. Edit it in Settings, or delete the demo products and add your own.',
  'support@example.com',
  'USD'
)
on conflict (id) do nothing;

-- The three payment methods, all OFF. Turn one on in the dashboard once it is
-- ready: ccp after you replace the placeholder account below with your own (a
-- buyer would otherwise pay a stranger), paypal and card after your server can
-- open sessions and receive their webhooks. Seeded regardless of demo content, and
-- never overwritten, so your edits survive a re-run.
insert into public.payment_methods
  (code, kind, provider, label, translations, instructions, details, currencies, countries,
   hold_hours, is_active, sort_order)
values
  ('ccp', 'manual', null, 'CCP (Algerie Poste)',
   '{"ar": {"label": "بريد الجزائر (CCP)", "instructions": "حوّل المبلغ بالضبط إلى الحساب البريدي الجاري أدناه، ثم ارفع صورة الوصل وأدخل رقمه. نؤكد طلبك خلال 24 ساعة."},
     "fr": {"label": "CCP (Algérie Poste)", "instructions": "Versez le montant exact sur le compte CCP ci-dessous, puis envoyez la photo du reçu et son numéro. Nous confirmons sous 24 h."}}'::jsonb,
   'Send the exact total to the CCP account below, then upload a photo of the receipt and enter its number. We confirm your order within 24 hours.',
   '{"account_holder": "CHANGE ME", "ccp_number": "0000000000", "ccp_key": "00", "rip": "00799999000000000000"}'::jsonb,
   array['DZD'], array['DZ'], 72, false, 1),
  ('paypal', 'online', 'paypal', 'PayPal',
   '{"ar": {"label": "باي بال"}, "fr": {"label": "PayPal"}}'::jsonb,
   null, '{}'::jsonb,
   array['USD', 'EUR', 'GBP'], '{}', 24, false, 2),
  ('card', 'online', 'stripe', 'Credit / debit card',
   '{"ar": {"label": "بطاقة بنكية"}, "fr": {"label": "Carte bancaire"}}'::jsonb,
   null, '{}'::jsonb,
   array['USD', 'EUR', 'GBP'], '{}', 24, false, 3)
on conflict (code) do nothing;

do $$
begin
  if exists (select 1 from public.admin_users) then
    return;
  end if;

  insert into public.categories (slug, name, sort_order) values
    ('templates', 'Templates', 1),
    ('software',  'Software',  2)
  on conflict (slug) do nothing;

  -- Three products that between them exercise every delivery path:
  --   free-sampler   free + a file    -> place_order completes by itself, so you
  --                                      can test delivery with no payment provider
  --   starter-ui-kit paid + a file    -> goes through your payment webhook
  --   pro-app        paid + license   -> a generated key per purchase
  insert into public.products (id, slug, name, description, status, category_id, license_mode, version, published_at)
  values
    ('11111111-1111-4111-8111-111111111111', 'free-sampler',
     'Free Sampler Pack', 'A small free pack. Great for testing the whole delivery flow.',
     'published', (select id from public.categories where slug = 'templates'), 'none', '1.0', now()),
    ('22222222-2222-4222-8222-222222222222', 'starter-ui-kit',
     'Starter UI Kit', 'A clean UI kit with components, icons and example screens.',
     'published', (select id from public.categories where slug = 'templates'), 'none', '2.1', now()),
    ('33333333-3333-4333-8333-333333333333', 'pro-app',
     'Pro App License', 'A lifetime license key for the Pro edition.',
     'published', (select id from public.categories where slug = 'software'), 'generated', '5.0', now())
  on conflict (id) do nothing;

  insert into public.product_prices (product_id, currency, amount, compare_at_amount) values
    ('11111111-1111-4111-8111-111111111111', 'USD', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'EUR', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'GBP', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'DZD', 0, null),
    ('22222222-2222-4222-8222-222222222222', 'USD', 2900, null),
    ('22222222-2222-4222-8222-222222222222', 'EUR', 2700, null),
    ('22222222-2222-4222-8222-222222222222', 'GBP', 2300, null),
    ('22222222-2222-4222-8222-222222222222', 'DZD', 2500, null),
    ('33333333-3333-4333-8333-333333333333', 'USD', 4900, 5900),
    ('33333333-3333-4333-8333-333333333333', 'EUR', 4500, 5500),
    ('33333333-3333-4333-8333-333333333333', 'GBP', 3900, 4900),
    ('33333333-3333-4333-8333-333333333333', 'DZD', 7500, 9000)
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

commit;-- =============================================================================
-- OpenStore Digital — complete database schema (digital products, worldwide)
-- =============================================================================
--
-- THIS IS THE ONLY DATABASE FILE. There are no migrations.
--
-- Install by pasting it once into the Supabase SQL editor, or:
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
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
--   4. Money is INTEGER minor units (cents). USD 29.00 is 2900; JPY 4500 is 4500.
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
-- Tax: the database computes tax from `tax_rates` for the buyer's country. It
-- seeds NO rates, because rates change and being wrong is your liability. For
-- cross-border digital sales (EU VAT, UK VAT, US state tax) consider a merchant
-- of record (Paddle, Lemon Squeezy) or Stripe Tax instead of maintaining rates.
--
-- =============================================================================

begin;

-- =============================================================================
-- 1. Types
-- =============================================================================

do $$ begin
  create type public.admin_role as enum ('owner', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.order_status as enum (
    'pending',    -- placed, awaiting payment
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

create table if not exists public.product_file_paths (
  file_id       uuid primary key references public.product_files(id) on delete cascade,
  -- Path inside the private 'digital-files' bucket.
  storage_path  text not null unique
                check (storage_path !~ '^/' and storage_path !~ '\.\.')
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

create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  -- Unguessable token for the buyer's order page. Never expose the id.
  public_token   uuid not null unique default gen_random_uuid(),

  customer_name  text not null,
  email          text not null check (email = lower(btrim(email))),
  country        text not null check (country ~ '^[A-Z]{2}$'),   -- billing country, drives tax
  currency       text not null references public.currencies(code),
  locale         text check (locale ~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$'),

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
                  ('order_paid', 'order_refunded', 'order_disputed', 'license_shortage')),
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

  -- A new order always opens pending and unpaid, whatever the caller sent.
  new.status := 'pending';
  new.subtotal := 0;
  new.tax_amount := 0;
  new.total := 0;
  new.paid_at := null;
  new.refunded_at := null;
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
       (old.status = 'pending'  and new.status in ('paid', 'cancelled', 'expired'))
    or (old.status = 'expired'  and new.status in ('paid', 'cancelled'))
    or (old.status = 'paid'     and new.status in ('refunded', 'disputed'))
    or (old.status = 'disputed' and new.status in ('paid', 'refunded'))
  ) then
    raise exception 'Invalid order status change: % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  -- current_user is the API role for a direct dashboard UPDATE, and the function
  -- owner inside mark_order_paid(), so this separates the two.
  if current_user in ('anon', 'authenticated')
     and new.status = 'paid' and old.status in ('pending', 'expired') then
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
  insert into public.orders (customer_name, email, country, currency, locale,
                             terms_accepted_at, withdrawal_waived_at, client_key)
  values (
    coalesce(p_customer->>'customer_name', ''),
    v_email,
    coalesce(p_customer->>'country', ''),
    coalesce(nullif(p_customer->>'currency', ''),
             (select s.default_currency from public.store_settings s where s.id = 1)),
    nullif(p_customer->>'locale', ''),
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

  -- A free order has nothing to charge, so it is paid and delivered right here.
  if v_order.total = 0 then
    update public.orders
       set status = 'paid', paid_at = now(), payment_provider = 'free'
     where id = v_order_id;
    perform public.fulfil_order(v_order_id);
    v_order.status := 'paid';
  end if;

  return jsonb_build_object(
    'token',    v_token,
    'status',   v_order.status,
    'total',    v_order.total,
    'currency', v_order.currency
  );
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

  update public.orders
     set status = 'paid', paid_at = now(),
         payment_provider = p_provider, payment_ref = p_reference
   where id = p_order_id;

  perform public.fulfil_order(p_order_id);
  return true;
end;
$$;

-- Close orders nobody paid. Schedule it (pg_cron, or a cron-triggered function).
create or replace function public.expire_pending_orders(p_hours int default 24)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with u as (
    update public.orders
       set status = 'expired'
     where status = 'pending'
       and created_at < now() - make_interval(hours => greatest(coalesce(p_hours, 24), 1))
    returning 1
  )
  select count(*) into v_n from u;
  return v_n;
end;
$$;

-- Check a download and spend one of its uses. Returns the private storage path
-- to YOUR server, which then signs a short-lived URL. A use is spent when the
-- URL is issued, not when the transfer finishes.
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

  select fp.storage_path into v_path from public.product_file_paths fp where fp.file_id = v_file.id;
  if v_path is null then
    raise exception 'File is not available' using errcode = 'check_violation', hint = 'not_found';
  end if;

  update public.entitlements set downloads_used = downloads_used + 1 where id = v_ent.id;
  insert into public.download_log (entitlement_id, file_id, client_key)
  values (v_ent.id, v_file.id, p_client_key);

  return jsonb_build_object('storage_path', v_path, 'file_name', v_file.name);
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
    'order_items', 'entitlements', 'download_log', 'payment_events'
  ] loop
    execute format('drop policy if exists %I on public.%I', 'Admins manage ' || t, t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (%s) with check (%s)',
      'Admins manage ' || t, t, v_staff, v_staff);
  end loop;

  -- Settings, currencies and tax rates change what buyers are charged: owner only.
  foreach t in array array['store_settings', 'currencies', 'tax_rates'] loop
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
  ('digital-files', 'digital-files', false, 1073741824, null)
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
  foreach b in array array['product-media', 'digital-files'] loop
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


-- =============================================================================
-- 8. Seed: a working demo shop
-- =============================================================================
--
-- A fresh install must show a shop, not an empty screen. Every insert is
-- idempotent, and demo content is added only to a shop nobody has claimed, so
-- re-running this file on a live shop never brings back products you deleted.

insert into public.currencies (code, name, minor_digits, sort_order) values
  ('USD', 'US Dollar',      2, 1),
  ('EUR', 'Euro',           2, 2),
  ('GBP', 'British Pound',  2, 3),
  ('JPY', 'Japanese Yen',   0, 4)
on conflict (code) do nothing;

insert into public.store_settings (
  id, name, tagline, description, support_email, default_currency
) values (
  1,
  'OpenStore Digital',
  'Instant delivery. Download in seconds.',
  'This is the demo shop created by schema.sql. Edit it in Settings, or delete the demo products and add your own.',
  'support@example.com',
  'USD'
)
on conflict (id) do nothing;

do $$
begin
  if exists (select 1 from public.admin_users) then
    return;
  end if;

  insert into public.categories (slug, name, sort_order) values
    ('templates', 'Templates', 1),
    ('software',  'Software',  2)
  on conflict (slug) do nothing;

  -- Three products that between them exercise every delivery path:
  --   free-sampler   free + a file    -> place_order completes by itself, so you
  --                                      can test delivery with no payment provider
  --   starter-ui-kit paid + a file    -> goes through your payment webhook
  --   pro-app        paid + license   -> a generated key per purchase
  insert into public.products (id, slug, name, description, status, category_id, license_mode, version, published_at)
  values
    ('11111111-1111-4111-8111-111111111111', 'free-sampler',
     'Free Sampler Pack', 'A small free pack. Great for testing the whole delivery flow.',
     'published', (select id from public.categories where slug = 'templates'), 'none', '1.0', now()),
    ('22222222-2222-4222-8222-222222222222', 'starter-ui-kit',
     'Starter UI Kit', 'A clean UI kit with components, icons and example screens.',
     'published', (select id from public.categories where slug = 'templates'), 'none', '2.1', now()),
    ('33333333-3333-4333-8333-333333333333', 'pro-app',
     'Pro App License', 'A lifetime license key for the Pro edition.',
     'published', (select id from public.categories where slug = 'software'), 'generated', '5.0', now())
  on conflict (id) do nothing;

  insert into public.product_prices (product_id, currency, amount, compare_at_amount) values
    ('11111111-1111-4111-8111-111111111111', 'USD', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'EUR', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'GBP', 0, null),
    ('11111111-1111-4111-8111-111111111111', 'JPY', 0, null),
    ('22222222-2222-4222-8222-222222222222', 'USD', 2900, null),
    ('22222222-2222-4222-8222-222222222222', 'EUR', 2700, null),
    ('22222222-2222-4222-8222-222222222222', 'GBP', 2300, null),
    ('22222222-2222-4222-8222-222222222222', 'JPY', 4500, null),
    ('33333333-3333-4333-8333-333333333333', 'USD', 4900, 5900),
    ('33333333-3333-4333-8333-333333333333', 'EUR', 4500, 5500),
    ('33333333-3333-4333-8333-333333333333', 'GBP', 3900, 4900),
    ('33333333-3333-4333-8333-333333333333', 'JPY', 7500, 9000)
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
  public.tax_rates, public.reviews
  to anon, authenticated;

-- The dashboard (the shop owner's signed-in browser). RLS limits these to admins.
grant select, insert, update, delete on
  public.categories, public.products, public.product_prices, public.product_images,
  public.product_files, public.product_file_paths, public.tax_rates, public.currencies
  to authenticated;
grant select, insert, update on public.store_settings to authenticated;   -- singleton: no delete
grant select, insert, delete on public.blocked_emails to authenticated;
grant select, insert, delete on public.license_keys to authenticated;
grant update (key, revoked_at) on public.license_keys to authenticated;
grant select, update, delete on public.reviews to authenticated;          -- no insert: see submit_review()
grant select on public.admin_users, public.order_items, public.download_log,
                public.payment_events to authenticated;

-- Orders are financial records: no insert (place_order() is the only way in) and
-- no delete. Admins may change only the status (guarded by guard_order_status)
-- and an internal note. A table-level `grant update` would cover every column,
-- including the money, so it is never issued.
grant select on public.orders to authenticated;
grant update (status, internal_note) on public.orders to authenticated;

grant select on public.entitlements to authenticated;
grant update (download_limit, expires_at, revoked_at) on public.entitlements to authenticated;

grant usage, select on sequence public.download_log_id_seq, public.outbox_id_seq to authenticated;

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

-- Functions only YOUR SERVER may call, with the service key. Never a browser.
-- mark_order_paid() hands over files, so a browser able to call it could take
-- everything in the shop for free.
grant execute on function public.mark_order_paid(uuid, text, text, int, text) to service_role;
grant execute on function public.authorize_download(uuid, uuid, text)         to service_role;
grant execute on function public.expire_pending_orders(int)                   to service_role;

-- Everything else (fulfil_order, recalculate_order, the trigger functions, the
-- normalisers) has no grant on purpose: it is reached only from inside the
-- functions and triggers above, which run as the owner.

-- Ask the API to pick up the new tables and functions straight away.
notify pgrst, 'reload schema';

commit;-- =============================================================================
-- OpenStore DZ — complete database schema
-- =============================================================================
--
-- THIS IS THE ONLY DATABASE FILE. There are no migrations.
--
-- A shop owner installs OpenStore by pasting this file once, or by running:
--     docker exec -i supabase_db_openstore-dz psql -U postgres -v ON_ERROR_STOP=1 < supabase/schema.sql
--
-- Every object below is created idempotently, so re-running this file against an
-- existing database is safe. Seed data uses ON CONFLICT so it never duplicates.
--
-- Design rules this file must not break:
--
--   1. Every table has RLS AND a base GRANT. PostgREST evaluates grants BEFORE
--      policies and returns 401 if the role lacks the table privilege, which
--      looks exactly like a broken policy and is not one.
--
--   2. Every policy has WITH CHECK, not just USING. USING decides which existing
--      rows you may touch; without WITH CHECK a caller could UPDATE a row's
--      owner_id and hand it to someone else.
--
--   3. Policy function calls are wrapped in (select ...) so Postgres evaluates
--      them once per statement instead of once per candidate row.
--
--   4. Prices are never trusted from the browser. Order totals are recomputed
--      from the catalogue by trigger.
--
--   5. Money is INTEGER dinar. Never floating point.
--
-- =============================================================================

-- =============================================================================
-- 1. Types
-- =============================================================================

do $$ begin
  create type public.admin_role as enum ('owner', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.product_kind as enum ('single', 'pack');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.order_status as enum (
    'pending',    -- placed, not yet confirmed by phone
    'confirmed',  -- customer confirmed by phone
    'refused',    -- customer refused the parcel
    'shipped',    -- handed to the courier
    'delivered',
    'cancelled',
    'returned'
  );
exception when duplicate_object then null; end $$;


-- =============================================================================
-- 2. Tables
-- =============================================================================

-- Store profile. Singleton: the CHECK on id makes a second row impossible.
create table if not exists public.store_settings (
  id                  smallint primary key default 1 check (id = 1),

  name                text not null default 'My Shop',
  tagline             text,
  description         text,
  -- Latin-script versions for French and English visitors. Optional.
  tagline_fr          text,
  description_fr      text,
  address_fr          text,
  logo_url            text,
  banner_url          text,
  -- The storefront's primary colour, "#rrggbb". Null keeps the default theme.
  brand_color         text check (brand_color ~ '^#[0-9a-fA-F]{6}$'),

  -- Contact and legal disclosures. Law 18-05 (10 May 2018) Article 11 requires
  -- these to be published by any Algerian e-commerce activity.
  legal_name          text,
  nif                 text,
  rc_number           text,
  phone               text,
  whatsapp            text,
  email               text,
  address             text,

  -- Commerce rules the storefront needs to render honestly.
  currency            text not null default 'DZD',
  delivery_fee_flat   int  not null default 600 check (delivery_fee_flat >= 0),
  delivery_wilayas    text[] not null default '{}',
  delivery_eta_days   int  not null default 3 check (delivery_eta_days >= 1),
  returns_days        int  not null default 14 check (returns_days >= 0),
  accepts_cod         boolean not null default true,
  -- Delivery is free once the subtotal reaches this. 0 means never free.
  free_shipping_threshold int not null default 0 check (free_shipping_threshold >= 0),

    -- Guepex origin. The carrier matches wilaya by exact name string, so this
    -- must match the carrier's spelling character for character.
    guepex_from_wilaya  text,

    -- What the shop says to buyers before they buy.
    --
    -- The announcement is off by default, so a shop that has never opened the
    -- settings page renders nothing rather than an empty bar.
    announcement            text,
    announcement_enabled    boolean not null default false,
    -- Full URLs, not handles. A handle cannot be turned into a correct link for
    -- every platform, and guessing wrong sends a buyer to a stranger's profile.
    instagram_url           text,
    facebook_url            text,
    tiktok_url              text,
    -- `returns_days` says how long; this says what is covered, which is the part
    -- buyers actually ask about.
    returns_note            text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Admin accounts. Roles live here, never on the user object itself.
create table if not exists public.admin_users (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  role        public.admin_role not null default 'staff',
  created_at  timestamptz not null default now()
);

-- Categories are rows, not free text, so a category page has a canonical slug and
-- a renamed label does not split one category into two.
create table if not exists public.categories (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  name_fr      text,
  description  text,
  image_url    text,
  sort_order   int not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  name_fr       text,
  description   text,
  description_fr text,
  kind          public.product_kind not null default 'single',
  status        text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  category_id   uuid references public.categories(id) on delete set null,
  -- Published products are world-readable; everything else is admin-only.
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.product_variants (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  size          text,
  color_name    text,
  color_hex     text,
  sku           text,
  -- Dinar. A variant may cost more or less than its product's base price.
  price         int not null check (price >= 0),
  stock         int not null default 0 check (stock >= 0),
  -- Physical measurements drive the Guepex volumetric-weight fee.
  weight_grams  int check (weight_grams is null or weight_grams > 0),
  length_cm     numeric(8,2) check (length_cm is null or length_cm > 0),
  width_cm      numeric(8,2) check (width_cm  is null or width_cm  > 0),
  height_cm     numeric(8,2) check (height_cm is null or height_cm > 0),
  sort_order    int not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.variant_images (
  id          uuid primary key default gen_random_uuid(),
  variant_id  uuid not null references public.product_variants(id) on delete cascade,
  url         text not null,
  alt         text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- What is inside a pack. Only used when products.kind = 'pack'.
create table if not exists public.pack_items (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  variant_id    uuid not null references public.product_variants(id) on delete cascade,
  quantity      int not null default 1 check (quantity > 0),
  sort_order    int not null default 0,
  unique (product_id, variant_id)
);

create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  -- Unguessable token for the public tracking link. Never expose the id.
  public_token   uuid not null unique default gen_random_uuid(),

  customer_name  text not null,
  phone          text not null,
  wilaya         text not null,
  commune        text,
  address        text not null,
  -- Home delivery, or pickup at the carrier's office (stopdesk), which costs the
  -- buyer less. The office is the carrier's own id, never free text.
  delivery_method text not null default 'home' check (delivery_method in ('home', 'stopdesk')),
  stopdesk_id    int,
  stopdesk_name  text,
  note           text,

  -- Recomputed by trigger from the catalogue. Any value supplied by the
  -- browser is ignored.
  subtotal       int not null default 0 check (subtotal >= 0),
  delivery_fee   int not null default 0 check (delivery_fee >= 0),
  total          int not null default 0 check (total >= 0),

  status         public.order_status not null default 'pending',

  -- Confirmation workflow. A phone call before dispatch is what cuts COD
  -- refusals, and refusal is what destroys margin on cash-on-delivery.
  confirmed_at   timestamptz,
  confirmed_by   text,
  refused_at     timestamptz,
  refused_reason text,

  -- Delivery, populated in the delivery sprint.
  carrier          text,
  tracking_number  text,
  tracking_url     text,
  shipped_at       timestamptz,
  delivered_at     timestamptz,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- Snapshots what was bought, at the price it was bought for. Product names and
-- prices must survive later catalogue edits, so they are copied, not joined.
create table if not exists public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  variant_id     uuid references public.product_variants(id) on delete set null,
  product_name   text not null,
  variant_label  text,
  quantity       int not null check (quantity > 0),
  unit_price     int not null check (unit_price >= 0),
  created_at     timestamptz not null default now()
);

create table if not exists public.reviews (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid references public.products(id) on delete set null,
  customer_name  text not null,
  rating         int not null check (rating between 1 and 5),
  comment        text not null,
  image_url      text,
  is_approved    boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Size guides. `product_id` null means a store-wide guide that every product can
-- show; a non-null value scopes it to one product. Clothes returns drop sharply
-- when a buyer can measure, which is the whole reason this table exists.
create table if not exists public.size_guides (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid references public.products(id) on delete cascade,
  name        text not null,
  -- Column headings, e.g. {المقاس, الصدر, الطول}
  headers     text[] not null default '{}',
  -- Array of string arrays, one per row, aligned to headers. jsonb rather than
  -- a child table because a guide is always read and written whole.
  rows        jsonb not null default '[]'::jsonb,
  note        text,
  note_fr     text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Per-wilaya delivery pricing. The flat fee in store_settings is the fallback;
-- a row here overrides it for that wilaya. Keeps a store usable before Guepex
-- is connected and after, when the carrier's own rate is authoritative.
create table if not exists public.delivery_zones (
  wilaya      text primary key,
  fee         int not null default 0 check (fee >= 0),
  -- Price for pickup at the carrier's office. Null means pickup is not offered here.
  stopdesk_fee int check (stopdesk_fee >= 0),
  eta_days    int not null default 3 check (eta_days >= 1),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);


-- Columns added after the first release. Declared above for a fresh install;
-- added here for an existing one, before section 7's grants name them.
alter table public.store_settings
  add column if not exists tagline_fr text,
  add column if not exists description_fr text,
  add column if not exists address_fr text;
alter table public.size_guides
  add column if not exists note_fr text;
alter table public.store_settings
  add column if not exists brand_color text check (brand_color ~ '^#[0-9a-fA-F]{6}$');
alter table public.delivery_zones
  add column if not exists stopdesk_fee int check (stopdesk_fee >= 0);
-- Who placed the order, as a hash of the caller's IP address (never the address
-- itself), so place_order() can cap how many orders one connection places an hour.
alter table public.orders
  add column if not exists client_key text;
alter table public.orders
  add column if not exists delivery_method text not null default 'home'
    check (delivery_method in ('home', 'stopdesk')),
  add column if not exists stopdesk_id int,
  add column if not exists stopdesk_name text;

-- =============================================================================
-- 3. Indexes
--
-- Only on columns a known query actually filters or sorts by. An index speeds
-- reads and slows every write on that table.
-- =============================================================================

create index if not exists products_status_idx      on public.products (status);
create index if not exists products_kind_idx        on public.products (kind);
create index if not exists variants_product_idx     on public.product_variants (product_id);
create index if not exists variants_active_idx      on public.product_variants (product_id) where is_active;
create index if not exists variant_images_variant_idx on public.variant_images (variant_id);
create index if not exists pack_items_product_idx   on public.pack_items (product_id);
-- The admin order list sorts by newest first.
create index if not exists orders_created_at_idx     on public.orders (created_at desc);
create index if not exists orders_status_idx        on public.orders (status);
create index if not exists orders_client_key_idx    on public.orders (client_key, created_at desc);
create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists reviews_product_idx      on public.reviews (product_id);
create index if not exists reviews_approved_idx     on public.reviews (created_at desc) where is_approved;
-- Covering indexes for the two foreign keys that Supabase's performance advisor
-- flagged. Without them, deleting a variant scans both tables, and the cascade
-- from products -> variants -> these rows gets slower as the catalogue grows.
create index if not exists order_items_variant_idx  on public.order_items (variant_id);
create index if not exists pack_items_variant_idx   on public.pack_items (variant_id);
create index if not exists size_guides_product_idx  on public.size_guides (product_id);


-- =============================================================================
-- 4. Functions
-- =============================================================================

-- Is this user an admin, and of what role?
--
-- SECURITY DEFINER so the policy can read admin_users without recursing into
-- admin_users' own policy. search_path is pinned and every reference is
-- schema-qualified, so a caller cannot point an unqualified name at their own
-- object and run it with this function owner's privileges.
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

revoke all on function public.has_admin_role(uuid, public.admin_role[]) from public;
grant execute on function public.has_admin_role(uuid, public.admin_role[]) to anon, authenticated;

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

-- Recompute an order's money from the stored lines.
--
-- Runs AFTER the line is written. This is the safety net that keeps totals
-- correct when an admin adds or removes a line from the dashboard. The unit
-- price itself is fixed earlier, by validate_order_item, which runs BEFORE.
create or replace function public.recalculate_order_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_subtotal int;
  v_fee      int;
begin
  -- Branch on tg_op instead of writing coalesce(new.x, old.x). In an INSERT
  -- trigger `old` is unassigned and in a DELETE trigger `new` is unassigned, so
  -- touching the wrong one raises "record old is not assigned yet" at runtime,
  -- not at create time. It compiles cleanly and then fails on the first row.
  if tg_op = 'DELETE' then
    v_order_id := old.order_id;
  else
    v_order_id := new.order_id;
  end if;

  select coalesce(sum(oi.quantity * oi.unit_price), 0)
    into v_subtotal
  from public.order_items oi
  where oi.order_id = v_order_id;

  select coalesce((select delivery_fee_flat from public.store_settings where id = 1), 0)
    into v_fee;

  update public.orders
     set subtotal     = v_subtotal,
         delivery_fee = v_fee,
         total        = v_subtotal + v_fee
   where id = v_order_id;

  -- Same reason: coalesce() cannot identify a composite record type.
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Field validation. The browser validates for the user's benefit; this is the
-- actual control, because a hand-crafted request never passes through React.
create or replace function public.validate_order()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if length(trim(coalesce(new.customer_name, ''))) < 2 or length(new.customer_name) > 120 then
    raise exception 'Invalid customer_name';
  end if;
  if new.phone !~ '^[0-9+\s\-]{8,20}$' then
    raise exception 'Invalid phone';
  end if;
  if length(trim(coalesce(new.wilaya, ''))) < 2 or length(new.wilaya) > 80 then
    raise exception 'Invalid wilaya';
  end if;
  if length(trim(coalesce(new.address, ''))) < 5 or length(new.address) > 500 then
    raise exception 'Invalid address';
  end if;
  if new.note is not null and length(new.note) > 1000 then
    raise exception 'Note too long';
  end if;

  -- An order always opens as pending. Callers cannot supply a different
  -- status, so nobody can open an order that is already marked delivered.
  new.status := 'pending';

  return new;
end;
$$;

create or replace function public.validate_order_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.quantity is null or new.quantity < 1 or new.quantity > 20 then
    raise exception 'Invalid quantity';
  end if;

  -- The browser sends only a variant_id and a quantity. Price and names are
  -- read from the catalogue here, so a hand-crafted request cannot buy a
  -- 45000 DZD variant for 1 DZD.
  select pv.price,
         nullif(concat_ws(' / ', nullif(pv.size, ''), nullif(pv.color_name, '')), ''),
         p.name
    into new.unit_price, new.variant_label, new.product_name
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where pv.id = new.variant_id;

  if not found then
    raise exception 'Variant does not exist';
  end if;

  if not exists (
    select 1 from public.product_variants
    where id = new.variant_id and is_active
  ) then
    raise exception 'Variant unavailable';
  end if;

  return new;
end;
$$;

create or replace function public.validate_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A script could fill the moderation queue with junk. Twenty waiting reviews an
  -- hour is far above what a small shop receives, and a flood stops there.
  -- Security definer so the count sees unapproved rows, which RLS hides.
  if (
    select count(*) from public.reviews r
    where not r.is_approved and r.created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'Too many reviews right now, please try again later'
      using errcode = 'check_violation', hint = 'too_many_reviews';
  end if;
  if length(trim(coalesce(new.customer_name, ''))) < 2 or length(new.customer_name) > 120 then
    raise exception 'Invalid customer_name';
  end if;
  if length(trim(coalesce(new.comment, ''))) < 3 or length(new.comment) > 2000 then
    raise exception 'Invalid comment';
  end if;
  -- Nobody self-approves, not even a signed-in admin pasting their own row in.
  new.is_approved := false;
  return new;
end;
$$;

-- Place an order and return its tracking token.
--
-- One transaction, one round trip. The alternative -- insert the order, then
-- insert its lines, then read it back -- leaves half-written orders behind
-- whenever the connection drops between calls, and those orphan rows still
-- occupy a stock order number and a confirmation slot in the phone queue.
--
-- The caller sends names, phone and a list of variant ids. It never sends a
-- price: validate_order_item reads unit_price from the catalogue.
create or replace function public.place_order(
  p_customer jsonb,
  p_items    jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_token    uuid;
  v_item     jsonb;
  v_inserted int := 0;
  v_units    int;
  v_headers  json;
  v_ip       text;
  v_client   text;
begin
  if p_customer is null or p_items is null then
    raise exception 'Missing order details';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Items must be a list';
  end if;

  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
    raise exception 'Order must contain between 1 and 50 items';
  end if;

  -- Fake orders drain real stock: every line takes stock away until the owner
  -- refuses it. Fifty pieces is a large retail order; bigger ones go through
  -- WhatsApp or a phone call.
  select coalesce(sum(greatest(coalesce((i->>'quantity')::int, 1), 1)), 0)
    into v_units from jsonb_array_elements(p_items) i;
  if v_units > 50 then
    raise exception 'Too many pieces in one order'
      using errcode = 'check_violation', hint = 'too_many_items';
  end if;

  -- One connection may place ten orders an hour. The per-phone cap alone does
  -- not stop a script inventing numbers. The IP is stored only as a salted hash.
  -- Not the first x-forwarded-for entry: a caller can write that one, and
  -- Cloudflare appends the real address after it (supabase discussion 34647).
  -- cf-connecting-ip is Cloudflare's own; the last forwarded entry is the
  -- fallback. Calls with neither (the SQL editor) are not limited.
  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_ip := coalesce(
    nullif(trim(v_headers->>'cf-connecting-ip'), ''),
    nullif(trim(regexp_replace(coalesce(v_headers->>'x-forwarded-for', ''), '^.*,', '')), '')
  );
  if v_ip is not null then
    v_client := md5('openstore-order:' || v_ip);
    -- Parallel requests from one connection wait here, so each one counts the
    -- orders committed before it and the eleventh is refused.
    perform pg_advisory_xact_lock(hashtext(v_client));
    if (
      select count(*) from public.orders o
      where o.client_key = v_client and o.created_at > now() - interval '1 hour'
    ) >= 10 then
      raise exception 'Too many orders from this connection, please try again later'
        using errcode = 'check_violation', hint = 'too_many_orders';
    end if;
  end if;

  -- validate_order() still runs as the BEFORE INSERT trigger and does the field
  -- checks. This function only decides the rows.
  insert into public.orders (customer_name, phone, wilaya, commune, address, note,
                             delivery_method, stopdesk_id, stopdesk_name, client_key)
  values (
    coalesce(p_customer->>'customer_name', ''),
    coalesce(p_customer->>'phone', ''),
    coalesce(p_customer->>'wilaya', ''),
    nullif(p_customer->>'commune', ''),
    coalesce(p_customer->>'address', ''),
    nullif(p_customer->>'note', ''),
    coalesce(nullif(p_customer->>'delivery_method', ''), 'home'),
    nullif(p_customer->>'stopdesk_id', '')::int,
    nullif(p_customer->>'stopdesk_name', ''),
    v_client
  )
  returning id, public_token into v_order_id, v_token;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into public.order_items (order_id, variant_id, quantity)
    values (
      v_order_id,
      (v_item->>'variant_id')::uuid,
      coalesce((v_item->>'quantity')::int, 1)
    );
    v_inserted := v_inserted + 1;
  end loop;

  if v_inserted = 0 then
    raise exception 'Order has no items';
  end if;

  -- Recompute now rather than relying on the row trigger, so the token is
  -- returned only once the order is fully priced.
  perform public.recalculate_for_order(v_order_id);

  return v_token;
end;
$$;

-- Recompute one order's totals. Split out of the trigger so place_order() can
-- force a synchronous recalculation instead of relying on AFTER-trigger order.
create or replace function public.recalculate_for_order(p_order_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.orders o
     set subtotal     = coalesce(s.sub, 0),
         delivery_fee = coalesce((select delivery_fee_flat from public.store_settings where id = 1), 0),
         total        = coalesce(s.sub, 0)
                    + coalesce((select delivery_fee_flat from public.store_settings where id = 1), 0)
    from (select sum(quantity * unit_price) as sub
            from public.order_items where order_id = p_order_id) s
   where o.id = p_order_id;
$$;

-- Read one order by its tracking token.
--
-- This is the only way an anonymous visitor learns anything about an order, and
-- it returns address and phone because the buyer typed them and the courier
-- needs them. It must not return the customer note beyond what tracking needs,
-- and it must never return internal ids that could be enumerated.
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

  select * into v_order
  from public.orders
  where public_token = p_token;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'token',        v_order.public_token,
    'customer_name', v_order.customer_name,
    'phone',        v_order.phone,
    'wilaya',       v_order.wilaya,
    'commune',      v_order.commune,
    'address',      v_order.address,
    'delivery_method', v_order.delivery_method,
    'stopdesk_name', v_order.stopdesk_name,
    'subtotal',     v_order.subtotal,
    'delivery_fee', v_order.delivery_fee,
    'total',        v_order.total,
    'status',       v_order.status,
    'carrier',      v_order.carrier,
    'tracking_number', v_order.tracking_number,
    'tracking_url', v_order.tracking_url,
    'created_at',   v_order.created_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_name',  oi.product_name,
        'variant_label', oi.variant_label,
        'quantity',      oi.quantity,
        'unit_price',    oi.unit_price
      ))
      from public.order_items oi
      where oi.order_id = v_order.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.place_order(jsonb, jsonb) from public;
grant execute on function public.place_order(jsonb, jsonb) to anon, authenticated;
revoke all on function public.track_order(uuid) from public;
grant execute on function public.track_order(uuid) to anon, authenticated;
-- place_order() calls recalculate_for_order internally as the owner, and the
-- AFTER trigger on order_items already keeps totals right when the dashboard
-- edits a line. No client needs to call it over RPC.
revoke all on function public.recalculate_for_order(uuid) from public, anon, authenticated;

-- Trigger functions are invoked by the trigger machinery, which does not check
-- EXECUTE privileges, so revoking costs nothing and removes them from the
-- exposed RPC surface. Supabase's advisor flags any SECURITY DEFINER function
-- reachable without signing in; five of these were reachable purely by accident.
revoke all on function public.touch_updated_at()         from public, anon, authenticated;
revoke all on function public.validate_order()           from public, anon, authenticated;
revoke all on function public.validate_order_item()      from public, anon, authenticated;
revoke all on function public.validate_review()          from public, anon, authenticated;
revoke all on function public.recalculate_order_totals() from public, anon, authenticated;


-- =============================================================================
-- 5. Triggers
-- =============================================================================

drop trigger if exists touch_store_settings on public.store_settings;
create trigger touch_store_settings before update on public.store_settings
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_variants on public.product_variants;
create trigger touch_variants before update on public.product_variants
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_orders on public.orders;
create trigger touch_orders before update on public.orders
  for each row execute function public.touch_updated_at();

drop trigger if exists validate_order_trigger on public.orders;
create trigger validate_order_trigger before insert on public.orders
  for each row execute function public.validate_order();

drop trigger if exists validate_order_item_trigger on public.order_items;
create trigger validate_order_item_trigger before insert on public.order_items
  for each row execute function public.validate_order_item();

-- After, not before: the totals can only be right once the item row exists.
drop trigger if exists recalculate_order_totals_trigger on public.order_items;
create trigger recalculate_order_totals_trigger
  after insert or update or delete on public.order_items
  for each row execute function public.recalculate_order_totals();

drop trigger if exists validate_review_trigger on public.reviews;
create trigger validate_review_trigger before insert on public.reviews
  for each row execute function public.validate_review();

drop trigger if exists touch_categories on public.categories;
create trigger touch_categories before update on public.categories
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_size_guides on public.size_guides;
create trigger touch_size_guides before update on public.size_guides
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_delivery_zones on public.delivery_zones;
create trigger touch_delivery_zones before update on public.delivery_zones
  for each row execute function public.touch_updated_at();


-- =============================================================================
-- 6. Row Level Security
--
-- Policy audience is deliberately two disjoint groups: the public storefront,
-- and the shop owner. There is no tenant, because there is only one shop.
-- =============================================================================

alter table public.store_settings    enable row level security;
alter table public.admin_users       enable row level security;
alter table public.products          enable row level security;
alter table public.product_variants  enable row level security;
alter table public.variant_images    enable row level security;
alter table public.pack_items        enable row level security;
alter table public.orders            enable row level security;
alter table public.order_items       enable row level security;
alter table public.reviews           enable row level security;
alter table public.categories        enable row level security;
alter table public.size_guides       enable row level security;
alter table public.delivery_zones    enable row level security;

-- Supabase grants anon and authenticated broad privileges on new tables in the
-- public schema. Policies do NOT remove grants. Revoke first, then re-grant
-- exactly what each role needs, or the policies below are decorative.
revoke all on all tables in schema public from anon, authenticated;

-- --- store_settings: public read (name, fees, policies are all public), admin write
drop policy if exists "Public can read store settings" on public.store_settings;
create policy "Public can read store settings"
  on public.store_settings for select to anon, authenticated
  using (true);

drop policy if exists "Admins manage store settings" on public.store_settings;
create policy "Admins manage store settings"
  on public.store_settings for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner']::public.admin_role[])) is true);

-- --- admin_users: a user may read only their own row.
-- There is deliberately no INSERT/UPDATE/DELETE policy. Staff accounts are
-- created in the SQL editor by the owner. Allowing a self-service policy would
-- mean every admin could promote themselves to owner.
drop policy if exists "Users read their own role" on public.admin_users;
create policy "Users read their own role"
  on public.admin_users for select to authenticated
  using ((select auth.uid()) = user_id);

-- --- products: published are public, drafts are admin-only
drop policy if exists "Public reads published products" on public.products;
create policy "Public reads published products"
  on public.products for select to anon, authenticated
  using (status = 'published');

drop policy if exists "Admins manage products" on public.products;
create policy "Admins manage products"
  on public.products for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- categories, size guides, delivery zones: public read, admin write.
-- All three are what the storefront shows before a buyer commits, so reading
-- them needs no session. Hidden categories and paused zones stay admin-only.
drop policy if exists "Public reads active categories" on public.categories;
create policy "Public reads active categories"
  on public.categories for select to anon, authenticated
  using (is_active);

drop policy if exists "Admins manage categories" on public.categories;
create policy "Admins manage categories"
  on public.categories for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

drop policy if exists "Public reads size guides" on public.size_guides;
create policy "Public reads size guides"
  on public.size_guides for select to anon, authenticated
  using (true);

drop policy if exists "Admins manage size guides" on public.size_guides;
create policy "Admins manage size guides"
  on public.size_guides for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

drop policy if exists "Public reads active delivery zones" on public.delivery_zones;
create policy "Public reads active delivery zones"
  on public.delivery_zones for select to anon, authenticated
  using (is_active);

drop policy if exists "Admins manage delivery zones" on public.delivery_zones;
create policy "Admins manage delivery zones"
  on public.delivery_zones for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- product_variants: readable only when the parent product is published
drop policy if exists "Public reads published variants" on public.product_variants;
create policy "Public reads published variants"
  on public.product_variants for select to anon, authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_id and p.status = 'published'
  ));

drop policy if exists "Admins manage variants" on public.product_variants;
create policy "Admins manage variants"
  on public.product_variants for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- variant_images
drop policy if exists "Public reads published images" on public.variant_images;
create policy "Public reads published images"
  on public.variant_images for select to anon, authenticated
  using (exists (
    select 1
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = variant_id and p.status = 'published'
  ));

drop policy if exists "Admins manage images" on public.variant_images;
create policy "Admins manage images"
  on public.variant_images for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- pack_items
drop policy if exists "Public reads published pack items" on public.pack_items;
create policy "Public reads published pack items"
  on public.pack_items for select to anon, authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_id and p.status = 'published'
  ));

drop policy if exists "Admins manage pack items" on public.pack_items;
create policy "Admins manage pack items"
  on public.pack_items for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- orders: anon has NO insert policy and NO select policy.
--
-- Orders are only ever written by place_order(), a SECURITY DEFINER function
-- owned by postgres, which bypasses RLS and performs the order insert and its
-- line inserts in one transaction. An anon INSERT policy would let a caller
-- write an order with no lines, or attach lines to any order whose id they
-- guessed, which is exactly what the RPC exists to prevent.
drop policy if exists "Anyone can place an order" on public.orders;

drop policy if exists "Buyers track their own order by token" on public.orders;
-- No public SELECT policy on orders. Tracking goes through track_order(), which
-- takes the token as an argument. Letting anon read orders by a session-scoped
-- GUC instead would make "can this caller see this order" depend on a request
-- header rather than on the value itself.

drop policy if exists "Admins manage orders" on public.orders;
create policy "Admins manage orders"
  on public.orders for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- order_items: anon has NO insert policy and NO select policy, for the same
-- reason as orders. place_order() writes the lines, track_order() reads them.
drop policy if exists "Buyers add lines to their own order" on public.order_items;

drop policy if exists "Buyers read lines of a tracked order" on public.order_items;
-- No public SELECT policy on order_items either. track_order() returns the
-- lines together with the order.

drop policy if exists "Admins manage order items" on public.order_items;
create policy "Admins manage order items"
  on public.order_items for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

-- --- reviews: public reads approved, anyone submits unapproved, admins moderate
drop policy if exists "Public reads approved reviews" on public.reviews;
create policy "Public reads approved reviews"
  on public.reviews for select to anon, authenticated
  using (is_approved);

drop policy if exists "Anyone submits a review" on public.reviews;
create policy "Anyone submits a review"
  on public.reviews for insert to anon, authenticated
  with check (is_approved = false);

drop policy if exists "Admins manage reviews" on public.reviews;
create policy "Admins manage reviews"
  on public.reviews for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);


-- =============================================================================
-- 7. Grants
--
-- PostgREST checks these BEFORE RLS. A missing grant here returns 401 even
-- though the policy above is perfect.
-- =============================================================================

grant usage on schema public to anon, authenticated;

-- The storefront sees only published catalogue rows. Orders, order_items and
-- admin_users are deliberately absent: they are reached through
-- place_order(), track_order() and the authenticated role instead.
grant select on public.store_settings   to anon, authenticated;
grant select on public.products         to anon, authenticated;
grant select on public.product_variants to anon, authenticated;
grant select on public.variant_images   to anon, authenticated;
grant select on public.pack_items       to anon, authenticated;
grant select on public.reviews          to anon, authenticated;
grant select on public.categories       to anon, authenticated;
grant select on public.size_guides      to anon, authenticated;
grant select on public.delivery_zones   to anon, authenticated;

-- Buyers do not get table-level INSERT on orders or order_items. place_order()
-- is their only route in and it is granted as a function, not as a table
-- privilege. Reviews stay directly insertable because a review is a single
-- self-contained row with nothing to couple it to.
grant insert on public.reviews to anon, authenticated;

-- The shop owner runs the dashboard from the same browser client.
-- Orders are listed separately below rather than included here.
grant select, insert, update, delete on
  public.products, public.product_variants, public.variant_images,
  public.pack_items, public.order_items, public.reviews,
  public.store_settings, public.categories, public.size_guides,
  public.delivery_zones
  to authenticated;

grant select on public.admin_users to authenticated;

-- Orders: column-level UPDATE only, and deliberately excluding the money.
--
-- These two lines have to be written this way. A table-level
-- `grant update on public.orders` followed by `revoke update (total)` does NOT
-- work: the table-level grant still covers every column, so the revoke is a
-- no-op and the dashboard can type its own totals. Column privileges are a
-- separate grant set from table privileges, so the table-level UPDATE must
-- simply never be issued.
grant select, insert, delete on public.orders to authenticated;

grant update (id, public_token, customer_name, phone, wilaya, commune, address,
              note, status, confirmed_at, confirmed_by, refused_at, refused_reason,
              carrier, tracking_number, tracking_url, shipped_at, delivered_at,
              stopdesk_id, stopdesk_name)
  on public.orders to authenticated;

-- Keep future tables consistent with the pattern above.
alter default privileges in schema public grant select on tables to anon, authenticated;


-- =============================================================================
-- 8. Storage
--
-- One public bucket for product and review imagery. Public read is the point:
-- an <img src> must resolve without a session. Listing stays closed, writing is
-- admin-only.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-media', 'product-media', true, 8388608,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/gif']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public reads product media" on storage.objects;
create policy "Public reads product media"
  on storage.objects for select
  using (bucket_id = 'product-media');

drop policy if exists "Admins upload product media" on storage.objects;
create policy "Admins upload product media"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-media'
    and public.has_admin_role(auth.uid(), array['owner','staff']::public.admin_role[]) is true
  );

drop policy if exists "Admins update product media" on storage.objects;
create policy "Admins update product media"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'product-media'
    and public.has_admin_role(auth.uid(), array['owner','staff']::public.admin_role[]) is true
  )
  with check (
    bucket_id = 'product-media'
    and public.has_admin_role(auth.uid(), array['owner','staff']::public.admin_role[]) is true
  );

drop policy if exists "Admins delete product media" on storage.objects;
create policy "Admins delete product media"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'product-media'
    and public.has_admin_role(auth.uid(), array['owner','staff']::public.admin_role[]) is true
  );

grant all on storage.objects to authenticated;


-- =============================================================================
-- 9. Seed: a working demo shop
--
-- A fresh install must show a shop, not an empty screen. An empty first screen
-- reads as broken. Every insert is idempotent.
-- =============================================================================

insert into public.store_settings (
  id, name, tagline, description,
  legal_name, nif, rc_number, phone, whatsapp, address,
  delivery_fee_flat, delivery_wilayas, delivery_eta_days, returns_days,
  free_shipping_threshold
) values (
  1,
  'OpenStore DZ',
  'متجرك الإلكتروني — الدفع عند الاستلام',
  'This is the demo shop created by supabase/schema.sql. Edit it in Settings, or delete the demo products and add your own.',
       'Demo SARL', '000000000000000', '00/00-0000000', '+213 555 00 00 00', '+213 555 00 00 00',
  'Alger, Algeria',
  600,
  -- Empty means every wilaya. It was a list of Arabic names, which the checkout
  -- (matching on the carrier's Latin names) filtered down to nothing.
  '{}',
  3, 14,
  10000
)
on conflict (id) do nothing;

-- Demo content goes only into a shop nobody has claimed yet. Owners re-run this
-- file to update a live shop, and that must never bring back demo products,
-- photos or reviews they deleted.
do $$
begin
  if exists (select 1 from public.admin_users) then
    return;
  end if;

  -- Two products: one single item, one pack. Prices and stock are the numbers the
  -- storefront and the seed-verification query in the README expect.
  insert into public.categories (slug, name, name_fr, sort_order)
  values
    ('shirts', 'قمصان', 'Chemises', 1),
    ('packs',  'باقات', 'Packs',    2)
  on conflict (slug) do nothing;

  insert into public.products (id, slug, name, name_fr, description, kind, status, category_id, published_at)
  values
    ('11111111-1111-4111-8111-111111111111', 'shirt-demo',  'قميص قطني كلاسيكي',  'Chemise coton classique',  'قميص قطني 100% بقصة مريحة، مناسب للعمل والمناسبات اليومية.', 'single', 'published', (select id from public.categories where slug = 'shirts'), now()),
    ('22222222-2222-4222-8222-222222222222', 'pack-demo',    'باك القميص + البنطال', 'Pack chemise + pantalon', 'باقة موفرة تجمع قميصاً وبنطالاً بسعر أقل من شرائهما منفصلين.', 'pack', 'published', (select id from public.categories where slug = 'packs'), now())
  on conflict (id) do nothing;

  insert into public.product_variants (id, product_id, size, color_name, color_hex, sku, price, stock, weight_grams, sort_order)
  values
    ('aaaaaaaa-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'M',  'أبيض',  '#ffffff', 'DEMO-TS-W-M',  2500, 12, 180, 0),
    ('aaaaaaaa-2222-4111-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'L',  'أسود',  '#000000', 'DEMO-TS-B-L',  2500,  8, 180, 1),
    ('bbbbbbbb-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', 'M',  'أبيض',  '#ffffff', 'DEMO-PK-W-M',  4500,  6, 420, 0),
    ('bbbbbbbb-2222-4111-8222-222222222222', '22222222-2222-4222-8222-222222222222', 'L',  'أسود',  '#000000', 'DEMO-PK-B-L',  4500,  4, 420, 1)
  on conflict (id) do nothing;

  -- Demo imagery: external placeholders so a fresh install renders a shop that
  -- looks like a shop on first load. Replace with uploaded media.
  insert into public.variant_images (variant_id, url, alt, sort_order)
  values
    ('aaaaaaaa-1111-4111-8111-111111111111', 'https://picsum.photos/seed/openstore-shirt-white/900/900', 'قميص أبيض', 0),
    ('aaaaaaaa-2222-4111-8222-222222222222', 'https://picsum.photos/seed/openstore-shirt-black/900/900', 'قميص أسود', 0),
    ('bbbbbbbb-1111-4111-8111-111111111111', 'https://picsum.photos/seed/openstore-pack-white/900/900', 'باقة بيضاء', 0),
    ('bbbbbbbb-2222-4111-8222-222222222222', 'https://picsum.photos/seed/openstore-pack-black/900/900', 'باقة سوداء', 0)
  on conflict do nothing;

  insert into public.pack_items (product_id, variant_id, quantity, sort_order)
  values
    ('22222222-2222-4222-8222-222222222222', 'aaaaaaaa-1111-4111-8111-111111111111', 1, 0),
    ('22222222-2222-4222-8222-222222222222', 'bbbbbbbb-1111-4111-8111-111111111111', 1, 1)
  on conflict (product_id, variant_id) do nothing;

  insert into public.reviews (id, product_id, customer_name, rating, comment, is_approved)
  values
    ('cccccccc-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'سعاد', 5, 'قماش ممتاز والتوصيل كان سريع.', true),
    ('cccccccc-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', 'كريم', 4, 'الباك مناسب والسعر معقول.', true)
  on conflict (id) do nothing;

  -- The `true` above is a lie, and deliberately so. validate_review() forces
  -- is_approved := false on every INSERT, including this one, because that trigger
  -- is the control that stops a customer approving their own review. The demo
  -- reviews therefore arrive unapproved and are approved here with an UPDATE,
  -- which is exactly the path the moderation screen uses. Do not "fix" this by
  -- weakening the trigger.
  update public.reviews
     set is_approved = true
   where id in (
     'cccccccc-1111-4111-8111-111111111111',
     'cccccccc-2222-4222-8222-222222222222'
   )
     and is_approved = false;
end;
$$;

-- =============================================================================
-- 10. Later additions
--
-- Everything below was applied to the live database as a migration and then
-- written back here. Leaving it out would mean a fresh install from this file
-- produced an older, weaker database than the one in production: no stock
-- decrement (so it would oversell), no way to become an administrator, and no
-- phone validation. Appended in dependency order rather than interleaved above,
-- because every statement here is idempotent and the order within the block is
-- what matters.
-- =============================================================================

-- ── Sale pricing ────────────────────────────────────────────────────────────
alter table public.product_variants
  add column if not exists compare_at_price int
  check (compare_at_price is null or compare_at_price >= 0);

comment on column public.product_variants.compare_at_price is
  'Original price when the variant is on sale, in dinar. Null means no sale.';

-- ── Carrier webhook audit ───────────────────────────────────────────────────
create table if not exists public.guepex_webhook_events (
  id           uuid primary key default gen_random_uuid(),
  event_id     text not null unique,
  type         text not null,
  occurred_at  timestamptz,
  data         jsonb not null default '{}'::jsonb,
  processed_at timestamptz,
  note         text,
  created_at   timestamptz not null default now()
);

create index if not exists guepex_events_created_idx on public.guepex_webhook_events (created_at desc);
create index if not exists guepex_events_type_idx    on public.guepex_webhook_events (type);

alter table public.guepex_webhook_events enable row level security;

drop policy if exists "Admins read carrier events" on public.guepex_webhook_events;
create policy "Admins read carrier events"
  on public.guepex_webhook_events for select to authenticated
  using ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

revoke all on public.guepex_webhook_events from anon, authenticated;
grant select on public.guepex_webhook_events to authenticated;

-- ── Algerian phone validation ───────────────────────────────────────────────
-- The original rule was `^[0-9+\s\-]{8,20}$`, which accepts "12345678". On cash
-- on delivery the phone is the only way to confirm an order.
create or replace function public.normalise_dz_phone(raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(coalesce(raw, ''), '[^0-9+]', '', 'g');
$$;

create or replace function public.is_valid_dz_phone(raw text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with cleaned as (select public.normalise_dz_phone(raw) as p)
  select case
    when p ~ '^0[5-7][0-9]{8}$' then true
    when p ~ '^\+?213[5-7][0-9]{8}$' then true
    when p ~ '^0[2-4][0-9]{7,8}$' then true
    when p ~ '^\+?213[2-4][0-9]{7,8}$' then true
    else false
  end
  from cleaned;
$$;

grant execute on function public.is_valid_dz_phone(text) to anon, authenticated;

-- ── Order item: price from the catalogue, stock decremented atomically ──────
create or replace function public.validate_order_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.quantity is null or new.quantity < 1 or new.quantity > 20 then
    raise exception 'Invalid quantity' using errcode = 'check_violation';
  end if;

  select pv.price,
         nullif(concat_ws(' / ', nullif(pv.size, ''), nullif(pv.color_name, '')), ''),
         p.name
    into new.unit_price, new.variant_label, new.product_name
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where pv.id = new.variant_id;

  if not found then
    raise exception 'Variant does not exist' using errcode = 'check_violation';
  end if;

  -- Atomic conditional decrement. Two simultaneous orders for the last item
  -- cannot both match, which a read-then-write check would allow.
  update public.product_variants
     set stock = stock - new.quantity
   where id = new.variant_id
     and is_active
     and stock >= new.quantity;

  if not found then
    if not exists (select 1 from public.product_variants where id = new.variant_id and is_active) then
      raise exception 'Variant unavailable' using errcode = 'check_violation';
    end if;
    raise exception 'Insufficient stock for %', coalesce(new.variant_label, 'item')
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ── Fake-order protection ──────────────────────────────────────────────────
-- Fake cash-on-delivery orders cost a shop the outbound and return shipping of
-- a parcel nobody collects. Two controls, enforced here so a script cannot skip
-- them: a number may hold at most three unconfirmed orders a day, and an owner
-- can block a number outright. Numbers are compared in one canonical form, so
-- "+213 555..." and "0555..." are the same buyer.
create or replace function public.canonical_dz_phone(raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p ~ '^\+?213' then '0' || regexp_replace(p, '^\+?213', '') else p end
  from (select regexp_replace(coalesce(raw, ''), '[^0-9+]', '', 'g') as p) cleaned;
$$;

create table if not exists public.blocked_phones (
  phone       text primary key,
  reason      text,
  created_at  timestamptz not null default now()
);

alter table public.blocked_phones enable row level security;

drop policy if exists "Admins manage blocked phones" on public.blocked_phones;
create policy "Admins manage blocked phones"
  on public.blocked_phones for all to authenticated
  using      ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true)
  with check ((select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true);

revoke all on public.blocked_phones from anon, authenticated;
grant select, insert, delete on public.blocked_phones to authenticated;

create index if not exists orders_phone_canon_idx
  on public.orders (public.canonical_dz_phone(phone), created_at desc);

-- What the dashboard shows next to an order: how this number has behaved before.
create or replace function public.admin_phone_history(p_phones text[])
returns table (phone text, orders bigint, refused bigint, delivered bigint, blocked boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.phone,
         count(o.id),
         count(o.id) filter (where o.status in ('refused', 'returned')),
         count(o.id) filter (where o.status = 'delivered'),
         exists (select 1 from public.blocked_phones b where b.phone = c.phone)
  from (select distinct public.canonical_dz_phone(x) as phone from unnest(p_phones) as x) c
  left join public.orders o on public.canonical_dz_phone(o.phone) = c.phone
  where (select public.has_admin_role((select auth.uid()), array['owner','staff']::public.admin_role[])) is true
  group by c.phone;
$$;

revoke all on function public.admin_phone_history(text[]) from public, anon;
grant execute on function public.admin_phone_history(text[]) to authenticated;

-- ── Order: field checks plus the owner's selling rules ─────────────────────
create or replace function public.validate_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_open boolean;
  v_allowed text[];
begin
  if length(trim(coalesce(new.customer_name, ''))) < 2 or length(new.customer_name) > 120 then
    raise exception 'Invalid customer_name' using errcode = 'check_violation';
  end if;

  if not public.is_valid_dz_phone(new.phone) then
    raise exception 'Invalid Algerian phone number' using errcode = 'check_violation';
  end if;

  if length(trim(coalesce(new.wilaya, ''))) < 2 or length(new.wilaya) > 80 then
    raise exception 'Invalid wilaya' using errcode = 'check_violation';
  end if;
  if length(trim(coalesce(new.address, ''))) < 5 or length(new.address) > 500 then
    raise exception 'Invalid address' using errcode = 'check_violation';
  end if;
  if new.note is not null and length(new.note) > 1000 then
    raise exception 'Note too long' using errcode = 'check_violation';
  end if;

  select accepts_cod, delivery_wilayas into v_open, v_allowed
  from public.store_settings where id = 1;

  if v_open is false then
    raise exception 'The shop is not accepting orders right now' using errcode = 'check_violation';
  end if;

  -- An empty list means everywhere. A populated list is a hard restriction.
  if coalesce(array_length(v_allowed, 1), 0) > 0 and not (new.wilaya = any(v_allowed)) then
    raise exception 'We do not deliver to % yet', new.wilaya using errcode = 'check_violation';
  end if;

  -- Pickup only where the owner priced it, so a buyer is never charged a
  -- pickup fee the shop never agreed to.
  if new.delivery_method = 'stopdesk' and not exists (
    select 1 from public.delivery_zones dz
    where dz.wilaya = new.wilaya and dz.is_active and dz.stopdesk_fee is not null
  ) then
    raise exception 'Pickup is not offered in %', new.wilaya
      using errcode = 'check_violation', hint = 'stopdesk_unavailable';
  end if;
  if new.delivery_method = 'home' then
    new.stopdesk_id := null;
    new.stopdesk_name := null;
  end if;

  -- The hint is a stable code the checkout translates; the message is for logs.
  if exists (
    select 1 from public.blocked_phones b where b.phone = public.canonical_dz_phone(new.phone)
  ) then
    raise exception 'This phone number cannot place orders'
      using errcode = 'check_violation', hint = 'phone_blocked';
  end if;

  if (
    select count(*) from public.orders o
    where public.canonical_dz_phone(o.phone) = public.canonical_dz_phone(new.phone)
      and o.status = 'pending'
      and o.created_at > now() - interval '24 hours'
  ) >= 3 then
    raise exception 'Too many unconfirmed orders for this phone number'
      using errcode = 'check_violation', hint = 'too_many_pending';
  end if;

  new.status := 'pending';
  return new;
end;
$$;

-- ── Restock when an order ends negatively ──────────────────────────────────
create or replace function public.restock_on_negative_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if new.status in ('refused', 'cancelled', 'returned')
     and old.status not in ('refused', 'cancelled', 'returned') then
    update public.product_variants pv
       set stock = pv.stock + oi.quantity
      from public.order_items oi
     where oi.order_id = new.id
       and oi.variant_id = pv.id;
  end if;

  return new;
end;
$$;

drop trigger if exists restock_on_negative_status_trigger on public.orders;
create trigger restock_on_negative_status_trigger
  after update of status on public.orders
  for each row execute function public.restock_on_negative_status();

revoke all on function public.restock_on_negative_status() from public, anon, authenticated;

-- ── Delivery fee: the zone, the flat fee, and the free-delivery threshold ──
-- The checkout shows the buyer the wilaya's zone fee, and the storefront
-- promises free delivery above the threshold. The totals used to charge the
-- flat fee regardless, so the order the courier collected on was not the order
-- the buyer agreed to. src/lib/delivery.ts mirrors this rule for display only.
alter table public.store_settings
  add column if not exists free_shipping_threshold int not null default 0
  check (free_shipping_threshold >= 0);

-- The two-argument version predates pickup. Left in place it would make every
-- two-argument call ambiguous against the defaulted three-argument one.
drop function if exists public.delivery_fee_for(text, int);

create or replace function public.delivery_fee_for(
  p_wilaya text,
  p_subtotal int,
  p_method text default 'home'
)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when s.free_shipping_threshold > 0 and p_subtotal >= s.free_shipping_threshold then 0
    when p_method = 'stopdesk' then
      (select dz.stopdesk_fee from public.delivery_zones dz where dz.wilaya = p_wilaya and dz.is_active)
    else coalesce(
      (select dz.fee from public.delivery_zones dz where dz.wilaya = p_wilaya and dz.is_active),
      s.delivery_fee_flat
    )
  end
  from public.store_settings s
  where s.id = 1;
$$;

create or replace function public.recalculate_for_order(p_order_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.orders o
     set subtotal     = s.sub,
         delivery_fee = coalesce(public.delivery_fee_for(o.wilaya, s.sub, o.delivery_method), 0),
         total        = s.sub + coalesce(public.delivery_fee_for(o.wilaya, s.sub, o.delivery_method), 0)
    from (select coalesce(sum(quantity * unit_price), 0)::int as sub
            from public.order_items where order_id = p_order_id) s
   where o.id = p_order_id;
$$;

-- The line trigger now defers to the same function, so a dashboard edit and a
-- new order can never price delivery two different ways.
create or replace function public.recalculate_order_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recalculate_for_order(old.order_id);
    return old;
  end if;
  perform public.recalculate_for_order(new.order_id);
  return new;
end;
$$;

-- ── Dashboard analytics ─────────────────────────────────────────────────────
-- One function, one round trip, so the totals are computed over every order
-- rather than over whatever a capped browser fetch happened to return. The
-- shape is the `Analytics` type in src/lib/analytics.ts.
--
-- "Confirmed value" counts orders the buyer said yes to on the phone and that
-- have not since failed. A refusal is a refused or returned parcel: both cost
-- the outbound and the return. Wilayas under three orders are left out, because
-- one refusal out of one order is noise, not a rate.
create or replace function public.admin_analytics(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since timestamptz;
  v_days  int := greatest(1, least(coalesce(p_days, 30), 366));
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
      'revenue', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'day', to_char(d.day, 'YYYY-MM-DD'),
                 'orders', coalesce(x.orders, 0),
                 'value', coalesce(x.value, 0)) order by d.day), '[]'::jsonb)
        from generate_series(v_since, date_trunc('day', now()), interval '1 day') as d(day)
        left join (
          select date_trunc('day', created_at) as day,
                 count(*) as orders,
                 sum(total) filter (where status in ('confirmed','shipped','delivered')) as value
          from win group by 1
        ) x on x.day = d.day
      ),
      'funnel', (
        select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
        from (select status::text as status, count(*) as n from win group by 1) f
      ),
      'totals', (
        select jsonb_build_object(
          'orders', count(*),
          'confirmedValue', coalesce(sum(total) filter (where status in ('confirmed','shipped','delivered')), 0),
          'refused', count(*) filter (where status in ('refused','returned')))
        from win
      ),
      'byWilaya', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'wilaya', wilaya, 'total', total, 'delivered', delivered,
                 'refused', refused, 'rate', round(refused::numeric / total, 4))
               order by refused::numeric / total desc, total desc), '[]'::jsonb)
        from (
          select wilaya, count(*) as total,
                 count(*) filter (where status = 'delivered') as delivered,
                 count(*) filter (where status in ('refused','returned')) as refused
          from win group by wilaya having count(*) >= 3
        ) w
      ),
      'topProducts', (
        select coalesce(jsonb_agg(jsonb_build_object('name', name, 'units', units, 'value', value)
               order by units desc, value desc), '[]'::jsonb)
        from (
          select oi.product_name as name, sum(oi.quantity) as units,
                 sum(oi.quantity * oi.unit_price) as value
          from public.order_items oi
          join win o on o.id = oi.order_id
          where o.status in ('confirmed','shipped','delivered')
          group by oi.product_name
          order by units desc, value desc
          limit 5
        ) t
      ),
      'lowStock', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', id, 'product', product, 'label', label, 'stock', stock)
               order by stock, product), '[]'::jsonb)
        from (
          select pv.id, p.name as product,
                 nullif(concat_ws(' / ', nullif(pv.size, ''), nullif(pv.color_name, '')), '') as label,
                 pv.stock
          from public.product_variants pv
          join public.products p on p.id = pv.product_id
          where pv.is_active and p.status = 'published' and pv.stock <= 3
          order by pv.stock, p.name
          limit 10
        ) l
      )
    )
  );
end;
$$;

revoke all on function public.admin_analytics(int) from public, anon;
grant execute on function public.admin_analytics(int) to authenticated;

revoke all on function public.delivery_fee_for(text, int, text) from public, anon, authenticated;
revoke all on function public.recalculate_for_order(uuid)     from public, anon, authenticated;
revoke all on function public.recalculate_order_totals()      from public, anon, authenticated;

-- ── Admin bootstrap ────────────────────────────────────────────────────────
-- `admin_users` deliberately has no INSERT policy, or any signed-in user could
-- promote themselves to owner. That left no legitimate route in at all, so this
-- adds exactly one: the first authenticated user may claim the store, and only
-- while it has no administrator. The advisory lock is what stops two
-- simultaneous claims both reading a count of zero and both inserting.
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
  v_uid uuid := auth.uid();
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

revoke all on function public.admin_exists() from public;
grant execute on function public.admin_exists() to anon, authenticated;

revoke all on function public.claim_store() from public;
grant execute on function public.claim_store() to authenticated;

-- =============================================================================
-- 11. Order export to Google Sheets, and to anything else taking a webhook
-- =============================================================================
--
-- An owner can point orders at one or many endpoints, typically a Google Apps
-- Script web app bound to their own Sheet. Off by default: a shop with no targets
-- behaves exactly as it did before.
--
--  * pg_net, not an Edge Function. Its requests are queued and sent after the
--    transaction commits, so a slow or dead endpoint can never delay or fail a
--    checkout. A function in the middle would add a hop and a second thing to
--    misconfigure for no benefit.
--  * The URL and the signing secret live here, in a table only the owner can
--    read, and the request is made by the database. No browser ever holds them,
--    so there is nothing for the storefront bundle to leak.
--  * Every payload is HMAC-SHA256 signed over the raw body, so the receiving
--    script can prove the request came from this shop. Without that the URL alone
--    is a bearer token, and an Apps Script endpoint has to be public.
--
-- pgcrypto lives in the `extensions` schema, so its functions are named in full
-- rather than relying on search_path.

create extension if not exists pg_net;

create table if not exists public.order_export_targets (
  id uuid primary key default gen_random_uuid(),
  label text not null check (length(trim(label)) between 1 and 80),
  -- https only. A plaintext webhook would put names, phone numbers and addresses
  -- on the wire in the clear.
  url text not null check (url ~ '^https://.'),
  secret text not null default encode(extensions.gen_random_bytes(32), 'hex'),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.order_export_targets is
  'Outbound order webhooks, typically a Google Apps Script bound to a Sheet. Owner-only, because the secret signs payloads and must be pasted into the receiving script.';

create table if not exists public.order_export_log (
  id bigserial primary key,
  target_id uuid not null references public.order_export_targets(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  event text not null check (event in ('created', 'status_changed')),
  status text not null,
  request_id bigint,
  created_at timestamptz not null default now()
);

comment on table public.order_export_log is
  'One row per attempted export. request_id correlates to net._http_response, which pg_net retains for six hours.';

create index if not exists order_export_log_target_idx
  on public.order_export_log (target_id, created_at desc);
create index if not exists order_export_log_order_idx
  on public.order_export_log (order_id);

drop trigger if exists order_export_targets_touch on public.order_export_targets;
create trigger order_export_targets_touch
  before update on public.order_export_targets
  for each row execute function public.touch_updated_at();

/*
 * A flat, self-describing payload rather than the raw row.
 *
 * The person writing the receiving script is a shop owner looking at a
 * spreadsheet, not at this schema, so every field is named in full and the line
 * total is precomputed.
 *
 * SECURITY DEFINER because it reads customer personal data and must never be
 * callable from a client. Execute is revoked from every API role below.
 */
create or replace function public.order_export_payload(p_order_id uuid, p_event text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'event', p_event,
    'sent_at', now(),
    'shop', (
      select jsonb_build_object('name', s.name, 'phone', s.phone, 'whatsapp', s.whatsapp)
      from public.store_settings s where s.id = 1
    ),
    'order', jsonb_build_object(
      'id', o.id,
      'token', o.public_token,
      'customer_name', o.customer_name,
      'phone', o.phone,
      'wilaya', o.wilaya,
      'commune', o.commune,
      'address', o.address,
      'note', o.note,
      'subtotal', o.subtotal,
      'delivery_fee', o.delivery_fee,
      'total', o.total,
      'status', o.status,
      'created_at', o.created_at,
      'confirmed_at', o.confirmed_at,
      'refused_at', o.refused_at,
      'refused_reason', o.refused_reason,
      'shipped_at', o.shipped_at,
      'delivered_at', o.delivered_at,
      'carrier', o.carrier,
      'tracking_number', o.tracking_number,
      'tracking_url', o.tracking_url
    ),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_name', i.product_name,
            'variant_label', i.variant_label,
            'quantity', i.quantity,
            'unit_price', i.unit_price,
            'line_total', i.unit_price * i.quantity
          )
          order by i.created_at
        )
        from public.order_items i where i.order_id = o.id
      ),
      '[]'::jsonb
    )
  )
  from public.orders o
  where o.id = p_order_id;
$$;

/*
 * Queue an export for every enabled target.
 *
 * Fires on creation and on any status change, because a sheet that only ever
 * shows new orders is a sheet the owner still reconciles by hand. The receiving
 * script upserts on order.id.
 *
 * The signature travels in two places, and that is not redundancy. A Google Apps
 * Script web app cannot read request headers at all: the event object passed to
 * doPost() has no `headers` field and never has had one (Google issue 67764685,
 * open since 2017). Apps Script is the main reason this feature exists, so a
 * header-only signature would be unverifiable for the one integration it was
 * built for. The query parameter is for Apps Script; the header is the usual
 * convention for anything else that can read it. Both carry the same digest over
 * the same body, which was verified byte-for-byte against a real endpoint.
 *
 * Wrapped so a misconfigured endpoint cannot fail a checkout. An export is a side
 * effect, and losing an order to a broken webhook would be an absurd trade.
 * Failures land in the log instead.
 */
create or replace function public.enqueue_order_export()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
  payload jsonb;
  event_name text;
  digest text;
  request_id bigint;
begin
  if tg_op = 'INSERT' then
    event_name := 'created';
  elsif new.status is distinct from old.status then
    event_name := 'status_changed';
  else
    return new;
  end if;

  payload := public.order_export_payload(new.id, event_name);
  if payload is null then
    return new;
  end if;

  for target in select id, url, secret from public.order_export_targets where enabled loop
    begin
      digest := encode(extensions.hmac(payload::text, target.secret, 'sha256'), 'hex');

      select net.http_post(
        url := target.url,
        body := payload,
        -- Raw hex, no prefix, because the receiving script compares hex to hex.
        params := jsonb_build_object('sig', digest),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'X-OpenStore-Event', event_name,
          -- Hex only, deliberately: pg_net refuses to send a request whose
          -- headers contain a carriage return or line feed, and hex cannot.
          'X-OpenStore-Signature', 'sha256=' || digest
        ),
        timeout_milliseconds := 10000
      ) into request_id;

      insert into public.order_export_log (target_id, order_id, event, status, request_id)
      values (target.id, new.id, event_name, 'queued', request_id);
    exception when others then
      insert into public.order_export_log (target_id, order_id, event, status)
      values (target.id, new.id, event_name, 'error: ' || sqlerrm);
    end;
  end loop;

  return new;
end;
$$;

drop trigger if exists order_export_enqueue on public.orders;
create trigger order_export_enqueue
  after insert or update of status on public.orders
  for each row execute function public.enqueue_order_export();

alter table public.order_export_targets enable row level security;
alter table public.order_export_log enable row level security;

grant select, insert, update, delete on public.order_export_targets to authenticated;
grant select on public.order_export_log to authenticated;
grant usage, select on sequence public.order_export_log_id_seq to authenticated;

-- Owner only, not owner-and-staff as elsewhere: this table holds a signing
-- secret, and a leaked one lets someone forge orders into the shop's spreadsheet.
drop policy if exists order_export_targets_admin on public.order_export_targets;
create policy order_export_targets_admin on public.order_export_targets
  for all to authenticated
  using (
    (select public.has_admin_role((select auth.uid()), array['owner'::public.admin_role])) is true
  )
  with check (
    (select public.has_admin_role((select auth.uid()), array['owner'::public.admin_role])) is true
  );

drop policy if exists order_export_log_admin on public.order_export_log;
create policy order_export_log_admin on public.order_export_log
  for select to authenticated
  using (
    (select public.has_admin_role((select auth.uid()), array['owner'::public.admin_role])) is true
  );

-- Supabase grants broad default privileges on new tables in `public` to anon,
-- authenticated and service_role. That is what makes the usual grant-plus-policy
-- pairing work, and it also means `anon` starts out holding SELECT and TRUNCATE
-- on these two. RLS returns no rows to anon here, because the only policies target
-- `authenticated`, but a signing secret should not be one dropped policy away from
-- being readable. TRUNCATE ignores RLS entirely, so leaving it granted would be a
-- loaded gun for no benefit. Same treatment `public.orders` already gets.
revoke all on public.order_export_targets from anon;
revoke all on public.order_export_log from anon;
revoke truncate, references, trigger on public.order_export_targets from authenticated, service_role;
revoke truncate, references, trigger on public.order_export_log from authenticated, service_role;
revoke all on sequence public.order_export_log_id_seq from anon;

-- These two expose customer personal data and are only ever called by the trigger,
-- which runs as the definer.
revoke all on function public.order_export_payload(uuid, text) from public, anon, authenticated;
revoke all on function public.enqueue_order_export() from public, anon, authenticated;

-- =============================================================================
-- 12. Storefront read helpers
-- =============================================================================
--
-- Both exist for the same reason: the storefront was doing work in the browser
-- that the database does in one row instead.

/*
 * Published product count per category.
 *
 * The home page used to select every published product's `category_id` and count
 * them in JavaScript, so producing eight numbers cost a full catalogue read on
 * every load. This returns eight rows.
 */
create or replace function public.category_product_counts()
returns table (category_id uuid, product_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select p.category_id, count(*)::bigint as product_count
  from public.products p
  where p.status = 'published'
    and p.category_id is not null
  group by p.category_id;
$$;

comment on function public.category_product_counts() is
  'Published product count per category, so the storefront counts in SQL instead of fetching every product.';

revoke all on function public.category_product_counts() from public;
grant execute on function public.category_product_counts() to anon, authenticated;

-- Supports the group-by above, and the catalogue's category filter.
create index if not exists products_status_category_idx
  on public.products (status, category_id);

-- -----------------------------------------------------------------------------
-- The storefront catalogue, filtered, sorted, searched and paged in SQL
-- -----------------------------------------------------------------------------
--
-- The storefront used to filter, sort, search and compute its facets in the
-- browser over the whole catalogue. That stops working the moment the list is
-- paged, and it fails in the worst way: filtering a paged list client-side only
-- ever sees the loaded page, so a result count becomes a wrong answer rather than
-- a slow one. This moves all of it to the database, so the count is always the
-- count of the whole matching set.

/*
 * Arabic normalisation. The rules are the ones a phone keyboard makes necessary:
 * diacritics and tatweel are stripped because nobody types them, hamza forms
 * collapse to bare alef, the two ya forms to one, and taa marbuta to ha, because
 * all of those are written interchangeably in practice.
 */
create or replace function public.normalize_arabic(input text)
returns text
language sql
immutable
as $$
  select trim(
    regexp_replace(
      regexp_replace(
        translate(lower(coalesce(input, '')), 'أإآٱىةؤئ', 'ااااييهءء'),
        '[ً-ْٰـ]', '', 'g'
      ),
      '\s+', ' ', 'g'
    )
  );
$$;

comment on function public.normalize_arabic(text) is
  'Normalises Arabic for search. The rules are the ones a phone keyboard makes necessary.';

/*
 * One page of the published catalogue, plus the total and the facets.
 *
 * Returns JSON in the shape the storefront already expects, so this was a change
 * of transport rather than of shape. Every word of the query must match, which is
 * what makes a second word narrow the results instead of widening them.
 *
 * Sort is a text switch rather than four queries, so a caller cannot ask for a
 * sort this does not know and silently get the default.
 */
create or replace function public.catalogue_page(
  p_category_slug text default null,
  p_query text default null,
  p_sizes text[] default null,
  p_colors text[] default null,
  p_min_price int default null,
  p_max_price int default null,
  p_in_stock boolean default false,
  p_sort text default 'newest',
  p_limit int default 12,
  p_offset int default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with matched as (
  select
    p.id,
    p.name,
    p.published_at,
    (select min(v.price) from public.product_variants v
      where v.product_id = p.id and v.is_active) as min_price,
    (select max(v.price) from public.product_variants v
      where v.product_id = p.id and v.is_active) as max_price
  from public.products p
  left join public.categories c on c.id = p.category_id
  where p.status = 'published'
    and (p_category_slug is null or c.slug = p_category_slug)
    and (
      coalesce(trim(p_query), '') = ''
      or not exists (
        select 1
        from unnest(string_to_array(public.normalize_arabic(p_query), ' ')) as word
        where word <> ''
          and public.normalize_arabic(
            p.name || ' ' || coalesce(p.name_fr, '') || ' ' || coalesce(p.description, '')
            || ' ' || p.slug || ' ' || coalesce((
              select string_agg(
                coalesce(v.sku, '') || ' ' || coalesce(v.size, '') || ' ' || coalesce(v.color_name, ''),
                ' '
              )
              from public.product_variants v where v.product_id = p.id
            ), '')
          ) not like '%' || word || '%'
      )
    )
    and (
      coalesce(array_length(p_sizes, 1), 0) = 0
      or exists (select 1 from public.product_variants v
        where v.product_id = p.id and v.is_active and v.size = any(p_sizes))
    )
    and (
      coalesce(array_length(p_colors, 1), 0) = 0
      or exists (select 1 from public.product_variants v
        where v.product_id = p.id and v.is_active and v.color_name = any(p_colors))
    )
    and (
      not coalesce(p_in_stock, false)
      or exists (select 1 from public.product_variants v
        where v.product_id = p.id and v.is_active and v.stock > 0)
    )
    and (
      p_min_price is null
      or exists (select 1 from public.product_variants v
        where v.product_id = p.id and v.is_active and v.price >= p_min_price)
    )
    and (
      p_max_price is null
      or exists (select 1 from public.product_variants v
        where v.product_id = p.id and v.is_active and v.price <= p_max_price)
    )
),
ranked as (
  select
    m.id,
    row_number() over (
      order by
        case when p_sort = 'price-asc' then m.min_price end asc nulls last,
        case when p_sort = 'price-desc' then m.max_price end desc nulls last,
        case when p_sort = 'name' then m.name end asc,
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
  'total', (select count(*) from matched),
  'products', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'slug', p.slug,
        'name', p.name,
        'name_fr', p.name_fr,
        'description', p.description,
        'description_fr', p.description_fr,
        'kind', p.kind,
        'status', p.status,
        'category_id', p.category_id,
        'published_at', p.published_at,
        -- Card ratings, aggregated here so a grid of twelve does not send twelve
        -- review requests of its own.
        'rating_avg', (select round(avg(r.rating)::numeric, 2) from public.reviews r
                        where r.product_id = p.id and r.is_approved),
        'rating_count', (select count(*) from public.reviews r
                          where r.product_id = p.id and r.is_approved),
        'categories', case when c.id is null then null else jsonb_build_object(
          'slug', c.slug, 'name', c.name, 'name_fr', c.name_fr
        ) end,
        -- Only what a card draws: price, sale, stock, order, and one photo. A
        -- product page fetches everything else itself. Sending every variant's
        -- every photo made the home page 510 KB of HTML for twelve cards.
        'product_variants', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', v.id,
              'size', v.size,
              'color_name', v.color_name,
              'color_hex', v.color_hex,
              'price', v.price,
              'compare_at_price', v.compare_at_price,
              'stock', v.stock,
              'is_active', v.is_active,
              'sort_order', v.sort_order,
              'variant_images', case
                when v.id = (
                  select v2.id from public.product_variants v2
                  where v2.product_id = p.id and v2.is_active
                    and exists (select 1 from public.variant_images i2 where i2.variant_id = v2.id)
                  order by v2.sort_order, v2.price
                  limit 1
                ) then coalesce((
                  select jsonb_agg(jsonb_build_object('id', i.id, 'url', i.url, 'alt', i.alt, 'sort_order', i.sort_order))
                  from (select * from public.variant_images
                        where variant_id = v.id order by sort_order limit 1) i
                ), '[]'::jsonb)
                else '[]'::jsonb
              end
            )
            order by v.sort_order
          )
          from public.product_variants v
          where v.product_id = p.id and v.is_active
        ), '[]'::jsonb)
      )
      order by page.ord
    )
    from page
    join public.products p on p.id = page.id
    left join public.categories c on c.id = p.category_id
  ), '[]'::jsonb),
  -- Facets come from the whole published catalogue, not the filtered page, so the
  -- filter panel does not empty itself out as the buyer narrows.
  'facets', jsonb_build_object(
    'sizes', coalesce((
      select jsonb_agg(distinct v.size order by v.size)
      from public.product_variants v
      join public.products p on p.id = v.product_id
      where p.status = 'published' and v.is_active and coalesce(v.size, '') <> ''
    ), '[]'::jsonb),
    'colors', coalesce((
      select jsonb_agg(distinct v.color_name order by v.color_name)
      from public.product_variants v
      join public.products p on p.id = v.product_id
      where p.status = 'published' and v.is_active and coalesce(v.color_name, '') <> ''
    ), '[]'::jsonb),
    'priceMin', coalesce((
      select min(v.price) from public.product_variants v
      join public.products p on p.id = v.product_id
      where p.status = 'published' and v.is_active
    ), 0),
    'priceMax', coalesce((
      select max(v.price) from public.product_variants v
      join public.products p on p.id = v.product_id
      where p.status = 'published' and v.is_active
    ), 0)
  )
);
$$;

comment on function public.catalogue_page(text, text, text[], text[], int, int, boolean, text, int, int) is
  'One page of the published catalogue with filtering, sorting, search, facets and total. Exists so the storefront can page without filtering only the loaded page.';

revoke all on function public.catalogue_page(text, text, text[], text[], int, int, boolean, text, int, int) from public;
grant execute on function public.catalogue_page(text, text, text[], text[], int, int, boolean, text, int, int) to anon, authenticated;
grant execute on function public.normalize_arabic(text) to anon, authenticated;


-- ── The eleven 2026 wilayas (Law 26-06) ─────────────────────────────────────
-- Algeria went from 58 to 69 wilayas. A shop that priced its delivery before
-- then has no row for Aflou, Barika and the rest, so their buyers would see no
-- price. Each new wilaya starts with the prices of the wilaya it was carved
-- from, and joins a restricted delivery list wherever its parent is on it. Rows
-- the owner already set are left alone; edit them in Admin > Delivery.
insert into public.delivery_zones (wilaya, fee, stopdesk_fee, eta_days, is_active)
select n.wilaya, p.fee, p.stopdesk_fee, p.eta_days, p.is_active
  from (values
    ('Aflou', 'Laghouat'),
    ('Barika', 'Batna'),
    ('El Kantara', 'Biskra'),
    ('Bir El Ater', 'Tebessa'),
    ('El Aricha', 'Tlemcen'),
    ('Ksar Chellala', 'Tiaret'),
    ('Ain Oussara', 'Djelfa'),
    ('Messaad', 'Djelfa'),
    ('Ksar El Boukhari', 'Medea'),
    ('Bou Saada', 'M''Sila'),
    ('El Abiodh Sidi Cheikh', 'El Bayadh')
  ) as n (wilaya, parent)
  join public.delivery_zones p on p.wilaya = n.parent
on conflict (wilaya) do nothing;

update public.store_settings s
   set delivery_wilayas = s.delivery_wilayas || array(
         select n.wilaya from (values
    ('Aflou', 'Laghouat'),
    ('Barika', 'Batna'),
    ('El Kantara', 'Biskra'),
    ('Bir El Ater', 'Tebessa'),
    ('El Aricha', 'Tlemcen'),
    ('Ksar Chellala', 'Tiaret'),
    ('Ain Oussara', 'Djelfa'),
    ('Messaad', 'Djelfa'),
    ('Ksar El Boukhari', 'Medea'),
    ('Bou Saada', 'M''Sila'),
    ('El Abiodh Sidi Cheikh', 'El Bayadh')
         ) as n (wilaya, parent)
          where n.parent = any(s.delivery_wilayas)
            and not (n.wilaya = any(s.delivery_wilayas)))
 where coalesce(array_length(s.delivery_wilayas, 1), 0) > 0;

-- ── Version ────────────────────────────────────────────────────────────────
-- Which schema.sql this database last ran. The dashboard compares it with the
-- code (SCHEMA_VERSION in src/lib/version.ts) and asks the owner to run the
-- update when the code is newer. Bump both together on every schema change.
create or replace function public.openstore_schema_version()
returns int
language sql
immutable
set search_path = ''
as $$
  select 3;
$$;
revoke all on function public.openstore_schema_version() from public;
grant execute on function public.openstore_schema_version() to anon, authenticated;

-- Ask the API to pick up the new tables and functions straight away, so a shop
-- set up from the SQL Editor works on the very next page refresh.
notify pgrst, 'reload schema';
