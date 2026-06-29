# Architecture Note — Commit-Reveal vs. Ritual-Native Hidden Submissions

This note compares the two approaches to hiding bounty submissions and then
gives a concrete design for the **advanced track** (Ritual-native, TEE-backed).

---

## 1. The two designs at a glance

| | **Commit-Reveal** (required, implemented) | **Ritual-Native TEE** (advanced, design) |
| --- | --- | --- |
| What's hidden during submission | Only a `keccak256` hash is on-chain | Encrypted ciphertext / a reference to it |
| When plaintext becomes public | **At reveal**, before AI judging | Only the **winner/bundle** after judging — losers can stay hidden |
| Who ever sees all plaintext | Everyone, after the reveal phase | Only the **TEE executor** (and the LLM inside it) |
| Trust assumption | Pure cryptography + EVM; trustless | Trust the Ritual TEE attestation + key management |
| Works on any EVM chain | ✅ Yes | ❌ Needs Ritual precompiles |
| Gas / storage | Cheap (32-byte hash) until reveal | Cheap (store ciphertext ref + hash off-chain) |
| Main weakness | Answers go public **before** judging; a participant who skips reveal keeps their answer secret but is disqualified | More moving parts; relies on TEE integrity |

**Key takeaway:** commit-reveal stops *copying during the submission window*, but
every revealed answer is public the moment it's revealed — i.e. *before* the AI
ranks them. The Ritual-native design closes that last gap: answers can be judged
while still encrypted, so they never have to be published just to be scored.

---

## 2. Commit-Reveal (implemented)

```
                       submissionDeadline            revealDeadline
   ────────────────────────────│──────────────────────────│────────────────────►
   COMMIT phase                │  REVEAL phase             │  JUDGE → FINALIZE
   on-chain: keccak hash only  │  on-chain: answer + salt  │  batch LLM, payout
   (nothing copyable)          │  hash must match          │  (owner only)
```

