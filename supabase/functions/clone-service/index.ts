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
const MENU_ITEM_COLUMNS = "id, environment, item_key, label, url, icon, icon_url, display_order, parent_key, visible, enabled, label_i18n_key, route, external_url, auth_required, min_app_version, max_app_version, feature_flag, badge_text, badge_i18n_key, badge_color, screen_slug";
const MENU_TIER_COLUMNS = "tier, visible, enabled, locked_action, route, external_url, label, label_i18n_key, badge_text, badge_i18n_key, badge_color, display_order, screen_slug";

// Copies the menu items owned by one level (with their per-tier rules) onto the cloned owner.
// Rows materialised from the starter menu levels (source_item_id set) are skipped: the
// bo_products / bo_product_locales seed triggers recreate them for the clone.
async function cloneMenuItems(
  // deno-lint-ignore no-explicit-any
  admin: any,
  column: "service_id" | "product_id" | "product_locale_id",
  sourceId: string,
  targetId: string,
): Promise<number> {
  try {
    const { data: items, error } = await admin.schema("backoffice").from("bo_product_menu_items").select(MENU_ITEM_COLUMNS).eq(column, sourceId).is("source_item_id", null);
    if (error || !items) {
      if (error) console.error("[error] clone-service: menu items read failed", error.message);
      return 0;
    }
    let cloned = 0;
    for (const item of items) {
      const { id: srcId, ...fields } = item;
      const { data: newItem, error: insErr } = await admin.schema("backoffice")
        .from("bo_product_menu_items")
        .insert({ ...fields, [column]: targetId })
        .select("id")
        .single();
      if (insErr || !newItem) {
        console.warn("[warning] clone-service: menu item copy skipped", item.item_key, insErr?.message);
        continue;
      }
      const { data: tiers } = await admin.schema("backoffice").from("bo_product_menu_item_tiers").select(MENU_TIER_COLUMNS).eq("menu_item_id", srcId);
      if (tiers && tiers.length > 0) {
        const { error: tierErr } = await admin.schema("backoffice").from("bo_product_menu_item_tiers")
          .insert(tiers.map((t: Record<string, unknown>) => ({ ...t, menu_item_id: newItem.id })));
        if (tierErr) console.error("[error] clone-service: menu item tiers copy failed", item.item_key, tierErr.message);
      }
      cloned++;
    }
    return cloned;
  } catch (err) {
    console.error("[error] clone-service: menu items clone failed", err instanceof Error ? err.message : String(err));
    return 0;
  }
}

