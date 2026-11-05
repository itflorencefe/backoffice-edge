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
function generatePassword() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
  const special = "!@#$%&*";
  let password = "";
  const array = new Uint8Array(12);
  crypto.getRandomValues(array);
  for(let i = 0; i < 12; i++){
    password += chars[array[i] % chars.length];
  }
  const specialArray = new Uint8Array(2);
  crypto.getRandomValues(specialArray);
  password += special[specialArray[0] % special.length];
  password += special[specialArray[1] % special.length];
  return password;
}
async function verifyAdmin(supabaseAdmin, authHeader) {
  const token = authHeader.replace("Bearer ", "");
  const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !user) return null;
  const { data: caller } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").select("role").eq("user_id", user.id).eq("is_active", true).maybeSingle();
  if (!caller || caller.role !== "admin") return null;
  return user;
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
    const supabaseAdmin = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    });
    const caller = await verifyAdmin(supabaseAdmin, authHeader);
    if (!caller) {
      return jsonResponse({
        ok: false,
        error: "Only admins can perform this action"
      }, 403);
    }
    const body = await req.json();
    const { action } = body;
    if (action === "reset-password") {
      const { user_id } = body;
      if (!user_id) {
        return jsonResponse({
          ok: false,
          error: "user_id is required"
        }, 400);
      }
      const newPassword = generatePassword();
      const { data: userCheck, error: userCheckErr } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").select("id").eq("user_id", user_id).maybeSingle();
      if (userCheckErr || !userCheck) {
        return jsonResponse({
          ok: false,
          error: "User not found"
        }, 404);
      }
      const { error: updateErr } = await supabaseAdmin.rpc("reset_user_password", {
        target_user_id: user_id,
        new_password: newPassword
      });
      if (updateErr) {
        return jsonResponse({
          ok: false,
          error: `Update failed: ${updateErr.message}`
        }, 500);
      }
      return jsonResponse({
        ok: true,
        generated_password: newPassword,
        message: "Password reset successfully."
      });
    }
    if (action === "delete-user") {
      const { user_id } = body;
      if (!user_id) {
        return jsonResponse({
          ok: false,
          error: "user_id is required"
        }, 400);
      }
      const { data: userCheck, error: userCheckErr } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").select("id, user_id").eq("user_id", user_id).maybeSingle();
      if (userCheckErr || !userCheck) {
        return jsonResponse({
          ok: false,
          error: "User not found"
        }, 404);
      }
      // Prevent self-deletion
      if (userCheck.user_id === caller.id) {
        return jsonResponse({
          ok: false,
          error: "Cannot delete your own account"
        }, 400);
      }
      const { error: deleteBoErr } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").delete().eq("user_id", user_id);
      if (deleteBoErr) {
        return jsonResponse({
          ok: false,
          error: `Failed to delete backoffice user: ${deleteBoErr.message}`
        }, 500);
      }
      const { error: deleteAuthErr } = await supabaseAdmin.auth.admin.deleteUser(user_id);
      if (deleteAuthErr) {
        return jsonResponse({
          ok: false,
          error: `Backoffice record deleted but auth user removal failed: ${deleteAuthErr.message}`
        }, 500);
      }
      return jsonResponse({
        ok: true,
        message: "User deleted successfully."
      });
    }
    // Default action: create user
    const { email, display_name, role, service_scope, product_scope } = body;
    if (!email) {
      return jsonResponse({
        ok: false,
        error: "email is required"
      }, 400);
    }
    const validRoles = [
      "viewer",
      "editor",
      "admin"
    ];
    const userRole = validRoles.includes(role) ? role : "viewer";
    const generatedPassword = generatePassword();
    // Validate service slugs exist
    const resolvedServiceScope = service_scope || [];
    if (resolvedServiceScope.length > 0) {
      const { data: services, error: svcErr } = await supabaseAdmin.schema("backoffice").from("bo_services").select("slug").in("slug", resolvedServiceScope);
      if (svcErr) {
        return jsonResponse({
          ok: false,
          error: `Failed to validate service slugs: ${svcErr.message}`
        }, 400);
      }
      const validSlugs = (services || []).map((s)=>s.slug);
      const invalid = resolvedServiceScope.filter((s)=>!validSlugs.includes(s));
      if (invalid.length > 0) {
        return jsonResponse({
          ok: false,
          error: `Invalid service slugs: ${invalid.join(', ')}`
        }, 400);
      }
    }
    // Validate product slugs exist
    const resolvedProductScope = product_scope || [];
    if (resolvedProductScope.length > 0) {
      const { data: products, error: prodErr } = await supabaseAdmin.schema("backoffice").from("bo_products").select("slug").in("slug", resolvedProductScope);
      if (prodErr) {
        return jsonResponse({
          ok: false,
          error: `Failed to validate product slugs: ${prodErr.message}`
        }, 400);
      }
      const validSlugs = (products || []).map((p)=>p.slug);
      const invalid = resolvedProductScope.filter((s)=>!validSlugs.includes(s));
      if (invalid.length > 0) {
        return jsonResponse({
          ok: false,
          error: `Invalid product slugs: ${invalid.join(', ')}`
        }, 400);
      }
    }
    const { data: newAuthUser, error: createErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password: generatedPassword,
      email_confirm: true,
      user_metadata: {
        display_name: display_name || email.split("@")[0]
      }
    });
    if (createErr) {
      return jsonResponse({
        ok: false,
        error: createErr.message
      }, 400);
    }
    if (!newAuthUser.user) {
      return jsonResponse({
        ok: false,
        error: "Failed to create auth user"
      }, 500);
    }
    const { data: boUser, error: boErr } = await supabaseAdmin.schema("backoffice").from("bo_backoffice_users").insert({
      user_id: newAuthUser.user.id,
      email,
      display_name: display_name || email.split("@")[0],
      role: userRole,
      is_active: true,
      service_scope: resolvedServiceScope,
      product_scope: resolvedProductScope
    }).select().single();
    if (boErr) {
      await supabaseAdmin.auth.admin.deleteUser(newAuthUser.user.id);
      return jsonResponse({
        ok: false,
        error: boErr.message
      }, 500);
    }
    return jsonResponse({
      ok: true,
      user: boUser,
      generated_password: generatedPassword,
      message: `User ${email} created successfully with role '${userRole}'.`
    });
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: err instanceof Error ? err.message : "Internal error"
    }, 500);
  }
});
