/*
# Baseline schema (v2) — schema-equivalent squash

Replaces v1 migration chain 20260609000001 … 20260826103700 (archived under
supabase/migrations_archive/v1/).

Generated from a local `supabase db reset` of the full v1 chain on Postgres 17,
then `supabase db dump --local --schema public`, plus:
  - required extensions (pgcrypto, pg_cron, pg_net, btree_gist)
  - storage.objects RLS policies from applied DB
  - realtime publication for avatar_generations

Data (tenants, live import, login-regex fix, admin users, storage buckets)
lives in supabase/seeds/ and is applied via [db.seed] on reset.

No intentional change to tables, RPCs, triggers, RLS, or storage policies
versus the v1 end-state.

Starter template additions:
  - bo_* tables and backoffice RPCs live in the `backoffice` schema (exposed to
    the Data API); web app data stays in `public`.
  - Menus, social links, translation sections/keys/overrides, branding templates
    and product-level config from the deno-dialog chain (up to
    20261008100000_menu_three_level_inheritance), plus its period-scoped
    points distribution in bo_product_dashboard. Kept from v1: avatar
    scheduling (no unique per locale/product/service), feature flags.
  - App Screens (screens, widgets, Label List, product timezone) and Atom legal
    documents (atom product ids, bo_atom_legal_documents, is_atom flags) from
    bravigo-migration 20261028120000_add_app_screens_and_atom_legal.
  - URL & Behaviour (docs/url-behaviour.md): page behaviour rules on Service,
    Product and Language (one owner, enabled, screen_slug), tier action
    "screen", viewer read / admin write RLS.
  - Login Methods (docs/login-methods.md): google and ios types, admin-only
    writes, product seed trigger as SECURITY DEFINER.
  - App Screens widget audience: bo_app_screen_sections.visible_to.
  - App Screens key change: backoffice.app_screen_rename_slug (atomic rename with
    URL & Behaviour, text namespace and widget ref cascade).
*/


CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';


-- Backoffice configuration tables (bo_*) live in their own schema, exposed to
-- the Data API: add `backoffice` to Settings -> API -> Exposed schemas.
-- Web app end-user data stays in public.
CREATE SCHEMA IF NOT EXISTS "backoffice";


ALTER SCHEMA "backoffice" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "backoffice" TO "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "backoffice" GRANT ALL ON TABLES TO "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "backoffice" GRANT ALL ON FUNCTIONS TO "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "backoffice" GRANT ALL ON SEQUENCES TO "anon", "authenticated", "service_role";



CREATE OR REPLACE FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT jsonb_build_object(
    'new_users', (SELECT count(*) FROM profiles WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to),
    'active_users', (
      SELECT count(DISTINCT x.user_id) FROM (
        SELECT user_id, created_at FROM quiz_attempts WHERE product_id = p_product_id
        UNION ALL SELECT user_id, created_at FROM content_attempts WHERE product_id = p_product_id
        UNION ALL SELECT user_id, created_at FROM user_activities WHERE product_id = p_product_id
        UNION ALL SELECT user_id, created_at FROM avatar_generations WHERE product_id = p_product_id
      ) x WHERE x.created_at >= p_from AND x.created_at < p_to
    ),
    'avatars', (SELECT count(*) FROM avatar_generations WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to),
    'badges', (SELECT count(*) FROM user_badges WHERE product_id = p_product_id AND earned_at >= p_from AND earned_at < p_to),
    'content_attempts', (
      (SELECT COALESCE(sum(attempt_count), 0) FROM content_attempts WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to)
      + (SELECT count(*) FROM quiz_attempts WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to)
    ),
    'redemptions', (SELECT count(*) FROM user_rewards WHERE product_id = p_product_id AND redeemed_at >= p_from AND redeemed_at < p_to),
    'points_earned', (
      (SELECT COALESCE(sum(points_earned), 0) FROM quiz_attempts WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to)
      + (SELECT COALESCE(sum(points_earned), 0) FROM user_activities WHERE product_id = p_product_id AND created_at >= p_from AND created_at < p_to)
    )
  );
$$;


ALTER FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assert_same_service"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  jwt_app_role text; jwt_service_id text; row_service_id uuid;
BEGIN
  BEGIN
    jwt_app_role := current_setting('request.jwt.claims', true)::jsonb->>'app_role';
    jwt_service_id := current_setting('request.jwt.claims', true)::jsonb->>'service_id';
  EXCEPTION WHEN OTHERS THEN RETURN NEW;
  END;
  IF jwt_app_role IS DISTINCT FROM 'app_user' THEN RETURN NEW; END IF;
  EXECUTE format('SELECT ($1).%I', 'service_id') INTO row_service_id USING NEW;
  IF row_service_id IS NULL THEN
    RAISE EXCEPTION 'service_id is required for app_user writes on table %', TG_TABLE_NAME USING ERRCODE = '42501';
  END IF;
  IF jwt_service_id IS NULL OR row_service_id::text <> jwt_service_id THEN
    RAISE EXCEPTION 'service_id mismatch: JWT=% row=%', jwt_service_id, row_service_id USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."assert_same_service"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."backoffice_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT role FROM backoffice.bo_backoffice_users
  WHERE user_id = auth.uid() AND is_active = true
  LIMIT 1;
$$;


ALTER FUNCTION "public"."backoffice_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION backoffice.bo_product_dashboard(p_product_id uuid, p_granularity text DEFAULT 'hour'::text, p_from timestamp with time zone DEFAULT (now() - '24:00:00'::interval), p_to timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE
  v_step interval;
  v_prev_from timestamptz;
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_role('viewer') THEN
    RAISE EXCEPTION 'Access denied: active backoffice user required';
  END IF;

  IF p_granularity NOT IN ('hour', 'day', 'week') THEN
    RAISE EXCEPTION 'Invalid granularity: must be hour, day or week';
  END IF;

  IF p_from >= p_to THEN
    RAISE EXCEPTION 'Invalid range: p_from must be before p_to';
  END IF;

  v_step := ('1 ' || p_granularity)::interval;
  v_prev_from := p_from - (p_to - p_from);

  SELECT jsonb_build_object(
    'range', jsonb_build_object(
      'from', p_from, 'to', p_to, 'granularity', p_granularity
    ),

    'kpis', (
      SELECT jsonb_build_object(
        'total_users', (SELECT count(*) FROM profiles WHERE product_id = p_product_id),
        'current', public._bo_dashboard_period_kpis(p_product_id, p_from, p_to),
        'previous', public._bo_dashboard_period_kpis(p_product_id, v_prev_from, p_from)
      )
    ),

    'series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'bucket', b,
        'new_users', (SELECT count(*) FROM profiles p WHERE p.product_id = p_product_id AND p.created_at >= b AND p.created_at < b + v_step),
        'active_users', (
          SELECT count(DISTINCT x.user_id) FROM (
            SELECT user_id, created_at FROM quiz_attempts WHERE product_id = p_product_id
            UNION ALL SELECT user_id, created_at FROM content_attempts WHERE product_id = p_product_id
            UNION ALL SELECT user_id, created_at FROM user_activities WHERE product_id = p_product_id
            UNION ALL SELECT user_id, created_at FROM avatar_generations WHERE product_id = p_product_id
          ) x WHERE x.created_at >= b AND x.created_at < b + v_step
        ),
        'avatars_completed', (SELECT count(*) FROM avatar_generations a WHERE a.product_id = p_product_id AND a.status = 'completed' AND a.created_at >= b AND a.created_at < b + v_step),
        'avatars_failed', (SELECT count(*) FROM avatar_generations a WHERE a.product_id = p_product_id AND a.status = 'failed' AND a.created_at >= b AND a.created_at < b + v_step),
        'avatars_pending', (SELECT count(*) FROM avatar_generations a WHERE a.product_id = p_product_id AND a.status NOT IN ('completed','failed') AND a.created_at >= b AND a.created_at < b + v_step),
        'badges', (SELECT count(*) FROM user_badges ub WHERE ub.product_id = p_product_id AND ub.earned_at >= b AND ub.earned_at < b + v_step),
        'quiz_attempts', (SELECT count(*) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= b AND q.created_at < b + v_step),
        'content_attempts', (SELECT COALESCE(sum(c.attempt_count), 0) FROM content_attempts c WHERE c.product_id = p_product_id AND c.created_at >= b AND c.created_at < b + v_step),
        'points_earned', (
          (SELECT COALESCE(sum(q.points_earned), 0) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= b AND q.created_at < b + v_step)
          + (SELECT COALESCE(sum(ua.points_earned), 0) FROM user_activities ua WHERE ua.product_id = p_product_id AND ua.created_at >= b AND ua.created_at < b + v_step)
        ),
        'points_redeemed', (SELECT COALESCE(sum(r.points_required), 0) FROM user_rewards ur JOIN rewards r ON r.id = ur.reward_id WHERE ur.product_id = p_product_id AND ur.redeemed_at >= b AND ur.redeemed_at < b + v_step),
        'redemptions', (SELECT count(*) FROM user_rewards ur WHERE ur.product_id = p_product_id AND ur.redeemed_at >= b AND ur.redeemed_at < b + v_step),
        'activities', (SELECT count(*) FROM user_activities ua WHERE ua.product_id = p_product_id AND ua.created_at >= b AND ua.created_at < b + v_step),
        'card_unlocks', (SELECT count(*) FROM user_cards uc WHERE uc.product_id = p_product_id AND uc.unlocked_at >= b AND uc.unlocked_at < b + v_step),
        'notifications', (SELECT count(*) FROM activity_notifications an WHERE an.product_id = p_product_id AND an.created_at >= b AND an.created_at < b + v_step)
      ) ORDER BY b), '[]'::jsonb)
      FROM generate_series(date_trunc(p_granularity, p_from), p_to - interval '1 microsecond', v_step) AS b
    ),

    'content_series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', t.b, 'type', t.ctype, 'count', t.cnt) ORDER BY t.b, t.ctype), '[]'::jsonb)
      FROM (
        SELECT date_trunc(p_granularity, c.created_at) AS b, c.content_type AS ctype, sum(c.attempt_count)::bigint AS cnt
        FROM content_attempts c
        WHERE c.product_id = p_product_id AND c.created_at >= p_from AND c.created_at < p_to
        GROUP BY 1, 2
        UNION ALL
        SELECT date_trunc(p_granularity, q.created_at), 'quiz', count(*)::bigint
        FROM quiz_attempts q
        WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to
        GROUP BY 1
      ) t
    ),

    'quiz', (
      SELECT jsonb_build_object(
        'attempts', COALESCE((SELECT count(*) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to), 0),
        'avg_score', (SELECT round(avg(q.score)::numeric, 1) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to),
        'accuracy', (SELECT round(100.0 * sum(q.correct_answers) / NULLIF(sum(q.total_questions), 0), 1) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to),
        'points_earned', COALESCE((SELECT sum(q.points_earned) FROM quiz_attempts q WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to), 0),
        'by_category', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'category', t.category, 'attempts', t.attempts, 'avg_score', t.avg_score,
            'accuracy', t.accuracy, 'points', t.points
          ) ORDER BY t.attempts DESC), '[]'::jsonb)
          FROM (
            SELECT COALESCE(q.category, 'uncategorised') AS category,
                   count(*) AS attempts,
                   round(avg(q.score)::numeric, 1) AS avg_score,
                   round(100.0 * sum(q.correct_answers) / NULLIF(sum(q.total_questions), 0), 1) AS accuracy,
                   COALESCE(sum(q.points_earned), 0) AS points
            FROM quiz_attempts q
            WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to
            GROUP BY 1
          ) t
        )
      )
    ),

    'avatar', (
      SELECT jsonb_build_object(
        'completed', count(*) FILTER (WHERE a.status = 'completed'),
        'failed', count(*) FILTER (WHERE a.status = 'failed'),
        'pending', count(*) FILTER (WHERE a.status NOT IN ('completed','failed')),
        'failure_reasons', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('reason', t.reason, 'count', t.cnt) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT COALESCE(NULLIF(trim(a2.error_message), ''), 'Unknown error') AS reason, count(*) AS cnt
            FROM avatar_generations a2
            WHERE a2.product_id = p_product_id AND a2.status = 'failed' AND a2.created_at >= p_from AND a2.created_at < p_to
            GROUP BY 1 ORDER BY 2 DESC LIMIT 6
          ) t
        )
      )
      FROM avatar_generations a
      WHERE a.product_id = p_product_id AND a.created_at >= p_from AND a.created_at < p_to
    ),

    'funnel', (
      SELECT jsonb_build_object(
        'registered', count(*),
        'onboarded', count(*) FILTER (WHERE p.onboarding_completed),
        'welcome_claimed', count(*) FILTER (WHERE p.welcome_bonus_claimed),
        'engaged', count(*) FILTER (WHERE p.total_points > 0),
        'redeemed', (SELECT count(DISTINCT ur.user_id) FROM user_rewards ur WHERE ur.product_id = p_product_id)
      )
      FROM profiles p
      WHERE p.product_id = p_product_id
    ),

    'rewards', (
      SELECT jsonb_build_object(
        'avg_points_cost', (
          SELECT round(avg(r.points_required)::numeric, 0)
          FROM user_rewards ur JOIN rewards r ON r.id = ur.reward_id
          WHERE ur.product_id = p_product_id AND ur.redeemed_at >= p_from AND ur.redeemed_at < p_to
        ),
        'top_redeemed', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', t.name, 'brand', t.brand, 'category', t.category,
            'points_required', t.points_required, 'count', t.cnt
          ) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT r.name, r.brand, r.category, r.points_required, count(*) AS cnt
            FROM user_rewards ur JOIN rewards r ON r.id = ur.reward_id
            WHERE ur.product_id = p_product_id AND ur.redeemed_at >= p_from AND ur.redeemed_at < p_to
            GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC LIMIT 8
          ) t
        ),
        'wishlist', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('name', t.name, 'brand', t.brand, 'count', t.cnt) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT r.name, r.brand, count(*) AS cnt
            FROM user_wishlist uw JOIN rewards r ON r.id = uw.reward_id
            WHERE uw.product_id = p_product_id
            GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 8
          ) t
        ),
        'brands', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('brand', t.brand, 'count', t.cnt) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT COALESCE(NULLIF(trim(rra.brand), ''), 'Unbranded') AS brand, count(*) AS cnt
            FROM redeemed_reward_assets rra
            JOIN profiles p ON p.id = rra.user_id
            WHERE p.product_id = p_product_id
            GROUP BY 1 ORDER BY 2 DESC LIMIT 8
          ) t
        )
      )
    ),

    'activities', (
      SELECT jsonb_build_object(
        'by_type', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('type', t.atype, 'count', t.cnt, 'points', t.points) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT ua.activity_type AS atype, count(*) AS cnt, COALESCE(sum(ua.points_earned), 0) AS points
            FROM user_activities ua
            WHERE ua.product_id = p_product_id AND ua.created_at >= p_from AND ua.created_at < p_to
            GROUP BY 1 ORDER BY 2 DESC LIMIT 10
          ) t
        ),
        'top_games', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.cnt, 'points', t.points) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT g.name, count(*) AS cnt, COALESCE(sum(ua.points_earned), 0) AS points
            FROM user_activities ua JOIN games g ON g.id = ua.game_id
            WHERE ua.product_id = p_product_id AND ua.created_at >= p_from AND ua.created_at < p_to
            GROUP BY 1 ORDER BY 2 DESC LIMIT 8
          ) t
        )
      )
    ),

    'cards', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'rarity', t.rarity, 'total_cards', t.total_cards,
        'unlocks', t.unlocks, 'unique_users', t.unique_users
      ) ORDER BY t.unlocks DESC), '[]'::jsonb)
      FROM (
        SELECT COALESCE(pc.rarity, 'common') AS rarity,
               count(DISTINCT pc.id) AS total_cards,
               count(uc.id) AS unlocks,
               count(DISTINCT uc.user_id) AS unique_users
        FROM player_cards pc
        LEFT JOIN user_cards uc ON uc.card_id = pc.id AND uc.product_id = p_product_id
        GROUP BY 1
      ) t
    ),

    'notifications', (
      SELECT jsonb_build_object(
        'total', count(*),
        'read_rate', round(100.0 * count(*) FILTER (WHERE an.is_read) / NULLIF(count(*), 0), 1),
        'by_type', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('type', t.ntype, 'count', t.cnt, 'read', t.read_cnt) ORDER BY t.cnt DESC), '[]'::jsonb)
          FROM (
            SELECT an2.type AS ntype, count(*) AS cnt, count(*) FILTER (WHERE an2.is_read) AS read_cnt
            FROM activity_notifications an2
            WHERE an2.product_id = p_product_id AND an2.created_at >= p_from AND an2.created_at < p_to
            GROUP BY 1 ORDER BY 2 DESC LIMIT 10
          ) t
        )
      )
      FROM activity_notifications an
      WHERE an.product_id = p_product_id AND an.created_at >= p_from AND an.created_at < p_to
    ),

    'points_distribution', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.label, 'users', t.users) ORDER BY t.ord), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN e.pts < 100 THEN '1-99'
            WHEN e.pts < 500 THEN '100-499'
            WHEN e.pts < 1000 THEN '500-999'
            WHEN e.pts < 5000 THEN '1k-5k'
            ELSE '5k+'
          END AS label,
          CASE
            WHEN e.pts < 100 THEN 1
            WHEN e.pts < 500 THEN 2
            WHEN e.pts < 1000 THEN 3
            WHEN e.pts < 5000 THEN 4
            ELSE 5
          END AS ord,
          count(*) AS users
        FROM (
          SELECT ev.user_id, sum(ev.pts) AS pts
          FROM (
            SELECT q.user_id, q.points_earned AS pts
            FROM quiz_attempts q
            WHERE q.product_id = p_product_id AND q.created_at >= p_from AND q.created_at < p_to
            UNION ALL
            SELECT ua.user_id, ua.points_earned
            FROM user_activities ua
            WHERE ua.product_id = p_product_id AND ua.created_at >= p_from AND ua.created_at < p_to
          ) ev
          GROUP BY ev.user_id
          HAVING sum(ev.pts) > 0
        ) e
        GROUP BY 1, 2
      ) t
    ),

    'badges_by_event', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('event', t.event_name, 'badge', t.badge_name, 'count', t.cnt) ORDER BY t.cnt DESC), '[]'::jsonb)
      FROM (
        SELECT COALESCE(se.name, 'No event') AS event_name, b.name AS badge_name, count(*) AS cnt
        FROM user_badges ub
        JOIN badges b ON b.id = ub.badge_id
        LEFT JOIN special_events se ON se.id = b.event_id
        WHERE ub.product_id = p_product_id
        GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 8
      ) t
    )
  ) INTO v_result;

  RETURN v_result;
END;
$function$;


ALTER FUNCTION "backoffice"."bo_product_dashboard"("p_product_id" "uuid", "p_granularity" "text", "p_from" timestamp with time zone, "p_to" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_locale_config_version"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  target_locale uuid; target_env text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_locale := OLD.product_locale_id; target_env := OLD.environment;
  ELSE
    target_locale := NEW.product_locale_id; target_env := NEW.environment;
  END IF;
  IF target_env = 'staging' THEN
    UPDATE backoffice.bo_product_locales
    SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE id = target_locale;
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.bo_product_locales
    SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE id = target_locale;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."bump_locale_config_version"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_nickname_available"("nickname_input" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE nickname = nickname_input AND service_id = public.jwt_service_id() AND id IS DISTINCT FROM auth.uid()
  );
END;
$$;