// Copies the rows of one table owned by `column = sourceId` onto `targetId`; failures are logged.
async function copyRows(
  // deno-lint-ignore no-explicit-any
  admin: any,
  table: string,
  columns: string,
  column: "service_id" | "product_id" | "product_locale_id",
  sourceId: string,
  targetId: string,
): Promise<void> {
  const { data: rows, error: readErr } = await admin.schema("backoffice").from(table).select(columns).eq(column, sourceId);
  if (readErr) {
    console.error(`[error] clone-service: ${table} read failed`, readErr.message);
    return;
  }
  if (!rows || rows.length === 0) return;
  const { error: writeErr } = await admin.schema("backoffice").from(table)
    .insert(rows.map((r: Record<string, unknown>) => ({ ...r, [column]: targetId })));
  if (writeErr) console.error(`[error] clone-service: ${table} copy failed`, writeErr.message);
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
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({
        ok: false,
        error: "Unauthorized"
      }, 401);
    }
    const supabaseAdmin = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
    if (authErr || !user) {
      return jsonResponse({
        ok: false,
        error: "Unauthorized"
      }, 401);
    }
    const { data: boUser } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").select("role").eq("user_id", user.id).eq("is_active", true).maybeSingle();
    if (!boUser || boUser.role !== "editor" && boUser.role !== "admin") {
      return jsonResponse({
        ok: false,
        error: "Insufficient permissions"
      }, 403);
    }
    const body = await req.json();
    const { source_service_id, new_slug, new_display_name } = body;
    if (!source_service_id || !new_slug || !new_display_name) {
      return jsonResponse({
        ok: false,
        error: "source_service_id, new_slug, and new_display_name are required"
      }, 400);
    }
    // 1. Fetch source service
    const { data: source, error: srcErr } = await supabaseAdmin.schema("backoffice").from("bo_services").select("*").eq("id", source_service_id).eq("status", "active").maybeSingle();
    if (srcErr) return jsonResponse({
      ok: false,
      error: srcErr.message
    }, 500);
    if (!source) return jsonResponse({
      ok: false,
      error: "Source service not found or not active"
    }, 404);
    // 2. Create new service
    const { data: newService, error: newSvcErr } = await supabaseAdmin.schema("backoffice").from("bo_services").insert({
      slug: new_slug,
      display_name: new_display_name,
      description: source.description,
      status: "active"
    }).select().single();
    if (newSvcErr) return jsonResponse({
      ok: false,
      error: newSvcErr.message
    }, 500);
    // 3. Clone service-level defaults (branding, assets, translations, config, flags, login methods, footer items).
    // Service menu items are rows of bo_product_menu_items owned by the service (cloned below).
    const defaultTables = [
      { table: "bo_service_branding_defaults", columns: "environment, colors, gradients, fonts, radius, spacing, font_sizes, font_weights, shadows" },
      { table: "bo_service_assets_defaults", columns: "environment, asset_key, url, mime_type, metadata" },
      { table: "bo_service_translations_defaults", columns: "environment, language_code, namespace, key, value" },
      { table: "bo_service_public_config_defaults", columns: "environment, key, value, description" },
      { table: "bo_service_feature_flags_defaults", columns: "environment, flag_key, enabled, description" },
      { table: "bo_service_login_methods_defaults", columns: "environment, method_key, enabled, display_order, config" },
      { table: "bo_service_footer_items_defaults", columns: "environment, item_key, label, url, icon, display_order, item_group, visible" },
    ];
    for (const { table, columns } of defaultTables) {
      await copyRows(supabaseAdmin, table, columns, "service_id", source_service_id, newService.id);
    }
    let menuItemsCloned = await cloneMenuItems(supabaseAdmin, "service_id", source_service_id, newService.id);
    // 4. Clone products
    await clonePageBehaviour(supabaseAdmin, "service_id", source_service_id, newService.id);
    const { data: sourceProducts } = await supabaseAdmin.schema("backoffice").from("bo_products").select("*").eq("service_id", source_service_id);
    let productsCloned = 0;
    let localesCloned = 0;
    for (const srcProduct of sourceProducts || []){
      const { data: newProduct, error: prodErr } = await supabaseAdmin.schema("backoffice").from("bo_products").insert({
        service_id: newService.id,
        slug: srcProduct.slug,
        display_name: srcProduct.display_name,
        country_code: srcProduct.country_code,
        is_global: srcProduct.is_global,
        native_bundle_id: srcProduct.native_bundle_id,
        hostname_staging: null,
        hostname_production: null,
        status: srcProduct.status
      }).select().single();
      if (prodErr || !newProduct) continue;
      productsCloned++;
      // If this was the global product, update the reference
      if (source.global_product_id === srcProduct.id) {
        await supabaseAdmin.schema("backoffice").from("bo_services").update({
          global_product_id: newProduct.id
        }).eq("id", newService.id);
      }
      // Clone content consumption rules for this product
      const { data: consumptionRules } = await supabaseAdmin.schema("backoffice").from("bo_product_content_consumption_rules").select("environment, content_type, tier, action, rate_limit_enabled, tries_limit, frequency_period, frequency_unit_count, on_limit_reached_action").eq("product_id", srcProduct.id);
      if (consumptionRules && consumptionRules.length > 0) {
        await supabaseAdmin.schema("backoffice").from("bo_product_content_consumption_rules").upsert(consumptionRules.map((r)=>({
            ...r,
            product_id: newProduct.id
          })), {
          onConflict: "product_id,environment,content_type,tier",
          ignoreDuplicates: true
        });
      }
      // Login methods and signup settings (product level, both environments)
      const { data: loginMethods, error: loginReadErr } = await supabaseAdmin.schema("backoffice").from("bo_product_login_methods").select("environment, type, enabled, is_default, display_order, label_i18n_key, icon, feature_flag, min_app_version, max_app_version, config").eq("product_id", srcProduct.id);
      if (loginReadErr) {
        console.error("[error] clone-service: login methods read failed", loginReadErr.message);
      } else if (loginMethods && loginMethods.length > 0) {
        const { error: loginWriteErr } = await supabaseAdmin.schema("backoffice").from("bo_product_login_methods").upsert(loginMethods.map((m)=>({
            ...m,
            product_id: newProduct.id
          })), {
          onConflict: "product_id,environment,type",
          ignoreDuplicates: true
        });
        if (loginWriteErr) console.error("[error] clone-service: login methods copy failed", loginWriteErr.message);
      }
      const { data: signupRows, error: signupReadErr } = await supabaseAdmin.schema("backoffice").from("bo_product_signup_settings").select("environment, enabled, signup_url").eq("product_id", srcProduct.id);
      if (signupReadErr) {
        console.error("[error] clone-service: signup settings read failed", signupReadErr.message);
      } else if (signupRows && signupRows.length > 0) {
        const { error: signupWriteErr } = await supabaseAdmin.schema("backoffice").from("bo_product_signup_settings").upsert(signupRows.map((s)=>({
            ...s,
            product_id: newProduct.id,
            updated_by: user.id
          })), { onConflict: "product_id,environment" });
        if (signupWriteErr) console.error("[error] clone-service: signup settings copy failed", signupWriteErr.message);
      }
      await clonePageBehaviour(supabaseAdmin, "product_id", srcProduct.id, newProduct.id);
      menuItemsCloned += await cloneMenuItems(supabaseAdmin, "product_id", srcProduct.id, newProduct.id);
      // Product-level assets keep the source file URLs (files are shared, not copied).
      await copyRows(supabaseAdmin, "bo_product_level_assets", "environment, asset_key, url, mime_type, metadata", "product_id", srcProduct.id, newProduct.id);
      // Clone locales for this product
      const { data: sourceLocales } = await supabaseAdmin.schema("backoffice").from("bo_product_locales").select("*").eq("product_id", srcProduct.id);
      for (const srcLocale of sourceLocales || []){
        const { data: newLocale, error: locErr } = await supabaseAdmin.schema("backoffice").from("bo_product_locales").insert({
          product_id: newProduct.id,
          language_code: srcLocale.language_code,
          display_name: srcLocale.display_name,
          is_default: srcLocale.is_default,
          status: srcLocale.status
        }).select().single();
        if (locErr || !newLocale) continue;
        localesCloned++;
        await clonePageBehaviour(supabaseAdmin, "product_locale_id", srcLocale.id, newLocale.id);
        menuItemsCloned += await cloneMenuItems(supabaseAdmin, "product_locale_id", srcLocale.id, newLocale.id);
        // Clone locale-level data
        const localeTables = [
          { table: "bo_product_branding", columns: "environment, colors, gradients, fonts, radius, spacing, font_sizes, font_weights, shadows" },
          { table: "bo_product_assets", columns: "environment, asset_key, url, mime_type, width, height, metadata" },
          { table: "bo_product_translations", columns: "environment, namespace, key, value" },
          { table: "bo_product_public_config", columns: "environment, key, value, description" },
          { table: "bo_product_feature_flags", columns: "environment, flag_key, enabled, description" },
          { table: "bo_product_footer_items", columns: "environment, item_key, label, url, icon, display_order, item_group, visible, link_type, document_slug" },
        ];
        for (const { table, columns } of localeTables) {
          await copyRows(supabaseAdmin, table, columns, "product_locale_id", srcLocale.id, newLocale.id);
        }
      }
    }
    return jsonResponse({
      ok: true,
      service: newService,
      products_cloned: productsCloned,
      locales_cloned: localesCloned,
      menu_items_cloned: menuItemsCloned,
      message: `Service cloned successfully with ${productsCloned} product(s) and ${localesCloned} locale(s). Secrets and hostnames were NOT copied.`
    });
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: err instanceof Error ? err.message : "Internal error"
    }, 500);
  }
});
