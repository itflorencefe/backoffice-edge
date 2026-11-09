import { pathParameter } from "./validation.ts";

export class GetShowVoteChoiceRequest {
  declare private readonly validated: void;

  constructor(readonly uuid: string) {
    pathParameter(uuid, "uuid");
    Object.freeze(this);
  }
}
