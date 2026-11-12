-- =============================================================================
-- Dual schema (port of bravigo-migration packs/bbm 20261112120000_bbm_dual_schema.sql)
-- =============================================================================
-- Brings the edge schema to the BBM dual-schema shape:
--   * back office tables: backoffice.bo_<name> -> backoffice.<name> (bo_ prefix removed);
--   * app tables: public -> application;
--   * public config folded into backoffice.product_public_config with three owners
--     (service_id / product_id / product_locale_id): bo_service_public_config_defaults and the
--     edge-only bo_product_level_public_config become service / product rows;
--   * agreed hygiene DROPs (tables, columns, dashboard RPCs);
--   * helpers rewritten on the new names (+ public RPC wrappers), read-only public compat views.
-- Edge-only objects are KEPT and renamed the same way: multi-level menus (incl.
-- service_menu_items_defaults, still used by the edge menu model), social links, branding templates,
-- translation keys/overrides/sections and their functions/triggers.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS backoffice;
CREATE SCHEMA IF NOT EXISTS application;

GRANT USAGE ON SCHEMA backoffice TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA application TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Drop dead RPCs (dashboard abandoned for 2.0)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS backoffice.bo_product_dashboard(uuid, text, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.bo_product_dashboard(uuid, text, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public._bo_dashboard_period_kpis(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.get_leaderboard(integer);
DROP FUNCTION IF EXISTS public.get_user_rank(uuid);

-- ---------------------------------------------------------------------------
-- 2. Public config three-level fold (before schema move)
-- ---------------------------------------------------------------------------
ALTER TABLE backoffice.bo_product_public_config
  ADD COLUMN IF NOT EXISTS service_id uuid,
  ADD COLUMN IF NOT EXISTS product_id uuid;

ALTER TABLE backoffice.bo_product_public_config
  ALTER COLUMN product_locale_id DROP NOT NULL;

ALTER TABLE backoffice.bo_product_public_config
  DROP CONSTRAINT IF EXISTS bo_product_public_config_one_owner;

ALTER TABLE backoffice.bo_product_public_config
  ADD CONSTRAINT bo_product_public_config_one_owner
  CHECK (num_nonnulls(service_id, product_id, product_locale_id) = 1);

DROP INDEX IF EXISTS backoffice.bo_product_public_config_product_locale_id_environment_key_key;
DROP INDEX IF EXISTS backoffice.bo_product_public_config_locale_env_idx;

CREATE UNIQUE INDEX bo_product_public_config_service_env_key
  ON backoffice.bo_product_public_config (service_id, environment, key)
  WHERE service_id IS NOT NULL;
CREATE UNIQUE INDEX bo_product_public_config_product_env_key
  ON backoffice.bo_product_public_config (product_id, environment, key)
  WHERE product_id IS NOT NULL;
CREATE UNIQUE INDEX bo_product_public_config_locale_env_key
  ON backoffice.bo_product_public_config (product_locale_id, environment, key)
  WHERE product_locale_id IS NOT NULL;
CREATE INDEX bo_product_public_config_locale_env_idx
  ON backoffice.bo_product_public_config (product_locale_id, environment)
  WHERE product_locale_id IS NOT NULL;

ALTER TABLE backoffice.bo_product_public_config
  DROP CONSTRAINT IF EXISTS bo_product_public_config_service_id_fkey;
ALTER TABLE backoffice.bo_product_public_config
  ADD CONSTRAINT bo_product_public_config_service_id_fkey
  FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id) ON DELETE CASCADE;

ALTER TABLE backoffice.bo_product_public_config
  DROP CONSTRAINT IF EXISTS bo_product_public_config_product_id_fkey;
ALTER TABLE backoffice.bo_product_public_config
  ADD CONSTRAINT bo_product_public_config_product_id_fkey
  FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

-- Fold service defaults (preserve ids when the id is free; else insert new id)
INSERT INTO backoffice.bo_product_public_config (
  id, service_id, product_id, product_locale_id, environment, key, value, description, created_at, updated_at
)
SELECT
  d.id, d.service_id, NULL, NULL, d.environment, d.key, d.value, d.description, d.created_at, d.updated_at
FROM backoffice.bo_service_public_config_defaults d
WHERE NOT EXISTS (SELECT 1 FROM backoffice.bo_product_public_config c WHERE c.id = d.id)
  AND NOT EXISTS (
    SELECT 1 FROM backoffice.bo_product_public_config c
    WHERE c.service_id = d.service_id AND c.environment = d.environment AND c.key = d.key
  );

INSERT INTO backoffice.bo_product_public_config (
  service_id, product_id, product_locale_id, environment, key, value, description, created_at, updated_at
)
SELECT
  d.service_id, NULL, NULL, d.environment, d.key, d.value, d.description, d.created_at, d.updated_at
FROM backoffice.bo_service_public_config_defaults d
WHERE NOT EXISTS (
  SELECT 1 FROM backoffice.bo_product_public_config c
  WHERE c.service_id = d.service_id AND c.environment = d.environment AND c.key = d.key
);

-- Fold the edge product-level public config (bo_product_level_public_config) into product rows
INSERT INTO backoffice.bo_product_public_config (
  id, service_id, product_id, product_locale_id, environment, key, value, description, created_at, updated_at
)
SELECT
  d.id, NULL, d.product_id, NULL, d.environment, d.key, d.value, d.description, d.created_at, d.updated_at
FROM backoffice.bo_product_level_public_config d
WHERE NOT EXISTS (SELECT 1 FROM backoffice.bo_product_public_config c WHERE c.id = d.id)
  AND NOT EXISTS (
    SELECT 1 FROM backoffice.bo_product_public_config c
    WHERE c.product_id = d.product_id AND c.environment = d.environment AND c.key = d.key
  );

INSERT INTO backoffice.bo_product_public_config (
  service_id, product_id, product_locale_id, environment, key, value, description, created_at, updated_at
)
SELECT
  NULL, d.product_id, NULL, d.environment, d.key, d.value, d.description, d.created_at, d.updated_at
FROM backoffice.bo_product_level_public_config d
WHERE NOT EXISTS (
  SELECT 1 FROM backoffice.bo_product_public_config c
  WHERE c.product_id = d.product_id AND c.environment = d.environment AND c.key = d.key
);

DROP TABLE IF EXISTS backoffice.bo_service_public_config_defaults CASCADE;
DROP TABLE IF EXISTS backoffice.bo_product_level_public_config CASCADE;

-- One config-version trigger for the three owners (replaced in section 6 with the owner-aware function)
DROP TRIGGER IF EXISTS product_public_config_bump_version ON backoffice.bo_product_public_config;

-- ---------------------------------------------------------------------------
-- 3. Drop hygiene tables (children first). No compat views for these.
-- ---------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.badges DROP CONSTRAINT IF EXISTS badges_event_id_fkey;

DROP TABLE IF EXISTS public.activity_notifications CASCADE;
DROP TABLE IF EXISTS public.user_wishlist CASCADE;
DROP TABLE IF EXISTS public.user_rewards CASCADE;
DROP TABLE IF EXISTS public.user_activities CASCADE;
DROP TABLE IF EXISTS public.user_cards CASCADE;
DROP TABLE IF EXISTS public.content_consumption_tier_rules CASCADE;
DROP TABLE IF EXISTS public.content_consumption_rules CASCADE;
DROP TABLE IF EXISTS public.player_cards CASCADE;
DROP TABLE IF EXISTS public.games CASCADE;
DROP TABLE IF EXISTS public.rewards CASCADE;
DROP TABLE IF EXISTS public.special_events CASCADE;
DROP TABLE IF EXISTS public.pulsar_quiz_cache CASCADE;
DROP TABLE IF EXISTS public.app_config CASCADE;
DROP TABLE IF EXISTS public.admin_users CASCADE;
DROP TABLE IF EXISTS backoffice.bo_product_domains CASCADE;
-- KEPT in edge: bo_service_menu_items_defaults (service menus -> product/locale menu propagation).

-- ---------------------------------------------------------------------------
-- 4. Drop agreed columns
-- ---------------------------------------------------------------------------
ALTER TABLE backoffice.bo_product_assets DROP COLUMN IF EXISTS width;
ALTER TABLE backoffice.bo_product_assets DROP COLUMN IF EXISTS height;
ALTER TABLE backoffice.bo_product_document_versions DROP COLUMN IF EXISTS body_markdown;
ALTER TABLE backoffice.bo_product_document_versions DROP COLUMN IF EXISTS body_json;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS points_expiry;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS rank_position;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS welcome_bonus_claimed;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS badge_name;
ALTER TABLE public.profiles DROP COLUMN IF EXISTS avatar_traits;
ALTER TABLE public.badges DROP COLUMN IF EXISTS description;
ALTER TABLE public.badges DROP COLUMN IF EXISTS event_id;
ALTER TABLE public.avatar_generations DROP COLUMN IF EXISTS favourite_team;
ALTER TABLE public.avatar_generations DROP COLUMN IF EXISTS card_mode;

-- ---------------------------------------------------------------------------
-- 5. Move KEEP tables to final schemas / names
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.avatar_generations;
  EXCEPTION WHEN undefined_object OR undefined_table THEN
    NULL;
  END;
END $$;

ALTER TABLE backoffice."bo_app_screen_labels" RENAME TO "app_screen_labels";
ALTER TABLE backoffice."bo_app_screen_sections" RENAME TO "app_screen_sections";
ALTER TABLE backoffice."bo_app_screens" RENAME TO "app_screens";
ALTER TABLE backoffice."bo_atom_legal_documents" RENAME TO "atom_legal_documents";
ALTER TABLE backoffice."bo_backoffice_audit_log" RENAME TO "backoffice_audit_log";
ALTER TABLE backoffice."bo_backoffice_users" RENAME TO "backoffice_users";
ALTER TABLE backoffice."bo_locale_avatar" RENAME TO "locale_avatar";
ALTER TABLE backoffice."bo_locale_instant_games" RENAME TO "locale_instant_games";
ALTER TABLE backoffice."bo_page_behaviour_rules" RENAME TO "page_behaviour_rules";
ALTER TABLE backoffice."bo_page_behaviour_tier_rules" RENAME TO "page_behaviour_tier_rules";
ALTER TABLE backoffice."bo_product_assets" RENAME TO "product_assets";
ALTER TABLE backoffice."bo_product_avatar" RENAME TO "product_avatar";
ALTER TABLE backoffice."bo_product_branding" RENAME TO "product_branding";
ALTER TABLE backoffice."bo_product_branding_templates" RENAME TO "product_branding_templates";
ALTER TABLE backoffice."bo_product_content_consumption_rules" RENAME TO "product_content_consumption_rules";
ALTER TABLE backoffice."bo_product_document_versions" RENAME TO "product_document_versions";
ALTER TABLE backoffice."bo_product_documents" RENAME TO "product_documents";
ALTER TABLE backoffice."bo_product_feature_flags" RENAME TO "product_feature_flags";
ALTER TABLE backoffice."bo_product_footer_hidden_pages" RENAME TO "product_footer_hidden_pages";
ALTER TABLE backoffice."bo_product_footer_items" RENAME TO "product_footer_items";
ALTER TABLE backoffice."bo_product_instant_games" RENAME TO "product_instant_games";
ALTER TABLE backoffice."bo_product_level_assets" RENAME TO "product_level_assets";
ALTER TABLE backoffice."bo_product_level_branding_templates" RENAME TO "product_level_branding_templates";
ALTER TABLE backoffice."bo_product_level_menu_items" RENAME TO "product_level_menu_items";
ALTER TABLE backoffice."bo_product_level_menus" RENAME TO "product_level_menus";
ALTER TABLE backoffice."bo_product_level_social_links" RENAME TO "product_level_social_links";
ALTER TABLE backoffice."bo_product_locales" RENAME TO "product_locales";
ALTER TABLE backoffice."bo_product_login_methods" RENAME TO "product_login_methods";
ALTER TABLE backoffice."bo_product_menu_item_tiers" RENAME TO "product_menu_item_tiers";
ALTER TABLE backoffice."bo_product_menu_items" RENAME TO "product_menu_items";
ALTER TABLE backoffice."bo_product_menus" RENAME TO "product_menus";
ALTER TABLE backoffice."bo_product_packs" RENAME TO "product_packs";
ALTER TABLE backoffice."bo_product_public_config" RENAME TO "product_public_config";
ALTER TABLE backoffice."bo_product_secrets" RENAME TO "product_secrets";
ALTER TABLE backoffice."bo_product_signup_settings" RENAME TO "product_signup_settings";
ALTER TABLE backoffice."bo_product_social_links" RENAME TO "product_social_links";
ALTER TABLE backoffice."bo_product_translations" RENAME TO "product_translations";
ALTER TABLE backoffice."bo_product_unsubscribe_methods" RENAME TO "product_unsubscribe_methods";
ALTER TABLE backoffice."bo_products" RENAME TO "products";
ALTER TABLE backoffice."bo_service_assets_defaults" RENAME TO "service_assets_defaults";
ALTER TABLE backoffice."bo_service_avatar_defaults" RENAME TO "service_avatar_defaults";
ALTER TABLE backoffice."bo_service_branding_defaults" RENAME TO "service_branding_defaults";
ALTER TABLE backoffice."bo_service_branding_templates" RENAME TO "service_branding_templates";
ALTER TABLE backoffice."bo_service_feature_flags_defaults" RENAME TO "service_feature_flags_defaults";
ALTER TABLE backoffice."bo_service_footer_items_defaults" RENAME TO "service_footer_items_defaults";
ALTER TABLE backoffice."bo_service_instant_games_defaults" RENAME TO "service_instant_games_defaults";
ALTER TABLE backoffice."bo_service_login_methods_defaults" RENAME TO "service_login_methods_defaults";
ALTER TABLE backoffice."bo_service_menu_items_defaults" RENAME TO "service_menu_items_defaults";
ALTER TABLE backoffice."bo_service_menus" RENAME TO "service_menus";
ALTER TABLE backoffice."bo_service_social_links_defaults" RENAME TO "service_social_links_defaults";
ALTER TABLE backoffice."bo_service_translations_defaults" RENAME TO "service_translations_defaults";
ALTER TABLE backoffice."bo_services" RENAME TO "services";
ALTER TABLE backoffice."bo_translation_keys" RENAME TO "translation_keys";
ALTER TABLE backoffice."bo_translation_overrides" RENAME TO "translation_overrides";
ALTER TABLE backoffice."bo_translation_sections" RENAME TO "translation_sections";

ALTER TABLE public."profiles" SET SCHEMA application;
ALTER TABLE public."avatar_generations" SET SCHEMA application;
ALTER TABLE public."badges" SET SCHEMA application;
ALTER TABLE public."user_badges" SET SCHEMA application;
ALTER TABLE public."quiz_attempts" SET SCHEMA application;
ALTER TABLE public."content_attempts" SET SCHEMA application;
ALTER TABLE public."redeemed_reward_assets" SET SCHEMA application;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE application.avatar_generations;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END $$;

-- Align with the BBM shape: product_level_assets defaults + index, and the full unique index on
-- page_behaviour_rules (product_id, environment, path) used by ON CONFLICT (equivalent to the edge
-- partial index: NULL product_id rows never conflict).
ALTER TABLE backoffice.product_level_assets
  ALTER COLUMN environment SET DEFAULT 'staging',
  ALTER COLUMN url SET DEFAULT '';
CREATE INDEX IF NOT EXISTS bo_product_level_assets_product_env_idx
  ON backoffice.product_level_assets (product_id, environment);
CREATE UNIQUE INDEX IF NOT EXISTS bo_page_behaviour_rules_product_id_environment_path_key
  ON backoffice.page_behaviour_rules (product_id, environment, path);

-- ---------------------------------------------------------------------------
-- 6. Rewrite helpers to qualify new schemas (+ public RPC wrappers)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION backoffice.backoffice_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$
  SELECT role FROM backoffice.backoffice_users
  WHERE user_id = auth.uid() AND is_active = true
  LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION public.backoffice_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$ SELECT backoffice.backoffice_role(); $$;

CREATE OR REPLACE FUNCTION backoffice.is_backoffice_role(required text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN required = 'viewer' THEN backoffice.backoffice_role() IN ('viewer','editor','admin')
    WHEN required = 'editor' THEN backoffice.backoffice_role() IN ('editor','admin')
    WHEN required = 'admin'  THEN backoffice.backoffice_role() = 'admin'
    ELSE false
  END;
$$;
CREATE OR REPLACE FUNCTION public.is_backoffice_role(required text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$ SELECT backoffice.is_backoffice_role(required); $$;

-- Triggers still call public.bump_locale_config_version; body writes physical tables.
CREATE OR REPLACE FUNCTION public.bump_locale_config_version() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
DECLARE
  target_locale uuid; target_env text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_locale := OLD.product_locale_id; target_env := OLD.environment;
  ELSE
    target_locale := NEW.product_locale_id; target_env := NEW.environment;
  END IF;
  IF target_locale IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF target_env = 'staging' THEN
    UPDATE backoffice.product_locales
    SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE id = target_locale;
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.product_locales
    SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE id = target_locale;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION backoffice.publish_document_version(p_version_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
DECLARE v_doc_id uuid; v_product_id uuid;
BEGIN
  SELECT document_id INTO v_doc_id FROM backoffice.product_document_versions WHERE id = p_version_id;
  IF v_doc_id IS NULL THEN RAISE EXCEPTION 'Version not found'; END IF;
  UPDATE backoffice.product_document_versions SET published_at = now() WHERE id = p_version_id;
  UPDATE backoffice.product_documents
  SET current_version_id = p_version_id, status = 'published', updated_at = now()
  WHERE id = v_doc_id RETURNING product_id INTO v_product_id;
  UPDATE backoffice.product_locales
  SET config_version_production = config_version_production + 1,
      config_version_staging = config_version_staging + 1
  WHERE product_id = v_product_id;
END;
$$;
CREATE OR REPLACE FUNCTION public.publish_document_version(p_version_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$ BEGIN PERFORM backoffice.publish_document_version(p_version_id); END; $$;

CREATE OR REPLACE FUNCTION backoffice.reorder_product_packs(p_product_id integer, p_pack_ids text[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
AS $$
DECLARE
  saved_count integer;
  updated_count integer;
BEGIN
  IF p_pack_ids IS NULL OR cardinality(p_pack_ids) = 0 OR
    cardinality(p_pack_ids) <> (SELECT count(DISTINCT id) FROM unnest(p_pack_ids) AS ids(id)) THEN
    RAISE EXCEPTION 'Provide each saved pack ID exactly once';
  END IF;
  PERFORM 1 FROM backoffice.product_packs WHERE "productId" = p_product_id FOR UPDATE;
  SELECT count(*) INTO saved_count FROM backoffice.product_packs WHERE "productId" = p_product_id;
  IF saved_count <> cardinality(p_pack_ids) THEN
    RAISE EXCEPTION 'Saved packs changed. Reload before reordering';
  END IF;
  UPDATE backoffice.product_packs p SET "sortOrder" = ids.position - 1
    FROM unnest(p_pack_ids) WITH ORDINALITY AS ids(id, position)
    WHERE p."productId" = p_product_id AND p."packId" = ids.id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> saved_count THEN
    RAISE EXCEPTION 'Unable to reorder all saved packs. Check permissions and reload';
  END IF;
END;
$$;
CREATE OR REPLACE FUNCTION public.reorder_product_packs(p_product_id integer, p_pack_ids text[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
AS $$ BEGIN PERFORM backoffice.reorder_product_packs(p_product_id, p_pack_ids); END; $$;

CREATE OR REPLACE FUNCTION public.seed_default_content_consumption_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
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
        INSERT INTO backoffice.product_content_consumption_rules
          (product_id, environment, content_type, tier, action, rate_limit_enabled, tries_limit, frequency_period, frequency_unit_count)
        VALUES (NEW.id, _env, _ct, _tier, _action, false, NULL, NULL, 1)
        ON CONFLICT (product_id, environment, content_type, tier) DO NOTHING;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.seed_default_content_consumption_rules() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.seed_default_content_consumption_rules() FROM anon, authenticated;
GRANT ALL ON FUNCTION public.seed_default_content_consumption_rules() TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_product_by_hostname(p_hostname text, p_environment text DEFAULT 'production') RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$
DECLARE
  v_product record;
  v_service record;
  v_locale record;
  host_col text;
BEGIN
  IF p_environment = 'staging' THEN
    SELECT * INTO v_product FROM backoffice.products
    WHERE lower(hostname_staging) = lower(p_hostname) AND status = 'active'
    LIMIT 1;
  ELSE
    SELECT * INTO v_product FROM backoffice.products
    WHERE lower(hostname_production) = lower(p_hostname) AND status = 'active'
    LIMIT 1;
  END IF;
  IF v_product IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_service FROM backoffice.services WHERE id = v_product.service_id;
  SELECT * INTO v_locale FROM backoffice.product_locales
  WHERE product_id = v_product.id AND status = 'active'
  ORDER BY is_default DESC, language_code
  LIMIT 1;
  RETURN jsonb_build_object(
    'service', to_jsonb(v_service),
    'product', to_jsonb(v_product),
    'locale', to_jsonb(v_locale),
    'domain', jsonb_build_object(
      'hostname', p_hostname,
      'environment', p_environment,
      'language_hint', '',
      'product_locale_id', v_locale.id
    ),
    'environment', p_environment
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.check_nickname_available(nickname_input text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
AS $$
BEGIN
  RETURN NOT EXISTS (
    SELECT 1 FROM application.profiles
    WHERE nickname = nickname_input
      AND service_id = public.jwt_service_id()
      AND id IS DISTINCT FROM auth.uid()
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_id_by_email(p_email text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
DECLARE v_user_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM backoffice.backoffice_users
    WHERE user_id = auth.uid() AND is_active = true AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only active backoffice admins can look up users';
  END IF;
  SELECT id INTO v_user_id FROM auth.users WHERE email = p_email LIMIT 1;
  RETURN v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_profile_points_on_quiz() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
BEGIN
  UPDATE application.profiles
  SET total_points = COALESCE(total_points, 0) + NEW.points_earned,
      points_this_week = COALESCE(points_this_week, 0) + NEW.points_earned,
      updated_at = now()
  WHERE id = NEW.user_id AND service_id = NEW.service_id;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION backoffice.app_screen_label_paths(p_service_id uuid, p_environment text)
RETURNS TABLE(
  label text, section_id uuid, platform text, widget_type text, widget_position bigint,
  section_enabled boolean, start_at_local timestamp without time zone, end_at_local timestamp without time zone,
  screen_slug text, screen_name text, screen_enabled boolean,
  service_name text, service_slug text, product_id uuid, product_name text, product_slug text,
  locale_id uuid, locale_name text, locale_code text
)
LANGUAGE sql STABLE
SET search_path TO ''
AS $$
  WITH scr AS (
    SELECT s.*, coalesce(s.product_id, pl.product_id) AS owner_product_id
    FROM backoffice.app_screens s
    LEFT JOIN backoffice.product_locales pl ON pl.id = s.product_locale_id
    WHERE s.environment = p_environment
  ),
  ranked AS (
    SELECT sec.*, row_number() OVER (PARTITION BY sec.screen_id, sec.platform ORDER BY sec.position, sec.created_at) AS rn
    FROM backoffice.app_screen_sections sec
    WHERE sec.screen_id IN (SELECT id FROM scr)
  )
  SELECT
    btrim(r.config->>'label'), r.id, r.platform, r.widget_type, r.rn, r.enabled,
    r.start_at_local::timestamp, r.end_at_local::timestamp,
    scr.slug, coalesce(nullif(scr.name, ''), scr.slug), scr.enabled,
    sv.display_name, sv.slug,
    p.id, p.display_name, p.slug,
    pl.id, pl.display_name, pl.language_code
  FROM ranked r
  JOIN scr ON scr.id = r.screen_id
  JOIN backoffice.services sv ON sv.id = p_service_id
  LEFT JOIN backoffice.products p ON p.id = scr.owner_product_id
  LEFT JOIN backoffice.product_locales pl ON pl.id = scr.product_locale_id
  WHERE coalesce(btrim(r.config->>'label'), '') <> ''
    AND (scr.service_id = p_service_id OR p.service_id = p_service_id)
  ORDER BY p.display_name NULLS FIRST, pl.display_name NULLS FIRST, scr.slug, r.platform, r.rn;
$$;
CREATE OR REPLACE FUNCTION public.app_screen_label_paths(p_service_id uuid, p_environment text)
RETURNS TABLE(
  label text, section_id uuid, platform text, widget_type text, widget_position bigint,
  section_enabled boolean, start_at_local timestamp without time zone, end_at_local timestamp without time zone,
  screen_slug text, screen_name text, screen_enabled boolean,
  service_name text, service_slug text, product_id uuid, product_name text, product_slug text,
  locale_id uuid, locale_name text, locale_code text
)
LANGUAGE sql STABLE
SET search_path TO ''
AS $$ SELECT * FROM backoffice.app_screen_label_paths(p_service_id, p_environment); $$;

CREATE OR REPLACE FUNCTION backoffice.app_screen_label_usage(p_service_id uuid, p_environment text, p_label text)
RETURNS TABLE(section_id uuid, screen_name text)
LANGUAGE sql STABLE
SET search_path TO ''
AS $$
  SELECT sec.id, coalesce(nullif(scr.name, ''), scr.slug)
  FROM backoffice.app_screen_sections sec
  JOIN backoffice.app_screens scr ON scr.id = sec.screen_id
  WHERE scr.environment = p_environment
    AND sec.config->>'label' = p_label
    AND (
      scr.service_id = p_service_id
      OR scr.product_id IN (SELECT id FROM backoffice.products WHERE service_id = p_service_id)
      OR scr.product_locale_id IN (
        SELECT pl.id FROM backoffice.product_locales pl
        JOIN backoffice.products p ON p.id = pl.product_id WHERE p.service_id = p_service_id
      )
    );
$$;
CREATE OR REPLACE FUNCTION public.app_screen_label_usage(p_service_id uuid, p_environment text, p_label text)
RETURNS TABLE(section_id uuid, screen_name text)
LANGUAGE sql STABLE
SET search_path TO ''
AS $$ SELECT * FROM backoffice.app_screen_label_usage(p_service_id, p_environment, p_label); $$;

CREATE OR REPLACE FUNCTION backoffice.rename_app_screen_label(p_label_id uuid, p_new_label text) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
AS $$
DECLARE
  v_row backoffice.app_screen_labels%ROWTYPE;
  v_new text := btrim(p_new_label);
  v_count integer;
BEGIN
  IF v_new = '' THEN RAISE EXCEPTION 'Label cannot be empty'; END IF;
  SELECT * INTO v_row FROM backoffice.app_screen_labels WHERE id = p_label_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Label not found'; END IF;
  UPDATE backoffice.app_screen_labels SET label = v_new, updated_at = now() WHERE id = p_label_id;
  UPDATE backoffice.app_screen_sections sec
  SET config = coalesce(sec.config, '{}'::jsonb) || jsonb_build_object('label', v_new), updated_at = now()
  WHERE sec.id IN (SELECT u.section_id FROM backoffice.app_screen_label_usage(v_row.service_id, v_row.environment, v_row.label) u);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
CREATE OR REPLACE FUNCTION public.rename_app_screen_label(p_label_id uuid, p_new_label text) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
AS $$ BEGIN RETURN backoffice.rename_app_screen_label(p_label_id, p_new_label); END; $$;

-- Move pack validators into backoffice (bodies have empty search_path; keep public wrappers)
CREATE OR REPLACE FUNCTION public.valid_product_pack_color(value json) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT SET search_path TO ''
AS $$ SELECT backoffice.valid_product_pack_color(value); $$;
CREATE OR REPLACE FUNCTION public.valid_product_pack_labels(value json) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT SET search_path TO ''
AS $$ SELECT backoffice.valid_product_pack_labels(value); $$;

-- normalize_product_hostnames stays as trigger on products; no public.bo refs in body

-- Edge: config version for the three-owner public config. A service row bumps every locale of the
-- service, a product row every locale of the product, a locale row that locale (same as the edge
-- per-level triggers before the fold).
CREATE OR REPLACE FUNCTION backoffice.bump_public_config_version() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
AS $$
DECLARE r record; v_locales uuid[];
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  IF r.product_locale_id IS NOT NULL THEN
    v_locales := ARRAY[r.product_locale_id];
  ELSIF r.product_id IS NOT NULL THEN
    SELECT array_agg(id) INTO v_locales FROM backoffice.product_locales WHERE product_id = r.product_id;
  ELSIF r.service_id IS NOT NULL THEN
    SELECT array_agg(pl.id) INTO v_locales FROM backoffice.product_locales pl
    JOIN backoffice.products p ON p.id = pl.product_id WHERE p.service_id = r.service_id;
  END IF;
  IF r.environment = 'staging' THEN
    UPDATE backoffice.product_locales SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE id = ANY (v_locales);
  ELSIF r.environment = 'production' THEN
    UPDATE backoffice.product_locales SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE id = ANY (v_locales);
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER product_public_config_bump_version
  AFTER INSERT OR DELETE OR UPDATE ON backoffice.product_public_config
  FOR EACH ROW EXECUTE FUNCTION backoffice.bump_public_config_version();

-- Edge-only functions: renamed helpers (bo_ prefix removed) and bodies on the new table names.
ALTER FUNCTION backoffice.bo_camel(text) RENAME TO camel;
ALTER FUNCTION backoffice.bo_rename_ref_namespaces(jsonb, jsonb) RENAME TO rename_ref_namespaces;

CREATE OR REPLACE FUNCTION backoffice.camel(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT coalesce(string_agg(CASE WHEN n = 1 THEN lower(w) ELSE upper(left(w, 1)) || lower(substr(w, 2)) END, '' ORDER BY n), '')
  FROM (
    SELECT w, row_number() OVER (ORDER BY ord) AS n
    FROM regexp_split_to_table(p, '[^a-zA-Z0-9]+') WITH ORDINALITY AS t(w, ord)
    WHERE w <> ''
  ) x;
$function$;

CREATE OR REPLACE FUNCTION backoffice.rename_ref_namespaces(p_config jsonb, p_map jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  WITH fix AS (
    SELECT CASE WHEN jsonb_typeof(i) = 'object' THEN (
      SELECT coalesce(jsonb_object_agg(f.key, CASE
        WHEN jsonb_typeof(f.value) = 'object' AND p_map ? (f.value->>'namespace')
        THEN jsonb_set(f.value, '{namespace}', p_map->(f.value->>'namespace')) ELSE f.value END), '{}')
      FROM jsonb_each(i) f) ELSE i END AS v, i
    FROM (SELECT p_config->'i18n' AS i) x
  )
  SELECT CASE WHEN p_config IS NULL THEN NULL ELSE
    (CASE WHEN p_config ? 'i18n' THEN jsonb_set(p_config, '{i18n}', (SELECT v FROM fix)) ELSE p_config END)
    || CASE WHEN jsonb_typeof(p_config->'slides') = 'array' THEN jsonb_build_object('slides', (
         SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(s->'i18n') = 'object' THEN jsonb_set(s, '{i18n}', (
           SELECT coalesce(jsonb_object_agg(f.key, CASE
             WHEN jsonb_typeof(f.value) = 'object' AND p_map ? (f.value->>'namespace')
             THEN jsonb_set(f.value, '{namespace}', p_map->(f.value->>'namespace')) ELSE f.value END), '{}')
           FROM jsonb_each(s->'i18n') f)) ELSE s END ORDER BY o), '[]')
         FROM jsonb_array_elements(p_config->'slides') WITH ORDINALITY AS a(s, o)))
       ELSE '{}'::jsonb END
  END;
$function$;

CREATE OR REPLACE FUNCTION backoffice.app_screen_rename_slug(p_level text, p_owner_id uuid, p_environment text, p_old text, p_new text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_service uuid;
  v_products uuid[] := '{}';
  v_locales uuid[] := '{}';
  v_up_service uuid;
  v_up_product uuid;
  v_map jsonb := '{}';
  v_from text; v_to text;
  v_screens int; v_rules int; v_tiers int; v_widgets int := 0; v_texts int := 0; n int;
BEGIN
  IF NOT public.is_backoffice_role('admin') THEN RAISE EXCEPTION 'Only admins can change screen keys' USING ERRCODE = '42501'; END IF;
  IF p_new IS NULL OR p_new !~ '^[a-z0-9][a-z0-9_-]{0,63}$' OR p_new = p_old THEN RAISE EXCEPTION 'Invalid new screen key' USING ERRCODE = '22023'; END IF;
  IF p_environment NOT IN ('staging', 'production') THEN RAISE EXCEPTION 'Invalid environment' USING ERRCODE = '22023'; END IF;

  IF p_level = 'service' THEN
    v_service := p_owner_id;
    SELECT coalesce(array_agg(id), '{}') INTO v_products FROM backoffice.products WHERE service_id = v_service;
  ELSIF p_level = 'product' THEN
    SELECT service_id INTO v_service FROM backoffice.products WHERE id = p_owner_id;
    v_products := ARRAY[p_owner_id]; v_up_service := v_service;
  ELSIF p_level = 'locale' THEN
    SELECT l.product_id, p.service_id INTO v_up_product, v_service
      FROM backoffice.product_locales l JOIN backoffice.products p ON p.id = l.product_id WHERE l.id = p_owner_id;
    v_locales := ARRAY[p_owner_id]; v_up_service := v_service;
  ELSE RAISE EXCEPTION 'Invalid level' USING ERRCODE = '22023'; END IF;
  IF v_service IS NULL THEN RAISE EXCEPTION 'Owner not found' USING ERRCODE = 'P0002'; END IF;
  IF p_level <> 'locale' THEN
    SELECT coalesce(array_agg(id), '{}') INTO v_locales FROM backoffice.product_locales WHERE product_id = ANY (v_products);
  END IF;

  IF EXISTS (
    SELECT 1 FROM backoffice.app_screens s WHERE s.environment = p_environment AND s.slug = p_new AND (
      (p_level = 'service' AND s.service_id = v_service) OR s.product_id = ANY (v_products) OR s.product_locale_id = ANY (v_locales)
      OR s.service_id = v_up_service OR s.product_id = v_up_product)
  ) THEN RAISE EXCEPTION 'A screen "%" already exists at this level, above it or below it', p_new USING ERRCODE = '23505'; END IF;

  -- Language texts share the product namespace, so a language rename moves no texts.
  IF p_level <> 'locale' THEN
    IF p_level = 'service' THEN
      v_map := v_map || jsonb_build_object(backoffice.camel(p_old) || 'Screen', backoffice.camel(p_new) || 'Screen');
    END IF;
    SELECT v_map || coalesce(jsonb_object_agg(backoffice.camel(slug || '-' || p_old) || 'Screen', backoffice.camel(slug || '-' || p_new) || 'Screen'), '{}')
      INTO v_map FROM backoffice.products WHERE id = ANY (v_products);
    IF EXISTS (SELECT 1 FROM backoffice.service_translations_defaults t, jsonb_each_text(v_map) m
               WHERE t.service_id = v_service AND t.environment = p_environment AND t.namespace = m.value)
       OR EXISTS (SELECT 1 FROM backoffice.product_translations t, jsonb_each_text(v_map) m
               WHERE t.product_locale_id = ANY (v_locales) AND t.environment = p_environment AND t.namespace = m.value)
    THEN RAISE EXCEPTION 'Texts already exist under the new screen namespace' USING ERRCODE = '23505'; END IF;
  END IF;

  UPDATE backoffice.app_screens SET slug = p_new, updated_at = now()
   WHERE environment = p_environment AND slug = p_old
     AND ((p_level = 'service' AND service_id = v_service) OR product_id = ANY (v_products) OR product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_screens = ROW_COUNT;

  UPDATE backoffice.page_behaviour_tier_rules t SET screen_slug = p_new, updated_at = now()
    FROM backoffice.page_behaviour_rules r
   WHERE t.rule_id = r.id AND t.screen_slug = p_old AND r.environment = p_environment
     AND ((p_level = 'service' AND r.service_id = v_service) OR r.product_id = ANY (v_products) OR r.product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_tiers = ROW_COUNT;

  UPDATE backoffice.page_behaviour_rules r
     SET screen_slug = p_new, path = CASE WHEN path = '/' || p_old THEN '/' || p_new ELSE path END, updated_at = now()
   WHERE r.environment = p_environment AND r.screen_slug = p_old
     AND ((p_level = 'service' AND r.service_id = v_service) OR r.product_id = ANY (v_products) OR r.product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_rules = ROW_COUNT;

  FOR v_from, v_to IN SELECT key, value FROM jsonb_each_text(v_map) LOOP
    UPDATE backoffice.service_translations_defaults SET namespace = v_to, updated_at = now()
     WHERE service_id = v_service AND environment = p_environment AND namespace = v_from;
    GET DIAGNOSTICS n = ROW_COUNT; v_texts := v_texts + n;
    UPDATE backoffice.product_translations SET namespace = v_to, updated_at = now()
     WHERE product_locale_id = ANY (v_locales) AND environment = p_environment AND namespace = v_from;
    GET DIAGNOSTICS n = ROW_COUNT; v_texts := v_texts + n;
  END LOOP;

  IF v_map <> '{}' THEN
    -- Relink widget texts anywhere in the service: any widget may link to a key of the moved namespaces.
    WITH svc_screens AS (
      SELECT s.id FROM backoffice.app_screens s
        LEFT JOIN backoffice.products p ON p.id = s.product_id
        LEFT JOIN backoffice.product_locales l ON l.id = s.product_locale_id
        LEFT JOIN backoffice.products lp ON lp.id = l.product_id
       WHERE s.environment = p_environment AND v_service IN (s.service_id, p.service_id, lp.service_id)
    ), relinked AS (
      UPDATE backoffice.app_screen_sections sec
         SET config = backoffice.rename_ref_namespaces(sec.config, v_map), updated_at = now()
       WHERE sec.screen_id IN (SELECT id FROM svc_screens)
         AND backoffice.rename_ref_namespaces(sec.config, v_map) IS DISTINCT FROM sec.config
      RETURNING 1
    ) SELECT count(*) INTO v_widgets FROM relinked;
  END IF;

  RETURN jsonb_build_object('screens', v_screens, 'rules', v_rules, 'tier_rules', v_tiers, 'widgets_relinked', v_widgets, 'texts_moved', v_texts);
END;
$function$;

CREATE OR REPLACE FUNCTION backoffice.bump_product_locales_config_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE target_product uuid; target_env text;
BEGIN
  IF TG_OP = 'DELETE' THEN target_product := OLD.product_id; target_env := OLD.environment;
  ELSE target_product := NEW.product_id; target_env := NEW.environment; END IF;
  IF target_env = 'staging' THEN
    UPDATE backoffice.product_locales SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE product_id = target_product;
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.product_locales SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE product_id = target_product;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.bump_service_locales_config_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE target_service uuid; target_env text;
BEGIN
  IF TG_OP = 'DELETE' THEN target_service := OLD.service_id; target_env := OLD.environment;
  ELSE target_service := NEW.service_id; target_env := NEW.environment; END IF;
  IF target_env = 'staging' THEN
    UPDATE backoffice.product_locales SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE product_id IN (SELECT id FROM backoffice.products WHERE service_id = target_service);
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.product_locales SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE product_id IN (SELECT id FROM backoffice.products WHERE service_id = target_service);
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.promote_locale_menus(p_locale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_product_id uuid; v_menus int; v_items int;
BEGIN
  SELECT product_id INTO v_product_id FROM product_locales WHERE id = p_locale_id;

  INSERT INTO product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT s.product_locale_id, 'production', s.menu_key, s.label, s.display_order,
         CASE WHEN s.source_menu_id IS NOT NULL THEN (
           SELECT pm.id FROM product_level_menus pm
           WHERE pm.product_id = v_product_id AND pm.environment = 'production' AND pm.menu_key = s.menu_key
         ) END
  FROM product_menus s
  WHERE s.product_locale_id = p_locale_id AND s.environment = 'staging'
  ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM product_menus p
  WHERE p.product_locale_id = p_locale_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM product_menus s
      WHERE s.product_locale_id = p_locale_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO product_menu_items (
    product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    document_slug, label, label_i18n_key, url, icon, icon_url, display_order, parent_key, visible,
    auth_required, min_app_version, max_app_version, feature_flag, badge_text, badge_color
  )
  SELECT si.product_locale_id, 'production', pm.id,
         CASE WHEN si.source_item_id IS NOT NULL THEN (
           SELECT pli.id FROM product_level_menu_items pli
           JOIN product_level_menus plm ON plm.id = pli.menu_id
           WHERE plm.product_id = v_product_id AND plm.environment = 'production'
             AND plm.menu_key = sm.menu_key AND pli.item_key = si.item_key
         ) END,
         si.item_key, si.item_type, si.nested_menu_key,
         si.document_slug, si.label, si.label_i18n_key, si.url, si.icon, si.icon_url, si.display_order, si.parent_key, si.visible,
         si.auth_required, si.min_app_version, si.max_app_version, si.feature_flag, si.badge_text, si.badge_color
  FROM product_menu_items si
  JOIN product_menus sm ON sm.id = si.menu_id
  JOIN product_menus pm ON pm.product_locale_id = p_locale_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, document_slug = EXCLUDED.document_slug,
    label = EXCLUDED.label, label_i18n_key = EXCLUDED.label_i18n_key, url = EXCLUDED.url, icon = EXCLUDED.icon,
    icon_url = EXCLUDED.icon_url, display_order = EXCLUDED.display_order, parent_key = EXCLUDED.parent_key,
    visible = EXCLUDED.visible, auth_required = EXCLUDED.auth_required, min_app_version = EXCLUDED.min_app_version,
    max_app_version = EXCLUDED.max_app_version, feature_flag = EXCLUDED.feature_flag,
    badge_text = EXCLUDED.badge_text, badge_color = EXCLUDED.badge_color, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM product_menu_items p
  WHERE p.product_locale_id = p_locale_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM product_menu_items si
      JOIN product_menus sm ON sm.id = si.menu_id
      JOIN product_menus pm ON pm.id = p.menu_id
      WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  -- Tiers: replace production tiers with staging tiers, matched by (menu_key, item_key)
  DELETE FROM product_menu_item_tiers t
  USING product_menu_items pi
  WHERE t.menu_item_id = pi.id AND pi.product_locale_id = p_locale_id AND pi.environment = 'production';

  INSERT INTO product_menu_item_tiers (
    menu_item_id, tier, visible, enabled, locked_action, route, external_url,
    label, label_i18n_key, badge_text, badge_color, display_order
  )
  SELECT pi.id, t.tier, t.visible, t.enabled, t.locked_action, t.route, t.external_url,
         t.label, t.label_i18n_key, t.badge_text, t.badge_color, t.display_order
  FROM product_menu_item_tiers t
  JOIN product_menu_items si ON si.id = t.menu_item_id
  JOIN product_menus sm ON sm.id = si.menu_id
  JOIN product_menus pm ON pm.product_locale_id = p_locale_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  JOIN product_menu_items pi ON pi.menu_id = pm.id AND pi.item_key = si.item_key
  WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging';

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.promote_product_menus(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_service_id uuid; v_menus int; v_items int;
BEGIN
  SELECT service_id INTO v_service_id FROM products WHERE id = p_product_id;

  INSERT INTO product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT s.product_id, 'production', s.menu_key, s.label, s.display_order,
         CASE WHEN s.source_menu_id IS NOT NULL THEN (
           SELECT sm.id FROM service_menus sm
           WHERE sm.service_id = v_service_id AND sm.environment = 'production' AND sm.menu_key = s.menu_key
         ) END
  FROM product_level_menus s
  WHERE s.product_id = p_product_id AND s.environment = 'staging'
  ON CONFLICT (product_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM product_level_menus p
  WHERE p.product_id = p_product_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM product_level_menus s
      WHERE s.product_id = p_product_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO product_level_menu_items (
    product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT si.product_id, 'production', pm.id,
         CASE WHEN si.source_item_id IS NOT NULL THEN (
           SELECT svi.id FROM service_menu_items_defaults svi
           JOIN service_menus svm ON svm.id = svi.menu_id
           WHERE svm.service_id = v_service_id AND svm.environment = 'production'
             AND svm.menu_key = sm.menu_key AND svi.item_key = si.item_key
         ) END,
         si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM product_level_menu_items si
  JOIN product_level_menus sm ON sm.id = si.menu_id
  JOIN product_level_menus pm ON pm.product_id = p_product_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.product_id = p_product_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, label = EXCLUDED.label,
    url = EXCLUDED.url, icon = EXCLUDED.icon, display_order = EXCLUDED.display_order,
    parent_key = EXCLUDED.parent_key, visible = EXCLUDED.visible, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM product_level_menu_items p
  WHERE p.product_id = p_product_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM product_level_menu_items si
      JOIN product_level_menus sm ON sm.id = si.menu_id
      JOIN product_level_menus pm ON pm.id = p.menu_id
      WHERE si.product_id = p_product_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.promote_service_menus(p_service_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_menus int; v_items int;
BEGIN
  INSERT INTO service_menus (service_id, environment, menu_key, label, display_order)
  SELECT service_id, 'production', menu_key, label, display_order
  FROM service_menus
  WHERE service_id = p_service_id AND environment = 'staging'
  ON CONFLICT (service_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM service_menus p
  WHERE p.service_id = p_service_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM service_menus s
      WHERE s.service_id = p_service_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO service_menu_items_defaults (
    service_id, environment, menu_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT si.service_id, 'production', pm.id, si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM service_menu_items_defaults si
  JOIN service_menus sm ON sm.id = si.menu_id
  JOIN service_menus pm ON pm.service_id = p_service_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.service_id = p_service_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, label = EXCLUDED.label,
    url = EXCLUDED.url, icon = EXCLUDED.icon, display_order = EXCLUDED.display_order,
    parent_key = EXCLUDED.parent_key, visible = EXCLUDED.visible, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM service_menu_items_defaults p
  WHERE p.service_id = p_service_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM service_menu_items_defaults si
      JOIN service_menus sm ON sm.id = si.menu_id
      JOIN service_menus pm ON pm.id = p.menu_id
      WHERE si.service_id = p_service_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.propagate_product_level_menu()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
    SELECT pl.id, NEW.environment, NEW.menu_key, NEW.label, NEW.display_order, NEW.id
    FROM product_locales pl
    WHERE pl.product_id = NEW.product_id
    ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
      SET source_menu_id = EXCLUDED.source_menu_id
      WHERE product_menus.source_menu_id IS NULL;
  ELSIF (OLD.label, OLD.display_order) IS DISTINCT FROM (NEW.label, NEW.display_order) THEN
    UPDATE product_menus SET
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      updated_at = now()
    WHERE source_menu_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.propagate_product_level_menu_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO product_menu_items (
      product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
      label, url, icon, display_order, parent_key, visible
    )
    SELECT lm.product_locale_id, NEW.environment, lm.id, NEW.id, NEW.item_key, NEW.item_type, NEW.nested_menu_key,
           NEW.label, NEW.url, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible
    FROM product_menus lm
    WHERE lm.source_menu_id = NEW.menu_id
    ON CONFLICT (menu_id, item_key) DO UPDATE
      SET source_item_id = EXCLUDED.source_item_id
      WHERE product_menu_items.source_item_id IS NULL;
  ELSIF (OLD.item_type, OLD.url, OLD.nested_menu_key, OLD.label, OLD.icon, OLD.display_order, OLD.parent_key, OLD.visible)
        IS DISTINCT FROM
        (NEW.item_type, NEW.url, NEW.nested_menu_key, NEW.label, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible) THEN
    UPDATE product_menu_items SET
      item_type = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.item_type ELSE item_type END,
      url = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.url ELSE url END,
      nested_menu_key = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.nested_menu_key ELSE nested_menu_key END,
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      icon = CASE WHEN icon IS NOT DISTINCT FROM OLD.icon THEN NEW.icon ELSE icon END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      parent_key = CASE WHEN parent_key IS NOT DISTINCT FROM OLD.parent_key THEN NEW.parent_key ELSE parent_key END,
      visible = CASE WHEN visible IS NOT DISTINCT FROM OLD.visible THEN NEW.visible ELSE visible END,
      updated_at = now()
    WHERE source_item_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.propagate_service_menu()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
    SELECT p.id, NEW.environment, NEW.menu_key, NEW.label, NEW.display_order, NEW.id
    FROM products p
    WHERE p.service_id = NEW.service_id
    ON CONFLICT (product_id, environment, menu_key) DO UPDATE
      SET source_menu_id = EXCLUDED.source_menu_id
      WHERE product_level_menus.source_menu_id IS NULL;
  ELSIF (OLD.label, OLD.display_order) IS DISTINCT FROM (NEW.label, NEW.display_order) THEN
    UPDATE product_level_menus SET
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      updated_at = now()
    WHERE source_menu_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.propagate_service_menu_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO product_level_menu_items (
      product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
      label, url, icon, display_order, parent_key, visible
    )
    SELECT pm.product_id, NEW.environment, pm.id, NEW.id, NEW.item_key, NEW.item_type, NEW.nested_menu_key,
           NEW.label, NEW.url, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible
    FROM product_level_menus pm
    WHERE pm.source_menu_id = NEW.menu_id
    ON CONFLICT (menu_id, item_key) DO UPDATE
      SET source_item_id = EXCLUDED.source_item_id
      WHERE product_level_menu_items.source_item_id IS NULL;
  ELSIF (OLD.item_type, OLD.url, OLD.nested_menu_key, OLD.label, OLD.icon, OLD.display_order, OLD.parent_key, OLD.visible)
        IS DISTINCT FROM
        (NEW.item_type, NEW.url, NEW.nested_menu_key, NEW.label, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible) THEN
    UPDATE product_level_menu_items SET
      item_type = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.item_type ELSE item_type END,
      url = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.url ELSE url END,
      nested_menu_key = CASE WHEN (item_type, url, nested_menu_key) IS NOT DISTINCT FROM (OLD.item_type, OLD.url, OLD.nested_menu_key)
        THEN NEW.nested_menu_key ELSE nested_menu_key END,
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      icon = CASE WHEN icon IS NOT DISTINCT FROM OLD.icon THEN NEW.icon ELSE icon END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      parent_key = CASE WHEN parent_key IS NOT DISTINCT FROM OLD.parent_key THEN NEW.parent_key ELSE parent_key END,
      visible = CASE WHEN visible IS NOT DISTINCT FROM OLD.visible THEN NEW.visible ELSE visible END,
      updated_at = now()
    WHERE source_item_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.seed_locale_menus(p_locale_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  INSERT INTO product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT pl.id, pm.environment, pm.menu_key, pm.label, pm.display_order, pm.id
  FROM product_locales pl
  JOIN product_level_menus pm ON pm.product_id = pl.product_id
  WHERE pl.id = p_locale_id
  ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
    SET source_menu_id = EXCLUDED.source_menu_id
    WHERE product_menus.source_menu_id IS NULL;

  INSERT INTO product_menu_items (
    product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT lm.product_locale_id, pi.environment, lm.id, pi.id, pi.item_key, pi.item_type, pi.nested_menu_key,
         pi.label, pi.url, pi.icon, pi.display_order, pi.parent_key, pi.visible
  FROM product_level_menu_items pi
  JOIN product_menus lm ON lm.source_menu_id = pi.menu_id
  WHERE lm.product_locale_id = p_locale_id
  ON CONFLICT (menu_id, item_key) DO UPDATE
    SET source_item_id = EXCLUDED.source_item_id
    WHERE product_menu_items.source_item_id IS NULL;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.seed_product_level_menus(p_product_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  INSERT INTO product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT p.id, sm.environment, sm.menu_key, sm.label, sm.display_order, sm.id
  FROM products p
  JOIN service_menus sm ON sm.service_id = p.service_id
  WHERE p.id = p_product_id
  ON CONFLICT (product_id, environment, menu_key) DO UPDATE
    SET source_menu_id = EXCLUDED.source_menu_id
    WHERE product_level_menus.source_menu_id IS NULL;

  INSERT INTO product_level_menu_items (
    product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT pm.product_id, si.environment, pm.id, si.id, si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM service_menu_items_defaults si
  JOIN product_level_menus pm ON pm.source_menu_id = si.menu_id
  WHERE pm.product_id = p_product_id
  ON CONFLICT (menu_id, item_key) DO UPDATE
    SET source_item_id = EXCLUDED.source_item_id
    WHERE product_level_menu_items.source_item_id IS NULL;
END; $function$;

CREATE OR REPLACE FUNCTION backoffice.set_default_product(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE
  v_service_id uuid;
BEGIN
  IF NOT is_backoffice_role('editor') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT service_id INTO v_service_id
  FROM backoffice.products
  WHERE id = p_id;

  IF v_service_id IS NULL THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  UPDATE backoffice.products
  SET is_default = false
  WHERE service_id = v_service_id AND is_default = true;

  UPDATE backoffice.products
  SET is_default = true
  WHERE id = p_id;
END;
$function$;

CREATE OR REPLACE FUNCTION backoffice.set_default_product_locale(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE
  v_product_id uuid;
BEGIN
  IF NOT is_backoffice_role('editor') THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT product_id INTO v_product_id
  FROM backoffice.product_locales
  WHERE id = p_id;

  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'Product locale not found';
  END IF;

  UPDATE backoffice.product_locales
  SET is_default = false
  WHERE product_id = v_product_id AND is_default = true;

  UPDATE backoffice.product_locales
  SET is_default = true
  WHERE id = p_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Read-only public compatibility views (old bo_ names / app tables in public)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public."bo_app_screen_labels"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."app_screen_labels";
GRANT SELECT ON public."bo_app_screen_labels" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_app_screen_labels" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_app_screen_sections"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."app_screen_sections";
GRANT SELECT ON public."bo_app_screen_sections" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_app_screen_sections" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_app_screens"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."app_screens";
GRANT SELECT ON public."bo_app_screens" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_app_screens" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_atom_legal_documents"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."atom_legal_documents";
GRANT SELECT ON public."bo_atom_legal_documents" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_atom_legal_documents" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_backoffice_audit_log"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."backoffice_audit_log";
GRANT SELECT ON public."bo_backoffice_audit_log" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_backoffice_audit_log" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_backoffice_users"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."backoffice_users";
GRANT SELECT ON public."bo_backoffice_users" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_backoffice_users" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_locale_avatar"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."locale_avatar";
GRANT SELECT ON public."bo_locale_avatar" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_locale_avatar" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_locale_instant_games"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."locale_instant_games";
GRANT SELECT ON public."bo_locale_instant_games" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_locale_instant_games" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_page_behaviour_rules"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."page_behaviour_rules";
GRANT SELECT ON public."bo_page_behaviour_rules" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_page_behaviour_rules" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_page_behaviour_tier_rules"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."page_behaviour_tier_rules";
GRANT SELECT ON public."bo_page_behaviour_tier_rules" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_page_behaviour_tier_rules" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_assets"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_assets";
GRANT SELECT ON public."bo_product_assets" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_assets" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_avatar"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_avatar";
GRANT SELECT ON public."bo_product_avatar" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_avatar" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_branding"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_branding";
GRANT SELECT ON public."bo_product_branding" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_branding" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_branding_templates"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_branding_templates";
GRANT SELECT ON public."bo_product_branding_templates" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_branding_templates" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_content_consumption_rules"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_content_consumption_rules";
GRANT SELECT ON public."bo_product_content_consumption_rules" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_content_consumption_rules" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_document_versions"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_document_versions";
GRANT SELECT ON public."bo_product_document_versions" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_document_versions" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_documents"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_documents";
GRANT SELECT ON public."bo_product_documents" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_documents" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_feature_flags"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_feature_flags";
GRANT SELECT ON public."bo_product_feature_flags" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_feature_flags" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_footer_hidden_pages"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_footer_hidden_pages";
GRANT SELECT ON public."bo_product_footer_hidden_pages" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_footer_hidden_pages" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_footer_items"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_footer_items";
GRANT SELECT ON public."bo_product_footer_items" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_footer_items" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_instant_games"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_instant_games";
GRANT SELECT ON public."bo_product_instant_games" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_instant_games" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_level_assets"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_level_assets";
GRANT SELECT ON public."bo_product_level_assets" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_level_assets" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_level_branding_templates"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_level_branding_templates";
GRANT SELECT ON public."bo_product_level_branding_templates" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_level_branding_templates" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_level_menu_items"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_level_menu_items";
GRANT SELECT ON public."bo_product_level_menu_items" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_level_menu_items" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_level_menus"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_level_menus";
GRANT SELECT ON public."bo_product_level_menus" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_level_menus" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_level_social_links"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_level_social_links";
GRANT SELECT ON public."bo_product_level_social_links" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_level_social_links" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_locales"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_locales";
GRANT SELECT ON public."bo_product_locales" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_locales" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_login_methods"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_login_methods";
GRANT SELECT ON public."bo_product_login_methods" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_login_methods" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_menu_item_tiers"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_menu_item_tiers";
GRANT SELECT ON public."bo_product_menu_item_tiers" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_menu_item_tiers" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_menu_items"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_menu_items";
GRANT SELECT ON public."bo_product_menu_items" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_menu_items" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_menus"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_menus";
GRANT SELECT ON public."bo_product_menus" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_menus" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_packs"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_packs";
GRANT SELECT ON public."bo_product_packs" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_packs" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_secrets"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_secrets";
GRANT SELECT ON public."bo_product_secrets" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_secrets" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_signup_settings"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_signup_settings";
GRANT SELECT ON public."bo_product_signup_settings" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_signup_settings" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_social_links"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_social_links";
GRANT SELECT ON public."bo_product_social_links" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_social_links" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_translations"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_translations";
GRANT SELECT ON public."bo_product_translations" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_translations" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_product_unsubscribe_methods"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."product_unsubscribe_methods";
GRANT SELECT ON public."bo_product_unsubscribe_methods" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_product_unsubscribe_methods" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_products"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."products";
GRANT SELECT ON public."bo_products" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_products" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_assets_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_assets_defaults";
GRANT SELECT ON public."bo_service_assets_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_assets_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_avatar_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_avatar_defaults";
GRANT SELECT ON public."bo_service_avatar_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_avatar_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_branding_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_branding_defaults";
GRANT SELECT ON public."bo_service_branding_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_branding_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_branding_templates"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_branding_templates";
GRANT SELECT ON public."bo_service_branding_templates" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_branding_templates" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_feature_flags_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_feature_flags_defaults";
GRANT SELECT ON public."bo_service_feature_flags_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_feature_flags_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_footer_items_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_footer_items_defaults";
GRANT SELECT ON public."bo_service_footer_items_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_footer_items_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_instant_games_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_instant_games_defaults";
GRANT SELECT ON public."bo_service_instant_games_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_instant_games_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_login_methods_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_login_methods_defaults";
GRANT SELECT ON public."bo_service_login_methods_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_login_methods_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_menu_items_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_menu_items_defaults";
GRANT SELECT ON public."bo_service_menu_items_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_menu_items_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_menus"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_menus";
GRANT SELECT ON public."bo_service_menus" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_menus" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_social_links_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_social_links_defaults";
GRANT SELECT ON public."bo_service_social_links_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_social_links_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_service_translations_defaults"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."service_translations_defaults";
GRANT SELECT ON public."bo_service_translations_defaults" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_service_translations_defaults" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_services"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."services";
GRANT SELECT ON public."bo_services" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_services" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_translation_keys"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."translation_keys";
GRANT SELECT ON public."bo_translation_keys" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_translation_keys" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_translation_overrides"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."translation_overrides";
GRANT SELECT ON public."bo_translation_overrides" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_translation_overrides" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."bo_translation_sections"
  WITH (security_invoker = true)
  AS SELECT * FROM backoffice."translation_sections";
GRANT SELECT ON public."bo_translation_sections" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."bo_translation_sections" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.bo_product_public_config
  WITH (security_invoker = true)
AS
SELECT id, product_locale_id, environment, key, value, description, created_at, updated_at
FROM backoffice.product_public_config
WHERE product_locale_id IS NOT NULL;
GRANT SELECT ON public.bo_product_public_config TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.bo_product_public_config FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.bo_product_level_public_config
  WITH (security_invoker = true)
AS
SELECT id, product_id, environment, key, value, description, created_at, updated_at
FROM backoffice.product_public_config
WHERE product_id IS NOT NULL;
GRANT SELECT ON public.bo_product_level_public_config TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.bo_product_level_public_config FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.bo_service_public_config_defaults
  WITH (security_invoker = true)
AS
SELECT id, service_id, environment, key, value, description, created_at, updated_at
FROM backoffice.product_public_config
WHERE service_id IS NOT NULL;
GRANT SELECT ON public.bo_service_public_config_defaults TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.bo_service_public_config_defaults FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."profiles"
  WITH (security_invoker = true)
  AS SELECT * FROM application."profiles";
GRANT SELECT ON public."profiles" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."profiles" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."avatar_generations"
  WITH (security_invoker = true)
  AS SELECT * FROM application."avatar_generations";
GRANT SELECT ON public."avatar_generations" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."avatar_generations" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."badges"
  WITH (security_invoker = true)
  AS SELECT * FROM application."badges";
GRANT SELECT ON public."badges" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."badges" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."user_badges"
  WITH (security_invoker = true)
  AS SELECT * FROM application."user_badges";
GRANT SELECT ON public."user_badges" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."user_badges" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."quiz_attempts"
  WITH (security_invoker = true)
  AS SELECT * FROM application."quiz_attempts";
GRANT SELECT ON public."quiz_attempts" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."quiz_attempts" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."content_attempts"
  WITH (security_invoker = true)
  AS SELECT * FROM application."content_attempts";
GRANT SELECT ON public."content_attempts" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."content_attempts" FROM anon, authenticated, service_role;

CREATE OR REPLACE VIEW public."redeemed_reward_assets"
  WITH (security_invoker = true)
  AS SELECT * FROM application."redeemed_reward_assets";
GRANT SELECT ON public."redeemed_reward_assets" TO anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public."redeemed_reward_assets" FROM anon, authenticated, service_role;

-- Ensure table grants remain usable on physical schemas (copied from public baseline intent)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS schemaname, c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('backoffice', 'application') AND c.relkind = 'r'
  LOOP
    EXECUTE format('GRANT ALL ON TABLE %I.%I TO anon, authenticated, service_role', r.schemaname, r.tablename);
  END LOOP;
END $$;
