/**
 * Smart Journey event payload builders for POST /sendEvent.
 *
 * How to add a new event_name:
 * 1. Add a builder function that merges common fields + body into the SMJ `data` object.
 * 2. Register it in EVENT_BUILDERS below.
 * 3. Document the expected body shape in the builder comment.
 *
 * Do not change index.ts or smartJourneyClient.ts when extending this catalog —
 * only this file.
 *
 * Catalog (REST /rest/template ids → event_name):
 *   1–2  lb_ranking
 *   3    dv_login
 *   4–8  profile_completed
 *   9–10 dv_user_interaction
 *   11   instant_game_res
 *   12–14 quiz_end
 *   15   tutorial_followed
 */

export type EventBuildInput = {
  event_name: string;
  product_id: string;
  user_id: string;
  body: Record<string, unknown>;
};

export class UnknownEventNameError extends Error {
  readonly event_name: string;
  readonly supported: string[];

  constructor(event_name: string, supported: string[]) {
    super(
      `Unknown event_name "${event_name}". Supported: ${supported.join(", ")}`,
    );
    this.name = "UnknownEventNameError";
    this.event_name = event_name;
    this.supported = supported;
  }
}

type EventBuilder = (input: EventBuildInput) => Record<string, unknown>;

function basePayload(input: EventBuildInput): Record<string, unknown> {
  return {
    product_id: input.product_id,
    user_id: input.user_id,
    event_name: input.event_name,
    ...input.body,
    collector_tstamp: new Date().toISOString(),
  };
}

/**
 * Templates 1–2 — leaderboard exact ranking / ranking range.
 * Body: { ranking: number } or fields that SMJ matches for range challenges.
 */
const buildLbRanking: EventBuilder = (input) => basePayload(input);

/**
 * Template 3 — login the service.
 * Body: typically empty.
 */
const buildDvLogin: EventBuilder = (input) => basePayload(input);

/**
 * Templates 4–8 — profile field completed (email, phone, nickname, birthday, avatar).
 * Body examples:
 *   { percent_completed: 100, profile: { email, nickname, phone, birthday } }
 *   { profile: { avatar_url: "https://..." } }
 */
const buildProfileCompleted: EventBuilder = (input) => basePayload(input);

/**
 * Templates 9–10 — start / end HTML game.
 * Body example:
 *   { contexts_com_dgp_interaction_element_1: [{ tracking_name: "GameStart" }] }
 *   { contexts_com_dgp_interaction_element_1: [{ tracking_name: "GameEnd" }] }
 */
const buildDvUserInteraction: EventBuilder = (input) => basePayload(input);

/**
 * Template 11 — instant game result.
 * Body example: { instant_game_tier: "VA1_15" }
 */
const buildInstantGameRes: EventBuilder = (input) => basePayload(input);

/**
 * Templates 12–14 — quiz good / bad / perfect.
 * Body examples:
 *   { nb_ok_response: 5 }
 *   { nb_nok_response: 2 }
 *   { quiz_perfect: true }
 */
const buildQuizEnd: EventBuilder = (input) => basePayload(input);

/**
 * Template 15 — tutorial completed.
 * Body example: { nb_actions: 5, action_followed: 3 }
 */
const buildTutorialFollowed: EventBuilder = (input) => basePayload(input);

const EVENT_BUILDERS: Record<string, EventBuilder> = {
  lb_ranking: buildLbRanking,
  dv_login: buildDvLogin,
  profile_completed: buildProfileCompleted,
  dv_user_interaction: buildDvUserInteraction,
  instant_game_res: buildInstantGameRes,
  quiz_end: buildQuizEnd,
  tutorial_followed: buildTutorialFollowed,
};

export function listSupportedEventNames(): string[] {
  return Object.keys(EVENT_BUILDERS);
}

/**
 * Build the SMJ event `data` object for push / push-lambda.
 * Throws UnknownEventNameError when event_name is not registered.
 */
export function buildEventData(input: EventBuildInput): Record<string, unknown> {
  const builder = EVENT_BUILDERS[input.event_name];
  if (!builder) {
    throw new UnknownEventNameError(
      input.event_name,
      listSupportedEventNames(),
    );
  }
  return builder(input);
}
