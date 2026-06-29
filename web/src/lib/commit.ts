import { keccak256, encodePacked, toHex, type Address } from "viem";

/**
 * Commit-reveal helpers (browser side).
 *
 * The on-chain commitment is:
 *   keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
 * Folding in the sender + bountyId makes a copied commitment unrevealable by
 * anyone else, which is the whole point of the scheme.
 */

export function computeCommitment({
  answer,
  salt,
  submitter,
  bountyId,
}: {
  answer: string;
  salt: `0x${string}`;
  submitter: Address;
  bountyId: bigint;
}): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, submitter, bountyId],
    ),
  );
}

/** Cryptographically-random 32-byte salt as a 0x hex string. */
export function randomSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

// --- Local persistence so a participant can reveal later from the same browser ---

export type StoredReveal = { answer: string; salt: `0x${string}` };

function key(contract: string, bountyId: bigint, user: string): string {
  return `crj:${contract.toLowerCase()}:${bountyId.toString()}:${user.toLowerCase()}`;
}

export function saveReveal(
  contract: string,
  bountyId: bigint,
  user: string,
  data: StoredReveal,
): void {
  try {
    localStorage.setItem(key(contract, bountyId, user), JSON.stringify(data));
  } catch {
    /* storage unavailable — the participant can still reveal manually */
  }
}

export function loadReveal(
  contract: string,
  bountyId: bigint,
  user: string,
): StoredReveal | null {
  try {
    const raw = localStorage.getItem(key(contract, bountyId, user));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as StoredReveal;
    if (typeof parsed?.answer === "string" && typeof parsed?.salt === "string") {
      return parsed;
    }
  } catch {
    /* ignore */
  }
  return null;
}
