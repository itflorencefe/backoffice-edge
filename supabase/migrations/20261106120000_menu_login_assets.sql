/*
# Menu items on three levels, login channels + signup settings, product-level assets

Port of bravigo-migration packs/bbm 20261106120000_bbm_menu_login_assets.sql to the
`backoffice` schema.

Differences from the BBM file:
- Login methods are CONVERTED to the new channels instead of being deleted
  (BBM deleted every row on explicit request of its product owner).
- Menu items keep the starter menus model (bo_product_menus, level tables
  materialised on language rows): Service / Product rows written directly in
  bo_product_menu_items are an additional, optional layer.
- bo_product_level_assets already exists in the baseline: no change.

## 1. Menu items on Service > Product > Language
- `bo_product_menu_items`: `product_locale_id` nullable, NEW `service_id`, `product_id`
  (cascade), `enabled` (false = hides an inherited item), check one owner,
  partial unique (owner, environment, item_key) for service and product rows.
- RLS: viewers read, editors write (items and tiers).
- `screen_slug` on items and tiers (App Screen link), `badge_i18n_key` on items and tiers.
- Labels / badges without an i18n key are copied to translations and referenced as
  "namespace.key" (service: `menuItems`, product / language: `<camelProductSlug>MenuItems`).
  Plain `label` / `badge_text` stay as fallback.

## 2. Login methods: channels email / msisdn / google / apple
Conversion of existing rows (config keys are kept, `mode` / `password_format` added):
  email_password            -> email  (password, alphanumeric)
  msisdn_pin                -> msisdn (password, numeric)
  otp                       -> msisdn (otp)
  pinless                   -> msisdn (pinless)
  email_password_msisdn_pin -> email (password, alphanumeric) + msisdn (password, numeric)
  email_password_otp        -> email (password, alphanumeric) + msisdn (otp)
  email_password_pinless    -> email (password, alphanumeric) + msisdn (pinless)
  google                    -> google
  ios                       -> apple
When two old rows map to the same channel, the enabled / default / first one is kept.
- NEW `bo_product_signup_settings` (one row per product and environment), filled from
  the legacy per-method `allow_signup` / `signup_url`. Legacy columns are kept, unused.
- The product seed trigger no longer creates a login method.
*/

-- =============================================================================
-- 1. Menu items on three levels
-- =============================================================================

