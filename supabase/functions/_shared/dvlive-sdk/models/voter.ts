import type { CastVoteResponse, CreateVoterResponse, GetVoterResponse, VoterBalanceResponse } from "../responses/voter.ts";

export type UserFraudStatus = "CLEAN" | "SUSPICIOUS" | "BLOCKED" | "VERIFIED";

/** Public DTOs. Customize field names and transformations in fromResponse(). */
export class OperationResult {
  constructor(
    readonly status: "success" | "error",
    readonly code: number,
    readonly message: string,
  ) {}

  static fromResponse(response: CreateVoterResponse | CastVoteResponse): OperationResult {
    return new OperationResult(
      response.status,
      response.code,
      response.message,
    );
  }
}

export class CreateVoterResult {
  constructor(
    readonly status: "success",
    readonly code: number,
    readonly message: string,
  ) {}

  static fromResponse(response: CreateVoterResponse): CreateVoterResult {
    return new CreateVoterResult(
      response.status,
      response.code,
      response.message,
    );
  }
}

export class CastVoteResult {
  constructor(
    readonly status: "success",
    readonly code: number,
    readonly message: string,
    readonly nbVoteRemaining: number,
  ) {}

  static fromResponse(response: CastVoteResponse): CastVoteResult {
    return new CastVoteResult(
      response.status,
      response.code,
      response.message,
      response.nbVoteRemaining,
    );
  }
}

export class VoterBalance {
  declare readonly standardPoint?: number;
  declare readonly additionalPoint?: number;
  declare readonly purchasedPoint?: number;

  constructor(
    standardPoint?: number,
    additionalPoint?: number,
    purchasedPoint?: number,
  ) {
    if (standardPoint !== undefined) this.standardPoint = standardPoint;
    if (additionalPoint !== undefined) this.additionalPoint = additionalPoint;
    if (purchasedPoint !== undefined) this.purchasedPoint = purchasedPoint;
  }

  static fromResponse(response: VoterBalanceResponse): VoterBalance {
    return new VoterBalance(
      response.standardPoint,
      response.additionalPoint,
      response.purchasedPoint,
    );
  }
}

export class Voter {
  declare readonly email?: string | null;
  declare readonly phone?: string | null;

  constructor(
    readonly uniqRef: string,
    readonly remainingPoints: number,
    readonly userFraudStatus: UserFraudStatus,
    readonly balance: VoterBalance,
    email?: string | null,
    phone?: string | null,
  ) {
    if (email !== undefined) this.email = email;
    if (phone !== undefined) this.phone = phone;
  }

  static fromResponse(response: GetVoterResponse): Voter {
    return new Voter(
      response.uniqRef,
      response.remainingPoints,
      response.userFraudStatus,
      VoterBalance.fromResponse(response.balance),
      response.email,
      response.phone,
    );
  }
}
