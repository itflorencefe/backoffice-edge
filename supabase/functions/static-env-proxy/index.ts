import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const TAG = "[static-env-proxy]";
const COMPETITION_BASE = Deno.env.get("COMPETITION_BASE_DOMAIN") || "https://competition.dvtech.io";
function getCorsHeaders(req) {
  let origin = "*";
  try {
    origin = req.headers.get("Origin") || "*";
  } catch  {
  // ignore
  }
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey, Context-Bearer",
    "Access-Control-Allow-Credentials": "true",
    "Vary": "Origin"
  };
}
Deno.serve(async (req)=>{
  let cors;
  try {
    cors = getCorsHeaders(req);
  } catch  {
    cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey, Context-Bearer"
    };
  }
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: cors
    });
  }
  try {
    const rawUrl = req.url;
    console.log(`${TAG} ${req.method} ${rawUrl}`);
    const funcPrefix = "/functions/v1/static-env-proxy";
    let pathAndQuery;
    const prefixIdx = rawUrl.indexOf(funcPrefix);
    if (prefixIdx !== -1) {
      pathAndQuery = rawUrl.substring(prefixIdx + funcPrefix.length);
    } else {
      const shortPrefix = "/static-env-proxy";
      const shortIdx = rawUrl.indexOf(shortPrefix);
      if (shortIdx !== -1) {
        pathAndQuery = rawUrl.substring(shortIdx + shortPrefix.length);
      } else {
        try {
          const u = new URL(rawUrl);
          pathAndQuery = u.pathname + u.search;
        } catch  {
          pathAndQuery = "/";
        }
      }
    }
    const targetUrl = `${COMPETITION_BASE}${pathAndQuery}`;
    console.log(`${TAG} Proxying to: ${targetUrl}`);
    const proxyHeaders = {};
    try {
      const contextBearer = req.headers.get("Context-Bearer");
      if (contextBearer) proxyHeaders["Context-Bearer"] = contextBearer;
      const ct = req.headers.get("Content-Type");
      if (ct) proxyHeaders["Content-Type"] = ct;
    } catch  {
    // ignore header read errors
    }
    let reqBody = null;
    if (req.method !== "GET" && req.method !== "HEAD") {
      try {
        reqBody = await req.arrayBuffer();
      } catch  {
      // empty body
      }
    }
    let proxyResp;
    try {
      proxyResp = await fetch(targetUrl, {
        method: req.method,
        headers: proxyHeaders,
        body: reqBody
      });
    } catch (fetchErr) {
      console.error(`${TAG} Fetch failed:`, fetchErr);
      return new Response(JSON.stringify({
        ok: false,
        error: "Upstream fetch failed"
      }), {
        status: 502,
        headers: {
          ...cors,
          "Content-Type": "application/json"
        }
      });
    }
    let respBody;
    try {
      respBody = await proxyResp.arrayBuffer();
    } catch  {
      respBody = new ArrayBuffer(0);
    }
    const respHeaders = {
      ...cors
    };
    const respContentType = proxyResp.headers.get("Content-Type");
    if (respContentType) {
      respHeaders["Content-Type"] = respContentType;
    }
    return new Response(respBody, {
      status: proxyResp.status,
      headers: respHeaders
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    console.error(`${TAG} Top-level error: ${message}`, err);
    return new Response(JSON.stringify({
      ok: false,
      error: message
    }), {
      status: 500,
      headers: {
        ...cors,
        "Content-Type": "application/json"
      }
    });
  }
});