ALTER TABLE backoffice.bo_product_menu_items ALTER COLUMN product_locale_id DROP NOT NULL;
ALTER TABLE backoffice.bo_product_menu_items
  ADD COLUMN IF NOT EXISTS service_id uuid REFERENCES backoffice.bo_services(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES backoffice.bo_products(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS screen_slug text,
  ADD COLUMN IF NOT EXISTS badge_i18n_key text;
ALTER TABLE backoffice.bo_product_menu_item_tiers
  ADD COLUMN IF NOT EXISTS screen_slug text,
  ADD COLUMN IF NOT EXISTS badge_i18n_key text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bo_product_menu_items_one_owner') THEN
    ALTER TABLE backoffice.bo_product_menu_items ADD CONSTRAINT bo_product_menu_items_one_owner
      CHECK (num_nonnulls(service_id, product_id, product_locale_id) = 1);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS bo_product_menu_items_service_env_key
  ON backoffice.bo_product_menu_items (service_id, environment, item_key) WHERE service_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bo_product_menu_items_product_env_key
  ON backoffice.bo_product_menu_items (product_id, environment, item_key) WHERE product_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bo_product_menu_items_screen_slug
  ON backoffice.bo_product_menu_items (environment, screen_slug) WHERE screen_slug IS NOT NULL;

ALTER TABLE backoffice.bo_product_menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE backoffice.bo_product_menu_item_tiers ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_product_menu_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_product_menu_item_tiers TO authenticated;

DROP POLICY IF EXISTS "Authenticated users can read product menu items" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "Authenticated users can insert product menu items" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "Authenticated users can update product menu items" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "Authenticated users can delete product menu items" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "menu_items_select_viewer" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "menu_items_insert_editor" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "menu_items_update_editor" ON backoffice.bo_product_menu_items;
DROP POLICY IF EXISTS "menu_items_delete_editor" ON backoffice.bo_product_menu_items;

CREATE POLICY "menu_items_select_viewer" ON backoffice.bo_product_menu_items FOR SELECT
  TO authenticated USING (public.is_backoffice_role('viewer'));
CREATE POLICY "menu_items_insert_editor" ON backoffice.bo_product_menu_items FOR INSERT
  TO authenticated WITH CHECK (public.is_backoffice_role('editor'));
CREATE POLICY "menu_items_update_editor" ON backoffice.bo_product_menu_items FOR UPDATE
  TO authenticated USING (public.is_backoffice_role('editor')) WITH CHECK (public.is_backoffice_role('editor'));
CREATE POLICY "menu_items_delete_editor" ON backoffice.bo_product_menu_items FOR DELETE
  TO authenticated USING (public.is_backoffice_role('editor'));

DROP POLICY IF EXISTS "Authenticated users can read menu item tiers" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "Authenticated users can insert menu item tiers" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "Authenticated users can update menu item tiers" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "Authenticated users can delete menu item tiers" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "menu_item_tiers_select_viewer" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "menu_item_tiers_insert_editor" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "menu_item_tiers_update_editor" ON backoffice.bo_product_menu_item_tiers;
DROP POLICY IF EXISTS "menu_item_tiers_delete_editor" ON backoffice.bo_product_menu_item_tiers;

CREATE POLICY "menu_item_tiers_select_viewer" ON backoffice.bo_product_menu_item_tiers FOR SELECT
  TO authenticated USING (public.is_backoffice_role('viewer'));
CREATE POLICY "menu_item_tiers_insert_editor" ON backoffice.bo_product_menu_item_tiers FOR INSERT
  TO authenticated WITH CHECK (public.is_backoffice_role('editor')
    AND EXISTS (SELECT 1 FROM backoffice.bo_product_menu_items i WHERE i.id = menu_item_id));
CREATE POLICY "menu_item_tiers_update_editor" ON backoffice.bo_product_menu_item_tiers FOR UPDATE
  TO authenticated USING (public.is_backoffice_role('editor'))
  WITH CHECK (public.is_backoffice_role('editor')
    AND EXISTS (SELECT 1 FROM backoffice.bo_product_menu_items i WHERE i.id = menu_item_id));
CREATE POLICY "menu_item_tiers_delete_editor" ON backoffice.bo_product_menu_item_tiers FOR DELETE
  TO authenticated USING (public.is_backoffice_role('editor'));

-- Menu texts move to translations (idempotent: only rows without a key).
CREATE OR REPLACE FUNCTION pg_temp.menu_camel(s text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg(CASE WHEN n = 1 THEN lower(w) ELSE upper(left(w, 1)) || lower(substr(w, 2)) END, '' ORDER BY n), '')
  FROM (SELECT w, row_number() OVER () AS n FROM regexp_split_to_table(s, '[^a-zA-Z0-9]+') AS w WHERE w <> '') t
$$;

CREATE TEMP TABLE menu_conv ON COMMIT DROP AS
SELECT m.id, m.environment, m.label, m.badge_text, m.label_i18n_key, m.badge_i18n_key,
  m.service_id, m.product_id, m.product_locale_id,
  CASE WHEN m.service_id IS NOT NULL THEN 'menuItems'
       ELSE pg_temp.menu_camel(coalesce(pp.slug, lp.slug)) || 'MenuItems' END AS ns,
  pg_temp.menu_camel(m.item_key) AS base
FROM backoffice.bo_product_menu_items m
LEFT JOIN backoffice.bo_products pp ON pp.id = m.product_id
LEFT JOIN backoffice.bo_product_locales l ON l.id = m.product_locale_id
LEFT JOIN backoffice.bo_products lp ON lp.id = l.product_id;

INSERT INTO backoffice.bo_service_translations_defaults (service_id, environment, language_code, namespace, key, value)
SELECT DISTINCT p.service_id, c.environment, l.language_code, c.ns, c.base || f.suffix, f.val
FROM menu_conv c
CROSS JOIN LATERAL (VALUES ('Text', c.label, c.label_i18n_key), ('Badge', c.badge_text, c.badge_i18n_key)) f(suffix, val, existing)
JOIN backoffice.bo_products p ON (c.service_id IS NOT NULL AND p.service_id = c.service_id) OR (c.product_id IS NOT NULL AND p.id = c.product_id)
JOIN backoffice.bo_product_locales l ON l.product_id = p.id
WHERE c.product_locale_id IS NULL AND f.existing IS NULL AND coalesce(f.val, '') <> ''
ON CONFLICT (service_id, environment, language_code, namespace, key) DO NOTHING;

INSERT INTO backoffice.bo_product_translations (product_locale_id, environment, namespace, key, value)
SELECT c.product_locale_id, c.environment, c.ns, c.base || f.suffix, f.val
FROM menu_conv c
CROSS JOIN LATERAL (VALUES ('Text', c.label, c.label_i18n_key), ('Badge', c.badge_text, c.badge_i18n_key)) f(suffix, val, existing)
WHERE c.product_locale_id IS NOT NULL AND f.existing IS NULL AND coalesce(f.val, '') <> ''
ON CONFLICT (product_locale_id, environment, namespace, key) DO NOTHING;

UPDATE backoffice.bo_product_menu_items m SET
  label_i18n_key = coalesce(m.label_i18n_key, CASE WHEN coalesce(c.label, '') <> '' THEN c.ns || '.' || c.base || 'Text' END),
  badge_i18n_key = coalesce(m.badge_i18n_key, CASE WHEN coalesce(c.badge_text, '') <> '' THEN c.ns || '.' || c.base || 'Badge' END)
FROM menu_conv c WHERE c.id = m.id;

-- =============================================================================
-- 2. Login channels + signup settings
-- =============================================================================

CREATE TABLE IF NOT EXISTS backoffice.bo_product_signup_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES backoffice.bo_products(id) ON DELETE CASCADE,
  environment text NOT NULL CHECK (environment IN ('staging', 'production')),
  enabled boolean NOT NULL DEFAULT false,
  signup_url text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id),
  CONSTRAINT product_signup_settings_unique UNIQUE (product_id, environment),
  CONSTRAINT product_signup_settings_url_format CHECK (signup_url IS NULL OR signup_url ~ '^(https?://\S+|/\S*)$'),
  CONSTRAINT product_signup_settings_url_required CHECK (NOT enabled OR signup_url IS NOT NULL)
);

