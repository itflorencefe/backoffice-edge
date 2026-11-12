import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { type BoltAuthClient, type BoltAuthEnv, createBoltAuthClient, createMemoryStorage } from "@digitalvirgo/su-bolt-core";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { create as jwtCreate, getNumericDate } from "jsr:@zaubrik/djwt@3.0.2";
import { resolveProduct, type ResolveProductParams } from "../_shared/resolve-product.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[bolt-auth-proxy]";
const APP_JWT_TTL_SECONDS = 1500;
const LOCAL_AUTH_PASSWORD = "123456";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

interface CommandRequest {
  command: string;
  userToken?: string;
  service_slug?: string;
  domain?: string;
  bundle_id?: string;
  country_code?: string;
  environment?: "staging" | "production";
}

function buildClient(serviceSlug: string) {
  const slugUpper = serviceSlug.toUpperCase().replace(/-/g, "_");
  const identifierKey = `${slugUpper}_SMART_USER_APP_ID`;
  const secretKey = `${slugUpper}_SMART_USER_APP_SECRET`;

  const identifier = Deno.env.get(identifierKey) ?? "";
  const secret = Deno.env.get(secretKey) ?? "";
  const env = (Deno.env.get("SMART_USER_APP_ENV") ?? "STAG") as BoltAuthEnv;

  if (!identifier || !secret) {
    return { client: null, error: `Server misconfigured: missing ${identifierKey} or ${secretKey}` };
  }

  const client = createBoltAuthClient({
    env,
    appCredentials: { identifier, secret },
    storage: createMemoryStorage(),
    debug: true,
    logRequests: true,
  });

  return { client, error: null };
}

function buildSupabaseAdmin() {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) {
    return { admin: null, error: "Server misconfigured: missing Supabase credentials" };
  }
  const admin = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  return { admin, error: null };
}

