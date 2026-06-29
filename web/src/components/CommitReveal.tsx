"use client";

import { useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canCommit, canReveal, type Bounty } from "@/lib/bounty";
import {
  computeCommitment,
  randomSalt,
  saveReveal,
  loadReveal,
} from "@/lib/commit";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Input,
  Textarea,
  Button,
  TxStatus,
  Notice,
  Badge,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

export function CommitReveal({
  bountyId,
  bounty,
  onChanged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onChanged: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();

  // This participant's commitment state: [hash, exists, revealed].
  const commitmentQ = useReadContract({
    address: contractAddress,
    abi: aiJudgeAbi,
    functionName: "getCommitment",
    args: address ? [bountyId, address] : undefined,
    chainId: ritualChain.id,
    query: { enabled: Boolean(address && contractAddress), refetchInterval: 12_000 },
  });
  const hasCommitted = commitmentQ.data?.[1] === true;
  const hasRevealed = commitmentQ.data?.[2] === true;

  const inCommit = canCommit(bounty, now);
  const inReveal = canReveal(bounty, now);

  // Outside both windows (or judged/finalized) there's nothing to do here.
  if (!inCommit && !inReveal) return null;

  return inCommit ? (
    <CommitCard
      bountyId={bountyId}
      address={address}
      isConnected={isConnected}
      hasCommitted={hasCommitted}
      onChanged={() => {
        void commitmentQ.refetch();
        onChanged();
      }}
    />
  ) : (
    <RevealCard
      bountyId={bountyId}
      address={address}
      isConnected={isConnected}
      hasCommitted={hasCommitted}
      hasRevealed={hasRevealed}
      onChanged={() => {
        void commitmentQ.refetch();
        onChanged();
      }}
    />
  );
}

function CommitCard({
  bountyId,
  address,
  isConnected,
  hasCommitted,
  onChanged,
}: {
  bountyId: bigint;
  address?: `0x${string}`;
  isConnected: boolean;
  hasCommitted: boolean;
  onChanged: () => void;
}) {
  const [answer, setAnswer] = useState("");
  const tx = useWriteTx(() => {
    setAnswer("");
    onChanged();
  });

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;
    const salt = randomSalt();
    const commitment = computeCommitment({
      answer: answer.trim(),
      salt,
      submitter: address,
      bountyId,
    });
    // Persist BEFORE sending so the reveal data survives even if the tab closes.
    saveReveal(contractAddress, bountyId, address, { answer: answer.trim(), salt });
    try {
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  return (
    <Card>
      <CardHeader
        title="Submit a commitment"
        subtitle="Commit phase — only a hash of your answer goes on-chain."
        action={hasCommitted ? <Badge tone="green">Committed</Badge> : undefined}
      />
      <CardBody>
        {hasCommitted ? (
          <Notice tone="green">
            You&apos;ve committed to this bounty. Your answer + salt are stored locally in this
            browser. Come back after the submission deadline to reveal.
          </Notice>
        ) : (
          <form onSubmit={handleCommit} className="space-y-3">
            <Notice tone="indigo">
              Your plaintext answer is never sent now — only{" "}
              <span className="font-mono">keccak256(answer, salt, you, bountyId)</span>. Nobody can
              read or copy it during the commit phase.
            </Notice>
            <Field label="Your answer" hint="Kept in this browser until you reveal it.">
              <Textarea
                value={answer}
                onChange={(e) => setAnswer(e.target.value)}
                rows={5}
                placeholder="Write your submission…"
              />
            </Field>
            <Button
              type="submit"
              disabled={!isConnected || !answer.trim() || tx.isBusy}
              className="w-full"
            >
              {tx.isBusy ? "Committing…" : "Submit commitment"}
            </Button>
            {!isConnected && (
              <p className="text-xs text-zinc-500">Connect your wallet to commit.</p>
            )}
            <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
          </form>
        )}
      </CardBody>
    </Card>
  );
}

function RevealCard({
  bountyId,
  address,
  isConnected,
  hasCommitted,
  hasRevealed,
  onChanged,
}: {
  bountyId: bigint;
  address?: `0x${string}`;
  isConnected: boolean;
  hasCommitted: boolean;
  hasRevealed: boolean;
  onChanged: () => void;
}) {
  // Prefill from the locally-stored commit data when available.
  const stored =
    address && contractAddress ? loadReveal(contractAddress, bountyId, address) : null;
  const [answer, setAnswer] = useState(stored?.answer ?? "");
  const [salt, setSalt] = useState<string>(stored?.salt ?? "");
  const tx = useWriteTx(() => onChanged());

  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !salt.trim() || !contractAddress) return;
    try {
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, answer, salt as `0x${string}`],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  if (!hasCommitted) {
    return (
      <Card>
        <CardHeader title="Reveal phase" subtitle="Reveal your committed answer." />
        <CardBody>
          <Notice tone="zinc">
            You didn&apos;t commit to this bounty during the submission phase, so there is nothing
            to reveal.
          </Notice>
        </CardBody>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader
        title="Reveal your answer"
        subtitle="Reveal phase — submission is closed; reveal must match your commitment."
        action={hasRevealed ? <Badge tone="green">Revealed</Badge> : undefined}
      />
      <CardBody>
        {hasRevealed ? (
          <Notice tone="green">
            Your answer is revealed and is now eligible for AI judging.
          </Notice>
        ) : (
          <form onSubmit={handleReveal} className="space-y-3">
            {!stored && (
              <Notice tone="amber">
                No local copy of your answer/salt was found in this browser. Paste the exact answer
                and salt you committed with.
              </Notice>
            )}
            <Field label="Your answer">
              <Textarea
                value={answer}
                onChange={(e) => setAnswer(e.target.value)}
                rows={5}
                placeholder="The exact answer you committed…"
              />
            </Field>
            <Field label="Salt" hint="The 0x… salt generated when you committed.">
              <Input
                value={salt}
                onChange={(e) => setSalt(e.target.value)}
                placeholder="0x…"
                className="font-mono"
              />
            </Field>
            <Button
              type="submit"
              disabled={!isConnected || !answer.trim() || !salt.trim() || tx.isBusy}
              className="w-full"
            >
              {tx.isBusy ? "Revealing…" : "Reveal answer"}
            </Button>
            <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
          </form>
        )}
      </CardBody>
    </Card>
  );
}
