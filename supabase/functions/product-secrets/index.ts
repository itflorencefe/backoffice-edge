import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey"
};
function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
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
      return json({
        error: "App users are not authorized for this endpoint"
      }, 403);
    }
  } catch  {
  // ignore
  }
  return null;
}
function redact(value) {
  if (!value) return "";
  if (value.length <= 8) return "*".repeat(value.length);
  return `${value.slice(0, 4)}${"*".repeat(Math.max(4, value.length - 8))}${value.slice(-4)}`;
}
function redactRow(row, reveal) {
  return {
    ...row,
    value: reveal ? row.value : redact(row.value)
  };
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 200,
      headers: corsHeaders
    });
  }
  const blocked = rejectAppUser(req);
  if (blocked) return blocked;
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const accessToken = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!accessToken) return json({
      error: "missing_authorization"
    }, 401);
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
    const authed = createClient(SUPABASE_URL, ANON_KEY, {
      global: {
        headers: {
          Authorization: `Bearer ${accessToken}`
        }
      }
    });
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: userData, error: userErr } = await authed.auth.getUser();
    if (userErr || !userData?.user) return json({
      error: "unauthenticated"
    }, 401);
    const { data: role } = await admin.schema("backoffice").from("bo_backoffice_users").select("role,is_active,service_scope,product_scope").eq("user_id", userData.user.id).maybeSingle();
    if (!role || !role.is_active) return json({
      error: "forbidden"
    }, 403);
    const isAdmin = role.role === "admin";
    const isEditor = role.role === "editor" || isAdmin;
    if (!isEditor) return json({
      error: "forbidden"
    }, 403);
    const url = new URL(req.url);
    const parts = url.pathname.replace(/^\/product-secrets\/?/, "").split("/").filter(Boolean);
    if (req.method === "GET" && parts.length === 0) {
      const productLocaleId = url.searchParams.get("product_locale_id");
      const environment = url.searchParams.get("environment");
      const reveal = url.searchParams.get("reveal") === "true" && isAdmin;
      if (!productLocaleId || !environment) return json({
        error: "missing_params"
      }, 400);
      const { data, error } = await admin.schema("backoffice").from("bo_product_secrets").select("*").eq("product_locale_id", productLocaleId).eq("environment", environment).order("key", {
        ascending: true
      });
      if (error) return json({
        error: error.message
      }, 500);
      return json({
        secrets: (data ?? []).map((r)=>redactRow(r, reveal))
      });
    }
    if (req.method === "POST" && parts.length === 0) {
      const body = await req.json().catch(()=>null);
      if (!body?.product_locale_id || !body?.environment || !body?.key) {
        return json({
          error: "missing_fields"
        }, 400);
      }
      const payload = {
        product_locale_id: body.product_locale_id,
        environment: body.environment,
        key: body.key,
        value: body.value ?? "",
        description: body.description ?? "",
        updated_at: new Date().toISOString()
      };
      const { data, error } = await admin.schema("backoffice").from("bo_product_secrets").upsert(payload, {
        onConflict: "product_locale_id,environment,key"
      }).select().maybeSingle();
      if (error) return json({
        error: error.message
      }, 500);
      await admin.schema("backoffice").from("bo_backoffice_audit_log").insert({
        actor_id: userData.user.id,
        actor_email: userData.user.email ?? "",
        action: "upsert_secret",
        entity_type: "product_secrets",
        entity_id: data?.id ?? null,
        product_locale_id: body.product_locale_id,
        environment: body.environment,
        diff: {
          key: body.key,
          has_value: !!body.value,
          description: body.description ?? ""
        }
      });
      return json({
        secret: data ? redactRow(data, false) : null
      });
    }
    if (req.method === "DELETE" && parts.length === 1) {
      if (!isAdmin) return json({
        error: "forbidden"
      }, 403);
      const id = parts[0];
      const { data: existing } = await admin.schema("backoffice").from("bo_product_secrets").select("product_locale_id,environment,key").eq("id", id).maybeSingle();
      const { error } = await admin.schema("backoffice").from("bo_product_secrets").delete().eq("id", id);
      if (error) return json({
        error: error.message
      }, 500);
      await admin.schema("backoffice").from("bo_backoffice_audit_log").insert({
        actor_id: userData.user.id,
        actor_email: userData.user.email ?? "",
        action: "delete_secret",
        entity_type: "product_secrets",
        entity_id: id,
        product_locale_id: existing?.product_locale_id ?? null,
        environment: existing?.environment ?? null,
        diff: {
          key: existing?.key ?? ""
        }
      });
      return json({
        deleted: true
      });
    }
    return json({
      error: "not_found"
    }, 404);
  } catch (err) {
    return json({
      error: err.message ?? "internal_error"
    }, 500);
  }
});
