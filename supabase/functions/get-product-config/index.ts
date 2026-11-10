import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { resolveProduct } from "../_shared/resolve-product.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Country-specific MSISDN validation rules and PIN configuration.
// These are injected at response time based on product.country_code.
const COUNTRY_PHONE_RULES: Record<string, {
  msisdn_prefix: string;
  msisdn_regex: string;
  msisdn_regex_flags: string;
  msisdn_min_length: number;
  msisdn_max_length: number;
  pin_length: number;
  pin_numeric_only: boolean;
  pin_regex: string;
  pin_regex_flags: string;
}> = {
  IT: {
    msisdn_prefix: '+39',
    msisdn_regex: '^\\+?39[0-9]{9,10}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 13,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  GB: {
    msisdn_prefix: '+44',
    msisdn_regex: '^\\+?44[0-9]{10}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 13,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  DE: {
    msisdn_prefix: '+49',
    msisdn_regex: '^\\+?49[0-9]{10,11}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 14,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  FR: {
    msisdn_prefix: '+33',
    msisdn_regex: '^\\+?33[0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 11,
    msisdn_max_length: 12,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  ES: {
    msisdn_prefix: '+34',
    msisdn_regex: '^\\+?34[0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 11,
    msisdn_max_length: 12,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  US: {
    msisdn_prefix: '+1',
    msisdn_regex: '^\\+?1[2-9][0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 11,
    msisdn_max_length: 12,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  BR: {
    msisdn_prefix: '+55',
    msisdn_regex: '^\\+?55[0-9]{10,11}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 14,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  ZA: {
    msisdn_prefix: '+27',
    msisdn_regex: '^\\+?27[0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 11,
    msisdn_max_length: 12,
    pin_length: 5,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{5}$',
    pin_regex_flags: '',
  },
  NG: {
    msisdn_prefix: '+234',
    msisdn_regex: '^\\+?234[0-9]{10}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 13,
    msisdn_max_length: 14,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  KE: {
    msisdn_prefix: '+254',
    msisdn_regex: '^\\+?254[0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 13,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  IN: {
    msisdn_prefix: '+91',
    msisdn_regex: '^\\+?91[6-9][0-9]{9}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 13,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
  PH: {
    msisdn_prefix: '+63',
    msisdn_regex: '^\\+?63[0-9]{10}$',
    msisdn_regex_flags: '',
    msisdn_min_length: 12,
    msisdn_max_length: 13,
    pin_length: 4,
    pin_numeric_only: true,
    pin_regex: '^[0-9]{4}$',
    pin_regex_flags: '',
  },
};

// Fallback for countries not in the map
const DEFAULT_PHONE_RULES = {
  msisdn_prefix: '+',
  msisdn_regex: '^\\+?[0-9]{7,15}$',
  msisdn_regex_flags: '',
  msisdn_min_length: 7,
  msisdn_max_length: 15,
  pin_length: 4,
  pin_numeric_only: true,
  pin_regex: '^[0-9]{4}$',
  pin_regex_flags: '',
};

// Types that require MSISDN phone rules injected into their config
const MSISDN_TYPES = new Set(['msisdn']);

// BCP 47 valid locales set for locale resolution
const VALID_LOCALES: Set<string> = new Set([
  'af-ZA', 'am-ET', 'ar-AE', 'ar-BH', 'ar-DZ', 'ar-EG', 'ar-IQ', 'ar-JO',
  'ar-KW', 'ar-LB', 'ar-LY', 'ar-MA', 'ar-OM', 'ar-QA', 'ar-SA', 'ar-SD',
  'ar-SY', 'ar-TN', 'ar-YE', 'az-AZ', 'be-BY', 'bg-BG', 'bn-BD', 'bn-IN',
  'bs-BA', 'ca-ES', 'cs-CZ', 'cy-GB', 'da-DK', 'de-AT', 'de-CH', 'de-DE',
  'de-LI', 'de-LU', 'el-CY', 'el-GR', 'en-AU', 'en-BZ', 'en-CA', 'en-GB',
  'en-GH', 'en-HK', 'en-IE', 'en-IN', 'en-JM', 'en-KE', 'en-MT', 'en-MY',
  'en-NG', 'en-NZ', 'en-PH', 'en-SG', 'en-TT', 'en-US', 'en-ZA', 'en-ZW',
  'es-AR', 'es-BO', 'es-CL', 'es-CO', 'es-CR', 'es-CU', 'es-DO', 'es-EC',
  'es-ES', 'es-GQ', 'es-GT', 'es-HN', 'es-MX', 'es-NI', 'es-PA', 'es-PE',
  'es-PR', 'es-PY', 'es-SV', 'es-US', 'es-UY', 'es-VE', 'et-EE', 'eu-ES',
  'fa-IR', 'fi-FI', 'fil-PH', 'fr-BE', 'fr-CA', 'fr-CH', 'fr-CI', 'fr-CM',
  'fr-FR', 'fr-HT', 'fr-LU', 'fr-MA', 'fr-MC', 'fr-ML', 'fr-SN', 'ga-IE',
  'gl-ES', 'gu-IN', 'ha-NG', 'he-IL', 'hi-IN', 'hr-BA', 'hr-HR', 'hu-HU',
  'hy-AM', 'id-ID', 'ig-NG', 'is-IS', 'it-CH', 'it-IT', 'ja-JP', 'ka-GE',
  'kk-KZ', 'km-KH', 'kn-IN', 'ko-KR', 'ky-KG', 'lo-LA', 'lt-LT', 'lv-LV',
  'mg-MG', 'mk-MK', 'ml-IN', 'mn-MN', 'mr-IN', 'ms-BN', 'ms-MY', 'mt-MT',
  'my-MM', 'nb-NO', 'ne-NP', 'nl-BE', 'nl-NL', 'nn-NO', 'or-IN', 'pa-IN',
  'pl-PL', 'ps-AF', 'pt-AO', 'pt-BR', 'pt-MZ', 'pt-PT', 'ro-MD', 'ro-RO',
  'ru-BY', 'ru-KG', 'ru-KZ', 'ru-RU', 'ru-UA', 'rw-RW', 'si-LK', 'sk-SK',
  'sl-SI', 'so-SO', 'sq-AL', 'sq-XK', 'sr-BA', 'sr-ME', 'sr-RS', 'sv-FI',
  'sv-SE', 'sw-KE', 'sw-TZ', 'ta-IN', 'ta-LK', 'ta-MY', 'ta-SG', 'te-IN',
  'tg-TJ', 'th-TH', 'ti-ER', 'ti-ET', 'tk-TM', 'tl-PH', 'tr-CY', 'tr-TR',
  'uk-UA', 'ur-IN', 'ur-PK', 'uz-UZ', 'vi-VN', 'wo-SN', 'xh-ZA', 'yo-NG',
  'zh-CN', 'zh-HK', 'zh-MO', 'zh-SG', 'zh-TW', 'zu-ZA',
]);

const LANGUAGE_FALLBACK_MAP: Record<string, string> = {
  af: 'af-ZA', am: 'am-ET', ar: 'ar-EG', az: 'az-AZ', be: 'be-BY', bg: 'bg-BG',
  bn: 'bn-BD', bs: 'bs-BA', ca: 'ca-ES', cs: 'cs-CZ', cy: 'cy-GB', da: 'da-DK',
  de: 'de-DE', el: 'el-GR', en: 'en-GB', es: 'es-ES', et: 'et-EE', eu: 'eu-ES',
  fa: 'fa-IR', fi: 'fi-FI', fil: 'fil-PH', fr: 'fr-FR', ga: 'ga-IE', gl: 'gl-ES',
  gu: 'gu-IN', ha: 'ha-NG', he: 'he-IL', hi: 'hi-IN', hr: 'hr-HR', hu: 'hu-HU',
  hy: 'hy-AM', id: 'id-ID', ig: 'ig-NG', is: 'is-IS', it: 'it-IT', ja: 'ja-JP',
  ka: 'ka-GE', kk: 'kk-KZ', km: 'km-KH', kn: 'kn-IN', ko: 'ko-KR', ky: 'ky-KG',
  lo: 'lo-LA', lt: 'lt-LT', lv: 'lv-LV', mg: 'mg-MG', mk: 'mk-MK', ml: 'ml-IN',
  mn: 'mn-MN', mr: 'mr-IN', ms: 'ms-MY', mt: 'mt-MT', my: 'my-MM', nb: 'nb-NO',
  ne: 'ne-NP', nl: 'nl-NL', nn: 'nn-NO', or: 'or-IN', pa: 'pa-IN', pl: 'pl-PL',
  ps: 'ps-AF', pt: 'pt-BR', ro: 'ro-RO', ru: 'ru-RU', rw: 'rw-RW', si: 'si-LK',
  sk: 'sk-SK', sl: 'sl-SI', so: 'so-SO', sq: 'sq-AL', sr: 'sr-RS', sv: 'sv-SE',
  sw: 'sw-KE', ta: 'ta-IN', te: 'te-IN', tg: 'tg-TJ', th: 'th-TH', ti: 'ti-ET',
  tk: 'tk-TM', tl: 'tl-PH', tr: 'tr-TR', uk: 'uk-UA', ur: 'ur-PK', uz: 'uz-UZ',
  vi: 'vi-VN', wo: 'wo-SN', xh: 'xh-ZA', yo: 'yo-NG', zh: 'zh-CN', zu: 'zu-ZA',
};

function resolveLocaleCode(languageCode: string, countryCode: string, override: string | null): string {
  if (override) return override;
  const computed = `${languageCode}-${countryCode.toUpperCase()}`;
  if (VALID_LOCALES.has(computed)) return computed;
  return LANGUAGE_FALLBACK_MAP[languageCode.toLowerCase()] || computed;
}

function deepMerge(base: Record<string, unknown>, override: Record<string, unknown>): Record<string, unknown> {
  const result = { ...base };
  for (const key of Object.keys(override)) {
    if (
      override[key] !== null &&
      typeof override[key] === "object" &&
      !Array.isArray(override[key]) &&
      base[key] !== null &&
      typeof base[key] === "object" &&
      !Array.isArray(base[key])
    ) {
      result[key] = deepMerge(base[key] as Record<string, unknown>, override[key] as Record<string, unknown>);
    } else {
      result[key] = override[key];
    }
  }
  return result;
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    const url = new URL(req.url);
    const forceInfo = url.searchParams.get("_forceinfo") === "1";

    if (!forceInfo) {
      const authHeader = req.headers.get("Authorization") ?? "";
      if (!authHeader.startsWith("Bearer ")) {
        return jsonResponse({ ok: false, error: "Missing or invalid authorization" }, 401);
      }
    }

    const serviceSlug = url.searchParams.get("slug");
    const countryCode = url.searchParams.get("country_code");
    const domain = url.searchParams.get("domain");
    const bundleId = url.searchParams.get("bundle_id")?.trim() || null;
    const languageCode = url.searchParams.get("language_code");
    const environment = url.searchParams.get("environment") || "production";
    const showDict = url.searchParams.get("show-dict") === "1";

    if (!domain && !bundleId && (!serviceSlug || !countryCode)) {
      return jsonResponse({
        ok: false,
        error: "Either 'domain', 'bundle_id', or both 'slug' and 'country_code' are required",
      }, 400);
    }

    if (environment !== "staging" && environment !== "production") {
      return jsonResponse({ ok: false, error: "environment must be 'staging' or 'production'" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Normalize hostname: strip protocol prefix and trailing slashes
    const normalizeHostname = (h: string) => h.replace(/^https?:\/\//, "").replace(/\/+$/, "");
    const cleanDomain = domain ? normalizeHostname(domain) : null;

    // Resolve product using the shared module
    let resolved;
    try {
      resolved = await resolveProduct(supabase, {
        domain: cleanDomain ?? undefined,
        bundle_id: bundleId ?? undefined,
        country_code: countryCode ?? undefined,
        service_slug: serviceSlug ?? undefined,
        environment: environment as "staging" | "production",
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Product resolution failed";
      return jsonResponse({ ok: false, error: message }, 404);
    }

    const service = resolved.service;
    const product = resolved.product;
    const detectedBy = resolved.detected_by;
    const countryFallback = detectedBy === "slug+default";

    // 3. Resolve language
    const { data: allLocales } = await supabase
      .schema("backoffice").from("bo_product_locales")
      .select("id, language_code, display_name, is_default, locale_override, footer_columns_staging, footer_columns_production")
      .eq("product_id", product.id)
      .eq("status", "active")
      .order("is_default", { ascending: false });

    const locales = allLocales || [];
    let locale = languageCode
      ? locales.find((l: { language_code: string }) => l.language_code === languageCode.toLowerCase())
      : null;

    if (!locale) {
      locale = locales.find((l: { is_default: boolean }) => l.is_default) || locales[0] || null;
    }

    if (!locale) {
      return jsonResponse({ ok: false, error: "No active language configured for this product" }, 404);
    }

    // 4. Fetch service defaults and locale overrides in parallel
    const [
      svcBranding, localeBranding,
      svcAssets, productAssets, localeAssets,
      svcTranslations, localeTranslations,
      svcConfig, localeConfig,
      svcFlags, localeFlags,
      signupSettingsRow, localeLoginMethods,
      menuItemRows,
      svcFooterItems, localeFooterItems,
      svcAvatar, prodAvatar, localeAvatar,
    ] = await Promise.all([
      // Branding
      supabase.schema("backoffice").from("bo_service_branding_defaults").select("colors, gradients, fonts, radius, spacing, font_sizes, font_weights, shadows")
        .eq("service_id", service.id).eq("environment", environment).maybeSingle(),
      supabase.schema("backoffice").from("bo_product_branding").select("colors, gradients, fonts, radius, spacing, font_sizes, font_weights, shadows")
        .eq("product_locale_id", locale.id).eq("environment", environment).maybeSingle(),
      // Assets
      supabase.schema("backoffice").from("bo_service_assets_defaults").select("asset_key, url, mime_type, metadata")
        .eq("service_id", service.id).eq("environment", environment),
      supabase.schema("backoffice").from("bo_product_level_assets").select("asset_key, url, mime_type, metadata")
        .eq("product_id", product.id).eq("environment", environment),
      supabase.schema("backoffice").from("bo_product_assets").select("asset_key, url, mime_type, metadata")
        .eq("product_locale_id", locale.id).eq("environment", environment),
      // Translations
      supabase.schema("backoffice").from("bo_service_translations_defaults").select("namespace, key, value")
        .eq("service_id", service.id).eq("environment", environment).eq("language_code", locale.language_code),
      supabase.schema("backoffice").from("bo_product_translations").select("namespace, key, value")
        .eq("product_locale_id", locale.id).eq("environment", environment),
      // Public Config
      supabase.schema("backoffice").from("bo_service_public_config_defaults").select("key, value")
        .eq("service_id", service.id).eq("environment", environment),
      supabase.schema("backoffice").from("bo_product_public_config").select("key, value")
        .eq("product_locale_id", locale.id).eq("environment", environment),
      // Feature Flags
      supabase.schema("backoffice").from("bo_service_feature_flags_defaults").select("flag_key, enabled")
        .eq("service_id", service.id).eq("environment", environment),
      supabase.schema("backoffice").from("bo_product_feature_flags").select("flag_key, enabled")
        .eq("product_locale_id", locale.id).eq("environment", environment),
      // Signup settings + Login Methods (product-level only, no service fallback)
      supabase.schema("backoffice").from("bo_product_signup_settings").select("enabled, signup_url")
        .eq("product_id", product.id).eq("environment", environment).maybeSingle(),
      supabase.schema("backoffice").from("bo_product_login_methods").select("type, enabled, is_default, display_order, label_i18n_key, icon, feature_flag, min_app_version, max_app_version, config")
        .eq("product_id", product.id).eq("environment", environment).order("display_order"),
      // Menu Items
      supabase.schema("backoffice").from("bo_product_menu_items").select("id, item_key, label, url, icon, icon_url, display_order, parent_key, visible, enabled, service_id, product_id, product_locale_id, route, external_url, auth_required, label_i18n_key, feature_flag, badge_text, badge_i18n_key, badge_color, min_app_version, max_app_version, screen_slug")
        .eq("environment", environment)
        .or(`service_id.eq.${service.id},product_id.eq.${product.id},product_locale_id.eq.${locale.id}`),
      // Footer Items
      supabase.schema("backoffice").from("bo_service_footer_items_defaults").select("item_key, label, url, icon, display_order, item_group, visible")
        .eq("service_id", service.id).eq("environment", environment).order("display_order"),
      supabase.schema("backoffice").from("bo_product_footer_items").select("item_key, label, url, icon, display_order, item_group, visible")
        .eq("product_locale_id", locale.id).eq("environment", environment).order("display_order"),
      // Avatar config (3-tier) — fetch all rows; active row is resolved below
      supabase.schema("backoffice").from("bo_service_avatar_defaults").select("configuration, themes, event, valid_from, valid_to, enabled")
        .eq("service_id", service.id).eq("environment", environment).eq("enabled", true),
      supabase.schema("backoffice").from("bo_product_avatar").select("configuration, themes, event, valid_from, valid_to, enabled")
        .eq("product_id", product.id).eq("environment", environment).eq("enabled", true),
      supabase.schema("backoffice").from("bo_locale_avatar").select("configuration, themes, event, valid_from, valid_to, enabled")
        .eq("product_locale_id", locale.id).eq("environment", environment).eq("enabled", true),
    ]);

    // 5. Merge branding (deep merge JSON fields)
    const baseBranding = svcBranding.data || {};
    const overrideBranding = localeBranding.data || {};
    const branding: Record<string, unknown> = {};
    for (const field of ["colors", "gradients", "fonts", "radius", "spacing", "font_sizes", "font_weights", "shadows"]) {
      const base = (baseBranding as Record<string, unknown>)[field] as Record<string, unknown> | null;
      const over = (overrideBranding as Record<string, unknown>)[field] as Record<string, unknown> | null;
      if (base && over) {
        branding[field] = deepMerge(base, over);
      } else {
        branding[field] = over || base || {};
      }
    }

    // 6. Merge assets (key-based): service < product < locale. A Service without rows for this
    // environment falls back to its staging rows; slots without an uploaded file are skipped.
    let serviceAssetRows = svcAssets.data || [];
    if (serviceAssetRows.length === 0 && environment !== "staging") {
      const { data: stagingSvcAssets } = await supabase.schema("backoffice").from("bo_service_assets_defaults")
        .select("asset_key, url, mime_type, metadata").eq("service_id", service.id).eq("environment", "staging");
      serviceAssetRows = stagingSvcAssets || [];
    }
    const assetsMap: Record<string, { url: string; mime_type: string; metadata: unknown }> = {};
    for (const a of [...serviceAssetRows, ...(productAssets.data || []), ...(localeAssets.data || [])]) {
      if (!a.url || a.url.trim() === "") continue;
      assetsMap[a.asset_key] = { url: a.url, mime_type: a.mime_type, metadata: a.metadata };
    }

    // 7. Merge translations (namespace.key based, locale wins)
    const translationsMap: Record<string, Record<string, string>> = {};
    for (const t of (svcTranslations.data || [])) {
      if (!translationsMap[t.namespace]) translationsMap[t.namespace] = {};
      translationsMap[t.namespace][t.key] = t.value;
    }
    for (const t of (localeTranslations.data || [])) {
      if (!translationsMap[t.namespace]) translationsMap[t.namespace] = {};
      translationsMap[t.namespace][t.key] = t.value;
    }

    if (showDict) {
      for (const ns of Object.keys(translationsMap)) {
        for (const k of Object.keys(translationsMap[ns])) {
          translationsMap[ns][k] = k;
        }
      }
    }

    // 8. Merge config (key-based, locale wins)
    const configMap: Record<string, string> = {};
    for (const c of (svcConfig.data || [])) {
      configMap[c.key] = c.value;
    }
    for (const c of (localeConfig.data || [])) {
      configMap[c.key] = c.value;
    }

    // 9. Merge flags (key-based, locale wins)
    const flagsMap: Record<string, boolean> = {};
    for (const f of (svcFlags.data || [])) {
      flagsMap[f.flag_key] = f.enabled;
    }
    for (const f of (localeFlags.data || [])) {
      flagsMap[f.flag_key] = f.enabled;
    }

    // 10. login_methods block: { signup, methods }. signup is always present (disabled when no row);
    // methods is [] for a product without rows. MSISDN gets country phone rules; stored values win.
    if (signupSettingsRow.error) console.error("[error] [get-product-config] signup settings query failed", signupSettingsRow.error.message);
    if (localeLoginMethods.error) console.error("[error] [get-product-config] login methods query failed", localeLoginMethods.error.message);
    const signup = {
      enabled: signupSettingsRow.data?.enabled ?? false,
      url: signupSettingsRow.data?.signup_url ?? null,
    };
    const phoneRules = COUNTRY_PHONE_RULES[product.country_code] || DEFAULT_PHONE_RULES;
    const loginMethods = (localeLoginMethods.data || []).map((m: {
        type: string; enabled: boolean; is_default: boolean; display_order: number;
        label_i18n_key: string | null; icon: string | null;
        feature_flag: string | null; min_app_version: string | null; max_app_version: string | null;
        config: Record<string, unknown>;
      }) => {
        let config = m.config || {};

        // Inject phone rules for any method that uses MSISDN
        if (MSISDN_TYPES.has(m.type)) {
          config = { ...phoneRules, ...config };
        }

        return {
          type: m.type,
          enabled: m.enabled,
          default: m.is_default,
          order: m.display_order,
          label_i18n_key: m.label_i18n_key || undefined,
          icon: m.icon || undefined,
          feature_flag: m.feature_flag || undefined,
          min_app_version: m.min_app_version || undefined,
          max_app_version: m.max_app_version || undefined,
          config,
        };
      });

    // 11. Menu items: Service > Product > Locale chain, per item_key the most
    // specific level wins; a winning row with enabled = false removes the item.
    if (menuItemRows.error) console.error("[error] get-product-config: menu items query failed", menuItemRows.error.message);
    type MenuRow = { id: string; item_key: string; label: string; url: string; icon: string; icon_url: string | null; display_order: number; parent_key: string | null; visible: boolean; enabled: boolean; service_id: string | null; product_id: string | null; product_locale_id: string | null; route: string | null; external_url: string | null; auth_required: boolean; label_i18n_key: string | null; feature_flag: string | null; badge_text: string | null; badge_i18n_key: string | null; badge_color: string | null; min_app_version: string | null; max_app_version: string | null; screen_slug: string | null };
    // Language rows are all kept (the starter menus model can repeat an item_key across menus);
    // Service / Product rows only fill the keys the language does not define.
    const allMenuRows = (menuItemRows.data || []) as MenuRow[];
    const localeRows = allMenuRows.filter((r) => r.product_locale_id);
    const localeKeys = new Set(localeRows.map((r) => r.item_key));
    const inherited = new Map<string, MenuRow>();
    for (const r of allMenuRows) {
      if (r.product_locale_id || localeKeys.has(r.item_key)) continue;
      const current = inherited.get(r.item_key);
      if (!current || (r.product_id && !current.product_id)) inherited.set(r.item_key, r);
    }
    const localeMenuItemsData = [...localeRows, ...inherited.values()]
      .filter((r) => r.enabled)
      .sort((a, b) => a.display_order - b.display_order || a.item_key.localeCompare(b.item_key));
    let menuItems: unknown[] = [];

    if (localeMenuItemsData.length > 0) {
      const itemIds = localeMenuItemsData.map((m: { id: string }) => m.id);
      const { data: tiersData } = await supabase
        .schema("backoffice").from("bo_product_menu_item_tiers")
        .select("menu_item_id, tier, visible, enabled, locked_action, route, external_url, label, label_i18n_key, badge_text, badge_i18n_key, badge_color, display_order, screen_slug")
        .in("menu_item_id", itemIds);

      const tiersByItem: Record<string, unknown[]> = {};
      for (const t of (tiersData || [])) {
        if (!tiersByItem[t.menu_item_id]) tiersByItem[t.menu_item_id] = [];
        tiersByItem[t.menu_item_id].push({
          tier: t.tier,
          visible: t.visible,
          enabled: t.enabled,
          locked_action: t.locked_action,
          route: t.route || undefined,
          screen_slug: t.screen_slug || undefined,
          external_url: t.external_url || undefined,
          label: t.label || undefined,
          label_i18n_key: t.label_i18n_key || undefined,
          badge_text: t.badge_text || undefined,
          badge_i18n_key: t.badge_i18n_key || undefined,
          badge_color: t.badge_color || undefined,
          display_order: t.display_order,
        });
      }

      menuItems = localeMenuItemsData
        .filter((m) => m.visible)
        .map((m) => ({
          key: m.item_key,
          label: m.label,
          label_i18n_key: m.label_i18n_key || undefined,
          icon: m.icon,
          icon_url: m.icon_url || undefined,
          route: m.route || undefined,
          screen_slug: m.screen_slug || undefined,
          external_url: m.external_url || undefined,
          url: m.url || undefined,
          position: m.display_order,
          parent_key: m.parent_key || undefined,
          auth_required: m.auth_required || false,
          feature_flag: m.feature_flag || undefined,
          badge_text: m.badge_text || undefined,
          badge_i18n_key: m.badge_i18n_key || undefined,
          badge_color: m.badge_color || undefined,
          min_app_version: m.min_app_version || undefined,
          max_app_version: m.max_app_version || undefined,
          tiers: tiersByItem[m.id] || [],
        }));
    }

    // 12. Footer items (locale replaces service if any exist)
    const footerItemsRaw = (localeFooterItems.data && localeFooterItems.data.length > 0)
      ? localeFooterItems.data
      : (svcFooterItems.data || []);
    const footerItems = footerItemsRaw
      .filter((m: { visible: boolean }) => m.visible)
      .map((m: { item_key: string; label: string; url: string; icon: string; display_order: number; item_group: string | null }) => ({
        key: m.item_key,
        label: m.label,
        url: m.url,
        icon: m.icon,
        position: m.display_order,
        group: m.item_group || undefined,
      }));

    // 12b. Footer hidden pages
    const { data: footerHiddenPagesData } = await supabase
      .schema("backoffice").from("bo_product_footer_hidden_pages")
      .select("page_path")
      .eq("product_locale_id", locale.id)
      .eq("environment", environment);

    const footerHiddenPages = (footerHiddenPagesData || []).map((r: { page_path: string }) => r.page_path);

    // 13. Page behaviour rules: Service > Product > Locale chain.
    // For each path the most specific level wins; a winning row with
    // enabled = false hides the path entirely (disables the inherited rule).
    const { data: pageBehaviourRaw } = await supabase
      .schema("backoffice").from("bo_page_behaviour_rules")
      .select("id, path, label, position, enabled, service_id, product_id, product_locale_id")
      .eq("environment", environment)
      .or(`service_id.eq.${service.id},product_id.eq.${product.id},product_locale_id.eq.${locale.id}`);

    type PbRule = { id: string; path: string; label: string | null; position: number; enabled: boolean; service_id: string | null; product_id: string | null; product_locale_id: string | null };
    const pbRank = (r: PbRule) => (r.product_locale_id ? 3 : r.product_id ? 2 : 1);
    const pbByPath = new Map<string, PbRule>();
    for (const r of (pageBehaviourRaw || []) as PbRule[]) {
      const current = pbByPath.get(r.path);
      if (!current || pbRank(r) > pbRank(current)) pbByPath.set(r.path, r);
    }
    const pageBehaviourRules = [...pbByPath.values()]
      .filter((r) => r.enabled)
      .sort((a, b) => a.position - b.position || a.path.localeCompare(b.path));

    // 14. Documents
    const { data: documentsData } = await supabase
      .schema("backoffice").from("bo_product_documents")
      .select("slug, path, title, updated_at, current_version:bo_product_document_versions!bo_fk_product_documents_current_version(version)")
      .eq("product_id", product.id)
      .eq("locale", locale.language_code)
      .eq("environment", environment)
      .eq("status", "published")
      .order("sort_order");

    const documents = (documentsData || []).map((d: { slug: string; path: string; title: string; updated_at: string; current_version: { version: number } | null }) => ({
      slug: d.slug,
      path: d.path,
      title: d.title,
      version: d.current_version?.version || 1,
      updated_at: d.updated_at,
    }));

    let pageBehaviour: unknown[] = [];
    if (pageBehaviourRules && pageBehaviourRules.length > 0) {
      const ruleIds = pageBehaviourRules.map((r: { id: string }) => r.id);
      const { data: tierRules } = await supabase
        .schema("backoffice").from("bo_page_behaviour_tier_rules")
        .select("rule_id, tier, action, redirect_url, screen_slug")
        .in("rule_id", ruleIds);

      // type/to contract: redirect -> URL, screen -> App Screen slug, null/null -> show the page.
      type PbTier = { type: "redirect" | "screen" | null; to: string | null };
      const toTier = (t: { action: string; redirect_url: string | null; screen_slug: string | null }): PbTier => {
        if (t.action === "redirect" && t.redirect_url) return { type: "redirect", to: t.redirect_url };
        if (t.action === "screen" && t.screen_slug) return { type: "screen", to: t.screen_slug };
        return { type: null, to: null };
      };
      const tiersByRule: Record<string, Record<string, PbTier>> = {};
      for (const t of (tierRules || [])) {
        if (!tiersByRule[t.rule_id]) tiersByRule[t.rule_id] = {};
        tiersByRule[t.rule_id][t.tier] = toTier(t);
      }

      pageBehaviour = pageBehaviourRules.map((r) => ({
        path: r.path,
        label: r.label || undefined,
        position: r.position,
        tiers: Object.fromEntries(
          ["guest", "free", "premium"].map((tier) => [tier, tiersByRule[r.id]?.[tier] ?? { type: null, to: null }]),
        ),
      }));
    }

    // 15. Content consumption rules
    //
    // Two parallel views are emitted from the SAME rows so deployed apps that
    // still read the legacy `content_consumption` field keep working unchanged,
    // while updated apps can opt in to the richer `consumption_rules` shape that
    // carries optional per-rule rate-limit configuration.
    //   - `content_consumption` (legacy, frozen): { [type]: { [tier]: action } }
    //   - `consumption_rules` (new): { [type]: { [tier]: { action, rate_limit } } }
    const { data: consumptionRows } = await supabase
      .schema("backoffice").from("bo_product_content_consumption_rules")
      .select("content_type, tier, action, rate_limit_enabled, tries_limit, frequency_period, frequency_unit_count, on_limit_reached_action")
      .eq("product_id", product.id)
      .eq("environment", environment);

    const contentConsumption: Record<string, Record<string, string>> = {};
    const consumptionRules: Record<string, Record<string, {
      action: string;
      rate_limit: {
        enabled: boolean;
        tries: number | null;
        period: string | null;
        every: number;
        on_limit_reached: string | null;
      };
    }>> = {};

    for (const row of (consumptionRows || [])) {
      if (!contentConsumption[row.content_type]) contentConsumption[row.content_type] = {};
      contentConsumption[row.content_type][row.tier] = row.action;

      if (!consumptionRules[row.content_type]) consumptionRules[row.content_type] = {};
      const enabled = row.rate_limit_enabled === true;
      consumptionRules[row.content_type][row.tier] = {
        action: row.action,
        rate_limit: {
          enabled,
          tries: enabled ? (row.tries_limit ?? null) : null,
          period: enabled ? (row.frequency_period ?? null) : null,
          every: enabled ? (row.frequency_unit_count ?? 1) : 1,
          on_limit_reached: enabled ? (row.on_limit_reached_action ?? null) : null,
        },
      };
    }

    // 16. Unsubscribe method
    const { data: unsubRow } = await supabase
      .schema("backoffice").from("bo_product_unsubscribe_methods")
      .select("method, confirm_unsubscription, permanent_delete_after_unsub, external_url, external_link_target, config")
      .eq("product_id", product.id)
      .eq("environment", environment)
      .maybeSingle();

    let unsubMethod = null;
    if (unsubRow) {
      const base = {
        method: unsubRow.method,
        confirm_unsubscription: unsubRow.confirm_unsubscription ?? false,
        config: unsubRow.config || {},
      };
      if (unsubRow.method === "standard") {
        unsubMethod = { ...base, permanent_delete_after_unsub: unsubRow.permanent_delete_after_unsub ?? false };
      } else if (unsubRow.method === "external_link") {
        unsubMethod = { ...base, external_url: unsubRow.external_url || "", external_link_target: unsubRow.external_link_target || "browser" };
      } else {
        unsubMethod = base;
      }
    }

    // Build response
    const hostname = environment === "production" ? product.hostname_production : product.hostname_staging;

    return jsonResponse({
      ok: true,
      detected_by: detectedBy,
      country_fallback: countryFallback,
      service: {
        slug: service.slug,
        display_name: service.display_name,
      },
      product: {
        id: product.id,
        slug: product.slug,
        display_name: product.display_name,
        country_code: product.country_code,
        hostname,
      },
      language: {
        code: locale.language_code,
        display_name: locale.display_name,
        is_default: locale.is_default,
        locale: resolveLocaleCode(locale.language_code, product.country_code, locale.locale_override || null),
      },
      available_languages: locales.map((l: { language_code: string; display_name: string; is_default: boolean; locale_override: string | null }) => ({
        code: l.language_code,
        display_name: l.display_name,
        is_default: l.is_default,
        locale: resolveLocaleCode(l.language_code, product.country_code, l.locale_override || null),
      })),
      branding,
      assets: assetsMap,
      translations: translationsMap,
      config: configMap,
      feature_flags: flagsMap,
      login_methods: { signup, methods: loginMethods },
      menu_items: menuItems,
      footer_items: footerItems,
      footer_columns: (locale as Record<string, unknown>)[environment === 'production' ? 'footer_columns_production' : 'footer_columns_staging'] as number || 1,
      footer_hidden_pages: footerHiddenPages,
      page_behaviour: pageBehaviour,
      documents,
      content_consumption: contentConsumption,
      consumption_rules: consumptionRules,
      unsub_method: unsubMethod,
      ...((() => {
        // Avatar config merge: locale > product > service (lowest non-empty wins)
        // Each query now returns an array; pick the currently active row from each level
        type AvatarRow = { configuration?: Record<string, unknown>; themes?: unknown[]; event?: string; valid_from?: string | null; valid_to?: string | null };
        function pickActiveAvatar(rows: AvatarRow[] | null): AvatarRow | null {
          if (!rows || rows.length === 0) return null;
          const nowMs = Date.now();
          return rows.find(r => {
            const from = r.valid_from ? new Date(r.valid_from).getTime() : -Infinity;
            const to = r.valid_to ? new Date(r.valid_to).getTime() : Infinity;
            return from <= nowMs && nowMs <= to;
          }) ?? null;
        }

        const svcA = pickActiveAvatar(svcAvatar.data as AvatarRow[] | null);
        const prodA = pickActiveAvatar(prodAvatar.data as AvatarRow[] | null);
        const locA = pickActiveAvatar(localeAvatar.data as AvatarRow[] | null);

        let cfg: Record<string, unknown> | null = null;
        let thms: unknown[] = [];
        let evt: string | null = null;

        if (svcA?.configuration && Object.keys(svcA.configuration).length > 0) cfg = svcA.configuration;
        if (svcA?.themes && (svcA.themes as unknown[]).length > 0) thms = svcA.themes as unknown[];
        if (svcA?.event) evt = svcA.event;

        if (prodA?.configuration && Object.keys(prodA.configuration).length > 0) cfg = prodA.configuration;
        if (prodA?.themes && (prodA.themes as unknown[]).length > 0) thms = prodA.themes as unknown[];
        if (prodA?.event) evt = prodA.event;

        if (locA?.configuration && Object.keys(locA.configuration).length > 0) cfg = locA.configuration;
        if (locA?.themes && (locA.themes as unknown[]).length > 0) thms = locA.themes as unknown[];
        if (locA?.event) evt = locA.event;

        if (!cfg && thms.length === 0 && !evt) return {};
        const avatarBlock: Record<string, unknown> = {};
        if (cfg) {
          avatarBlock.configuration = cfg;
          avatarBlock.agent_id = (typeof cfg.agent_id === 'string' && cfg.agent_id) ? cfg.agent_id : null;
        } else {
          avatarBlock.agent_id = null;
        }
        if (thms.length > 0) avatarBlock.themes = thms;
        if (evt) avatarBlock.event = evt;
        return { avatar: avatarBlock };
      })()),
    });
  } catch (err) {
    return jsonResponse(
      { ok: false, error: err instanceof Error ? err.message : "Internal error" },
      500
    );
  }
});
