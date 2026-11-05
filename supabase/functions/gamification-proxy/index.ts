import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const TAG = "[gamification-proxy]";
const COMPETITION_BASE = Deno.env.get("COMPETITION_BASE_DOMAIN") || "https://competition.dvtech.io";
function corsHeaders(req) {
  const origin = req.headers.get("Origin") || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey, Context-Bearer, X-B-Test-Id",
    "Access-Control-Allow-Credentials": "true"
  };
}
function json(body, status, req) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(req),
      "Content-Type": "application/json"
    }
  });
}
Deno.serve(async (req)=>{
  const ts = new Date().toISOString();
  const cors = corsHeaders(req);
  try {
    console.log(`${TAG} ${ts} | ${req.method} ${req.url}`);
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 200,
        headers: cors
      });
    }
    const url = new URL(req.url);
    const pathname = url.pathname;
    // Handle /static_env and /galaxybin proxy pass
    const proxyPrefixes = [
      "/static_env",
      "/galaxybin"
    ];
    const funcPrefix = "/gamification-proxy";
    const strippedPath = pathname.startsWith(funcPrefix) ? pathname.slice(funcPrefix.length) : pathname;
    for (const prefix of proxyPrefixes){
      if (strippedPath.startsWith(prefix)) {
        const bTestIdHeader = req.headers.get("X-B-Test-Id");
        const targetUrlObj = new URL(`${COMPETITION_BASE}${strippedPath}${url.search}`);
        if (bTestIdHeader) {
          targetUrlObj.searchParams.set("b_test_id", bTestIdHeader);
        }
        const targetUrl = targetUrlObj.toString();
        console.log(`${TAG} ${ts} | Proxying to: ${targetUrl}`);
        const headers = new Headers();
        const authHeader = req.headers.get("Context-Bearer");
        if (authHeader) {
          headers.set("Context-Bearer", authHeader);
        }
        const proxyResp = await fetch(targetUrl, {
          method: req.method,
          headers,
          body: req.method !== "GET" && req.method !== "HEAD" ? req.body : undefined
        });
        const respHeaders = new Headers(cors);
        const contentType = proxyResp.headers.get("Content-Type");
        if (contentType) {
          respHeaders.set("Content-Type", contentType);
        }
        return new Response(proxyResp.body, {
          status: proxyResp.status,
          headers: respHeaders
        });
      }
    }
    // Handle POST for gamification.getGameplaySource
    if (req.method !== "POST") {
      return json({
        ok: false,
        error: "Method not allowed"
      }, 405, req);
    }
    let body;
    try {
      body = await req.json();
    } catch  {
      return json({
        ok: false,
        error: "Invalid JSON body"
      }, 400, req);
    }
    if (!body.content_id) {
      return json({
        ok: false,
        error: "Missing content_id"
      }, 400, req);
    }
    if (!body.campaign_id) {
      return json({
        ok: false,
        error: "Missing campaign_id"
      }, 400, req);
    }
    const bTestId = body.b_test_id || req.headers.get("X-B-Test-Id") || "";
    const params = new URLSearchParams({
      content_id: body.content_id || "",
      campaign_id: body.campaign_id || "",
      lang: body.lang || "fr",
      country: body.country || "fr",
      product_domain: body.product_domain || "https://competition.dvtech.io",
      user_id: body.user_id || "",
      application_id: body.application_id || "prod_dv_xx_configme",
      session_id: body.session_id || ""
    });
    if (bTestId) {
      params.set("settrack", bTestId);
      params.set("b_test_id", bTestId);
    }
    const targetUrl = `${COMPETITION_BASE}/static_env/lapis/su/gamification.getGameplaySource?${params.toString()}`;
    console.log(`${TAG} ${ts} | Calling: ${targetUrl}`);
    const fetchHeaders = {
      "Accept": "application/json"
    };
    if (body.context_bearer) {
      fetchHeaders["Context-Bearer"] = body.context_bearer;
    }
    const apiResp = await fetch(targetUrl, {
      method: "GET",
      headers: fetchHeaders
    });
    const contentType = apiResp.headers.get("Content-Type") || "";
    let responseData;
    if (contentType.includes("application/json")) {
      responseData = await apiResp.json();
    } else {
      const text = await apiResp.text();
      try {
        responseData = JSON.parse(text);
      } catch  {
        responseData = {
          raw: text
        };
      }
    }
    console.log(`${TAG} ${ts} | API responded with status ${apiResp.status}`);
    return json({
      ok: true,
      data: responseData
    }, apiResp.status >= 400 ? apiResp.status : 200, req);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Request failed";
    console.error(`${TAG} ${ts} | Error: ${message}`, err);
    return json({
      ok: false,
      error: message
    }, 500, req);
  }
});
