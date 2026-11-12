/*
  BBM pack seed: URL & Behaviour rules + tiers for product za-bbm.
  Sourced from live okvvttojqgpiblrlrywq.
*/
DO $$
DECLARE
  v_product uuid;
BEGIN
  SELECT p.id INTO v_product
  FROM backoffice.products p
  JOIN backoffice.services s ON s.id = p.service_id
  WHERE s.slug = 'bbm' AND p.slug = 'za-bbm';

  IF v_product IS NULL THEN
    RAISE NOTICE 'Skipped seed 14: product bbm/za-bbm not found';
    RETURN;
  END IF;

  INSERT INTO backoffice.page_behaviour_rules (
    id, product_id, environment, path, label, "position", created_at, updated_at,
    service_id, product_locale_id, enabled, screen_slug
  )
  SELECT v.id, v_product, v.environment, v.path, v.label, v.position::integer, v.created_at, v.updated_at,
         NULL, NULL, v.enabled::boolean, v.screen_slug
  FROM (VALUES
  ('1c6e067e-9ab8-452e-8e74-79a61ca765b4'::uuid, 'production', '/', NULL, 0, '2026-11-05T15:07:32.532756+00:00'::timestamptz, '2026-11-05T15:07:32.532756+00:00'::timestamptz, true, NULL),
  ('1971c214-fd2b-4fa5-bad5-1426b89f60db'::uuid, 'production', '/bonus-votes', 'votami', 1, '2026-11-05T15:07:32.738944+00:00'::timestamptz, '2026-11-05T15:07:32.738944+00:00'::timestamptz, true, 'bonus-votes'),
  ('5c4ce56a-457d-4adf-90a3-1890bb009f0f'::uuid, 'production', '/home', NULL, 2, '2026-11-05T15:07:32.939645+00:00'::timestamptz, '2026-11-05T15:07:32.939645+00:00'::timestamptz, true, 'home'),
  ('20a3e73d-a812-486b-b56a-53f4a1bd3dc6'::uuid, 'staging', '/', NULL, 0, '2026-10-28T14:09:44.168238+00:00'::timestamptz, '2026-11-03T13:58:51.705+00:00'::timestamptz, true, NULL),
  ('267434f3-4231-4b46-9180-e9a3d4059ef2'::uuid, 'staging', '/bonus-votes', 'votami', 1, '2026-10-28T13:50:01.78941+00:00'::timestamptz, '2026-11-02T10:50:50.105+00:00'::timestamptz, true, 'bonus-votes'),
  ('9e5beac2-c626-41b2-879a-e9b6fa08388f'::uuid, 'staging', '/home', NULL, 2, '2026-11-02T10:53:22.965951+00:00'::timestamptz, '2026-11-02T10:53:22.965951+00:00'::timestamptz, true, 'home')
  ) AS v(id, environment, path, label, position, created_at, updated_at, enabled, screen_slug)
  ON CONFLICT (product_id, environment, path) DO NOTHING;

  INSERT INTO backoffice.page_behaviour_tier_rules (
    id, rule_id, tier, action, redirect_url, reason, created_at, updated_at, screen_slug
  )
  SELECT v.id, v.rule_id, v.tier, v.action, v.redirect_url, v.reason, v.created_at, v.updated_at, v.screen_slug
  FROM (VALUES
  ('e2e61b8f-b24a-4c9f-9120-59506697c3b0'::uuid, '1971c214-fd2b-4fa5-bad5-1426b89f60db'::uuid, 'free', 'none', NULL, NULL, '2026-11-05T15:07:32.877231+00:00'::timestamptz, '2026-11-05T15:07:32.877231+00:00'::timestamptz, NULL),
  ('5cb7be23-13e8-4bae-84ec-a9e12a62af17'::uuid, '1971c214-fd2b-4fa5-bad5-1426b89f60db'::uuid, 'guest', 'none', NULL, NULL, '2026-11-05T15:07:32.877231+00:00'::timestamptz, '2026-11-05T15:07:32.877231+00:00'::timestamptz, NULL),
  ('016388ee-fec8-4f99-b61e-c8bfe79659ba'::uuid, '1971c214-fd2b-4fa5-bad5-1426b89f60db'::uuid, 'premium', 'none', NULL, NULL, '2026-11-05T15:07:32.877231+00:00'::timestamptz, '2026-11-05T15:07:32.877231+00:00'::timestamptz, NULL),
  ('b738b109-1d4d-48fb-8f12-4058c56b3f0e'::uuid, '1c6e067e-9ab8-452e-8e74-79a61ca765b4'::uuid, 'free', 'screen', NULL, NULL, '2026-11-05T15:07:32.6801+00:00'::timestamptz, '2026-11-05T15:07:32.6801+00:00'::timestamptz, 'home'),
  ('923364a2-c494-48d6-8da5-94835572430f'::uuid, '1c6e067e-9ab8-452e-8e74-79a61ca765b4'::uuid, 'guest', 'redirect', '/auth', NULL, '2026-11-05T15:07:32.6801+00:00'::timestamptz, '2026-11-05T15:07:32.6801+00:00'::timestamptz, NULL),
  ('ebea78cd-6de6-44ef-b3d8-fd19e38442cd'::uuid, '1c6e067e-9ab8-452e-8e74-79a61ca765b4'::uuid, 'premium', 'screen', NULL, NULL, '2026-11-05T15:07:32.6801+00:00'::timestamptz, '2026-11-05T15:07:32.6801+00:00'::timestamptz, 'home'),
  ('69fe1793-02b4-4d78-80f7-fbd30be50924'::uuid, '20a3e73d-a812-486b-b56a-53f4a1bd3dc6'::uuid, 'free', 'screen', NULL, NULL, '2026-11-03T13:58:52.26177+00:00'::timestamptz, '2026-11-03T13:58:52.26177+00:00'::timestamptz, 'home'),
  ('f909fb0e-8380-47b7-b6f5-5df5674ad364'::uuid, '20a3e73d-a812-486b-b56a-53f4a1bd3dc6'::uuid, 'guest', 'redirect', '/auth', NULL, '2026-11-03T13:58:52.26177+00:00'::timestamptz, '2026-11-03T13:58:52.26177+00:00'::timestamptz, NULL),
  ('3258bb5d-8977-4f4e-8470-9e8ef177efa9'::uuid, '20a3e73d-a812-486b-b56a-53f4a1bd3dc6'::uuid, 'premium', 'screen', NULL, NULL, '2026-11-03T13:58:52.26177+00:00'::timestamptz, '2026-11-03T13:58:52.26177+00:00'::timestamptz, 'home'),
  ('6df04af9-85c9-4c2f-b795-8a7d5de241f9'::uuid, '267434f3-4231-4b46-9180-e9a3d4059ef2'::uuid, 'free', 'none', NULL, NULL, '2026-11-02T10:50:50.566273+00:00'::timestamptz, '2026-11-02T10:50:50.566273+00:00'::timestamptz, NULL),
  ('99d1b8c0-8ba4-4a23-bfa3-43313d815d99'::uuid, '267434f3-4231-4b46-9180-e9a3d4059ef2'::uuid, 'guest', 'none', NULL, NULL, '2026-11-02T10:50:50.566273+00:00'::timestamptz, '2026-11-02T10:50:50.566273+00:00'::timestamptz, NULL),
  ('370d3f42-2932-4594-a10f-22c74ccb77b1'::uuid, '267434f3-4231-4b46-9180-e9a3d4059ef2'::uuid, 'premium', 'none', NULL, NULL, '2026-11-02T10:50:50.566273+00:00'::timestamptz, '2026-11-02T10:50:50.566273+00:00'::timestamptz, NULL),
  ('e91b0135-7a93-4cfc-a98d-d2d4720238d7'::uuid, '5c4ce56a-457d-4adf-90a3-1890bb009f0f'::uuid, 'free', 'none', NULL, NULL, '2026-11-05T15:07:33.080014+00:00'::timestamptz, '2026-11-05T15:07:33.080014+00:00'::timestamptz, NULL),
  ('0a887577-0ce1-4fee-aefc-20479fb6c859'::uuid, '5c4ce56a-457d-4adf-90a3-1890bb009f0f'::uuid, 'guest', 'none', NULL, NULL, '2026-11-05T15:07:33.080014+00:00'::timestamptz, '2026-11-05T15:07:33.080014+00:00'::timestamptz, NULL),
  ('c7e4755a-17e0-4237-8ed1-dbfdc9fcf5ee'::uuid, '5c4ce56a-457d-4adf-90a3-1890bb009f0f'::uuid, 'premium', 'none', NULL, NULL, '2026-11-05T15:07:33.080014+00:00'::timestamptz, '2026-11-05T15:07:33.080014+00:00'::timestamptz, NULL),
  ('3eb97d18-7193-434a-9390-5bbe75143a48'::uuid, '9e5beac2-c626-41b2-879a-e9b6fa08388f'::uuid, 'free', 'none', NULL, NULL, '2026-11-02T10:53:23.201428+00:00'::timestamptz, '2026-11-02T10:53:23.201428+00:00'::timestamptz, NULL),
  ('4ec551c0-63c8-46f2-b22c-07957f990428'::uuid, '9e5beac2-c626-41b2-879a-e9b6fa08388f'::uuid, 'guest', 'none', NULL, NULL, '2026-11-02T10:53:23.201428+00:00'::timestamptz, '2026-11-02T10:53:23.201428+00:00'::timestamptz, NULL),
  ('7583c90c-8690-4bc1-9f16-597560929661'::uuid, '9e5beac2-c626-41b2-879a-e9b6fa08388f'::uuid, 'premium', 'none', NULL, NULL, '2026-11-02T10:53:23.201428+00:00'::timestamptz, '2026-11-02T10:53:23.201428+00:00'::timestamptz, NULL)
  ) AS v(id, rule_id, tier, action, redirect_url, reason, created_at, updated_at, screen_slug)
  WHERE EXISTS (SELECT 1 FROM backoffice.page_behaviour_rules r WHERE r.id = v.rule_id)
  ON CONFLICT (rule_id, tier) DO NOTHING;
END $$;
