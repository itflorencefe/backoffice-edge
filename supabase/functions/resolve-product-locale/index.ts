import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
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
Deno.serve(async (req)=>{
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 200,
        headers: corsHeaders
      });
    }
    const url = new URL(req.url);
    const serviceSlug = url.searchParams.get("slug");
    const countryCode = url.searchParams.get("country_code");
    if (!serviceSlug || !countryCode) {
      return jsonResponse({
        ok: false,
        error: "slug and country_code query parameters are required"
      }, 400);
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // Resolve: service slug -> service -> product (by country_code) -> product_locales
    const { data: service, error: serviceError } = await supabase.schema("backoffice").from("bo_services").select("id").eq("slug", serviceSlug).maybeSingle();
    if (serviceError) {
      return jsonResponse({
        ok: false,
        error: serviceError.message
      }, 500);
    }
    if (!service) {
      return jsonResponse({
        ok: false,
        error: "Service not found"
      }, 404);
    }
    let product = null;
    let countryFallback = false;
    const { data: exactProduct, error: productError } = await supabase.schema("backoffice").from("bo_products").select("id, slug, display_name, country_code, hostname_staging, hostname_production, status").eq("service_id", service.id).eq("country_code", countryCode.toUpperCase()).eq("status", "active").maybeSingle();
    if (productError) {
      return jsonResponse({
        ok: false,
        error: productError.message
      }, 500);
    }
    if (exactProduct) {
      product = exactProduct;
    } else {
      const { data: defaultProduct, error: defaultErr } = await supabase.schema("backoffice").from("bo_products").select("id, slug, display_name, country_code, hostname_staging, hostname_production, status").eq("service_id", service.id).eq("is_default", true).eq("status", "active").maybeSingle();
      if (defaultErr) return jsonResponse({
        ok: false,
        error: defaultErr.message
      }, 500);
      if (!defaultProduct) {
        return jsonResponse({
          ok: false,
          error: `No active product found for service '${serviceSlug}' in country '${countryCode}'`
        }, 404);
      }
      product = defaultProduct;
      countryFallback = true;
    }
    // Get all active locales for this product
    const { data: locales, error: localesError } = await supabase.schema("backoffice").from("bo_product_locales").select("id, language_code, display_name, is_default, status, config_version_staging, config_version_production").eq("product_id", product.id).eq("status", "active").order("is_default", {
      ascending: false
    });
    if (localesError) {
      return jsonResponse({
        ok: false,
        error: localesError.message
      }, 500);
    }
    const defaultLocale = locales?.find((l)=>l.is_default) || locales?.[0] || null;
    return jsonResponse({
      ok: true,
      country_fallback: countryFallback,
      service_slug: serviceSlug,
      country_code: countryCode.toUpperCase(),
      product: {
        id: product.id,
        slug: product.slug,
        display_name: product.display_name,
        hostname_staging: product.hostname_staging,
        hostname_production: product.hostname_production
      },
      default_locale: defaultLocale ? {
        product_locale_id: defaultLocale.id,
        language_code: defaultLocale.language_code,
        display_name: defaultLocale.display_name
      } : null,
      available_locales: (locales || []).map((l)=>({
          product_locale_id: l.id,
          language_code: l.language_code,
          display_name: l.display_name,
          is_default: l.is_default
        }))
    });
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: err instanceof Error ? err.message : "Internal error"
    }, 500);
  }
});
