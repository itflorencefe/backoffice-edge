import { assertEquals, assertMatch } from "@std/assert";
import { type FakeSupabase, get, loadFunction, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("get-product-config");

type Row = Record<string, unknown>;

const SERVICE = "svc-1";
const PRODUCT = "prod-it";
const LOC_IT = "loc-it";
const LOC_EN = "loc-en";

function seedProduct(fake: FakeSupabase) {
  fake.seed("backoffice.bo_services", [{ id: SERVICE, slug: "test", display_name: "Test", status: "active" }]);
  fake.seed("backoffice.bo_products", [
    {
      id: PRODUCT, service_id: SERVICE, slug: "it-test", display_name: "Test IT", country_code: "IT", status: "active",
      is_default: false, native_bundle_id: null, hostname_staging: "staging.test.it", hostname_production: "www.test.it",
    },
    {
      id: "prod-fr", service_id: SERVICE, slug: "fr-test", display_name: "Test FR", country_code: "FR", status: "active",
      is_default: true, native_bundle_id: null, hostname_staging: null, hostname_production: null,
    },
  ]);
  fake.seed("backoffice.bo_product_locales", [
    { id: LOC_IT, product_id: PRODUCT, language_code: "it", display_name: "Italiano", is_default: true, status: "active", locale_override: null, footer_columns_staging: 3, footer_columns_production: 2 },
    { id: LOC_EN, product_id: PRODUCT, language_code: "en", display_name: "English", is_default: false, status: "active", locale_override: "en-GB", footer_columns_staging: 1, footer_columns_production: 1 },
    { id: "loc-fr", product_id: "prod-fr", language_code: "fr", display_name: "Français", is_default: true, status: "active", locale_override: null, footer_columns_staging: 1, footer_columns_production: 1 },
  ]);
}

async function call(params: Record<string, string>, headers?: Record<string, string>) {
  const res = await handler(get("get-product-config", params, headers));
  return { status: res.status, body: await readJson(res) };
}

const base = { slug: "test", country_code: "it", environment: "staging" };

Deno.test("get-product-config: request validation", async () => {
  const noAuth = await handler(new Request("http://edge.test/get-product-config?slug=test&country_code=IT"));
  assertEquals(noAuth.status, 401);
  assertEquals((await call({ slug: "test" })).status, 400);
  assertEquals((await call({ ...base, environment: "dev" })).body, { ok: false, error: "environment must be 'staging' or 'production'" });
  const options = await handler(new Request("http://edge.test/get-product-config", { method: "OPTIONS" }));
  assertEquals(options.status, 200);
});

Deno.test("get-product-config: unknown service or product returns 404", async () => {
  await withFake(async () => {
    const { status, body } = await call(base);
    assertEquals(status, 404);
    assertMatch(String(body.error), /Service 'test' not found/);
  });
});

Deno.test("get-product-config: resolves by slug+country, by domain and falls back to the default product", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    const bySlug = await call(base);
    assertEquals(bySlug.status, 200);
    assertEquals(bySlug.body.detected_by, "slug+country");
    assertEquals(bySlug.body.country_fallback, false);
    assertEquals((bySlug.body.product as Row).hostname, "staging.test.it");

    const byDomain = await call({ domain: "https://www.test.it/", environment: "production" });
    assertEquals(byDomain.body.detected_by, "domain");
    assertEquals((byDomain.body.product as Row).id, PRODUCT);

    const fallback = await call({ ...base, country_code: "ES" });
    assertEquals(fallback.body.detected_by, "slug+default");
    assertEquals(fallback.body.country_fallback, true);
    assertEquals((fallback.body.product as Row).id, "prod-fr");
  });
});

