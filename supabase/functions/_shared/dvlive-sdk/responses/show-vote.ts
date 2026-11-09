import { ChoiceResponse } from "./show-vote-choice.ts";
import { array, integer, nullable, object, string } from "./decoding.ts";

/** Decoded DV Live wire models. Each class owns its validation. */
export class RoundResponse {
  constructor(
    readonly currentRound: number,
    readonly startDay: string,
    readonly endDay: string,
    readonly name: string,
    readonly choices: ChoiceResponse[],
  ) {}

  static decode(value: unknown, path = "RoundResponse"): RoundResponse {
    const source = object(value, path);
    const response = new RoundResponse(
      integer(source.currentRound, `${path}.currentRound`),
      string(source.startDay, `${path}.startDay`),
      string(source.endDay, `${path}.endDay`),
      string(source.name, `${path}.name`),
      array(source.choices, ChoiceResponse.decode, `${path}.choices`),
    );
    return response;
  }
}

export class ShowVoteResponse {
  declare round?: RoundResponse | null;

  constructor(
    readonly name: string,
    readonly startDate: string,
    readonly endDate: string,
  ) {}

  static decode(value: unknown, path = "ShowVoteResponse"): ShowVoteResponse {
    const source = object(value, path);
    const response = new ShowVoteResponse(
      string(source.name, `${path}.name`),
      string(source.startDate, `${path}.startDate`),
      string(source.endDate, `${path}.endDate`),
    );
    if (source.round !== undefined) response.round = nullable(source.round, RoundResponse.decode, `${path}.round`);
    return response;
  }
}
