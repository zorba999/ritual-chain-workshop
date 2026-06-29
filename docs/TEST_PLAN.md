# Test Plan — Commit-Reveal Bounty

Tests live in
[`hardhat/contracts/CommitRevealAIJudge.t.sol`](../hardhat/contracts/CommitRevealAIJudge.t.sol)
and run with:

```bash
cd hardhat
npx hardhat test solidity
```

The real Ritual LLM precompile (`0x0802`) does not exist in the local EVM
simulator, so the suite `vm.etch`-es a `MockLLMPrecompile` at that address which
returns a well-formed successful judging response. This lets the entire
commit → reveal → judge → finalize lifecycle run locally.

**Status: 23/23 passing** (incl. a 256-run fuzz test).

## Coverage matrix

### Commit phase

| Case | Expectation | Test |
| --- | --- | --- |
| Valid commitment stored | `exists=true, revealed=false`, hash matches | `test_SubmitCommitment_Stores` |
| Same participant commits twice | revert `already committed` | `test_RevertWhen_DoubleCommit` |
| Commit after submission deadline | revert `submissions closed` | `test_RevertWhen_CommitAfterDeadline` |
| Commit with zero hash | revert `empty commitment` | `test_RevertWhen_EmptyCommitment` |
| More than `MAX_SUBMISSIONS` (10) | 11th reverts `too many submissions` | `test_RevertWhen_TooManyCommitments` |

### Reveal phase — valid

| Case | Expectation | Test |
| --- | --- | --- |
| Correct answer + salt | reveal stored, `revealedCount=1` | `test_Reveal_Valid` |
| Arbitrary answer/salt round-trip | always reveals when commitment was built correctly | `testFuzz_CommitRevealRoundTrip` (fuzz) |

### Reveal phase — invalid (the important edge cases)

| Case | Expectation | Test |
| --- | --- | --- |
| Reveal before submission deadline | revert `reveal not open` | `test_RevertWhen_RevealBeforeSubmissionDeadline` |
| Reveal after reveal deadline | revert `reveal closed` | `test_RevertWhen_RevealAfterRevealDeadline` |
| Wrong salt | revert `commitment mismatch` | `test_RevertWhen_RevealWrongSalt` |
| Tampered answer | revert `commitment mismatch` | `test_RevertWhen_RevealWrongAnswer` |
| Reveal with no commitment | revert `no commitment` | `test_RevertWhen_RevealNoCommitment` |
| Reveal twice | revert `already revealed` | `test_RevertWhen_DoubleReveal` |
| **Copied commitment, revealed by another address** | revert `commitment mismatch`; original committer still succeeds | `test_RevertWhen_CopiedCommitmentRevealedByOther` |

> The last row is the core fairness property: even copying the exact commitment
> bytes is useless because the hash binds `msg.sender`.

### Judging

| Case | Expectation | Test |
| --- | --- | --- |
| Judge after reveal deadline with ≥1 reveal | `judged=true`, `aiReview` populated | `test_JudgeAll_Succeeds` |
| Judge before reveal deadline | revert `reveal not over` | `test_RevertWhen_JudgeBeforeRevealDeadline` |
| Judge with zero reveals | revert `no revealed answers` | `test_RevertWhen_JudgeNoReveals` |
| Non-owner judges | revert `not bounty owner` | `test_RevertWhen_NonOwnerJudges` |

### Finalization

| Case | Expectation | Test |
| --- | --- | --- |
| Owner finalizes valid index | winner paid, `finalized=true`, reward zeroed | `test_FinalizeWinner_PaysWinner` |
| Finalize before judging | revert `not judged yet` | `test_RevertWhen_FinalizeBeforeJudge` |
| Finalize out-of-range index | revert `invalid winner index` | `test_RevertWhen_FinalizeInvalidIndex` |
| Non-owner finalizes | revert `not bounty owner` | `test_RevertWhen_NonOwnerFinalizes` |

### End-to-end

| Case | Expectation | Test |
| --- | --- | --- |
| Two participants, full lifecycle, owner picks winner #1 | correct payout to chosen winner | `test_FullLifecycle` |

## Things deliberately covered by design (not just asserts)

- **Reentrancy:** `finalizeWinner` zeroes `reward` before the external `call`
  (checks-effects-interactions). A second finalize reverts on `already finalized`.
- **Reward escrow:** reward is locked at `createBounty` and can only leave via a
  single successful `finalizeWinner`.
- **Batch judging:** `judgeAll` makes exactly one precompile call regardless of
  the number of revealed answers.
