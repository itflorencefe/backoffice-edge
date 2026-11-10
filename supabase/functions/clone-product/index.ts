import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { clonePageBehaviour } from "../_shared/page-behaviour-clone.ts";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey"
};
function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    }
  });
}
function rejectAppUser(req) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return null;
  const parts = auth.slice(7).trim().split(".");
  if (parts.length !== 3) return null;
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padding = padded.length % 4 === 0 ? "" : "=".repeat(4 - padded.length % 4);
    const payload = JSON.parse(atob(padded + padding));
    if (payload?.app_role === "app_user") {
      return jsonResponse({
        ok: false,
        error: "App users are not authorized for this endpoint"
      }, 403);
    }
  } catch  {
  // ignore
  }
  return null;
}

type NamespacePair = { from: string; to: string };
type SlugRename = { from: string; to: string };

function camel(...parts: string[]): string {
  const words = parts.join("-").split(/[^a-zA-Z0-9]+/).filter(Boolean).map((w) => w.toLowerCase());
  return words.map((w, i) => (i === 0 ? w : w[0].toUpperCase() + w.slice(1))).join("");
}

const screenNamespace = (productSlug: string, screenSlug: string) => `${camel(productSlug, screenSlug)}Screen`;

function renameNamespace(config: Record<string, unknown>, pair: NamespacePair) {
  const remap = (i18n: unknown) => {
    const refs = (i18n && typeof i18n === "object" ? i18n : {}) as Record<string, Record<string, unknown>>;
    const out: Record<string, unknown> = {};
    for (const [field, ref] of Object.entries(refs)) {
      out[field] = ref?.owned === true && ref.namespace === pair.from ? { ...ref, namespace: pair.to } : ref;
    }
    return out;
  };
  const next: Record<string, unknown> = { ...config, i18n: remap(config.i18n) };
  if (Array.isArray(config.slides)) {
    next.slides = config.slides.map((s: Record<string, unknown>) => ({ ...s, i18n: remap(s?.i18n) }));
  }
  return next;
}

const MENU_ITEM_COLUMNS = "id, environment, item_key, label, url, icon, icon_url, display_order, parent_key, visible, enabled, label_i18n_key, route, external_url, auth_required, min_app_version, max_app_version, feature_flag, badge_text, badge_i18n_key, badge_color, screen_slug";
const MENU_TIER_COLUMNS = "tier, visible, enabled, locked_action, route, external_url, label, label_i18n_key, badge_text, badge_i18n_key, badge_color, display_order, screen_slug";

const menuNamespace = (productSlug: string) => `${camel(productSlug)}MenuItems`;

// Menu rows store text refs as "namespace.key"; refs in the source product's namespace move to the clone's.
function renameMenuRefs<T extends Record<string, unknown>>(row: T, pair: NamespacePair): T {
  const out: Record<string, unknown> = { ...row };
  for (const col of ["label_i18n_key", "badge_i18n_key"]) {
    const ref = row[col];
    if (typeof ref === "string" && ref.startsWith(`${pair.from}.`)) out[col] = `${pair.to}${ref.slice(pair.from.length)}`;
  }
  return out as T;
}

