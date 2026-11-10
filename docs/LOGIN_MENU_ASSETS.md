# Login channels, three-level menus and product assets

Migration [`20261106120000_menu_login_assets.sql`](../supabase/migrations/20261106120000_menu_login_assets.sql), ported from bravigo-migration `packs/bbm`. This note lists what changes for the apps and for the back office.

## Breaking change for the apps: `get-product-config` → `login_methods`

**Before:** an array of methods with combined types (`msisdn_pin`, `email_password_otp`, …), per-method `allow_signup` / `signup_url`, and the service defaults used when the product had no rows.

**After:**

```json
{
  "login_methods": {
    "signup": { "enabled": true, "url": "/register" },
    "methods": [
      {
        "type": "msisdn", "enabled": true, "default": true, "order": 10,
        "config": { "mode": "password", "password_format": "numeric", "msisdn_prefix": "+39" }
      }
    ]
  }
}
```

- Types are only `email`, `msisdn`, `google`, `apple`.
- `email`: `config.mode` is `otp` or `password`. `msisdn`: `otp`, `password` or `pinless`.
- `mode = password` requires `config.password_format`: `numeric` or `alphanumeric`.
- `signup` is always present (`enabled: false, url: null` when not configured). No per-method signup fields.
- No service-default fallback: a product without rows returns `methods: []` (treat it as "not configured").
- Country phone rules are injected only for `type = msisdn`.

### Data conversion

Existing rows are converted, not deleted (the BBM migration deleted them). Existing config keys are kept; `mode` / `password_format` are added:

| Old type | New rows |
| --- | --- |
| `email_password` | `email` (password, alphanumeric) |
| `msisdn_pin` | `msisdn` (password, numeric) |
| `otp` | `msisdn` (otp) |
| `pinless` | `msisdn` (pinless) |
| `email_password_msisdn_pin` / `_otp` / `_pinless` | `email` (password, alphanumeric) + `msisdn` (password numeric / otp / pinless) |
| `google` | `google` |
| `ios` | `apple` |

When two old rows map to the same channel, the enabled, then default, then first one is kept. `bo_product_signup_settings` is filled from the legacy `allow_signup` / `signup_url` (enabled only with a valid URL). The legacy columns stay, unused. New products start with no login method.

Check the converted rows of each project: the old seeded `msisdn_pin` default carried an alphanumeric `password_regex` while it becomes `password_format: numeric`.

## Back office (starter) follow-ups

- Login methods editor: the database now rejects the old types. The editor must write `email` / `msisdn` / `google` / `apple` with `config.mode` (and `password_format`), and edit signup in `bo_product_signup_settings` (admins write, viewers read).
- Menu items: `bo_product_menu_items` and its tiers are now readable by viewers and writable by editors only (`public.is_backoffice_role`).

## Menu items on Service > Product > Language

`bo_product_menu_items` rows can now be owned by a service (`service_id`), a product (`product_id`) or a language (`product_locale_id`), exactly one of them. New columns: `enabled` (false hides an inherited item), `screen_slug`, `badge_i18n_key` (also on tiers).

`get-product-config` keeps every language row (the starter menus model can repeat a key across menus) and adds the service / product rows whose `item_key` the language does not define (product wins over service). Items with `enabled = false` are dropped. `screen_slug` and `badge_i18n_key` are returned when set.

Labels and badges without an i18n key were copied to translations and referenced as `namespace.key` (`menuItems` for service rows, `<camelProductSlug>MenuItems` otherwise); plain `label` / `badge_text` stay as fallback.

## Product-level assets

`get-product-config` merges assets service < product (`bo_product_level_assets`) < language. When the service has no rows for the requested environment its staging rows are used; entries without a URL are skipped.

## Clone functions

- `clone-product` and `clone-service` copy signup settings, product-level assets and menu items of every level with their tiers (rows materialised from the starter menu levels are recreated by the seed triggers, not copied). `clone-product` renames menu text refs to the new product namespace.
- `clone-service` now really copies the service defaults and the language data: it used table names without `bo_` and outside the `backoffice` schema, so nothing was copied.