ALTER FUNCTION "public"."check_nickname_available"("nickname_input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_product_id_from_jwt"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  resolved_product_id uuid;

BEGIN
  resolved_product_id := public.jwt_product_id();

  IF resolved_product_id IS NOT NULL AND NEW.product_id IS NULL THEN
    NEW.product_id := resolved_product_id;

  END IF;

  RETURN NEW;

END;

$$;


ALTER FUNCTION "public"."fill_product_id_from_jwt"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_service_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.service_id IS NULL THEN
    NEW.service_id := public.jwt_service_id();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fill_service_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fill_service_id_from_jwt"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  resolved_service_id uuid;
BEGIN
  -- Use the already-patched jwt_service_id() which handles both token formats
  resolved_service_id := public.jwt_service_id();

  IF resolved_service_id IS NOT NULL AND NEW.service_id IS NULL THEN
    NEW.service_id := resolved_service_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fill_service_id_from_jwt"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_leaderboard"("limit_count" integer DEFAULT 10) RETURNS TABLE("user_id" "uuid", "nickname" "text", "avatar_url" "text", "total_earned" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT p.id AS user_id, p.nickname, p.avatar_url, COALESCE(SUM(ua.points_earned), 0) AS total_earned
  FROM public.profiles p
  LEFT JOIN public.user_activities ua ON ua.user_id = p.id AND ua.service_id = p.service_id
  WHERE p.service_id = public.jwt_service_id()
  GROUP BY p.id, p.nickname, p.avatar_url
  ORDER BY total_earned DESC LIMIT limit_count;
$$;


ALTER FUNCTION "public"."get_leaderboard"("limit_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_id_by_email"("p_email" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_user_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM backoffice.bo_backoffice_users
    WHERE user_id = auth.uid() AND is_active = true AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only active backoffice admins can look up users';
  END IF;
  SELECT id INTO v_user_id FROM auth.users WHERE email = p_email LIMIT 1;
  RETURN v_user_id;
END;
$$;


ALTER FUNCTION "public"."get_user_id_by_email"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_rank"("target_user_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(rank_position::integer, 1) FROM (
    SELECT p.id, RANK() OVER (ORDER BY COALESCE(SUM(ua.points_earned), 0) DESC) AS rank_position
    FROM public.profiles p
    LEFT JOIN public.user_activities ua ON ua.user_id = p.id AND ua.service_id = p.service_id
    WHERE p.service_id = public.jwt_service_id()
    GROUP BY p.id
  ) ranked WHERE ranked.id = target_user_id;
$$;


ALTER FUNCTION "public"."get_user_rank"("target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_backoffice_role"("required" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN required = 'viewer' THEN public.backoffice_role() IN ('viewer','editor','admin')
    WHEN required = 'editor' THEN public.backoffice_role() IN ('editor','admin')
    WHEN required = 'admin'  THEN public.backoffice_role() = 'admin'
    ELSE false
  END;
$$;


ALTER FUNCTION "public"."is_backoffice_role"("required" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."jwt_product_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT COALESCE(
    NULLIF(
      (current_setting('request.jwt.claims', true)::jsonb ->> 'product_id'), ''
    )::uuid,
    NULLIF(
      (current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'product_id'), ''
    )::uuid
  );

$$;


ALTER FUNCTION "public"."jwt_product_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."jwt_service_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT COALESCE(
    NULLIF(
      (current_setting('request.jwt.claims', true)::jsonb ->> 'service_id'), ''
    )::uuid,
    NULLIF(
      (current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'service_id'), ''
    )::uuid
  );
$$;


ALTER FUNCTION "public"."jwt_service_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_product_hostnames"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
  IF NEW.hostname_production IS NOT NULL THEN
    NEW.hostname_production := regexp_replace(regexp_replace(NEW.hostname_production, '^https?://', ''), '/+$', '');
  END IF;
  IF NEW.hostname_staging IS NOT NULL THEN
    NEW.hostname_staging := regexp_replace(regexp_replace(NEW.hostname_staging, '^https?://', ''), '/+$', '');
  END IF;
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."normalize_product_hostnames"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."publish_document_version"("p_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE v_doc_id uuid; v_product_id uuid;
BEGIN
  SELECT document_id INTO v_doc_id FROM backoffice.bo_product_document_versions WHERE id = p_version_id;
  IF v_doc_id IS NULL THEN RAISE EXCEPTION 'Version not found'; END IF;
  UPDATE backoffice.bo_product_document_versions SET published_at = now() WHERE id = p_version_id;
  UPDATE backoffice.bo_product_documents
  SET current_version_id = p_version_id, status = 'published', updated_at = now()
  WHERE id = v_doc_id RETURNING product_id INTO v_product_id;
  UPDATE backoffice.bo_product_locales
  SET config_version_production = config_version_production + 1,
      config_version_staging = config_version_staging + 1
  WHERE product_id = v_product_id;
END;
$$;


ALTER FUNCTION "public"."publish_document_version"("p_version_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_user_password"("target_user_id" "uuid", "new_password" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'auth', 'extensions', 'public'
    AS $$
BEGIN
  UPDATE auth.users
  SET encrypted_password = crypt(new_password, gen_salt('bf')), updated_at = now()
  WHERE id = target_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
END;
$$;


ALTER FUNCTION "public"."reset_user_password"("target_user_id" "uuid", "new_password" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_product_by_hostname"("p_hostname" "text", "p_environment" "text" DEFAULT 'production'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_domain record; v_locale record; v_product record; v_service record;
BEGIN
  SELECT * INTO v_domain FROM backoffice.bo_product_domains
  WHERE lower(hostname) = lower(p_hostname) AND environment = p_environment LIMIT 1;
  IF v_domain IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_locale FROM backoffice.bo_product_locales WHERE id = v_domain.product_locale_id;
  SELECT * INTO v_product FROM backoffice.bo_products WHERE id = v_locale.product_id;
  SELECT * INTO v_service FROM backoffice.bo_services WHERE id = v_product.service_id;
  RETURN jsonb_build_object(
    'service', to_jsonb(v_service), 'product', to_jsonb(v_product),
    'locale', to_jsonb(v_locale), 'domain', to_jsonb(v_domain), 'environment', p_environment
  );
END;
$$;


ALTER FUNCTION "public"."resolve_product_by_hostname"("p_hostname" "text", "p_environment" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_default_content_consumption_rules"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
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
  FOREACH _env IN ARRAY envs LOOP
    INSERT INTO backoffice.bo_product_login_methods
      (product_id, environment, type, enabled, is_default, display_order, allow_signup, config)
    VALUES (NEW.id, _env, 'msisdn_pin', true, true, 10, true,
      '{"allow_signup":true,"detection_hint":"auto","password_regex":"^(?=.*[A-Za-z])(?=.*\\d).{6,}$","password_min_length":6,"password_regex_flags":"","allow_forgot_password":true,"error_message_i18n_key":"login.combined.error"}'::jsonb)
    ON CONFLICT (product_id, environment, type) DO NOTHING;
  END LOOP;
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."seed_default_content_consumption_rules"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_profiles_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."touch_profiles_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_content_attempts_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."update_content_attempts_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_profile_points_on_quiz"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  UPDATE public.profiles
  SET total_points = COALESCE(total_points, 0) + NEW.points_earned,
      points_this_week = COALESCE(points_this_week, 0) + NEW.points_earned,
      updated_at = now()
  WHERE id = NEW.user_id AND service_id = NEW.service_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_profile_points_on_quiz"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."activity_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "points" integer,
    "is_read" boolean DEFAULT false,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."activity_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'viewer'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "admin_users_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'editor'::"text", 'viewer'::"text"])))
);


ALTER TABLE "public"."admin_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "key" "text" NOT NULL,
    "service_id" "uuid" NOT NULL,
    "value" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avatar_generations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "source_image_url" "text" DEFAULT ''::"text" NOT NULL,
    "favourite_team" "text" DEFAULT ''::"text",
    "relevance_job_id" "text" DEFAULT ''::"text",
    "relevance_studio_id" "text" DEFAULT ''::"text",
    "relevance_conversation_id" "text" DEFAULT ''::"text",
    "generated_avatar_url" "text",
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "theme" "text" DEFAULT ''::"text" NOT NULL,
    "event" "text",
    "card_mode" "text" DEFAULT 'common'::"text" NOT NULL,
    "provider" "text" DEFAULT 'relevance'::"text" NOT NULL,
    "openai_response_id" "text"
);


ALTER TABLE "public"."avatar_generations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."badges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "image_url" "text",
    "event_id" "uuid",
    "criteria" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL
);


ALTER TABLE "public"."badges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_backoffice_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_id" "uuid",
    "actor_email" "text" DEFAULT ''::"text",
    "action" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "service_id" "uuid",
    "product_id" "uuid",
    "product_locale_id" "uuid",
    "environment" "text",
    "diff" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_id" "text"
);


ALTER TABLE "backoffice"."bo_backoffice_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_backoffice_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "display_name" "text" DEFAULT ''::"text",
    "role" "text" DEFAULT 'viewer'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "service_scope" "text"[] DEFAULT '{}'::"text"[],
    "product_scope" "text"[] DEFAULT '{}'::"text"[],
    CONSTRAINT "backoffice_users_role_check" CHECK (("role" = ANY (ARRAY['viewer'::"text", 'editor'::"text", 'admin'::"text"])))
);


ALTER TABLE "backoffice"."bo_backoffice_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_locale_avatar" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "themes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "event" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "label" "text",
    "valid_from" timestamp with time zone,
    "valid_to" timestamp with time zone,
    "archived" boolean DEFAULT false NOT NULL,
    "configuration" "jsonb" DEFAULT '{}'::"jsonb",
    "enabled" boolean DEFAULT true NOT NULL,
    CONSTRAINT "locale_avatar_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_locale_avatar" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_locale_instant_games" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "game_type_id" integer NOT NULL,
    "template_name" "text" DEFAULT 'default'::"text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "preview_icon" "text",
    "enabled_from" timestamp with time zone,
    "enabled_to" timestamp with time zone,
    "assets" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "theme" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "locale_ig_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_locale_instant_games" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_page_behaviour_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "path" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text",
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "page_behaviour_rules_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_page_behaviour_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_page_behaviour_tier_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rule_id" "uuid" NOT NULL,
    "tier" "text" NOT NULL,
    "action" "text" DEFAULT 'none'::"text" NOT NULL,
    "redirect_url" "text",
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "page_behaviour_tier_rules_action_check" CHECK (("action" = ANY (ARRAY['none'::"text", 'redirect'::"text"]))),
    CONSTRAINT "page_behaviour_tier_rules_tier_check" CHECK (("tier" = ANY (ARRAY['guest'::"text", 'free'::"text", 'premium'::"text"])))
);


ALTER TABLE "backoffice"."bo_page_behaviour_tier_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "asset_key" "text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "mime_type" "text" DEFAULT ''::"text",
    "width" integer,
    "height" integer,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_assets_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_avatar" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "themes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "event" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "label" "text",
    "valid_from" timestamp with time zone,
    "valid_to" timestamp with time zone,
    "archived" boolean DEFAULT false NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "configuration" "jsonb" DEFAULT '{}'::"jsonb",
    CONSTRAINT "prod_avatar_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_avatar" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_branding" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "colors" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "gradients" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "fonts" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "radius" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "spacing" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "font_sizes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "font_weights" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "shadows" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_branding_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_branding" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_content_consumption_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "content_type" "text" NOT NULL,
    "tier" "text" NOT NULL,
    "action" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "rate_limit_enabled" boolean DEFAULT false NOT NULL,
    "tries_limit" integer,
    "frequency_period" "text",
    "frequency_unit_count" integer DEFAULT 1 NOT NULL,
    "on_limit_reached_action" "text",
    CONSTRAINT "bo_product_content_consumption_rules_frequency_period_check" CHECK ((("frequency_period" IS NULL) OR ("frequency_period" = ANY (ARRAY['day'::"text", 'week'::"text", 'month'::"text", 'lifetime'::"text"])))),
    CONSTRAINT "bo_product_content_consumption_rules_on_limit_reached_check" CHECK ((("on_limit_reached_action" IS NULL) OR ("on_limit_reached_action" = ANY (ARRAY['LOGIN'::"text", 'SUBSCRIBE'::"text", 'BLOCK'::"text"])))),
    CONSTRAINT "bo_product_content_consumption_rules_rate_limit_check" CHECK ((("rate_limit_enabled" = false) OR (("action" = 'PLAY'::"text") AND ("tries_limit" IS NOT NULL) AND ("tries_limit" > 0) AND ("frequency_period" IS NOT NULL) AND ("frequency_unit_count" >= 1) AND ("on_limit_reached_action" IS NOT NULL)))),
    CONSTRAINT "product_content_consumption_rules_action_check" CHECK (("action" = ANY (ARRAY['PLAY'::"text", 'LOGIN'::"text", 'SUBSCRIBE'::"text"]))),
    CONSTRAINT "product_content_consumption_rules_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"]))),
    CONSTRAINT "product_content_consumption_rules_tier_check" CHECK (("tier" = ANY (ARRAY['guest'::"text", 'free'::"text", 'premium'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_content_consumption_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_document_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "version" integer NOT NULL,
    "body_html" "text" DEFAULT ''::"text" NOT NULL,
    "body_markdown" "text",
    "body_json" "jsonb",
    "change_note" "text",
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_at" timestamp with time zone
);


ALTER TABLE "backoffice"."bo_product_document_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "locale" "text" NOT NULL,
    "path" "text" NOT NULL,
    "title" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "current_version_id" "uuid",
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "slug" "text" NOT NULL,
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "product_documents_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"]))),
    CONSTRAINT "product_documents_locale_check" CHECK (("locale" ~ '^[a-z]{2}(-[A-Z]{2})?$'::"text")),
    CONSTRAINT "product_documents_path_check" CHECK (("path" ~ '^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*$'::"text")),
    CONSTRAINT "product_documents_slug_check" CHECK (("slug" ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::"text")),
    CONSTRAINT "product_documents_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'archived'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_domains" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "hostname" "text" NOT NULL,
    "environment" "text" NOT NULL,
    "language_hint" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_domains_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_domains" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_feature_flags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "flag_key" "text" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_feature_flags_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_feature_flags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_footer_hidden_pages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "page_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "backoffice"."bo_product_footer_hidden_pages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_footer_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "item_key" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "icon" "text" DEFAULT ''::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "item_group" "text" DEFAULT ''::"text" NOT NULL,
    "visible" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "backoffice"."bo_product_footer_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_instant_games" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "game_type_id" integer NOT NULL,
    "template_name" "text" DEFAULT 'default'::"text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "preview_icon" "text",
    "enabled_from" timestamp with time zone,
    "enabled_to" timestamp with time zone,
    "assets" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "theme" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "prod_ig_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_instant_games" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_locales" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "language_code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "config_version_staging" bigint DEFAULT 1 NOT NULL,
    "config_version_production" bigint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "footer_columns_staging" integer DEFAULT 1 NOT NULL,
    "footer_columns_production" integer DEFAULT 1 NOT NULL,
    "locale_override" "text",
    CONSTRAINT "product_locales_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'archived'::"text", 'draft'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_locales" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_login_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "type" "text" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "display_order" integer DEFAULT 100 NOT NULL,
    "label_i18n_key" "text",
    "icon" "text",
    "allow_signup" boolean DEFAULT false NOT NULL,
    "feature_flag" "text",
    "min_app_version" "text",
    "max_app_version" "text",
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "signup_url" "text",
    CONSTRAINT "product_login_methods_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"]))),
    CONSTRAINT "product_login_methods_type_check" CHECK (("type" = ANY (ARRAY['email_password'::"text", 'msisdn_pin'::"text", 'otp'::"text", 'pinless'::"text", 'email_password_msisdn_pin'::"text", 'email_password_otp'::"text", 'email_password_pinless'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_login_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_menu_item_tiers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "menu_item_id" "uuid" NOT NULL,
    "tier" "text" NOT NULL,
    "visible" boolean DEFAULT true NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "locked_action" "text" DEFAULT 'none'::"text" NOT NULL,
    "route" "text",
    "external_url" "text",
    "label" "text",
    "label_i18n_key" "text",
    "badge_text" "text",
    "badge_color" "text",
    "display_order" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "product_menu_item_tiers_locked_action_check" CHECK (("locked_action" = ANY (ARRAY['none'::"text", 'upsell'::"text", 'login'::"text", 'toast'::"text"]))),
    CONSTRAINT "product_menu_item_tiers_tier_check" CHECK (("tier" = ANY (ARRAY['guest'::"text", 'free'::"text", 'premium'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_menu_item_tiers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "item_key" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "icon" "text" DEFAULT ''::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "parent_key" "text" DEFAULT ''::"text" NOT NULL,
    "visible" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "label_i18n_key" "text",
    "route" "text",
    "external_url" "text",
    "auth_required" boolean DEFAULT false NOT NULL,
    "min_app_version" "text",
    "max_app_version" "text",
    "feature_flag" "text",
    "badge_text" "text",
    "badge_color" "text",
    "icon_url" "text"
);


ALTER TABLE "backoffice"."bo_product_menu_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_public_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_public_config_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_public_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_secrets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_secrets_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_secrets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_translations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_locale_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "namespace" "text" DEFAULT 'common'::"text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_translations_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_translations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_product_unsubscribe_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "method" "text" DEFAULT 'standard'::"text" NOT NULL,
    "external_url" "text",
    "external_link_label" "text",
    "external_link_target" "text" DEFAULT 'browser'::"text",
    "avoided_reason_i18n_key" "text",
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirm_unsubscription" boolean DEFAULT false NOT NULL,
    "permanent_delete_after_unsub" boolean DEFAULT false NOT NULL,
    CONSTRAINT "product_unsubscribe_methods_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"]))),
    CONSTRAINT "product_unsubscribe_methods_external_link_target_check" CHECK ((("external_link_target" IS NULL) OR ("external_link_target" = ANY (ARRAY['browser'::"text", 'webview'::"text"])))),
    CONSTRAINT "product_unsubscribe_methods_method_check" CHECK (("method" = ANY (ARRAY['standard'::"text", 'external_link'::"text", 'avoided'::"text"])))
);


ALTER TABLE "backoffice"."bo_product_unsubscribe_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "slug" "text" NOT NULL,
    "display_name" "text" DEFAULT ''::"text" NOT NULL,
    "country_code" "text" DEFAULT ''::"text" NOT NULL,
    "is_global" boolean DEFAULT false NOT NULL,
    "native_bundle_id" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "hostname_staging" "text",
    "hostname_production" "text",
    "is_default" boolean DEFAULT false NOT NULL,
    CONSTRAINT "products_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'archived'::"text", 'draft'::"text"])))
);


ALTER TABLE "backoffice"."bo_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_assets_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "asset_key" "text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "mime_type" "text" DEFAULT ''::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "service_assets_defaults_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_assets_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_avatar_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "themes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "event" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "label" "text",
    "valid_from" timestamp with time zone,
    "valid_to" timestamp with time zone,
    "archived" boolean DEFAULT false NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "configuration" "jsonb" DEFAULT '{}'::"jsonb",
    CONSTRAINT "svc_avatar_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_avatar_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_branding_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "colors" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "gradients" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "fonts" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "radius" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "spacing" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "font_sizes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "font_weights" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "shadows" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "service_branding_defaults_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_branding_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_feature_flags_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "flag_key" "text" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "service_feature_flags_defaults_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_feature_flags_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_footer_items_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "item_key" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "icon" "text" DEFAULT ''::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "item_group" "text" DEFAULT ''::"text" NOT NULL,
    "visible" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "backoffice"."bo_service_footer_items_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_instant_games_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "game_type_id" integer NOT NULL,
    "template_name" "text" DEFAULT 'default'::"text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "preview_icon" "text",
    "enabled_from" timestamp with time zone,
    "enabled_to" timestamp with time zone,
    "assets" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "theme" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "svc_ig_env_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_instant_games_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_login_methods_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "method_key" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "backoffice"."bo_service_login_methods_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_menu_items_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" DEFAULT 'staging'::"text" NOT NULL,
    "item_key" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "url" "text" DEFAULT ''::"text" NOT NULL,
    "icon" "text" DEFAULT ''::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "parent_key" "text" DEFAULT ''::"text" NOT NULL,
    "visible" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "backoffice"."bo_service_menu_items_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_public_config_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "service_public_config_defaults_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_public_config_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_service_translations_defaults" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "language_code" "text" NOT NULL,
    "namespace" "text" DEFAULT 'common'::"text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "service_translations_defaults_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "backoffice"."bo_service_translations_defaults" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "backoffice"."bo_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "display_name" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "global_product_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "services_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'archived'::"text", 'draft'::"text"])))
);


ALTER TABLE "backoffice"."bo_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."content_attempts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content_type" "text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "period_start" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."content_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."content_consumption_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "environment" "text" NOT NULL,
    "content_type" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "content_consumption_rules_content_type_check" CHECK (("content_type" = ANY (ARRAY['game'::"text", 'video'::"text", 'audio'::"text", 'scratch_card'::"text", 'quiz'::"text", 'contest'::"text"]))),
    CONSTRAINT "content_consumption_rules_environment_check" CHECK (("environment" = ANY (ARRAY['staging'::"text", 'production'::"text"])))
);


ALTER TABLE "public"."content_consumption_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."content_consumption_tier_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rule_id" "uuid" NOT NULL,
    "tier" "text" NOT NULL,
    "action" "text" DEFAULT 'PLAY'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "content_consumption_tier_rules_action_check" CHECK (("action" = ANY (ARRAY['PLAY'::"text", 'LOGIN'::"text", 'SUBSCRIBE'::"text"]))),
    CONSTRAINT "content_consumption_tier_rules_tier_check" CHECK (("tier" = ANY (ARRAY['guest'::"text", 'free'::"text", 'premium'::"text"])))
);


ALTER TABLE "public"."content_consumption_tier_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."games" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "type" "text" NOT NULL,
    "points_reward" integer NOT NULL,
    "image_url" "text",
    "config" "jsonb",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL,
    CONSTRAINT "games_type_check" CHECK (("type" = ANY (ARRAY['instant'::"text", 'mini'::"text", 'quiz'::"text", 'html5'::"text", 'daily'::"text", 'weekly'::"text"])))
);


ALTER TABLE "public"."games" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "image_url" "text",
    "rarity" "text" NOT NULL,
    "unlock_requirement" "text",
    "points_required" integer DEFAULT 0,
    "order_index" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL,
    CONSTRAINT "player_cards_rarity_check" CHECK (("rarity" = ANY (ARRAY['common'::"text", 'rare'::"text", 'epic'::"text", 'legendary'::"text"])))
);


ALTER TABLE "public"."player_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "nickname" "text" NOT NULL,
    "avatar_url" "text",
    "total_points" integer DEFAULT 0,
    "points_this_week" integer DEFAULT 0,
    "points_expiry" timestamp with time zone DEFAULT ("now"() + '90 days'::interval),
    "rank_position" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "onboarding_completed" boolean DEFAULT false,
    "preferences" "jsonb" DEFAULT '{}'::"jsonb",
    "avatar_traits" "jsonb" DEFAULT '{"style": "casual", "gender": "neutral", "interests": [], "accessories": [], "personality": []}'::"jsonb",
    "badge_name" "text" DEFAULT 'Rookie'::"text",
    "welcome_bonus_claimed" boolean DEFAULT false,
    "last_scratch_card_view" timestamp with time zone,
    "service_id" "uuid",
    "first_name" "text" DEFAULT ''::"text" NOT NULL,
    "last_name" "text" DEFAULT ''::"text" NOT NULL,
    "email" "text" DEFAULT ''::"text" NOT NULL,
    "birth_date" "text" DEFAULT ''::"text" NOT NULL,
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pulsar_quiz_cache" (
    "cache_key" "text" NOT NULL,
    "service_id" "uuid" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "provider_env" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL
);


ALTER TABLE "public"."pulsar_quiz_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_attempts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "category" "text" NOT NULL,
    "score" integer DEFAULT 0 NOT NULL,
    "total_questions" integer NOT NULL,
    "correct_answers" integer NOT NULL,
    "points_earned" integer DEFAULT 0 NOT NULL,
    "completed_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "pulsar_quiz_id" integer,
    "pulsar_category_id" integer,
    "service_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."quiz_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."redeemed_reward_assets" (
    "user_id" "uuid" NOT NULL,
    "article_id" "text" NOT NULL,
    "thumbnail_url" "text",
    "name" "text",
    "brand" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."redeemed_reward_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rewards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "points_required" integer NOT NULL,
    "category" "text" NOT NULL,
    "image_url" "text",
    "brand" "text",
    "available" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL,
    CONSTRAINT "rewards_category_check" CHECK (("category" = ANY (ARRAY['voucher'::"text", 'ecard'::"text", 'topup'::"text"])))
);


ALTER TABLE "public"."rewards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."special_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "start_date" timestamp with time zone NOT NULL,
    "end_date" timestamp with time zone NOT NULL,
    "image_url" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid" NOT NULL
);


ALTER TABLE "public"."special_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "activity_type" "text" NOT NULL,
    "points_earned" integer NOT NULL,
    "description" "text",
    "game_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_badges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "badge_id" "uuid" NOT NULL,
    "earned_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_badges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "card_id" "uuid" NOT NULL,
    "unlocked_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_rewards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "reward_id" "uuid" NOT NULL,
    "redeemed_at" timestamp with time zone DEFAULT "now"(),
    "code" "text",
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_rewards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_wishlist" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "reward_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"(),
    "service_id" "uuid",
    "product_id" "uuid" NOT NULL
);


ALTER TABLE "public"."user_wishlist" OWNER TO "postgres";


ALTER TABLE ONLY "public"."activity_notifications"
    ADD CONSTRAINT "activity_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_users"
    ADD CONSTRAINT "admin_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("service_id", "key");



ALTER TABLE ONLY "public"."avatar_generations"
    ADD CONSTRAINT "avatar_generations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."badges"
    ADD CONSTRAINT "badges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_backoffice_audit_log"
    ADD CONSTRAINT "bo_backoffice_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_backoffice_users"
    ADD CONSTRAINT "bo_backoffice_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_locale_avatar"
    ADD CONSTRAINT "bo_locale_avatar_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_locale_instant_games"
    ADD CONSTRAINT "bo_locale_instant_games_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_page_behaviour_rules"
    ADD CONSTRAINT "bo_page_behaviour_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_page_behaviour_tier_rules"
    ADD CONSTRAINT "bo_page_behaviour_tier_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_assets"
    ADD CONSTRAINT "bo_product_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_avatar"
    ADD CONSTRAINT "bo_product_avatar_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_branding"
    ADD CONSTRAINT "bo_product_branding_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_content_consumption_rules"
    ADD CONSTRAINT "bo_product_content_consumption_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_document_versions"
    ADD CONSTRAINT "bo_product_document_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_documents"
    ADD CONSTRAINT "bo_product_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_domains"
    ADD CONSTRAINT "bo_product_domains_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_feature_flags"
    ADD CONSTRAINT "bo_product_feature_flags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_footer_hidden_pages"
    ADD CONSTRAINT "bo_product_footer_hidden_pages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_footer_items"
    ADD CONSTRAINT "bo_product_footer_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_instant_games"
    ADD CONSTRAINT "bo_product_instant_games_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_locales"
    ADD CONSTRAINT "bo_product_locales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_login_methods"
    ADD CONSTRAINT "bo_product_login_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_menu_item_tiers"
    ADD CONSTRAINT "bo_product_menu_item_tiers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_menu_items"
    ADD CONSTRAINT "bo_product_menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_public_config"
    ADD CONSTRAINT "bo_product_public_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_secrets"
    ADD CONSTRAINT "bo_product_secrets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_translations"
    ADD CONSTRAINT "bo_product_translations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_unsubscribe_methods"
    ADD CONSTRAINT "bo_product_unsubscribe_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_products"
    ADD CONSTRAINT "bo_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_assets_defaults"
    ADD CONSTRAINT "bo_service_assets_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_avatar_defaults"
    ADD CONSTRAINT "bo_service_avatar_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_branding_defaults"
    ADD CONSTRAINT "bo_service_branding_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_feature_flags_defaults"
    ADD CONSTRAINT "bo_service_feature_flags_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_footer_items_defaults"
    ADD CONSTRAINT "bo_service_footer_items_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_instant_games_defaults"
    ADD CONSTRAINT "bo_service_instant_games_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_login_methods_defaults"
    ADD CONSTRAINT "bo_service_login_methods_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_menu_items_defaults"
    ADD CONSTRAINT "bo_service_menu_items_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_public_config_defaults"
    ADD CONSTRAINT "bo_service_public_config_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_translations_defaults"
    ADD CONSTRAINT "bo_service_translations_defaults_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_services"
    ADD CONSTRAINT "bo_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."content_attempts"
    ADD CONSTRAINT "content_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."content_consumption_rules"
    ADD CONSTRAINT "content_consumption_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."content_consumption_tier_rules"
    ADD CONSTRAINT "content_consumption_tier_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."games"
    ADD CONSTRAINT "games_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_locale_avatar"
    ADD CONSTRAINT "locale_avatar_no_overlap" EXCLUDE USING "gist" ("product_locale_id" WITH =, "environment" WITH =, "tstzrange"(COALESCE("valid_from", '-infinity'::timestamp with time zone), COALESCE("valid_to", 'infinity'::timestamp with time zone), '[]'::"text") WITH &&) WHERE ((NOT "archived"));



