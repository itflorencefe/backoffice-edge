import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * create-first-user
 *
 * Bootstrap-only edge function. Creates the first backoffice admin when
 * backoffice.backoffice_users is empty (see migration 20261027120000_baseline_schema.sql).
 *
 * Insert columns (backoffice_users):
 *   user_id        uuid  — auth.users.id from Auth Admin createUser
 *   email          text
 *   display_name   text
 *   role           text  — always 'admin' for first user
 *   is_active      boolean — true
 *   service_scope  text[] — '{}'
 *   product_scope  text[] — '{}'
 *
 * Call with anon (publishable) key as apikey + Authorization Bearer.
 * Uses SUPABASE_SERVICE_ROLE_KEY from the function env (never from the client).
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    if (req.method !== "POST") {
      return jsonResponse({ ok: false, error: "Method not allowed" }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse(
        { ok: false, error: "Server misconfigured: missing Supabase admin env" },
        500,
      );
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: existing, error: countErr } = await admin
      .schema("backoffice").from("backoffice_users")
      .select("email, role")
      .order("created_at", { ascending: true });

    if (countErr) {
      return jsonResponse(
        {
          ok: false,
          error:
            `Could not read backoffice_users: ${countErr.message}. Run migrations first.`,
        },
        500,
      );
    }

    if (existing && existing.length > 0) {
      // Report the oldest admin (or the oldest user when there is no admin) so the wizard can name it.
      const first = existing.find((u) => u.role === "admin") ?? existing[0];
      return jsonResponse(
        {
          ok: false,
          code: "ADMIN_EXISTS",
          existing_email: first.email,
          error:
            `A backoffice user already exists (${first.email}). Sign in with that account and manage users from the backoffice.`,
        },
        409,
      );
    }

    let body: {
      email?: string;
      password?: string;
      display_name?: string;
      data?: { first_name?: string };
    };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ ok: false, error: "Invalid JSON body" }, 400);
    }

    const email = (body.email || "").trim().toLowerCase();
    const password = (body.password || "").trim();
    const displayName =
      (body.display_name || "").trim() ||
      (body.data?.first_name || "").trim() ||
      (email.includes("@") ? email.split("@")[0] : "") ||
      "Admin";

    if (!email || !password) {
      return jsonResponse(
        { ok: false, error: "email and password are required" },
        400,
      );
    }

    const { data: authData, error: createErr } = await admin.auth.admin
      .createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          display_name: displayName,
          first_name: displayName,
        },
      });

    if (createErr) {
      return jsonResponse({ ok: false, error: createErr.message }, 400);
    }

    const userId = authData.user?.id;
    if (!userId) {
      return jsonResponse(
        { ok: false, error: "Auth user created but no user id returned" },
        500,
      );
    }

    // Values match backoffice.backoffice_users from the baseline_schema migration.
    const { data: boUser, error: boErr } = await admin
      .schema("backoffice").from("backoffice_users")
      .insert({
        user_id: userId,
        email,
        display_name: displayName,
        role: "admin",
        is_active: true,
        service_scope: [] as string[],
        product_scope: [] as string[],
      })
      .select()
      .single();

    if (boErr) {
      await admin.auth.admin.deleteUser(userId);
      return jsonResponse(
        {
          ok: false,
          error: `Auth user created but backoffice_users insert failed: ${boErr.message}`,
        },
        500,
      );
    }

    return jsonResponse({
      ok: true,
      user: boUser,
      message:
        `First admin ${email} created. Sign in and add services from the backoffice.`,
    });
  } catch (err) {
    return jsonResponse(
      {
        ok: false,
        error: err instanceof Error ? err.message : "Internal error",
      },
      500,
    );
  }
});
