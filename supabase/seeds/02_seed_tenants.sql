/*
  =============================================================================
  BOLT PLATFORM - SEED DATA: TENANTS, PRODUCTS, LOCALES & DEFAULTS
  =============================================================================

  Purpose:
    Populates bo_services, bo_products, bo_product_locales, service-level
    feature-flag defaults, service-level public-config defaults, and a
    bootstrap admin row in bo_backoffice_users.

  Idempotency:
    All INSERTs use ON CONFLICT DO NOTHING so this file can be safely re-run.

  Side effects:
    Inserting products fires trg_seed_content_consumption_rules, which
    auto-creates bo_product_content_consumption_rules for each new product.
    Login methods are no longer seeded (channel catalogue is product-owned).

  Post-deploy step:
    The DBA must create a Supabase Auth user for the bootstrap admin,
    then UPDATE the placeholder user_id. See README.md.

  =============================================================================
*/


-- ===========================================================================
-- 1. SERVICES (top-level tenants / brands)
-- ===========================================================================

INSERT INTO backoffice.services (id, slug, display_name, description, status, created_at, updated_at)
VALUES
  (
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51',
    'winfinity',
    'Winfinity',
    'Gamified loyalty platform',
    'active',
    '2026-05-05T06:28:04.373183+00:00',
    '2026-05-05T06:28:04.373183+00:00'
  ),
  (
    '1927f41e-a809-49c9-9661-5a54a6177069',
    'bravigo',
    'Bravigo',
    'Gamified loyalty platform',
    'active',
    '2026-05-15T08:08:26.803286+00:00',
    '2026-05-15T08:08:26.803286+00:00'
  )
ON CONFLICT (id) DO NOTHING;
-- ===========================================================================
-- 2. PRODUCTS (per-country deployments within services)
-- ===========================================================================

INSERT INTO backoffice.products (id, service_id, slug, display_name, country_code, is_global, native_bundle_id, status, created_at, updated_at, hostname_staging, hostname_production, is_default)
VALUES
  -- Winfinity: Senegal (default)
  (
    '0b707835-d7d4-42d6-8a4b-3b8759ef52a0',
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51',
    'sn-winfinity',
    'Winfinity by OSN',
    'SN',
    false,
    NULL,
    'active',
    '2026-05-19T13:30:45.988591+00:00',
    '2026-05-19T13:30:45.988591+00:00',
    'winfinity.blast.dvbuilder.com',
    'www.osn-winfinity.com',
    true
  ),
  -- Winfinity: Botswana
  (
    'dcf2903f-1993-42e7-9619-9db4b28dd5f3',
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51',
    'bw-winfinity',
    'Winfinity Botswana',
    'BW',
    false,
    NULL,
    'active',
    '2026-06-09T08:29:27.841055+00:00',
    '2026-06-09T08:29:27.841055+00:00',
    NULL,
    'obw-winfinity.com',
    false
  ),
  -- Winfinity: Cote d'Ivoire
  (
    '4a51d659-4a91-424c-beee-9761448e20d0',
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51',
    'ci-winfinity',
    'Winfinity Cote d''Ivoire (West Africa)',
    'CI',
    false,
    NULL,
    'active',
    '2026-06-09T08:42:58.875141+00:00',
    '2026-06-09T08:42:58.875141+00:00',
    NULL,
    'oci-winfinity.com',
    false
  ),
  -- Winfinity: Congo (RDC)
  (
    '73d2909d-d746-4cc1-9a3e-5d4556385b68',
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51',
    'cd-winfinity',
    'Winfiniy CD (RDC)',
    'CD',
    false,
    NULL,
    'active',
    '2026-06-08T09:59:06.102182+00:00',
    '2026-06-08T09:59:06.102182+00:00',
    NULL,
    'www.ordc-winfinty.com',
    false
  ),
  -- Bravigo: Morocco (default)
  (
    '8a236df7-f1da-49d9-a255-d851b180b162',
    '1927f41e-a809-49c9-9661-5a54a6177069',
    'ma-bravigo',
    'Bravigo MA',
    'MA',
    false,
    NULL,
    'active',
    '2026-05-19T13:18:31.264672+00:00',
    '2026-05-19T13:18:31.264672+00:00',
    'bravigo.blast.dvbuilder.com',
    'ma.bravigo.com',
    true
  )
