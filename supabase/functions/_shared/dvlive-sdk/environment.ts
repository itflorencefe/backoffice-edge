type ApiEnvironment = "STAG" | "PROD";

const BASE_URLS: Readonly<Record<ApiEnvironment, string>> = {
  STAG: "https://dev-webshow-engine.dv-live.com",
  PROD: "https://webshow-engine.dv-live.com",
};

export function resolveBaseUrl(environment: string | undefined): string {
  if (environment !== "STAG" && environment !== "PROD") {
    throw new TypeError('environment must be "STAG" or "PROD".');
  }
  return BASE_URLS[environment];
}
