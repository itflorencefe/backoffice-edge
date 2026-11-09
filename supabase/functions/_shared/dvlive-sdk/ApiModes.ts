/** Supported operations. Values match the public mode query parameter. */
export enum ApiModes {
  GetShowVoteChoice = "getShowVoteChoice",
  GetShowVote = "getShowVote",
  CreateVoter = "createVoter",
  GetVoter = "getVoter",
  CastVote = "castVote",
}

export interface ApiModeDefinition {
  readonly method: "GET" | "POST";
  /** Required URL query parameters, excluding mode itself. */
  readonly params: readonly string[];
  /** Supported JSON body fields. */
  readonly body: readonly string[];
  readonly requiredBody?: readonly string[];
  readonly description: string;
  readonly response: string;
}

export const API_MODES: Readonly<Record<ApiModes, ApiModeDefinition>> = {
  [ApiModes.GetShowVoteChoice]: {
    method: "GET", params: ["uuid"], body: [],
    description: "Returns a participant: UUID, name, status, order, biography, images, and elimination/reintroduction rounds.",
    response: "ShowVoteChoice",
  },
  [ApiModes.GetShowVote]: {
    method: "GET", params: ["uuid"], body: [],
    description: "Returns the show name and dates, current round, and its participants.",
    response: "ShowVote",
  },
  [ApiModes.CreateVoter]: {
    method: "POST", params: ["showVoteUuid"], body: ["email", "phone"],
    description: "Registers a voter and returns the operation result (status, code, message). Voter identity (uniqRef) is taken from the app JWT absolute_reference claim.",
    response: "CreateVoterResult",
  },
  [ApiModes.GetVoter]: {
    method: "GET", params: ["showVoteUuid"], body: [],
    description: "Returns the voter reference and contact details, remaining points, fraud status, and balance breakdown. Voter identity (userRef) is taken from the app JWT absolute_reference claim.",
    response: "Voter",
  },
  [ApiModes.CastVote]: {
    method: "POST", params: ["showVoteUuid"],
    body: ["votes", "sessionToken", "phoneFingerPrint", "ip", "userAgent", "uniqSubscriptionId"],
    requiredBody: ["votes"],
    description: "Casts votes for participants in the current round and returns the operation result, including nbVoteRemaining when provided by the API. Voter identity (userRef) is taken from the app JWT absolute_reference claim.",
    response: "CastVoteResult",
  },
};


export interface ModeCatalog {
  name: "DVLive";
  description: string;
  modes: Readonly<Record<ApiModes, ApiModeDefinition>>;
}

export type ModeParseResult =
  | { mode: ApiModes; catalog: null }
  | { mode: null; catalog: ModeCatalog };

export function getModeCatalog(): ModeCatalog {
  return {
    name: "DVLive",
    description: "Select a mode in the URL query. The params list contains required query parameters; body lists supported POST JSON fields and requiredBody lists mandatory body fields. Authenticate with Authorization: Bearer <app JWT>. The edge function attaches the DV Live API token from server secrets.",
    modes: API_MODES,
  };
}

/** Exact, case-sensitive parsing. Missing or unsupported modes return the catalog. */
export function parseMode(value: string | null | undefined): ModeParseResult {
  const mode = Object.values(ApiModes).find((mode) => mode === value);
  return mode === undefined ? { mode: null, catalog: getModeCatalog() } : { mode, catalog: null };
}
