import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { SmartJourneyClient, SmartJourneyError } from "./smartJourneyClient.ts";
import {
  buildEventData,
  listSupportedEventNames,
  UnknownEventNameError,
} from "./eventTemplates.ts";

// --- CORS ---
const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey, X-User-Token",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// --- Config ---
const SMART_JOURNEY_BASE_URL =
  Deno.env.get("SMART_JOURNEY_BASE_URL") || "https://sj-api-dev.dvtech.io";
const SESAME_LOGIN = Deno.env.get("SESAME_ACCOUNT_LOGIN") || "";
const SESAME_PASSWORD = Deno.env.get("SESAME_ACCOUNT_PASSWORD") || "";
const SESAME_ACCOUNT_ID = Deno.env.get("SESAME_ACCOUNT_ID") || "";
// Fallback when request omits journeyId (query/body)
const DEFAULT_JOURNEY_ID = "34";
// "lambda" (default) = sync push-lambda; "push" = async SQS push
const SMART_JOURNEY_EVENT_MODE = (
  Deno.env.get("SMART_JOURNEY_EVENT_MODE") || "lambda"
).toLowerCase();
const TAG = "[smart-journey]";

function resolveJourneyId(
  url: URL,
  body?: Record<string, unknown>,
): string {
  const fromQuery = url.searchParams.get("journeyId");
  if (fromQuery) return fromQuery;

  if (body) {
    const fromBody = body.journeyId;
    if (fromBody !== undefined && fromBody !== null && fromBody !== "") {
      return String(fromBody);
    }
  }

  return DEFAULT_JOURNEY_ID;
}

// --- SmartJourneyClient Singleton ---
let clientInstance: SmartJourneyClient | null = null;

function getClient(): SmartJourneyClient {
  if (!clientInstance) {
    clientInstance = new SmartJourneyClient({
      baseUrl: SMART_JOURNEY_BASE_URL,
      username: SESAME_LOGIN,
      password: SESAME_PASSWORD,
    });
  }
  return clientInstance;
}

function resolveLang(url: URL): string | undefined {
  const locale = url.searchParams.get("locale");
  if (locale) return locale.replace("-", "_");
  const language = url.searchParams.get("language") || "";
  const country = url.searchParams.get("country") || "";
  if (language && country) return `${language}_${country.toUpperCase()}`;
  if (language) return language;
  return undefined;
}

// --- Extract user token from request ---
function extractUserToken(
  req: Request,
  url: URL,
): string | null {
  const headerToken = req.headers.get("X-User-Token");
  if (headerToken) return headerToken;

  const paramToken = url.searchParams.get("userToken");
  if (paramToken) return paramToken;

  return null;
}