ALTER TABLE ONLY "public"."player_cards"
    ADD CONSTRAINT "player_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_product_avatar"
    ADD CONSTRAINT "prod_avatar_no_overlap" EXCLUDE USING "gist" ("product_id" WITH =, "environment" WITH =, "tstzrange"(COALESCE("valid_from", '-infinity'::timestamp with time zone), COALESCE("valid_to", 'infinity'::timestamp with time zone), '[]'::"text") WITH &&) WHERE ((NOT "archived"));



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_service_product_unique" UNIQUE ("id", "service_id", "product_id");



ALTER TABLE ONLY "public"."pulsar_quiz_cache"
    ADD CONSTRAINT "pulsar_quiz_cache_pkey" PRIMARY KEY ("cache_key");



ALTER TABLE ONLY "public"."quiz_attempts"
    ADD CONSTRAINT "quiz_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."redeemed_reward_assets"
    ADD CONSTRAINT "redeemed_reward_assets_pkey" PRIMARY KEY ("user_id", "article_id");



ALTER TABLE ONLY "public"."rewards"
    ADD CONSTRAINT "rewards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."special_events"
    ADD CONSTRAINT "special_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "backoffice"."bo_service_avatar_defaults"
    ADD CONSTRAINT "svc_avatar_no_overlap" EXCLUDE USING "gist" ("service_id" WITH =, "environment" WITH =, "tstzrange"(COALESCE("valid_from", '-infinity'::timestamp with time zone), COALESCE("valid_to", 'infinity'::timestamp with time zone), '[]'::"text") WITH &&) WHERE ((NOT "archived"));



ALTER TABLE ONLY "public"."user_activities"
    ADD CONSTRAINT "user_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_cards"
    ADD CONSTRAINT "user_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_rewards"
    ADD CONSTRAINT "user_rewards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_wishlist"
    ADD CONSTRAINT "user_wishlist_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "admin_users_user_id_key" ON "public"."admin_users" USING "btree" ("user_id");



CREATE INDEX "bo_audit_log_created_idx" ON "backoffice"."bo_backoffice_audit_log" USING "btree" ("created_at" DESC);



CREATE INDEX "bo_audit_log_service_idx" ON "backoffice"."bo_backoffice_audit_log" USING "btree" ("service_id");



CREATE UNIQUE INDEX "bo_backoffice_users_user_id_key" ON "backoffice"."bo_backoffice_users" USING "btree" ("user_id");



CREATE INDEX "bo_idx_audit_log_session_id" ON "backoffice"."bo_backoffice_audit_log" USING "btree" ("session_id") WHERE ("session_id" IS NOT NULL);



CREATE INDEX "bo_idx_product_document_versions_doc" ON "backoffice"."bo_product_document_versions" USING "btree" ("document_id", "version" DESC);



CREATE INDEX "bo_idx_product_documents_product_locale" ON "backoffice"."bo_product_documents" USING "btree" ("product_id", "locale");



CREATE UNIQUE INDEX "bo_idx_products_one_default_per_service" ON "backoffice"."bo_products" USING "btree" ("service_id") WHERE ("is_default" = true);



CREATE UNIQUE INDEX "bo_locale_ig_unique" ON "backoffice"."bo_locale_instant_games" USING "btree" ("product_locale_id", "environment", "game_type_id", "template_name");



CREATE UNIQUE INDEX "bo_page_behaviour_rules_product_id_environment_path_key" ON "backoffice"."bo_page_behaviour_rules" USING "btree" ("product_id", "environment", "path");



CREATE UNIQUE INDEX "bo_page_behaviour_tier_rules_rule_id_tier_key" ON "backoffice"."bo_page_behaviour_tier_rules" USING "btree" ("rule_id", "tier");



CREATE UNIQUE INDEX "bo_prod_ig_unique" ON "backoffice"."bo_product_instant_games" USING "btree" ("product_id", "environment", "game_type_id", "template_name");



CREATE INDEX "bo_product_assets_locale_env_idx" ON "backoffice"."bo_product_assets" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_assets_product_locale_id_environment_asset_key_key" ON "backoffice"."bo_product_assets" USING "btree" ("product_locale_id", "environment", "asset_key");



CREATE UNIQUE INDEX "bo_product_branding_product_locale_id_environment_key" ON "backoffice"."bo_product_branding" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_content_consumption_r_product_id_environment_conten_" ON "backoffice"."bo_product_content_consumption_rules" USING "btree" ("product_id", "environment", "content_type", "tier");



CREATE UNIQUE INDEX "bo_product_document_versions_document_id_version_key" ON "backoffice"."bo_product_document_versions" USING "btree" ("document_id", "version");



CREATE UNIQUE INDEX "bo_product_documents_product_locale_path_env_key" ON "backoffice"."bo_product_documents" USING "btree" ("product_id", "locale", "path", "environment");



CREATE UNIQUE INDEX "bo_product_documents_product_slug_locale_env_key" ON "backoffice"."bo_product_documents" USING "btree" ("product_id", "slug", "locale", "environment");



CREATE UNIQUE INDEX "bo_product_domains_hostname_environment_key" ON "backoffice"."bo_product_domains" USING "btree" ("hostname", "environment");



CREATE INDEX "bo_product_domains_hostname_idx" ON "backoffice"."bo_product_domains" USING "btree" ("hostname");



CREATE INDEX "bo_product_domains_locale_idx" ON "backoffice"."bo_product_domains" USING "btree" ("product_locale_id");



CREATE INDEX "bo_product_feature_flags_locale_env_idx" ON "backoffice"."bo_product_feature_flags" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_feature_flags_product_locale_id_environment_flag_ke_" ON "backoffice"."bo_product_feature_flags" USING "btree" ("product_locale_id", "environment", "flag_key");



CREATE UNIQUE INDEX "bo_product_footer_items_product_locale_id_environment_item_key_" ON "backoffice"."bo_product_footer_items" USING "btree" ("product_locale_id", "environment", "item_key");



CREATE UNIQUE INDEX "bo_product_locales_product_id_language_code_key" ON "backoffice"."bo_product_locales" USING "btree" ("product_id", "language_code");



CREATE INDEX "bo_product_locales_product_idx" ON "backoffice"."bo_product_locales" USING "btree" ("product_id");



CREATE UNIQUE INDEX "bo_product_login_methods_product_id_environment_type_key" ON "backoffice"."bo_product_login_methods" USING "btree" ("product_id", "environment", "type");



CREATE UNIQUE INDEX "bo_product_menu_item_tiers_menu_item_id_tier_key" ON "backoffice"."bo_product_menu_item_tiers" USING "btree" ("menu_item_id", "tier");




CREATE INDEX "bo_product_public_config_locale_env_idx" ON "backoffice"."bo_product_public_config" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_public_config_product_locale_id_environment_key_key" ON "backoffice"."bo_product_public_config" USING "btree" ("product_locale_id", "environment", "key");



CREATE INDEX "bo_product_secrets_locale_env_idx" ON "backoffice"."bo_product_secrets" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_secrets_product_locale_id_environment_key_key" ON "backoffice"."bo_product_secrets" USING "btree" ("product_locale_id", "environment", "key");



CREATE INDEX "bo_product_translations_locale_env_idx" ON "backoffice"."bo_product_translations" USING "btree" ("product_locale_id", "environment");



CREATE UNIQUE INDEX "bo_product_translations_product_locale_id_environment_namespac_" ON "backoffice"."bo_product_translations" USING "btree" ("product_locale_id", "environment", "namespace", "key");



CREATE UNIQUE INDEX "bo_product_unsubscribe_methods_product_id_environment_key" ON "backoffice"."bo_product_unsubscribe_methods" USING "btree" ("product_id", "environment");



CREATE INDEX "bo_products_country_idx" ON "backoffice"."bo_products" USING "btree" ("country_code");



CREATE INDEX "bo_products_service_id_idx" ON "backoffice"."bo_products" USING "btree" ("service_id");



CREATE UNIQUE INDEX "bo_products_service_id_slug_key" ON "backoffice"."bo_products" USING "btree" ("service_id", "slug");



CREATE UNIQUE INDEX "bo_service_assets_defaults_service_id_environment_asset_key_key" ON "backoffice"."bo_service_assets_defaults" USING "btree" ("service_id", "environment", "asset_key");



CREATE UNIQUE INDEX "bo_service_branding_defaults_service_id_environment_key" ON "backoffice"."bo_service_branding_defaults" USING "btree" ("service_id", "environment");



CREATE UNIQUE INDEX "bo_service_feature_flags_default_service_id_environment_flag_k_" ON "backoffice"."bo_service_feature_flags_defaults" USING "btree" ("service_id", "environment", "flag_key");



CREATE UNIQUE INDEX "bo_service_footer_items_defaults_service_id_environment_item_k_" ON "backoffice"."bo_service_footer_items_defaults" USING "btree" ("service_id", "environment", "item_key");



CREATE UNIQUE INDEX "bo_service_login_methods_default_service_id_environment_method_" ON "backoffice"."bo_service_login_methods_defaults" USING "btree" ("service_id", "environment", "method_key");




CREATE UNIQUE INDEX "bo_service_public_config_defaults_service_id_environment_key_ke" ON "backoffice"."bo_service_public_config_defaults" USING "btree" ("service_id", "environment", "key");



CREATE UNIQUE INDEX "bo_service_translations_defaults_service_id_environment_langua_" ON "backoffice"."bo_service_translations_defaults" USING "btree" ("service_id", "environment", "language_code", "namespace", "key");



CREATE UNIQUE INDEX "bo_services_slug_key" ON "backoffice"."bo_services" USING "btree" ("slug");



CREATE UNIQUE INDEX "bo_svc_ig_defaults_unique" ON "backoffice"."bo_service_instant_games_defaults" USING "btree" ("service_id", "environment", "game_type_id", "template_name");



CREATE UNIQUE INDEX "bo_unique_hidden_page_per_locale_env" ON "backoffice"."bo_product_footer_hidden_pages" USING "btree" ("product_locale_id", "environment", "page_path");



CREATE UNIQUE INDEX "content_attempts_user_content_service_product_unique" ON "public"."content_attempts" USING "btree" ("user_id", "content_type", "service_id", "product_id");



CREATE UNIQUE INDEX "content_consumption_rules_product_id_environment_content_ty_key" ON "public"."content_consumption_rules" USING "btree" ("product_id", "environment", "content_type");



CREATE UNIQUE INDEX "content_consumption_tier_rules_rule_id_tier_key" ON "public"."content_consumption_tier_rules" USING "btree" ("rule_id", "tier");



CREATE INDEX "idx_activity_notifications_is_read" ON "public"."activity_notifications" USING "btree" ("user_id", "is_read", "created_at" DESC);



CREATE INDEX "idx_activity_notifications_lookup" ON "public"."activity_notifications" USING "btree" ("service_id", "user_id", "created_at" DESC);



CREATE INDEX "idx_activity_notifications_product_id" ON "public"."activity_notifications" USING "btree" ("product_id");



CREATE INDEX "idx_activity_notifications_user_created" ON "public"."activity_notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_avatar_generations_product_id" ON "public"."avatar_generations" USING "btree" ("product_id");



CREATE INDEX "idx_avatar_generations_provider" ON "public"."avatar_generations" USING "btree" ("provider");



CREATE INDEX "idx_avatar_generations_status" ON "public"."avatar_generations" USING "btree" ("status");



CREATE INDEX "idx_avatar_generations_user_id" ON "public"."avatar_generations" USING "btree" ("user_id");



CREATE INDEX "idx_badges_service" ON "public"."badges" USING "btree" ("service_id");



CREATE INDEX "idx_content_attempts_product_id" ON "public"."content_attempts" USING "btree" ("product_id");



CREATE INDEX "idx_content_attempts_service_id" ON "public"."content_attempts" USING "btree" ("service_id");



CREATE INDEX "idx_games_service" ON "public"."games" USING "btree" ("service_id", "active", "type");



CREATE INDEX "idx_games_type" ON "public"."games" USING "btree" ("type");



CREATE INDEX "idx_locale_avatar_lookup" ON "backoffice"."bo_locale_avatar" USING "btree" ("product_locale_id", "environment");



CREATE INDEX "idx_player_cards_service" ON "public"."player_cards" USING "btree" ("service_id", "order_index");



CREATE INDEX "idx_product_avatar_lookup" ON "backoffice"."bo_product_avatar" USING "btree" ("product_id", "environment");



CREATE INDEX "idx_profiles_product_id" ON "public"."profiles" USING "btree" ("product_id");



CREATE INDEX "idx_profiles_service_id" ON "public"."profiles" USING "btree" ("service_id");



CREATE INDEX "idx_profiles_total_points" ON "public"."profiles" USING "btree" ("total_points" DESC);



CREATE INDEX "idx_pulsar_quiz_cache_expires" ON "public"."pulsar_quiz_cache" USING "btree" ("expires_at");



CREATE INDEX "idx_quiz_attempts_category" ON "public"."quiz_attempts" USING "btree" ("category");



CREATE INDEX "idx_quiz_attempts_completed_at" ON "public"."quiz_attempts" USING "btree" ("completed_at" DESC);



CREATE INDEX "idx_quiz_attempts_product_id" ON "public"."quiz_attempts" USING "btree" ("product_id");



CREATE INDEX "idx_quiz_attempts_user_id" ON "public"."quiz_attempts" USING "btree" ("user_id");



CREATE INDEX "idx_rewards_category" ON "public"."rewards" USING "btree" ("category");



CREATE INDEX "idx_rewards_service" ON "public"."rewards" USING "btree" ("service_id", "available", "category");



CREATE INDEX "idx_special_events_service" ON "public"."special_events" USING "btree" ("service_id", "active", "end_date" DESC);



CREATE INDEX "idx_svc_avatar_defaults_lookup" ON "backoffice"."bo_service_avatar_defaults" USING "btree" ("service_id", "environment");



CREATE INDEX "idx_user_activities_created_at" ON "public"."user_activities" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_user_activities_product_id" ON "public"."user_activities" USING "btree" ("product_id");



CREATE INDEX "idx_user_activities_service_id" ON "public"."user_activities" USING "btree" ("service_id");



CREATE INDEX "idx_user_activities_user_id" ON "public"."user_activities" USING "btree" ("user_id");



CREATE INDEX "idx_user_badges_product_id" ON "public"."user_badges" USING "btree" ("product_id");



CREATE INDEX "idx_user_badges_service_id" ON "public"."user_badges" USING "btree" ("service_id");



CREATE INDEX "idx_user_badges_user_id" ON "public"."user_badges" USING "btree" ("user_id");



CREATE INDEX "idx_user_cards_product_id" ON "public"."user_cards" USING "btree" ("product_id");



CREATE INDEX "idx_user_cards_user_id" ON "public"."user_cards" USING "btree" ("user_id");



CREATE INDEX "idx_user_rewards_product_id" ON "public"."user_rewards" USING "btree" ("product_id");



CREATE INDEX "idx_user_rewards_service_id" ON "public"."user_rewards" USING "btree" ("service_id");



CREATE INDEX "idx_user_wishlist_product_id" ON "public"."user_wishlist" USING "btree" ("product_id");



CREATE INDEX "idx_user_wishlist_user_id" ON "public"."user_wishlist" USING "btree" ("user_id");



CREATE UNIQUE INDEX "profiles_nickname_key" ON "public"."profiles" USING "btree" ("nickname");



CREATE UNIQUE INDEX "user_badges_user_id_badge_id_key" ON "public"."user_badges" USING "btree" ("user_id", "badge_id");



CREATE UNIQUE INDEX "user_cards_user_id_card_id_key" ON "public"."user_cards" USING "btree" ("user_id", "card_id");



CREATE UNIQUE INDEX "user_wishlist_user_id_reward_id_key" ON "public"."user_wishlist" USING "btree" ("user_id", "reward_id");



CREATE OR REPLACE TRIGGER "assert_same_service_trg" BEFORE INSERT OR UPDATE ON "public"."user_activities" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "assert_same_service_trg" BEFORE INSERT OR UPDATE ON "public"."user_badges" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "assert_same_service_trg" BEFORE INSERT OR UPDATE ON "public"."user_cards" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "assert_same_service_trg" BEFORE INSERT OR UPDATE ON "public"."user_rewards" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "assert_same_service_trg" BEFORE INSERT OR UPDATE ON "public"."user_wishlist" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "product_assets_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_assets" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "product_branding_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_branding" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "product_feature_flags_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_feature_flags" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "product_public_config_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_public_config" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "product_secrets_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_secrets" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "product_translations_bump_version" AFTER INSERT OR DELETE OR UPDATE ON "backoffice"."bo_product_translations" FOR EACH ROW EXECUTE FUNCTION "public"."bump_locale_config_version"();



CREATE OR REPLACE TRIGGER "trg_activity_notifications_assert_service" BEFORE INSERT OR UPDATE ON "public"."activity_notifications" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_activity_notifications_fill_product_id" BEFORE INSERT ON "public"."activity_notifications" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_activity_notifications_fill_service" BEFORE INSERT ON "public"."activity_notifications" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_avatar_generations_assert_service" BEFORE INSERT OR UPDATE ON "public"."avatar_generations" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_avatar_generations_fill_product_id" BEFORE INSERT ON "public"."avatar_generations" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_avatar_generations_fill_service" BEFORE INSERT ON "public"."avatar_generations" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_content_attempts_fill_product_id" BEFORE INSERT ON "public"."content_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_content_attempts_fill_service_id" BEFORE INSERT ON "public"."content_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_content_attempts_updated_at" BEFORE UPDATE ON "public"."content_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."update_content_attempts_updated_at"();



CREATE OR REPLACE TRIGGER "trg_normalize_product_hostnames" BEFORE INSERT OR UPDATE OF "hostname_production", "hostname_staging" ON "backoffice"."bo_products" FOR EACH ROW EXECUTE FUNCTION "public"."normalize_product_hostnames"();



CREATE OR REPLACE TRIGGER "trg_profiles_assert_service" BEFORE INSERT OR UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_profiles_fill_product_id" BEFORE INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_profiles_fill_service_id" BEFORE INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."touch_profiles_updated_at"();



CREATE OR REPLACE TRIGGER "trg_quiz_attempts_0_fill_service_id" BEFORE INSERT ON "public"."quiz_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_quiz_attempts_assert_service" BEFORE INSERT OR UPDATE ON "public"."quiz_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_quiz_attempts_fill_product_id" BEFORE INSERT ON "public"."quiz_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_seed_content_consumption_rules" AFTER INSERT ON "backoffice"."bo_products" FOR EACH ROW EXECUTE FUNCTION "public"."seed_default_content_consumption_rules"();



CREATE OR REPLACE TRIGGER "trg_update_profile_points_on_quiz" AFTER INSERT ON "public"."quiz_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."update_profile_points_on_quiz"();



CREATE OR REPLACE TRIGGER "trg_user_activities_assert_service" BEFORE INSERT OR UPDATE ON "public"."user_activities" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_user_activities_fill_product_id" BEFORE INSERT ON "public"."user_activities" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_activities_fill_service" BEFORE INSERT ON "public"."user_activities" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_user_activities_fill_service_id" BEFORE INSERT ON "public"."user_activities" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_badges_assert_service" BEFORE INSERT OR UPDATE ON "public"."user_badges" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_user_badges_fill_product_id" BEFORE INSERT ON "public"."user_badges" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_badges_fill_service" BEFORE INSERT ON "public"."user_badges" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_user_badges_fill_service_id" BEFORE INSERT ON "public"."user_badges" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_cards_assert_service" BEFORE INSERT OR UPDATE ON "public"."user_cards" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_user_cards_fill_product_id" BEFORE INSERT ON "public"."user_cards" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_cards_fill_service" BEFORE INSERT ON "public"."user_cards" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_user_rewards_assert_service" BEFORE INSERT OR UPDATE ON "public"."user_rewards" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_user_rewards_fill_product_id" BEFORE INSERT ON "public"."user_rewards" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_rewards_fill_service" BEFORE INSERT ON "public"."user_rewards" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "trg_user_rewards_fill_service_id" BEFORE INSERT ON "public"."user_rewards" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_wishlist_assert_service" BEFORE INSERT OR UPDATE ON "public"."user_wishlist" FOR EACH ROW EXECUTE FUNCTION "public"."assert_same_service"();



CREATE OR REPLACE TRIGGER "trg_user_wishlist_fill_product_id" BEFORE INSERT ON "public"."user_wishlist" FOR EACH ROW EXECUTE FUNCTION "public"."fill_product_id_from_jwt"();



CREATE OR REPLACE TRIGGER "trg_user_wishlist_fill_service" BEFORE INSERT ON "public"."user_wishlist" FOR EACH ROW EXECUTE FUNCTION "public"."fill_service_id"();



CREATE OR REPLACE TRIGGER "update_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."activity_notifications"
    ADD CONSTRAINT "activity_notifications_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activity_notifications"
    ADD CONSTRAINT "activity_notifications_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."activity_notifications"
    ADD CONSTRAINT "activity_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."avatar_generations"
    ADD CONSTRAINT "avatar_generations_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."avatar_generations"
    ADD CONSTRAINT "avatar_generations_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id");



ALTER TABLE ONLY "public"."avatar_generations"
    ADD CONSTRAINT "avatar_generations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."badges"
    ADD CONSTRAINT "badges_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."special_events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."badges"
    ADD CONSTRAINT "badges_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "backoffice"."bo_backoffice_audit_log"
    ADD CONSTRAINT "bo_backoffice_audit_log_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "backoffice"."bo_backoffice_audit_log"
    ADD CONSTRAINT "bo_backoffice_audit_log_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "backoffice"."bo_backoffice_audit_log"
    ADD CONSTRAINT "bo_backoffice_audit_log_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "backoffice"."bo_backoffice_audit_log"
    ADD CONSTRAINT "bo_backoffice_audit_log_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "backoffice"."bo_backoffice_users"
    ADD CONSTRAINT "bo_backoffice_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_documents"
    ADD CONSTRAINT "bo_fk_product_documents_current_version" FOREIGN KEY ("current_version_id") REFERENCES "backoffice"."bo_product_document_versions"("id");



