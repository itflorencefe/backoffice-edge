import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { PulsarClient } from "@digitalvirgo/galaxy-pulsar-sdk";

// --- CORS ---
const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// --- Pulsar Environment URL Matrix ---
const PULSAR_URLS: Record<string, Record<string, string>> = {
  DEV: {
    PREVIEW: "https://pulsar-preview.dev.galaxydve.com",
    ONLINE: "https://pulsar.dev.galaxydve.com",
  },
  STAGE: {
    PREVIEW: "https://pulsar-preview.pp.galaxydve.com",
    ONLINE: "https://pulsar.pp.galaxydve.com",
  },
  PROD: {
    PREVIEW: "https://pulsar-preview.galaxydve.com",
    ONLINE: "https://pulsar.galaxydve.com",
  },
};

// --- Config ---
const PULSAR_ENV = Deno.env.get("PULSAR_ENV") || "DEV";
const PULSAR_MODE = Deno.env.get("PULSAR_MODE") || "PREVIEW";
const SESAME_LOGIN = Deno.env.get("SESAME_ACCOUNT_LOGIN") || "winfinity_client";
const SESAME_PASSWORD = Deno.env.get("SESAME_ACCOUNT_PASSWORD") || "!7pef1!L55xT";
const DEFAULT_COUNTRY = Deno.env.get("PULSAR_DEFAULT_COUNTRY") || "FR";
const DEFAULT_LOCALE = Deno.env.get("PULSAR_DEFAULT_LOCALE") || "fr-FR";
const DEFAULT_VIDEO_QUIZ_SECTION_REF = Deno.env.get("PULSAR_DEFAULT_VIDEO_QUIZ_SECTION_REF") || "videos_quizzes";
const DEFAULT_CLASSIC_QUIZ_PAGE_REF = Deno.env.get("PULSAR_DEFAULT_CLASSIC_QUIZ_PAGE_REF") || "classic_quiz";

const TAG = `[Pulsar][${PULSAR_ENV}][${PULSAR_MODE}]`;

// --- PulsarClient Factory with Caching ---
const clientCache = new Map<string, PulsarClient>();

function getPulsarClient(country?: string, locale?: string): PulsarClient {
  const c = country || DEFAULT_COUNTRY;
  const l = locale || DEFAULT_LOCALE;
  const key = `${PULSAR_ENV}|${PULSAR_MODE}|${c}|${l}`;

  const cached = clientCache.get(key);
  if (cached) return cached;

  const baseUrl = PULSAR_URLS[PULSAR_ENV]?.[PULSAR_MODE];
  if (!baseUrl) {
    throw new Error(`Invalid PULSAR_ENV=${PULSAR_ENV} or PULSAR_MODE=${PULSAR_MODE}`);
  }

  const client = new PulsarClient({
    baseUrl,
    country: c,
    locale: l,
    username: SESAME_LOGIN,
    password: SESAME_PASSWORD,
  });

  clientCache.set(key, client);
  return client;
}

// --- Typed SDK helpers ---
//
// Used by POST /instant-game/:id/play only. The galaxy-pulsar-sdk exposes
// `client.ig.getPrize(igId, params)` as TWO positional arguments.
async function igGetPrize(client: PulsarClient, igId: number, userRef: string): Promise<unknown> {
  return await client.ig.getPrize(igId, { user_ref: userRef });
}

function maskUserRef(ref: string | undefined | null): string {
  if (!ref) return "<none>";
  return ref.length <= 8 ? ref : `${ref.slice(0, 4)}***${ref.slice(-4)}`;
}

// --- Unwrap Pulsar SDK response envelope ---
function unwrap<T>(response: unknown): T[] {
  if (!response || typeof response !== "object") return [];

  const r = response as Record<string, unknown>;

  if (Array.isArray(r)) return r as T[];

  if (Array.isArray(r.payload)) {
    return (r.payload as Array<Record<string, unknown>>).map((entry) => {
      if (entry.item && typeof entry.item === "object") return entry.item as T;
      return entry as unknown as T;
    });
  }

  if (Array.isArray(r.data)) return r.data as T[];
  if (Array.isArray(r.items)) return r.items as T[];
  if (r.id !== undefined) return [r as unknown as T];

  return [];
}

