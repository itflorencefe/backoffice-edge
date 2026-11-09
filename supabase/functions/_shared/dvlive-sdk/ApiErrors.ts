/** Invalid request parameter or body. No upstream HTTP request has been made. */
export class ApiValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ApiValidationError";
  }
}

/** Failed upstream HTTP response, including JSON and non-JSON bodies. */
export class ApiHttpError extends Error {
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;
  readonly document: unknown;
  readonly bodyText: string;

  constructor(response: Response, bodyText: string, document?: unknown) {
    super(`HTTP ${response.status}: ${response.statusText}`);
    this.name = "ApiHttpError";
    this.status = response.status;
    this.statusText = response.statusText;
    this.headers = new Headers(response.headers);
    this.document = document;
    this.bodyText = bodyText;
  }
}

export class ApiRequestError extends Error {
  readonly kind: "network" | "timeout";

  constructor(kind: "network" | "timeout", cause: unknown) {
    super(kind === "timeout" ? "DV Live API request timed out." : "DV Live API is unreachable.", { cause });
    this.name = "ApiRequestError";
    this.kind = kind;
  }
}

/** A successful HTTP response could not be decoded into its response contract. */
export class ApiResponseError extends Error {
  readonly status: number;
  readonly headers: Headers;
  readonly bodyText: string;

  constructor(response: Pick<Response, "status" | "headers">, bodyText: string, cause?: unknown) {
    super("DV Live API returned an invalid JSON response.", { cause });
    this.name = "ApiResponseError";
    this.status = response.status;
    this.headers = new Headers(response.headers);
    this.bodyText = bodyText;
  }
}
