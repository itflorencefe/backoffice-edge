import { assertEquals } from "@std/assert";
import { type FakeSupabase, loadFunction, post, readJson, withFake } from "./harness.ts";

const handler = await loadFunction("clone-service");

const TOKEN = "editor-token";
const auth = { Authorization: `Bearer ${TOKEN}` };
const body = { source_service_id: "svc", new_slug: "copy", new_display_name: "Copy" };

function seedEditor(fake: FakeSupabase, role = "editor") {
  fake.addAuthUser({ id: "user-1", email: "editor@example.com", token: TOKEN });
  fake.seed("backoffice.backoffice_users", [{ id: "bo-1", user_id: "user-1", role, is_active: true }]);
}

Deno.test("clone-service: access control and unknown source", async () => {
  await withFake(async (fake) => {
    const noAuth = await handler(new Request("http://edge.test/clone-service", { method: "POST", body: "{}" }));
    assertEquals(noAuth.status, 401);
    await noAuth.body?.cancel();
    seedEditor(fake, "viewer");
    const viewer = await handler(post("clone-service", body, auth));
    assertEquals(viewer.status, 403);
    await viewer.body?.cancel();
    seedEditor(fake);
    const unknown = await handler(post("clone-service", body, auth));
    assertEquals(unknown.status, 404);
    await unknown.body?.cancel();
  });
});

Deno.test("clone-service: copies service defaults, products, locales, login, signup, assets and menus", async () => {
  await withFake(async (fake) => {
    seedEditor(fake);
    const env = { environment: "staging" };
    fake.seed("backoffice.services", [{ id: "svc", slug: "svc", display_name: "Svc", description: "d", status: "active", global_product_id: null }]);
    fake.seed("backoffice.service_branding_defaults", [{ service_id: "svc", ...env, colors: { primary: "#000" } }]);
    fake.seed("backoffice.service_translations_defaults", [{ service_id: "svc", ...env, language_code: "it", namespace: "menuItems", key: "homeText", value: "Home" }]);
    fake.seed("backoffice.service_footer_items_defaults", [{ service_id: "svc", ...env, item_key: "tos", label: "ToS" }]);
    fake.seed("backoffice.products", [{ id: "p1", service_id: "svc", slug: "it", display_name: "IT", country_code: "IT", is_global: false, native_bundle_id: null, status: "active" }]);
    fake.seed("backoffice.product_locales", [{ id: "l1", product_id: "p1", language_code: "it", display_name: "Italiano", is_default: true, status: "active" }]);
    fake.seed("backoffice.product_login_methods", [{ product_id: "p1", ...env, type: "msisdn", enabled: true, is_default: true, display_order: 0, config: { mode: "otp" } }]);
    fake.seed("backoffice.product_signup_settings", [{ product_id: "p1", ...env, enabled: false, signup_url: null }]);
    fake.seed("backoffice.product_level_assets", [{ product_id: "p1", ...env, asset_key: "logo", url: "u", mime_type: "", metadata: {} }]);
    fake.seed("backoffice.product_branding", [{ product_locale_id: "l1", ...env, colors: { primary: "#fff" } }]);
    fake.seed("backoffice.product_translations", [{ product_locale_id: "l1", ...env, namespace: "common", key: "hi", value: "Ciao" }]);
    fake.seed("backoffice.product_menu_items", [
      { id: "ms", service_id: "svc", ...env, item_key: "home", label: "Home", label_i18n_key: "menuItems.homeText", source_item_id: null },
      { id: "mp", product_id: "p1", ...env, item_key: "vip", label: "VIP", source_item_id: null },
      { id: "ml", product_locale_id: "l1", ...env, item_key: "help", label: "Help", source_item_id: null },
      { id: "seeded", product_locale_id: "l1", ...env, item_key: "x", label: "X", source_item_id: "lvl" },
    ]);

    const res = await handler(post("clone-service", body, auth));
    assertEquals(res.status, 200);
    const out = await readJson(res);
    assertEquals([out.products_cloned, out.locales_cloned, out.menu_items_cloned], [1, 1, 3]);

    const svc = fake.rows("backoffice.services").find((s) => s.slug === "copy")!;
    const product = fake.rows("backoffice.products").find((p) => p.service_id === svc.id)!;
    const locale = fake.rows("backoffice.product_locales").find((l) => l.product_id === product.id)!;
    const owned = (table: string, column: string, id: unknown) => fake.rows(table).filter((r) => r[column] === id);

    assertEquals(owned("backoffice.service_branding_defaults", "service_id", svc.id).length, 1);
    assertEquals(owned("backoffice.service_translations_defaults", "service_id", svc.id).map((t) => t.key), ["homeText"]);
    assertEquals(owned("backoffice.service_footer_items_defaults", "service_id", svc.id).map((t) => t.item_key), ["tos"]);
    assertEquals(owned("backoffice.product_login_methods", "product_id", product.id).map((m) => [m.type, (m.config as { mode: string }).mode]), [["msisdn", "otp"]]);
    assertEquals(owned("backoffice.product_signup_settings", "product_id", product.id).length, 1);
    assertEquals(owned("backoffice.product_level_assets", "product_id", product.id).map((a) => a.asset_key), ["logo"]);
    assertEquals(owned("backoffice.product_branding", "product_locale_id", locale.id).length, 1);
    assertEquals(owned("backoffice.product_translations", "product_locale_id", locale.id).map((t) => t.key), ["hi"]);
    assertEquals(owned("backoffice.product_menu_items", "service_id", svc.id).map((m) => m.label_i18n_key), ["menuItems.homeText"]);
    assertEquals(owned("backoffice.product_menu_items", "product_id", product.id).map((m) => m.item_key), ["vip"]);
    assertEquals(owned("backoffice.product_menu_items", "product_locale_id", locale.id).map((m) => m.item_key), ["help"]);
  });
});

