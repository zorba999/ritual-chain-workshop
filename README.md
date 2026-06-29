# Privacy-Preserving AI Bounty Judge — Commit-Reveal

> Homework submission for the Ritual Academy *AI Bounty Judge* workshop.
> Author: [@zorba999](https://github.com/zorba999)

This repo extends the workshop's `AIJudge` bounty app so that **submissions stay
hidden until judging is complete**, killing the original flaw where late
participants could read and copy earlier answers before the deadline.

- **Required track — Commit-Reveal:** implemented in Solidity, works on any EVM
  chain. → [`hardhat/contracts/CommitRevealAIJudge.sol`](hardhat/contracts/CommitRevealAIJudge.sol)
- **Advanced track — Ritual-native hidden submissions (TEE):** design note. →
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## Documents

| File | What's inside |
| --- | --- |
| [`hardhat/contracts/CommitRevealAIJudge.sol`](hardhat/contracts/CommitRevealAIJudge.sol) | The commit-reveal bounty contract (required track). |
| [`hardhat/contracts/CommitRevealAIJudge.t.sol`](hardhat/contracts/CommitRevealAIJudge.t.sol) | Foundry-style tests covering valid/invalid reveal cases. |
| [`docs/TEST_PLAN.md`](docs/TEST_PLAN.md) | Written test plan mapped to each test. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Commit-reveal vs Ritual-native TEE design + diagram. |
| [`docs/REFLECTION.md`](docs/REFLECTION.md) | Answer to the reflection question. |

---

## The problem

The original `submitAnswer(bountyId, answer)` stored the **plaintext** answer
on-chain the moment it was submitted. Because all on-chain state is public,
anyone could:

1. Read every answer already submitted to an open bounty.
2. Copy the strongest ideas.
3. Submit an "improved" version before the deadline.

In a winner-takes-all bounty that is unfair. We want answers to be **secret
during the submission window** and only become readable when it's too late to
copy them.

## The solution: commit-reveal

Submission is split into two phases.

### Phase 1 — Commit (before `submissionDeadline`)

Participants compute, **off-chain**, a commitment hash and submit only that:

```
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

```solidity
submitCommitment(uint256 bountyId, bytes32 commitment)
```

The plaintext answer never touches the chain in this phase, so there is nothing
to copy. The `salt` is a random secret that stops anyone from brute-forcing the
answer out of the hash. `msg.sender` and `bountyId` are folded in so a commitment
is **bound to one participant and one bounty** — copying the hash is useless
(see below).

### Phase 2 — Reveal (after `submissionDeadline`, before `revealDeadline`)

Once submissions are closed, participants reveal their answer + salt:

```solidity
revealAnswer(uint256 bountyId, string answer, bytes32 salt)
```

The contract recomputes `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`
and accepts the reveal **only if it matches** the stored commitment. Valid
reveals are pushed into the `revealed[]` array — the only answers eligible for
judging.

### Phase 3 — Judge (after `revealDeadline`, owner only)

```solidity
judgeAll(uint256 bountyId, bytes llmInput)
```

The owner triggers **one batched** Ritual LLM inference (precompile `0x0802`)
over all revealed answers — never one call per answer. The model's response is
stored on-chain as `aiReview`.

### Phase 4 — Finalize (owner only, human-in-the-loop)

```solidity
finalizeWinner(uint256 bountyId, uint256 winnerIndex)
```

The AI *recommends*; the human owner *decides*. The owner picks the winning
index and the contract pays out the escrowed reward (checks-effects-interactions,
reward zeroed before transfer to block reentrancy).

```
 create ──► COMMIT ──(submissionDeadline)──► REVEAL ──(revealDeadline)──► JUDGE ──► FINALIZE
            hash only                         answer+salt                 batch LLM   pay winner
```

## Why copying a commitment doesn't work

Because the hash binds `msg.sender`, an attacker who copies someone else's
commitment bytes during the commit phase **cannot reveal it**: the reveal
recomputes the hash with the *attacker's* address, which no longer matches. This
is enforced and tested in
[`test_RevertWhen_CopiedCommitmentRevealedByOther`](hardhat/contracts/CommitRevealAIJudge.t.sol).

## Contract rules enforced

- ✅ Commitments only **before** the submission deadline.
- ✅ Reveals only **after** submission deadline and **before** reveal deadline.
- ✅ One commitment per participant per bounty (max `MAX_SUBMISSIONS = 10`).
- ✅ A reveal is valid only if the commitment hash matches.
- ✅ Unrevealed commitments are **not** eligible for judging.
- ✅ Owner can judge only **after** the reveal deadline.
- ✅ Owner can finalize only **after** judging.
- ✅ Exactly one winner is paid; reward can only be released once.

## How the LLM receives submissions (batch judging)

`judgeAll` forwards an off-chain-built `llmInput` (ABI-encoded Ritual LLM
request) to precompile `0x0802`. The frontend serialises **all** revealed
answers into a single JSON array inside one prompt — see
[`web/src/lib/ritualLlm.ts`](web/src/lib/ritualLlm.ts) (`buildJudgeAllLlmInput`).
The model returns one JSON verdict (`{ winnerIndex, summary, ... }`) which the UI
decodes from the on-chain `aiReview` bytes
([`web/src/lib/aiReview.ts`](web/src/lib/aiReview.ts)). One bounty = one LLM call.

> Security note: the system prompt marks submissions as untrusted content and
> tells the model not to follow instructions inside them (prompt-injection
> defense). The AI output is only a *recommendation* — no funds move without the
> human owner calling `finalizeWinner`.

---

## Running it locally

```bash
cd hardhat
npm install                 # (or pnpm install)
npx hardhat build           # compile contracts
npx hardhat test solidity   # run the commit-reveal test suite
```

The tests `vm.etch` a mock LLM precompile at `0x0802` so the full
commit → reveal → judge → finalize lifecycle runs in the local EVM simulator
(the real Ritual precompile isn't present off-chain).

### Deploy

```bash
# Local simulated chain
npx hardhat ignition deploy ignition/modules/CommitRevealAIJudge.ts

# Ritual chain (set DEPLOYER_PRIVATE_KEY via keystore or env — never commit it)
npx hardhat ignition deploy --network ritual ignition/modules/CommitRevealAIJudge.ts
```

> ⚠️ **Secrets:** never put a private key in a tracked file. Use
> `npx hardhat keystore set DEPLOYER_PRIVATE_KEY` or a gitignored `.env`.
> The deploy key used for this homework is a throwaway testnet/faucet key.

---

*Original workshop starter: `/hardhat` holds the smart contracts, `/web` holds
the Next.js frontend.*
