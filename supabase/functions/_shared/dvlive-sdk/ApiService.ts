import { ShowVoteResponse } from "./responses/show-vote.ts";
import { ShowVoteChoiceResponse } from "./responses/show-vote-choice.ts";
import { GetVoterResponse, CreateVoterResponse, CastVoteResponse } from "./responses/voter.ts";
import { ApiHttpError, ApiRequestError, ApiResponseError } from "./ApiErrors.ts";
import { resolveBaseUrl } from "./environment.ts";
import { ApiResponse } from "./models/api-response.ts";
import { ShowVote } from "./models/show-vote.ts";
import { ShowVoteChoice } from "./models/show-vote-choice.ts";
import { CastVoteResult, CreateVoterResult, Voter } from "./models/voter.ts";
import { GetVoterRequest, CastVoteRequest, CreateVoterRequest, CreateVoterBody, CastVoteBody } from "./requests/voter.ts";
import { GetShowVoteRequest } from "./requests/show-vote.ts";
import { GetShowVoteChoiceRequest } from "./requests/show-vote-choice.ts";
import type { GetVoterInput, CreateVoterInput, CastVoteInput } from "./requests/voter.ts";
import { DvLiveLogger } from "./logger.ts";

interface HttpResponse extends ApiResponse<unknown> {
  bodyText: string;
}

export interface ApiServiceConfig {
  environment: string | undefined;
  headers?: Record<string, string> | (() => Record<string, string>);
  timeoutMs?: number;
  /** Accepts TRUE/FALSE environment strings or booleans. Defaults to false. */
  logEnable?: boolean | string;
  /** WARNING (default), INFO or DEBUG. Applied only when logging is enabled. */
  logLevel?: string;
}

export class ApiService {
  private readonly url: string;
  private readonly extraHeaders: ApiServiceConfig["headers"];
  private readonly timeoutMs: number;
  private readonly logger: DvLiveLogger;

  constructor(config: ApiServiceConfig) {
    this.url = resolveBaseUrl(config.environment);
    this.logger = new DvLiveLogger(config.logEnable, config.logLevel);
    this.extraHeaders = config.headers;
    this.timeoutMs = config.timeoutMs ?? 15000;
    if (!Number.isInteger(this.timeoutMs) || this.timeoutMs <= 0 || this.timeoutMs > 2147483647) {
      throw new TypeError("timeoutMs must be a positive 32-bit integer.");
    }
  }

  async getShowVote(uuid: string): Promise<ApiResponse<ShowVote>> {
    const request = new GetShowVoteRequest(uuid);
    const response = await this.request("getShowVote", "GET", `/show-vote/${encodeURIComponent(request.uuid)}`);
    try {
      const decoded = ShowVoteResponse.decode(response.data);
      return new ApiResponse(ShowVote.fromResponse(decoded), response.status, response.headers);
    } catch (cause) {
      this.logger.write("WARNING", "Response decoding failed", { operation: "getShowVote", status: response.status });
      throw new ApiResponseError(response, response.bodyText, cause);
    }
  }

  async getShowVoteChoice(uuid: string): Promise<ApiResponse<ShowVoteChoice>> {
    const request = new GetShowVoteChoiceRequest(uuid);
    const response = await this.request("getShowVoteChoice", "GET", `/show-vote-choice/${encodeURIComponent(request.uuid)}`);
    try {
      const decoded = ShowVoteChoiceResponse.decode(response.data);
      return new ApiResponse(ShowVoteChoice.fromResponse(decoded), response.status, response.headers);
    } catch (cause) {
      this.logger.write("WARNING", "Response decoding failed", { operation: "getShowVoteChoice", status: response.status });
      throw new ApiResponseError(response, response.bodyText, cause);
    }
  }

  async createVoter(...args: [input: CreateVoterInput] | [input: Pick<CreateVoterInput, "showVoteUuid">, body: unknown]): Promise<ApiResponse<CreateVoterResult>> {
    const [input, ...body] = args;
    const request = new CreateVoterRequest(input?.showVoteUuid, CreateVoterBody.decode(body.length === 0 ? input : body[0]));
    const response = await this.request("createVoter", "POST", this.voterPath(request.showVoteUuid), request.body);
    try {
      const decoded = CreateVoterResponse.decode(response.data);
      return new ApiResponse(CreateVoterResult.fromResponse(decoded), response.status, response.headers);
    } catch (cause) {
      this.logger.write("WARNING", "Response decoding failed", { operation: "createVoter", status: response.status });
      throw new ApiResponseError(response, response.bodyText, cause);
    }
  }