function isLocalMode(): boolean {
  const secret = Deno.env.get("APP_JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  return !secret;
}

async function importJwtKey(): Promise<CryptoKey | null> {
  const secret = Deno.env.get("APP_JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  if (!secret) return null;
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

async function resolveAbsoluteReference(
  boltClient: BoltAuthClient,
  userToken: string,
  ts: string,
): Promise<string> {
  const absoluteReference = await boltClient.fetchCurrentUser(userToken);
  console.log(`${TAG} ${ts} | fetchCurrentUser absoluteReference:`, absoluteReference);
  if (!absoluteReference) {
    throw Object.assign(new Error("Could not resolve absoluteReference from userToken"), {
      statusCode: 401,
      code: "AUTH_INVALID_TOKEN",
    });
  }
  return absoluteReference;
}

/**
 * Local mode: creates/reuses a Supabase Auth user and returns a platform-signed JWT.
 * The JWT will contain service_id and product_id inside app_metadata, which
 * jwt_service_id() and jwt_product_id() read via the COALESCE fallback path.
 */
async function handleSyncUserLocal(
  boltClient: BoltAuthClient,
  body: CommandRequest,
  userToken: string,
  ts: string,
): Promise<Response> {
  const absoluteReference = await resolveAbsoluteReference(boltClient, userToken, ts);
  console.log(`${TAG} ${ts} | [LOCAL] syncUser absoluteReference=${absoluteReference}`);

  const { admin, error: adminError } = buildSupabaseAdmin();
  if (!admin) {
    console.error(`${TAG} ${ts} | ${adminError}`);
    return json({ ok: false, error: { message: adminError, code: "SERVER_MISCONFIGURED" } }, 500);
  }

  // Resolve product using the shared module
  const resolutionParams: ResolveProductParams = {
    domain: body.domain,
    bundle_id: body.bundle_id,
    country_code: body.country_code,
    service_slug: body.service_slug,
    environment: body.environment,
  };

  let resolved;
  try {
    resolved = await resolveProduct(admin, resolutionParams);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Product resolution failed";
    console.error(`${TAG} ${ts} | resolveProduct failed:`, message);
    const code = message.includes("not found") ? "PRODUCT_NOT_FOUND" : "PRODUCT_RESOLUTION_FAILED";
    return json({ ok: false, error: { message, code } }, 404);
  }

  console.log(`${TAG} ${ts} | [LOCAL] resolved: service=${resolved.service.slug} product=${resolved.product.slug} by=${resolved.detected_by}`);

  if (resolved.service) {
    const { data: svcCheck } = await admin
      .schema("backoffice").from("services")
      .select("status")
      .eq("id", resolved.service.id)
      .maybeSingle();
    if (svcCheck && svcCheck.status !== "active") {
      return json({ ok: false, error: { message: `Service '${resolved.service.slug}' is not active`, code: "SERVICE_INACTIVE" } }, 403);
    }
  }

  const userId = absoluteReference;

  // Upsert profile with product_id
  const { error: profileError } = await admin
    .schema("application").from("profiles")
    .upsert(
      {
        id: userId,
        service_id: resolved.service.id,
        product_id: resolved.product.id,
        nickname: `user_${absoluteReference.substring(0, 8)}`,
        onboarding_completed: false,
      },
      { onConflict: "id,service_id,product_id", ignoreDuplicates: true },
    );

  if (profileError) {
    console.error(`${TAG} ${ts} | profile upsert failed:`, profileError.message);
    return json({ ok: false, error: { message: profileError.message, code: "PROFILE_UPSERT_FAILED" } }, 500);
  }

  // -- LOCAL MODE: Create/get Supabase Auth user and sign in --
  const email = `${absoluteReference}@bolt.local`;
  const appMetadata = {
    service_id: resolved.service.id,
    service_slug: resolved.service.slug,
    product_id: resolved.product.id,
    product_slug: resolved.product.slug,
    absolute_reference: absoluteReference,
    app_role: "app_user",
  };

  const { data: createData, error: createError } = await admin.auth.admin.createUser({
    id: userId,
    email,
    password: LOCAL_AUTH_PASSWORD,
    email_confirm: true,
    app_metadata: appMetadata,
  });

  if (createError) {
    if (createError.message?.includes("already") || (createError as any).status === 422) {
      console.log(`${TAG} ${ts} | [LOCAL] auth user already exists, updating app_metadata`);
      const { error: updateErr } = await admin.auth.admin.updateUserById(userId, {
        app_metadata: appMetadata,
      });
      if (updateErr) {
        console.error(`${TAG} ${ts} | [LOCAL] failed to update app_metadata:`, updateErr.message);
      }
    } else {
      console.error(`${TAG} ${ts} | [LOCAL] createUser failed:`, createError.message);
      return json({ ok: false, error: { message: createError.message, code: "AUTH_CREATE_FAILED" } }, 500);
    }
  } else {
    console.log(`${TAG} ${ts} | [LOCAL] created auth user id=${createData.user.id}`);
  }

  // Sign in to get a Supabase-signed JWT
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const anonClient = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: signInData, error: signInError } = await anonClient.auth.signInWithPassword({
    email,
    password: LOCAL_AUTH_PASSWORD,
  });

  if (signInError || !signInData.session) {
    const msg = signInError?.message ?? "signInWithPassword returned no session";
    console.error(`${TAG} ${ts} | [LOCAL] signIn failed:`, msg);
    return json({ ok: false, error: { message: msg, code: "AUTH_SIGNIN_FAILED" } }, 500);
  }

  const accessToken = signInData.session.access_token;
  const expiresIn = signInData.session.expires_in ?? APP_JWT_TTL_SECONDS;

  console.log(`${TAG} ${ts} | [LOCAL] syncUser complete user_id=${userId} product=${resolved.product.slug} expires_in=${expiresIn}`);
  return json({
    ok: true,
    data: {
      absolute_reference: absoluteReference,
      user_id: userId,
      service_id: resolved.service.id,
      service_slug: resolved.service.slug,
      product_id: resolved.product.id,
      product_slug: resolved.product.slug,
      detected_by: resolved.detected_by,
      access_token: accessToken,
      expires_in: expiresIn,
    },
  }, 200);
}

/**
 * Production mode: mints a custom HS256 JWT using APP_JWT_SECRET.
 * Used with external Supabase instances where the JWT secret is known.
 */
async function handleSyncUserProduction(
  boltClient: BoltAuthClient,
  body: CommandRequest,
  userToken: string,
  ts: string,
): Promise<Response> {
  const absoluteReference = await resolveAbsoluteReference(boltClient, userToken, ts);
  console.log(`${TAG} ${ts} | [PROD] syncUser absoluteReference=${absoluteReference}`);

  const { admin, error: adminError } = buildSupabaseAdmin();
  if (!admin) {
    console.error(`${TAG} ${ts} | ${adminError}`);
    return json({ ok: false, error: { message: adminError, code: "SERVER_MISCONFIGURED" } }, 500);
  }

  // Resolve product using the shared module
  const resolutionParams: ResolveProductParams = {
    domain: body.domain,
    bundle_id: body.bundle_id,
    country_code: body.country_code,
    service_slug: body.service_slug,
    environment: body.environment,
  };

  let resolved;
  try {
    resolved = await resolveProduct(admin, resolutionParams);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Product resolution failed";
    console.error(`${TAG} ${ts} | resolveProduct failed:`, message);
    const code = message.includes("not found") ? "PRODUCT_NOT_FOUND" : "PRODUCT_RESOLUTION_FAILED";
    return json({ ok: false, error: { message, code } }, 404);
  }

  console.log(`${TAG} ${ts} | [PROD] resolved: service=${resolved.service.slug} product=${resolved.product.slug} by=${resolved.detected_by}`);

  if (resolved.service) {
    const { data: svcCheck } = await admin
      .schema("backoffice").from("services")
      .select("status")
      .eq("id", resolved.service.id)
      .maybeSingle();
    if (svcCheck && svcCheck.status !== "active") {
      return json({ ok: false, error: { message: `Service '${resolved.service.slug}' is not active`, code: "SERVICE_INACTIVE" } }, 403);
    }
  }

  const userId = absoluteReference;

  // Upsert profile with product_id
  const { error: profileError } = await admin
    .schema("application").from("profiles")
    .upsert(
      {
        id: userId,
        service_id: resolved.service.id,
        product_id: resolved.product.id,
        nickname: `user_${absoluteReference.substring(0, 8)}`,
        onboarding_completed: false,
      },
      { onConflict: "id,service_id,product_id", ignoreDuplicates: true },
    );

  if (profileError) {
    console.error(`${TAG} ${ts} | profile upsert failed:`, profileError.message);
    return json({ ok: false, error: { message: profileError.message, code: "PROFILE_UPSERT_FAILED" } }, 500);
  }

  const key = await importJwtKey();
  if (!key) {
    return json({ ok: false, error: { message: "JWT signing secret not configured", code: "SERVER_MISCONFIGURED" } }, 500);
  }

  const iat = getNumericDate(0);
  const exp = getNumericDate(APP_JWT_TTL_SECONDS);

  const accessToken = await jwtCreate(
    { alg: "HS256", typ: "JWT" },
    {
      sub: userId,
      service_id: resolved.service.id,
      service_slug: resolved.service.slug,
      product_id: resolved.product.id,
      product_slug: resolved.product.slug,
      role: "authenticated",
      app_role: "app_user",
      absolute_reference: absoluteReference,
      iat,
      exp,
    },
    key,
  );

  console.log(`${TAG} ${ts} | [PROD] syncUser complete user_id=${userId} product=${resolved.product.slug}`);
  return json({
    ok: true,
    data: {
      absolute_reference: absoluteReference,
      user_id: userId,
      service_id: resolved.service.id,
      service_slug: resolved.service.slug,
      product_id: resolved.product.id,
      product_slug: resolved.product.slug,
      detected_by: resolved.detected_by,
      access_token: accessToken,
      expires_in: APP_JWT_TTL_SECONDS,
    },
  }, 200);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();
  const local = isLocalMode();

  try {
    console.log(`${TAG} ${ts} | ${req.method} ${req.url} mode=${local ? "LOCAL" : "PRODUCTION"}`);

    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (req.method === "GET") {
      return json({
        ok: true,
        mode: local ? "local" : "production",
        commands: ["fetchCurrentUser", "getIdentities", "isPayingFor", "syncUser"],
        usage: {
          method: "POST",
          body: {
            command: "<command>",
            userToken: "<session token>",
            domain: "<optional: app domain for product resolution>",
            bundle_id: "<optional: native bundle id>",
            country_code: "<optional: ISO country code>",
            service_slug: "<optional: fallback service slug>",
            environment: "<optional: staging | production>",
          },
        },
      }, 200);
    }

    if (req.method !== "POST") {
      return json({ ok: false, error: { message: "Method not allowed" } }, 405);
    }

    let body: CommandRequest;
    try {
      body = await req.json();
    } catch {
      return json({ ok: false, error: { message: "Invalid JSON" } }, 400);
    }

    if (!body.command) {
      return json({ ok: false, error: { message: "Missing command" } }, 400);
    }
    if (!body.userToken) {
      return json({ ok: false, error: { message: "Missing userToken" } }, 400);
    }

    // Determine service_slug for building the Bolt SDK client
    let resolvedSlugForClient = body.service_slug;

    if (!resolvedSlugForClient) {
      if (!body.domain && !body.bundle_id) {
        return json({ ok: false, error: { message: "Missing resolution parameters (domain, bundle_id, or service_slug)", code: "VALIDATION_ERROR" } }, 400);
      }
      // Pre-resolve to discover the service slug
      const { admin: preAdmin } = buildSupabaseAdmin();
      if (preAdmin) {
        try {
          const preResolved = await resolveProduct(preAdmin, {
            domain: body.domain,
            bundle_id: body.bundle_id,
            country_code: body.country_code,
            environment: body.environment,
          });
          resolvedSlugForClient = preResolved.service.slug;
        } catch (err) {
          const message = err instanceof Error ? err.message : "Product resolution failed";
          return json({ ok: false, error: { message, code: "PRODUCT_RESOLUTION_FAILED" } }, 404);
        }
      }
    }

    if (!resolvedSlugForClient) {
      return json({ ok: false, error: { message: "Could not determine service_slug", code: "VALIDATION_ERROR" } }, 400);
    }

    const { client, error } = buildClient(resolvedSlugForClient);
    if (!client) {
      console.error(`${TAG} ${ts} | ${error}`);
      return json({ ok: false, error: { message: error } }, 500);
    }

    await client.initialize();

    console.log(`${TAG} ${ts} | command=${body.command} service=${resolvedSlugForClient}`);

    switch (body.command) {
      case "syncUser": {
        if (local) {
          return await handleSyncUserLocal(client, body, body.userToken, ts);
        }
        return await handleSyncUserProduction(client, body, body.userToken, ts);
      }

      case "fetchCurrentUser": {
        const absoluteReference = await resolveAbsoluteReference(client, body.userToken, ts);
        console.log(`${TAG} ${ts} | fetchCurrentUser absoluteReference=${absoluteReference}`);
        return json({ ok: true, data: { absoluteReference } }, 200);
      }

      case "getIdentities": {
        const data = await client.getIdentities(body.userToken);
        console.log(`${TAG} ${ts} | getIdentities success`);
        return json({ ok: true, data }, 200);
      }

      case "isPayingFor": {
        const data = await client.isPayingFor(body.userToken);
        console.log(`${TAG} ${ts} | isPayingFor success`);
        return json({ ok: true, data }, 200);
      }

      default:
        return json({ ok: false, error: { message: `Unknown command: ${body.command}` } }, 400);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : "Request failed";
    const code = (err as any)?.code;
    const statusCode = (err as any)?.statusCode ?? 500;
    console.error(`${TAG} ${ts} | Error: ${message}`, err);
    return json({ ok: false, error: { message, code } }, statusCode);
  }
});
