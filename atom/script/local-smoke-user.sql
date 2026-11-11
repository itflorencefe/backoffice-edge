-- LOCAL DEVELOPMENT ONLY. Never apply this known-password fixture to a remote project.
-- Not a seed: it lives outside supabase/ so the sync never ships it to the back office repos.
-- Creates the Supabase Auth user used by atom/script/smoke-*.sh and gives it an active
-- `viewer` row in backoffice.bo_backoffice_users (the table read by the `atom` edge function).
-- Idempotent: re-running keeps existing users, passwords and roles.
begin;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  'b0000000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'atom-smoke@example.test',
  extensions.crypt('AtomSmoke-local-only-2026!', extensions.gen_salt('bf')),
  now(), '', '', '', '',
  '{"provider":"email","providers":["email"]}', '{}', now(), now()
) on conflict do nothing;

insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
select id::text, id,
  jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
  'email', now(), now()
from auth.users where id = 'b0000000-0000-4000-8000-000000000001'
on conflict (provider_id, provider) do nothing;

insert into backoffice.bo_backoffice_users (user_id, email, display_name, role, is_active)
select id, email, 'Atom smoke (local)', 'viewer', true from auth.users
where id = 'b0000000-0000-4000-8000-000000000001'
on conflict (user_id) do nothing;

commit;
