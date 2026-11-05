import { assertEquals, assertExists } from "@std/assert";
import { type FakeSupabase, get, loadFunction, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("screen-layout");

const SERVICE = "11111111-1111-4111-8111-111111111111";
const PRODUCT = "22222222-2222-4222-8222-222222222222";
const LOCALE_EN = "33333333-3333-4333-8333-333333333333";
const LOCALE_IT = "44444444-4444-4444-8444-444444444444";
const STORAGE = "http://supabase.test/storage/v1/object/public/product-assets/app-screens";

type Row = Record<string, unknown>;

function screen(id: string, slug: string, owner: Row, extra: Row = {}): Row {
  return {
    id, slug, name: slug[0].toUpperCase() + slug.slice(1), enabled: true, environment: "staging",
    service_id: null, product_id: null, product_locale_id: null, updated_at: "2026-10-30T10:00:00+00:00",
    ...owner, ...extra,
  };
}

function section(id: string, screenId: string, extra: Row = {}): Row {
  return {
    id, screen_id: screenId, platform: "mobile", widget_type: "placeholder_text", title: "Raw title",
    show_title: true, enabled: true, position: 0, col_span: 12, config: { label: "Label", description: "Raw description" },
    start_at_local: null, end_at_local: null, visible_to: null, created_at: "2026-10-30T10:00:00+00:00", ...extra,
  };
}

function seedBase(fake: FakeSupabase) {
  fake.seed("backoffice.bo_products", [{ id: PRODUCT, service_id: SERVICE, timezone: null, country_code: "IT" }]);
  fake.seed("backoffice.bo_product_locales", [
    { id: LOCALE_EN, product_id: PRODUCT, language_code: "en", is_default: true, status: "active", created_at: "2026-01-01" },
    { id: LOCALE_IT, product_id: PRODUCT, language_code: "it", is_default: false, status: "active", created_at: "2026-01-02" },
  ]);
}

async function call(params: Record<string, string>) {
  const res = await handler(get("screen-layout", params));
  return { status: res.status, body: await readJson(res), headers: res.headers };
}

// ---------------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------------

Deno.test("screen-layout: OPTIONS answers the CORS preflight", async () => {
  const res = await handler(new Request("http://edge.test/screen-layout", { method: "OPTIONS" }));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
});

Deno.test("screen-layout: only GET is allowed", async () => {
  const res = await handler(new Request("http://edge.test/screen-layout", { method: "POST" }));
  assertEquals(res.status, 405);
  assertEquals(await res.json(), { ok: false, error: "Use GET" });
});

Deno.test("screen-layout: invalid parameters return 400 with the spec messages", async () => {
  const cases: [Record<string, string>, string][] = [
    [{}, "'product_id' is required"],
    [{ product_id: "abc" }, "'product_id' must be a valid product code (uuid)"],
    [{ product_id: PRODUCT, environment: "dev" }, "environment must be 'staging' or 'production'"],
    [{ product_id: PRODUCT, platform: "tv" }, "platform must be 'mobile' or 'desktop'"],
    [{ product_id: PRODUCT, screen: "-bad" }, "Invalid screen"],
    [{ product_id: PRODUCT, locale: "1" }, "Invalid locale"],
    [{ product_id: PRODUCT, language_code: "toolong-locale-x" }, "Invalid locale"],
  ];
  for (const [params, error] of cases) {
    const { status, body } = await call(params);
    assertEquals(status, 400, JSON.stringify(params));
    assertEquals(body, { ok: false, error });
  }
});

Deno.test("screen-layout: unknown product returns 404", async () => {
  await withFake(async () => {
    const { status, body } = await call({ product_id: PRODUCT });
    assertEquals(status, 404);
    assertEquals(body, { ok: false, error: "Product not found" });
  });
});

Deno.test("screen-layout: database errors map to the spec 500 messages", async () => {
  await withFake(async (fake) => {
    fake.fail("backoffice.bo_products");
    assertEquals((await call({ product_id: PRODUCT })).body, { ok: false, error: "Could not load product" });
  });
  await withFake(async (fake) => {
    seedBase(fake);
    fake.fail("backoffice.bo_product_locales");
    assertEquals((await call({ product_id: PRODUCT })).body, { ok: false, error: "Could not load languages" });
  });
  await withFake(async (fake) => {
    seedBase(fake);
    fake.fail("backoffice.bo_app_screens");
    const { status, body } = await call({ product_id: PRODUCT });
    assertEquals(status, 500);
    assertEquals(body, { ok: false, error: "Could not load screens" });
  });
});

// ---------------------------------------------------------------------------
// Screen list
// ---------------------------------------------------------------------------

Deno.test("screen-layout: list merges levels, hides disabled screens and sorts by key", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-home", "home", { service_id: SERVICE }),
      screen("s-promo", "promo", { service_id: SERVICE }),
      screen("p-promo", "promo", { product_id: PRODUCT }, { name: "Promo product" }),
      screen("l-bonus", "bonus", { product_locale_id: LOCALE_EN }),
      screen("l-bonus-it", "bonus-it", { product_locale_id: LOCALE_IT }),
      screen("p-off", "off", { product_id: PRODUCT }, { enabled: false }),
      screen("s-prod", "home", { service_id: SERVICE }, { environment: "production" }),
      screen("x-other", "other", { service_id: "99999999-9999-4999-8999-999999999999" }),
    ]);
    const { status, body } = await call({ product_id: PRODUCT, environment: "staging" });
    assertEquals(status, 200);
    assertEquals(body, {
      ok: true,
      data: {
        environment: "staging",
        locale: "en",
        platform: "mobile",
        timezone: "Europe/Rome",
        screens: [
          { screen: "bonus", name: "Bonus", source_level: "locale", resolved_platform: "mobile", sections: [] },
          { screen: "home", name: "Home", source_level: "service", resolved_platform: "mobile", sections: [] },
          { screen: "promo", name: "Promo product", source_level: "product", resolved_platform: "mobile", sections: [] },
        ],
      },
    });
  });
});