- **Plaintext location:** off-chain (in the participant's wallet/app) during the
  commit phase; on-chain after they reveal.
- **On-chain:** the 32-byte commitment, then the revealed answer string.
- **Binding:** `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
  Folding in `msg.sender` + `bountyId` makes a copied commitment unrevealable by
  anyone else.
- **Batch judging:** `judgeAll` builds **one** LLM request containing all
  revealed answers (see `web/src/lib/ritualLlm.ts`).

This is the trustless baseline. Its accepted limitation: revealed answers are
public before the model picks a winner.

---

## 3. Ritual-Native Hidden Submissions (advanced design)

Goal: answers stay **encrypted** until judging is done — the public chain never
sees plaintext losing answers, and copying is impossible at every stage.

### 3.1 Components

- **Ritual TEE executor** — runs the judging logic inside a Trusted Execution
  Environment. It can see private inputs but the host/public chain cannot.
- **DKMS precompile (`0x081B`)** / Ritual key flow — a TEE-held key pair.
  Participants encrypt to the executor's public key; only code running inside the
  attested TEE can decrypt.
- **Off-chain blob store** (IPFS / Ritual storage) — holds ciphertexts and, later,
  the revealed bundle. The chain stores only **references + hashes**, never large
  plaintext.

### 3.2 Where plaintext answers exist & who can read them

| Stage | Plaintext exists at | Who can read it |
| --- | --- | --- |
| Submission | Participant's device only | The participant |
| In transit / at rest | Nowhere in plaintext — only ciphertext (encrypted to the TEE key) | No one (ciphertext on IPFS + on-chain ref) |
| Judging | **Inside the TEE only**, transiently in memory | The TEE executor + the LLM call it makes |
| After judging | The published "revealed bundle" | Everyone (but now it's too late to copy) |

The public chain and other participants **never** see a competitor's plaintext
before judging.

### 3.3 On-chain vs off-chain

| On-chain (contract storage) | Off-chain |
| --- | --- |
| Bounty config (reward, deadlines, owner) | Encrypted answer blobs (ciphertext) |
| Per-participant `submissionRef` (e.g. `ipfs://…`) | The plaintext answers (only inside the TEE during judging) |
| Per-participant `submissionHash` (hash of ciphertext, anti-tamper) | The final **revealed answers bundle** (JSON) |
| AI verdict / `aiReview` (winner + summary) | |
| `revealedAnswersRef` + `revealedAnswersHash` after judging | |

> **Why:** storing big strings on-chain is expensive and pointless. We store a
> hash so the chain can *commit* to exactly which ciphertext/bundle was used,
> while the bytes live in cheap off-chain storage.

### 3.4 How the LLM receives all submissions together (batch)

During `judgeAll`, the TEE workflow:

1. Reads every `submissionRef` for the bounty from the contract.
2. Fetches the ciphertexts from off-chain storage.
3. Decrypts them **inside the TEE** using the DKMS/TEE key.
4. Assembles **one** prompt — a JSON array of all answers + the rubric — and
   makes a **single** LLM inference call (precompile `0x0802`). Never one call
   per answer.
5. Produces a verdict: `{ winnerIndex, ranking, summary }`.

### 3.5 How the final reveal happens & how the contract commits to it

After judging, the executor publishes a **revealed answers bundle** (all answers,
or at least the winner) to off-chain storage and writes back to the contract:

```jsonc
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://bafy.../bundle.json",
  "revealedAnswersHash": "0x…",   // keccak256 of the bundle bytes
  "summary": "Submission 2 is the strongest answer."
}
```

The contract stores `revealedAnswersRef` and `revealedAnswersHash`. Anyone can
now fetch the bundle, hash it, and check it matches `revealedAnswersHash` — proof
that the published answers are exactly what the TEE judged, with no swaps or
edits. The owner then calls `finalizeWinner` (human-in-the-loop) to release funds.

### 3.6 Private submission flow (diagram)

```
 Participant                Off-chain store        Contract (chain)        Ritual TEE Executor
     │                           │                      │                        │
     │ 1. encrypt(answer, TEEpub)│                      │                        │
     │──ciphertext──────────────►│                      │                        │
     │                           │  ipfs://…            │                        │
     │ 2. submitEncrypted(ref, hash(ciphertext)) ──────►│ store ref+hash         │
     │                           │                      │ (plaintext = none)     │
     │ · · · · · · · · · · submissionDeadline passes · · · · · · · · · · · · · · ·│
     │                           │                      │ 3. judgeAll() ────────►│ fetch all refs
     │                           │◄─────────────────────│                        │ decrypt in TEE
     │                           │   (reads ciphertexts)│                        │ ONE batch LLM call
     │                           │                      │◄── verdict + bundle ───│ publish bundle
     │                           │  bundle.json         │ store ref+hash+review  │
     │ · · · · · · · · · · · · · · · · · · · · · · · · · │ 4. finalizeWinner() (owner) → pay
```

### 3.7 Ritual feature focus (how this is more than "just call an LLM")

- **TEE-backed execution:** judging sees private inputs while keeping them hidden
  from the public chain.
- **Encrypted inputs/secrets:** answers (and any storage credentials) are
  encrypted to the TEE key via DKMS — never plaintext on-chain.
- **Batch judging:** all submissions judged in **one** LLM request, not a loop.
- **Human-in-the-loop:** the AI recommends; the owner finalizes the payout.

---

## 4. Recommendation

Ship **commit-reveal** as the production baseline today — it's trustless and runs
on any EVM chain. Layer the **Ritual-native TEE** design on top where the extra
guarantee matters: keeping losing answers private and never publishing plaintext
*before* the AI has judged. The contract surface (`submit*`, `judgeAll`,
`finalizeWinner`) stays the same shape, so the upgrade is mostly swapping the
hash-commitment for an encrypted-ref commitment plus a TEE judging step.
