import type { Address } from "viem";

/**
 * Parsed shape of the commit-reveal `getBounty` return value.
 *
 * NOTE: `submissionDeadline` / `revealDeadline` are in **milliseconds** because
 * Ritual Chain's `block.timestamp` is in ms (not unix seconds). All time math
 * here compares against `Date.now()` directly.
 */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint; // ms
  revealDeadline: bigint; // ms
  judged: boolean;
  finalized: boolean;
  committerCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
};

/** getBounty returns a single struct — viem hands it back as a named object. */
export function parseBounty(raw: {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint;
  revealDeadline: bigint;
  judged: boolean;
  finalized: boolean;
  committerCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
}): Bounty {
  return { ...raw };
}

export type BountyStatus =
  | "commit" // before submission deadline
  | "reveal" // between submission and reveal deadline
  | "ready" // reveal closed, awaiting judging
  | "judged" // judged, awaiting finalize
  | "finalized";

/** Phase of the bounty. `nowMs` defaults to wall-clock ms. */
export function getBountyStatus(b: Bounty, nowMs = Date.now()): BountyStatus {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (nowMs < Number(b.submissionDeadline)) return "commit";
  if (nowMs < Number(b.revealDeadline)) return "reveal";
  return "ready";
}

export const STATUS_META: Record<
  BountyStatus,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" }
> = {
  commit: { label: "Commit phase", tone: "green" },
  reveal: { label: "Reveal phase", tone: "amber" },
  ready: { label: "Ready for judging", tone: "amber" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant still submit a *commitment*? (commit phase only) */
export function canCommit(b: Bounty, nowMs = Date.now()): boolean {
  return !b.judged && !b.finalized && nowMs < Number(b.submissionDeadline);
}

/** Can a participant reveal? (between submission and reveal deadline) */
export function canReveal(b: Bounty, nowMs = Date.now()): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    nowMs >= Number(b.submissionDeadline) &&
    nowMs < Number(b.revealDeadline)
  );
}

/** Has the reveal window closed (owner may judge)? */
export function canJudge(b: Bounty, nowMs = Date.now()): boolean {
  return !b.judged && !b.finalized && nowMs >= Number(b.revealDeadline);
}
