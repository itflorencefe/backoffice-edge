import { integer, nullable, object, string } from "./decoding.ts";

export type UserFraudStatusResponse = "CLEAN" | "SUSPICIOUS" | "BLOCKED" | "VERIFIED";

function decodeUserFraudStatus(value: unknown, path: string): UserFraudStatusResponse {
  switch (value) {
    case "CLEAN": case "SUSPICIOUS": case "BLOCKED": case "VERIFIED": return value;
    default: throw new TypeError(`${path} must be a supported voter fraud status.`);
  }
}

function decodeSuccess(value: unknown, path: string): "success" {
  if (value !== "success") throw new TypeError(`${path} must be success.`);
  return value;
}

/** Decoded DV Live wire models. Each class owns its validation. */
export class VoterBalanceResponse {
  declare standardPoint?: number;
  declare additionalPoint?: number;
  declare purchasedPoint?: number;

  static decode(value: unknown, path = "VoterBalanceResponse"): VoterBalanceResponse {
    const source = object(value, path);
    const response = new VoterBalanceResponse();
    if (source.standardPoint !== undefined) response.standardPoint = integer(source.standardPoint, `${path}.standardPoint`);
    if (source.additionalPoint !== undefined) response.additionalPoint = integer(source.additionalPoint, `${path}.additionalPoint`);
    if (source.purchasedPoint !== undefined) response.purchasedPoint = integer(source.purchasedPoint, `${path}.purchasedPoint`);
    return response;
  }
}

export class GetVoterResponse {
  declare email?: string | null;
  declare phone?: string | null;

  constructor(
    readonly uniqRef: string,
    readonly remainingPoints: number,
    readonly userFraudStatus: UserFraudStatusResponse,
    readonly balance: VoterBalanceResponse,
  ) {}

  static decode(value: unknown, path = "GetVoterResponse"): GetVoterResponse {
    const source = object(value, path);
    const response = new GetVoterResponse(
      string(source.uniqRef, `${path}.uniqRef`),
      integer(source.remainingPoints, `${path}.remainingPoints`),
      decodeUserFraudStatus(source.userFraudStatus, `${path}.userFraudStatus`),
      VoterBalanceResponse.decode(source.balance, `${path}.balance`),
    );
    if (source.email !== undefined) response.email = nullable(source.email, string, `${path}.email`);
    if (source.phone !== undefined) response.phone = nullable(source.phone, string, `${path}.phone`);
    return response;
  }
}

export class CreateVoterResponse {
  constructor(
    readonly status: "success",
    readonly code: number,
    readonly message: string,
  ) {}

  static decode(value: unknown, path = "CreateVoterResponse"): CreateVoterResponse {
    const source = object(value, path);
    const response = new CreateVoterResponse(
      decodeSuccess(source.status, `${path}.status`),
      integer(source.code, `${path}.code`),
      string(source.message, `${path}.message`),
    );
    return response;
  }
}

export class CastVoteResponse {
  constructor(
    readonly status: "success",
    readonly code: number,
    readonly message: string,
    readonly nbVoteRemaining: number,
  ) {}

  static decode(value: unknown, path = "CastVoteResponse"): CastVoteResponse {
    const source = object(value, path);
    const response = new CastVoteResponse(
      decodeSuccess(source.status, `${path}.status`),
      integer(source.code, `${path}.code`),
      string(source.message, `${path}.message`),
      integer(source.nbVoteRemaining, `${path}.nbVoteRemaining`),
    );
    return response;
  }
}
