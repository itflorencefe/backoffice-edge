/**
 * avatar-generate — server-side OpenAI trading-card avatar generation.
 *
 * Auth: app JWT via Authorization: Bearer, verified like app-account-delete.
 * Lifecycle: concurrency guard → pending → processing → completed|failed.
 * Long work runs under EdgeRuntime.waitUntil with a hard fail-before-kill deadline.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.1";
import { verify as jwtVerify } from "jsr:@zaubrik/djwt@3.0.2";
import { CARD_AGENT_INSTRUCTIONS } from "./cardAgentInstructions.ts";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[avatar-generate]";
const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const DEFAULT_MODEL = "gpt-4o-mini";
/** Pro wall-clock is 400s; ~90s typical success → default 180s (~2× headroom). */
const DEFAULT_TIMEOUT_SECONDS = 180;
const SAFETY_BUFFER_SECONDS = 40;

type ImageOutputFormat = "webp" | "png" | "jpeg";
type ImageQuality = "low" | "medium" | "high";
type ImageDetail = "low" | "high";

interface ImageToolOpts {
  quality: ImageQuality;
  detail: ImageDetail;
  outputFormat: ImageOutputFormat;
  size: string;
  extension: string;
  contentType: string;
}

declare const EdgeRuntime: {
  waitUntil(promise: Promise<unknown>): void;
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function importJwtKey(): Promise<CryptoKey> {
  const secret = Deno.env.get("APP_JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  if (!secret) throw new Error("JWT secret not configured");
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

interface NormalizedAppClaims {
  sub: string;
  app_role: string;
  service_id: string | null;
  product_id: string | null;
}

/**
 * Accept production flat JWTs and local GoTrue JWTs (tenancy under app_metadata).
 * Same COALESCE order as Postgres jwt_product_id() / jwt_service_id().
 */
function normalizeAppClaims(raw: Record<string, unknown>): NormalizedAppClaims | null {
  const meta =
    raw.app_metadata && typeof raw.app_metadata === "object"
      ? (raw.app_metadata as Record<string, unknown>)
      : {};
  const sub = typeof raw.sub === "string" ? raw.sub : "";
  const app_role = String(raw.app_role ?? meta.app_role ?? "");
  const service_id = String(raw.service_id ?? meta.service_id ?? "") || null;
  const product_id = String(raw.product_id ?? meta.product_id ?? "") || null;
  if (!sub || app_role !== "app_user") return null;
  return { sub, app_role, service_id, product_id };
}

interface RequestBody {
  sourceImageUrl?: string;
  nickname?: string;
  theme?: string;
  event?: string | null;
  model?: string;
  timeout_seconds?: number;
  instructions?: string;
}

interface ImageGenerationCall {
  type: string;
  result?: string;
  revised_prompt?: string;
}

interface OpenAIResponseBody {
  id?: string;
  status?: string;
  output?: Array<{
    type: string;
    result?: string;
    revised_prompt?: string;
    content?: Array<{ type: string; text?: string }>;
  }>;
  error?: { message?: string };
}

function serviceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
}

function hardLimitSeconds(): number {
  const raw = Deno.env.get("AVATAR_EDGE_HARD_LIMIT_SECONDS");
  const n = raw ? parseInt(raw, 10) : 400;
  return Number.isFinite(n) && n > 60 ? n : 400;
}

/** Deno-only knobs for OpenAI image tool (not product-config). Invalid values → defaults. */
function resolveImageToolOpts(): ImageToolOpts {
  const qualityRaw = (Deno.env.get("AVATAR_IMAGE_QUALITY") || "medium").trim().toLowerCase();
  const quality: ImageQuality =
    qualityRaw === "low" || qualityRaw === "medium" || qualityRaw === "high"
      ? qualityRaw
      : "medium";

  const detailRaw = (Deno.env.get("AVATAR_IMAGE_DETAIL") || "high").trim().toLowerCase();
  const detail: ImageDetail = detailRaw === "low" || detailRaw === "high" ? detailRaw : "high";

  const formatRaw = (Deno.env.get("AVATAR_IMAGE_OUTPUT_FORMAT") || "webp").trim().toLowerCase();
  const outputFormat: ImageOutputFormat =
    formatRaw === "png" || formatRaw === "jpeg" || formatRaw === "webp" || formatRaw === "jpg"
      ? (formatRaw === "jpg" ? "jpeg" : formatRaw)
      : "webp";

  const sizeRaw = (Deno.env.get("AVATAR_IMAGE_SIZE") || "1024x1024").trim();
  const size = /^\d{2,4}x\d{2,4}$/.test(sizeRaw) ? sizeRaw : "1024x1024";

  const extension =
    outputFormat === "webp" ? "webp" : outputFormat === "jpeg" ? "jpg" : "png";
  const contentType =
    outputFormat === "webp"
      ? "image/webp"
      : outputFormat === "jpeg"
        ? "image/jpeg"
        : "image/png";

  return { quality, detail, outputFormat, size, extension, contentType };
}

function buildUserInput(username: string, theme: string, event: string): string {
  return [
    "Generate a collectible trading card using the supplied source image.",
    `USERNAME: ${username}`,
    `THEME: ${theme}`,
    `EVENT: ${event}`,
    event ? "CARD_TYPE: SHINY_EVENT" : "CARD_TYPE: COMMON",
    "The supplied image is USER_IMAGE and is the identity source.",
  ].join("\n");
}

function extractImageCall(body: OpenAIResponseBody): ImageGenerationCall | undefined {
  return body.output?.find(
    (item) =>
      item.type === "image_generation_call" &&
      typeof item.result === "string" &&
      item.result.length > 0,
  ) as ImageGenerationCall | undefined;
}

function extractOutputText(body: OpenAIResponseBody): string | undefined {
  const textParts: string[] = [];
  for (const item of body.output ?? []) {
    if (item.type !== "message" || !item.content) continue;
    for (const content of item.content) {
      if (content.type === "output_text" && content.text) textParts.push(content.text);
    }
  }
  const text = textParts.join("\n").trim();
  return text || undefined;
}

function parseValidationFailure(
  body: OpenAIResponseBody,
): { error: string; message: string } | undefined {
  const text = extractOutputText(body);
  if (!text) return undefined;
  const normalized = text
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```$/i, "")
    .trim();
  try {
    const parsed = JSON.parse(normalized) as {
      status?: string;
      error?: string;
      message?: string;
    };
    if (
      parsed.status === "incomplete" &&
      typeof parsed.error === "string" &&
      typeof parsed.message === "string"
    ) {
      return { error: parsed.error, message: parsed.message };
    }
  } catch {
    // fall through
  }
  return undefined;
}

async function parseSSEStream(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  onResponseId?: (id: string) => void,
  signal?: AbortSignal,
): Promise<OpenAIResponseBody> {
  const decoder = new TextDecoder();
  let buffer = "";
  let responseId: string | undefined;
  let finalBody: OpenAIResponseBody | undefined;

  while (true) {
    if (signal?.aborted) throw new Error("GENERATION_TIMEOUT");
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      const jsonStr = line.slice(6).trim();
      if (!jsonStr || jsonStr === "[DONE]") continue;
      try {
        const event = JSON.parse(jsonStr);
        const eventType = event?.type;
        if (eventType === "response.created" && event?.response?.id && !responseId) {
          responseId = event.response.id as string;
          onResponseId?.(responseId);
        }
        if (eventType === "response.completed" && event?.response) {
          finalBody = event.response as OpenAIResponseBody;
        }
      } catch {
        // skip malformed
      }
    }
  }

  if (!finalBody && responseId) {
    finalBody = { id: responseId, status: "unknown", output: [] };
  }
  if (!finalBody) {
    throw new Error("SSE stream ended without a response.completed event");
  }
  return finalBody;
}

function base64ToUint8Array(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function markFailed(
  supabase: SupabaseClient,
  generationId: string,
  errorMessage: string,
): Promise<void> {
  await supabase
    .from("avatar_generations")
    .update({
      status: "failed",
      error_message: errorMessage,
      updated_at: new Date().toISOString(),
    })
    .eq("id", generationId)
    .in("status", ["pending", "processing"]);
}

function elapsedSeconds(startedAt: number): number {
  return Math.round((Date.now() - startedAt) / 1000);
}

function tenancyCtx(opts: {
  generationId: string;
  userId: string;
  serviceId: string | null;
  productId: string | null;
}): string {
  return `generation=${opts.generationId} user=${opts.userId.slice(0, 8)} service=${opts.serviceId ?? "-"} product=${opts.productId ?? "-"}`;
}

async function runGeneration(opts: {
  generationId: string;
  userId: string;
  serviceId: string | null;
  productId: string | null;
  nickname: string;
  theme: string;
  event: string | null;
  sourceImageUrl: string;
  model: string;
  timeoutSeconds: number;
  instructions: string;
}): Promise<void> {
  const supabase = serviceClient();
  const startedAt = Date.now();
  const ctx = tenancyCtx(opts);
  let outcome: "completed" | "failed" = "failed";
  let errorCode: string | null = "OPENAI_API_KEY not configured";

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    await markFailed(supabase, opts.generationId, "OPENAI_API_KEY not configured");
    console.log(
      `${TAG} generation failed | ${ctx} duration=${elapsedSeconds(startedAt)}s status=failed error=OPENAI_API_KEY not configured`,
    );
    return;
  }

  const budgetSeconds = Math.min(
    opts.timeoutSeconds,
    Math.max(60, hardLimitSeconds() - SAFETY_BUFFER_SECONDS),
  );
  const controller = new AbortController();
  const deadlineTimer = setTimeout(() => controller.abort(), budgetSeconds * 1000);
  const imageOpts = resolveImageToolOpts();

  console.log(
    `${TAG} run start | ${ctx} theme=${opts.theme} event=${opts.event ?? "-"} model=${opts.model} ` +
      `timeoutRequested=${opts.timeoutSeconds}s budget=${budgetSeconds}s ` +
      `quality=${imageOpts.quality} detail=${imageOpts.detail} format=${imageOpts.outputFormat} size=${imageOpts.size}`,
  );

  try {
    const event = opts.event?.trim() || "";
    const httpResponse = await fetch(OPENAI_RESPONSES_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      signal: controller.signal,
      body: JSON.stringify({
        model: opts.model || DEFAULT_MODEL,
        instructions: opts.instructions,
        stream: true,
        input: [
          {
            role: "user",
            content: [
              { type: "input_text", text: buildUserInput(opts.nickname, opts.theme, event) },
              { type: "input_image", image_url: opts.sourceImageUrl, detail: imageOpts.detail },
            ],
          },
        ],
        tools: [
          {
            type: "image_generation",
            action: "edit",
            size: imageOpts.size,
            quality: imageOpts.quality,
            output_format: imageOpts.outputFormat,
          },
        ],
        tool_choice: "auto",
        store: true,
      }),
    });

    if (!httpResponse.ok) {
      const errorText = await httpResponse.text();
      let errMsg = `OpenAI request failed with HTTP ${httpResponse.status}`;
      try {
        const errBody = JSON.parse(errorText);
        if (errBody?.error?.message) errMsg = errBody.error.message;
      } catch {
        // keep default
      }
      errorCode = errMsg;
      await markFailed(supabase, opts.generationId, errMsg);
      return;
    }

    if (!httpResponse.body) {
      errorCode = "OpenAI response has no stream body";
      await markFailed(supabase, opts.generationId, errorCode);
      return;
    }

    const reader = httpResponse.body.getReader();
    let body = await parseSSEStream(
      reader,
      (responseId) => {
        void supabase
          .from("avatar_generations")
          .update({
            openai_response_id: responseId,
            updated_at: new Date().toISOString(),
          })
          .eq("id", opts.generationId);
      },
      controller.signal,
    );

    const imageCall = extractImageCall(body);
    if (imageCall?.result) {
      let base64 = imageCall.result;
      imageCall.result = undefined;
      const responseId = body.id ?? null;
      body = { id: responseId ?? undefined, status: body.status, output: [] };

      const base64Length = base64.length;
      console.log(
        `${TAG} image payload | ${ctx} base64Length=${base64Length} approxMB=${(base64Length / (1024 * 1024)).toFixed(2)} format=${imageOpts.outputFormat}`,
      );

      const bytes = base64ToUint8Array(base64);
      base64 = "";

      const fileName = `${opts.userId}/generated-avatar-${Date.now()}.${imageOpts.extension}`;
      const { error: uploadError } = await supabase.storage
        .from("avatars")
        .upload(fileName, bytes, { contentType: imageOpts.contentType, upsert: false });

      if (uploadError) {
        errorCode = uploadError.message || "UPLOAD_FAILED";
        await markFailed(supabase, opts.generationId, errorCode);
        return;
      }

      const { data: publicUrlData } = supabase.storage.from("avatars").getPublicUrl(fileName);
      const supabaseUrl = `${publicUrlData.publicUrl}?t=${Date.now()}`;

      await supabase
        .from("avatar_generations")
        .update({
          status: "completed",
          generated_avatar_url: supabaseUrl,
          openai_response_id: responseId,
          updated_at: new Date().toISOString(),
        })
        .eq("id", opts.generationId);

      await supabase
        .from("profiles")
        .update({ avatar_url: supabaseUrl, onboarding_completed: true })
        .eq("id", opts.userId);

      outcome = "completed";
      errorCode = null;
      return;
    }

    const validationFailure = parseValidationFailure(body);
    if (validationFailure) {
      errorCode = validationFailure.error;
      await markFailed(supabase, opts.generationId, validationFailure.error);
      return;
    }

    errorCode = "GENERATION_FAILED";
    await markFailed(supabase, opts.generationId, "GENERATION_FAILED");
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Generation failed";
    const code = msg === "GENERATION_TIMEOUT" || (err instanceof DOMException && err.name === "AbortError")
      ? "GENERATION_TIMEOUT"
      : msg;
    errorCode = code;
    console.error(`${TAG} runGeneration error:`, code);
    await markFailed(supabase, opts.generationId, code);
  } finally {
    clearTimeout(deadlineTimer);
    const duration = elapsedSeconds(startedAt);
    if (outcome === "completed") {
      console.log(`${TAG} generation complete | ${ctx} duration=${duration}s status=completed`);
    } else {
      console.log(
        `${TAG} generation failed | ${ctx} duration=${duration}s status=failed error=${errorCode ?? "unknown"}`,
      );
    }
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "Method not allowed", code: "METHOD_NOT_ALLOWED" }, 405);
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return json({ ok: false, error: "Missing bearer token", code: "AUTH_REQUIRED" }, 401);
  }

  let verified: Record<string, unknown>;
  try {
    const key = await importJwtKey();
    verified = (await jwtVerify(auth.slice(7).trim(), key)) as unknown as Record<string, unknown>;
  } catch (err) {
    console.warn(`${TAG} ${ts} | JWT verify failed:`, err instanceof Error ? err.message : err);
    return json({ ok: false, error: "Invalid token", code: "INVALID_TOKEN" }, 401);
  }

  const claims = normalizeAppClaims(verified);
  if (!claims) {
    return json({ ok: false, error: "Not an app_user token", code: "INVALID_TOKEN" }, 403);
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body", code: "MISSING_FIELDS" }, 400);
  }

  const sourceImageUrl = (body.sourceImageUrl || "").trim();
  const nickname = (body.nickname || "").trim();
  const theme = (body.theme || "").trim();
  const event = body.event?.trim() || null;
  const model = (body.model || "").trim() || DEFAULT_MODEL;
  const timeoutSeconds =
    typeof body.timeout_seconds === "number" && body.timeout_seconds > 0
      ? body.timeout_seconds
      : DEFAULT_TIMEOUT_SECONDS;
  const instructions = (body.instructions || "").trim() || CARD_AGENT_INSTRUCTIONS;

  if (!sourceImageUrl || !nickname || !theme) {
    return json({
      ok: false,
      error: "sourceImageUrl, nickname, and theme are required",
      code: "MISSING_FIELDS",
    }, 400);
  }

  const supportedSource =
    /^https:\/\//i.test(sourceImageUrl) ||
    /^data:image\/(png|jpeg|jpg|webp);base64,/i.test(sourceImageUrl);
  if (!supportedSource) {
    return json({
      ok: false,
      error: "sourceImageUrl must be HTTPS or an image data URI",
      code: "MISSING_FIELDS",
    }, 400);
  }

  const supabase = serviceClient();
  const userId = claims.sub;
  const serviceId = claims.service_id;
  const productId = claims.product_id;

  if (!productId) {
    return json({
      ok: false,
      error: "Token missing product_id",
      code: "INVALID_TOKEN",
    }, 401);
  }

  // --- Concurrency guard ---
  const { data: activeRow } = await supabase
    .from("avatar_generations")
    .select("id, status, created_at")
    .eq("user_id", userId)
    .in("status", ["pending", "processing"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (activeRow) {
    const ageSeconds = Math.round(
      (Date.now() - new Date(activeRow.created_at || 0).getTime()) / 1000,
    );
    if (ageSeconds <= timeoutSeconds) {
      console.log(
        `${TAG} ${ts} | reuse active generation=${activeRow.id} age=${ageSeconds}s user=${userId.slice(0, 8)} service=${serviceId ?? "-"} product=${productId}`,
      );
      return json({
        ok: true,
        generation_id: activeRow.id,
        status: "processing",
        reused: true,
        code: "GENERATION_IN_PROGRESS",
        message: "Avatar generation already in progress",
      }, 200);
    }

    console.warn(`${TAG} ${ts} | stale active row ${activeRow.id} age=${ageSeconds}s — failing`);
    await markFailed(supabase, activeRow.id, "GENERATION_TIMEOUT");
  }

  const insertPayload: Record<string, unknown> = {
    user_id: userId,
    status: "pending",
    source_image_url: sourceImageUrl,
    theme,
    event,
    provider: "edge",
    product_id: productId,
  };
  if (serviceId) insertPayload.service_id = serviceId;

  const { data: genRow, error: insertError } = await supabase
    .from("avatar_generations")
    .insert(insertPayload)
    .select("id")
    .maybeSingle();

  if (insertError || !genRow?.id) {
    console.error(`${TAG} ${ts} | insert failed:`, insertError?.message);
    // Race: another insert may have won — try return active row
    const { data: raced } = await supabase
      .from("avatar_generations")
      .select("id, status")
      .eq("user_id", userId)
      .in("status", ["pending", "processing"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (raced?.id) {
      console.log(
        `${TAG} ${ts} | reuse raced generation=${raced.id} user=${userId.slice(0, 8)} service=${serviceId ?? "-"} product=${productId}`,
      );
      return json({
        ok: true,
        generation_id: raced.id,
        status: "processing",
        reused: true,
        code: "GENERATION_IN_PROGRESS",
        message: "Avatar generation already in progress",
      }, 200);
    }
    return json({ ok: false, error: "Failed to start avatar generation", code: "INSERT_FAILED" }, 500);
  }

  const generationId = genRow.id as string;

  await supabase
    .from("avatar_generations")
    .update({ status: "processing", updated_at: new Date().toISOString() })
    .eq("id", generationId);

  const work = runGeneration({
    generationId,
    userId,
    serviceId,
    productId,
    nickname,
    theme,
    event,
    sourceImageUrl,
    model,
    timeoutSeconds,
    instructions,
  });

  try {
    EdgeRuntime.waitUntil(work);
  } catch {
    // Local/dev without EdgeRuntime: still run in background
    work.catch((err) => console.error(`${TAG} background error:`, err));
  }

  console.log(
    `${TAG} ${ts} | started generation=${generationId} user=${userId.slice(0, 8)} service=${serviceId ?? "-"} product=${productId}`,
  );

  return json({
    ok: true,
    generation_id: generationId,
    status: "processing",
    message: "Avatar generation started",
  }, 202);
});