ALTER TABLE ONLY "backoffice"."bo_locale_avatar"
    ADD CONSTRAINT "bo_locale_avatar_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_locale_instant_games"
    ADD CONSTRAINT "bo_locale_instant_games_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_page_behaviour_rules"
    ADD CONSTRAINT "bo_page_behaviour_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_page_behaviour_tier_rules"
    ADD CONSTRAINT "bo_page_behaviour_tier_rules_rule_id_fkey" FOREIGN KEY ("rule_id") REFERENCES "backoffice"."bo_page_behaviour_rules"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_assets"
    ADD CONSTRAINT "bo_product_assets_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_avatar"
    ADD CONSTRAINT "bo_product_avatar_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_branding"
    ADD CONSTRAINT "bo_product_branding_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_content_consumption_rules"
    ADD CONSTRAINT "bo_product_content_consumption_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_document_versions"
    ADD CONSTRAINT "bo_product_document_versions_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "backoffice"."bo_product_document_versions"
    ADD CONSTRAINT "bo_product_document_versions_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "backoffice"."bo_product_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_documents"
    ADD CONSTRAINT "bo_product_documents_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "backoffice"."bo_product_documents"
    ADD CONSTRAINT "bo_product_documents_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_documents"
    ADD CONSTRAINT "bo_product_documents_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "backoffice"."bo_product_domains"
    ADD CONSTRAINT "bo_product_domains_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_feature_flags"
    ADD CONSTRAINT "bo_product_feature_flags_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_footer_hidden_pages"
    ADD CONSTRAINT "bo_product_footer_hidden_pages_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_footer_items"
    ADD CONSTRAINT "bo_product_footer_items_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_instant_games"
    ADD CONSTRAINT "bo_product_instant_games_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_locales"
    ADD CONSTRAINT "bo_product_locales_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_login_methods"
    ADD CONSTRAINT "bo_product_login_methods_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_login_methods"
    ADD CONSTRAINT "bo_product_login_methods_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "backoffice"."bo_product_menu_item_tiers"
    ADD CONSTRAINT "bo_product_menu_item_tiers_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "backoffice"."bo_product_menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_menu_items"
    ADD CONSTRAINT "bo_product_menu_items_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_public_config"
    ADD CONSTRAINT "bo_product_public_config_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_secrets"
    ADD CONSTRAINT "bo_product_secrets_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_translations"
    ADD CONSTRAINT "bo_product_translations_product_locale_id_fkey" FOREIGN KEY ("product_locale_id") REFERENCES "backoffice"."bo_product_locales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_product_unsubscribe_methods"
    ADD CONSTRAINT "bo_product_unsubscribe_methods_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_products"
    ADD CONSTRAINT "bo_products_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_assets_defaults"
    ADD CONSTRAINT "bo_service_assets_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_avatar_defaults"
    ADD CONSTRAINT "bo_service_avatar_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_branding_defaults"
    ADD CONSTRAINT "bo_service_branding_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_feature_flags_defaults"
    ADD CONSTRAINT "bo_service_feature_flags_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_footer_items_defaults"
    ADD CONSTRAINT "bo_service_footer_items_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_instant_games_defaults"
    ADD CONSTRAINT "bo_service_instant_games_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_login_methods_defaults"
    ADD CONSTRAINT "bo_service_login_methods_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_menu_items_defaults"
    ADD CONSTRAINT "bo_service_menu_items_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_public_config_defaults"
    ADD CONSTRAINT "bo_service_public_config_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_service_translations_defaults"
    ADD CONSTRAINT "bo_service_translations_defaults_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "backoffice"."bo_services"
    ADD CONSTRAINT "bo_services_global_product_fk" FOREIGN KEY ("global_product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."content_attempts"
    ADD CONSTRAINT "content_attempts_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."content_attempts"
    ADD CONSTRAINT "content_attempts_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."content_consumption_rules"
    ADD CONSTRAINT "content_consumption_rules_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."content_consumption_tier_rules"
    ADD CONSTRAINT "content_consumption_tier_rules_rule_id_fkey" FOREIGN KEY ("rule_id") REFERENCES "public"."content_consumption_rules"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."games"
    ADD CONSTRAINT "games_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."player_cards"
    ADD CONSTRAINT "player_cards_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pulsar_quiz_cache"
    ADD CONSTRAINT "pulsar_quiz_cache_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."quiz_attempts"
    ADD CONSTRAINT "quiz_attempts_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quiz_attempts"
    ADD CONSTRAINT "quiz_attempts_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id");



ALTER TABLE ONLY "public"."quiz_attempts"
    ADD CONSTRAINT "quiz_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rewards"
    ADD CONSTRAINT "rewards_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."special_events"
    ADD CONSTRAINT "special_events_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."user_activities"
    ADD CONSTRAINT "user_activities_game_id_fkey" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_activities"
    ADD CONSTRAINT "user_activities_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_activities"
    ADD CONSTRAINT "user_activities_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_activities"
    ADD CONSTRAINT "user_activities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_badge_id_fkey" FOREIGN KEY ("badge_id") REFERENCES "public"."badges"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_badges"
    ADD CONSTRAINT "user_badges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_cards"
    ADD CONSTRAINT "user_cards_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."player_cards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_cards"
    ADD CONSTRAINT "user_cards_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_cards"
    ADD CONSTRAINT "user_cards_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id");



ALTER TABLE ONLY "public"."user_cards"
    ADD CONSTRAINT "user_cards_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_rewards"
    ADD CONSTRAINT "user_rewards_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_rewards"
    ADD CONSTRAINT "user_rewards_reward_id_fkey" FOREIGN KEY ("reward_id") REFERENCES "public"."rewards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_rewards"
    ADD CONSTRAINT "user_rewards_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_rewards"
    ADD CONSTRAINT "user_rewards_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_wishlist"
    ADD CONSTRAINT "user_wishlist_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "backoffice"."bo_products"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_wishlist"
    ADD CONSTRAINT "user_wishlist_reward_id_fkey" FOREIGN KEY ("reward_id") REFERENCES "public"."rewards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_wishlist"
    ADD CONSTRAINT "user_wishlist_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "backoffice"."bo_services"("id");



ALTER TABLE ONLY "public"."user_wishlist"
    ADD CONSTRAINT "user_wishlist_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can delete admin_users" ON "public"."admin_users" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."admin_users" "au"
  WHERE (("au"."user_id" = "auth"."uid"()) AND ("au"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can insert admin_users" ON "public"."admin_users" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."admin_users" "au"
  WHERE (("au"."user_id" = "auth"."uid"()) AND ("au"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can update admin_users" ON "public"."admin_users" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."admin_users" "au"
  WHERE (("au"."user_id" = "auth"."uid"()) AND ("au"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."admin_users" "au"
  WHERE (("au"."user_id" = "auth"."uid"()) AND ("au"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can view admin_users" ON "public"."admin_users" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."admin_users" "au"
  WHERE (("au"."user_id" = "auth"."uid"()) AND ("au"."role" = 'admin'::"text")))));



CREATE POLICY "Admins delete backoffice users" ON "backoffice"."bo_backoffice_users" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete locale_avatar" ON "backoffice"."bo_locale_avatar" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete locale_ig" ON "backoffice"."bo_locale_instant_games" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete prod_avatar" ON "backoffice"."bo_product_avatar" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete prod_ig" ON "backoffice"."bo_product_instant_games" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product assets" ON "backoffice"."bo_product_assets" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product branding" ON "backoffice"."bo_product_branding" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product domains" ON "backoffice"."bo_product_domains" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product feature flags" ON "backoffice"."bo_product_feature_flags" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product locales" ON "backoffice"."bo_product_locales" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product public config" ON "backoffice"."bo_product_public_config" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete product translations" ON "backoffice"."bo_product_translations" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete products" ON "backoffice"."bo_products" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete service_assets_defaults" ON "backoffice"."bo_service_assets_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete service_branding_defaults" ON "backoffice"."bo_service_branding_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete service_feature_flags_defaults" ON "backoffice"."bo_service_feature_flags_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete service_public_config_defaults" ON "backoffice"."bo_service_public_config_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete service_translations_defaults" ON "backoffice"."bo_service_translations_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete services" ON "backoffice"."bo_services" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete svc_avatar_defaults" ON "backoffice"."bo_service_avatar_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins delete svc_ig_defaults" ON "backoffice"."bo_service_instant_games_defaults" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins insert backoffice users" ON "backoffice"."bo_backoffice_users" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins update backoffice users" ON "backoffice"."bo_backoffice_users" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text")) WITH CHECK ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Admins view all backoffice users" ON "backoffice"."bo_backoffice_users" FOR SELECT TO "authenticated" USING ("public"."is_backoffice_role"('admin'::"text"));



CREATE POLICY "Anyone can view active events" ON "public"."special_events" FOR SELECT TO "authenticated" USING ((("active" = true) AND ("now"() >= "start_date") AND ("now"() <= "end_date")));



CREATE POLICY "Anyone can view active games" ON "public"."games" FOR SELECT TO "authenticated" USING (("active" = true));



CREATE POLICY "Anyone can view available rewards" ON "public"."rewards" FOR SELECT TO "authenticated", "anon" USING (("available" = true));



CREATE POLICY "Anyone can view badges" ON "public"."badges" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone reads active product locales" ON "backoffice"."bo_product_locales" FOR SELECT TO "authenticated", "anon" USING ((("status" = 'active'::"text") OR "public"."is_backoffice_role"('viewer'::"text")));



CREATE POLICY "Anyone reads active products" ON "backoffice"."bo_products" FOR SELECT TO "authenticated", "anon" USING ((("status" = 'active'::"text") OR "public"."is_backoffice_role"('viewer'::"text")));



CREATE POLICY "Anyone reads active services" ON "backoffice"."bo_services" FOR SELECT TO "authenticated", "anon" USING ((("status" = 'active'::"text") OR "public"."is_backoffice_role"('viewer'::"text")));



CREATE POLICY "Anyone reads locale_ig" ON "backoffice"."bo_locale_instant_games" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads prod_ig" ON "backoffice"."bo_product_instant_games" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product assets" ON "backoffice"."bo_product_assets" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product branding" ON "backoffice"."bo_product_branding" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product domains" ON "backoffice"."bo_product_domains" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product feature flags" ON "backoffice"."bo_product_feature_flags" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product public config" ON "backoffice"."bo_product_public_config" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads product translations" ON "backoffice"."bo_product_translations" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads service_assets_defaults" ON "backoffice"."bo_service_assets_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads service_branding_defaults" ON "backoffice"."bo_service_branding_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads service_feature_flags_defaults" ON "backoffice"."bo_service_feature_flags_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads service_public_config_defaults" ON "backoffice"."bo_service_public_config_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads service_translations_defaults" ON "backoffice"."bo_service_translations_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anyone reads svc_ig_defaults" ON "backoffice"."bo_service_instant_games_defaults" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Authenticated select locale_avatar" ON "backoffice"."bo_locale_avatar" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated select prod_avatar" ON "backoffice"."bo_product_avatar" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated select svc_avatar_defaults" ON "backoffice"."bo_service_avatar_defaults" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete content consumption rules" ON "backoffice"."bo_product_content_consumption_rules" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete content_consumption_rules" ON "public"."content_consumption_rules" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete content_consumption_tier_rules" ON "public"."content_consumption_tier_rules" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete footer hidden pages" ON "backoffice"."bo_product_footer_hidden_pages" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete menu item tiers" ON "backoffice"."bo_product_menu_item_tiers" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_product_menu_items" "pmi"
  WHERE ("pmi"."id" = "bo_product_menu_item_tiers"."menu_item_id"))));



CREATE POLICY "Authenticated users can delete page_behaviour_rules" ON "backoffice"."bo_page_behaviour_rules" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete page_behaviour_tier_rules" ON "backoffice"."bo_page_behaviour_tier_rules" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete product footer items" ON "backoffice"."bo_product_footer_items" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can delete product menu items" ON "backoffice"."bo_product_menu_items" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can delete product_unsubscribe_methods" ON "backoffice"."bo_product_unsubscribe_methods" FOR DELETE TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can delete service footer items defaults" ON "backoffice"."bo_service_footer_items_defaults" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can delete service login methods defaults" ON "backoffice"."bo_service_login_methods_defaults" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can delete service menu items defaults" ON "backoffice"."bo_service_menu_items_defaults" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can insert content consumption rules" ON "backoffice"."bo_product_content_consumption_rules" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert content_consumption_rules" ON "public"."content_consumption_rules" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert content_consumption_tier_rules" ON "public"."content_consumption_tier_rules" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert footer hidden pages" ON "backoffice"."bo_product_footer_hidden_pages" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert menu item tiers" ON "backoffice"."bo_product_menu_item_tiers" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_product_menu_items" "pmi"
  WHERE ("pmi"."id" = "bo_product_menu_item_tiers"."menu_item_id"))));



CREATE POLICY "Authenticated users can insert page_behaviour_rules" ON "backoffice"."bo_page_behaviour_rules" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert page_behaviour_tier_rules" ON "backoffice"."bo_page_behaviour_tier_rules" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert product footer items" ON "backoffice"."bo_product_footer_items" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can insert product menu items" ON "backoffice"."bo_product_menu_items" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can insert product_unsubscribe_methods" ON "backoffice"."bo_product_unsubscribe_methods" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can insert service footer items defaults" ON "backoffice"."bo_service_footer_items_defaults" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can insert service login methods defaults" ON "backoffice"."bo_service_login_methods_defaults" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can insert service menu items defaults" ON "backoffice"."bo_service_menu_items_defaults" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can read content_consumption_rules" ON "public"."content_consumption_rules" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read content_consumption_tier_rules" ON "public"."content_consumption_tier_rules" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read menu item tiers" ON "backoffice"."bo_product_menu_item_tiers" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_product_menu_items" "pmi"
  WHERE ("pmi"."id" = "bo_product_menu_item_tiers"."menu_item_id"))));



CREATE POLICY "Authenticated users can read page_behaviour_rules" ON "backoffice"."bo_page_behaviour_rules" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read page_behaviour_tier_rules" ON "backoffice"."bo_page_behaviour_tier_rules" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read product footer items" ON "backoffice"."bo_product_footer_items" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can read product menu items" ON "backoffice"."bo_product_menu_items" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can read service footer items defaults" ON "backoffice"."bo_service_footer_items_defaults" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can read service login methods defaults" ON "backoffice"."bo_service_login_methods_defaults" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can read service menu items defaults" ON "backoffice"."bo_service_menu_items_defaults" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can select content consumption rules" ON "backoffice"."bo_product_content_consumption_rules" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can select footer hidden pages" ON "backoffice"."bo_product_footer_hidden_pages" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can select product_unsubscribe_methods" ON "backoffice"."bo_product_unsubscribe_methods" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update content consumption rules" ON "backoffice"."bo_product_content_consumption_rules" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update content_consumption_rules" ON "public"."content_consumption_rules" FOR UPDATE TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update content_consumption_tier_rules" ON "public"."content_consumption_tier_rules" FOR UPDATE TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update menu item tiers" ON "backoffice"."bo_product_menu_item_tiers" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_product_menu_items" "pmi"
  WHERE ("pmi"."id" = "bo_product_menu_item_tiers"."menu_item_id")))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_product_menu_items" "pmi"
  WHERE ("pmi"."id" = "bo_product_menu_item_tiers"."menu_item_id"))));



CREATE POLICY "Authenticated users can update page_behaviour_rules" ON "backoffice"."bo_page_behaviour_rules" FOR UPDATE TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update page_behaviour_tier_rules" ON "backoffice"."bo_page_behaviour_tier_rules" FOR UPDATE TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update product footer items" ON "backoffice"."bo_product_footer_items" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can update product menu items" ON "backoffice"."bo_product_menu_items" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can update product_unsubscribe_methods" ON "backoffice"."bo_product_unsubscribe_methods" FOR UPDATE TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update service footer items defaults" ON "backoffice"."bo_service_footer_items_defaults" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can update service login methods defaults" ON "backoffice"."bo_service_login_methods_defaults" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can update service menu items defaults" ON "backoffice"."bo_service_menu_items_defaults" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users"
  WHERE ("bo_backoffice_users"."user_id" = "auth"."uid"()))));



