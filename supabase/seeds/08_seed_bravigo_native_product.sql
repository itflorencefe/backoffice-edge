-- Bravigo native app product (xx-bravigo). Safe to re-run: UPSERT on (id).

INSERT INTO backoffice.products (
  id, service_id, slug, display_name, country_code, is_global,
  native_bundle_id, status, created_at, updated_at,
  hostname_staging, hostname_production, is_default
)
VALUES (
  '57c22efc-ec1e-4a13-a5fe-c1e1eecb42c7'::uuid,
  '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
  'xx-bravigo',
  'native app',
  'MA',
  false,
  'com.digitalvirgo.bravigo',
  'active',
  '2026-06-22 21:04:19.688115+00'::timestamptz,
  '2026-06-22 21:04:19.688115+00'::timestamptz,
  NULL,
  'com.digitalvirgo.bravigo',
  false
)
ON CONFLICT (id) DO UPDATE SET
  service_id           = EXCLUDED.service_id,
  slug                 = EXCLUDED.slug,
  display_name         = EXCLUDED.display_name,
  country_code         = EXCLUDED.country_code,
  is_global            = EXCLUDED.is_global,
  native_bundle_id     = EXCLUDED.native_bundle_id,
  status               = EXCLUDED.status,
  hostname_staging     = EXCLUDED.hostname_staging,
  hostname_production  = EXCLUDED.hostname_production,
  is_default           = EXCLUDED.is_default,
  updated_at           = EXCLUDED.updated_at;