  async getVoter(input: GetVoterInput): Promise<ApiResponse<Voter>> {
    const request = new GetVoterRequest(input?.showVoteUuid, input?.userRef);
    const response = await this.request("getVoter", "GET", `${this.voterPath(request.showVoteUuid)}/${encodeURIComponent(request.userRef)}`);
    try {
      const decoded = GetVoterResponse.decode(response.data);
      return new ApiResponse(Voter.fromResponse(decoded), response.status, response.headers);
    } catch (cause) {
      this.logger.write("WARNING", "Response decoding failed", { operation: "getVoter", status: response.status });
      throw new ApiResponseError(response, response.bodyText, cause);
    }
  }

  async castVote(...args: [input: CastVoteInput] | [input: Pick<CastVoteInput, "showVoteUuid" | "userRef">, body: unknown]): Promise<ApiResponse<CastVoteResult>> {
    const [input, ...body] = args;
    const request = new CastVoteRequest(input?.showVoteUuid, input?.userRef, CastVoteBody.decode(body.length === 0 ? input : body[0]));
    const response = await this.request("castVote", "POST", `${this.voterPath(request.showVoteUuid)}/${encodeURIComponent(request.userRef)}/vote`, request.body);
    try {
      const decoded = CastVoteResponse.decode(response.data);
      return new ApiResponse(CastVoteResult.fromResponse(decoded), response.status, response.headers);
    } catch (cause) {
      this.logger.write("WARNING", "Response decoding failed", { operation: "castVote", status: response.status });
      throw new ApiResponseError(response, response.bodyText, cause);
    }
  }

  private voterPath(showVoteUuid: string): string {
    return `/show-vote/${encodeURIComponent(showVoteUuid)}/voter`;
  }

  private async request(operation: string, method: "GET" | "POST", path: string, body?: unknown): Promise<HttpResponse> {
    const extra = typeof this.extraHeaders === "function" ? this.extraHeaders() : this.extraHeaders;
    const headers = new Headers({ Accept: "application/json", ...(body === undefined ? {} : { "Content-Type": "application/json" }) });
    new Headers(extra).forEach((value, key) => headers.set(key, value));
    const requestBody = body === undefined ? undefined : JSON.stringify(body);
    const signal = AbortSignal.timeout(this.timeoutMs);
    const started = Date.now();
    const secrets: string[] = [];
    headers.forEach((value, key) => {
      if (/authorization|token|key/i.test(key)) secrets.push(value, value.replace(/^Bearer\s+/i, ""));
    });
    const voterRef = path.match(/\/voter\/([^/]+)/)?.[1];
    if (voterRef) secrets.push(voterRef, decodeURIComponent(voterRef));
    const context = { operation, method, url: this.url + path.replace(/(\/voter\/)[^/]+/, "$1[REDACTED]") };
    this.logger.write("INFO", "Request started", context, secrets);
    this.logger.write("DEBUG", "Request details", { ...context, body }, secrets);
    let response: Response;
    let text: string;
    try {
      response = await fetch(new URL(this.url + path), {
        method, headers, body: requestBody, signal, redirect: "error",
      });
      // Keep body reading inside the timeout/network boundary as well.
      text = await response.text();
    } catch (cause) {
      const timedOut = signal.aborted || (cause instanceof Error && cause.name === "TimeoutError");
      this.logger.write("WARNING", timedOut ? "Request timed out" : "Network request failed", {
        ...context, durationMs: Date.now() - started,
      }, secrets);
      throw new ApiRequestError(timedOut ? "timeout" : "network", cause);
    }
    const result = { ...context, status: response.status, durationMs: Date.now() - started };
    this.logger.write("INFO", "HTTP response received", result, secrets);
    let document: unknown;
    try {
      document = JSON.parse(text);
    } catch (cause) {
      if (response.ok) {
        this.logger.write("WARNING", "Response is not valid JSON", result, secrets);
        throw new ApiResponseError(response, text, cause);
      }
      // Preserve non-JSON error responses unchanged.
    }
    this.logger.write("DEBUG", "Response details", { ...result, body: document ?? "[Non-JSON body omitted]" }, secrets);
    if (!response.ok) {
      this.logger.write("WARNING", "HTTP request failed", result, secrets);
      throw new ApiHttpError(response, text, document);
    }
    return { data: document, status: response.status, headers: new Headers(response.headers), bodyText: text };
  }
}
