-- Seed a single BBM backoffice admin into auth.users, auth.identities, and
-- bo_backoffice_users. Compatible with: supabase db reset / db push seeds.

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
DO $$
DECLARE
  v_user_id uuid := 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
  v_user_email text := 'admin@digitalvirgo.com';
  v_instance_id uuid := COALESCE(
    (SELECT id FROM auth.instances LIMIT 1),
    '00000000-0000-0000-0000-000000000000'::uuid
  );
  v_now timestamptz := now();
BEGIN
  SET search_path TO auth, extensions, public;

  IF NOT EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = v_user_id OR email = v_user_email
  ) THEN
    INSERT INTO auth.users (
      id,
      instance_id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      recovery_token
    ) VALUES (
      v_user_id,
      v_instance_id,
      'authenticated',
      'authenticated',
      v_user_email,
      crypt('123456', gen_salt('bf')),
      v_now,
      '{"provider": "email", "providers": ["email"]}'::jsonb,
      jsonb_build_object('email', v_user_email),
      v_now,
      v_now,
      '',
      ''
    );
  END IF;

  INSERT INTO auth.identities (
    id,
    user_id,
    provider_id,
    provider,
    identity_data,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    gen_random_uuid(),
    v_user_id,
    v_user_id::text,
    'email',
    jsonb_build_object(
      'sub', v_user_id::text,
      'email', v_user_email,
      'email_verified', true,
      'phone_verified', false
    ),
    v_now,
    v_now,
    v_now
  ) ON CONFLICT (provider_id, provider) DO NOTHING;

  INSERT INTO backoffice.backoffice_users (
    id,
    user_id,
    email,
    display_name,
    role,
    is_active,
    service_scope,
    product_scope
  ) VALUES (
    gen_random_uuid(),
    v_user_id,
    v_user_email,
    'Admin',
    'admin',
    true,
    '{}',
    '{}'
  ) ON CONFLICT (user_id) DO NOTHING;

END $$;
COMMIT;

-- Auth token columns for SQL-seeded admins (was migration 20260610000005)
-- GoTrue requires string token columns to be '' not NULL on password login
-- See: https://github.com/supabase/auth/issues/1940

BEGIN;
UPDATE auth.users SET
  confirmation_token           = COALESCE(confirmation_token, ''),
  recovery_token               = COALESCE(recovery_token, ''),
  email_change                 = COALESCE(email_change, ''),
  email_change_token_new       = COALESCE(email_change_token_new, ''),
  email_change_token_current   = COALESCE(email_change_token_current, ''),
  reauthentication_token       = COALESCE(reauthentication_token, ''),
  is_sso_user                  = COALESCE(is_sso_user, false),
  updated_at                   = now()
WHERE id = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
COMMIT;
