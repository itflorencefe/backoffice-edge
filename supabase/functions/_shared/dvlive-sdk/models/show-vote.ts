import type { RoundResponse, ShowVoteResponse } from "../responses/show-vote.ts";
import { Choice } from "./show-vote-choice.ts";

/** Public DTOs. Customize field names and transformations in fromResponse(). */
export class Round {
  constructor(
    readonly currentRound: number,
    readonly startDay: string,
    readonly endDay: string,
    readonly name: string,
    readonly choices: Choice[],
  ) {}

  static fromResponse(response: RoundResponse): Round {
    return new Round(
      response.currentRound,
      response.startDay,
      response.endDay,
      response.name,
      response.choices.map(Choice.fromResponse),
    );
  }
}

export class ShowVote {
  declare readonly round?: Round | null;

  constructor(
    readonly name: string,
    readonly startDate: string,
    readonly endDate: string,
    round?: Round | null,
  ) {
    if (round !== undefined) this.round = round;
  }

  static fromResponse(response: ShowVoteResponse): ShowVote {
    return new ShowVote(
      response.name,
      response.startDate,
      response.endDate,
      response.round == null ? response.round : Round.fromResponse(response.round),
    );
  }
}