Deno.test("screen-layout: list mode returns each screen complete, like the single-screen call", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-home", "home", { service_id: SERVICE }),
      screen("s-promo", "promo", { service_id: SERVICE }),
      screen("s-empty", "empty", { service_id: SERVICE }),
    ]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("h-desk", "s-home", { platform: "desktop", position: 0, config: { label: "Desk" } }),
      section("h-mob-2", "s-home", { position: 3, widget_type: "banner", config: { image_url: `${STORAGE}/b.png` } }),
      section("h-mob-1", "s-home", { position: 1, visible_to: ["free"] }),
      section("h-hidden", "s-home", { position: 2, enabled: false }),
      section("p-desk", "s-promo", { platform: "desktop", position: 0, title: "Desktop only" }),
      section("p-future", "s-promo", { platform: "desktop", position: 1, start_at_local: "2999-01-01T00:00:00" }),
    ]);
    const list = await call({ product_id: PRODUCT, environment: "staging", platform: "mobile" });
    assertEquals(list.status, 200);
    const screens = (list.body.data as Row).screens as Row[];
    assertEquals(screens.map((s) => [s.screen, s.resolved_platform]), [["empty", "mobile"], ["home", "mobile"], ["promo", "desktop"]]);
    assertEquals(screens[0].sections, []);

    for (const item of screens) {
      const single = await call({ product_id: PRODUCT, environment: "staging", platform: "mobile", screen: String(item.screen) });
      const data = single.body.data as Row;
      assertEquals(item.sections, data.sections, String(item.screen));
      assertEquals(item.resolved_platform, data.resolved_platform, String(item.screen));
      assertEquals(item.source_level, data.source_level, String(item.screen));
    }
    assertEquals((screens[1].sections as Row[]).map((s) => [s.id, s.position]), [["h-mob-1", 0], ["h-mob-2", 1]]);

    const widgetQueries = fake.requests.filter((r) => r.path.endsWith("/bo_app_screen_sections"));
    assertEquals(widgetQueries.length, 1 + screens.length);
  });
});

Deno.test("screen-layout: list mode hides slugs whose winning level is disabled", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-home", "home", { service_id: SERVICE }),
      screen("s-promo", "promo", { service_id: SERVICE }),
      screen("p-promo", "promo", { product_id: PRODUCT }, { enabled: false }),
      screen("s-quiz", "quiz", { service_id: SERVICE }),
      screen("l-quiz", "quiz", { product_locale_id: LOCALE_EN }, { enabled: false }),
    ]);
    const screens = ((await call({ product_id: PRODUCT, environment: "staging" })).body.data as Row).screens as Row[];
    assertEquals(screens.map((s) => s.screen), ["home"]);
  });
});

