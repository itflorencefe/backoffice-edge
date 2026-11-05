import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey"
};
const TAG = "[avatar-poll-worker]";
const POLL_ITERATIONS = 4;
const POLL_INTERVAL_MS = 15_000;
const TIMEOUT_MINUTES = 5;
const IMAGE_URL_REGEX = /https?:\/\/[^\s"'<>\\)}\]]+\.(?:png|jpg|jpeg|webp|gif)(?:[?#][^\s"'<>\\)}\]]*)?/i;
function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json"
    }
  });
}
function adminClient() {
  return createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });
}
function extractImageUrl(obj) {
  const str = JSON.stringify(obj);
  const match = str.match(IMAGE_URL_REGEX);
  return match ? match[0] : null;
}
async function pollRelevanceJob(row, relevanceBaseUrl, relevanceAuth, supabase) {
  const pollUrl = `${relevanceBaseUrl}/studios/${row.relevance_studio_id}/async_poll/${row.relevance_job_id}`;
  const pollResp = await fetch(pollUrl, {
    method: "GET",
    headers: {
      Authorization: relevanceAuth
    }
  });
  if (!pollResp.ok) {
    console.log(`${TAG} poll failed for ${row.id}: HTTP ${pollResp.status}`);
    return;
  }
  const pollData = await pollResp.json();
  const updates = pollData?.updates ?? [];
  const successUpdate = updates.find((u)=>u.type === "chain-success");
  const errorUpdate = updates.find((u)=>u.type === "chain-error" || u.type === "error");
  if (errorUpdate) {
    await supabase.from("avatar_generations").update({
      status: "failed",
      error_message: "Generation failed at Relevance AI",
      updated_at: new Date().toISOString()
    }).eq("id", row.id);
    console.log(`${TAG} marked ${row.id} as failed (chain-error)`);
    return;
  }
  if (!successUpdate) {
    return; // still processing
  }
  // Extract image URL from chain-success update
  let imageUrl = extractImageUrl(successUpdate);
  // Fallback: search entire response
  if (!imageUrl) {
    imageUrl = extractImageUrl(pollData);
  }
  // Second fallback: query knowledge list
  if (!imageUrl && row.relevance_conversation_id) {
    try {
      const knowledgeResp = await fetch(`${relevanceBaseUrl}/knowledge/list`, {
        method: "POST",
        headers: {
          Authorization: relevanceAuth,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          knowledge_set: row.relevance_conversation_id,
          page_size: 20,
          sort: [
            {
              insert_date_: "desc"
            }
          ],
          filters: []
        })
      });
      if (knowledgeResp.ok) {
        const knowledgeData = await knowledgeResp.json();
        imageUrl = extractImageUrl(knowledgeData);
      }
    } catch (e) {
      console.log(`${TAG} knowledge fallback failed for ${row.id}:`, e);
    }
  }
  if (!imageUrl) {
    await supabase.from("avatar_generations").update({
      status: "failed",
      error_message: "Could not extract generated image URL from AI response",
      updated_at: new Date().toISOString()
    }).eq("id", row.id);
    console.log(`${TAG} marked ${row.id} as failed (no image URL found)`);
    return;
  }
  // Download the generated image
  const downloadHeaders = {};
  if (imageUrl.includes("tryrelevance.com")) {
    downloadHeaders["Authorization"] = relevanceAuth;
  }
  const imgResp = await fetch(imageUrl, {
    headers: downloadHeaders
  });
  if (!imgResp.ok) {
    await supabase.from("avatar_generations").update({
      status: "failed",
      error_message: `Failed to download generated image: HTTP ${imgResp.status}`,
      updated_at: new Date().toISOString()
    }).eq("id", row.id);
    console.log(`${TAG} marked ${row.id} as failed (image download failed)`);
    return;
  }
  const imgBuffer = new Uint8Array(await imgResp.arrayBuffer());
  // Look up service_slug for storage path
  const { data: svcData } = await supabase.schema("backoffice").from("bo_services").select("slug").eq("id", row.service_id).maybeSingle();
  const serviceSlug = svcData?.slug ?? "default";
  const timestamp = Date.now();
  const storagePath = `${serviceSlug}/${row.user_id}/generated-avatar-${timestamp}.jpg`;
  const { error: uploadErr } = await supabase.storage.from("avatars").upload(storagePath, imgBuffer, {
    contentType: "image/jpeg",
    upsert: true
  });
  if (uploadErr) {
    await supabase.from("avatar_generations").update({
      status: "failed",
      error_message: `Re-upload to storage failed: ${uploadErr.message}`,
      updated_at: new Date().toISOString()
    }).eq("id", row.id);
    console.log(`${TAG} marked ${row.id} as failed (re-upload failed)`);
    return;
  }
  const { data: pubUrl } = supabase.storage.from("avatars").getPublicUrl(storagePath);
  const generatedAvatarUrl = pubUrl.publicUrl;
  // Update avatar_generations to completed
  await supabase.from("avatar_generations").update({
    status: "completed",
    generated_avatar_url: generatedAvatarUrl,
    updated_at: new Date().toISOString()
  }).eq("id", row.id);
  // Check if this is the user's first avatar (for bonus points)
  const { data: profile } = await supabase.from("profiles").select("avatar_url").eq("id", row.user_id).maybeSingle();
  const isFirstAvatar = !profile?.avatar_url;
  // Update profile
  await supabase.from("profiles").update({
    avatar_url: generatedAvatarUrl,
    onboarding_completed: true,
    updated_at: new Date().toISOString()
  }).eq("id", row.user_id);
  // Award first-avatar bonus
  if (isFirstAvatar) {
    await supabase.from("user_activities").insert({
      user_id: row.user_id,
      service_id: row.service_id,
      activity_type: "avatar_created",
      points_earned: 200,
      description: "First avatar creation bonus"
    });
    await supabase.from("profiles").update({
      total_points: profile?.total_points ? profile.total_points + 200 : 200,
      updated_at: new Date().toISOString()
    }).eq("id", row.user_id);
  }
  console.log(`${TAG} completed ${row.id} -> ${generatedAvatarUrl} (first_avatar=${isFirstAvatar})`);
}
async function runPollCycle(supabase) {
  //const relevanceBaseUrl = Deno.env.get("RELEVANCE_BASE_URL");
  //const relevanceProjectId = Deno.env.get("RELEVANCE_PROJECT_ID");
  //const relevanceApiKey = Deno.env.get("RELEVANCE_AI_API_KEY");
  const relevanceBaseUrl = "https://api-d7b62b.stack.tryrelevance.com/latest" || Deno.env.get("RELEVANCE_BASE_URL");
  const relevanceProjectId = "0d9321b6-6f45-4384-bc14-461f2a33bfd9" || Deno.env.get("RELEVANCE_PROJECT_ID");
  const relevanceApiKey = "sk-Y2MzNDJjODQtOTIwYy00MGZkLTgxNzMtZTkyYWU3YTA0YmNl" || Deno.env.get("RELEVANCE_AI_API_KEY");
  if (!relevanceBaseUrl || !relevanceProjectId || !relevanceApiKey) {
    console.error(`${TAG} Relevance AI env vars not configured`);
    return 0;
  }
  const relevanceAuth = `${relevanceProjectId}:${relevanceApiKey}`;
  // Timeout sweep: mark stale processing rows as failed
  await supabase.rpc("exec_sql", {
    query: `
      UPDATE avatar_generations SET
        status = 'failed',
        error_message = 'Generation timed out after ${TIMEOUT_MINUTES} minutes',
        updated_at = now()
      WHERE status = 'processing'
        AND updated_at < now() - interval '${TIMEOUT_MINUTES} minutes'
    `
  }).then(()=>{}).catch(()=>{
  // fallback: do it via the client
  });
  // Also do timeout via direct update (in case RPC doesn't exist)
  await supabase.from("avatar_generations").update({
    status: "failed",
    error_message: `Generation timed out after ${TIMEOUT_MINUTES} minutes`,
    updated_at: new Date().toISOString()
  }).eq("status", "processing").lt("updated_at", new Date(Date.now() - TIMEOUT_MINUTES * 60 * 1000).toISOString());
  // Query active jobs
  const { data: rows, error } = await supabase.from("avatar_generations").select("id, user_id, service_id, relevance_job_id, relevance_studio_id, relevance_conversation_id").eq("status", "processing").neq("relevance_job_id", "").not("relevance_job_id", "is", null).lt("updated_at", new Date(Date.now() - 5000).toISOString()).order("created_at", {
    ascending: true
  }).limit(10);
  if (error || !rows || rows.length === 0) {
    return 0;
  }
  console.log(`${TAG} polling ${rows.length} active jobs`);
  for (const row of rows){
    try {
      await pollRelevanceJob(row, relevanceBaseUrl, relevanceAuth, supabase);
    } catch (err) {
      console.error(`${TAG} error polling ${row.id}:`, err);
    }
  }
  return rows.length;
}
Deno.serve(async (req)=>{
  const ts = new Date().toISOString();
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 200,
      headers: CORS
    });
  }
  // Auth: accept service_role_key in Authorization OR X-Cron-Secret header
  const authHeader = req.headers.get("Authorization") ?? "";
  const cronSecret = req.headers.get("X-Cron-Secret") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const expectedCronSecret = "avatar-poll-cron-2026-secret-key-internal";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const isServiceRole = token === serviceRoleKey;
  const isCronAuth = cronSecret === expectedCronSecret;
  if (!isServiceRole && !isCronAuth) {
    return json({
      ok: false,
      error: "Unauthorized"
    }, 401);
  }
  try {
    const supabase = adminClient();
    let totalProcessed = 0;
    for(let i = 0; i < POLL_ITERATIONS; i++){
      const count = await runPollCycle(supabase);
      totalProcessed += count;
      // Sleep between iterations (skip sleep after last iteration)
      if (i < POLL_ITERATIONS - 1) {
        await new Promise((resolve)=>setTimeout(resolve, POLL_INTERVAL_MS));
      }
    }
    console.log(`${TAG} ${ts} | completed ${POLL_ITERATIONS} cycles, processed ${totalProcessed} rows total`);
    return json({
      ok: true,
      iterations: POLL_ITERATIONS,
      total_processed: totalProcessed
    }, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal error";
    console.error(`${TAG} ${ts} | unhandled error:`, message);
    return json({
      ok: false,
      error: message
    }, 500);
  }
});
