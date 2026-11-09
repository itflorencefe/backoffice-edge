import { integer, nullable, object, string } from "./decoding.ts";

export type ChoiceStatusResponse = "EVICTED" | "PRESENT";

function decodeChoiceStatus(value: unknown, path: string): ChoiceStatusResponse {
  switch (value) {
    case "EVICTED": case "PRESENT": return value;
    default: throw new TypeError(`${path} must be EVICTED or PRESENT.`);
  }
}

/** Decoded DV Live wire models. Each class owns its validation. */
export class EliminatedRoundResponse {
  constructor(
    readonly uuid: string,
    readonly round: number,
  ) {}

  static decode(value: unknown, path = "EliminatedRoundResponse"): EliminatedRoundResponse {
    const source = object(value, path);
    const response = new EliminatedRoundResponse(
      string(source.uuid, `${path}.uuid`),
      integer(source.round, `${path}.round`),
    );
    return response;
  }
}

export class ReintroducedRoundResponse {
  constructor(
    readonly uuid: string,
    readonly round: number,
  ) {}

  static decode(value: unknown, path = "ReintroducedRoundResponse"): ReintroducedRoundResponse {
    const source = object(value, path);
    const response = new ReintroducedRoundResponse(
      string(source.uuid, `${path}.uuid`),
      integer(source.round, `${path}.round`),
    );
    return response;
  }
}

export class ChoiceResponse {
  declare bio?: string | null;
  declare desktopPicture?: string | null;
  declare mobilePicture?: string | null;

  constructor(
    readonly uuid: string,
    readonly firstname: string,
    readonly lastname: string,
    readonly status: ChoiceStatusResponse,
  ) {}

  static decode(value: unknown, path = "ChoiceResponse"): ChoiceResponse {
    const source = object(value, path);
    const response = new ChoiceResponse(
      string(source.uuid, `${path}.uuid`),
      string(source.firstname, `${path}.firstname`),
      string(source.lastname, `${path}.lastname`),
      decodeChoiceStatus(source.status, `${path}.status`),
    );
    if (source.bio !== undefined) response.bio = nullable(source.bio, string, `${path}.bio`);
    if (source.desktopPicture !== undefined) response.desktopPicture = nullable(source.desktopPicture, string, `${path}.desktopPicture`);
    if (source.mobilePicture !== undefined) response.mobilePicture = nullable(source.mobilePicture, string, `${path}.mobilePicture`);
    return response;
  }
}

export class ShowVoteChoiceResponse {
  declare bio?: string | null;
  declare desktopPicture?: string | null;
  declare mobilePicture?: string | null;
  declare eliminatedRound?: EliminatedRoundResponse | null;
  declare reintroducedRound?: ReintroducedRoundResponse | null;

  constructor(
    readonly uuid: string,
    readonly showVoteUuid: string,
    readonly firstname: string,
    readonly lastname: string,
    readonly status: string,
    readonly order: number,
  ) {}

  static decode(value: unknown, path = "ShowVoteChoiceResponse"): ShowVoteChoiceResponse {
    const source = object(value, path);
    const response = new ShowVoteChoiceResponse(
      string(source.uuid, `${path}.uuid`),
      string(source.showVoteUuid, `${path}.showVoteUuid`),
      string(source.firstname, `${path}.firstname`),
      string(source.lastname, `${path}.lastname`),
      string(source.status, `${path}.status`),
      integer(source.order, `${path}.order`),
    );
    if (source.bio !== undefined) response.bio = nullable(source.bio, string, `${path}.bio`);
    if (source.desktopPicture !== undefined) response.desktopPicture = nullable(source.desktopPicture, string, `${path}.desktopPicture`);
    if (source.mobilePicture !== undefined) response.mobilePicture = nullable(source.mobilePicture, string, `${path}.mobilePicture`);
    if (source.eliminatedRound !== undefined) response.eliminatedRound = nullable(source.eliminatedRound, EliminatedRoundResponse.decode, `${path}.eliminatedRound`);
    if (source.reintroducedRound !== undefined) response.reintroducedRound = nullable(source.reintroducedRound, ReintroducedRoundResponse.decode, `${path}.reintroducedRound`);
    return response;
  }
}