// Copies the menu items owned by one level (with their per-tier rules) onto the cloned owner.
// Rows materialised from the starter menu levels (source_item_id set) are skipped: the
// bo_products / bo_product_locales seed triggers recreate them for the clone.
async function cloneMenuItems(
  // deno-lint-ignore no-explicit-any
  admin: any,
  column: "product_id" | "product_locale_id",
  sourceId: string,
  targetId: string,
  pair: NamespacePair,
): Promise<number> {
  try {
    const { data: items, error } = await admin.schema("backoffice").from("bo_product_menu_items").select(MENU_ITEM_COLUMNS).eq(column, sourceId).is("source_item_id", null);
    if (error || !items) {
      if (error) console.error("[error] clone-product: menu items read failed", error.message);
      return 0;
    }
    let cloned = 0;
    for (const item of items) {
      const { id: srcId, ...fields } = item;
      const { data: newItem, error: insErr } = await admin.schema("backoffice")
        .from("bo_product_menu_items")
        .insert({ ...renameMenuRefs(fields, pair), [column]: targetId })
        .select("id")
        .single();
      if (insErr || !newItem) {
        console.warn("[warning] clone-product: menu item copy skipped", item.item_key, insErr?.message);
        continue;
      }
      const { data: tiers } = await admin.schema("backoffice").from("bo_product_menu_item_tiers").select(MENU_TIER_COLUMNS).eq("menu_item_id", srcId);
      if (tiers && tiers.length > 0) {
        const { error: tierErr } = await admin.schema("backoffice").from("bo_product_menu_item_tiers")
          .insert(tiers.map((t: Record<string, unknown>) => ({ ...renameMenuRefs(t, pair), menu_item_id: newItem.id })));
        if (tierErr) console.error("[error] clone-product: menu item tiers copy failed", item.item_key, tierErr.message);
      }
      cloned++;
    }
    return cloned;
  } catch (err) {
    console.error("[error] clone-product: menu items clone failed", err instanceof Error ? err.message : String(err));
    return 0;
  }
}

async function cloneAppScreens(
  // deno-lint-ignore no-explicit-any
  admin: any,
  column: "product_id" | "product_locale_id",
  sourceId: string,
  targetId: string,
  rename: SlugRename,
): Promise<{ cloned: number; pairs: NamespacePair[] }> {
  const pairs: NamespacePair[] = [];
  try {
    const { data: screens, error } = await admin
      .schema("backoffice").from("bo_app_screens")
      .select("id, environment, slug, name, enabled")
      .eq(column, sourceId);
    if (error || !screens) return { cloned: 0, pairs };

    let cloned = 0;
    for (const s of screens) {
      const { data: newScreen, error: insErr } = await admin
        .schema("backoffice").from("bo_app_screens")
        .insert({ [column]: targetId, environment: s.environment, slug: s.slug, name: s.name, enabled: s.enabled })
        .select("id")
        .single();
      if (insErr || !newScreen) continue;

      const { data: sections } = await admin
        .schema("backoffice").from("bo_app_screen_sections")
        .select("platform, widget_type, title, show_title, enabled, position, col_span, config, start_at_local, end_at_local, visible_to")
        .eq("screen_id", s.id);

      if (sections && sections.length > 0) {
        const pair = { from: screenNamespace(rename.from, s.slug), to: screenNamespace(rename.to, s.slug) };
        const rows = sections.map((sec: Record<string, unknown>) => ({
          ...sec,
          id: crypto.randomUUID(),
          config: renameNamespace((sec.config ?? {}) as Record<string, unknown>, pair),
          screen_id: newScreen.id,
        }));
        const { error: secErr } = await admin.schema("backoffice").from("bo_app_screen_sections").insert(rows);
        if (secErr) {
          await admin.schema("backoffice").from("bo_app_screens").delete().eq("id", newScreen.id);
          continue;
        }
        pairs.push(pair);
      }
      cloned++;
    }
    return { cloned, pairs };
  } catch {
    return { cloned: 0, pairs };
  }
}

async function copyRekeyedTexts(
  // deno-lint-ignore no-explicit-any
  admin: any,
  serviceId: string,
  newLocaleIds: string[],
  allPairs: NamespacePair[],
) {
  const pairs = [...new Map(allPairs.filter((p) => p.from !== p.to).map((p) => [p.from, p])).values()];
  for (const p of pairs) {
    const { data: svcRows } = await admin
      .schema("backoffice").from("bo_service_translations_defaults")
      .select("environment, language_code, key, value")
      .eq("service_id", serviceId)
      .eq("namespace", p.from);
    if (svcRows && svcRows.length > 0) {
      await admin.schema("backoffice").from("bo_service_translations_defaults").upsert(
        svcRows.map((r: Record<string, string>) => ({ ...r, service_id: serviceId, namespace: p.to })),
        { onConflict: "service_id,environment,language_code,namespace,key", ignoreDuplicates: true },
      );
    }
    if (newLocaleIds.length > 0) {
      await admin.schema("backoffice").from("bo_product_translations")
        .update({ namespace: p.to })
        .in("product_locale_id", newLocaleIds)
        .eq("namespace", p.from);
    }
  }
}

