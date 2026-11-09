import type { ShowVote } from "./show-vote.ts";
import type { ShowVoteChoice } from "./show-vote-choice.ts";
import type { Voter, CreateVoterResult, CastVoteResult } from "./voter.ts";

/** Public data returned by any supported SDK operation. */
export type ApiResult =
  | ShowVote
  | ShowVoteChoice
  | Voter
  | CreateVoterResult
  | CastVoteResult;