CREATE POLICY "Authenticated users can view all player cards" ON "public"."player_cards" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Backoffice users can view document versions" ON "backoffice"."bo_product_document_versions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("backoffice"."bo_product_documents" "d"
     JOIN "backoffice"."bo_backoffice_users" "bu" ON (("bu"."user_id" = "auth"."uid"())))
  WHERE (("d"."id" = "bo_product_document_versions"."document_id") AND ("bu"."is_active" = true) AND (("bu"."product_scope" @> ARRAY[("d"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Backoffice users can view documents" ON "backoffice"."bo_product_documents" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users" "bu"
  WHERE (("bu"."user_id" = "auth"."uid"()) AND ("bu"."is_active" = true) AND (("bu"."product_scope" @> ARRAY[("bo_product_documents"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Backoffice users view own row" ON "backoffice"."bo_backoffice_users" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Backoffice viewers can read login methods" ON "backoffice"."bo_product_login_methods" FOR SELECT TO "authenticated" USING ("public"."is_backoffice_role"('viewer'::"text"));



CREATE POLICY "Editors append audit log" ON "backoffice"."bo_backoffice_audit_log" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors can delete document versions" ON "backoffice"."bo_product_document_versions" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("backoffice"."bo_product_documents" "d"
     JOIN "backoffice"."bo_backoffice_users" "bu" ON (("bu"."user_id" = "auth"."uid"())))
  WHERE (("d"."id" = "bo_product_document_versions"."document_id") AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("d"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can delete documents" ON "backoffice"."bo_product_documents" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users" "bu"
  WHERE (("bu"."user_id" = "auth"."uid"()) AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("bo_product_documents"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can delete login methods" ON "backoffice"."bo_product_login_methods" FOR DELETE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors can insert document versions" ON "backoffice"."bo_product_document_versions" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM ("backoffice"."bo_product_documents" "d"
     JOIN "backoffice"."bo_backoffice_users" "bu" ON (("bu"."user_id" = "auth"."uid"())))
  WHERE (("d"."id" = "bo_product_document_versions"."document_id") AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("d"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can insert documents" ON "backoffice"."bo_product_documents" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users" "bu"
  WHERE (("bu"."user_id" = "auth"."uid"()) AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("bo_product_documents"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can insert login methods" ON "backoffice"."bo_product_login_methods" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors can update document versions" ON "backoffice"."bo_product_document_versions" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("backoffice"."bo_product_documents" "d"
     JOIN "backoffice"."bo_backoffice_users" "bu" ON (("bu"."user_id" = "auth"."uid"())))
  WHERE (("d"."id" = "bo_product_document_versions"."document_id") AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("d"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("backoffice"."bo_product_documents" "d"
     JOIN "backoffice"."bo_backoffice_users" "bu" ON (("bu"."user_id" = "auth"."uid"())))
  WHERE (("d"."id" = "bo_product_document_versions"."document_id") AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("d"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can update documents" ON "backoffice"."bo_product_documents" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users" "bu"
  WHERE (("bu"."user_id" = "auth"."uid"()) AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("bo_product_documents"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "backoffice"."bo_backoffice_users" "bu"
  WHERE (("bu"."user_id" = "auth"."uid"()) AND ("bu"."is_active" = true) AND ("bu"."role" = ANY (ARRAY['editor'::"text", 'admin'::"text"])) AND (("bu"."product_scope" @> ARRAY[("bo_product_documents"."product_id")::"text"]) OR ("bu"."role" = 'admin'::"text"))))));



CREATE POLICY "Editors can update login methods" ON "backoffice"."bo_product_login_methods" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert locale_avatar" ON "backoffice"."bo_locale_avatar" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert locale_ig" ON "backoffice"."bo_locale_instant_games" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert prod_avatar" ON "backoffice"."bo_product_avatar" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert prod_ig" ON "backoffice"."bo_product_instant_games" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product assets" ON "backoffice"."bo_product_assets" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product branding" ON "backoffice"."bo_product_branding" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product domains" ON "backoffice"."bo_product_domains" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product feature flags" ON "backoffice"."bo_product_feature_flags" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product locales" ON "backoffice"."bo_product_locales" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product public config" ON "backoffice"."bo_product_public_config" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert product translations" ON "backoffice"."bo_product_translations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert products" ON "backoffice"."bo_products" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert service_assets_defaults" ON "backoffice"."bo_service_assets_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert service_branding_defaults" ON "backoffice"."bo_service_branding_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert service_feature_flags_defaults" ON "backoffice"."bo_service_feature_flags_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert service_public_config_defaults" ON "backoffice"."bo_service_public_config_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert service_translations_defaults" ON "backoffice"."bo_service_translations_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert services" ON "backoffice"."bo_services" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert svc_avatar_defaults" ON "backoffice"."bo_service_avatar_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors insert svc_ig_defaults" ON "backoffice"."bo_service_instant_games_defaults" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update locale_avatar" ON "backoffice"."bo_locale_avatar" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update locale_ig" ON "backoffice"."bo_locale_instant_games" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update prod_avatar" ON "backoffice"."bo_product_avatar" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update prod_ig" ON "backoffice"."bo_product_instant_games" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product assets" ON "backoffice"."bo_product_assets" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product branding" ON "backoffice"."bo_product_branding" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product domains" ON "backoffice"."bo_product_domains" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product feature flags" ON "backoffice"."bo_product_feature_flags" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product locales" ON "backoffice"."bo_product_locales" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product public config" ON "backoffice"."bo_product_public_config" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update product translations" ON "backoffice"."bo_product_translations" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update products" ON "backoffice"."bo_products" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update service_assets_defaults" ON "backoffice"."bo_service_assets_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update service_branding_defaults" ON "backoffice"."bo_service_branding_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update service_feature_flags_defaults" ON "backoffice"."bo_service_feature_flags_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update service_public_config_defaults" ON "backoffice"."bo_service_public_config_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update service_translations_defaults" ON "backoffice"."bo_service_translations_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update services" ON "backoffice"."bo_services" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update svc_avatar_defaults" ON "backoffice"."bo_service_avatar_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Editors update svc_ig_defaults" ON "backoffice"."bo_service_instant_games_defaults" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_role"('editor'::"text")) WITH CHECK ("public"."is_backoffice_role"('editor'::"text"));



CREATE POLICY "Service role can read content consumption rules" ON "backoffice"."bo_product_content_consumption_rules" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Users can insert own reward assets" ON "public"."redeemed_reward_assets" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read own reward assets" ON "public"."redeemed_reward_assets" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own reward assets" ON "public"."redeemed_reward_assets" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Viewers read audit log" ON "backoffice"."bo_backoffice_audit_log" FOR SELECT TO "authenticated" USING ("public"."is_backoffice_role"('viewer'::"text"));



ALTER TABLE "public"."activity_notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_notifications_delete_own" ON "public"."activity_notifications" FOR DELETE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"())));



CREATE POLICY "activity_notifications_insert_own" ON "public"."activity_notifications" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "activity_notifications_select_own" ON "public"."activity_notifications" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "activity_notifications_update_own" ON "public"."activity_notifications" FOR UPDATE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()))) WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"())));



ALTER TABLE "public"."admin_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_config_select" ON "public"."app_config" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "public"."avatar_generations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "avatar_generations_delete_own" ON "public"."avatar_generations" FOR DELETE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "avatar_generations_insert_own" ON "public"."avatar_generations" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "avatar_generations_select_own" ON "public"."avatar_generations" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "avatar_generations_update_own" ON "public"."avatar_generations" FOR UPDATE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()))) WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"())));



ALTER TABLE "public"."badges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "badges_select" ON "public"."badges" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "backoffice"."bo_backoffice_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_backoffice_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_locale_avatar" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_locale_instant_games" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_page_behaviour_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_page_behaviour_tier_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_assets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_avatar" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_branding" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_content_consumption_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_document_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_domains" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_feature_flags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_footer_hidden_pages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_footer_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_instant_games" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_locales" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_login_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_menu_item_tiers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_menu_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_public_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_secrets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_translations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_product_unsubscribe_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_assets_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_avatar_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_branding_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_feature_flags_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_footer_items_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_instant_games_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_login_methods_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_menu_items_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_public_config_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_service_translations_defaults" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "backoffice"."bo_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."content_attempts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "content_attempts_insert_own" ON "public"."content_attempts" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "content_attempts_select_own" ON "public"."content_attempts" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "content_attempts_update_own" ON "public"."content_attempts" FOR UPDATE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"()))) WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."content_consumption_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."content_consumption_tier_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."games" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "games_select" ON "public"."games" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "public"."player_cards" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_cards_select" ON "public"."player_cards" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_insert_own" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ((("id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((("id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"()))) WITH CHECK ((("id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."pulsar_quiz_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quiz_attempts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quiz_attempts_insert_own" ON "public"."quiz_attempts" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "quiz_attempts_select_own" ON "public"."quiz_attempts" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "quiz_attempts_update_own" ON "public"."quiz_attempts" FOR UPDATE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"()))) WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."redeemed_reward_assets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rewards" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rewards_select" ON "public"."rewards" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "public"."special_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "special_events_select" ON "public"."special_events" FOR SELECT TO "authenticated" USING (("service_id" = "public"."jwt_service_id"()));



ALTER TABLE "public"."user_activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_activities_insert_own" ON "public"."user_activities" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_activities_select_own" ON "public"."user_activities" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."user_badges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_badges_insert_own" ON "public"."user_badges" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_badges_select_own" ON "public"."user_badges" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."user_cards" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_cards_insert_own" ON "public"."user_cards" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_cards_select_own" ON "public"."user_cards" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."user_rewards" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_rewards_insert_own" ON "public"."user_rewards" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_rewards_select_own" ON "public"."user_rewards" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



ALTER TABLE "public"."user_wishlist" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_wishlist_delete_own" ON "public"."user_wishlist" FOR DELETE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_wishlist_insert_own" ON "public"."user_wishlist" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



CREATE POLICY "user_wishlist_select_own" ON "public"."user_wishlist" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND ("service_id" = "public"."jwt_service_id"()) AND ("product_id" = "public"."jwt_product_id"())));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."_bo_dashboard_period_kpis"("p_product_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."assert_same_service"() TO "anon";
GRANT ALL ON FUNCTION "public"."assert_same_service"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assert_same_service"() TO "service_role";



GRANT ALL ON FUNCTION "public"."backoffice_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."backoffice_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."backoffice_role"() TO "service_role";



REVOKE ALL ON FUNCTION "backoffice"."bo_product_dashboard"("p_product_id" "uuid", "p_granularity" "text", "p_from" timestamp with time zone, "p_to" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "backoffice"."bo_product_dashboard"("p_product_id" "uuid", "p_granularity" "text", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "backoffice"."bo_product_dashboard"("p_product_id" "uuid", "p_granularity" "text", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "backoffice"."bo_product_dashboard"("p_product_id" "uuid", "p_granularity" "text", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_locale_config_version"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_locale_config_version"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_locale_config_version"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_nickname_available"("nickname_input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_nickname_available"("nickname_input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_nickname_available"("nickname_input" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_product_id_from_jwt"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_product_id_from_jwt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_product_id_from_jwt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_service_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_service_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_service_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fill_service_id_from_jwt"() TO "anon";
GRANT ALL ON FUNCTION "public"."fill_service_id_from_jwt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fill_service_id_from_jwt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_leaderboard"("limit_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_leaderboard"("limit_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_leaderboard"("limit_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_id_by_email"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_id_by_email"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_id_by_email"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_rank"("target_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_rank"("target_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_rank"("target_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_backoffice_role"("required" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_backoffice_role"("required" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_backoffice_role"("required" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."jwt_product_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."jwt_product_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."jwt_product_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."jwt_service_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."jwt_service_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."jwt_service_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_product_hostnames"() TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_product_hostnames"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_product_hostnames"() TO "service_role";



GRANT ALL ON FUNCTION "public"."publish_document_version"("p_version_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."publish_document_version"("p_version_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."publish_document_version"("p_version_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_user_password"("target_user_id" "uuid", "new_password" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reset_user_password"("target_user_id" "uuid", "new_password" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_user_password"("target_user_id" "uuid", "new_password" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_product_by_hostname"("p_hostname" "text", "p_environment" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_product_by_hostname"("p_hostname" "text", "p_environment" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_product_by_hostname"("p_hostname" "text", "p_environment" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."seed_default_content_consumption_rules"() TO "anon";
GRANT ALL ON FUNCTION "public"."seed_default_content_consumption_rules"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."seed_default_content_consumption_rules"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_profiles_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_profiles_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_profiles_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_content_attempts_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_content_attempts_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_content_attempts_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_profile_points_on_quiz"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_profile_points_on_quiz"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_profile_points_on_quiz"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON TABLE "public"."activity_notifications" TO "anon";
GRANT ALL ON TABLE "public"."activity_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."admin_users" TO "anon";
GRANT ALL ON TABLE "public"."admin_users" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_users" TO "service_role";



GRANT ALL ON TABLE "public"."app_config" TO "anon";
GRANT ALL ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";



GRANT ALL ON TABLE "public"."avatar_generations" TO "anon";
GRANT ALL ON TABLE "public"."avatar_generations" TO "authenticated";
GRANT ALL ON TABLE "public"."avatar_generations" TO "service_role";



GRANT ALL ON TABLE "public"."badges" TO "anon";
GRANT ALL ON TABLE "public"."badges" TO "authenticated";
GRANT ALL ON TABLE "public"."badges" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_backoffice_audit_log" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_backoffice_audit_log" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_backoffice_audit_log" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_backoffice_users" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_backoffice_users" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_backoffice_users" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_locale_avatar" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_locale_avatar" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_locale_avatar" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_locale_instant_games" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_locale_instant_games" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_locale_instant_games" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_rules" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_rules" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_rules" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_tier_rules" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_tier_rules" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_page_behaviour_tier_rules" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_assets" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_assets" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_assets" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_avatar" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_avatar" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_avatar" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_branding" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_branding" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_branding" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_content_consumption_rules" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_content_consumption_rules" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_content_consumption_rules" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_document_versions" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_document_versions" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_document_versions" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_documents" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_documents" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_documents" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_domains" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_domains" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_domains" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_feature_flags" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_feature_flags" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_feature_flags" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_footer_hidden_pages" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_footer_hidden_pages" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_footer_hidden_pages" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_footer_items" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_footer_items" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_footer_items" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_instant_games" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_instant_games" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_instant_games" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_locales" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_locales" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_locales" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_login_methods" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_login_methods" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_login_methods" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_menu_item_tiers" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_menu_item_tiers" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_menu_item_tiers" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_menu_items" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_menu_items" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_menu_items" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_public_config" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_public_config" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_public_config" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_secrets" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_secrets" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_secrets" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_translations" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_translations" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_translations" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_product_unsubscribe_methods" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_product_unsubscribe_methods" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_product_unsubscribe_methods" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_products" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_products" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_products" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_assets_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_assets_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_assets_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_avatar_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_avatar_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_avatar_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_branding_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_branding_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_branding_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_feature_flags_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_feature_flags_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_feature_flags_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_footer_items_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_footer_items_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_footer_items_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_instant_games_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_instant_games_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_instant_games_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_login_methods_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_login_methods_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_login_methods_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_menu_items_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_menu_items_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_menu_items_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_public_config_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_public_config_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_public_config_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_service_translations_defaults" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_service_translations_defaults" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_service_translations_defaults" TO "service_role";



GRANT ALL ON TABLE "backoffice"."bo_services" TO "anon";
GRANT ALL ON TABLE "backoffice"."bo_services" TO "authenticated";
GRANT ALL ON TABLE "backoffice"."bo_services" TO "service_role";



GRANT ALL ON TABLE "public"."content_attempts" TO "anon";
GRANT ALL ON TABLE "public"."content_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."content_attempts" TO "service_role";



GRANT ALL ON TABLE "public"."content_consumption_rules" TO "anon";
GRANT ALL ON TABLE "public"."content_consumption_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."content_consumption_rules" TO "service_role";



GRANT ALL ON TABLE "public"."content_consumption_tier_rules" TO "anon";
GRANT ALL ON TABLE "public"."content_consumption_tier_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."content_consumption_tier_rules" TO "service_role";



GRANT ALL ON TABLE "public"."games" TO "anon";
GRANT ALL ON TABLE "public"."games" TO "authenticated";
GRANT ALL ON TABLE "public"."games" TO "service_role";



GRANT ALL ON TABLE "public"."player_cards" TO "anon";
GRANT ALL ON TABLE "public"."player_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."player_cards" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."pulsar_quiz_cache" TO "anon";
GRANT ALL ON TABLE "public"."pulsar_quiz_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."pulsar_quiz_cache" TO "service_role";



GRANT ALL ON TABLE "public"."quiz_attempts" TO "anon";
GRANT ALL ON TABLE "public"."quiz_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."quiz_attempts" TO "service_role";



GRANT ALL ON TABLE "public"."redeemed_reward_assets" TO "anon";
GRANT ALL ON TABLE "public"."redeemed_reward_assets" TO "authenticated";
GRANT ALL ON TABLE "public"."redeemed_reward_assets" TO "service_role";



GRANT ALL ON TABLE "public"."rewards" TO "anon";
GRANT ALL ON TABLE "public"."rewards" TO "authenticated";
GRANT ALL ON TABLE "public"."rewards" TO "service_role";



GRANT ALL ON TABLE "public"."special_events" TO "anon";
GRANT ALL ON TABLE "public"."special_events" TO "authenticated";
GRANT ALL ON TABLE "public"."special_events" TO "service_role";



GRANT ALL ON TABLE "public"."user_activities" TO "anon";
GRANT ALL ON TABLE "public"."user_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."user_activities" TO "service_role";



GRANT ALL ON TABLE "public"."user_badges" TO "anon";
GRANT ALL ON TABLE "public"."user_badges" TO "authenticated";
GRANT ALL ON TABLE "public"."user_badges" TO "service_role";



GRANT ALL ON TABLE "public"."user_cards" TO "anon";
GRANT ALL ON TABLE "public"."user_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."user_cards" TO "service_role";



GRANT ALL ON TABLE "public"."user_rewards" TO "anon";
GRANT ALL ON TABLE "public"."user_rewards" TO "authenticated";
GRANT ALL ON TABLE "public"."user_rewards" TO "service_role";



GRANT ALL ON TABLE "public"."user_wishlist" TO "anon";
GRANT ALL ON TABLE "public"."user_wishlist" TO "authenticated";
GRANT ALL ON TABLE "public"."user_wishlist" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";









-- ==========================================================================
-- Backoffice menus, social links, translations, branding templates and
-- product-level configuration (from deno-dialog migrations up to
-- 20261008100000_menu_three_level_inheritance).
-- ==========================================================================

-- --- Functions (RPCs called by the backoffice live in the backoffice schema)

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
    UPDATE backoffice.bo_product_locales SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE product_id = target_product;
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.bo_product_locales SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE product_id = target_product;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $function$
;

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
    UPDATE backoffice.bo_product_locales SET config_version_staging = config_version_staging + 1, updated_at = now()
    WHERE product_id IN (SELECT id FROM backoffice.bo_products WHERE service_id = target_service);
  ELSIF target_env = 'production' THEN
    UPDATE backoffice.bo_product_locales SET config_version_production = config_version_production + 1, updated_at = now()
    WHERE product_id IN (SELECT id FROM backoffice.bo_products WHERE service_id = target_service);
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.normalize_menu_item_link()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  NEW.route := CASE WHEN NEW.item_type = 'internal' THEN NULLIF(NEW.url, '') END;
  NEW.external_url := CASE WHEN NEW.item_type = 'external' THEN NULLIF(NEW.url, '') END;
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.on_locale_created_seed_menus()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  PERFORM backoffice.seed_locale_menus(NEW.id);
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.on_product_created_seed_menus()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  PERFORM backoffice.seed_product_level_menus(NEW.id);
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.promote_locale_menus(p_locale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_product_id uuid; v_menus int; v_items int;
BEGIN
  SELECT product_id INTO v_product_id FROM bo_product_locales WHERE id = p_locale_id;

  INSERT INTO bo_product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT s.product_locale_id, 'production', s.menu_key, s.label, s.display_order,
         CASE WHEN s.source_menu_id IS NOT NULL THEN (
           SELECT pm.id FROM bo_product_level_menus pm
           WHERE pm.product_id = v_product_id AND pm.environment = 'production' AND pm.menu_key = s.menu_key
         ) END
  FROM bo_product_menus s
  WHERE s.product_locale_id = p_locale_id AND s.environment = 'staging'
  ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM bo_product_menus p
  WHERE p.product_locale_id = p_locale_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM bo_product_menus s
      WHERE s.product_locale_id = p_locale_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO bo_product_menu_items (
    product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    document_slug, label, label_i18n_key, url, icon, icon_url, display_order, parent_key, visible,
    auth_required, min_app_version, max_app_version, feature_flag, badge_text, badge_color
  )
  SELECT si.product_locale_id, 'production', pm.id,
         CASE WHEN si.source_item_id IS NOT NULL THEN (
           SELECT pli.id FROM bo_product_level_menu_items pli
           JOIN bo_product_level_menus plm ON plm.id = pli.menu_id
           WHERE plm.product_id = v_product_id AND plm.environment = 'production'
             AND plm.menu_key = sm.menu_key AND pli.item_key = si.item_key
         ) END,
         si.item_key, si.item_type, si.nested_menu_key,
         si.document_slug, si.label, si.label_i18n_key, si.url, si.icon, si.icon_url, si.display_order, si.parent_key, si.visible,
         si.auth_required, si.min_app_version, si.max_app_version, si.feature_flag, si.badge_text, si.badge_color
  FROM bo_product_menu_items si
  JOIN bo_product_menus sm ON sm.id = si.menu_id
  JOIN bo_product_menus pm ON pm.product_locale_id = p_locale_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, document_slug = EXCLUDED.document_slug,
    label = EXCLUDED.label, label_i18n_key = EXCLUDED.label_i18n_key, url = EXCLUDED.url, icon = EXCLUDED.icon,
    icon_url = EXCLUDED.icon_url, display_order = EXCLUDED.display_order, parent_key = EXCLUDED.parent_key,
    visible = EXCLUDED.visible, auth_required = EXCLUDED.auth_required, min_app_version = EXCLUDED.min_app_version,
    max_app_version = EXCLUDED.max_app_version, feature_flag = EXCLUDED.feature_flag,
    badge_text = EXCLUDED.badge_text, badge_color = EXCLUDED.badge_color, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM bo_product_menu_items p
  WHERE p.product_locale_id = p_locale_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM bo_product_menu_items si
      JOIN bo_product_menus sm ON sm.id = si.menu_id
      JOIN bo_product_menus pm ON pm.id = p.menu_id
      WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  -- Tiers: replace production tiers with staging tiers, matched by (menu_key, item_key)
  DELETE FROM bo_product_menu_item_tiers t
  USING bo_product_menu_items pi
  WHERE t.menu_item_id = pi.id AND pi.product_locale_id = p_locale_id AND pi.environment = 'production';

  INSERT INTO bo_product_menu_item_tiers (
    menu_item_id, tier, visible, enabled, locked_action, route, external_url,
    label, label_i18n_key, badge_text, badge_color, display_order
  )
  SELECT pi.id, t.tier, t.visible, t.enabled, t.locked_action, t.route, t.external_url,
         t.label, t.label_i18n_key, t.badge_text, t.badge_color, t.display_order
  FROM bo_product_menu_item_tiers t
  JOIN bo_product_menu_items si ON si.id = t.menu_item_id
  JOIN bo_product_menus sm ON sm.id = si.menu_id
  JOIN bo_product_menus pm ON pm.product_locale_id = p_locale_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  JOIN bo_product_menu_items pi ON pi.menu_id = pm.id AND pi.item_key = si.item_key
  WHERE si.product_locale_id = p_locale_id AND si.environment = 'staging';

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.promote_product_menus(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_service_id uuid; v_menus int; v_items int;
BEGIN
  SELECT service_id INTO v_service_id FROM bo_products WHERE id = p_product_id;

  INSERT INTO bo_product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT s.product_id, 'production', s.menu_key, s.label, s.display_order,
         CASE WHEN s.source_menu_id IS NOT NULL THEN (
           SELECT sm.id FROM bo_service_menus sm
           WHERE sm.service_id = v_service_id AND sm.environment = 'production' AND sm.menu_key = s.menu_key
         ) END
  FROM bo_product_level_menus s
  WHERE s.product_id = p_product_id AND s.environment = 'staging'
  ON CONFLICT (product_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM bo_product_level_menus p
  WHERE p.product_id = p_product_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM bo_product_level_menus s
      WHERE s.product_id = p_product_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO bo_product_level_menu_items (
    product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT si.product_id, 'production', pm.id,
         CASE WHEN si.source_item_id IS NOT NULL THEN (
           SELECT svi.id FROM bo_service_menu_items_defaults svi
           JOIN bo_service_menus svm ON svm.id = svi.menu_id
           WHERE svm.service_id = v_service_id AND svm.environment = 'production'
             AND svm.menu_key = sm.menu_key AND svi.item_key = si.item_key
         ) END,
         si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM bo_product_level_menu_items si
  JOIN bo_product_level_menus sm ON sm.id = si.menu_id
  JOIN bo_product_level_menus pm ON pm.product_id = p_product_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.product_id = p_product_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, label = EXCLUDED.label,
    url = EXCLUDED.url, icon = EXCLUDED.icon, display_order = EXCLUDED.display_order,
    parent_key = EXCLUDED.parent_key, visible = EXCLUDED.visible, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM bo_product_level_menu_items p
  WHERE p.product_id = p_product_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM bo_product_level_menu_items si
      JOIN bo_product_level_menus sm ON sm.id = si.menu_id
      JOIN bo_product_level_menus pm ON pm.id = p.menu_id
      WHERE si.product_id = p_product_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.promote_service_menus(p_service_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'backoffice', 'public'
AS $function$
DECLARE v_menus int; v_items int;
BEGIN
  INSERT INTO bo_service_menus (service_id, environment, menu_key, label, display_order)
  SELECT service_id, 'production', menu_key, label, display_order
  FROM bo_service_menus
  WHERE service_id = p_service_id AND environment = 'staging'
  ON CONFLICT (service_id, environment, menu_key) DO UPDATE
    SET label = EXCLUDED.label, display_order = EXCLUDED.display_order, updated_at = now();
  GET DIAGNOSTICS v_menus = ROW_COUNT;

  DELETE FROM bo_service_menus p
  WHERE p.service_id = p_service_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1 FROM bo_service_menus s
      WHERE s.service_id = p_service_id AND s.environment = 'staging' AND s.menu_key = p.menu_key
    );

  INSERT INTO bo_service_menu_items_defaults (
    service_id, environment, menu_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT si.service_id, 'production', pm.id, si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM bo_service_menu_items_defaults si
  JOIN bo_service_menus sm ON sm.id = si.menu_id
  JOIN bo_service_menus pm ON pm.service_id = p_service_id AND pm.environment = 'production' AND pm.menu_key = sm.menu_key
  WHERE si.service_id = p_service_id AND si.environment = 'staging'
  ON CONFLICT (menu_id, item_key) DO UPDATE SET
    item_type = EXCLUDED.item_type, nested_menu_key = EXCLUDED.nested_menu_key, label = EXCLUDED.label,
    url = EXCLUDED.url, icon = EXCLUDED.icon, display_order = EXCLUDED.display_order,
    parent_key = EXCLUDED.parent_key, visible = EXCLUDED.visible, updated_at = now();
  GET DIAGNOSTICS v_items = ROW_COUNT;

  DELETE FROM bo_service_menu_items_defaults p
  WHERE p.service_id = p_service_id AND p.environment = 'production'
    AND NOT EXISTS (
      SELECT 1
      FROM bo_service_menu_items_defaults si
      JOIN bo_service_menus sm ON sm.id = si.menu_id
      JOIN bo_service_menus pm ON pm.id = p.menu_id
      WHERE si.service_id = p_service_id AND si.environment = 'staging'
        AND sm.menu_key = pm.menu_key AND si.item_key = p.item_key
    );

  RETURN jsonb_build_object('menus', v_menus, 'menu_items', v_items);
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.propagate_product_level_menu()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO bo_product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
    SELECT pl.id, NEW.environment, NEW.menu_key, NEW.label, NEW.display_order, NEW.id
    FROM bo_product_locales pl
    WHERE pl.product_id = NEW.product_id
    ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
      SET source_menu_id = EXCLUDED.source_menu_id
      WHERE bo_product_menus.source_menu_id IS NULL;
  ELSIF (OLD.label, OLD.display_order) IS DISTINCT FROM (NEW.label, NEW.display_order) THEN
    UPDATE bo_product_menus SET
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      updated_at = now()
    WHERE source_menu_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.propagate_product_level_menu_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO bo_product_menu_items (
      product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
      label, url, icon, display_order, parent_key, visible
    )
    SELECT lm.product_locale_id, NEW.environment, lm.id, NEW.id, NEW.item_key, NEW.item_type, NEW.nested_menu_key,
           NEW.label, NEW.url, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible
    FROM bo_product_menus lm
    WHERE lm.source_menu_id = NEW.menu_id
    ON CONFLICT (menu_id, item_key) DO UPDATE
      SET source_item_id = EXCLUDED.source_item_id
      WHERE bo_product_menu_items.source_item_id IS NULL;
  ELSIF (OLD.item_type, OLD.url, OLD.nested_menu_key, OLD.label, OLD.icon, OLD.display_order, OLD.parent_key, OLD.visible)
        IS DISTINCT FROM
        (NEW.item_type, NEW.url, NEW.nested_menu_key, NEW.label, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible) THEN
    UPDATE bo_product_menu_items SET
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
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.propagate_service_menu()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO bo_product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
    SELECT p.id, NEW.environment, NEW.menu_key, NEW.label, NEW.display_order, NEW.id
    FROM bo_products p
    WHERE p.service_id = NEW.service_id
    ON CONFLICT (product_id, environment, menu_key) DO UPDATE
      SET source_menu_id = EXCLUDED.source_menu_id
      WHERE bo_product_level_menus.source_menu_id IS NULL;
  ELSIF (OLD.label, OLD.display_order) IS DISTINCT FROM (NEW.label, NEW.display_order) THEN
    UPDATE bo_product_level_menus SET
      label = CASE WHEN label IS NOT DISTINCT FROM OLD.label THEN NEW.label ELSE label END,
      display_order = CASE WHEN display_order IS NOT DISTINCT FROM OLD.display_order THEN NEW.display_order ELSE display_order END,
      updated_at = now()
    WHERE source_menu_id = NEW.id;
  END IF;
  RETURN NEW;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.propagate_service_menu_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO bo_product_level_menu_items (
      product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
      label, url, icon, display_order, parent_key, visible
    )
    SELECT pm.product_id, NEW.environment, pm.id, NEW.id, NEW.item_key, NEW.item_type, NEW.nested_menu_key,
           NEW.label, NEW.url, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible
    FROM bo_product_level_menus pm
    WHERE pm.source_menu_id = NEW.menu_id
    ON CONFLICT (menu_id, item_key) DO UPDATE
      SET source_item_id = EXCLUDED.source_item_id
      WHERE bo_product_level_menu_items.source_item_id IS NULL;
  ELSIF (OLD.item_type, OLD.url, OLD.nested_menu_key, OLD.label, OLD.icon, OLD.display_order, OLD.parent_key, OLD.visible)
        IS DISTINCT FROM
        (NEW.item_type, NEW.url, NEW.nested_menu_key, NEW.label, NEW.icon, NEW.display_order, NEW.parent_key, NEW.visible) THEN
    UPDATE bo_product_level_menu_items SET
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
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.seed_locale_menus(p_locale_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  INSERT INTO bo_product_menus (product_locale_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT pl.id, pm.environment, pm.menu_key, pm.label, pm.display_order, pm.id
  FROM bo_product_locales pl
  JOIN bo_product_level_menus pm ON pm.product_id = pl.product_id
  WHERE pl.id = p_locale_id
  ON CONFLICT (product_locale_id, environment, menu_key) DO UPDATE
    SET source_menu_id = EXCLUDED.source_menu_id
    WHERE bo_product_menus.source_menu_id IS NULL;

  INSERT INTO bo_product_menu_items (
    product_locale_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT lm.product_locale_id, pi.environment, lm.id, pi.id, pi.item_key, pi.item_type, pi.nested_menu_key,
         pi.label, pi.url, pi.icon, pi.display_order, pi.parent_key, pi.visible
  FROM bo_product_level_menu_items pi
  JOIN bo_product_menus lm ON lm.source_menu_id = pi.menu_id
  WHERE lm.product_locale_id = p_locale_id
  ON CONFLICT (menu_id, item_key) DO UPDATE
    SET source_item_id = EXCLUDED.source_item_id
    WHERE bo_product_menu_items.source_item_id IS NULL;
END; $function$
;

CREATE OR REPLACE FUNCTION backoffice.seed_product_level_menus(p_product_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'backoffice', 'public'
AS $function$
BEGIN
  INSERT INTO bo_product_level_menus (product_id, environment, menu_key, label, display_order, source_menu_id)
  SELECT p.id, sm.environment, sm.menu_key, sm.label, sm.display_order, sm.id
  FROM bo_products p
  JOIN bo_service_menus sm ON sm.service_id = p.service_id
  WHERE p.id = p_product_id
  ON CONFLICT (product_id, environment, menu_key) DO UPDATE
    SET source_menu_id = EXCLUDED.source_menu_id
    WHERE bo_product_level_menus.source_menu_id IS NULL;

  INSERT INTO bo_product_level_menu_items (
    product_id, environment, menu_id, source_item_id, item_key, item_type, nested_menu_key,
    label, url, icon, display_order, parent_key, visible
  )
  SELECT pm.product_id, si.environment, pm.id, si.id, si.item_key, si.item_type, si.nested_menu_key,
         si.label, si.url, si.icon, si.display_order, si.parent_key, si.visible
  FROM bo_service_menu_items_defaults si
  JOIN bo_product_level_menus pm ON pm.source_menu_id = si.menu_id
  WHERE pm.product_id = p_product_id
  ON CONFLICT (menu_id, item_key) DO UPDATE
    SET source_item_id = EXCLUDED.source_item_id
    WHERE bo_product_level_menu_items.source_item_id IS NULL;
END; $function$
;

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
  FROM backoffice.bo_products
  WHERE id = p_id;

  IF v_service_id IS NULL THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  UPDATE backoffice.bo_products
  SET is_default = false
  WHERE service_id = v_service_id AND is_default = true;

  UPDATE backoffice.bo_products
  SET is_default = true
  WHERE id = p_id;
END;
$function$
;

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
  FROM backoffice.bo_product_locales
  WHERE id = p_id;

  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'Product locale not found';
  END IF;

  UPDATE backoffice.bo_product_locales
  SET is_default = false
  WHERE product_id = v_product_id AND is_default = true;

  UPDATE backoffice.bo_product_locales
  SET is_default = true
  WHERE id = p_id;
END;
$function$
;


;


-- --- Tables

CREATE TABLE backoffice.bo_product_branding_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_locale_id uuid NOT NULL,
    environment text NOT NULL,
    branding_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    schema_def jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_branding_templates_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_level_assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_assets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text NOT NULL,
    asset_key text NOT NULL,
    url text NOT NULL,
    mime_type text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_assets_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_level_branding_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_branding_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text NOT NULL,
    branding_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    schema_def jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_branding_templates_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_level_menu_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_menu_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    menu_id uuid NOT NULL,
    source_item_id uuid,
    item_key text NOT NULL,
    item_type text DEFAULT 'internal'::text NOT NULL,
    nested_menu_key text,
    label text DEFAULT ''::text NOT NULL,
    url text DEFAULT ''::text NOT NULL,
    icon text DEFAULT ''::text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    parent_key text DEFAULT ''::text NOT NULL,
    visible boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_menu_items_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text]))),
    CONSTRAINT bo_product_level_menu_items_item_type_check CHECK ((item_type = ANY (ARRAY['internal'::text, 'external'::text, 'language_selector'::text, 'menu'::text])))
);

--
-- Name: bo_product_level_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    menu_key text NOT NULL,
    label text DEFAULT ''::text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    source_menu_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_menus_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_level_public_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_public_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text NOT NULL,
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_public_config_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_level_social_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_level_social_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    environment text NOT NULL,
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    icon_url text DEFAULT ''::text NOT NULL,
    description text,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_product_level_social_links_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_locale_id uuid NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    menu_key text NOT NULL,
    label text DEFAULT ''::text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source_menu_id uuid
);

--
-- Name: bo_product_social_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_product_social_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_locale_id uuid NOT NULL,
    environment text NOT NULL,
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    icon_url text DEFAULT ''::text NOT NULL,
    description text,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT social_links_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_service_branding_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_service_branding_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    service_id uuid NOT NULL,
    environment text NOT NULL,
    branding_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    schema_def jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_service_branding_templates_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_service_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_service_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    service_id uuid NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    menu_key text NOT NULL,
    label text DEFAULT ''::text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: bo_service_social_links_defaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_service_social_links_defaults (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    service_id uuid NOT NULL,
    environment text NOT NULL,
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    icon_url text DEFAULT ''::text NOT NULL,
    description text,
    display_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_service_social_links_defaults_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_translation_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_translation_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    section_id uuid NOT NULL,
    service_id uuid NOT NULL,
    key text NOT NULL,
    default_value text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    CONSTRAINT bo_translation_keys_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_translation_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_translation_overrides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    translation_key_id uuid NOT NULL,
    product_locale_id uuid NOT NULL,
    environment text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bo_translation_overrides_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_translation_sections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE backoffice.bo_translation_sections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    service_id uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    environment text DEFAULT 'staging'::text NOT NULL,
    CONSTRAINT bo_translation_sections_environment_check CHECK ((environment = ANY (ARRAY['staging'::text, 'production'::text])))
);

--
-- Name: bo_product_branding_templates bo_product_branding_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_branding_templates
    ADD CONSTRAINT bo_product_branding_templates_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_assets bo_product_level_assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_assets
    ADD CONSTRAINT bo_product_level_assets_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_branding_templates bo_product_level_branding_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_branding_templates
    ADD CONSTRAINT bo_product_level_branding_templates_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_menu_items bo_product_level_menu_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menu_items
    ADD CONSTRAINT bo_product_level_menu_items_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_menus bo_product_level_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menus
    ADD CONSTRAINT bo_product_level_menus_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_public_config bo_product_level_public_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_public_config
    ADD CONSTRAINT bo_product_level_public_config_pkey PRIMARY KEY (id);

--
-- Name: bo_product_level_social_links bo_product_level_social_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_social_links
    ADD CONSTRAINT bo_product_level_social_links_pkey PRIMARY KEY (id);

--
-- Name: bo_product_menus bo_product_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_menus
    ADD CONSTRAINT bo_product_menus_pkey PRIMARY KEY (id);

--
-- Name: bo_product_social_links bo_product_social_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_social_links
    ADD CONSTRAINT bo_product_social_links_pkey PRIMARY KEY (id);

--
-- Name: bo_service_branding_templates bo_service_branding_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_branding_templates
    ADD CONSTRAINT bo_service_branding_templates_pkey PRIMARY KEY (id);

--
-- Name: bo_service_menus bo_service_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_menus
    ADD CONSTRAINT bo_service_menus_pkey PRIMARY KEY (id);

--
-- Name: bo_service_social_links_defaults bo_service_social_links_defaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_social_links_defaults
    ADD CONSTRAINT bo_service_social_links_defaults_pkey PRIMARY KEY (id);

--
-- Name: bo_translation_keys bo_translation_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_keys
    ADD CONSTRAINT bo_translation_keys_pkey PRIMARY KEY (id);

--
-- Name: bo_translation_keys bo_translation_keys_section_id_key_environment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_keys
    ADD CONSTRAINT bo_translation_keys_section_id_key_environment_key UNIQUE (section_id, key, environment);

--
-- Name: bo_translation_overrides bo_translation_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_overrides
    ADD CONSTRAINT bo_translation_overrides_pkey PRIMARY KEY (id);

--
-- Name: bo_translation_overrides bo_translation_overrides_translation_key_id_product_locale__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_overrides
    ADD CONSTRAINT bo_translation_overrides_translation_key_id_product_locale__key UNIQUE (translation_key_id, product_locale_id, environment);

--
-- Name: bo_translation_sections bo_translation_sections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_sections
    ADD CONSTRAINT bo_translation_sections_pkey PRIMARY KEY (id);

--
-- Name: bo_translation_sections bo_translation_sections_service_id_name_environment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_sections
    ADD CONSTRAINT bo_translation_sections_service_id_name_environment_key UNIQUE (service_id, name, environment);

--
-- Name: bo_product_branding_templates_locale_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_branding_templates_locale_env_key ON backoffice.bo_product_branding_templates USING btree (product_locale_id, environment);

--
-- Name: bo_product_level_assets_product_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_assets_product_env_key ON backoffice.bo_product_level_assets USING btree (product_id, environment, asset_key);

--
-- Name: bo_product_level_branding_templates_product_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_branding_templates_product_env_key ON backoffice.bo_product_level_branding_templates USING btree (product_id, environment);

--
-- Name: bo_product_level_menu_items_menu_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_menu_items_menu_key ON backoffice.bo_product_level_menu_items USING btree (menu_id, item_key);

--
-- Name: bo_product_level_menus_product_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_menus_product_env_key ON backoffice.bo_product_level_menus USING btree (product_id, environment, menu_key);

--
-- Name: bo_product_level_public_config_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_public_config_uniq ON backoffice.bo_product_level_public_config USING btree (product_id, environment, key);

--
-- Name: bo_product_level_social_links_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_level_social_links_uniq ON backoffice.bo_product_level_social_links USING btree (product_id, environment, key);

--
-- Name: bo_product_menus_locale_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_menus_locale_env_key ON backoffice.bo_product_menus USING btree (product_locale_id, environment, menu_key);

--
-- Name: bo_product_social_links_locale_env_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bo_product_social_links_locale_env_idx ON backoffice.bo_product_social_links USING btree (product_locale_id, environment);

--
-- Name: bo_product_social_links_locale_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_product_social_links_locale_env_key ON backoffice.bo_product_social_links USING btree (product_locale_id, environment, key);

--
-- Name: bo_service_branding_templates_service_id_environment_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_service_branding_templates_service_id_environment_key ON backoffice.bo_service_branding_templates USING btree (service_id, environment);

--
-- Name: bo_service_menus_service_env_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_service_menus_service_env_key ON backoffice.bo_service_menus USING btree (service_id, environment, menu_key);

--
-- Name: bo_service_social_links_defaults_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bo_service_social_links_defaults_uniq ON backoffice.bo_service_social_links_defaults USING btree (service_id, environment, key);

--
-- Name: idx_bo_product_level_menu_items_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_product_level_menu_items_product ON backoffice.bo_product_level_menu_items USING btree (product_id, environment);

--
-- Name: idx_bo_product_level_menu_items_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_product_level_menu_items_source ON backoffice.bo_product_level_menu_items USING btree (source_item_id);

--
-- Name: idx_bo_product_level_menus_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_product_level_menus_source ON backoffice.bo_product_level_menus USING btree (source_menu_id);

--
-- Name: idx_bo_product_menus_product_locale_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_product_menus_product_locale_id ON backoffice.bo_product_menus USING btree (product_locale_id);

--
-- Name: idx_bo_product_menus_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_product_menus_source ON backoffice.bo_product_menus USING btree (source_menu_id);

--
-- Name: idx_bo_service_menus_service_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bo_service_menus_service_id ON backoffice.bo_service_menus USING btree (service_id);

--
-- Name: idx_translation_keys_section; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_keys_section ON backoffice.bo_translation_keys USING btree (section_id);

--
-- Name: idx_translation_keys_service_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_keys_service_env ON backoffice.bo_translation_keys USING btree (service_id, environment);

--
-- Name: idx_translation_overrides_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_overrides_key ON backoffice.bo_translation_overrides USING btree (translation_key_id);

--
-- Name: idx_translation_overrides_locale_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_overrides_locale_env ON backoffice.bo_translation_overrides USING btree (product_locale_id, environment);

--
-- Name: idx_translation_sections_service_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_translation_sections_service_env ON backoffice.bo_translation_sections USING btree (service_id, environment);

--
-- Name: bo_product_level_menu_items product_level_menu_items_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_menu_items_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_product_level_menu_items FOR EACH ROW EXECUTE FUNCTION backoffice.bump_product_locales_config_version();

--
-- Name: bo_product_level_menu_items product_level_menu_items_propagate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_menu_items_propagate AFTER INSERT OR UPDATE ON backoffice.bo_product_level_menu_items FOR EACH ROW EXECUTE FUNCTION backoffice.propagate_product_level_menu_item();

--
-- Name: bo_product_level_menus product_level_menus_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_menus_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_product_level_menus FOR EACH ROW EXECUTE FUNCTION backoffice.bump_product_locales_config_version();

--
-- Name: bo_product_level_menus product_level_menus_propagate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_menus_propagate AFTER INSERT OR UPDATE ON backoffice.bo_product_level_menus FOR EACH ROW EXECUTE FUNCTION backoffice.propagate_product_level_menu();

--
-- Name: bo_product_level_public_config product_level_public_config_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_public_config_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_product_level_public_config FOR EACH ROW EXECUTE FUNCTION backoffice.bump_product_locales_config_version();

--
-- Name: bo_product_level_social_links product_level_social_links_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_level_social_links_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_product_level_social_links FOR EACH ROW EXECUTE FUNCTION backoffice.bump_product_locales_config_version();

--
-- Name: bo_service_menus service_menus_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER service_menus_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_service_menus FOR EACH ROW EXECUTE FUNCTION backoffice.bump_service_locales_config_version();

--
-- Name: bo_service_menus service_menus_propagate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER service_menus_propagate AFTER INSERT OR UPDATE ON backoffice.bo_service_menus FOR EACH ROW EXECUTE FUNCTION backoffice.propagate_service_menu();

--
-- Name: bo_service_social_links_defaults service_social_links_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER service_social_links_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_service_social_links_defaults FOR EACH ROW EXECUTE FUNCTION backoffice.bump_service_locales_config_version();

--
-- Name: bo_product_social_links social_links_bump_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER social_links_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_product_social_links FOR EACH ROW EXECUTE FUNCTION public.bump_locale_config_version();

--
-- Name: bo_product_branding_templates bo_product_branding_templates_product_locale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_branding_templates
    ADD CONSTRAINT bo_product_branding_templates_product_locale_id_fkey FOREIGN KEY (product_locale_id) REFERENCES backoffice.bo_product_locales(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_assets bo_product_level_assets_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_assets
    ADD CONSTRAINT bo_product_level_assets_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_branding_templates bo_product_level_branding_templates_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_branding_templates
    ADD CONSTRAINT bo_product_level_branding_templates_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_menu_items bo_product_level_menu_items_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menu_items
    ADD CONSTRAINT bo_product_level_menu_items_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES backoffice.bo_product_level_menus(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_menu_items bo_product_level_menu_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menu_items
    ADD CONSTRAINT bo_product_level_menu_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_menu_items bo_product_level_menu_items_source_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menu_items
    ADD CONSTRAINT bo_product_level_menu_items_source_item_id_fkey FOREIGN KEY (source_item_id) REFERENCES backoffice.bo_service_menu_items_defaults(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_menus bo_product_level_menus_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menus
    ADD CONSTRAINT bo_product_level_menus_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_menus bo_product_level_menus_source_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_menus
    ADD CONSTRAINT bo_product_level_menus_source_menu_id_fkey FOREIGN KEY (source_menu_id) REFERENCES backoffice.bo_service_menus(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_public_config bo_product_level_public_config_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_public_config
    ADD CONSTRAINT bo_product_level_public_config_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_level_social_links bo_product_level_social_links_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_level_social_links
    ADD CONSTRAINT bo_product_level_social_links_product_id_fkey FOREIGN KEY (product_id) REFERENCES backoffice.bo_products(id) ON DELETE CASCADE;

--
-- Name: bo_product_menus bo_product_menus_product_locale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_menus
    ADD CONSTRAINT bo_product_menus_product_locale_id_fkey FOREIGN KEY (product_locale_id) REFERENCES backoffice.bo_product_locales(id) ON DELETE CASCADE;

--
-- Name: bo_product_menus bo_product_menus_source_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_menus
    ADD CONSTRAINT bo_product_menus_source_menu_id_fkey FOREIGN KEY (source_menu_id) REFERENCES backoffice.bo_product_level_menus(id) ON DELETE CASCADE;

--
-- Name: bo_product_social_links bo_product_social_links_product_locale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_product_social_links
    ADD CONSTRAINT bo_product_social_links_product_locale_id_fkey FOREIGN KEY (product_locale_id) REFERENCES backoffice.bo_product_locales(id) ON DELETE CASCADE;

--
-- Name: bo_service_branding_templates bo_service_branding_templates_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_branding_templates
    ADD CONSTRAINT bo_service_branding_templates_service_id_fkey FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id) ON DELETE CASCADE;

--
-- Name: bo_service_menus bo_service_menus_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_menus
    ADD CONSTRAINT bo_service_menus_service_id_fkey FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id) ON DELETE CASCADE;

--
-- Name: bo_service_social_links_defaults bo_service_social_links_defaults_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_service_social_links_defaults
    ADD CONSTRAINT bo_service_social_links_defaults_service_id_fkey FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id) ON DELETE CASCADE;

--
-- Name: bo_translation_keys bo_translation_keys_section_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_keys
    ADD CONSTRAINT bo_translation_keys_section_id_fkey FOREIGN KEY (section_id) REFERENCES backoffice.bo_translation_sections(id) ON DELETE CASCADE;

--
-- Name: bo_translation_keys bo_translation_keys_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_keys
    ADD CONSTRAINT bo_translation_keys_service_id_fkey FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id);

--
-- Name: bo_translation_overrides bo_translation_overrides_product_locale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_overrides
    ADD CONSTRAINT bo_translation_overrides_product_locale_id_fkey FOREIGN KEY (product_locale_id) REFERENCES backoffice.bo_product_locales(id);

--
-- Name: bo_translation_overrides bo_translation_overrides_translation_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_overrides
    ADD CONSTRAINT bo_translation_overrides_translation_key_id_fkey FOREIGN KEY (translation_key_id) REFERENCES backoffice.bo_translation_keys(id) ON DELETE CASCADE;

--
-- Name: bo_translation_sections bo_translation_sections_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY backoffice.bo_translation_sections
    ADD CONSTRAINT bo_translation_sections_service_id_fkey FOREIGN KEY (service_id) REFERENCES backoffice.bo_services(id);

--
-- Name: bo_product_level_public_config Admins delete bo_product_level_public_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete bo_product_level_public_config" ON backoffice.bo_product_level_public_config FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_product_level_social_links Admins delete bo_product_level_social_links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete bo_product_level_social_links" ON backoffice.bo_product_level_social_links FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_service_social_links_defaults Admins delete bo_service_social_links_defaults; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete bo_service_social_links_defaults" ON backoffice.bo_service_social_links_defaults FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_product_branding_templates Admins delete product_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete product_branding_templates" ON backoffice.bo_product_branding_templates FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_service_branding_templates Admins delete service_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete service_branding_templates" ON backoffice.bo_service_branding_templates FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_product_social_links Admins delete social links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins delete social links" ON backoffice.bo_product_social_links FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'::text));

--
-- Name: bo_product_level_public_config Anyone reads bo_product_level_public_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads bo_product_level_public_config" ON backoffice.bo_product_level_public_config FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_product_level_social_links Anyone reads bo_product_level_social_links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads bo_product_level_social_links" ON backoffice.bo_product_level_social_links FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_service_social_links_defaults Anyone reads bo_service_social_links_defaults; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads bo_service_social_links_defaults" ON backoffice.bo_service_social_links_defaults FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_product_branding_templates Anyone reads product_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads product_branding_templates" ON backoffice.bo_product_branding_templates FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_product_level_assets Anyone reads product_level_assets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads product_level_assets" ON backoffice.bo_product_level_assets FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_product_level_branding_templates Anyone reads product_level_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads product_level_branding_templates" ON backoffice.bo_product_level_branding_templates FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_service_branding_templates Anyone reads service_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads service_branding_templates" ON backoffice.bo_service_branding_templates FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_product_social_links Anyone reads social links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads social links" ON backoffice.bo_product_social_links FOR SELECT TO authenticated, anon USING (true);

--
-- Name: bo_translation_keys Anyone reads translation_keys; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads translation_keys" ON backoffice.bo_translation_keys FOR SELECT TO authenticated USING (true);

--
-- Name: bo_translation_overrides Anyone reads translation_overrides; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads translation_overrides" ON backoffice.bo_translation_overrides FOR SELECT TO authenticated USING (true);

--
-- Name: bo_translation_sections Anyone reads translation_sections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Anyone reads translation_sections" ON backoffice.bo_translation_sections FOR SELECT TO authenticated USING (true);

--
-- Name: bo_product_level_menu_items Authenticated users can delete bo_product_level_menu_items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete bo_product_level_menu_items" ON backoffice.bo_product_level_menu_items FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menus Authenticated users can delete bo_product_level_menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete bo_product_level_menus" ON backoffice.bo_product_level_menus FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_menus Authenticated users can delete product menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete product menus" ON backoffice.bo_product_menus FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_service_menus Authenticated users can delete service menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete service menus" ON backoffice.bo_service_menus FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menu_items Authenticated users can insert bo_product_level_menu_items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert bo_product_level_menu_items" ON backoffice.bo_product_level_menu_items FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menus Authenticated users can insert bo_product_level_menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert bo_product_level_menus" ON backoffice.bo_product_level_menus FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_menus Authenticated users can insert product menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert product menus" ON backoffice.bo_product_menus FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_service_menus Authenticated users can insert service menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert service menus" ON backoffice.bo_service_menus FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menu_items Authenticated users can read bo_product_level_menu_items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read bo_product_level_menu_items" ON backoffice.bo_product_level_menu_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menus Authenticated users can read bo_product_level_menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read bo_product_level_menus" ON backoffice.bo_product_level_menus FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_menus Authenticated users can read product menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read product menus" ON backoffice.bo_product_menus FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_service_menus Authenticated users can read service menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read service menus" ON backoffice.bo_service_menus FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menu_items Authenticated users can update bo_product_level_menu_items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update bo_product_level_menu_items" ON backoffice.bo_product_level_menu_items FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_menus Authenticated users can update bo_product_level_menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update bo_product_level_menus" ON backoffice.bo_product_level_menus FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_menus Authenticated users can update product menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update product menus" ON backoffice.bo_product_menus FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_service_menus Authenticated users can update service menus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update service menus" ON backoffice.bo_service_menus FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid())))) WITH CHECK ((EXISTS ( SELECT 1
   FROM backoffice.bo_backoffice_users
  WHERE (bo_backoffice_users.user_id = auth.uid()))));

--
-- Name: bo_product_level_assets Editors delete product_level_assets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors delete product_level_assets" ON backoffice.bo_product_level_assets FOR DELETE TO authenticated USING (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_branding_templates Editors delete product_level_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors delete product_level_branding_templates" ON backoffice.bo_product_level_branding_templates FOR DELETE TO authenticated USING (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_keys Editors delete translation_keys; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors delete translation_keys" ON backoffice.bo_translation_keys FOR DELETE TO authenticated USING (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_overrides Editors delete translation_overrides; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors delete translation_overrides" ON backoffice.bo_translation_overrides FOR DELETE TO authenticated USING (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_sections Editors delete translation_sections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors delete translation_sections" ON backoffice.bo_translation_sections FOR DELETE TO authenticated USING (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_public_config Editors insert bo_product_level_public_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert bo_product_level_public_config" ON backoffice.bo_product_level_public_config FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_social_links Editors insert bo_product_level_social_links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert bo_product_level_social_links" ON backoffice.bo_product_level_social_links FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_service_social_links_defaults Editors insert bo_service_social_links_defaults; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert bo_service_social_links_defaults" ON backoffice.bo_service_social_links_defaults FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_branding_templates Editors insert product_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert product_branding_templates" ON backoffice.bo_product_branding_templates FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_assets Editors insert product_level_assets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert product_level_assets" ON backoffice.bo_product_level_assets FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_branding_templates Editors insert product_level_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert product_level_branding_templates" ON backoffice.bo_product_level_branding_templates FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_service_branding_templates Editors insert service_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert service_branding_templates" ON backoffice.bo_service_branding_templates FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_social_links Editors insert social links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert social links" ON backoffice.bo_product_social_links FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_keys Editors insert translation_keys; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert translation_keys" ON backoffice.bo_translation_keys FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_overrides Editors insert translation_overrides; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert translation_overrides" ON backoffice.bo_translation_overrides FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_sections Editors insert translation_sections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors insert translation_sections" ON backoffice.bo_translation_sections FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_public_config Editors update bo_product_level_public_config; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update bo_product_level_public_config" ON backoffice.bo_product_level_public_config FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_social_links Editors update bo_product_level_social_links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update bo_product_level_social_links" ON backoffice.bo_product_level_social_links FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_service_social_links_defaults Editors update bo_service_social_links_defaults; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update bo_service_social_links_defaults" ON backoffice.bo_service_social_links_defaults FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_branding_templates Editors update product_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update product_branding_templates" ON backoffice.bo_product_branding_templates FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_assets Editors update product_level_assets; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update product_level_assets" ON backoffice.bo_product_level_assets FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_level_branding_templates Editors update product_level_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update product_level_branding_templates" ON backoffice.bo_product_level_branding_templates FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_service_branding_templates Editors update service_branding_templates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update service_branding_templates" ON backoffice.bo_service_branding_templates FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_social_links Editors update social links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update social links" ON backoffice.bo_product_social_links FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_keys Editors update translation_keys; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update translation_keys" ON backoffice.bo_translation_keys FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_overrides Editors update translation_overrides; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update translation_overrides" ON backoffice.bo_translation_overrides FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_translation_sections Editors update translation_sections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Editors update translation_sections" ON backoffice.bo_translation_sections FOR UPDATE TO authenticated USING (public.is_backoffice_role('editor'::text)) WITH CHECK (public.is_backoffice_role('editor'::text));

--
-- Name: bo_product_branding_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_branding_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_assets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_assets ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_branding_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_branding_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_menu_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_menu_items ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_menus; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_menus ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_public_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_public_config ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_level_social_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_level_social_links ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_menus; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_menus ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_product_social_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_product_social_links ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_service_branding_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_service_branding_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_service_menus; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_service_menus ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_service_social_links_defaults; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_service_social_links_defaults ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_translation_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_translation_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_translation_overrides; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_translation_overrides ENABLE ROW LEVEL SECURITY;

--
-- Name: bo_translation_sections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE backoffice.bo_translation_sections ENABLE ROW LEVEL SECURITY;

--
-- Name: TABLE bo_product_branding_templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_branding_templates TO anon;
GRANT ALL ON TABLE backoffice.bo_product_branding_templates TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_branding_templates TO service_role;

--
-- Name: TABLE bo_product_level_assets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_assets TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_assets TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_assets TO service_role;

--
-- Name: TABLE bo_product_level_branding_templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_branding_templates TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_branding_templates TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_branding_templates TO service_role;

--
-- Name: TABLE bo_product_level_menu_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_menu_items TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_menu_items TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_menu_items TO service_role;

--
-- Name: TABLE bo_product_level_menus; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_menus TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_menus TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_menus TO service_role;

--
-- Name: TABLE bo_product_level_public_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_public_config TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_public_config TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_public_config TO service_role;

--
-- Name: TABLE bo_product_level_social_links; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_level_social_links TO anon;
GRANT ALL ON TABLE backoffice.bo_product_level_social_links TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_level_social_links TO service_role;

--
-- Name: TABLE bo_product_menus; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_menus TO anon;
GRANT ALL ON TABLE backoffice.bo_product_menus TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_menus TO service_role;

--
-- Name: TABLE bo_product_social_links; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_product_social_links TO anon;
GRANT ALL ON TABLE backoffice.bo_product_social_links TO authenticated;
GRANT ALL ON TABLE backoffice.bo_product_social_links TO service_role;

--
-- Name: TABLE bo_service_branding_templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_service_branding_templates TO anon;
GRANT ALL ON TABLE backoffice.bo_service_branding_templates TO authenticated;
GRANT ALL ON TABLE backoffice.bo_service_branding_templates TO service_role;

--
-- Name: TABLE bo_service_menus; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_service_menus TO anon;
GRANT ALL ON TABLE backoffice.bo_service_menus TO authenticated;
GRANT ALL ON TABLE backoffice.bo_service_menus TO service_role;

--
-- Name: TABLE bo_service_social_links_defaults; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_service_social_links_defaults TO anon;
GRANT ALL ON TABLE backoffice.bo_service_social_links_defaults TO authenticated;
GRANT ALL ON TABLE backoffice.bo_service_social_links_defaults TO service_role;

--
-- Name: TABLE bo_translation_keys; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_translation_keys TO anon;
GRANT ALL ON TABLE backoffice.bo_translation_keys TO authenticated;
GRANT ALL ON TABLE backoffice.bo_translation_keys TO service_role;

--
-- Name: TABLE bo_translation_overrides; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_translation_overrides TO anon;
GRANT ALL ON TABLE backoffice.bo_translation_overrides TO authenticated;
GRANT ALL ON TABLE backoffice.bo_translation_overrides TO service_role;

--
-- Name: TABLE bo_translation_sections; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE backoffice.bo_translation_sections TO anon;
GRANT ALL ON TABLE backoffice.bo_translation_sections TO authenticated;
GRANT ALL ON TABLE backoffice.bo_translation_sections TO service_role;


-- --- Columns, constraints, indexes and triggers on existing tables

ALTER TABLE ONLY backoffice.bo_locale_avatar ADD COLUMN agent_id text;
ALTER TABLE ONLY backoffice.bo_product_avatar ADD COLUMN agent_id text;
ALTER TABLE ONLY backoffice.bo_product_footer_items ADD COLUMN link_type text DEFAULT 'internal'::text NOT NULL;
ALTER TABLE ONLY backoffice.bo_product_footer_items ADD COLUMN document_slug text;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD COLUMN menu_id uuid;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD COLUMN item_type text DEFAULT 'internal'::text NOT NULL;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD COLUMN nested_menu_key text;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD COLUMN document_slug text;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD COLUMN source_item_id uuid;
ALTER TABLE ONLY backoffice.bo_service_avatar_defaults ADD COLUMN agent_id text;
ALTER TABLE ONLY backoffice.bo_service_menu_items_defaults ADD COLUMN menu_id uuid;
ALTER TABLE ONLY backoffice.bo_service_menu_items_defaults ADD COLUMN item_type text DEFAULT 'internal'::text NOT NULL;
ALTER TABLE ONLY backoffice.bo_service_menu_items_defaults ADD COLUMN nested_menu_key text;
ALTER TABLE ONLY backoffice.bo_services ADD COLUMN translations_default_locale text;
ALTER TABLE ONLY backoffice.bo_product_footer_items ADD CONSTRAINT bo_product_footer_items_link_type_check CHECK ((link_type = ANY (ARRAY['internal'::text, 'external'::text, 'document'::text])));
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD CONSTRAINT bo_product_menu_items_item_type_check CHECK ((item_type = ANY (ARRAY['internal'::text, 'external'::text, 'language_selector'::text, 'menu'::text, 'document'::text])));
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD CONSTRAINT bo_product_menu_items_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES backoffice.bo_product_menus(id) ON DELETE CASCADE;
ALTER TABLE ONLY backoffice.bo_product_menu_items ADD CONSTRAINT bo_product_menu_items_source_item_id_fkey FOREIGN KEY (source_item_id) REFERENCES backoffice.bo_product_level_menu_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY backoffice.bo_service_menu_items_defaults ADD CONSTRAINT bo_service_menu_items_defaults_item_type_check CHECK ((item_type = ANY (ARRAY['internal'::text, 'external'::text, 'language_selector'::text, 'menu'::text])));
ALTER TABLE ONLY backoffice.bo_service_menu_items_defaults ADD CONSTRAINT bo_service_menu_items_defaults_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES backoffice.bo_service_menus(id) ON DELETE CASCADE;
CREATE UNIQUE INDEX bo_product_menu_items_menu_id_item_key_key ON backoffice.bo_product_menu_items USING btree (menu_id, item_key);
CREATE UNIQUE INDEX bo_service_menu_items_defaults_menu_id_item_key_key ON backoffice.bo_service_menu_items_defaults USING btree (menu_id, item_key);
CREATE INDEX idx_bo_product_menu_items_source ON backoffice.bo_product_menu_items USING btree (source_item_id);
CREATE INDEX idx_footer_items_document_slug ON backoffice.bo_product_footer_items USING btree (product_locale_id, environment, document_slug) WHERE (document_slug IS NOT NULL);
CREATE INDEX idx_product_menu_items_document_slug ON backoffice.bo_product_menu_items USING btree (product_locale_id, environment, document_slug) WHERE (document_slug IS NOT NULL);
CREATE TRIGGER product_locales_seed_menus AFTER INSERT ON backoffice.bo_product_locales FOR EACH ROW EXECUTE FUNCTION backoffice.on_locale_created_seed_menus();
CREATE TRIGGER product_menu_items_normalize_link BEFORE INSERT OR UPDATE ON backoffice.bo_product_menu_items FOR EACH ROW EXECUTE FUNCTION backoffice.normalize_menu_item_link();
CREATE TRIGGER products_seed_menus AFTER INSERT ON backoffice.bo_products FOR EACH ROW EXECUTE FUNCTION backoffice.on_product_created_seed_menus();
CREATE TRIGGER service_menu_items_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_service_menu_items_defaults FOR EACH ROW EXECUTE FUNCTION backoffice.bump_service_locales_config_version();
CREATE TRIGGER service_menu_items_propagate AFTER INSERT OR UPDATE ON backoffice.bo_service_menu_items_defaults FOR EACH ROW EXECUTE FUNCTION backoffice.propagate_service_menu_item();
CREATE TRIGGER service_public_config_bump_version AFTER INSERT OR DELETE OR UPDATE ON backoffice.bo_service_public_config_defaults FOR EACH ROW EXECUTE FUNCTION backoffice.bump_service_locales_config_version();
CREATE INDEX idx_bo_product_menu_items_product_locale_id ON backoffice.bo_product_menu_items USING btree (product_locale_id);
CREATE INDEX idx_bo_products_slug ON backoffice.bo_products USING btree (slug);
CREATE INDEX idx_bo_backoffice_audit_log_actor_id ON backoffice.bo_backoffice_audit_log USING btree (actor_id);
CREATE INDEX idx_bo_backoffice_audit_log_entity ON backoffice.bo_backoffice_audit_log USING btree (entity_type, entity_id);


-- =============================================================================
-- App Screens + Atom legal documents (from bravigo-migration
-- 20261028120000_add_app_screens_and_atom_legal.sql, moved to the backoffice schema)
-- =============================================================================

-- Product time zone (schedules are evaluated in the product's local time)
ALTER TABLE backoffice.bo_products ADD COLUMN IF NOT EXISTS timezone text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bo_products_timezone_format_check') THEN
    ALTER TABLE backoffice.bo_products
      ADD CONSTRAINT bo_products_timezone_format_check
      CHECK (timezone IS NULL OR timezone ~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$|^UTC$');
  END IF;
END $$;

-- Screens
CREATE TABLE IF NOT EXISTS backoffice.bo_app_screens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id uuid REFERENCES backoffice.bo_services(id) ON DELETE CASCADE,
  product_id uuid REFERENCES backoffice.bo_products(id) ON DELETE CASCADE,
  product_locale_id uuid REFERENCES backoffice.bo_product_locales(id) ON DELETE CASCADE,
  environment text NOT NULL CHECK (environment IN ('staging', 'production')),
  slug text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  name text NOT NULL DEFAULT '',
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bo_app_screens_one_owner CHECK (num_nonnulls(service_id, product_id, product_locale_id) = 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS bo_app_screens_service_slug_uq
  ON backoffice.bo_app_screens (service_id, environment, slug) WHERE service_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bo_app_screens_product_slug_uq
  ON backoffice.bo_app_screens (product_id, environment, slug) WHERE product_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bo_app_screens_locale_slug_uq
  ON backoffice.bo_app_screens (product_locale_id, environment, slug) WHERE product_locale_id IS NOT NULL;

-- Widgets
CREATE TABLE IF NOT EXISTS backoffice.bo_app_screen_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  screen_id uuid NOT NULL REFERENCES backoffice.bo_app_screens(id) ON DELETE CASCADE,
  platform text NOT NULL DEFAULT 'mobile' CHECK (platform IN ('mobile', 'desktop')),
  widget_type text NOT NULL CHECK (widget_type ~ '^[a-z0-9_]{1,64}$'),
  title text NOT NULL DEFAULT '',
  show_title boolean NOT NULL DEFAULT true,
  enabled boolean NOT NULL DEFAULT true,
  position integer NOT NULL DEFAULT 0,
  col_span integer NOT NULL DEFAULT 12 CHECK (col_span BETWEEN 1 AND 12),
  config jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  start_at_local timestamp without time zone,
  end_at_local timestamp without time zone,
  CONSTRAINT bo_app_screen_sections_schedule_check
    CHECK (start_at_local IS NULL OR end_at_local IS NULL OR end_at_local > start_at_local)
);

CREATE INDEX IF NOT EXISTS bo_app_screen_sections_screen_idx
  ON backoffice.bo_app_screen_sections (screen_id, platform, position);

-- Label List
CREATE TABLE IF NOT EXISTS backoffice.bo_app_screen_labels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id uuid NOT NULL REFERENCES backoffice.bo_services(id) ON DELETE CASCADE,
  environment text NOT NULL CHECK (environment IN ('staging', 'production')),
  label text NOT NULL CHECK (btrim(label) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS bo_app_screen_labels_unique
  ON backoffice.bo_app_screen_labels (service_id, environment, lower(label));

-- RLS
ALTER TABLE backoffice.bo_app_screens ENABLE ROW LEVEL SECURITY;
ALTER TABLE backoffice.bo_app_screen_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE backoffice.bo_app_screen_labels ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_app_screens, backoffice.bo_app_screen_sections, backoffice.bo_app_screen_labels TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_app_screens, backoffice.bo_app_screen_sections, backoffice.bo_app_screen_labels TO service_role;
REVOKE ALL ON backoffice.bo_app_screens, backoffice.bo_app_screen_sections, backoffice.bo_app_screen_labels FROM anon;

DROP POLICY IF EXISTS "Backoffice reads app_screens" ON backoffice.bo_app_screens;
CREATE POLICY "Backoffice reads app_screens" ON backoffice.bo_app_screens FOR SELECT
  TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins insert app_screens" ON backoffice.bo_app_screens;
CREATE POLICY "Admins insert app_screens" ON backoffice.bo_app_screens FOR INSERT
  TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins update app_screens" ON backoffice.bo_app_screens;
CREATE POLICY "Admins update app_screens" ON backoffice.bo_app_screens FOR UPDATE
  TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins delete app_screens" ON backoffice.bo_app_screens;
CREATE POLICY "Admins delete app_screens" ON backoffice.bo_app_screens FOR DELETE
  TO authenticated USING (public.is_backoffice_role('admin'));

DROP POLICY IF EXISTS "Backoffice reads app_screen_sections" ON backoffice.bo_app_screen_sections;
CREATE POLICY "Backoffice reads app_screen_sections" ON backoffice.bo_app_screen_sections FOR SELECT
  TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins insert app_screen_sections" ON backoffice.bo_app_screen_sections;
CREATE POLICY "Admins insert app_screen_sections" ON backoffice.bo_app_screen_sections FOR INSERT
  TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins update app_screen_sections" ON backoffice.bo_app_screen_sections;
CREATE POLICY "Admins update app_screen_sections" ON backoffice.bo_app_screen_sections FOR UPDATE
  TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins delete app_screen_sections" ON backoffice.bo_app_screen_sections;
CREATE POLICY "Admins delete app_screen_sections" ON backoffice.bo_app_screen_sections FOR DELETE
  TO authenticated USING (public.is_backoffice_role('admin'));

DROP POLICY IF EXISTS "Backoffice reads app_screen_labels" ON backoffice.bo_app_screen_labels;
CREATE POLICY "Backoffice reads app_screen_labels" ON backoffice.bo_app_screen_labels FOR SELECT
  TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins insert app_screen_labels" ON backoffice.bo_app_screen_labels;
CREATE POLICY "Admins insert app_screen_labels" ON backoffice.bo_app_screen_labels FOR INSERT
  TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins update app_screen_labels" ON backoffice.bo_app_screen_labels;
CREATE POLICY "Admins update app_screen_labels" ON backoffice.bo_app_screen_labels FOR UPDATE
  TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins delete app_screen_labels" ON backoffice.bo_app_screen_labels;
CREATE POLICY "Admins delete app_screen_labels" ON backoffice.bo_app_screen_labels FOR DELETE
  TO authenticated USING (public.is_backoffice_role('admin'));

-- Label List helpers
CREATE OR REPLACE FUNCTION backoffice.app_screen_label_usage(p_service_id uuid, p_environment text, p_label text)
RETURNS TABLE (section_id uuid, screen_name text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'backoffice', 'public'
AS $$
  SELECT sec.id, coalesce(nullif(scr.name, ''), scr.slug)
  FROM backoffice.bo_app_screen_sections sec
  JOIN backoffice.bo_app_screens scr ON scr.id = sec.screen_id
  WHERE scr.environment = p_environment
    AND sec.config->>'label' = p_label
    AND (
      scr.service_id = p_service_id
      OR scr.product_id IN (SELECT id FROM backoffice.bo_products WHERE service_id = p_service_id)
      OR scr.product_locale_id IN (
        SELECT pl.id FROM backoffice.bo_product_locales pl JOIN backoffice.bo_products p ON p.id = pl.product_id WHERE p.service_id = p_service_id
      )
    );
$$;

CREATE OR REPLACE FUNCTION backoffice.rename_app_screen_label(p_label_id uuid, p_new_label text)
RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'backoffice', 'public'
AS $$
DECLARE
  v_row backoffice.bo_app_screen_labels%ROWTYPE;
  v_new text := btrim(p_new_label);
  v_count integer;
BEGIN
  IF v_new = '' THEN RAISE EXCEPTION 'Label cannot be empty'; END IF;
  SELECT * INTO v_row FROM backoffice.bo_app_screen_labels WHERE id = p_label_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Label not found'; END IF;

  UPDATE backoffice.bo_app_screen_labels SET label = v_new, updated_at = now() WHERE id = p_label_id;

  UPDATE backoffice.bo_app_screen_sections sec
  SET config = coalesce(sec.config, '{}'::jsonb) || jsonb_build_object('label', v_new), updated_at = now()
  WHERE sec.id IN (SELECT u.section_id FROM app_screen_label_usage(v_row.service_id, v_row.environment, v_row.label) u);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION backoffice.app_screen_label_paths(p_service_id uuid, p_environment text)
RETURNS TABLE (
  label text,
  section_id uuid,
  platform text,
  widget_type text,
  widget_position bigint,
  section_enabled boolean,
  start_at_local timestamp,
  end_at_local timestamp,
  screen_slug text,
  screen_name text,
  screen_enabled boolean,
  service_name text,
  service_slug text,
  product_id uuid,
  product_name text,
  product_slug text,
  locale_id uuid,
  locale_name text,
  locale_code text
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'backoffice', 'public'
AS $$
  WITH scr AS (
    SELECT s.*, coalesce(s.product_id, pl.product_id) AS owner_product_id
    FROM backoffice.bo_app_screens s
    LEFT JOIN backoffice.bo_product_locales pl ON pl.id = s.product_locale_id
    WHERE s.environment = p_environment
  ),
  ranked AS (
    SELECT sec.*, row_number() OVER (PARTITION BY sec.screen_id, sec.platform ORDER BY sec.position, sec.created_at) AS rn
    FROM backoffice.bo_app_screen_sections sec
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
  JOIN backoffice.bo_services sv ON sv.id = p_service_id
  LEFT JOIN backoffice.bo_products p ON p.id = scr.owner_product_id
  LEFT JOIN backoffice.bo_product_locales pl ON pl.id = scr.product_locale_id
  WHERE coalesce(btrim(r.config->>'label'), '') <> ''
    AND (scr.service_id = p_service_id OR p.service_id = p_service_id)
  ORDER BY p.display_name NULLS FIRST, pl.display_name NULLS FIRST, scr.slug, r.platform, r.rn;
$$;

REVOKE EXECUTE ON FUNCTION backoffice.app_screen_label_usage(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION backoffice.app_screen_label_usage(uuid, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION backoffice.rename_app_screen_label(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION backoffice.rename_app_screen_label(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION backoffice.app_screen_label_paths(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION backoffice.app_screen_label_paths(uuid, text) TO authenticated;

-- Default labels for services that already exist when this migration runs
-- (no-op on a fresh database).
INSERT INTO backoffice.bo_app_screen_labels (service_id, environment, label)
SELECT s.id, e.env, d.label
FROM backoffice.bo_services s
CROSS JOIN (VALUES ('staging'), ('production')) AS e(env)
CROSS JOIN (VALUES ('Custom Widget'), ('PlaceholderText'), ('Banner'), ('Video')) AS d(label)
ON CONFLICT DO NOTHING;

-- =============================================================================
-- Part B: Atom legal documents
-- =============================================================================

-- Atom product IDs on bo_products (one per environment)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'backoffice' AND table_name = 'bo_products' AND column_name = 'atom_product_id_staging'
  ) THEN
    ALTER TABLE backoffice.bo_products
      ADD COLUMN atom_product_id_staging integer;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'backoffice' AND table_name = 'bo_products' AND column_name = 'atom_product_id_production'
  ) THEN
    ALTER TABLE backoffice.bo_products
      ADD COLUMN atom_product_id_production integer;
  END IF;
END $$;

-- Slug registry (HTML is fetched live via get-atom-legal-document; never stored here)
CREATE TABLE IF NOT EXISTS backoffice.bo_atom_legal_documents (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id         uuid NOT NULL REFERENCES backoffice.bo_products(id) ON DELETE CASCADE,
  locale             text NOT NULL CONSTRAINT atom_legal_docs_locale_check CHECK (locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  environment        text NOT NULL CONSTRAINT atom_legal_docs_env_check CHECK (environment IN ('staging','production')),
  document_type      text NOT NULL,
  document_name      text NOT NULL,
  atom_document_id   text,
  last_discovered_at timestamptz NOT NULL DEFAULT now(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bo_atom_legal_documents_unique UNIQUE (product_id, locale, environment, document_type)
);

ALTER TABLE backoffice.bo_atom_legal_documents ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_atom_legal_documents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON backoffice.bo_atom_legal_documents TO service_role;
REVOKE ALL ON backoffice.bo_atom_legal_documents FROM anon;

DROP POLICY IF EXISTS "Backoffice users can view atom legal docs" ON backoffice.bo_atom_legal_documents;
CREATE POLICY "Backoffice users can view atom legal docs"
ON backoffice.bo_atom_legal_documents FOR SELECT
TO authenticated
USING (EXISTS (
  SELECT 1 FROM backoffice.bo_backoffice_users bu
  WHERE bu.user_id = auth.uid()
  AND bu.is_active = true
  AND (bu.product_scope @> ARRAY[backoffice.bo_atom_legal_documents.product_id::text] OR bu.role = 'admin')
));

DROP POLICY IF EXISTS "Editors can insert atom legal docs" ON backoffice.bo_atom_legal_documents;
CREATE POLICY "Editors can insert atom legal docs"
ON backoffice.bo_atom_legal_documents FOR INSERT
TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM backoffice.bo_backoffice_users bu
  WHERE bu.user_id = auth.uid()
  AND bu.is_active = true
  AND bu.role IN ('editor','admin')
  AND (bu.product_scope @> ARRAY[backoffice.bo_atom_legal_documents.product_id::text] OR bu.role = 'admin')
));

DROP POLICY IF EXISTS "Editors can update atom legal docs" ON backoffice.bo_atom_legal_documents;
CREATE POLICY "Editors can update atom legal docs"
ON backoffice.bo_atom_legal_documents FOR UPDATE
TO authenticated
USING (EXISTS (
  SELECT 1 FROM backoffice.bo_backoffice_users bu
  WHERE bu.user_id = auth.uid()
  AND bu.is_active = true
  AND bu.role IN ('editor','admin')
  AND (bu.product_scope @> ARRAY[backoffice.bo_atom_legal_documents.product_id::text] OR bu.role = 'admin')
))
WITH CHECK (EXISTS (
  SELECT 1 FROM backoffice.bo_backoffice_users bu
  WHERE bu.user_id = auth.uid()
  AND bu.is_active = true
  AND bu.role IN ('editor','admin')
  AND (bu.product_scope @> ARRAY[backoffice.bo_atom_legal_documents.product_id::text] OR bu.role = 'admin')
));

DROP POLICY IF EXISTS "Editors can delete atom legal docs" ON backoffice.bo_atom_legal_documents;
CREATE POLICY "Editors can delete atom legal docs"
ON backoffice.bo_atom_legal_documents FOR DELETE
TO authenticated
USING (EXISTS (
  SELECT 1 FROM backoffice.bo_backoffice_users bu
  WHERE bu.user_id = auth.uid()
  AND bu.is_active = true
  AND bu.role IN ('editor','admin')
  AND (bu.product_scope @> ARRAY[backoffice.bo_atom_legal_documents.product_id::text] OR bu.role = 'admin')
));

CREATE INDEX IF NOT EXISTS idx_bo_atom_legal_docs_product_locale_env
  ON backoffice.bo_atom_legal_documents (product_id, locale, environment);

-- Mark product documents that are sourced from Atom (live fetch; no version HTML)
ALTER TABLE backoffice.bo_product_documents
  ADD COLUMN IF NOT EXISTS is_atom boolean NOT NULL DEFAULT false;

ALTER TABLE backoffice.bo_product_documents
  ADD COLUMN IF NOT EXISTS atom_document_type text;



-- =============================================================================
-- URL & Behaviour: Service > Product > Language rules + tier action "screen"
-- (docs/url-behaviour.md, backend requests 2026-10-28-page-behaviour-three-levels
-- and 2026-10-28-page-behaviour-tier-screen)
-- =============================================================================

-- Rules: exactly one owner (service, product or language), per-level enable and linked App Screen
ALTER TABLE backoffice.bo_page_behaviour_rules ALTER COLUMN product_id DROP NOT NULL;
ALTER TABLE backoffice.bo_page_behaviour_rules
  ADD COLUMN IF NOT EXISTS service_id uuid REFERENCES backoffice.bo_services(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS product_locale_id uuid REFERENCES backoffice.bo_product_locales(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS screen_slug text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'page_behaviour_rules_one_owner') THEN
    ALTER TABLE backoffice.bo_page_behaviour_rules
      ADD CONSTRAINT page_behaviour_rules_one_owner
      CHECK (num_nonnulls(service_id, product_id, product_locale_id) = 1);
  END IF;
END $$;

DROP INDEX IF EXISTS backoffice.bo_page_behaviour_rules_product_id_environment_path_key;
CREATE UNIQUE INDEX IF NOT EXISTS bo_page_behaviour_rules_service_path_uq
  ON backoffice.bo_page_behaviour_rules (service_id, environment, path) WHERE service_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bo_page_behaviour_rules_product_path_uq
  ON backoffice.bo_page_behaviour_rules (product_id, environment, path) WHERE product_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS bo_page_behaviour_rules_locale_path_uq
  ON backoffice.bo_page_behaviour_rules (product_locale_id, environment, path) WHERE product_locale_id IS NOT NULL;

-- Tiers: action "screen" shows an App Screen (screen_slug required) instead of the page
ALTER TABLE backoffice.bo_page_behaviour_tier_rules ADD COLUMN IF NOT EXISTS screen_slug text;
ALTER TABLE backoffice.bo_page_behaviour_tier_rules DROP CONSTRAINT IF EXISTS page_behaviour_tier_rules_action_check;
ALTER TABLE backoffice.bo_page_behaviour_tier_rules
  ADD CONSTRAINT page_behaviour_tier_rules_action_check CHECK (action IN ('none', 'redirect', 'screen'));
ALTER TABLE backoffice.bo_page_behaviour_tier_rules DROP CONSTRAINT IF EXISTS page_behaviour_tier_rules_screen_slug_check;
ALTER TABLE backoffice.bo_page_behaviour_tier_rules
  ADD CONSTRAINT page_behaviour_tier_rules_screen_slug_check
  CHECK (action <> 'screen' OR (screen_slug IS NOT NULL AND btrim(screen_slug) <> ''));

-- RLS: back-office viewers read, admins write
DROP POLICY IF EXISTS "Authenticated users can read page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
DROP POLICY IF EXISTS "Authenticated users can insert page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
DROP POLICY IF EXISTS "Authenticated users can update page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
DROP POLICY IF EXISTS "Authenticated users can delete page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
DROP POLICY IF EXISTS "Authenticated users can read page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
DROP POLICY IF EXISTS "Authenticated users can insert page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
DROP POLICY IF EXISTS "Authenticated users can update page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
DROP POLICY IF EXISTS "Authenticated users can delete page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;

DROP POLICY IF EXISTS "Viewers can read page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
CREATE POLICY "Viewers can read page_behaviour_rules" ON backoffice.bo_page_behaviour_rules
  FOR SELECT TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins can insert page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
CREATE POLICY "Admins can insert page_behaviour_rules" ON backoffice.bo_page_behaviour_rules
  FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can update page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
CREATE POLICY "Admins can update page_behaviour_rules" ON backoffice.bo_page_behaviour_rules
  FOR UPDATE TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can delete page_behaviour_rules" ON backoffice.bo_page_behaviour_rules;
CREATE POLICY "Admins can delete page_behaviour_rules" ON backoffice.bo_page_behaviour_rules
  FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'));

DROP POLICY IF EXISTS "Viewers can read page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
CREATE POLICY "Viewers can read page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules
  FOR SELECT TO authenticated USING (public.is_backoffice_role('viewer'));
DROP POLICY IF EXISTS "Admins can insert page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
CREATE POLICY "Admins can insert page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules
  FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can update page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
CREATE POLICY "Admins can update page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules
  FOR UPDATE TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can delete page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules;
CREATE POLICY "Admins can delete page_behaviour_tier_rules" ON backoffice.bo_page_behaviour_tier_rules
  FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'));



-- =============================================================================
-- Login Methods: Google / iOS types, admin-only writes, seed trigger as definer
-- (docs/login-methods.md, migrations login_methods_google_ios_admin_write and
-- seed_product_defaults_security_definer)
-- =============================================================================

ALTER TABLE backoffice.bo_product_login_methods DROP CONSTRAINT IF EXISTS product_login_methods_type_check;
ALTER TABLE backoffice.bo_product_login_methods
  ADD CONSTRAINT product_login_methods_type_check CHECK (type IN (
    'email_password', 'msisdn_pin', 'otp', 'pinless',
    'email_password_msisdn_pin', 'email_password_otp', 'email_password_pinless',
    'google', 'ios'
  ));

-- RLS: back-office viewers read, admins write
DROP POLICY IF EXISTS "Editors can insert login methods" ON backoffice.bo_product_login_methods;
DROP POLICY IF EXISTS "Editors can update login methods" ON backoffice.bo_product_login_methods;
DROP POLICY IF EXISTS "Editors can delete login methods" ON backoffice.bo_product_login_methods;

DROP POLICY IF EXISTS "Admins can insert login methods" ON backoffice.bo_product_login_methods;
CREATE POLICY "Admins can insert login methods" ON backoffice.bo_product_login_methods
  FOR INSERT TO authenticated WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can update login methods" ON backoffice.bo_product_login_methods;
CREATE POLICY "Admins can update login methods" ON backoffice.bo_product_login_methods
  FOR UPDATE TO authenticated USING (public.is_backoffice_role('admin')) WITH CHECK (public.is_backoffice_role('admin'));
DROP POLICY IF EXISTS "Admins can delete login methods" ON backoffice.bo_product_login_methods;
CREATE POLICY "Admins can delete login methods" ON backoffice.bo_product_login_methods
  FOR DELETE TO authenticated USING (public.is_backoffice_role('admin'));

-- New products seed their default login method even when an editor creates them
ALTER FUNCTION public.seed_default_content_consumption_rules() SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION public.seed_default_content_consumption_rules() FROM PUBLIC, anon, authenticated;



-- =============================================================================
-- App Screens: widget audience (visible_to = guest / free / premium, all by default).
-- screen-layout returns it and the app filters.
-- =============================================================================

ALTER TABLE backoffice.bo_app_screen_sections
  ADD COLUMN IF NOT EXISTS visible_to text[] NOT NULL DEFAULT ARRAY['guest', 'free', 'premium']::text[];

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bo_app_screen_sections_visible_to_check') THEN
    ALTER TABLE backoffice.bo_app_screen_sections
      ADD CONSTRAINT bo_app_screen_sections_visible_to_check
      CHECK (visible_to <@ ARRAY['guest', 'free', 'premium']::text[]);
  END IF;
END $$;



-- =============================================================================
-- App Screens: change a screen key (docs/app-screens-rename-key-handoff.md, section 9)
-- One transaction renames the screen and its same-key versions below it, the URL &
-- Behaviour rules and tier actions that point at it, moves the screen text namespaces
-- and relinks widget text refs. Admins only (checked inside, SECURITY DEFINER).
-- =============================================================================

-- camelCase of the words of p, as camel() in src/lib/app-screen-texts.ts.
CREATE OR REPLACE FUNCTION backoffice.bo_camel(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(string_agg(CASE WHEN n = 1 THEN lower(w) ELSE upper(left(w, 1)) || lower(substr(w, 2)) END, '' ORDER BY n), '')
  FROM (
    SELECT w, row_number() OVER (ORDER BY ord) AS n
    FROM regexp_split_to_table(p, '[^a-zA-Z0-9]+') WITH ORDINALITY AS t(w, ord)
    WHERE w <> ''
  ) x;
$$;

-- Rewrites i18n.* and slides[].i18n.* ref namespaces of a widget config using a {from: to} map.
CREATE OR REPLACE FUNCTION backoffice.bo_rename_ref_namespaces(p_config jsonb, p_map jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
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
$$;

CREATE OR REPLACE FUNCTION backoffice.app_screen_rename_slug(
  p_level text, p_owner_id uuid, p_environment text, p_old text, p_new text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
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
    SELECT coalesce(array_agg(id), '{}') INTO v_products FROM backoffice.bo_products WHERE service_id = v_service;
  ELSIF p_level = 'product' THEN
    SELECT service_id INTO v_service FROM backoffice.bo_products WHERE id = p_owner_id;
    v_products := ARRAY[p_owner_id]; v_up_service := v_service;
  ELSIF p_level = 'locale' THEN
    SELECT l.product_id, p.service_id INTO v_up_product, v_service
      FROM backoffice.bo_product_locales l JOIN backoffice.bo_products p ON p.id = l.product_id WHERE l.id = p_owner_id;
    v_locales := ARRAY[p_owner_id]; v_up_service := v_service;
  ELSE RAISE EXCEPTION 'Invalid level' USING ERRCODE = '22023'; END IF;
  IF v_service IS NULL THEN RAISE EXCEPTION 'Owner not found' USING ERRCODE = 'P0002'; END IF;
  IF p_level <> 'locale' THEN
    SELECT coalesce(array_agg(id), '{}') INTO v_locales FROM backoffice.bo_product_locales WHERE product_id = ANY (v_products);
  END IF;

  IF EXISTS (
    SELECT 1 FROM backoffice.bo_app_screens s WHERE s.environment = p_environment AND s.slug = p_new AND (
      (p_level = 'service' AND s.service_id = v_service) OR s.product_id = ANY (v_products) OR s.product_locale_id = ANY (v_locales)
      OR s.service_id = v_up_service OR s.product_id = v_up_product)
  ) THEN RAISE EXCEPTION 'A screen "%" already exists at this level, above it or below it', p_new USING ERRCODE = '23505'; END IF;

  -- Language texts share the product namespace, so a language rename moves no texts.
  IF p_level <> 'locale' THEN
    IF p_level = 'service' THEN
      v_map := v_map || jsonb_build_object(backoffice.bo_camel(p_old) || 'Screen', backoffice.bo_camel(p_new) || 'Screen');
    END IF;
    SELECT v_map || coalesce(jsonb_object_agg(backoffice.bo_camel(slug || '-' || p_old) || 'Screen', backoffice.bo_camel(slug || '-' || p_new) || 'Screen'), '{}')
      INTO v_map FROM backoffice.bo_products WHERE id = ANY (v_products);
    IF EXISTS (SELECT 1 FROM backoffice.bo_service_translations_defaults t, jsonb_each_text(v_map) m
               WHERE t.service_id = v_service AND t.environment = p_environment AND t.namespace = m.value)
       OR EXISTS (SELECT 1 FROM backoffice.bo_product_translations t, jsonb_each_text(v_map) m
               WHERE t.product_locale_id = ANY (v_locales) AND t.environment = p_environment AND t.namespace = m.value)
    THEN RAISE EXCEPTION 'Texts already exist under the new screen namespace' USING ERRCODE = '23505'; END IF;
  END IF;

  UPDATE backoffice.bo_app_screens SET slug = p_new, updated_at = now()
   WHERE environment = p_environment AND slug = p_old
     AND ((p_level = 'service' AND service_id = v_service) OR product_id = ANY (v_products) OR product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_screens = ROW_COUNT;

  UPDATE backoffice.bo_page_behaviour_tier_rules t SET screen_slug = p_new, updated_at = now()
    FROM backoffice.bo_page_behaviour_rules r
   WHERE t.rule_id = r.id AND t.screen_slug = p_old AND r.environment = p_environment
     AND ((p_level = 'service' AND r.service_id = v_service) OR r.product_id = ANY (v_products) OR r.product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_tiers = ROW_COUNT;

  UPDATE backoffice.bo_page_behaviour_rules r
     SET screen_slug = p_new, path = CASE WHEN path = '/' || p_old THEN '/' || p_new ELSE path END, updated_at = now()
   WHERE r.environment = p_environment AND r.screen_slug = p_old
     AND ((p_level = 'service' AND r.service_id = v_service) OR r.product_id = ANY (v_products) OR r.product_locale_id = ANY (v_locales));
  GET DIAGNOSTICS v_rules = ROW_COUNT;

  FOR v_from, v_to IN SELECT key, value FROM jsonb_each_text(v_map) LOOP
    UPDATE backoffice.bo_service_translations_defaults SET namespace = v_to, updated_at = now()
     WHERE service_id = v_service AND environment = p_environment AND namespace = v_from;
    GET DIAGNOSTICS n = ROW_COUNT; v_texts := v_texts + n;
    UPDATE backoffice.bo_product_translations SET namespace = v_to, updated_at = now()
     WHERE product_locale_id = ANY (v_locales) AND environment = p_environment AND namespace = v_from;
    GET DIAGNOSTICS n = ROW_COUNT; v_texts := v_texts + n;
  END LOOP;

  IF v_map <> '{}' THEN
    -- Relink widget texts anywhere in the service: any widget may link to a key of the moved namespaces.
    WITH svc_screens AS (
      SELECT s.id FROM backoffice.bo_app_screens s
        LEFT JOIN backoffice.bo_products p ON p.id = s.product_id
        LEFT JOIN backoffice.bo_product_locales l ON l.id = s.product_locale_id
        LEFT JOIN backoffice.bo_products lp ON lp.id = l.product_id
       WHERE s.environment = p_environment AND v_service IN (s.service_id, p.service_id, lp.service_id)
    ), relinked AS (
      UPDATE backoffice.bo_app_screen_sections sec
         SET config = backoffice.bo_rename_ref_namespaces(sec.config, v_map), updated_at = now()
       WHERE sec.screen_id IN (SELECT id FROM svc_screens)
         AND backoffice.bo_rename_ref_namespaces(sec.config, v_map) IS DISTINCT FROM sec.config
      RETURNING 1
    ) SELECT count(*) INTO v_widgets FROM relinked;
  END IF;

  RETURN jsonb_build_object('screens', v_screens, 'rules', v_rules, 'tier_rules', v_tiers, 'widgets_relinked', v_widgets, 'texts_moved', v_texts);
END;
$$;

REVOKE EXECUTE ON FUNCTION backoffice.app_screen_rename_slug(text, uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION backoffice.app_screen_rename_slug(text, uuid, text, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION backoffice.bo_rename_ref_namespaces(jsonb, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION backoffice.bo_camel(text) FROM PUBLIC, anon;



-- =============================================================================
-- Storage object RLS policies (storage schema is platform-managed)
-- =============================================================================
DROP POLICY IF EXISTS "Admins can delete product assets" ON storage.objects;
CREATE POLICY "Admins can delete product assets" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'product-assets'::"text") AND "public"."is_backoffice_role"('admin'::"text")));

DROP POLICY IF EXISTS "Authenticated users can delete quiz videos" ON storage.objects;
CREATE POLICY "Authenticated users can delete quiz videos" ON "storage"."objects" FOR DELETE TO "authenticated" USING (("bucket_id" = 'quiz-videos'::"text"));

DROP POLICY IF EXISTS "Authenticated users can update quiz videos" ON storage.objects;
CREATE POLICY "Authenticated users can update quiz videos" ON "storage"."objects" FOR UPDATE TO "authenticated" USING (("bucket_id" = 'quiz-videos'::"text"));

DROP POLICY IF EXISTS "Authenticated users can upload quiz videos" ON storage.objects;
CREATE POLICY "Authenticated users can upload quiz videos" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK (("bucket_id" = 'quiz-videos'::"text"));

DROP POLICY IF EXISTS "Editors can update product assets" ON storage.objects;
CREATE POLICY "Editors can update product assets" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'product-assets'::"text") AND "public"."is_backoffice_role"('editor'::"text"))) WITH CHECK ((("bucket_id" = 'product-assets'::"text") AND "public"."is_backoffice_role"('editor'::"text")));

DROP POLICY IF EXISTS "Editors can upload product assets" ON storage.objects;
CREATE POLICY "Editors can upload product assets" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'product-assets'::"text") AND "public"."is_backoffice_role"('editor'::"text")));

DROP POLICY IF EXISTS "Public Access to Quiz Videos" ON storage.objects;
CREATE POLICY "Public Access to Quiz Videos" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'quiz-videos'::"text"));

DROP POLICY IF EXISTS "Public can read product assets" ON storage.objects;
CREATE POLICY "Public can read product assets" ON "storage"."objects" FOR SELECT TO "authenticated", "anon" USING (("bucket_id" = 'product-assets'::"text"));

DROP POLICY IF EXISTS "Public read access for avatars" ON storage.objects;
CREATE POLICY "Public read access for avatars" ON "storage"."objects" FOR SELECT USING (("bucket_id" = 'avatars'::"text"));

DROP POLICY IF EXISTS "Users can delete their own avatars" ON storage.objects;
CREATE POLICY "Users can delete their own avatars" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'avatars'::"text") AND (("auth"."uid"())::"text" = ("storage"."foldername"("name"))[1])));

DROP POLICY IF EXISTS "Users can update their own avatars" ON storage.objects;
CREATE POLICY "Users can update their own avatars" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'avatars'::"text") AND (("auth"."uid"())::"text" = ("storage"."foldername"("name"))[1])));

DROP POLICY IF EXISTS "Users can upload their own avatars" ON storage.objects;
CREATE POLICY "Users can upload their own avatars" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'avatars'::"text") AND (("auth"."uid"())::"text" = ("storage"."foldername"("name"))[1])));

DROP POLICY IF EXISTS "avatars_block_anon_writes_delete" ON storage.objects;
CREATE POLICY "avatars_block_anon_writes_delete" ON "storage"."objects" FOR DELETE TO "anon" USING (("bucket_id" <> 'avatars'::"text"));

DROP POLICY IF EXISTS "avatars_block_anon_writes_insert" ON storage.objects;
CREATE POLICY "avatars_block_anon_writes_insert" ON "storage"."objects" FOR INSERT TO "anon" WITH CHECK (("bucket_id" <> 'avatars'::"text"));

DROP POLICY IF EXISTS "avatars_block_anon_writes_update" ON storage.objects;
CREATE POLICY "avatars_block_anon_writes_update" ON "storage"."objects" FOR UPDATE TO "anon" USING (("bucket_id" <> 'avatars'::"text")) WITH CHECK (("bucket_id" <> 'avatars'::"text"));


-- =============================================================================
-- Realtime
-- =============================================================================
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.avatar_generations;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
