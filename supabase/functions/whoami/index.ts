import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import manifest from "./manifest.json" with {
  type: "json"
};
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey"
};
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
      return new Response(JSON.stringify({
        error: "App users are not authorized for this endpoint"
      }), {
        status: 403,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
  } catch  {
  // ignore decode errors; treat as non-app-user
  }
  return null;
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
    const destDomain = Deno.env.get("COMPETITION_BASE_DOMAIN") || "https://competition.dvtech.io";
    const productId = Deno.env.get("SMART_USER_APP_ID") || "test.bolt";
    const country = Deno.env.get("SMART_USER_COUNTRY") || "fr";
    const languages = Array.from(new Set([
      country || "fr",
      "en"
    ]));
    const resolved = {
      ...manifest,
      DEST_DOMAIN: destDomain,
      LANGUAGES: languages,
      PRODUCT_ID: productId,
      COUNTRY: country || "fr"
    };
    return new Response(JSON.stringify(resolved, null, 2), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    return new Response(JSON.stringify({
      error: message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
