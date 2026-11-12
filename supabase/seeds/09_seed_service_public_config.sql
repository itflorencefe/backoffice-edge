-- Service public_config defaults: Bravigo IAP_* + SMART_JOURNEY_ID (both services).
-- Production only (as exported). Safe to re-run: UPSERT on (id).

INSERT INTO backoffice.product_public_config (
  id, service_id, environment, key, value, description, created_at, updated_at
)
VALUES
  -- Bravigo IAP
  (
    '3a59eefc-da9b-4366-9b54-479c22bcddcd'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_NATIVE_PAYMENT',
    'ENABLED',
    '',
    '2026-09-23 08:12:59.506798+00'::timestamptz,
    '2026-09-23 08:12:59.506798+00'::timestamptz
  ),
  (
    '42ed10a5-5fec-4724-9611-3392eb8dcee3'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_PLAY_BASE_PLAN_ID',
    'monthly',
    '',
    '2026-09-23 08:18:49.520004+00'::timestamptz,
    '2026-09-23 08:18:49.520004+00'::timestamptz
  ),
  (
    '89b6df43-cb06-4610-bda5-de8f996312e8'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_APPLE_ANNUAL_PRODUCT_ID',
    'test_annual_subscription',
    '',
    '2026-09-23 10:20:28.178163+00'::timestamptz,
    '2026-09-23 10:20:28.178163+00'::timestamptz
  ),
  (
    'b627f8e3-6619-4167-8057-8d36c46b9018'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_APPLE_PRODUCT_ID',
    'test_monthly_subscription',
    '',
    '2026-09-23 08:19:13.155199+00'::timestamptz,
    '2026-09-23 08:19:13.155199+00'::timestamptz
  ),
  (
    'c91a4b48-f090-4d76-8da9-6da5defb40f4'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_PLAY_PRODUCT_ID',
    'test_monthly_subscription',
    '',
    '2026-09-23 08:13:18.031567+00'::timestamptz,
    '2026-09-23 08:13:18.031567+00'::timestamptz
  ),
  (
    'd173433e-9ef4-4008-8d54-e4161731912e'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'IAP_PLAY_ANNUAL_PRODUCT_ID',
    'test_annual_subscription',
    '',
    '2026-09-23 10:21:16.004605+00'::timestamptz,
    '2026-09-23 10:21:16.004605+00'::timestamptz
  ),
  -- SMART_JOURNEY_ID
  (
    '430f64d7-bee7-4cba-88e2-4753c965fb2b'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    'SMART_JOURNEY_ID',
    '38',
    '',
    '2026-10-27 11:35:25.690743+00'::timestamptz,
    '2026-10-27 11:35:25.690743+00'::timestamptz
  ),
  (
    'd6d493d4-3ac5-416d-a4fa-a73cf95176a9'::uuid,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid,
    'production',
    'SMART_JOURNEY_ID',
    '34',
    '',
    '2026-10-27 11:35:43.588262+00'::timestamptz,
    '2026-10-27 11:35:43.588262+00'::timestamptz
  )
ON CONFLICT (id) DO UPDATE SET
  service_id  = EXCLUDED.service_id,
  environment = EXCLUDED.environment,
  key         = EXCLUDED.key,
  value       = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at  = EXCLUDED.updated_at;
