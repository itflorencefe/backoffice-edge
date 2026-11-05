/**
 * Minimal SmartJourney API client (Deno-compatible TypeScript).
 *
 * Wraps the documented endpoints (https://sj-api-dev.dvtech.io/swagger) behind
 * a small object-per-resource surface:
 *
 *   client.users.getXp({ sesameaccountId, journeyId, userRef })
 *
 * Authentication is HTTP Basic via btoa().
 */

interface ErrorMeta {
  statusCode?: number;
  statusText?: string;
  errorCode?: string;
  body?: unknown;
  method?: string;
  url?: string;
  retryAfter?: string | null;
}

interface ClientOptions {
  baseUrl: string;
  username?: string;
  password?: string;
}

interface RequestOptions {
  query?: Record<string, string | number | undefined | null>;
  body?: unknown;
  headers?: Record<string, string>;
}

interface UserParams {
  sesameaccountId: string;
  journeyId: string | number;
  userRef: string;
  page?: number;
  pageSize?: number;
  lang?: string;
}

interface RedeemParams {
  sesameaccountId: string;
  userRef: string;
  rewardId: string | number;
  journeyId?: string | number;
  page?: number;
  pageSize?: number;
  sandbox?: string;
}

interface RewardAllParams {
  sesameaccountId: string;
  journeyId: string | number;
  categoryId?: number;
  page?: number;
  pageSize?: number;
  lang?: string;
  maxXpCost?: number;
  orderXpCost?: "ASC" | "DESC";
}

interface RewardDetailParams {
  sesameaccountId: string;
  rewardId: string | number;
  journeyId: string | number;
  lang?: string;
}

interface RewardCategoryParams {
  sesameaccountId: string;
  journeyId: string | number;
  page?: number;
  pageSize?: number;
  lang?: string;
}

interface RewardHistoryParams {
  sesameaccountId: string;
  journeyId: string | number;
  userRef: string;
  page?: number;
  pageSize?: number;
  lang?: string;
}

interface ChallengeAllParams {
  sesameaccountId: string;
  journeyId: string | number;
  page?: number;
  pageSize?: number;
  lang?: string;
}

interface EventPushParams {
  sesameaccountId: string;
  data?: unknown;
  body?: unknown;
}

export class SmartJourneyError extends Error {
  statusCode?: number;
  statusText?: string;
  errorCode?: string;
  body?: unknown;
  method?: string;
  url?: string;

  constructor(message: string, opts: ErrorMeta = {}) {
    super(message);
    this.name = "SmartJourneyError";
    this.statusCode = opts.statusCode;
    this.statusText = opts.statusText;
    this.errorCode = opts.errorCode;
    this.body = opts.body;
    this.method = opts.method;
    this.url = opts.url;
  }
}

export class SmartJourneyAuthError extends SmartJourneyError {
  constructor(message: string, opts: ErrorMeta = {}) {
    super(message, opts);
    this.name = "SmartJourneyAuthError";
  }
}

export class SmartJourneyForbiddenError extends SmartJourneyError {
  constructor(message: string, opts: ErrorMeta = {}) {
    super(message, opts);
    this.name = "SmartJourneyForbiddenError";
  }
}

export class SmartJourneyNotFoundError extends SmartJourneyError {
  constructor(message: string, opts: ErrorMeta = {}) {
    super(message, opts);
    this.name = "SmartJourneyNotFoundError";
  }
}

export class SmartJourneyRateLimitError extends SmartJourneyError {
  retryAfter?: string | null;

  constructor(message: string, opts: ErrorMeta = {}) {
    super(message, opts);
    this.name = "SmartJourneyRateLimitError";
    this.retryAfter = opts.retryAfter;
  }
}

export class SmartJourneyClient {
  private baseUrl: string;
  private authHeader: string | null;

  users: {
    getXp: (params: UserParams) => Promise<unknown>;
    getHistory: (params: UserParams) => Promise<unknown>;
    getSuccessLine: (params: UserParams) => Promise<unknown>;
    getRedeems: (params: RewardHistoryParams) => Promise<unknown>;
    redeemRewardFromXp: (params: RedeemParams) => Promise<unknown>;
  };

  rewards: {
    getAll: (params: RewardAllParams) => Promise<unknown>;
    getDetail: (params: RewardDetailParams) => Promise<unknown>;
    getCategories: (params: RewardCategoryParams) => Promise<unknown>;
  };

  challenges: {
    getAll: (params: ChallengeAllParams) => Promise<unknown>;
  };

  events: {
    push: (params: EventPushParams) => Promise<unknown>;
    pushLambda: (params: EventPushParams) => Promise<unknown>;
  };