Deno.test("get-product-config: resolves by bundle_id (with country, or the default product of the bundle)", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    for (const p of fake.rows("backoffice.bo_products")) p.native_bundle_id = "com.test.app";

    const withCountry = await call({ bundle_id: "com.test.app", country_code: "it", environment: "production" });
    assertEquals(withCountry.status, 200);
    assertEquals(withCountry.body.detected_by, "bundle_id+country");
    assertEquals((withCountry.body.product as Row).id, PRODUCT);

    const bundleOnly = await call({ bundle_id: " com.test.app ", environment: "production" });
    assertEquals(bundleOnly.status, 200);
    assertEquals(bundleOnly.body.detected_by, "bundle_id+default");
    assertEquals((bundleOnly.body.product as Row).id, "prod-fr");

    const unknownCountry = await call({ bundle_id: "com.test.app", country_code: "es", environment: "production" });
    assertEquals(unknownCountry.body.detected_by, "bundle_id+default");

    const unknownBundle = await call({ bundle_id: "com.other.app", environment: "production" });
    assertEquals(unknownBundle.status, 404);

    const blank = await call({ bundle_id: "  ", environment: "production" });
    assertEquals(blank.status, 400);
    assertMatch(String(blank.body.error), /'bundle_id'/);
  });
});

Deno.test("get-product-config: language resolution and locale codes", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    const def = await call(base);
    assertEquals(def.body.language, { code: "it", display_name: "Italiano", is_default: true, locale: "it-IT" });
    assertEquals(def.body.footer_columns, 3);

    const en = await call({ ...base, language_code: "EN" });
    assertEquals((en.body.language as Row).code, "en");
    assertEquals((en.body.language as Row).locale, "en-GB");

    const unknown = await call({ ...base, language_code: "de" });
    assertEquals((unknown.body.language as Row).code, "it");
    assertEquals((def.body.available_languages as Row[]).map((l) => l.code), ["it", "en"]);
  });
});

Deno.test("get-product-config: product without active languages returns 404", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    fake.seed("backoffice.bo_product_locales", []);
    const { status, body } = await call(base);
    assertEquals(status, 404);
    assertEquals(body.error, "No active language configured for this product");
  });
});

Deno.test("get-product-config: locale values override service defaults", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    const env = { environment: "staging" };
    fake.seed("backoffice.bo_service_branding_defaults", [
      { service_id: SERVICE, ...env, colors: { primary: "#000", secondary: "#111" }, fonts: { body: "Inter" } },
    ]);
    fake.seed("backoffice.bo_product_branding", [{ product_locale_id: LOC_IT, ...env, colors: { primary: "#f00" } }]);
    fake.seed("backoffice.bo_service_translations_defaults", [
      { service_id: SERVICE, ...env, language_code: "it", namespace: "home", key: "title", value: "Servizio" },
      { service_id: SERVICE, ...env, language_code: "it", namespace: "home", key: "cta", value: "Gioca" },
      { service_id: SERVICE, ...env, language_code: "en", namespace: "home", key: "title", value: "English" },
    ]);
    fake.seed("backoffice.bo_product_translations", [
      { product_locale_id: LOC_IT, ...env, namespace: "home", key: "title", value: "Prodotto" },
      { product_locale_id: LOC_IT, environment: "production", namespace: "home", key: "cta", value: "Prod" },
    ]);
    fake.seed("backoffice.bo_service_public_config_defaults", [
      { service_id: SERVICE, ...env, key: "A", value: "svc" },
      { service_id: SERVICE, ...env, key: "B", value: "svc" },
    ]);
    fake.seed("backoffice.bo_product_public_config", [{ product_locale_id: LOC_IT, ...env, key: "B", value: "loc" }]);
    fake.seed("backoffice.bo_service_feature_flags_defaults", [
      { service_id: SERVICE, ...env, flag_key: "quiz", enabled: false },
      { service_id: SERVICE, ...env, flag_key: "games", enabled: true },
    ]);
    fake.seed("backoffice.bo_product_feature_flags", [{ product_locale_id: LOC_IT, ...env, flag_key: "quiz", enabled: true }]);

    const { body } = await call(base);
    assertEquals((body.branding as Row).colors, { primary: "#f00", secondary: "#111" });
    assertEquals((body.branding as Row).fonts, { body: "Inter" });
    assertEquals(body.translations, { home: { title: "Prodotto", cta: "Gioca" } });
    assertEquals(body.config, { A: "svc", B: "loc" });
    assertEquals(body.feature_flags, { quiz: true, games: true });

    const dict = await call({ ...base, "show-dict": "1" });
    assertEquals(dict.body.translations, { home: { title: "title", cta: "cta" } });
  });
});

