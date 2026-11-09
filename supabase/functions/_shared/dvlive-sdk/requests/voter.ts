import { ApiValidationError } from "../ApiErrors.ts";
import { bodyObject, string, optionalString as decodeOptionalString, optionalPhone, number } from "./body-decoding.ts";
import { pathParameter, optionalString, positiveInteger } from "./validation.ts";
export class CreateVoterBody {
  declare private readonly validated: void;
  declare readonly email?: string;
  declare readonly phone?: string | null;
  declare readonly uniqRef?: string;

  constructor(fields: { email?: string; phone?: string | null; uniqRef?: string } = {}) {
    if (fields === null || typeof fields !== "object" || Array.isArray(fields)) {
      throw new ApiValidationError("Body fields must be an object.");
    }
    optionalString(fields.email, "email");
    optionalString(fields.uniqRef, "uniqRef");
    if (fields.phone !== undefined && fields.phone !== null && typeof fields.phone !== "string") {
      throw new ApiValidationError("phone must be a string or null.");
    }
    if (fields.email !== undefined) this.email = fields.email;
    if (fields.phone !== undefined) this.phone = fields.phone;
    if (fields.uniqRef !== undefined) this.uniqRef = fields.uniqRef;
    Object.freeze(this);
  }

  static decode(value: unknown): CreateVoterBody {
    const source = bodyObject(value);
    return new CreateVoterBody({
      email: decodeOptionalString(source.email, "email"),
      phone: optionalPhone(source.phone),
      uniqRef: decodeOptionalString(source.uniqRef, "uniqRef"),
    });
  }
}

export interface CastVoteChoiceInput {
  choiceUuid: string;
  nbVotes: number;
}

export class CastVoteChoiceRequest {
  declare private readonly validated: void;

  constructor(readonly choiceUuid: string, readonly nbVotes: number) {
    pathParameter(choiceUuid, "choiceUuid");
    positiveInteger(nbVotes, "nbVotes");
    Object.freeze(this);
  }

  static decode(value: unknown): CastVoteChoiceRequest {
    const source = bodyObject(value);
    return new CastVoteChoiceRequest(string(source.choiceUuid, "choiceUuid"), number(source.nbVotes, "nbVotes"));
  }
}

interface CastVoteFields {
  votes: readonly CastVoteChoiceRequest[];
  sessionToken?: string;
  phoneFingerPrint?: string;
  ip?: string;
  userAgent?: string;
  uniqSubscriptionId?: string;
}

export class CastVoteBody {
  declare private readonly validated: void;
  readonly votes: readonly CastVoteChoiceRequest[];
  declare readonly sessionToken?: string;
  declare readonly phoneFingerPrint?: string;
  declare readonly ip?: string;
  declare readonly userAgent?: string;
  declare readonly uniqSubscriptionId?: string;

  constructor(fields: CastVoteFields) {
    if (fields === null || typeof fields !== "object" || Array.isArray(fields)) {
      throw new ApiValidationError("Body fields must be an object.");
    }
    if (!Array.isArray(fields.votes) || !fields.votes.length || !fields.votes.every((vote) => vote instanceof CastVoteChoiceRequest)) {
      throw new ApiValidationError("votes must contain at least one CastVoteChoiceRequest.");
    }
    optionalString(fields.sessionToken, "sessionToken");
    optionalString(fields.phoneFingerPrint, "phoneFingerPrint");
    optionalString(fields.ip, "ip");
    optionalString(fields.userAgent, "userAgent");
    optionalString(fields.uniqSubscriptionId, "uniqSubscriptionId");
    this.votes = Object.freeze([...fields.votes]);
    if (fields.sessionToken !== undefined) this.sessionToken = fields.sessionToken;
    if (fields.phoneFingerPrint !== undefined) this.phoneFingerPrint = fields.phoneFingerPrint;
    if (fields.ip !== undefined) this.ip = fields.ip;
    if (fields.userAgent !== undefined) this.userAgent = fields.userAgent;
    if (fields.uniqSubscriptionId !== undefined) this.uniqSubscriptionId = fields.uniqSubscriptionId;
    Object.freeze(this);
  }

  static decode(value: unknown): CastVoteBody {
    const source = bodyObject(value);
    if (!Array.isArray(source.votes) || !source.votes.length) {
      throw new ApiValidationError("votes must contain at least one object with choiceUuid and nbVotes as a positive integer.");
    }
    return new CastVoteBody({
      votes: source.votes.map((vote: unknown) => CastVoteChoiceRequest.decode(vote)),
      sessionToken: decodeOptionalString(source.sessionToken, "sessionToken"),
      phoneFingerPrint: decodeOptionalString(source.phoneFingerPrint, "phoneFingerPrint"),
      ip: decodeOptionalString(source.ip, "ip"),
      userAgent: decodeOptionalString(source.userAgent, "userAgent"),
      uniqSubscriptionId: decodeOptionalString(source.uniqSubscriptionId, "uniqSubscriptionId"),
    });
  }
}

export interface GetVoterInput {
  showVoteUuid: string;
  userRef: string;
}

export class GetVoterRequest {
  declare private readonly validated: void;

  constructor(readonly showVoteUuid: string, readonly userRef: string) {
    pathParameter(showVoteUuid, "showVoteUuid");
    pathParameter(userRef, "userRef");
    Object.freeze(this);
  }
}

export interface CreateVoterInput {
  showVoteUuid: string;
  email?: string;
  phone?: string | null;
  uniqRef?: string;
}

export class CreateVoterRequest {
  declare private readonly validated: void;

  constructor(readonly showVoteUuid: string, readonly body: CreateVoterBody) {
    pathParameter(showVoteUuid, "showVoteUuid");
    if (!(body instanceof CreateVoterBody)) throw new ApiValidationError("body must be a CreateVoterBody.");
    Object.freeze(this);
  }
}

export interface CastVoteInput extends GetVoterInput {
  votes: readonly CastVoteChoiceInput[];
  sessionToken?: string;
  phoneFingerPrint?: string;
  ip?: string;
  userAgent?: string;
  uniqSubscriptionId?: string;
}

export class CastVoteRequest {
  declare private readonly validated: void;

  constructor(readonly showVoteUuid: string, readonly userRef: string, readonly body: CastVoteBody) {
    pathParameter(showVoteUuid, "showVoteUuid");
    pathParameter(userRef, "userRef");
    if (!(body instanceof CastVoteBody)) throw new ApiValidationError("body must be a CastVoteBody.");
    Object.freeze(this);
  }
}