Deno.test("screen-layout: list mode with no active screen returns 200 and an empty list", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    const { status, body } = await call({ product_id: PRODUCT, environment: "staging", platform: "desktop" });
    assertEquals(status, 200);
    assertEquals(body, { ok: true, data: { environment: "staging", locale: "en", platform: "desktop", timezone: "Europe/Rome", screens: [] } });
    assertEquals(fake.requests.filter((r) => r.path.endsWith("/bo_app_screen_sections")).length, 0);
  });
});

Deno.test("screen-layout: list mode translates the texts of every screen", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-a", "a", { service_id: SERVICE }),
      screen("s-b", "b", { service_id: SERVICE }),
    ]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("wa", "s-a", { config: { i18n: { title: { namespace: "aScreen", key: "t" } } } }),
      section("wb", "s-b", { config: { i18n: { title: { namespace: "bScreen", key: "t" } } } }),
    ]);
    fake.seed("backoffice.bo_service_translations_defaults", [
      { service_id: SERVICE, environment: "staging", language_code: "en", namespace: "aScreen", key: "t", value: "Title A" },
      { service_id: SERVICE, environment: "staging", language_code: "en", namespace: "bScreen", key: "t", value: "Title B" },
    ]);
    const screens = ((await call({ product_id: PRODUCT, environment: "staging" })).body.data as Row).screens as Row[];
    assertEquals(screens.map((s) => (s.sections as Row[])[0].title), ["Title A", "Title B"]);
  });
});

Deno.test("screen-layout: list mode errors on widgets and texts return 500", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.fail("backoffice.bo_app_screen_sections");
    assertEquals((await call({ product_id: PRODUCT, environment: "staging" })).body, { ok: false, error: "Could not load screens" });
  });
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.seed("backoffice.bo_app_screen_sections", [section("w", "s-home", { config: { i18n: { title: { namespace: "n", key: "k" } } } })]);
    fake.fail("backoffice.bo_product_translations");
    assertEquals((await call({ product_id: PRODUCT, environment: "staging" })).body, { ok: false, error: "Could not load texts" });
  });
});

Deno.test("screen-layout: an empty screen returns the screen list", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-home", "home", { service_id: SERVICE }),
      screen("p-promo", "promo", { product_id: PRODUCT }),
    ]);
    for (const value of ["", "   "]) {
      const { status, body } = await call({ product_id: PRODUCT, environment: "staging", screen: value });
      assertEquals(status, 200, JSON.stringify(value));
      assertEquals(((body.data as Row).screens as Row[]).map((s) => s.screen), ["home", "promo"]);
    }
  });
});

Deno.test("screen-layout: environment defaults to production", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    const { status, body } = await call({ product_id: PRODUCT, screen: "home" });
    assertEquals(status, 404);
    assertEquals(body, { ok: false, error: "Screen 'home' not found" });
  });
});

// ---------------------------------------------------------------------------
// Locale and time zone
// ---------------------------------------------------------------------------

Deno.test("screen-layout: locale resolution (requested, alias, default, first, none)", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    assertEquals(((await call({ product_id: PRODUCT, locale: "IT" })).body.data as Row).locale, "it");
    assertEquals(((await call({ product_id: PRODUCT, language_code: "it" })).body.data as Row).locale, "it");
    assertEquals(((await call({ product_id: PRODUCT, locale: "fr" })).body.data as Row).locale, "en");
    assertEquals(((await call({ product_id: PRODUCT, locale: "en", language_code: "it" })).body.data as Row).locale, "en");
  });
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_products", [{ id: PRODUCT, service_id: SERVICE, timezone: null, country_code: "IT" }]);
    fake.seed("backoffice.bo_product_locales", [
      { id: LOCALE_IT, product_id: PRODUCT, language_code: "it", is_default: false, status: "active", created_at: "2026-01-02" },
      { id: LOCALE_EN, product_id: PRODUCT, language_code: "en", is_default: true, status: "archived", created_at: "2026-01-01" },
    ]);
    assertEquals(((await call({ product_id: PRODUCT, locale: "en" })).body.data as Row).locale, "it");
  });
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_products", [{ id: PRODUCT, service_id: SERVICE, timezone: null, country_code: "IT" }]);
    assertEquals(((await call({ product_id: PRODUCT })).body.data as Row).locale, null);
  });
});