ALTER TABLE backoffice.bo_product_signup_settings ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_product_signup_settings TO authenticated, service_role;

DROP POLICY IF EXISTS "Backoffice viewers can read signup settings" ON backoffice.bo_product_signup_settings;
CREATE POLICY "Backoffice viewers can read signup settings" ON backoffice.bo_product_signup_settings
  FOR SELECT TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins can insert signup settings" ON backoffice.bo_product_signup_settings;
CREATE POLICY "Admins can insert signup settings" ON backoffice.bo_product_signup_settings
  FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can update signup settings" ON backoffice.bo_product_signup_settings;
CREATE POLICY "Admins can update signup settings" ON backoffice.bo_product_signup_settings
  FOR UPDATE TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can delete signup settings" ON backoffice.bo_product_signup_settings;
CREATE POLICY "Admins can delete signup settings" ON backoffice.bo_product_signup_settings
  FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'));

-- Signup: enabled when an enabled legacy method allowed it and a valid URL exists.
INSERT INTO backoffice.bo_product_signup_settings (product_id, environment, enabled, signup_url)
SELECT product_id, environment, coalesce(any_signup, false) AND url IS NOT NULL, url
FROM (
  SELECT product_id, environment,
    bool_or(enabled AND allow_signup) AS any_signup,
    (array_agg(signup_url ORDER BY display_order) FILTER (WHERE signup_url ~ '^(https?://\S+|/\S*)$'))[1] AS url
  FROM backoffice.bo_product_login_methods
  GROUP BY product_id, environment
) legacy
ON CONFLICT (product_id, environment) DO NOTHING;

ALTER TABLE backoffice.bo_product_login_methods DROP CONSTRAINT IF EXISTS product_login_methods_type_check;

CREATE TEMP TABLE login_conv ON COMMIT DROP AS
SELECT DISTINCT ON (m.product_id, m.environment, v.new_type)
  m.id AS old_id, m.product_id, m.environment, v.new_type AS type, m.enabled, m.is_default,
  m.display_order + v.sub AS display_order, m.label_i18n_key, m.icon, m.feature_flag,
  m.min_app_version, m.max_app_version, (m.config - 'allow_signup') || v.extra::jsonb AS config, m.updated_by