ON CONFLICT (id) DO NOTHING;
-- ===========================================================================
-- 3. PRODUCT LOCALES (language configurations per product)
-- ===========================================================================

INSERT INTO backoffice.product_locales (id, product_id, language_code, display_name, is_default, status)
VALUES
  -- Winfinity SN: French (default)
  ('dc4719b6-8b06-4fb9-91de-c833507585a0', '0b707835-d7d4-42d6-8a4b-3b8759ef52a0', 'fr', 'francais', true, 'active'),
  -- Winfinity BW: French (default) + English
  ('bae65fd9-d170-49f6-96fd-55cc547d2c88', 'dcf2903f-1993-42e7-9619-9db4b28dd5f3', 'fr', 'francais', true, 'active'),
  ('79db63ec-2b1b-4fe0-8942-4624f1aa5f8b', 'dcf2903f-1993-42e7-9619-9db4b28dd5f3', 'en', 'English', false, 'active'),
  -- Winfinity CI: French (default)
  ('587b7f53-276c-44b6-95a3-13b8380619ff', '4a51d659-4a91-424c-beee-9761448e20d0', 'fr', 'francais', true, 'active'),
  -- Winfinity CD: French (default)
  ('045a1d00-8b53-4216-9898-73a22f6cbb33', '73d2909d-d746-4cc1-9a3e-5d4556385b68', 'fr', 'francais', true, 'active'),
  -- Bravigo MA: French (default) + Arabic
  ('90237437-7a3f-4509-8741-2ab816fc0325', '8a236df7-f1da-49d9-a255-d851b180b162', 'fr', 'francais', true, 'active'),
  ('a4144d36-963e-4093-a58b-41b57f9befa7', '8a236df7-f1da-49d9-a255-d851b180b162', 'ar', 'arabic', false, 'active')
ON CONFLICT (product_id, language_code) DO NOTHING;
-- ===========================================================================
-- 4. SERVICE FEATURE-FLAG DEFAULTS (all disabled by default)
-- ===========================================================================
-- 14 flags x 2 environments x 2 services = 56 rows

INSERT INTO backoffice.service_feature_flags_defaults (service_id, environment, flag_key, enabled)
VALUES
  -- Winfinity: staging
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.avatar_camera', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.hall_of_fame', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.memory_match', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.notifications', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.penalty_rivals', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.puzzle', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.quiz_of_the_day', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.scratch_card', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.spin_wheel', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'module.welcome_scratch_modal', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'tab.discovery', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'tab.events', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'tab.profile', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'tab.rewards', false),
  -- Winfinity: production
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.avatar_camera', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.hall_of_fame', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.memory_match', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.notifications', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.penalty_rivals', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.puzzle', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.quiz_of_the_day', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.scratch_card', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.spin_wheel', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'module.welcome_scratch_modal', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'tab.discovery', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'tab.events', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'tab.profile', false),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'tab.rewards', false),
  -- Bravigo: staging
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.avatar_camera', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.hall_of_fame', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.memory_match', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.notifications', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.penalty_rivals', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.puzzle', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.quiz_of_the_day', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.scratch_card', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.spin_wheel', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'module.welcome_scratch_modal', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'tab.discovery', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'tab.events', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'tab.profile', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'tab.rewards', false),
  -- Bravigo: production
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.avatar_camera', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.hall_of_fame', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.memory_match', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.notifications', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.penalty_rivals', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.puzzle', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.quiz_of_the_day', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.scratch_card', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.spin_wheel', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'module.welcome_scratch_modal', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'tab.discovery', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'tab.events', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'tab.profile', false),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'tab.rewards', false)
ON CONFLICT (service_id, environment, flag_key) DO NOTHING;
-- ===========================================================================
-- 5. SERVICE PUBLIC-CONFIG DEFAULTS
-- ===========================================================================
-- 16 keys x 2 environments x 2 services = 64 rows (all empty except one)