Deno.test("screen-layout: time zone from product, then country, then UTC", async () => {
  const tz = async (timezone: string | null, country: string | null) =>
    await withFake(async (fake) => {
      fake.seed("backoffice.bo_products", [{ id: PRODUCT, service_id: SERVICE, timezone, country_code: country }]);
      return ((await call({ product_id: PRODUCT })).body.data as Row).timezone;
    });
  assertEquals(await tz("Asia/Tokyo", "IT"), "Asia/Tokyo");
  assertEquals(await tz("Not/AZone", "ZA"), "Africa/Johannesburg");
  assertEquals(await tz(null, "za"), "Africa/Johannesburg");
  assertEquals(await tz(null, "XX"), "UTC");
  assertEquals(await tz(null, null), "UTC");
});

// ---------------------------------------------------------------------------
// One screen
// ---------------------------------------------------------------------------

Deno.test("screen-layout: the most specific level wins and disabled winners return 404", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [
      screen("s-home", "home", { service_id: SERVICE }),
      screen("p-home", "home", { product_id: PRODUCT }),
      screen("l-home", "home", { product_locale_id: LOCALE_IT }),
      screen("p-off", "off", { product_id: PRODUCT }, { enabled: false }),
      screen("s-off", "off", { service_id: SERVICE }),
    ]);
    const en = await call({ product_id: PRODUCT, screen: "home", environment: "staging" });
    assertEquals((en.body.data as Row).source_level, "product");
    const it = await call({ product_id: PRODUCT, screen: "home", environment: "staging", locale: "it" });
    assertEquals((it.body.data as Row).source_level, "locale");
    const off = await call({ product_id: PRODUCT, screen: "off", environment: "staging" });
    assertEquals(off.status, 404);
    assertEquals(off.body, { ok: false, error: "Screen 'off' is disabled for this product" });
  });
});

Deno.test("screen-layout: screen key is matched case-insensitively", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    const { status, body } = await call({ product_id: PRODUCT, screen: "Home", environment: "staging" });
    assertEquals(status, 200);
    assertEquals((body.data as Row).screen, "home");
  });
});

Deno.test("screen-layout: full section output per widget type", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("w-text", "s-home", {
        position: 0,
        config: { label: "Info", description: "Watch and earn", link: { type: "internal", url: "rewards/list" } },
        visible_to: ["premium", "guest"],
      }),
      section("w-banner", "s-home", {
        widget_type: "banner", position: 1, col_span: 6, title: "Summer promo",
        config: { label: "Banner", description: "", image_source: "upload", image_url: `${STORAGE}/banner.png`, link: { type: "external", url: "https://example.com/promo" } },
      }),
      section("w-video", "s-home", {
        widget_type: "video", position: 2, col_span: 6, title: "How it works",
        config: { label: "Video", description: "", video_source: "external", video_url: "https://cdn.example.com/intro.mp4", cover_image_url: "https://cdn.example.com/poster.jpg" },
      }),
      section("w-custom", "s-home", {
        widget_type: "custom_widget", position: 3, title: "Top picks", show_title: false,
        config: {
          label: "", description: "Picks", carousel_enabled: true,
          slides: [
            { id: "x1", title: "Dogs", description: "dropped", image_url: `${STORAGE}/dogs.jpg`, link: { type: "internal", url: "dogs" } },
            { id: "x2", title: "", image_url: "https://cdn.example.com/cats.jpg", link: { type: "none", url: "" } },
            { id: "x3", title: "", image_url: "" },
          ],
        },
      }),
    ]);
    const { status, body } = await call({ product_id: PRODUCT, screen: "home", environment: "staging" });
    assertEquals(status, 200);
    const data = body.data as Row;
    assertEquals(data.screen, "home");
    assertEquals(data.name, "Home");
    assertEquals(data.platform, "mobile");
    assertEquals(data.resolved_platform, "mobile");
    assertEquals(data.sections, [
      {
        id: "w-text", widget_type: "placeholder_text", title: "Raw title", show_title: true, col_span: 12, position: 0,
        start_at: null, end_at: null, visible_to: ["guest", "premium"], label: "Info", description: "Watch and earn",
        link: { type: "internal", url: "rewards/list" },
      },
      {
        id: "w-banner", widget_type: "banner", title: "Summer promo", show_title: true, col_span: 6, position: 1,
        start_at: null, end_at: null, visible_to: ["guest", "free", "premium"], label: "Banner", description: "",
        link: { type: "external", url: "https://example.com/promo" }, image_source: "upload", image_url: `${STORAGE}/banner.png`,
      },
      {
        id: "w-video", widget_type: "video", title: "How it works", show_title: true, col_span: 6, position: 2,
        start_at: null, end_at: null, visible_to: ["guest", "free", "premium"], label: "Video", description: "",
        link: { type: null, url: null }, video_url: "https://cdn.example.com/intro.mp4",
        image_source: "url", image_url: "https://cdn.example.com/poster.jpg",
      },
      {
        id: "w-custom", widget_type: "custom_widget", title: "Top picks", show_title: false, col_span: 12, position: 3,
        start_at: null, end_at: null, visible_to: ["guest", "free", "premium"], label: null, description: "Picks",
        link: { type: null, url: null },
        items: [
          { id: "x1", title: "Dogs", image_source: "upload", image_url: `${STORAGE}/dogs.jpg`, link: { type: "internal", url: "dogs" } },
          { id: "x2", title: "", image_source: "url", image_url: "https://cdn.example.com/cats.jpg", link: { type: null, url: null } },
        ],
      },
    ]);
  });
});

