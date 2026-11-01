-- Verification queries for supabase/schema.sql (digital products, Latin America,
-- Algeria not served)
-- Every one of these must return the expected result. Run after applying:
--
--     psql "$DATABASE_URL" -f supabase/verify.sql
--
-- Do NOT pass -v ON_ERROR_STOP=1: several checks expect an ERROR, and a rejected
-- statement is the pass condition. It writes test orders for verify*@example.com
-- and removes them again in the last step.

\echo '=== 1. Tables (expect 21) ==='
select count(*) as tables
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'currencies','store_settings','admin_users','categories','products',
    'product_prices','product_images','product_files','product_file_paths',
    'license_keys','tax_rates','blocked_emails','payment_methods','orders',
    'order_items','entitlements','download_log','reviews','payment_proofs',
    'payment_events','outbox'
  );

\echo '=== 2. RLS enabled on every table (expect all true) ==='
select relname, relrowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relkind = 'r'
order by relrowsecurity, relname;

\echo '=== 3. anon must have NO access to private tables (expect 0) ==='
select count(*) as anon_private_grants
from information_schema.role_table_grants
where grantee = 'anon'
  and table_schema = 'public'
  and table_name in (
    'orders','order_items','entitlements','license_keys','product_file_paths',
    'payment_proofs','payment_events','outbox','download_log','admin_users','blocked_emails'
  );

\echo '=== 4. authenticated may update ONLY status and internal_note on orders (expect 2 rows) ==='
select column_name
from information_schema.column_privileges
where grantee = 'authenticated'
  and table_schema = 'public'
  and table_name = 'orders'
  and privilege_type = 'UPDATE'
order by column_name;

\echo '=== 5. Server-only functions are closed to browsers (expect false, false) ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('mark_order_paid','authorize_download','expire_pending_orders',
                    'settle_order','fulfil_order')
order by p.proname;

\echo '=== 6. Seed data present (expect 3 products, 18 prices, 6 currencies, 3 methods, 1 settings) ==='
select
  (select count(*) from public.products)         as products,
  (select count(*) from public.product_prices)   as prices,
  (select count(*) from public.currencies)       as currencies,
  (select count(*) from public.payment_methods)  as methods,
  (select count(*) from public.store_settings)   as settings_rows;

\echo '=== 7. All payment methods start OFF (expect 3 rows, all false) ==='
select code, kind, provider, currencies, countries, hold_hours, is_active
from public.payment_methods order by sort_order;

\echo '=== 8. Latin America served, Algeria not (expect 18, true, false, es) ==='
select cardinality(allowed_countries)       as countries_served,
       'DZ' = any(blocked_countries)        as algeria_blocked,
       'DZ' = any(allowed_countries)        as algeria_allowed,
       default_locale
from public.store_settings where id = 1;

\echo '=== 9. Whole-peso currency (expect CLP 0, MXN 2) ==='
select code, minor_digits from public.currencies where code in ('CLP','MXN') order by code;

\echo '=== 10. Singleton constraint holds (expect ERROR below) ==='
insert into public.store_settings (id, name) values (2, 'second shop');

\echo '=== 11. A buyer in Algeria is refused (expect ERROR country_blocked below) ==='
select public.place_order(
  '{"customer_name":"Verify Algeria","email":"verify1@example.com","country":"DZ","currency":"USD","accepted_terms":true}',
  '[{"product_id":"11111111-1111-4111-8111-111111111111","quantity":1}]'
);

\echo '=== 12. A country outside the list is refused (expect ERROR country_not_served below) ==='
select public.place_order(
  '{"customer_name":"Verify France","email":"verify2@example.com","country":"FR","currency":"USD","accepted_terms":true}',
  '[{"product_id":"11111111-1111-4111-8111-111111111111","quantity":1}]'
);

\echo '=== 13. A method that is switched off is refused (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Three","email":"verify3@example.com","country":"MX","currency":"MXN","phone":"5512345678","payment_method":"transfer","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 14. A free product completes by itself, no payment method needed ==='
select (public.place_order(
  '{"customer_name":"Verify Free","email":"verify4@example.com","country":"MX","currency":"USD","accepted_terms":true}',
  '[{"product_id":"11111111-1111-4111-8111-111111111111","quantity":1}]'
)->>'token') as free_tok \gset

