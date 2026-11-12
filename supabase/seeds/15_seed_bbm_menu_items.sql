/*
  BBM pack seed: service-level menu items + tiers for service slug bbm.
  Sourced from live okvvttojqgpiblrlrywq.
*/
DO $$
DECLARE
  v_service uuid;
BEGIN
  SELECT id INTO v_service FROM backoffice.services WHERE slug = 'bbm';
  IF v_service IS NULL THEN
    RAISE NOTICE 'Skipped seed 15: service bbm not found';
    RETURN;
  END IF;

  INSERT INTO backoffice.product_menu_items (
    id, product_locale_id, environment, item_key, label, url, icon, display_order, parent_key, visible,
    created_at, updated_at, label_i18n_key, route, external_url, auth_required, min_app_version, max_app_version,
    feature_flag, badge_text, badge_color, icon_url, service_id, product_id, enabled, screen_slug, badge_i18n_key
  )
  -- edge: url is the link source (normalize_menu_item_link derives route from it)
  SELECT v.id, NULL, v.environment, v.item_key, v.label, COALESCE(NULLIF(v.url, ''), v.route, ''), v.icon, v.display_order::integer, v.parent_key, v.visible::boolean,
         v.created_at, v.updated_at, v.label_i18n_key, v.route, v.external_url, v.auth_required::boolean, v.min_app_version, v.max_app_version,
         v.feature_flag, v.badge_text, v.badge_color, v.icon_url, v_service, NULL, v.enabled::boolean, v.screen_slug, v.badge_i18n_key
  FROM (VALUES
  ('a81cd796-fd5e-468d-b1b0-2a841f2291e5'::uuid, 'production', 'logo', 'logo', '', 'home', 1, '', true, '2026-11-05T11:06:45.284907+00:00'::timestamptz, '2026-11-05T11:06:45.284907+00:00'::timestamptz, 'menuItems.logoText', '/home', NULL, false, NULL, NULL, NULL, NULL, NULL, 'https://okvvttojqgpiblrlrywq.supabase.co/storage/v1/object/public/product-assets/bbm/_service/staging/menu-icons/logo.png', true, 'home', NULL),
  ('caa4473c-bee2-443b-a0e4-83f29e4231f4'::uuid, 'production', 'voting', 'Voting', '', 'home', 2, '', true, '2026-11-05T11:06:45.49338+00:00'::timestamptz, '2026-11-05T11:06:45.49338+00:00'::timestamptz, 'menuItems.votingText', '/home', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, 'home', NULL),
  ('c5eb1a3a-9303-459d-ad03-6ded7b489353'::uuid, 'production', 'buy_votes', 'Buy Votes', '', 'home', 3, '', true, '2026-11-05T11:06:45.655818+00:00'::timestamptz, '2026-11-05T11:06:45.655818+00:00'::timestamptz, 'menuItems.buyVotesText', '/buy-votes', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, NULL),
  ('f89e3b78-b586-4dc7-abf8-1b7c8f59552d'::uuid, 'production', 'play_win', 'Play and win', '', 'gift', 4, '', true, '2026-11-05T11:06:45.812797+00:00'::timestamptz, '2026-11-05T11:06:45.812797+00:00'::timestamptz, 'menuItems.playWinText', '/bonus-votes', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, 'bonus-votes', NULL),
  ('cc985edf-f6b6-40d1-ad3e-719f0ea96b8c'::uuid, 'staging', 'logo', 'logo', '', 'home', 1, '', true, '2026-11-04T13:47:31.619689+00:00'::timestamptz, '2026-11-04T13:47:31.619689+00:00'::timestamptz, 'menuItems.logoText', '/home', NULL, false, NULL, NULL, NULL, NULL, NULL, 'https://okvvttojqgpiblrlrywq.supabase.co/storage/v1/object/public/product-assets/bbm/_service/staging/menu-icons/logo.png', true, 'home', NULL),
  ('27c2f29f-e9db-428b-a6b9-fba23bb5ca42'::uuid, 'staging', 'voting', 'Voting', '', 'home', 2, '', true, '2026-11-04T13:27:05.301324+00:00'::timestamptz, '2026-11-04T13:27:05.301324+00:00'::timestamptz, 'menuItems.votingText', '/home', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, 'home', NULL),
  ('e8f1a8bd-6285-46c6-bb7d-2db683fec438'::uuid, 'staging', 'buy_votes', 'Buy Votes', '', 'home', 3, '', true, '2026-11-04T13:29:02.469243+00:00'::timestamptz, '2026-11-04T13:29:02.469243+00:00'::timestamptz, 'menuItems.buyVotesText', '/buy-votes', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, NULL),
  ('fed6dfe3-a1b2-4c3a-9911-06ac54bcd64f'::uuid, 'staging', 'play_win', 'Play and win', '', 'gift', 4, '', true, '2026-11-04T11:52:57.350088+00:00'::timestamptz, '2026-11-04T11:52:57.350088+00:00'::timestamptz, 'menuItems.playWinText', '/bonus-votes', NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, true, 'bonus-votes', NULL)
  ) AS v(
    id, environment, item_key, label, url, icon, display_order, parent_key, visible,
    created_at, updated_at, label_i18n_key, route, external_url, auth_required, min_app_version, max_app_version,
    feature_flag, badge_text, badge_color, icon_url, enabled, screen_slug, badge_i18n_key
  )
  ON CONFLICT DO NOTHING;

  INSERT INTO backoffice.product_menu_item_tiers (
    id, menu_item_id, tier, visible, enabled, locked_action, route, external_url, label, label_i18n_key,
    badge_text, badge_color, display_order, created_at, updated_at, screen_slug, badge_i18n_key
  )
  SELECT v.id, v.menu_item_id, v.tier, v.visible::boolean, v.enabled::boolean, v.locked_action, v.route, v.external_url, v.label, v.label_i18n_key,
         v.badge_text, v.badge_color, v.display_order::integer, v.created_at, v.updated_at, v.screen_slug, v.badge_i18n_key
  FROM (VALUES
  ('2ef0f669-0034-4f83-b9dd-9aeec21c732c'::uuid, '27c2f29f-e9db-428b-a6b9-fba23bb5ca42'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:27:05.491593+00:00'::timestamptz, '2026-11-04T13:27:05.491593+00:00'::timestamptz, NULL, NULL),
  ('2c3d32c7-02a9-4fc4-9e7f-a602548d3b76'::uuid, '27c2f29f-e9db-428b-a6b9-fba23bb5ca42'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:27:05.491593+00:00'::timestamptz, '2026-11-04T13:27:05.491593+00:00'::timestamptz, NULL, NULL),
  ('c5e2a5a1-eb8c-4b84-882e-ffd0b8b0adae'::uuid, '27c2f29f-e9db-428b-a6b9-fba23bb5ca42'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:27:05.491593+00:00'::timestamptz, '2026-11-04T13:27:05.491593+00:00'::timestamptz, NULL, NULL),
  ('53c16e9d-fdcc-4e04-a0c9-4a0f76168a40'::uuid, 'a81cd796-fd5e-468d-b1b0-2a841f2291e5'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.402367+00:00'::timestamptz, '2026-11-05T11:06:45.402367+00:00'::timestamptz, NULL, NULL),
  ('db9d20c0-5901-4602-a80e-078f83c3b92c'::uuid, 'a81cd796-fd5e-468d-b1b0-2a841f2291e5'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.402367+00:00'::timestamptz, '2026-11-05T11:06:45.402367+00:00'::timestamptz, NULL, NULL),
  ('34efbeb3-43a7-409d-bbfc-07dca45630cc'::uuid, 'a81cd796-fd5e-468d-b1b0-2a841f2291e5'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.402367+00:00'::timestamptz, '2026-11-05T11:06:45.402367+00:00'::timestamptz, NULL, NULL),
  ('44b7b96d-35c5-4c38-ad07-f1f09c299d29'::uuid, 'c5eb1a3a-9303-459d-ad03-6ded7b489353'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.735892+00:00'::timestamptz, '2026-11-05T11:06:45.735892+00:00'::timestamptz, NULL, NULL),
  ('67be5f1d-f7db-4d63-8060-708dec151a70'::uuid, 'c5eb1a3a-9303-459d-ad03-6ded7b489353'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.735892+00:00'::timestamptz, '2026-11-05T11:06:45.735892+00:00'::timestamptz, NULL, NULL),
  ('c03df3d8-f31a-4805-894e-292966e24425'::uuid, 'c5eb1a3a-9303-459d-ad03-6ded7b489353'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.735892+00:00'::timestamptz, '2026-11-05T11:06:45.735892+00:00'::timestamptz, NULL, NULL),
  ('496d80fd-8ec6-412d-866d-07c8a3d0050f'::uuid, 'caa4473c-bee2-443b-a0e4-83f29e4231f4'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.569811+00:00'::timestamptz, '2026-11-05T11:06:45.569811+00:00'::timestamptz, NULL, NULL),
  ('6723ded7-1a0a-4020-8e02-9aa37c5d4aaf'::uuid, 'caa4473c-bee2-443b-a0e4-83f29e4231f4'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.569811+00:00'::timestamptz, '2026-11-05T11:06:45.569811+00:00'::timestamptz, NULL, NULL),
  ('b4a91138-0698-4a95-ab8d-bcab454a5388'::uuid, 'caa4473c-bee2-443b-a0e4-83f29e4231f4'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.569811+00:00'::timestamptz, '2026-11-05T11:06:45.569811+00:00'::timestamptz, NULL, NULL),
  ('263c9085-9367-4180-82fe-32869b6144cf'::uuid, 'cc985edf-f6b6-40d1-ad3e-719f0ea96b8c'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:47:31.790238+00:00'::timestamptz, '2026-11-04T13:47:31.790238+00:00'::timestamptz, NULL, NULL),
  ('f1fba870-7942-4e6a-86a9-5965bcd3c1ca'::uuid, 'cc985edf-f6b6-40d1-ad3e-719f0ea96b8c'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:47:31.790238+00:00'::timestamptz, '2026-11-04T13:47:31.790238+00:00'::timestamptz, NULL, NULL),
  ('dce893af-3c8d-4e9d-9fb6-31e22ded6932'::uuid, 'cc985edf-f6b6-40d1-ad3e-719f0ea96b8c'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:47:31.790238+00:00'::timestamptz, '2026-11-04T13:47:31.790238+00:00'::timestamptz, NULL, NULL),
  ('9d722ecd-1cbd-446b-901a-50705138a5bf'::uuid, 'e8f1a8bd-6285-46c6-bb7d-2db683fec438'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:29:02.575108+00:00'::timestamptz, '2026-11-04T13:29:02.575108+00:00'::timestamptz, NULL, NULL),
  ('e244aef4-368c-4efe-a366-277eb299a323'::uuid, 'e8f1a8bd-6285-46c6-bb7d-2db683fec438'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:29:02.575108+00:00'::timestamptz, '2026-11-04T13:29:02.575108+00:00'::timestamptz, NULL, NULL),
  ('121dcf7f-60be-4ba8-a2dc-e22578d1b3f4'::uuid, 'e8f1a8bd-6285-46c6-bb7d-2db683fec438'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T13:29:02.575108+00:00'::timestamptz, '2026-11-04T13:29:02.575108+00:00'::timestamptz, NULL, NULL),
  ('12c8ed10-6f50-42f2-805a-299708b85259'::uuid, 'f89e3b78-b586-4dc7-abf8-1b7c8f59552d'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.891453+00:00'::timestamptz, '2026-11-05T11:06:45.891453+00:00'::timestamptz, NULL, NULL),
  ('60207a37-ef1b-449a-ba16-740c4faddbd0'::uuid, 'f89e3b78-b586-4dc7-abf8-1b7c8f59552d'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.891453+00:00'::timestamptz, '2026-11-05T11:06:45.891453+00:00'::timestamptz, NULL, NULL),
  ('1225aaac-c5a2-4591-9cb1-930b7db1fa76'::uuid, 'f89e3b78-b586-4dc7-abf8-1b7c8f59552d'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-05T11:06:45.891453+00:00'::timestamptz, '2026-11-05T11:06:45.891453+00:00'::timestamptz, NULL, NULL),
  ('ea7376ce-b4f2-4b5f-b327-1baf6a9cfb45'::uuid, 'fed6dfe3-a1b2-4c3a-9911-06ac54bcd64f'::uuid, 'free', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T11:52:57.524399+00:00'::timestamptz, '2026-11-04T11:52:57.524399+00:00'::timestamptz, NULL, NULL),
  ('3549d793-7621-4669-901e-f48f7a1d1f2a'::uuid, 'fed6dfe3-a1b2-4c3a-9911-06ac54bcd64f'::uuid, 'guest', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T11:52:57.524399+00:00'::timestamptz, '2026-11-04T11:52:57.524399+00:00'::timestamptz, NULL, NULL),
  ('1d6950ac-3068-488a-a6ae-b0deb816e9e1'::uuid, 'fed6dfe3-a1b2-4c3a-9911-06ac54bcd64f'::uuid, 'premium', true, true, 'none', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-11-04T11:52:57.524399+00:00'::timestamptz, '2026-11-04T11:52:57.524399+00:00'::timestamptz, NULL, NULL)
  ) AS v(
    id, menu_item_id, tier, visible, enabled, locked_action, route, external_url, label, label_i18n_key,
    badge_text, badge_color, display_order, created_at, updated_at, screen_slug, badge_i18n_key
  )
  WHERE EXISTS (SELECT 1 FROM backoffice.product_menu_items i WHERE i.id = v.menu_item_id)
  ON CONFLICT (menu_item_id, tier) DO NOTHING;
END $$;