Deno.test("screen-layout: invalid links and media are nulled", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("a", "s-home", { position: 0, config: { link: { type: "external", url: "http://insecure.example.com" } } }),
      section("b", "s-home", { position: 1, config: { link: { type: "internal", url: "/absolute" } } }),
      section("c", "s-home", { position: 2, config: { link: { type: "internal", url: "../escape" } } }),
      section("d", "s-home", {
        position: 3, widget_type: "banner",
        config: { image_source: "external", image_url: "javascript:alert(1)", link: { type: "external", url: "ftp://x.y" } },
      }),
      section("e", "s-home", { position: 4, widget_type: "video", config: { video_source: "internal", video_url: "/abs.mp4" } }),
      section("f", "s-home", { position: 5, widget_type: "unknown_type" }),
    ]);
    const sections = ((await call({ product_id: PRODUCT, screen: "home", environment: "staging" })).body.data as Row).sections as Row[];
    assertEquals(sections.map((s) => s.id), ["a", "b", "c", "d", "e"]);
    for (const s of sections) assertEquals(s.link, { type: null, url: null }, String(s.id));
    assertEquals([sections[3].image_source, sections[3].image_url], [null, null]);
    assertEquals(sections[4].video_url, null);
  });
});

Deno.test("screen-layout: carousel off keeps only the first item", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("w", "s-home", {
        widget_type: "custom_widget",
        config: { carousel_enabled: false, slides: [{ id: "1", title: "One" }, { id: "2", title: "Two" }] },
      }),
    ]);
    const [s] = ((await call({ product_id: PRODUCT, screen: "home", environment: "staging" })).body.data as Row).sections as Row[];
    assertEquals((s.items as Row[]).map((i) => i.id), ["1"]);
  });
});

Deno.test("screen-layout: platform fallback, hidden widgets and positions restart from 0", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("m-hidden", "s-home", { position: 0, enabled: false }),
      section("m-2", "s-home", { position: 5 }),
      section("m-1", "s-home", { position: 2 }),
    ]);
    const { body } = await call({ product_id: PRODUCT, screen: "home", environment: "staging", platform: "DESKTOP" });
    const data = body.data as Row;
    assertEquals(data.platform, "desktop");
    assertEquals(data.resolved_platform, "mobile");
    assertEquals((data.sections as Row[]).map((s) => [s.id, s.position]), [["m-1", 0], ["m-2", 1]]);
  });
});