\echo '=== 15. The free order is paid and holds a download right (expect paid, 1 file, 10 left) ==='
select t->>'status' as status,
       jsonb_array_length(t->'items'->0->'files') as files,
       t->'items'->0->'access'->>'downloads_remaining' as downloads_remaining
from (select public.track_order(:'free_tok'::uuid) as t) x;

-- From here on the methods are needed, so switch them on for the test only.
update public.payment_methods set is_active = true;

\echo '=== 16. A paid order with no payment method is refused (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Five","email":"verify5@example.com","country":"MX","currency":"MXN","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 17. Transfer only takes pesos and reais (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Six","email":"verify6@example.com","country":"MX","currency":"USD","phone":"5512345678","payment_method":"transfer","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 18. Transfer only works in Mexico and Brazil (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Seven","email":"verify7@example.com","country":"CO","currency":"MXN","phone":"3001234567","payment_method":"transfer","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 19. PayPal only takes USD (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Eight","email":"verify8@example.com","country":"BR","currency":"BRL","payment_method":"paypal","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 20. A transfer needs a phone number (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Nine","email":"verify9@example.com","country":"MX","currency":"MXN","payment_method":"transfer","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 21. Terms must be accepted (expect ERROR below) ==='
select public.place_order(
  '{"customer_name":"Verify Ten","email":"verify10@example.com","country":"MX","currency":"MXN","phone":"5512345678","payment_method":"transfer"}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
);

\echo '=== 22. A transfer order in pesos: price from the catalogue (expect 49900 MXN, pending, manual) ==='
select (public.place_order(
  '{"customer_name":"Verify Eleven","email":"verify11@example.com","country":"MX","currency":"MXN","phone":"5512345678","payment_method":"transfer","accepted_terms":true,"total":1}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1,"unit_price":1}]'
)->>'token') as tr_tok \gset

select o.subtotal, o.tax_amount, o.total, o.currency, o.status, o.payment_method,
       oi.product_name, oi.unit_price
from public.orders o
join public.order_items oi on oi.order_id = o.id
where o.public_token = :'tr_tok'::uuid;

\echo '=== 23. Before paying, the buyer sees the payee details and no files (expect details + 0 files) ==='
select t->'payment'->>'kind' as kind,
       t->'payment'->'details'->>'account_holder' as account_holder,
       jsonb_array_length(t->'items'->0->'files') as files
from (select public.track_order(:'tr_tok'::uuid) as t) x;

\echo '=== 24. A receipt can be uploaded for this order, and only this one (expect true, false) ==='
select public.can_upload_proof(:'tr_tok' || '/receipt.jpg')                          as own_order,
       public.can_upload_proof(gen_random_uuid()::text || '/receipt.jpg')            as random_folder;

\echo '=== 25. Sending the receipt moves the order to verifying (expect verifying) ==='
select public.submit_payment_proof(
  :'tr_tok'::uuid, 'Verify Eleven', 'TRANSFER-VERIFY-0001', null, 'test receipt'
)->>'status' as status;

\echo '=== 26. The same receipt number cannot back a second order (expect ERROR below) ==='
select (public.place_order(
  '{"customer_name":"Verify Twelve","email":"verify12@example.com","country":"MX","currency":"MXN","phone":"5512345678","payment_method":"transfer","accepted_terms":true}',
  '[{"product_id":"22222222-2222-4222-8222-222222222222","quantity":1}]'
)->>'token') as tr_tok2 \gset

select public.submit_payment_proof(:'tr_tok2'::uuid, 'Verify Twelve', 'transfer-verify-0001') as should_fail;

\echo '=== 27. Nobody can confirm a payment without being an admin (expect ERROR below) ==='
select public.confirm_manual_payment(
  (select id from public.orders where public_token = :'tr_tok'::uuid), 49900
);

\echo '=== 28. A receipt cannot jump to refunded (expect ERROR below) ==='
update public.orders set status = 'refunded' where public_token = :'tr_tok'::uuid;

