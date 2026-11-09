import { pathParameter } from "./validation.ts";

export class GetShowVoteRequest {
  declare private readonly validated: void;

  constructor(readonly uuid: string) {
    pathParameter(uuid, "uuid");
    Object.freeze(this);
  }
}