Deno.test("screen-layout: schedule uses product-local minutes with an inclusive end", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_products", [{ id: PRODUCT, service_id: SERVICE, timezone: "UTC", country_code: null }]);
    fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
    const now = new Date().toISOString().slice(0, 16);
    fake.seed("backoffice.bo_app_screen_sections", [
      section("future", "s-home", { position: 0, start_at_local: "2999-01-01T00:00:00" }),
      section("past", "s-home", { position: 1, end_at_local: "2000-01-01 00:00:00" }),
      section("ends-now", "s-home", { position: 2, end_at_local: `${now}:00` }),
      section("running", "s-home", { position: 3, start_at_local: "2000-01-01T00:00:00", end_at_local: "2999-12-31T23:59:00" }),
    ]);
    const sections = ((await call({ product_id: PRODUCT, screen: "home", environment: "staging" })).body.data as Row).sections as Row[];
    assertEquals(sections.map((s) => s.id), ["ends-now", "running"]);
    assertEquals(sections[1].start_at, "2000-01-01T00:00");
    assertEquals(sections[1].end_at, "2999-12-31T23:59");
  });
});

// ---------------------------------------------------------------------------
// Texts
// ---------------------------------------------------------------------------

const ref = (namespace: string, key: string) => ({ namespace, key });

function seedTexts(fake: FakeSupabase) {
  seedBase(fake);
  fake.seed("backoffice.bo_app_screens", [screen("s-home", "home", { service_id: SERVICE })]);
  fake.seed("backoffice.bo_app_screen_sections", [
    section("w", "s-home", {
      platform: "desktop", widget_type: "custom_widget", title: "raw",
      config: {
        i18n: { title: ref("homeScreen", "titleDesktop"), description: ref("homeScreen", "desc") },
        carousel_enabled: true,
        slides: [{ id: "s1", title: "raw slide", image_url: "https://cdn.example.com/a.jpg", i18n: { title: ref("homeScreen", "slide") } }],
      },
    }),
  ]);
  fake.seed("backoffice.bo_service_translations_defaults", [
    { service_id: SERVICE, environment: "staging", language_code: "en", namespace: "homeScreen", key: "title", value: "Service title" },
    { service_id: SERVICE, environment: "staging", language_code: "en", namespace: "homeScreen", key: "desc", value: "Service desc" },
    { service_id: SERVICE, environment: "staging", language_code: "en", namespace: "homeScreen", key: "slide", value: "Service slide" },
    { service_id: SERVICE, environment: "staging", language_code: "it", namespace: "homeScreen", key: "desc", value: "Descrizione" },
  ]);
  fake.seed("backoffice.bo_product_translations", [
    { product_locale_id: LOCALE_EN, environment: "staging", namespace: "homeScreen", key: "slide", value: "Locale slide" },
    { product_locale_id: LOCALE_EN, environment: "production", namespace: "homeScreen", key: "desc", value: "Prod desc" },
  ]);
}

Deno.test("screen-layout: texts come from locale overrides, then service defaults, desktop keys fall back", async () => {
  await withFake(async (fake) => {
    seedTexts(fake);
    const { body } = await call({ product_id: PRODUCT, screen: "home", environment: "staging", platform: "desktop" });
    const [s] = (body.data as Row).sections as Row[];
    assertEquals(s.title, "Service title");
    assertEquals(s.description, "Service desc");
    assertEquals((s.items as Row[])[0].title, "Locale slide");

    const it = await call({ product_id: PRODUCT, screen: "home", environment: "staging", platform: "desktop", locale: "it" });
    const [sIt] = (it.body.data as Row).sections as Row[];
    assertEquals(sIt.description, "Descrizione");
    assertEquals(sIt.title, "raw");
  });
});

Deno.test("screen-layout: text loading errors return 500", async () => {
  await withFake(async (fake) => {
    seedTexts(fake);
    fake.fail("backoffice.bo_product_translations");
    const { status, body } = await call({ product_id: PRODUCT, screen: "home", environment: "staging" });
    assertEquals(status, 500);
    assertEquals(body, { ok: false, error: "Could not load texts" });
  });
});

Deno.test("screen-layout: responses are JSON with CORS headers", async () => {
  await withFake(async (fake) => {
    seedBase(fake);
    const { headers } = await call({ product_id: PRODUCT });
    assertEquals(headers.get("Content-Type"), "application/json");
    assertExists(headers.get("Access-Control-Allow-Origin"));
  });
});