Deno.test("get-product-config: login methods get country phone rules only for MSISDN types", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    fake.seed("backoffice.bo_product_login_methods", [
      { product_id: PRODUCT, environment: "staging", type: "google", enabled: true, is_default: false, display_order: 20, config: { app_id: "g-1" } },
      { product_id: PRODUCT, environment: "staging", type: "msisdn_pin", enabled: true, is_default: true, display_order: 10, config: { pin_length: 6 } },
      { product_id: PRODUCT, environment: "production", type: "ios", enabled: true, is_default: false, display_order: 0, config: {} },
    ]);
    const methods = (await call(base)).body.login_methods as Row[];
    assertEquals(methods.map((m) => [m.type, m.order, m.default]), [["msisdn_pin", 10, true], ["google", 20, false]]);
    const msisdn = methods[0].config as Row;
    assertEquals(msisdn.msisdn_prefix, "+39");
    assertEquals(msisdn.pin_length, 6);
    assertEquals(methods[1].config, { app_id: "g-1" });
  });
});

Deno.test("get-product-config: page behaviour merges Service > Product > Language per path", async () => {
  await withFake(async (fake) => {
    seedProduct(fake);
    const env = { environment: "staging", label: null, service_id: null, product_id: null, product_locale_id: null };
    fake.seed("backoffice.bo_page_behaviour_rules", [
      { ...env, id: "s-games", service_id: SERVICE, path: "/games", position: 1, enabled: true },
      { ...env, id: "p-games", product_id: PRODUCT, path: "/games", position: 1, enabled: true, label: "Games" },
      { ...env, id: "s-vip", service_id: SERVICE, path: "/vip", position: 0, enabled: true },
      { ...env, id: "l-vip", product_locale_id: LOC_IT, path: "/vip", position: 0, enabled: false },
      { ...env, id: "s-quiz", service_id: SERVICE, path: "/quiz", position: 1, enabled: true },
      { ...env, id: "en-only", product_locale_id: LOC_EN, path: "/en", position: 0, enabled: true },
      { ...env, id: "other-svc", service_id: "svc-2", path: "/other", position: 0, enabled: true },
      { ...env, id: "prod-env", service_id: SERVICE, path: "/prod", position: 0, enabled: true, environment: "production" },
    ]);
    fake.seed("backoffice.bo_page_behaviour_tier_rules", [
      { rule_id: "s-games", tier: "guest", action: "redirect", redirect_url: "/service", screen_slug: null },
      { rule_id: "p-games", tier: "guest", action: "redirect", redirect_url: "/login", screen_slug: null },
      { rule_id: "p-games", tier: "free", action: "screen", redirect_url: null, screen_slug: "upsell" },
      { rule_id: "p-games", tier: "premium", action: "none", redirect_url: null, screen_slug: null },
    ]);
    const rules = (await call(base)).body.page_behaviour as Row[];
    assertEquals(rules, [
      {
        path: "/games", label: "Games", position: 1,
        tiers: { guest: { type: "redirect", to: "/login" }, free: { type: "screen", to: "upsell" }, premium: { type: null, to: null } },
      },
      {
        path: "/quiz", position: 1,
        tiers: { guest: { type: null, to: null }, free: { type: null, to: null }, premium: { type: null, to: null } },
      },
    ]);
  });
});
