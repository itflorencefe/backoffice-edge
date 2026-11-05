import { assertEquals } from "@std/assert";
import { createClient } from "npm:@supabase/supabase-js@2";
import { clonePageBehaviour } from "../functions/_shared/page-behaviour-clone.ts";
import { SERVICE_ROLE_KEY, SUPABASE_URL, withFake } from "./harness.ts";

const client = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

Deno.test("clonePageBehaviour: copies rules of both environments with their tiers", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_page_behaviour_rules", [
      { id: "r1", product_id: "src", environment: "staging", path: "/games", label: "Games", position: 1, enabled: true, screen_slug: null },
      { id: "r2", product_id: "src", environment: "production", path: "/vip", label: null, position: 2, enabled: false, screen_slug: "vip" },
      { id: "r3", product_id: "other", environment: "staging", path: "/other", label: null, position: 0, enabled: true, screen_slug: null },
    ]);
    fake.seed("backoffice.bo_page_behaviour_tier_rules", [
      { id: "t1", rule_id: "r1", tier: "guest", action: "redirect", redirect_url: "/login", screen_slug: null, reason: "login" },
      { id: "t2", rule_id: "r1", tier: "free", action: "screen", redirect_url: null, screen_slug: "upsell", reason: null },
      { id: "t3", rule_id: "r3", tier: "guest", action: "redirect", redirect_url: "/x", screen_slug: null, reason: null },
    ]);

    const copied = await clonePageBehaviour(client(), "product_id", "src", "dst");
    assertEquals(copied, 2);

    const rules = fake.rows("backoffice.bo_page_behaviour_rules").filter((r) => r.product_id === "dst");
    assertEquals(
      rules.map((r) => [r.environment, r.path, r.label, r.position, r.enabled, r.screen_slug]),
      [["staging", "/games", "Games", 1, true, null], ["production", "/vip", null, 2, false, "vip"]],
    );
    const games = rules.find((r) => r.path === "/games")!;
    const tiers = fake.rows("backoffice.bo_page_behaviour_tier_rules").filter((t) => t.rule_id === games.id);
    assertEquals(
      tiers.map((t) => [t.tier, t.action, t.redirect_url, t.screen_slug, t.reason]),
      [["guest", "redirect", "/login", null, "login"], ["free", "screen", null, "upsell", null]],
    );
    assertEquals(fake.rows("backoffice.bo_page_behaviour_tier_rules").length, 5);
  });
});

Deno.test("clonePageBehaviour: nothing to copy returns 0 without writes", async () => {
  await withFake(async (fake) => {
    assertEquals(await clonePageBehaviour(client(), "service_id", "src", "dst"), 0);
    assertEquals(fake.requests.filter((r) => r.method !== "GET").length, 0);
  });
});

Deno.test("clonePageBehaviour: a rule that fails to insert is skipped", async () => {
  await withFake(async (fake) => {
    fake.seed("backoffice.bo_page_behaviour_rules", [
      { id: "r1", product_locale_id: "src", environment: "staging", path: "/a", label: null, position: 0, enabled: true, screen_slug: null },
    ]);
    fake.fail("backoffice.bo_page_behaviour_rules", "POST");
    assertEquals(await clonePageBehaviour(client(), "product_locale_id", "src", "dst"), 0);
  });
});
