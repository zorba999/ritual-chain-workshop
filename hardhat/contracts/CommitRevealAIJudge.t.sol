// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealAIJudge} from "./CommitRevealAIJudge.sol";

/**
 * @dev Stand-in for the Ritual LLM inference precompile (0x0802).
 *
 * The real precompile is provided by Ritual block builders inside a TEE and is
 * not present in the local EDR simulator, so we `vm.etch` this mock's runtime
 * code at the precompile address. Its return shape matches what
 * {PrecompileConsumer._executePrecompile} expects for short-running async
 * precompiles: abi.encode(bytes simmedInput, bytes actualOutput), where
 * actualOutput = abi.encode(bool hasError, bytes completion, bytes, string, ConvoHistory).
 */
contract MockLLMPrecompile {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // Catch-all that returns a well-formed, successful judging response.
    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory completion = bytes('{"winnerIndex":0,"summary":"ok"}');
        bytes memory actualOutput = abi.encode(
            false, // hasError
            completion, // completionData
            bytes(""), // (unused field)
            "", // errorMessage
            ConvoHistory("", "", "") // convo history
        );
        // Short-running async precompile envelope: (simmedInput, actualOutput).
        return abi.encode(bytes(""), actualOutput);
    }
}

contract CommitRevealAIJudgeTest is Test {
    CommitRevealAIJudge internal judge;

    address internal constant LLM_PRECOMPILE =
        0x0000000000000000000000000000000000000802;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal reward = 1 ether;
    uint256 internal subDeadline;
    uint256 internal revealDeadline;
    uint256 internal bountyId;

    // Reused test answer/salt.
    string internal constant ANSWER = "the answer is 42, with a detailed rationale";
    bytes32 internal constant SALT = keccak256("alice-secret-salt");

    function setUp() public {
        judge = new CommitRevealAIJudge();

        subDeadline = block.timestamp + 1 days;
        revealDeadline = subDeadline + 1 days;

        // Owner creates a funded bounty.
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        bountyId = judge.createBounty{value: reward}(
            "Best gas optimization",
            "Pick the answer that best satisfies the rubric.",
            subDeadline,
            revealDeadline
        );

        // Install the LLM precompile mock at 0x0802.
        MockLLMPrecompile mock = new MockLLMPrecompile();
        vm.etch(LLM_PRECOMPILE, address(mock).code);
    }

    // ------------------------------------------------------------------ //
    //  Helpers
    // ------------------------------------------------------------------ //

    function _commit(address who, string memory answer, bytes32 salt) internal {
        bytes32 c = judge.previewCommitment(answer, salt, who, bountyId);
        vm.prank(who);
        judge.submitCommitment(bountyId, c);
    }

    function _warpToReveal() internal {
        vm.warp(subDeadline + 1);
    }

    function _warpToJudge() internal {
        vm.warp(revealDeadline + 1);
    }

    // ------------------------------------------------------------------ //
    //  Commit phase
    // ------------------------------------------------------------------ //

    function test_SubmitCommitment_Stores() public {
        _commit(alice, ANSWER, SALT);
        (bytes32 h, bool exists, bool revealed) = judge.getCommitment(
            bountyId,
            alice
        );
        assertTrue(exists);
        assertFalse(revealed);
        assertEq(h, judge.previewCommitment(ANSWER, SALT, alice, bountyId));
    }

    function test_RevertWhen_DoubleCommit() public {
        _commit(alice, ANSWER, SALT);
        bytes32 c = judge.previewCommitment(ANSWER, SALT, alice, bountyId);
        vm.prank(alice);
        vm.expectRevert("already committed");
        judge.submitCommitment(bountyId, c);
    }

    function test_RevertWhen_CommitAfterDeadline() public {
        _warpToReveal();
        bytes32 c = judge.previewCommitment(ANSWER, SALT, alice, bountyId);
        vm.prank(alice);
        vm.expectRevert("submissions closed");
        judge.submitCommitment(bountyId, c);
    }

    function test_RevertWhen_EmptyCommitment() public {
        vm.prank(alice);
        vm.expectRevert("empty commitment");
        judge.submitCommitment(bountyId, bytes32(0));
    }

    function test_RevertWhen_TooManyCommitments() public {
        // MAX_SUBMISSIONS (10) commitments succeed; the 11th reverts.
        for (uint256 i = 0; i < 10; i++) {
            address a = address(uint160(0x10000 + i));
            vm.prank(a);
            judge.submitCommitment(bountyId, keccak256(abi.encode(i)));
        }
        vm.prank(address(0x20000));
        vm.expectRevert("too many submissions");
        judge.submitCommitment(bountyId, keccak256("overflow"));
    }

    // ------------------------------------------------------------------ //
    //  Reveal phase — valid
    // ------------------------------------------------------------------ //

    function test_Reveal_Valid() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();

        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);

        (, , bool revealed) = judge.getCommitment(bountyId, alice);
        assertTrue(revealed);
        assertEq(judge.getRevealedCount(bountyId), 1);

        (address submitter, string memory ans) = judge.getRevealedSubmission(
            bountyId,
            0
        );
        assertEq(submitter, alice);
        assertEq(ans, ANSWER);
    }

    // ------------------------------------------------------------------ //
    //  Reveal phase — invalid
    // ------------------------------------------------------------------ //

    function test_RevertWhen_RevealBeforeSubmissionDeadline() public {
        _commit(alice, ANSWER, SALT);
        vm.prank(alice);
        vm.expectRevert("reveal not open");
        judge.revealAnswer(bountyId, ANSWER, SALT);
    }

    function test_RevertWhen_RevealAfterRevealDeadline() public {
        _commit(alice, ANSWER, SALT);
        _warpToJudge(); // past revealDeadline
        vm.prank(alice);
        vm.expectRevert("reveal closed");
        judge.revealAnswer(bountyId, ANSWER, SALT);
    }

    function test_RevertWhen_RevealWrongSalt() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(bountyId, ANSWER, keccak256("wrong-salt"));
    }

    function test_RevertWhen_RevealWrongAnswer() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(bountyId, "a tampered answer", SALT);
    }

    function test_RevertWhen_RevealNoCommitment() public {
        _warpToReveal();
        vm.prank(bob);
        vm.expectRevert("no commitment");
        judge.revealAnswer(bountyId, ANSWER, SALT);
    }

    function test_RevertWhen_DoubleReveal() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.startPrank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        vm.expectRevert("already revealed");
        judge.revealAnswer(bountyId, ANSWER, SALT);
        vm.stopPrank();
    }

    /**
     * @dev The headline fairness property: even if Bob copies Alice's *exact*
     * commitment bytes during the submission phase, he cannot reveal her answer
     * because the on-chain hash folds in `msg.sender`. His reveal is computed
     * with Bob's address and no longer matches the stored commitment.
     */
    function test_RevertWhen_CopiedCommitmentRevealedByOther() public {
        bytes32 aliceCommitment = judge.previewCommitment(
            ANSWER,
            SALT,
            alice,
            bountyId
        );
        vm.prank(alice);
        judge.submitCommitment(bountyId, aliceCommitment);

        // Bob copies the exact commitment hash he saw on-chain.
        vm.prank(bob);
        judge.submitCommitment(bountyId, aliceCommitment);

        _warpToReveal();

        // Bob knows Alice's answer + salt but still cannot reveal it as his own.
        vm.prank(bob);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(bountyId, ANSWER, SALT);

        // Alice reveals her own entry successfully.
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        assertEq(judge.getRevealedCount(bountyId), 1);
    }

    // ------------------------------------------------------------------ //
    //  Judging
    // ------------------------------------------------------------------ //

    function test_JudgeAll_Succeeds() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);

        _warpToJudge();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        CommitRevealAIJudge.BountyView memory v = judge.getBounty(bountyId);
        assertTrue(v.judged);
        assertGt(v.aiReview.length, 0);
    }

    function test_RevertWhen_JudgeBeforeRevealDeadline() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);

        vm.prank(owner);
        vm.expectRevert("reveal not over");
        judge.judgeAll(bountyId, hex"00");
    }

    function test_RevertWhen_JudgeNoReveals() public {
        _commit(alice, ANSWER, SALT); // committed but never revealed
        _warpToJudge();
        vm.prank(owner);
        vm.expectRevert("no revealed answers");
        judge.judgeAll(bountyId, hex"00");
    }

    function test_RevertWhen_NonOwnerJudges() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);

        _warpToJudge();
        vm.prank(alice);
        vm.expectRevert("not bounty owner");
        judge.judgeAll(bountyId, hex"00");
    }

    // ------------------------------------------------------------------ //
    //  Finalization
    // ------------------------------------------------------------------ //

    function test_FinalizeWinner_PaysWinner() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        _warpToJudge();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        uint256 before = alice.balance;
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);
        assertEq(alice.balance, before + reward);

        CommitRevealAIJudge.BountyView memory v = judge.getBounty(bountyId);
        assertTrue(v.finalized);
        assertEq(v.winnerIndex, 0);
        assertEq(v.reward, 0);
    }

    function test_RevertWhen_FinalizeBeforeJudge() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);

        vm.prank(owner);
        vm.expectRevert("not judged yet");
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_FinalizeInvalidIndex() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        _warpToJudge();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        vm.prank(owner);
        vm.expectRevert("invalid winner index");
        judge.finalizeWinner(bountyId, 5);
    }

    function test_RevertWhen_NonOwnerFinalizes() public {
        _commit(alice, ANSWER, SALT);
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        _warpToJudge();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        vm.prank(bob);
        vm.expectRevert("not bounty owner");
        judge.finalizeWinner(bountyId, 0);
    }

    // ------------------------------------------------------------------ //
    //  End-to-end + fuzz
    // ------------------------------------------------------------------ //

    function test_FullLifecycle() public {
        // Two participants commit during the submission phase.
        _commit(alice, ANSWER, SALT);
        _commit(bob, "bob's competing answer", keccak256("bob-salt"));

        // Reveal phase.
        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, ANSWER, SALT);
        vm.prank(bob);
        judge.revealAnswer(bountyId, "bob's competing answer", keccak256("bob-salt"));
        assertEq(judge.getRevealedCount(bountyId), 2);

        // Judge after the reveal window closes.
        _warpToJudge();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"00");

        // Owner finalizes Bob (index 1) as the human-decided winner.
        uint256 before = bob.balance;
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 1);
        assertEq(bob.balance, before + reward);
    }

    function testFuzz_CommitRevealRoundTrip(
        string calldata answer,
        bytes32 salt
    ) public {
        vm.assume(bytes(answer).length <= judge.MAX_ANSWER_LENGTH());

        bytes32 c = judge.previewCommitment(answer, salt, alice, bountyId);
        vm.prank(alice);
        judge.submitCommitment(bountyId, c);

        _warpToReveal();
        vm.prank(alice);
        judge.revealAnswer(bountyId, answer, salt);

        (, , bool revealed) = judge.getCommitment(bountyId, alice);
        assertTrue(revealed);
    }
}
