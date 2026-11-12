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
    const productSlug = url.searchParams.get("product_slug");
    const documentSlug = url.searchParams.get("document_slug");
    const locale = url.searchParams.get("locale");
    const environment = url.searchParams.get("environment") || "production";
    if (!productSlug || !documentSlug || !locale) {
      return jsonResponse({
        ok: false,
        error: "product_slug, document_slug, and locale are required"
      }, 400);
    }
    if (environment !== "staging" && environment !== "production") {
      return jsonResponse({
        ok: false,
        error: "environment must be 'staging' or 'production'"
      }, 400);
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // Resolve product
    const { data: product, error: prodErr } = await supabase.schema("backoffice").from("products").select("id").eq("slug", productSlug).eq("status", "active").maybeSingle();
    if (prodErr) return jsonResponse({
      ok: false,
      error: prodErr.message
    }, 500);
    if (!product) return jsonResponse({
      ok: false,
      error: "Product not found"
    }, 404);
    // Resolve available locales for fallback
    const { data: allLocales } = await supabase.schema("backoffice").from("product_locales").select("language_code, is_default").eq("product_id", product.id).eq("status", "active").order("is_default", {
      ascending: false
    });
    const locales = allLocales || [];
    const requestedLocale = locale.toLowerCase();
    const hasRequestedLocale = locales.some((l)=>l.language_code === requestedLocale);
    const defaultLocale = locales.find((l)=>l.is_default) || locales[0];
    const resolvedLocale = hasRequestedLocale ? requestedLocale : defaultLocale?.language_code || requestedLocale;
    // Fetch the document using resolved locale
    const { data: doc, error: docErr } = await supabase.schema("backoffice").from("product_documents").select("id, slug, path, title, locale, updated_at, current_version_id").eq("product_id", product.id).eq("slug", documentSlug).eq("locale", resolvedLocale).eq("environment", environment).eq("status", "published").maybeSingle();
    if (docErr) return jsonResponse({
      ok: false,
      error: docErr.message
    }, 500);
    if (!doc) return jsonResponse({
      ok: false,
      error: "Document not found"
    }, 404);
    // Fetch the current version content
    let version = 1;
    let bodyHtml = "";
    if (doc.current_version_id) {
      const { data: ver } = await supabase.schema("backoffice").from("product_document_versions").select("version, body_html").eq("id", doc.current_version_id).maybeSingle();
      if (ver) {
        version = ver.version;
        bodyHtml = ver.body_html;
      }
    }
    return jsonResponse({
      ok: true,
      document: {
        slug: doc.slug,
        path: doc.path,
        title: doc.title,
        locale: doc.locale,
        version,
        body_html: bodyHtml,
        updated_at: doc.updated_at
      }
    });
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: err instanceof Error ? err.message : "Internal error"
    }, 500);
  }
});