\echo '=== 29. A card order for a licence product: 4900 USD, pending, online ==='
select (public.place_order(
  '{"customer_name":"Verify Thirteen","email":"verify13@example.com","country":"CO","currency":"USD","payment_method":"card","accepted_terms":true}',
  '[{"product_id":"33333333-3333-4333-8333-333333333333","quantity":1}]'
)->>'token') as card_tok \gset

select o.id as card_order_id, o.total, o.currency, o.status, o.payment_method
from public.orders o where o.public_token = :'card_tok'::uuid \gset

select :'card_order_id' as order_id, :total as total, :'currency' as currency, :'status' as status;

\echo '=== 30. A browser cannot call mark_order_paid (expect permission denied below) ==='
begin;
set local role anon;
select public.mark_order_paid(:'card_order_id'::uuid, 'stripe', 'pi_verify_1', :total, :'currency');
rollback;

\echo '=== 31. A payment for the wrong amount is refused (expect ERROR below) ==='
select public.mark_order_paid(:'card_order_id'::uuid, 'stripe', 'pi_verify_1', 100, 'USD');

\echo '=== 32. The right payment marks the order paid (expect true, then false on retry) ==='
select public.mark_order_paid(:'card_order_id'::uuid, 'stripe', 'pi_verify_1', :total, 'USD') as first_call;
select public.mark_order_paid(:'card_order_id'::uuid, 'stripe', 'pi_verify_1', :total, 'USD') as retry;

\echo '=== 33. The buyer now holds one generated licence key (expect paid, 1 key) ==='
select t->>'status' as status,
       jsonb_array_length(t->'items'->0->'licenses') as keys
from (select public.track_order(:'card_tok'::uuid) as t) x;

\echo '=== 34. A different payment cannot pay it again (expect ERROR below) ==='
select public.mark_order_paid(:'card_order_id'::uuid, 'paypal', 'PAYPAL-OTHER', :total, 'USD');

\echo '=== 35. Only a buyer can review (expect ERROR on the first, nothing on the second) ==='
select public.submit_review(gen_random_uuid(), '33333333-3333-4333-8333-333333333333', 'Nobody', 5, 'Great');
select public.submit_review(:'card_tok'::uuid, '33333333-3333-4333-8333-333333333333', 'Verify Thirteen', 5, 'Works well');

\echo '=== 36. A review waits for approval (expect verified = true, approved = false) ==='
select verified_purchase, is_approved from public.reviews where customer_name = 'Verify Thirteen';

\echo '=== 37. Search works across languages and ignores accents (expect 1 and 1) ==='
-- 'icones' finds the Portuguese text "ícones"; 'licencia' finds the Spanish name.
select jsonb_array_length(public.catalogue_page(null, 'icones', 'USD')->'products')   as accent_insensitive,
       jsonb_array_length(public.catalogue_page(null, 'licencia', 'MXN')->'products') as spanish_word;

\echo '=== 38. Every non-SELECT policy has a WITH CHECK (expect NO rows below) ==='
select tablename, policyname, cmd,
       (qual is not null)       as has_using,
       (with_check is not null) as has_with_check
from pg_policies
where schemaname = 'public'
  and cmd in ('INSERT','UPDATE','ALL')
  and with_check is null
order by tablename, policyname;

\echo '=== 39. Storage buckets (expect product-media public, the other two private, receipts 5 MB) ==='
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id in ('product-media','digital-files','payment-proofs')
order by id;

\echo '=== 40. No public SELECT policy on storage: listing stays closed (expect 0) ==='
select count(*) as public_select_policies
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and cmd = 'SELECT' and roles && array['anon','public']::name[];

\echo '=== 41. Clean up the test data and switch the methods back off ==='
delete from public.orders where email like 'verify%@example.com';
delete from public.license_keys
 where order_item_id is null
   and product_id = '33333333-3333-4333-8333-333333333333';
delete from public.reviews where customer_name = 'Verify Thirteen';
update public.payment_methods set is_active = false;

select (select count(*) from public.orders where email like 'verify%@example.com') as leftover_orders,
       (select count(*) from public.payment_methods where is_active)               as active_methods;
