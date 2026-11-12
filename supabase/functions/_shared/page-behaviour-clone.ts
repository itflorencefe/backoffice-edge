import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type OwnerColumn = "service_id" | "product_id" | "product_locale_id";

/**
 * Copies the URL & Behaviour rules of one owner (both environments) and their tier rows
 * to another owner of the same level. Returns the number of rules copied.
 */
export async function clonePageBehaviour(
  client: SupabaseClient,
  column: OwnerColumn,
  sourceId: string,
  targetId: string,
): Promise<number> {
  const db = client.schema("backoffice");
  const { data: rules } = await db
    .from("page_behaviour_rules")
    .select("id, environment, path, label, position, enabled, screen_slug")
    .eq(column, sourceId);
  if (!rules || rules.length === 0) return 0;

  const { data: tiers } = await db
    .from("page_behaviour_tier_rules")
    .select("rule_id, tier, action, redirect_url, screen_slug, reason")
    .in("rule_id", rules.map((r) => r.id));

  let copied = 0;
  for (const { id, ...rule } of rules) {
    const { data: newRule, error } = await db
      .from("page_behaviour_rules")
      .insert({ ...rule, [column]: targetId })
      .select("id")
      .single();
    if (error || !newRule) continue;
    const ruleTiers = (tiers || []).filter((t) => t.rule_id === id);
    if (ruleTiers.length > 0) {
      await db.from("page_behaviour_tier_rules").insert(
        ruleTiers.map(({ rule_id: _ruleId, ...t }) => ({ ...t, rule_id: newRule.id })),
      );
    }
    copied++;
  }
  return copied;
}
