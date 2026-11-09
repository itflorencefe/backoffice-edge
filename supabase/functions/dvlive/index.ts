import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  ApiService,
  ApiHttpError,
  ApiRequestError,
  ApiResponseError,
  ApiValidationError,
  ApiModes,
  API_MODES,
  parseMode,
  type ApiModeDefinition,
  type ApiResult,
  type ApiResponse,
} from "@digitalvirgo/dvlive-api";
import { verifyAppJwt } from "../_shared/verify-app-jwt.ts";

const DVLIVE_ENV = Deno.env.get("DVLIVE_ENV") || "";
const DVLIVE_API_TOKEN = Deno.env.get("DVLIVE_API_TOKEN") || "";
const DVLIVE_LOG_ENABLE = Deno.env.get("DVLIVE_LOG_ENABLE");
const DVLIVE_LOG_LEVEL = Deno.env.get("DVLIVE_LOG_LEVEL");
const TAG = `[DVLive][${DVLIVE_ENV || "unset"}]`;

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function json(body: unknown, status: number, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...headers },
  });
}

function ok(data: unknown, status = 200): Response {
  return json({ ok: true, data }, status);
}

function fail(
  status: number,
  message: string,
  code: string,
  details?: unknown,
  headers: Record<string, string> = {},
): Response {
  const error: Record<string, unknown> = { message, code };
  if (details !== undefined) error.details = details;
  return json({ ok: false, error }, status, headers);
}

class InputError extends Error {
  readonly status: number;
  readonly code: string;
  readonly headers: Record<string, string>;

  constructor(
    message: string,
    status = 400,
    code = "VALIDATION",
    headers: Record<string, string> = {},
  ) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

async function parseRequestBody(req: Request, action: ApiModeDefinition, mode: ApiModes): Promise<unknown> {
  if (req.method !== action.method) {
    throw new InputError(
      `Mode ${mode} requires ${action.method}.`,
      405,
      "METHOD_NOT_ALLOWED",
      { Allow: `${action.method}, OPTIONS` },
    );
  }
  if (action.method !== "POST") return undefined;
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers.get("content-type") ?? "")) {
    throw new InputError("The request body must use application/json.", 415, "INVALID_JSON");
  }
  try {
    return await req.json();
  } catch {
    throw new InputError("Invalid JSON body.", 400, "INVALID_JSON");
  }
}

function callApi(
  api: ApiService,
  mode: ApiModes,
  query: URLSearchParams,
  body: unknown,
  userRef: string,
): Promise<ApiResponse<ApiResult>> {
  const uuid = query.get("uuid") ?? "";
  const showVoteUuid = query.get("showVoteUuid") ?? "";

  switch (mode) {
    case ApiModes.GetShowVote:
      return api.getShowVote(uuid);
    case ApiModes.GetShowVoteChoice:
      return api.getShowVoteChoice(uuid);
    case ApiModes.GetVoter:
      return api.getVoter({ showVoteUuid, userRef });
    case ApiModes.CreateVoter:
      return api.createVoter(
        { showVoteUuid },
        body && typeof body === "object" && !Array.isArray(body)
          ? { ...body, uniqRef: userRef }
          : { uniqRef: userRef },
      );
    case ApiModes.CastVote:
      return api.castVote({ showVoteUuid, userRef }, body);
    default: {
      const unsupported: ApiModes = mode;
      throw new InputError(`Unsupported mode: ${unsupported}.`, 400, "VALIDATION");
    }
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const parsed = parseMode(url.searchParams.get("mode"));
    if (parsed.mode === null) {
      console.log(`${TAG} ${ts} | catalog`);
      return ok(parsed.catalog);
    }

    const mode = parsed.mode;
    const action = API_MODES[mode];
    const body = await parseRequestBody(req, action, mode);

    const auth = await verifyAppJwt(req);
    if (!auth.ok) {
      console.log(`${TAG} ${ts} | auth failed mode=${mode} status=${auth.status}`);
      return fail(auth.status, auth.message, auth.status === 403 ? "FORBIDDEN" : "AUTH_REQUIRED");
    }

    const needsUser =
      mode === ApiModes.GetVoter ||
      mode === ApiModes.CreateVoter ||
      mode === ApiModes.CastVote;
    const userRef = auth.claims.absolute_reference?.trim() ?? "";
    if (needsUser && !userRef) {
      return fail(403, "Missing absolute_reference claim.", "FORBIDDEN");
    }

    if (!DVLIVE_API_TOKEN || !DVLIVE_ENV) {
      console.error(`${TAG} ${ts} | missing DVLIVE_API_TOKEN or DVLIVE_ENV`);
      return fail(500, "DVLive is not configured.", "SERVER_MISCONFIGURED");
    }

    let api: ApiService;
    try {
      api = new ApiService({
        environment: DVLIVE_ENV,
        logEnable: DVLIVE_LOG_ENABLE,
        logLevel: DVLIVE_LOG_LEVEL,
        headers: () => ({ Authorization: `Bearer ${DVLIVE_API_TOKEN}` }),
      });
    } catch (err) {
      console.error(`${TAG} ${ts} | invalid SDK config:`, err instanceof Error ? err.message : err);
      return fail(500, "Invalid DVLive SDK configuration.", "SERVER_MISCONFIGURED");
    }

    console.log(
      `${TAG} ${ts} | mode=${mode}${needsUser ? ` user=${userRef.slice(0, 4)}***` : ""}`,
    );
    const result = await callApi(api, mode, url.searchParams, body, userRef);
    return ok(result.data, result.status);
  } catch (err) {
    if (err instanceof InputError) {
      return fail(err.status, err.message, err.code, undefined, err.headers);
    }
    if (err instanceof ApiValidationError) {
      return fail(400, err.message, "VALIDATION");
    }
    if (err instanceof ApiHttpError) {
      if (err.document !== undefined) {
        return fail(err.status, "DV Live upstream error.", "UPSTREAM_ERROR", err.document);
      }
      return fail(err.status, err.bodyText || "DV Live upstream error.", "UPSTREAM_ERROR");
    }
    if (err instanceof ApiRequestError) {
      return fail(
        err.kind === "timeout" ? 504 : 502,
        err.message,
        err.kind === "timeout" ? "UPSTREAM_TIMEOUT" : "UPSTREAM_ERROR",
      );
    }
    if (err instanceof ApiResponseError) {
      return fail(502, err.message, "UPSTREAM_ERROR");
    }
    console.error(`${TAG} ${ts} | unexpected:`, err instanceof Error ? err.message : err);
    return fail(500, "Internal DVLive error.", "INTERNAL_ERROR");
  }
});
