import type { ChoiceStatusResponse, ChoiceResponse, EliminatedRoundResponse, ReintroducedRoundResponse, ShowVoteChoiceResponse } from "../responses/show-vote-choice.ts";

export type ChoiceStatus = ChoiceStatusResponse;

/** Public DTOs. Customize field names and transformations in fromResponse(). */
export class EliminatedRound {
  constructor(
    readonly uuid: string,
    readonly round: number,
  ) {}

  static fromResponse(response: EliminatedRoundResponse): EliminatedRound {
    return new EliminatedRound(
      response.uuid,
      response.round,
    );
  }
}

export class ReintroducedRound {
  constructor(
    readonly uuid: string,
    readonly round: number,
  ) {}

  static fromResponse(response: ReintroducedRoundResponse): ReintroducedRound {
    return new ReintroducedRound(
      response.uuid,
      response.round,
    );
  }
}

export class Choice {
  declare readonly bio?: string | null;
  declare readonly desktopPicture?: string | null;
  declare readonly mobilePicture?: string | null;

  constructor(
    readonly uuid: string,
    readonly firstname: string,
    readonly lastname: string,
    readonly status: ChoiceStatus,
    bio?: string | null,
    desktopPicture?: string | null,
    mobilePicture?: string | null,
  ) {
    if (bio !== undefined) this.bio = bio;
    if (desktopPicture !== undefined) this.desktopPicture = desktopPicture;
    if (mobilePicture !== undefined) this.mobilePicture = mobilePicture;
  }

  static fromResponse(response: ChoiceResponse): Choice {
    return new Choice(
      response.uuid,
      response.firstname,
      response.lastname,
      response.status,
      response.bio,
      response.desktopPicture,
      response.mobilePicture,
    );
  }
}

export class ShowVoteChoice {
  declare readonly bio?: string | null;
  declare readonly desktopPicture?: string | null;
  declare readonly mobilePicture?: string | null;
  declare readonly eliminatedRound?: EliminatedRound | null;
  declare readonly reintroducedRound?: ReintroducedRound | null;

  constructor(
    readonly uuid: string,
    readonly showVoteUuid: string,
    readonly firstname: string,
    readonly lastname: string,
    readonly status: string,
    readonly order: number,
    bio?: string | null,
    desktopPicture?: string | null,
    mobilePicture?: string | null,
    eliminatedRound?: EliminatedRound | null,
    reintroducedRound?: ReintroducedRound | null,
  ) {
    if (bio !== undefined) this.bio = bio;
    if (desktopPicture !== undefined) this.desktopPicture = desktopPicture;
    if (mobilePicture !== undefined) this.mobilePicture = mobilePicture;
    if (eliminatedRound !== undefined) this.eliminatedRound = eliminatedRound;
    if (reintroducedRound !== undefined) this.reintroducedRound = reintroducedRound;
  }

  static fromResponse(response: ShowVoteChoiceResponse): ShowVoteChoice {
    return new ShowVoteChoice(
      response.uuid,
      response.showVoteUuid,
      response.firstname,
      response.lastname,
      response.status,
      response.order,
      response.bio,
      response.desktopPicture,
      response.mobilePicture,
      response.eliminatedRound == null ? response.eliminatedRound : EliminatedRound.fromResponse(response.eliminatedRound),
      response.reintroducedRound == null ? response.reintroducedRound : ReintroducedRound.fromResponse(response.reintroducedRound),
    );
  }
}