Deno.serve(async (req)=>{
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 200,
        headers: corsHeaders
      });
    }
    const blocked = rejectAppUser(req);
    if (blocked) return blocked;
    if (req.method !== "POST") {
      return jsonResponse({
        ok: false,
        error: "Method not allowed"
      }, 405);
    }
    // Verify auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({
        ok: false,
        error: "Unauthorized"
      }, 401);
    }
    const supabaseAdmin = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // Verify the user's JWT
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
    if (authErr || !user) {
      return jsonResponse({
        ok: false,
        error: "Unauthorized"
      }, 401);
    }
    // Check that the user is at least an editor
    const { data: boUser } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").select("role").eq("user_id", user.id).eq("is_active", true).maybeSingle();
    if (!boUser || boUser.role !== "editor" && boUser.role !== "admin") {
      return jsonResponse({
        ok: false,
        error: "Insufficient permissions"
      }, 403);
    }
    const body = await req.json();
    const { source_product_id, new_slug, new_display_name, new_country_code } = body;
    if (!source_product_id || !new_slug || !new_display_name || !new_country_code) {
      return jsonResponse({
        ok: false,
        error: "source_product_id, new_slug, new_display_name, and new_country_code are required"
      }, 400);
    }
    // 1. Fetch source product
    const { data: source, error: srcErr } = await supabaseAdmin.schema("backoffice").from("bo_products").select("*").eq("id", source_product_id).maybeSingle();
    if (srcErr) return jsonResponse({
      ok: false,
      error: srcErr.message
    }, 500);
    if (!source) return jsonResponse({
      ok: false,
      error: "Source product not found"
    }, 404);
    // 2. Create new product (copy timezone so schedules keep the same zone)
    const { data: newProduct, error: newProdErr } = await supabaseAdmin.schema("backoffice").from("bo_products").insert({
      service_id: source.service_id,
      slug: new_slug,
      display_name: new_display_name,
      country_code: new_country_code.toUpperCase(),
      is_global: false,
      native_bundle_id: source.native_bundle_id,
      hostname_staging: null,
      hostname_production: null,
      status: "active",
      timezone: source.timezone ?? null
    }).select().single();
    if (newProdErr) return jsonResponse({
      ok: false,
      error: newProdErr.message
    }, 500);
    // Clone login methods (product level, both environments). New products start with no login
    // method; the delete only clears rows seeded by an older trigger, and runs only once the
    // source rows were read (a failure keeps them and is logged).
    const { data: loginMethods, error: loginReadErr } = await supabaseAdmin.schema("backoffice").from("bo_product_login_methods").select("environment, type, enabled, is_default, display_order, label_i18n_key, icon, feature_flag, min_app_version, max_app_version, config, updated_by").eq("product_id", source_product_id);
    if (loginReadErr) {
      console.error("[error] clone-product: login methods read failed", loginReadErr.message);
    } else if (loginMethods && loginMethods.length > 0) {
      const { error: loginDelErr } = await supabaseAdmin.schema("backoffice").from("bo_product_login_methods").delete().eq("product_id", newProduct.id);
      if (loginDelErr) {
        console.error("[error] clone-product: clearing seeded login methods failed", loginDelErr.message);
      } else {
        const { error: loginWriteErr } = await supabaseAdmin.schema("backoffice").from("bo_product_login_methods").insert(loginMethods.map((m)=>({
            ...m,
            product_id: newProduct.id
          })));
        if (loginWriteErr) console.error("[error] clone-product: login methods copy failed", loginWriteErr.message);
      }
    }
    // Signup settings (product level, both environments)
    const { data: signupRows, error: signupReadErr } = await supabaseAdmin.schema("backoffice").from("bo_product_signup_settings").select("environment, enabled, signup_url").eq("product_id", source_product_id);
    if (signupReadErr) {
      console.error("[error] clone-product: signup settings read failed", signupReadErr.message);
    } else if (signupRows && signupRows.length > 0) {
      const { error: signupWriteErr } = await supabaseAdmin.schema("backoffice").from("bo_product_signup_settings").upsert(signupRows.map((s)=>({
          ...s,
          product_id: newProduct.id,
          updated_by: user.id
        })), { onConflict: "product_id,environment" });
      if (signupWriteErr) console.error("[error] clone-product: signup settings copy failed", signupWriteErr.message);
    }
    // Product-level assets keep the source file URLs (files are shared, not copied).
    const { data: productAssets, error: productAssetsReadErr } = await supabaseAdmin.schema("backoffice").from("bo_product_level_assets").select("environment, asset_key, url, mime_type, metadata").eq("product_id", source_product_id);
    if (productAssetsReadErr) {
      console.error("[error] clone-product: product assets read failed", productAssetsReadErr.message);
    } else if (productAssets && productAssets.length > 0) {
      const { error: productAssetsWriteErr } = await supabaseAdmin.schema("backoffice").from("bo_product_level_assets").insert(productAssets.map((a)=>({
          ...a,
          product_id: newProduct.id
        })));
      if (productAssetsWriteErr) console.error("[error] clone-product: product assets copy failed", productAssetsWriteErr.message);
    }
    // URL & Behaviour rules of the product (locale rules are copied with each locale)
    await clonePageBehaviour(supabaseAdmin, "product_id", source_product_id, newProduct.id);
    // 3. Fetch source locales
    const { data: sourceLocales } = await supabaseAdmin
      .schema("backoffice").from("bo_product_locales")
      .select("*")
      .eq("product_id", source_product_id);

    const slugRename = { from: source.slug || "product", to: newProduct.slug || "product" };
    const productScreens = await cloneAppScreens(supabaseAdmin, "product_id", source_product_id, newProduct.id, slugRename);
    let appScreensCloned = productScreens.cloned;
    const menuPair = { from: menuNamespace(slugRename.from), to: menuNamespace(slugRename.to) };
    let menuItemsCloned = await cloneMenuItems(supabaseAdmin, "product_id", source_product_id, newProduct.id, menuPair);
    const textPairs = [...productScreens.pairs, menuPair];
    const newLocaleIds: string[] = [];

    if (!sourceLocales || sourceLocales.length === 0) {
      await copyRekeyedTexts(supabaseAdmin, newProduct.service_id, [], textPairs);
      return jsonResponse({
        ok: true,
        product: newProduct,
        locales_cloned: 0,
        app_screens_cloned: appScreensCloned,
        menu_items_cloned: menuItemsCloned,
        message: "Product cloned (no locales to copy)",
      });
    }
    // 4. Clone each locale and its data
    let localesCloned = 0;
    for (const srcLocale of sourceLocales){
      // Create new locale
      const { data: newLocale, error: locErr } = await supabaseAdmin.schema("backoffice").from("bo_product_locales").insert({
        product_id: newProduct.id,
        language_code: srcLocale.language_code,
        display_name: srcLocale.display_name,
        is_default: srcLocale.is_default,
        status: srcLocale.status
      }).select().single();
      if (locErr || !newLocale) continue;
      // Clone branding (both environments)
      const { data: brandings } = await supabaseAdmin.schema("backoffice").from("bo_product_branding").select("environment, colors, gradients, fonts, radius, spacing, font_sizes, font_weights, shadows").eq("product_locale_id", srcLocale.id);
      if (brandings && brandings.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_branding").insert(brandings.map((b)=>({
            ...b,
            product_locale_id: newLocale.id
          })));
      }
      // Clone assets
      const { data: assets } = await supabaseAdmin.schema("backoffice").from("bo_product_assets").select("environment, asset_key, url, mime_type, width, height, metadata").eq("product_locale_id", srcLocale.id);
      if (assets && assets.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_assets").insert(assets.map((a)=>({
            ...a,
            product_locale_id: newLocale.id
          })));
      }
      // Clone translations
      const { data: translations } = await supabaseAdmin.schema("backoffice").from("bo_product_translations").select("environment, namespace, key, value").eq("product_locale_id", srcLocale.id);
      if (translations && translations.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_translations").insert(translations.map((t)=>({
            ...t,
            product_locale_id: newLocale.id
          })));
      }
      // Clone public config
      const { data: configs } = await supabaseAdmin.schema("backoffice").from("bo_product_public_config").select("environment, key, value, description").eq("product_locale_id", srcLocale.id);
      if (configs && configs.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_public_config").insert(configs.map((c)=>({
            ...c,
            product_locale_id: newLocale.id
          })));
      }
      // Clone feature flags
      const { data: flags } = await supabaseAdmin.schema("backoffice").from("bo_product_feature_flags").select("environment, flag_key, enabled, description").eq("product_locale_id", srcLocale.id);
      if (flags && flags.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_feature_flags").insert(flags.map((f)=>({
            ...f,
            product_locale_id: newLocale.id
          })));
      }
      await clonePageBehaviour(supabaseAdmin, "product_locale_id", srcLocale.id, newLocale.id);
      menuItemsCloned += await cloneMenuItems(supabaseAdmin, "product_locale_id", srcLocale.id, newLocale.id, menuPair);
      // Clone footer items
      const { data: footerItems } = await supabaseAdmin.schema("backoffice").from("bo_product_footer_items").select("environment, item_key, label, url, icon, display_order, item_group, visible").eq("product_locale_id", srcLocale.id);
      if (footerItems && footerItems.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_footer_items").insert(footerItems.map((m)=>({
            ...m,
            product_locale_id: newLocale.id
          })));
      }

      const localeScreens = await cloneAppScreens(supabaseAdmin, "product_locale_id", srcLocale.id, newLocale.id, slugRename);
      appScreensCloned += localeScreens.cloned;
      textPairs.push(...localeScreens.pairs);
      newLocaleIds.push(newLocale.id);

      localesCloned++;
    }

    await copyRekeyedTexts(supabaseAdmin, newProduct.service_id, newLocaleIds, textPairs);

    // Clone content consumption rules (product-level)
    const { data: consumptionRules } = await supabaseAdmin.schema("backoffice").from("bo_product_content_consumption_rules").select("environment, content_type, tier, action, rate_limit_enabled, tries_limit, frequency_period, frequency_unit_count, on_limit_reached_action").eq("product_id", source_product_id);
    if (consumptionRules && consumptionRules.length > 0) {
      await supabaseAdmin.schema("backoffice").from("bo_product_content_consumption_rules").insert(consumptionRules.map((r)=>({
          ...r,
          product_id: newProduct.id
        })));
    }
    // Clone unsubscribe methods (product-level)
    const { data: unsubMethods } = await supabaseAdmin.schema("backoffice").from("bo_product_unsubscribe_methods").select("environment, method, external_url, external_link_label, external_link_target, avoided_reason_i18n_key, config").eq("product_id", source_product_id);
    if (unsubMethods && unsubMethods.length > 0) {
      await supabaseAdmin.schema("backoffice").from("bo_product_unsubscribe_methods").insert(unsubMethods.map((m)=>({
          ...m,
          product_id: newProduct.id
        })));
    }
    return jsonResponse({
      ok: true,
      product: newProduct,
      locales_cloned: localesCloned,
      app_screens_cloned: appScreensCloned,
      menu_items_cloned: menuItemsCloned,
      message: `Product cloned successfully with ${localesCloned} locale(s). Secrets were NOT copied for security reasons.`,
    });
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: err instanceof Error ? err.message : "Internal error"
    }, 500);
  }
});