// --- Route Handling ---
Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();

  try {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    const url = new URL(req.url);
    const funcPrefix = "/pulsar";
    let pathname = url.pathname;
    if (pathname.startsWith(funcPrefix)) {
      pathname = pathname.slice(funcPrefix.length) || "/";
    }

    console.log(`${TAG} ${ts} | ${req.method} ${pathname}`);

    const country = url.searchParams.get("country") || DEFAULT_COUNTRY;
    const language = url.searchParams.get("language") || DEFAULT_LOCALE.split(/[-_]/)[0];
    const locale = url.searchParams.get("locale") || `${language}-${country}`;

    const userToken = url.searchParams.get("userToken");

    let body: Record<string, unknown> | undefined;
    if (req.method === "POST") {
      try {
        body = await req.json();
      } catch {
        // acceptable for routes that don't need a body
      }
    }

    // --- GET / --- Self-description
    if ((pathname === "/" || pathname === "") && req.method === "GET") {
      return json({
        ok: true,
        service: "pulsar",
        version: "4.1.0",
        pulsar_env: PULSAR_ENV,
        pulsar_mode: PULSAR_MODE,
        routes: [
          "GET /instant-games",
          "GET /instant-game/:id",
          "POST /instant-game/:id/play",
          "GET /videos-quizzes",
          "GET /classic-quiz/categories",
          "GET /classic-quiz/:reference/quizzes",
          "GET /sections/:reference",
          "GET /quizzes/:id",
          "POST /quizzes/:id/start",
          "POST /attempts/:attemptId/answer",
          "GET /quiz-categories [DEPRECATED]",
          "GET /quizzes?category_id=<int> [DEPRECATED]",
        ],
      }, 200);
    }

    // --- GET /classic-quiz/categories --- (uses pages.sections)
    if (pathname === "/classic-quiz/categories" && req.method === "GET") {
      const pageReference = url.searchParams.get("page_reference") || DEFAULT_CLASSIC_QUIZ_PAGE_REF;
      const limit = parseInt(url.searchParams.get("limit") || "200", 10);
      const offset = parseInt(url.searchParams.get("offset") || "1", 10);
      const sort = url.searchParams.get("sort") || undefined;

      const client = getPulsarClient(country, locale);
      const rawResponse = await client.pages.sections(pageReference, { limit, offset, sort }) as Record<string, unknown>;
      const nbItems = (rawResponse.nb_items as number) ?? 0;
      const payload = (rawResponse.payload as Array<Record<string, unknown>>) ?? [];

      const mapped = payload.map((entry) => {
        const item = (entry.item as Record<string, unknown>) ?? {};
        const covers = (item.covers as string[]) ?? [];
        return {
          id: item.id,
          title: item.title ?? null,
          description: item.description ?? null,
          image_url: covers[0] ?? null,
          reference: item.reference ?? null,
        };
      });

      console.log(`${TAG} ${ts} | classic-quiz/categories fetched (page=${pageReference}): ${mapped.length} items`);

      return json({ ok: true, nb_items: nbItems, data: mapped }, 200);
    }

    // --- GET /classic-quiz/:reference/quizzes --- (uses sections.items)
    const classicQuizMatch = pathname.match(/^\/classic-quiz\/([^/]+)\/quizzes$/);
    if (classicQuizMatch && req.method === "GET") {
      const reference = decodeURIComponent(classicQuizMatch[1]);
      const limit = parseInt(url.searchParams.get("limit") || "200", 10);
      const offset = parseInt(url.searchParams.get("offset") || "1", 10);
      const sort = url.searchParams.get("sort") || undefined;

      const client = getPulsarClient(country, locale);
      const rawResponse = await client.sections.items(reference, { limit, offset, sort }) as Record<string, unknown>;
      const nbItems = (rawResponse.nb_items as number) ?? 0;
      const payload = (rawResponse.payload as Array<Record<string, unknown>>) ?? [];

      const quizEntries = payload.filter((entry) => entry.item_type === "quiz");

      const mapped = quizEntries.map((entry) => {
        const q = (entry.item as Record<string, unknown>) ?? {};
        const type = q.type as Record<string, unknown> | undefined;
        return {
          id: q.id,
          title: q.title,
          description: q.description ?? null,
          difficulty: q.difficulty ?? null,
          total_questions: q.total_questions ?? null,
          time_limit_seconds: q.time_limit_seconds ?? null,
          passing_score_percentage: q.passing_score_percentage ?? null,
          type: type ?? null,
          type_id: type?.id ?? null,
          covers: q.covers ?? [],
        };
      });

      console.log(`${TAG} ${ts} | classic-quiz/${reference}/quizzes fetched: ${mapped.length} items`);

      return json({ ok: true, nb_items: nbItems, data: mapped }, 200);
    }

    // [DEPRECATED] Kept for backward compatibility
    // --- GET /quiz-categories ---
    if (pathname === "/quiz-categories" && req.method === "GET") {
      const client = getPulsarClient(country, locale);
      const rawResponse = await client.quizzes.categories();
      const categories = unwrap<Record<string, unknown>>(rawResponse);

      // Reference: QuizCategory { id, name, description?, icon_url? }
      const mapped = categories.map((c) => ({
        id: c.id,
        title: c.name ?? null,
        description: c.description ?? null,
        image_url: c.icon_url ?? null,
      }));

      console.log(`${TAG} ${ts} | quiz-categories fetched: ${mapped.length} items`);

      return json({ ok: true, data: mapped }, 200);
    }

    // [DEPRECATED] Kept for backward compatibility
    // --- GET /quizzes ---
    if (pathname === "/quizzes" && req.method === "GET") {
      const categoryId = url.searchParams.get("category_id");
      if (!categoryId) {
        return json({ ok: false, error: { message: "Missing category_id query param", code: "MISSING_PARAM" } }, 400);
      }

      const client = getPulsarClient(country, locale);
      const params: Record<string, unknown> = { category_id: parseInt(categoryId, 10) };
      const rawResponse = await client.quizzes.list(params);
      const quizzes = unwrap<Record<string, unknown>>(rawResponse);

      // Reference: QuizItem { id, title, description?, covers, difficulty,
      // type: QuizType, total_questions, time_limit_seconds?, passing_score_percentage }
      const mapped = quizzes.map((q: Record<string, unknown>) => {
        const type = q.type as Record<string, unknown> | undefined;
        return {
          id: q.id,
          title: q.title,
          description: q.description ?? null,
          difficulty: q.difficulty ?? null,
          total_questions: q.total_questions ?? null,
          time_limit_seconds: q.time_limit_seconds ?? null,
          passing_score_percentage: q.passing_score_percentage ?? null,
          type: type ?? null,
          type_id: type?.id ?? null,
          covers: q.covers ?? [],
        };
      });

      console.log(`${TAG} ${ts} | quizzes fetched for category ${categoryId}: ${mapped.length} items`);

      return json({ ok: true, data: mapped }, 200);
    }

    // --- GET /sections/:reference --- (uses client.sections.get)
    const sectionDetailMatch = pathname.match(/^\/sections\/([^/]+)$/);
    if (sectionDetailMatch && req.method === "GET") {
      const reference = decodeURIComponent(sectionDetailMatch[1]);
      const client = getPulsarClient(country, locale);

      const rawResponse = await client.sections.get(reference) as Record<string, unknown>;
      const payload = (rawResponse.payload as Array<Record<string, unknown>> | undefined) ?? [];
      const entry = payload[0];

      if (!entry) {
        return json({ ok: false, error: { message: `Section "${reference}" not found`, code: "NOT_FOUND" } }, 404);
      }

      const item = (entry.item as Record<string, unknown>) ?? entry;
      const covers = (item.covers as string[]) ?? [];

      const data = {
        id: item.id,
        name: item.name ?? null,
        reference: item.reference ?? reference,
        title: item.title ?? null,
        description: item.description ?? null,
        covers,
        display_order: item.display_order ?? null,
      };

      console.log(`${TAG} ${ts} | section/${reference} fetched: id=${data.id}, title=${data.title}`);

      return json({ ok: true, data }, 200);
    }

    // --- GET /quizzes/:id --- (uses client.quizzes.get directly)
    const quizDetailMatch = pathname.match(/^\/quizzes\/(\d+)$/);
    if (quizDetailMatch && req.method === "GET") {
      const quizId = parseInt(quizDetailMatch[1], 10);
      const client = getPulsarClient(country, locale);

      const rawResponse = await client.quizzes.get(quizId) as Record<string, unknown>;
      const payload = (rawResponse.payload as Array<Record<string, unknown>> | undefined) ?? [];
      const entry = payload[0];

      if (!entry) {
        return json({ ok: false, error: { message: `Quiz ${quizId} not found`, code: "NOT_FOUND" } }, 404);
      }

      const raw = (entry.item as Record<string, unknown>) ?? entry;
      const type = raw.type as Record<string, unknown> | undefined;

      const detail = {
        id: raw.id,
        title: raw.title,
        description: raw.description ?? null,
        difficulty: raw.difficulty ?? null,
        total_questions: raw.total_questions ?? null,
        time_limit_seconds: raw.time_limit_seconds ?? null,
        passing_score_percentage: raw.passing_score_percentage ?? null,
        type: type ?? null,
        type_id: type?.id ?? null,
        covers: raw.covers ?? [],
      };

      console.log(`${TAG} ${ts} | quiz detail fetched: ${quizId}`);

      return json({ ok: true, data: detail }, 200);
    }

    // --- GET /instant-games ---
    if (pathname === "/instant-games" && req.method === "GET") {
      const client = getPulsarClient(country, locale);

      // Reference: IgListParams { type?, offset?, limit? }
      const params: Record<string, unknown> = {};
      const limit = url.searchParams.get("limit");
      const offset = url.searchParams.get("offset");
      const type = url.searchParams.get("type");

      if (limit) params.limit = parseInt(limit, 10);
      if (offset) params.offset = parseInt(offset, 10);
      if (type) params.type = parseInt(type, 10);

      const rawResponse = await client.ig.list(params);
      const items = unwrap<Record<string, unknown>>(rawResponse);

      // Reference: IgItem { id, title, description?, covers, type: IgType }
      const mapped = items.map((it) => ({
        id: it.id,
        title: it.title ?? null,
        description: it.description ?? null,
        covers: it.covers ?? [],
        type: it.type ?? null,
      }));

      console.log(`${TAG} ${ts} | instant-games fetched: ${mapped.length} items`);

      return json({ ok: true, data: mapped }, 200);
    }

    // --- GET /videos-quizzes ---
    if (pathname === "/videos-quizzes" && req.method === "GET") {
      const sectionReference = url.searchParams.get("sectionReference") || DEFAULT_VIDEO_QUIZ_SECTION_REF;
      if (!sectionReference) {
        return json({
          ok: false,
          error: { message: "Missing sectionReference param and PULSAR_DEFAULT_VIDEO_QUIZ_SECTION_REF is not configured", code: "SERVER_ERROR" },
        }, 500);
      }

      const client = getPulsarClient(country, locale);

      const limit = parseInt(url.searchParams.get("limit") || "200", 10);
      const offset = parseInt(url.searchParams.get("offset") || "1", 10);

      // Reference: section items return SectionItem (heterogeneous union -
      // ContentItem | ArtistItem | QuizItem | IgItem | EditorialPlaylistResponse | SectionResponse).
      // The video-quizzes section is curated to contain only video-content items,
      // so we map fields shaped like ContentItem/QuizItem and ignore unrelated entries.
      const rawResponse = await client.sections.items(sectionReference, { limit, offset });
      const r = rawResponse as Record<string, unknown>;
      const payload = (r.payload as Array<Record<string, unknown>> | undefined) ?? [];

      const VIDEO_LIKE_ITEM_TYPES = new Set([
        "video",
        "movie",
        "series_episode",
        "music_video_track",
        "quiz",
        "video_quiz",
      ]);

      const mapped = payload
        .filter((entry) => {
          const t = entry.item_type;
          if (!t || typeof t !== "string") return true; // be lenient when missing
          return VIDEO_LIKE_ITEM_TYPES.has(t);
        })
        .map((entry) => {
          const item = (entry.item as Record<string, unknown>) ?? {};
          const trailers = item.trailers as Array<Record<string, unknown>> | undefined;
          const deliveries = item.deliveries as Array<Record<string, unknown>> | undefined;
          const trailerUrl = trailers?.[0]?.url || deliveries?.[0]?.url || null;

          return {
            id: item.item_id ?? item.id,
            title: item.title ?? null,
            description: item.description ?? null,
            covers: item.covers ?? [],
            trailer_url: trailerUrl,
            total_questions: item.total_questions ?? null,
            difficulty: item.difficulty ?? null,
          };
        });

      console.log(`${TAG} ${ts} | videos-quizzes fetched (section=${sectionReference}): ${mapped.length} items`);

      return json({ ok: true, data: mapped, available: mapped.length > 0 }, 200);
    }

    // --- GET /instant-game/:id --- (uses client.ig.get — read-only, no prize draw)
    const detailMatch = pathname.match(/^\/instant-game\/(\d+)$/);
    if (detailMatch && req.method === "GET") {
      const igId = parseInt(detailMatch[1], 10);

      const client = getPulsarClient(country, locale);
      console.log(`${TAG} ${ts} | calling ig.get(igId=${igId}, country=${country}, locale=${locale})`);
      const rawResponse = await client.ig.get(igId) as Record<string, unknown>;

      const payload = rawResponse.payload as Array<Record<string, unknown>> | undefined;
      const item = payload?.[0]?.item as Record<string, unknown> | undefined;

      if (!item) {
        return json({ ok: false, error: { message: `Instant game ${igId} not found`, code: "NOT_FOUND" } }, 404);
      }

      const prizes = (item.prizes ?? []) as unknown[];

      console.log(`${TAG} ${ts} | instant-game ${igId} prizes fetched: ${prizes.length} prizes`);

      return json({ ok: true, data: prizes }, 200);
    }

    // --- POST /instant-game/:id/play ---
    const playMatch = pathname.match(/^\/instant-game\/(\d+)\/play$/);
    if (playMatch && req.method === "POST") {
      const igId = parseInt(playMatch[1], 10);

      if (!userToken) {
        return json({ ok: false, error: { message: "Missing userToken query parameter", code: "AUTH_REQUIRED" } }, 401);
      }

      const client = getPulsarClient(country, locale);
      console.log(`${TAG} ${ts} | calling ig.getPrize(igId=${igId}, user_ref=${maskUserRef(userToken)}, country=${country}, locale=${locale})`);
      const rawResponse = await igGetPrize(client, igId, userToken);

      const r = rawResponse as Record<string, unknown>;
      const payload = r.payload as Array<Record<string, unknown>> | undefined;
      const item = payload?.[0]?.item as Record<string, unknown> | undefined;

      const prizes = item?.prizes || [];
      const smartjourneyEvent = item?.smartjourney_event || null;

      console.log(`${TAG} ${ts} | instant-game ${igId} played by ${maskUserRef(userToken)}: ${(prizes as unknown[]).length} prizes, sj_event=${!!smartjourneyEvent}`);

      return json({ ok: true, data: { prizes, smartjourney_event: smartjourneyEvent } }, 200);
    }

    // --- POST /quizzes/:id/start ---
    const startMatch = pathname.match(/^\/quizzes\/(\d+)\/start$/);
    if (startMatch && req.method === "POST") {
      const quizId = parseInt(startMatch[1], 10);

      if (!userToken) {
        return json({ ok: false, error: { message: "Missing userToken query parameter", code: "AUTH_REQUIRED" } }, 401);
      }

      const client = getPulsarClient(country, locale);
      const rawResponse = await client.quizzes.startAttempt(quizId, { user_ref: userToken });

      const items = unwrap<Record<string, unknown>>(rawResponse);
      const item = items[0] || {};

      const data = {
        attempt_id: item.attempt_id,
        question: item.question,
      };

      console.log(`${TAG} ${ts} | quiz ${quizId} attempt started for ${maskUserRef(userToken)}: attempt_id=${data.attempt_id}`);

      return json({ ok: true, data }, 200);
    }

    // --- POST /attempts/:attemptId/answer ---
    const answerMatch = pathname.match(/^\/attempts\/(\d+)\/answer$/);
    if (answerMatch && req.method === "POST") {
      const attemptId = parseInt(answerMatch[1], 10);

      if (!userToken) {
        return json({ ok: false, error: { message: "Missing userToken query parameter", code: "AUTH_REQUIRED" } }, 401);
      }

      const questionId = body?.question_id as number | undefined;
      const optionId = body?.option_id as number | undefined;
      if (!questionId || !optionId) {
        return json({ ok: false, error: { message: "Missing question_id or option_id in body", code: "MISSING_PARAM" } }, 400);
      }

      const client = getPulsarClient(country, locale);
      const rawResponse = await client.quizzes.submitAnswer(attemptId, {
        question_id: questionId,
        option_id: optionId,
        user_ref: userToken,
      });

      const items = unwrap<Record<string, unknown>>(rawResponse);
      const item = items[0] || {};

      const data: Record<string, unknown> = {
        is_correct: item.is_correct,
        correct_option_id: item.correct_option_id,
      };

      if (item.next_question) {
        data.next_question = item.next_question;
      }
      if (item.result) {
        data.result = item.result;
      }
      if (item.smartjourney_event) {
        data.smartjourney_event = item.smartjourney_event;
      }

      console.log(`${TAG} ${ts} | attempt ${attemptId} answer: correct=${item.is_correct}, has_next=${!!item.next_question}, has_result=${!!item.result}`);

      return json({ ok: true, data }, 200);
    }

    // --- Not Found ---
    return json({ ok: false, error: { message: "Route not found", code: "NOT_FOUND" } }, 404);

  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal server error";
    const name = err instanceof Error ? err.constructor.name : "Error";

    // Re-derive request context for the error log so a stack trace alone is
    // never the only signal we have on a regression.
    let ctx = "";
    try {
      const u = new URL(req.url);
      let p = u.pathname;
      if (p.startsWith("/pulsar")) p = p.slice("/pulsar".length) || "/";
      const c = u.searchParams.get("country") || DEFAULT_COUNTRY;
      const lang = u.searchParams.get("language") || DEFAULT_LOCALE.split(/[-_]/)[0];
      const loc = u.searchParams.get("locale") || `${lang}-${c}`;
      ctx = ` route=${req.method} ${p} country=${c} locale=${loc}`;
    } catch {
      ctx = ` (failed to derive request context)`;
    }

    const errRecord = err as Record<string, unknown> | null;
    const sdkStatus = errRecord && typeof errRecord === "object" ? errRecord.statusCode : undefined;
    const sdkErrorCode = errRecord && typeof errRecord === "object" ? errRecord.errorCode : undefined;
    console.error(`${TAG} ${ts} | ${name}: ${message}${ctx} sdkStatus=${sdkStatus ?? "-"} sdkErrorCode=${sdkErrorCode ?? "-"}`, err);

    let status = 500;
    let code = "INTERNAL_ERROR";
    if (name === "PulsarAuthError") { status = 401; code = "AUTH_ERROR"; }
    else if (name === "PulsarForbiddenError") { status = 403; code = "FORBIDDEN"; }
    else if (name === "PulsarNotFoundError") { status = 404; code = "NOT_FOUND"; }
    else if (name === "PulsarRateLimitError") { status = 429; code = "RATE_LIMITED"; }

    return json({ ok: false, error: { message, code } }, status);
  }
});
