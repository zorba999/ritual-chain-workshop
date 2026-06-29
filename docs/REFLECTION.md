# Reflection

**What should be public, what should stay hidden, and what should be decided by
AI versus by a human in a bounty system?**

The bounty's *rules* should be fully public — the reward, the rubric, the
deadlines, and the final result — because participants need to trust that the
game is fair and verifiable on-chain. Each participant's *answer* should stay
hidden during the submission window, since publishing it early just lets later
entrants copy the good ideas and win unfairly; a commitment hash (or an encrypted
blob in the Ritual-native design) is enough to lock in an entry without exposing
it. Once submissions are closed, answers can be revealed for verification, and in
the TEE design even the losing answers can stay private while still being scored.
The *salt and any private keys* must always remain off-chain secrets, never
written to public storage. The AI should do the **objective, scalable** part:
reading every submission against the rubric in one batch and recommending a
ranked winner with reasons. The human owner should keep the **accountable,
final** decisions: confirming the AI's recommendation, handling edge cases or
suspected manipulation, and actually releasing the funds. This human-in-the-loop
split matters because an LLM can be prompt-injected or simply wrong, so no money
should move automatically from raw model output. In short: make the *process*
transparent and the *content* private until it's safe to reveal, let AI judge at
scale, and let a human own the payout.