Deno.test("clone-service: works on a BBM-schema database (no starter menu levels, no footer document links)", async () => {
  await withFake(async (fake) => {
    seedEditor(fake);
    const env = { environment: "staging" };
    fake.dropColumns("backoffice.product_menu_items", ["source_item_id", "menu_id", "item_type", "document_slug", "nested_menu_key"]);
    fake.dropColumns("backoffice.product_footer_items", ["link_type", "document_slug"]);
    fake.seed("backoffice.services", [{ id: "svc", slug: "svc", display_name: "Svc", description: "d", status: "active", global_product_id: null }]);
    fake.seed("backoffice.products", [{ id: "p1", service_id: "svc", slug: "it", display_name: "IT", country_code: "IT", is_global: false, native_bundle_id: null, status: "active" }]);
    fake.seed("backoffice.product_locales", [{ id: "l1", product_id: "p1", language_code: "it", display_name: "Italiano", is_default: true, status: "active" }]);
    fake.seed("backoffice.product_footer_items", [{ product_locale_id: "l1", ...env, item_key: "tos", label: "ToS", url: "/tos", icon: "", display_order: 0, item_group: "", visible: true }]);
    fake.seed("backoffice.product_menu_items", [
      { id: "ms", service_id: "svc", ...env, item_key: "home", label: "Home" },
      { id: "ml", product_locale_id: "l1", ...env, item_key: "help", label: "Help" },
    ]);

    const res = await handler(post("clone-service", body, auth));
    assertEquals(res.status, 200);
    const out = await readJson(res);
    assertEquals(out.menu_items_cloned, 2);

    const svc = fake.rows("backoffice.services").find((s) => s.slug === "copy")!;
    const product = fake.rows("backoffice.products").find((p) => p.service_id === svc.id)!;
    const locale = fake.rows("backoffice.product_locales").find((l) => l.product_id === product.id)!;
    const owned = (table: string, column: string, id: unknown) => fake.rows(table).filter((r) => r[column] === id);
    assertEquals(owned("backoffice.product_menu_items", "service_id", svc.id).map((m) => m.item_key), ["home"]);
    assertEquals(owned("backoffice.product_menu_items", "product_locale_id", locale.id).map((m) => m.item_key), ["help"]);
    assertEquals(owned("backoffice.product_footer_items", "product_locale_id", locale.id).map((f) => f.item_key), ["tos"]);
  });
});
