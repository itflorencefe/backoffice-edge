-- Auto-seed Back to School avatar defaults for Bravigo and Winfinity
-- (staging + production). Safe to re-run: UPSERT on (id).
--
-- configuration routes the client to the avatar-generate edge function
-- (server-side OpenAI). Explicit function_name + timeout_seconds (180 = 3 min,
-- matches DEFAULT_TIMEOUT_SECONDS). model is omitted so the edge function
-- uses gpt-4o-mini. OPENAI_API_KEY is an edge secret (not stored here).

INSERT INTO backoffice.service_avatar_defaults (
  id, service_id, environment, themes, event,
  label, valid_from, valid_to, archived, enabled, configuration,
  created_at, updated_at
)
VALUES
  -- Bravigo production
  (
    'b6d2a723-2a57-444d-9c58-b8326a658c32'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'production',
    '[{"theme":"Mathematics","label_i18n_key":"theme.mathematics"},{"theme":"History","label_i18n_key":"theme.history"},{"theme":"Literature","label_i18n_key":"theme.literature"},{"theme":"Science","label_i18n_key":"theme.science"},{"theme":"Sports","label_i18n_key":"theme.sports"},{"theme":"Music","label_i18n_key":"theme.music"},{"theme":"Art","label_i18n_key":"theme.art"}]'::jsonb,
    'Back to School',
    NULL,
    NULL,
    NULL,
    false,
    true,
    '{"type":"edge-function","function_name":"avatar-generate","timeout_seconds":180}'::jsonb,
    now(),
    now()
  ),
  -- Bravigo staging
  (
    'b9101c7a-feb5-4783-9bc0-ea3c0f082e75'::uuid,
    '1927f41e-a809-49c9-9661-5a54a6177069'::uuid,
    'staging',
    '[{"theme":"Mathematics","label_i18n_key":"theme.mathematics"},{"theme":"History","label_i18n_key":"theme.history"},{"theme":"Literature","label_i18n_key":"theme.literature"},{"theme":"Science","label_i18n_key":"theme.science"},{"theme":"Sports","label_i18n_key":"theme.sports"},{"theme":"Music","label_i18n_key":"theme.music"},{"theme":"Art","label_i18n_key":"theme.art"}]'::jsonb,
    'Back to School',
    NULL,
    NULL,
    NULL,
    false,
    true,
    '{"type":"edge-function","function_name":"avatar-generate","timeout_seconds":180}'::jsonb,
    now(),
    now()
  ),
  -- Winfinity production
  (
    'b0d7147f-4778-40ea-abaf-d92f0b48a82f'::uuid,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid,
    'production',
    '[{"theme":"Mathematics","label_i18n_key":"theme.mathematics"},{"theme":"History","label_i18n_key":"theme.history"},{"theme":"Literature","label_i18n_key":"theme.literature"},{"theme":"Science","label_i18n_key":"theme.science"},{"theme":"Sports","label_i18n_key":"theme.sports"},{"theme":"Music","label_i18n_key":"theme.music"},{"theme":"Art","label_i18n_key":"theme.art"}]'::jsonb,
    'Back to School',
    NULL,
    NULL,
    NULL,
    false,
    true,
    '{"type":"edge-function","function_name":"avatar-generate","timeout_seconds":180}'::jsonb,
    now(),
    now()
  ),
  -- Winfinity staging
  (
    '060fcbb9-d9af-40c6-a3e4-9f46388c6237'::uuid,
    '365a2e0b-49d6-46f9-bf2e-c1937decfe51'::uuid,
    'staging',
    '[{"theme":"Mathematics","label_i18n_key":"theme.mathematics"},{"theme":"History","label_i18n_key":"theme.history"},{"theme":"Literature","label_i18n_key":"theme.literature"},{"theme":"Science","label_i18n_key":"theme.science"},{"theme":"Sports","label_i18n_key":"theme.sports"},{"theme":"Music","label_i18n_key":"theme.music"},{"theme":"Art","label_i18n_key":"theme.art"}]'::jsonb,
    'Back to School',
    NULL,
    NULL,
    NULL,
    false,
    true,
    '{"type":"edge-function","function_name":"avatar-generate","timeout_seconds":180}'::jsonb,
    now(),
    now()
  )
ON CONFLICT (id) DO UPDATE SET
  themes        = EXCLUDED.themes,
  event         = EXCLUDED.event,
  label         = EXCLUDED.label,
  valid_from    = EXCLUDED.valid_from,
  valid_to      = EXCLUDED.valid_to,
  archived      = EXCLUDED.archived,
  enabled       = EXCLUDED.enabled,
  configuration = EXCLUDED.configuration,
  updated_at    = now();
