"use client";

import { useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress, executorAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canJudge, type Bounty } from "@/lib/bounty";
import { useNow } from "@/hooks/useNow";
import { buildJudgeAllLlmInput, type JudgeSubmission } from "@/lib/ritualLlm";
import { useWriteTx } from "@/hooks/useWriteTx";
import { useRitualWalletStatus } from "@/hooks/useRitualWalletStatus";
import { RitualWalletPanel } from "@/components/RitualWalletPanel";
import { Card, CardHeader, CardBody, Button, TxStatus, Notice, Spinner } from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

export function JudgeAll({
  bountyId,
  bounty,
  isOwner,
  onJudged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  isOwner: boolean;
  onJudged: () => void;
}) {
  const { address } = useAccount();
  const publicClient = usePublicClient({ chainId: ritualChain.id });
  const now = useNow();
  const [gathering, setGathering] = useState(false);
  const [gatherError, setGatherError] = useState<string | null>(null);
  const tx = useWriteTx(() => onJudged());

  // Preflight the *connected* wallet's RitualWallet funding (not the bounty
  // contract) — judgeAll spends prepaid+locked RITUAL via the LLM precompile.
  const walletStatus = useRitualWalletStatus(address);

  const count = Number(bounty.revealedCount);

  // Gate per spec: owner only, reveal window closed, has revealed answers, not judged.
  if (!isOwner || bounty.judged || bounty.finalized || count === 0) {
    return null;
  }

  const revealClosed = canJudge(bounty, now);

  async function handleJudge() {
    if (!publicClient || !contractAddress || !walletStatus.ready) return;
    setGatherError(null);
    setGathering(true);
    try {
      // Load every *revealed* answer for this bounty.
      const submissions: JudgeSubmission[] = [];
      for (let i = 0; i < count; i++) {
        const [submitter, answer] = await publicClient.readContract({
          address: contractAddress,
          abi: aiJudgeAbi,
          functionName: "getRevealedSubmission",
          args: [bountyId, BigInt(i)],
        });
        submissions.push({ index: i, submitter, answer });
      }

      // Build the batch judging prompt and encode the Ritual LLM request.
      const llmInput = buildJudgeAllLlmInput({
        executorAddress,
        title: bounty.title,
        rubric: bounty.rubric,
        submissions,
      });

      setGathering(false);

      // Submit it on-chain — one batched LLM inference over all answers.
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "judgeAll",
        args: [bountyId, llmInput],
        chainId: ritualChain.id,
      });
    } catch (e) {
      setGathering(false);
      setGatherError(
        (e as { shortMessage?: string; message?: string }).shortMessage ||
          (e as Error).message ||
          "Failed to gather submissions.",
      );
    }
  }

  const busy = gathering || tx.isBusy;
  const fundingReady = walletStatus.ready === true;

  return (
    <Card>
      <CardHeader
        title="Judge all revealed answers"
        subtitle="Sends one Ritual LLM request ranking every revealed answer."
      />
      <CardBody className="space-y-3">
        <Notice tone="indigo">AI review is advisory. The bounty owner finalizes the winner.</Notice>

        {!revealClosed ? (
          <Notice tone="amber">
            Judging opens after the reveal deadline, so participants can&apos;t game the result.
          </Notice>
        ) : (
          <>
            <RitualWalletPanel status={walletStatus} onDeposited={walletStatus.refetch} />

            <Button onClick={handleJudge} disabled={busy || !fundingReady} className="w-full">
              {gathering ? (
                <>
                  <Spinner /> Gathering {count} revealed answers…
                </>
              ) : tx.isBusy ? (
                "Judging…"
              ) : !fundingReady ? (
                "Fund RitualWallet to judge"
              ) : (
                `Judge all (${count})`
              )}
            </Button>
            {gatherError && <Notice tone="red">{gatherError}</Notice>}
            <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
          </>
        )}
      </CardBody>
    </Card>
  );
}
