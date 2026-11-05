import { assertEquals } from "@std/assert";
import { type FakeSupabase, loadFunction, post, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("clone-product");

const TOKEN = "editor-token";
const auth = { Authorization: `Bearer ${TOKEN}` };
const body = { source_product_id: "src", new_slug: "fr-test", new_display_name: "Test FR", new_country_code: "fr" };

function seedEditor(fake: FakeSupabase, role = "editor") {
  fake.addAuthUser({ id: "user-1", email: "editor@example.com", token: TOKEN });
  fake.seed("backoffice.bo_backoffice_users", [{ id: "bo-1", user_id: "user-1", role, is_active: true }]);
}

/** A JWT-shaped token whose payload carries app_role (the signature is not checked by the function). */
function appUserToken(): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "");
  return `${b64({ alg: "HS256" })}.${b64({ app_role: "app_user" })}.sig`;
}

Deno.test("clone-product: access control", async () => {
  await withFake(async (fake) => {
    const noAuth = await handler(new Request("http://edge.test/clone-product", { method: "POST", body: "{}" }));
    assertEquals(noAuth.status, 401);

    const badToken = await handler(post("clone-product", body, { Authorization: "Bearer nope" }));
    assertEquals(badToken.status, 401);

    const appUser = await handler(post("clone-product", body, { Authorization: `Bearer ${appUserToken()}` }));
    assertEquals(appUser.status, 403);

    seedEditor(fake, "viewer");
    const viewer = await handler(post("clone-product", body, auth));
    assertEquals(viewer.status, 403);
    assertEquals((await readJson(viewer)).error, "Insufficient permissions");

    const getRes = await handler(new Request("http://edge.test/clone-product", { method: "GET", headers: auth }));
    assertEquals(getRes.status, 405);
  });
});

Deno.test("clone-product: required fields and unknown source", async () => {
  await withFake(async (fake) => {
    seedEditor(fake);
    const missing = await handler(post("clone-product", { source_product_id: "src" }, auth));
    assertEquals(missing.status, 400);
    const unknown = await handler(post("clone-product", body, auth));
    assertEquals(unknown.status, 404);
    assertEquals((await readJson(unknown)).error, "Source product not found");
  });
});

Deno.test("clone-product: copies product data, locales, login methods, rules and app screens", async () => {
  await withFake(async (fake) => {
    seedEditor(fake, "admin");
    fake.seed("backoffice.bo_products", [
      { id: "src", service_id: "svc", slug: "it-test", display_name: "Test IT", country_code: "IT", native_bundle_id: null, timezone: "Europe/Rome" },
    ]);
    fake.seed("backoffice.bo_product_locales", [
      { id: "loc-src", product_id: "src", language_code: "it", display_name: "Italiano", is_default: true, status: "active" },
    ]);
    fake.seed("backoffice.bo_product_login_methods", [
      { id: "lm1", product_id: "src", environment: "staging", type: "google", enabled: true, is_default: false, display_order: 10, config: { app_id: "g-1" } },
      { id: "lm2", product_id: "src", environment: "production", type: "msisdn_pin", enabled: true, is_default: true, display_order: 0, config: {} },
    ]);
    fake.seed("backoffice.bo_product_translations", [
      { product_locale_id: "loc-src", environment: "staging", namespace: "itTestHomeScreen", key: "title", value: "Ciao" },
    ]);
    fake.seed("backoffice.bo_page_behaviour_rules", [
      { id: "pr", product_id: "src", environment: "staging", path: "/p", label: null, position: 0, enabled: true, screen_slug: null },
      { id: "lr", product_locale_id: "loc-src", environment: "staging", path: "/l", label: null, position: 0, enabled: true, screen_slug: null },
    ]);
    fake.seed("backoffice.bo_app_screens", [
      { id: "scr", product_id: "src", environment: "staging", slug: "home", name: "Home", enabled: true },
    ]);
    fake.seed("backoffice.bo_app_screen_sections", [{
      id: "sec", screen_id: "scr", platform: "mobile", widget_type: "placeholder_text", title: "t", show_title: true, enabled: true,
      position: 0, col_span: 12, start_at_local: null, end_at_local: null, visible_to: ["premium"],
      config: { i18n: { title: { namespace: "itTestHomeScreen", key: "title", owned: true } } },
    }]);

    const res = await handler(post("clone-product", body, auth));
    assertEquals(res.status, 200);
    const out = await readJson(res);
    assertEquals(out.ok, true);
    assertEquals(out.locales_cloned, 1);
    assertEquals(out.app_screens_cloned, 1);

    const product = fake.rows("backoffice.bo_products").find((p) => p.slug === "fr-test")!;
    assertEquals([product.country_code, product.service_id, product.timezone], ["FR", "svc", "Europe/Rome"]);

    const methods = fake.rows("backoffice.bo_product_login_methods").filter((m) => m.product_id === product.id);
    assertEquals(methods.map((m) => [m.environment, m.type, (m.config as Record<string, unknown>).app_id]), [
      ["staging", "google", "g-1"],
      ["production", "msisdn_pin", undefined],
    ]);

    const locale = fake.rows("backoffice.bo_product_locales").find((l) => l.product_id === product.id)!;
    const rules = fake.rows("backoffice.bo_page_behaviour_rules");
    assertEquals(rules.filter((r) => r.product_id === product.id).map((r) => r.path), ["/p"]);
    assertEquals(rules.filter((r) => r.product_locale_id === locale.id).map((r) => r.path), ["/l"]);

    const screen = fake.rows("backoffice.bo_app_screens").find((s) => s.product_id === product.id)!;
    const [section] = fake.rows("backoffice.bo_app_screen_sections").filter((s) => s.screen_id === screen.id);
    assertEquals(section.visible_to, ["premium"]);
    const i18n = (section.config as { i18n: { title: { namespace: string } } }).i18n;
    assertEquals(i18n.title.namespace, "frTestHomeScreen");
    const texts = fake.rows("backoffice.bo_product_translations").filter((t) => t.product_locale_id === locale.id);
    assertEquals(texts.map((t) => [t.namespace, t.key, t.value]), [["frTestHomeScreen", "title", "Ciao"]]);
  });
});