// --- Route Handling ---
Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();

  try {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    const url = new URL(req.url);
    const funcPrefix = "/smart-journey";
    let pathname = url.pathname;
    if (pathname.startsWith(funcPrefix)) {
      pathname = pathname.slice(funcPrefix.length) || "/";
    }

    console.log(`${TAG} ${ts} | ${req.method} ${pathname}`);

    // --- GET / --- Self-description
    if ((pathname === "/" || pathname === "") && req.method === "GET") {
      return json(
        {
          ok: true,
          service: "smart-journey",
          routes: [
            "GET /getConfig",
            "GET /getXp",
            "GET /getXpHistory",
            "GET /getRewards",
            "GET /getRewardDetail",
            "GET /getRewardsCategories",
            "GET /getRewardsHistory",
            "GET /getChallenges",
            "POST /redeemReward",
            "POST /sendEvent",
          ],
        },
        200,
      );
    }

    // --- GET /getConfig ---
    if (pathname === "/getConfig" && req.method === "GET") {
      return json(
        { ok: true, data: { defaultJourneyId: DEFAULT_JOURNEY_ID } },
        200,
      );
    }

    // --- GET /getXp ---
    if (pathname === "/getXp" && req.method === "GET") {
      const userToken = extractUserToken(req, url);
      if (!userToken) {
        return json(
          {
            ok: false,
            error: { message: "Missing user token", code: "AUTH_REQUIRED" },
          },
          401,
        );
      }

      const userRef = userToken;
      const journeyId = resolveJourneyId(url);
      const client = getClient();

      const result = (await client.users.getXp({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        userRef,
      })) as Record<string, unknown>;

      const data = (result?.data as Record<string, unknown>) || {};
      const stock = data.stock ?? 0;

      console.log(
        `${TAG} ${ts} | getXp for ${userRef}: stock=${stock}`,
      );

      return json({ ok: true, data: { stock } }, 200);
    }

    // --- GET /getXpHistory ---
    if (pathname === "/getXpHistory" && req.method === "GET") {
      const userToken = extractUserToken(req, url);
      if (!userToken) {
        return json(
          {
            ok: false,
            error: { message: "Missing user token", code: "AUTH_REQUIRED" },
          },
          401,
        );
      }

      const page = parseInt(url.searchParams.get("page") || "1", 10) || 1;
      const pageSize =
        parseInt(url.searchParams.get("pageSize") || "20", 10) || 20;
      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const userRef = userToken;
      const client = getClient();

      const result = (await client.users.getHistory({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        userRef,
        page,
        pageSize,
        lang,
      })) as Record<string, unknown>;

      const responseData = (result?.data as Record<string, unknown>) || {};
      const history = responseData.history ?? [];
      const pagination = {
        page: responseData.page ?? page,
        page_size: responseData.page_size ?? pageSize,
        page_total: responseData.page_total ?? 0,
        total_elements: responseData.total_elements ?? 0,
      };

      console.log(
        `${TAG} ${ts} | getXpHistory for ${userRef}: ${(history as unknown[]).length} items, page=${pagination.page}/${pagination.page_total}`,
      );

      return json({ ok: true, data: { history, ...pagination } }, 200);
    }

    // --- GET /getRewards ---
    if (pathname === "/getRewards" && req.method === "GET") {
      const page = parseInt(url.searchParams.get("page") || "1", 10) || 1;
      const pageSize =
        parseInt(url.searchParams.get("pageSize") || "20", 10) || 20;
      const categoryIdRaw = url.searchParams.get("categoryId");
      const categoryId = categoryIdRaw ? parseInt(categoryIdRaw, 10) : undefined;
      const maxXpCostRaw = url.searchParams.get("maxXpCost");
      const maxXpCost = maxXpCostRaw !== null && maxXpCostRaw !== ""
        ? parseInt(maxXpCostRaw, 10)
        : undefined;
      const orderXpCostRaw = (url.searchParams.get("orderXpCost") || "").toUpperCase();
      const orderXpCost: "ASC" | "DESC" | undefined =
        orderXpCostRaw === "ASC" || orderXpCostRaw === "DESC"
          ? (orderXpCostRaw as "ASC" | "DESC")
          : undefined;

      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const client = getClient();

      const result = (await client.rewards.getAll({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        categoryId,
        page,
        pageSize,
        lang,
        maxXpCost: Number.isFinite(maxXpCost as number) ? maxXpCost : undefined,
        orderXpCost,
      })) as Record<string, unknown>;

      const responseData = (result?.data as Record<string, unknown>) || {};
      const rewards = responseData.rewards ?? [];
      const pagination = {
        page: responseData.page ?? page,
        page_size: responseData.page_size ?? pageSize,
        page_total: responseData.page_total ?? 0,
        total_elements: responseData.total_elements ?? 0,
      };

      console.log(
        `${TAG} ${ts} | getRewards: page=${pagination.page}, total=${pagination.total_elements}, lang=${lang || "default"}, maxXpCost=${maxXpCost ?? "-"}, orderXpCost=${orderXpCost ?? "-"}`,
      );

      return json({ ok: true, data: { rewards, ...pagination } }, 200);
    }

    // --- GET /getRewardDetail ---
    if (pathname === "/getRewardDetail" && req.method === "GET") {
      const rewardIdRaw = url.searchParams.get("rewardId");
      if (!rewardIdRaw) {
        return json(
          {
            ok: false,
            error: { message: "rewardId is required", code: "BAD_REQUEST" },
          },
          400,
        );
      }

      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const client = getClient();

      const result = (await client.rewards.getDetail({
        sesameaccountId: SESAME_ACCOUNT_ID,
        rewardId: rewardIdRaw,
        journeyId,
        lang,
      })) as Record<string, unknown>;

      const success = result?.success !== false;
      const data = result?.data as Record<string, unknown> | undefined;

      if (!success || !data || (data as Record<string, unknown>).id === undefined) {
        const errors = result?.errors;
        const firstErr = Array.isArray(errors) && errors.length > 0
          ? (errors[0] as Record<string, unknown>)
          : null;
        const message = (firstErr?.message as string) || "Reward not found";
        return json(
          { ok: false, error: { message, code: "NOT_FOUND" } },
          404,
        );
      }

      console.log(
        `${TAG} ${ts} | getRewardDetail: rewardId=${rewardIdRaw}, lang=${lang || "default"}`,
      );

      return json({ ok: true, data }, 200);
    }

    // --- GET /getRewardsCategories ---
    if (pathname === "/getRewardsCategories" && req.method === "GET") {
      const page = parseInt(url.searchParams.get("page") || "1", 10) || 1;
      const pageSize =
        parseInt(url.searchParams.get("pageSize") || "20", 10) || 20;
      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const client = getClient();

      const result = (await client.rewards.getCategories({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        page,
        pageSize,
        lang,
      })) as Record<string, unknown>;

      const responseData = (result?.data as Record<string, unknown>) || {};
      const reward_category = responseData.reward_category ?? [];
      const pagination = {
        page: responseData.page ?? page,
        page_size: responseData.page_size ?? pageSize,
        page_total: responseData.page_total ?? 0,
        total_elements: responseData.total_elements ?? 0,
      };

      console.log(
        `${TAG} ${ts} | getRewardsCategories: ${(reward_category as unknown[]).length} categories, lang=${lang || "default"}`,
      );

      return json({ ok: true, data: { reward_category, ...pagination } }, 200);
    }

    // --- GET /getRewardsHistory ---
    if (pathname === "/getRewardsHistory" && req.method === "GET") {
      const userToken = extractUserToken(req, url);
      if (!userToken) {
        return json(
          {
            ok: false,
            error: { message: "Missing user token", code: "AUTH_REQUIRED" },
          },
          401,
        );
      }

      const page = parseInt(url.searchParams.get("page") || "1", 10) || 1;
      const pageSize =
        parseInt(url.searchParams.get("pageSize") || "20", 10) || 20;
      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const userRef = userToken;
      const client = getClient();

      const historyResult = (await client.users.getRedeems({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        userRef,
        page,
        pageSize,
        lang,
      })) as Record<string, unknown>;

      const historyData = (historyResult?.data as Record<string, unknown>) || {};
      const userRewards = (historyData.user_rewards as Array<Record<string, unknown>>) ?? [];

      // Enrich each history item with reward catalog data
      const rewardIds = [...new Set(userRewards.map((r) => r.reward_id))].filter(Boolean);
      let rewardMap: Map<unknown, Record<string, unknown>> = new Map();

      if (rewardIds.length > 0) {
        try {
          const catalogResult = (await client.rewards.getAll({
            sesameaccountId: SESAME_ACCOUNT_ID,
            journeyId,
            pageSize: 500,
            lang,
          })) as Record<string, unknown>;
          const catalogData = (catalogResult?.data as Record<string, unknown>) || {};
          const catalogRewards = (catalogData.rewards as Array<Record<string, unknown>>) || [];
          for (const reward of catalogRewards) {
            if (reward.id !== undefined) {
              rewardMap.set(reward.id, reward);
            }
          }
        } catch (err) {
          console.warn(`${TAG} ${ts} | Failed to fetch reward catalog for enrichment:`, err);
        }
      }

      const enrichedRewards = userRewards.map((item) => {
        const catalogEntry = rewardMap.get(item.reward_id);
        if (catalogEntry) {
          return { ...item, reward: catalogEntry };
        }
        return item;
      });

      const pagination = {
        page: historyData.page ?? page,
        page_size: historyData.page_size ?? pageSize,
        page_total: historyData.page_total ?? 0,
        total_elements: historyData.total_elements ?? 0,
      };

      console.log(
        `${TAG} ${ts} | getRewardsHistory for ${userRef}: ${enrichedRewards.length} items, enriched=${rewardMap.size} rewards`,
      );

      return json({ ok: true, data: { user_rewards: enrichedRewards, ...pagination } }, 200);
    }

    // --- GET /getChallenges ---
    if (pathname === "/getChallenges" && req.method === "GET") {
      const page = parseInt(url.searchParams.get("page") || "1", 10) || 1;
      const pageSize =
        parseInt(url.searchParams.get("pageSize") || "20", 10) || 20;
      const lang = resolveLang(url);
      const journeyId = resolveJourneyId(url);

      const client = getClient();

      const result = (await client.challenges.getAll({
        sesameaccountId: SESAME_ACCOUNT_ID,
        journeyId,
        page,
        pageSize,
        lang,
      })) as Record<string, unknown>;

      const responseData = (result?.data as Record<string, unknown>) || {};
      const challenges = responseData.challenges ?? [];
      const pagination = {
        page: responseData.page ?? page,
        page_size: responseData.page_size ?? pageSize,
        page_total: responseData.page_total ?? 0,
        total_elements: responseData.total_elements ?? 0,
      };

      console.log(
        `${TAG} ${ts} | getChallenges: ${(challenges as unknown[]).length} challenges, page=${pagination.page}/${pagination.page_total}, lang=${lang || "default"}`,
      );

      return json({ ok: true, data: { challenges, ...pagination } }, 200);
    }

    // --- POST /redeemReward ---
    if (pathname === "/redeemReward" && req.method === "POST") {
      const userToken = extractUserToken(req, url);
      if (!userToken) {
        return json(
          {
            ok: false,
            error: { message: "Missing user token", code: "AUTH_REQUIRED" },
          },
          401,
        );
      }

      let body: Record<string, unknown> = {};
      try {
        body = (await req.json()) as Record<string, unknown>;
      } catch {
        return json(
          {
            ok: false,
            error: { message: "Invalid JSON body", code: "BAD_REQUEST" },
          },
          400,
        );
      }

      const rewardId = body.reward_id;
      if (rewardId === undefined || rewardId === null || rewardId === "") {
        return json(
          {
            ok: false,
            error: { message: "reward_id is required", code: "BAD_REQUEST" },
          },
          400,
        );
      }

      const userRef = userToken;
      const journeyId = resolveJourneyId(url, body);
      const client = getClient();
      const sandbox = url.searchParams.get("sandbox") || undefined;

      const result = (await client.users.redeemRewardFromXp({
        sesameaccountId: SESAME_ACCOUNT_ID,
        userRef,
        rewardId: String(rewardId),
        journeyId,
        sandbox,
      })) as Record<string, unknown>;

      const data = (result?.data as Record<string, unknown>) || {};

      console.log(
        `${TAG} ${ts} | redeemReward for ${userRef}: reward_id=${rewardId}, sandbox=${sandbox || "-"}, newUserRewardId=${data.newUserRewardId}`,
      );

      return json({ ok: true, data }, 200);
    }

    // --- POST /sendEvent ---
    if (pathname === "/sendEvent" && req.method === "POST") {
      const userToken = extractUserToken(req, url);
      if (!userToken) {
        return json(
          {
            ok: false,
            error: { message: "Missing user token", code: "AUTH_REQUIRED" },
          },
          401,
        );
      }

      const eventName = url.searchParams.get("event_name") || "";
      const productId = url.searchParams.get("product_id") || "";
      if (!eventName) {
        return json(
          {
            ok: false,
            error: {
              message: "event_name is required",
              code: "BAD_REQUEST",
              supported_event_names: listSupportedEventNames(),
            },
          },
          400,
        );
      }
      if (!productId) {
        return json(
          {
            ok: false,
            error: { message: "product_id is required", code: "BAD_REQUEST" },
          },
          400,
        );
      }

      let body: Record<string, unknown> = {};
      const rawBody = await req.text();
      if (rawBody && rawBody.trim()) {
        try {
          const parsed = JSON.parse(rawBody) as unknown;
          if (
            parsed !== null &&
            typeof parsed === "object" &&
            !Array.isArray(parsed)
          ) {
            body = parsed as Record<string, unknown>;
          } else {
            return json(
              {
                ok: false,
                error: {
                  message: "JSON body must be an object",
                  code: "BAD_REQUEST",
                },
              },
              400,
            );
          }
        } catch {
          return json(
            {
              ok: false,
              error: { message: "Invalid JSON body", code: "BAD_REQUEST" },
            },
            400,
          );
        }
      }

      let data: Record<string, unknown>;
      try {
        data = buildEventData({
          event_name: eventName,
          product_id: productId,
          user_id: userToken,
          body,
        });
      } catch (err) {
        if (err instanceof UnknownEventNameError) {
          return json(
            {
              ok: false,
              error: {
                message: err.message,
                code: "BAD_REQUEST",
                supported_event_names: err.supported,
              },
            },
            400,
          );
        }
        throw err;
      }

      const client = getClient();
      const useLambda = SMART_JOURNEY_EVENT_MODE !== "push";
      const result = (
        useLambda
          ? await client.events.pushLambda({
            sesameaccountId: SESAME_ACCOUNT_ID,
            data,
          })
          : await client.events.push({
            sesameaccountId: SESAME_ACCOUNT_ID,
            data,
          })
      ) as Record<string, unknown>;

      const responseData = (result?.data as Record<string, unknown>) ?? result;

      console.log(
        `${TAG} ${ts} | sendEvent mode=${useLambda ? "lambda" : "push"} event_name=${eventName} product_id=${productId} user=${userToken}`,
      );

      return json({ ok: true, data: responseData }, 200);
    }

    // --- Not Found ---
    return json(
      { ok: false, error: { message: "Route not found", code: "NOT_FOUND" } },
      404,
    );
  } catch (err) {
    const message =
      err instanceof Error ? err.message : "Internal server error";
    const name = err instanceof Error ? err.constructor.name : "Error";
    console.error(`${TAG} ${ts} | ${name}: ${message}`, err);

    let status = 500;
    let code = "INTERNAL_ERROR";
    if (err instanceof SmartJourneyError) {
      if (err.statusCode === 401) {
        status = 401;
        code = "AUTH_ERROR";
      } else if (err.statusCode === 403) {
        status = 403;
        code = "FORBIDDEN";
      } else if (err.statusCode === 404) {
        status = 404;
        code = "NOT_FOUND";
      } else if (err.statusCode === 429) {
        status = 429;
        code = "RATE_LIMITED";
      }
    }

    return json({ ok: false, error: { message, code } }, status);
  }
});