  constructor({ baseUrl, username, password }: ClientOptions) {
    if (!baseUrl || typeof baseUrl !== "string") {
      throw new Error("SmartJourneyClient: baseUrl is required");
    }
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    const user = username || "";
    const pass = password || "";
    this.authHeader =
      user && pass ? "Basic " + btoa(`${user}:${pass}`) : null;

    const userPostJson =
      (label: string, urlPath: string, extra = false) =>
      (params: UserParams) => {
        const { sesameaccountId, journeyId, userRef, page, pageSize, lang } =
          params;
        if (!sesameaccountId) {
          throw new Error(`users.${label}: sesameaccountId is required`);
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error(`users.${label}: journeyId is required`);
        }
        if (!userRef) {
          throw new Error(`users.${label}: userRef is required`);
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
          user_ref: userRef,
        };
        if (extra) {
          if (page !== undefined) query.p = page;
          if (pageSize !== undefined) query.l = pageSize;
          if (lang !== undefined) query.lang = lang;
        }
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/user/${urlPath}`,
          { query },
        );
      };

    this.users = {
      getXp: userPostJson("getXp", "getxp.json"),
      getHistory: userPostJson("getHistory", "gethistory.json", true),
      getSuccessLine: userPostJson(
        "getSuccessLine",
        "getsuccessline.json",
        true,
      ),
      getRedeems: (params: RewardHistoryParams) => {
        const { sesameaccountId, journeyId, userRef, page, pageSize, lang } =
          params;
        if (!sesameaccountId) {
          throw new Error("users.getRedeems: sesameaccountId is required");
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error("users.getRedeems: journeyId is required");
        }
        if (!userRef) {
          throw new Error("users.getRedeems: userRef is required");
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
          user_ref: userRef,
        };
        if (page !== undefined) query.p = page;
        if (pageSize !== undefined) query.l = pageSize;
        if (lang) query.lang = lang;
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/user/gettheredeems.json`,
          { query },
        );
      },
      redeemRewardFromXp: (params: RedeemParams) => {
        const { sesameaccountId, userRef, rewardId, journeyId, page, pageSize, sandbox } =
          params;
        if (!sesameaccountId) {
          throw new Error(
            "users.redeemRewardFromXp: sesameaccountId is required",
          );
        }
        if (!userRef) {
          throw new Error("users.redeemRewardFromXp: userRef is required");
        }
        if (
          rewardId === undefined ||
          rewardId === null ||
          rewardId === ""
        ) {
          throw new Error("users.redeemRewardFromXp: rewardId is required");
        }
        const query: Record<string, string | number> = {
          user_ref: userRef,
          reward_id: rewardId,
        };
        if (
          journeyId !== undefined &&
          journeyId !== null &&
          journeyId !== ""
        ) {
          query.journey_id = journeyId;
        }
        if (page !== undefined) query.p = page;
        if (pageSize !== undefined) query.l = pageSize;
        if (sandbox) query.sandbox = sandbox;
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/user/redeemrewardfromxp.json`,
          { query },
        );
      },
    };

    this.rewards = {
      getAll: (params: RewardAllParams) => {
        const {
          sesameaccountId,
          journeyId,
          categoryId,
          page,
          pageSize,
          lang,
          maxXpCost,
          orderXpCost,
        } = params;
        if (!sesameaccountId) {
          throw new Error("rewards.getAll: sesameaccountId is required");
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error("rewards.getAll: journeyId is required");
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
        };
        if (categoryId !== undefined) query.category_id = categoryId;
        if (page !== undefined) query.p = page;
        if (pageSize !== undefined) query.l = pageSize;
        if (lang) query.lang = lang;
        if (maxXpCost !== undefined && maxXpCost !== null) {
          query.max_xp_cost = maxXpCost;
        }
        if (orderXpCost === "ASC" || orderXpCost === "DESC") {
          query.order_xp_cost = orderXpCost;
        }
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/reward/all.json`,
          { query },
        );
      },
      getDetail: (params: RewardDetailParams) => {
        const { sesameaccountId, rewardId, journeyId, lang } = params;
        if (!sesameaccountId) {
          throw new Error("rewards.getDetail: sesameaccountId is required");
        }
        if (
          rewardId === undefined ||
          rewardId === null ||
          rewardId === ""
        ) {
          throw new Error("rewards.getDetail: rewardId is required");
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error("rewards.getDetail: journeyId is required");
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
        };
        if (lang) query.lang = lang;
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/reward/${encodeURIComponent(String(rewardId))}.json`,
          { query },
        );
      },
      getCategories: (params: RewardCategoryParams) => {
        const { sesameaccountId, journeyId, page, pageSize, lang } = params;
        if (!sesameaccountId) {
          throw new Error("rewards.getCategories: sesameaccountId is required");
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error("rewards.getCategories: journeyId is required");
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
        };
        if (page !== undefined) query.p = page;
        if (pageSize !== undefined) query.l = pageSize;
        if (lang) query.lang = lang;
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/reward/allcategory.json`,
          { query },
        );
      },
    };

    this.challenges = {
      getAll: (params: ChallengeAllParams) => {
        const { sesameaccountId, journeyId, page, pageSize, lang } = params;
        if (!sesameaccountId) {
          throw new Error("challenges.getAll: sesameaccountId is required");
        }
        if (
          journeyId === undefined ||
          journeyId === null ||
          journeyId === ""
        ) {
          throw new Error("challenges.getAll: journeyId is required");
        }
        const query: Record<string, string | number> = {
          journey_id: journeyId,
        };
        if (page !== undefined) query.p = page;
        if (pageSize !== undefined) query.l = pageSize;
        if (lang) query.lang = lang;
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/challenge/all.json`,
          { query },
        );
      },
    };

    this.events = {
      // POST /{sesameaccountId}/event/push.json?data=<json>
      push: ({ sesameaccountId, data }: EventPushParams) => {
        if (!sesameaccountId) {
          throw new Error("events.push: sesameaccountId is required");
        }
        const query: Record<string, string> = {};
        if (data !== undefined && data !== null) {
          query.data = typeof data === "string" ? data : JSON.stringify(data);
        }
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/event/push.json`,
          { query },
        );
      },

      // POST /{sesameaccountId}/event/push-lambda.json?data=<json>
      pushLambda: ({ sesameaccountId, data, body }: EventPushParams) => {
        if (!sesameaccountId) {
          throw new Error("events.pushLambda: sesameaccountId is required");
        }
        const query: Record<string, string> = {};
        if (data !== undefined && data !== null && body === undefined) {
          query.data = typeof data === "string" ? data : JSON.stringify(data);
        }
        return this.request(
          "POST",
          `/${encodeURIComponent(sesameaccountId)}/event/push-lambda.json`,
          { query, body },
        );
      },
    };
  }

  async request(
    method: string,
    path: string,
    { query, body, headers }: RequestOptions = {},
  ): Promise<unknown> {
    const url = new URL(this.baseUrl + path);
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null) continue;
        url.searchParams.set(k, String(v));
      }
    }

    const reqHeaders: Record<string, string> = {
      Accept: "application/json",
      ...(this.authHeader ? { Authorization: this.authHeader } : {}),
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    };

    const urlStr = url.toString();
    let res: Response;
    try {
      res = await fetch(url, {
        method,
        headers: reqHeaders,
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
    } catch (err) {
      throw new SmartJourneyError(
        `Network error: ${(err as Error).message}`,
        { method, url: urlStr },
      );
    }

    const text = await res.text();
    let parsed: unknown = text;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        /* keep raw text */
      }
    } else {
      parsed = null;
    }

    if (!res.ok) {
      let firstErr: Record<string, unknown> | null = null;
      if (parsed && typeof parsed === "object") {
        const p = parsed as Record<string, unknown>;
        if (Array.isArray(p.errors)) {
          firstErr = (p.errors[0] as Record<string, unknown>) || null;
        } else if (p.errors && typeof p.errors === "object") {
          firstErr = p.errors as Record<string, unknown>;
        }
      }
      const errCode = (firstErr?.code ?? firstErr?.error_code) as
        | string
        | undefined;
      const apiMsg = firstErr?.message as string | undefined;
      const errMsg = apiMsg
        ? `HTTP ${res.status} ${res.statusText}: ${apiMsg}`
        : `HTTP ${res.status} ${res.statusText}`;
      const opts: ErrorMeta = {
        statusCode: res.status,
        statusText: res.statusText,
        errorCode: errCode,
        body: parsed,
        method,
        url: urlStr,
      };

      if (res.status === 401) throw new SmartJourneyAuthError(errMsg, opts);
      if (res.status === 403)
        throw new SmartJourneyForbiddenError(errMsg, opts);
      if (res.status === 404)
        throw new SmartJourneyNotFoundError(errMsg, opts);
      if (res.status === 429) {
        throw new SmartJourneyRateLimitError(errMsg, {
          ...opts,
          retryAfter: res.headers.get("retry-after"),
        });
      }
      throw new SmartJourneyError(errMsg, opts);
    }

    return parsed;
  }
}
