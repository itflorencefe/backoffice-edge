# Dual schema (migration `20261112120000_dual_schema.sql`)

Port of the BBM dual-schema Step 1 (`bravigo-migration` `packs/bbm/supabase/migrations/20261112120000_bbm_dual_schema.sql`) to this repo. Objects that only exist here are kept and follow the same rules.

## What changes

| Before | After |
|---|---|
| `backoffice.bo_<name>` | `backoffice.<name>` (prefix removed on every back office table, edge-only ones included) |
| `public.profiles`, `avatar_generations`, `badges`, `user_badges`, `quiz_attempts`, `content_attempts`, `redeemed_reward_assets` | same names in schema `application` |
| `bo_service_public_config_defaults` + `bo_product_level_public_config` + `bo_product_public_config` | one table `backoffice.product_public_config`, exactly one owner per row: `service_id`, `product_id` or `product_locale_id` |
| nothing in `public` for the back office | read-only views `public.bo_<name>` (and `public.<app table>`), `security_invoker`: reads keep working, writes fail |

Kept from this repo (renamed): menus at every level (`service_menus`, `service_menu_items_defaults`, `product_level_menus`, `product_level_menu_items`, `product_menus`) with their seed / propagate / promote functions and triggers, social links, branding templates, `translation_keys` / `translation_overrides` / `translation_sections`, `set_default_product(_locale)`, `app_screen_rename_slug`. The helpers `bo_camel` and `bo_rename_ref_namespaces` are now `camel` and `rename_ref_namespaces`.

The public config version bump follows the owner of the row: a service row bumps every locale of the service, a product row every locale of the product, a locale row that locale (`backoffice.bump_public_config_version`).

## Dropped (agreed in the BBM dual-schema roadmap)

- Tables: `activity_notifications`, `user_wishlist`, `user_rewards`, `user_activities`, `user_cards`, `content_consumption_rules`, `content_consumption_tier_rules`, `player_cards`, `games`, `rewards`, `special_events`, `pulsar_quiz_cache`, `app_config`, `admin_users`, `bo_product_domains` (product hostnames are the source of truth).
- Columns: `product_assets.width/height`, `product_document_versions.body_markdown/body_json`, `profiles.points_expiry/rank_position/welcome_bonus_claimed/badge_name/avatar_traits`, `badges.description/event_id`, `avatar_generations.favourite_team/card_mode`.
- RPCs: `bo_product_dashboard`, `_bo_dashboard_period_kpis` (dashboard abandoned for 2.0), `get_leaderboard`, `get_user_rank`.
- Edge functions: `whoami`, `app-profile`, `app-game-sessions`, `avatar-poll-worker` (the sync removes them from the consumers).

## What a consumer repo has to change

The sync updates `supabase/` only. The app / back office code of each repo must follow:

- `supabase.schema('backoffice').from('bo_products')` → `.from('products')` (same for every table).
- App tables: `supabase.schema('application').from('profiles')` (the `public` views are read-only).
- Public config: service rows `product_public_config` with `service_id`, product rows with `product_id`, language rows with `product_locale_id`. Unique per owner + `(environment, key)`.
- RPCs `app_screen_label_paths`, `app_screen_label_usage`, `rename_app_screen_label`, `reorder_product_packs`, `publish_document_version`, `is_backoffice_role`, `backoffice_role` exist in `backoffice` and as `public` wrappers.
- Hosted projects: add `application` to *Settings → API → Exposed schemas* (local: `supabase/config.toml`).

## Seeds

`supabase/seeds/02`–`15` come from the BBM pack (tenants, admin `admin@digitalvirgo.com` / `123456`, live back office import, BBM screens / login methods / assets / translations / page behaviour / menu items). Two edits for this repo's menu model, where `url` is the link source and `normalize_menu_item_link` derives `route` from it: `04` inserts its menu items with that trigger off and then moves `route` into `url`; `15` writes the route into `url`.