FROM backoffice.bo_product_login_methods m
JOIN (VALUES
  ('email_password',            'email',  '{"mode":"password","password_format":"alphanumeric"}', 0),
  ('msisdn_pin',                'msisdn', '{"mode":"password","password_format":"numeric"}',      0),
  ('otp',                       'msisdn', '{"mode":"otp"}',                                       0),
  ('pinless',                   'msisdn', '{"mode":"pinless"}',                                   0),
  ('email_password_msisdn_pin', 'email',  '{"mode":"password","password_format":"alphanumeric"}', 0),
  ('email_password_msisdn_pin', 'msisdn', '{"mode":"password","password_format":"numeric"}',      1),
  ('email_password_otp',        'email',  '{"mode":"password","password_format":"alphanumeric"}', 0),
  ('email_password_otp',        'msisdn', '{"mode":"otp"}',                                       1),
  ('email_password_pinless',    'email',  '{"mode":"password","password_format":"alphanumeric"}', 0),
  ('email_password_pinless',    'msisdn', '{"mode":"pinless"}',                                   1),
  ('google',                    'google', '{}',                                                   0),
  ('ios',                       'apple',  '{}',                                                   0)
) AS v(old_type, new_type, extra, sub) ON v.old_type = m.type
ORDER BY m.product_id, m.environment, v.new_type, m.enabled DESC, m.is_default DESC, m.display_order, m.id;

DELETE FROM backoffice.bo_product_login_methods
WHERE type NOT IN ('email', 'msisdn', 'google', 'apple');

INSERT INTO backoffice.bo_product_login_methods
  (product_id, environment, type, enabled, is_default, display_order, label_i18n_key, icon,
   feature_flag, min_app_version, max_app_version, config, updated_by)
SELECT product_id, environment, type, enabled, is_default, display_order, label_i18n_key, icon,
  feature_flag, min_app_version, max_app_version, config, updated_by
FROM login_conv
ON CONFLICT (product_id, environment, type) DO NOTHING;

ALTER TABLE backoffice.bo_product_login_methods ADD CONSTRAINT product_login_methods_type_check
  CHECK (type IN ('email', 'msisdn', 'google', 'apple'));

ALTER TABLE backoffice.bo_product_login_methods DROP CONSTRAINT IF EXISTS product_login_methods_mode_check;
ALTER TABLE backoffice.bo_product_login_methods ADD CONSTRAINT product_login_methods_mode_check CHECK (
  (type IN ('google', 'apple'))
  OR (type = 'email' AND coalesce(config->>'mode', '') IN ('otp', 'password'))
  OR (type = 'msisdn' AND coalesce(config->>'mode', '') IN ('otp', 'password', 'pinless'))
);

ALTER TABLE backoffice.bo_product_login_methods DROP CONSTRAINT IF EXISTS product_login_methods_password_format_check;
ALTER TABLE backoffice.bo_product_login_methods ADD CONSTRAINT product_login_methods_password_format_check CHECK (
  coalesce(config->>'mode', '') <> 'password'
  OR coalesce(config->>'password_format', '') IN ('numeric', 'alphanumeric')
);

-- New products start with no login method.
CREATE OR REPLACE FUNCTION public.seed_default_content_consumption_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  content_types text[] := ARRAY['game','video','audio','quiz','instant'];
  envs text[] := ARRAY['staging','production'];
  tiers text[] := ARRAY['guest','free','premium'];
  _ct text; _env text; _tier text; _action text;
BEGIN
  FOREACH _env IN ARRAY envs LOOP
    FOREACH _ct IN ARRAY content_types LOOP
      FOREACH _tier IN ARRAY tiers LOOP
        IF _tier = 'premium' THEN _action := 'PLAY'; ELSE _action := 'LOGIN'; END IF;
        INSERT INTO backoffice.bo_product_content_consumption_rules
          (product_id, environment, content_type, tier, action, rate_limit_enabled, tries_limit, frequency_period, frequency_unit_count)
        VALUES (NEW.id, _env, _ct, _tier, _action, false, NULL, NULL, 1)
        ON CONFLICT (product_id, environment, content_type, tier) DO NOTHING;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.seed_default_content_consumption_rules() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