INSERT INTO backoffice.product_public_config (service_id, environment, key, value)
VALUES
  -- Winfinity: staging
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'ANIMATION_GRAPHQL_ENDPOINT', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'ANIMATION_PRODUCT_NAME', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'ANIMATION_PRODUCT_PAGE', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'COMPETITION_BASE_DOMAIN', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'DV_LOYALTY_API_BASE_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'landing_page_subsciption_url', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'landing_page_upgrade_url', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'LOG_ENABLED', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'LOG_LEVEL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'QUIZ_OF_THE_DAY_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'RELEVANCE_BASE_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'RELEVANCE_PROJECT_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'SMART_USER_APP_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'SMART_USER_ENV', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'SMART_USER_PROXY_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'staging', 'user_wrong_state_fallbackUrl', '/auth/login'),
  -- Winfinity: production
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'ANIMATION_GRAPHQL_ENDPOINT', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'ANIMATION_PRODUCT_NAME', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'ANIMATION_PRODUCT_PAGE', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'COMPETITION_BASE_DOMAIN', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'DV_LOYALTY_API_BASE_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'landing_page_subsciption_url', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'landing_page_upgrade_url', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'LOG_ENABLED', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'LOG_LEVEL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'QUIZ_OF_THE_DAY_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'RELEVANCE_BASE_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'RELEVANCE_PROJECT_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'SMART_USER_APP_ID', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'SMART_USER_ENV', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'SMART_USER_PROXY_URL', ''),
  ('365a2e0b-49d6-46f9-bf2e-c1937decfe51', 'production', 'user_wrong_state_fallbackUrl', '/auth/login'),
  -- Bravigo: staging
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'ANIMATION_GRAPHQL_ENDPOINT', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'ANIMATION_PRODUCT_NAME', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'ANIMATION_PRODUCT_PAGE', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'COMPETITION_BASE_DOMAIN', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'DV_LOYALTY_API_BASE_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'landing_page_subsciption_url', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'landing_page_upgrade_url', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'LOG_ENABLED', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'LOG_LEVEL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'QUIZ_OF_THE_DAY_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'RELEVANCE_BASE_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'RELEVANCE_PROJECT_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'SMART_USER_APP_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'SMART_USER_ENV', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'SMART_USER_PROXY_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'staging', 'user_wrong_state_fallbackUrl', '/auth/login'),
  -- Bravigo: production
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'ANIMATION_GRAPHQL_ENDPOINT', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'ANIMATION_PRODUCT_NAME', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'ANIMATION_PRODUCT_PAGE', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'COMPETITION_BASE_DOMAIN', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'DV_LOYALTY_API_BASE_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'landing_page_subsciption_url', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'landing_page_upgrade_url', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'LOG_ENABLED', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'LOG_LEVEL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'QUIZ_OF_THE_DAY_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'RELEVANCE_BASE_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'RELEVANCE_PROJECT_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'SMART_USER_APP_ID', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'SMART_USER_ENV', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'SMART_USER_PROXY_URL', ''),
  ('1927f41e-a809-49c9-9661-5a54a6177069', 'production', 'user_wrong_state_fallbackUrl', '/auth/login')
ON CONFLICT (service_id, environment, key) WHERE service_id IS NOT NULL DO NOTHING;
-- ===========================================================================
-- 6. BACKOFFICE ADMINS
-- ===========================================================================
-- Placeholder bootstrap admin removed from the seed path: FK to auth.users
-- requires a real auth row. Admins are created in 05_seed_admin_users.sql
-- (same end-state as the v1 chain after seed_admin_users + token fix).
-- ===========================================================================
-- END OF SEED DATA
-- ===========================================================================;
