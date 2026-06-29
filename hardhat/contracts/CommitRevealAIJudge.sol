// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title CommitRevealAIJudge
 * @notice Privacy-preserving bounty judge using a commit-reveal scheme.
 *
 * Problem this solves
 * -------------------
 * In the original {AIJudge} contract, `submitAnswer` stored the plaintext
 * answer on-chain immediately. Anyone could read earlier submissions, copy the
 * good ideas, and submit an improved version before the deadline. That is unfair
 * in a winner-takes-all bounty.
 *
 * The fix: a two-phase commit-reveal flow.
 *   1. Submission phase: participants publish only a *commitment hash*. The
 *      plaintext answer never touches the chain, so nothing can be copied.
 *   2. Reveal phase: after the submission deadline, participants reveal their
 *      answer + salt. The contract recomputes the hash and only accepts it if it
 *      matches the original commitment.
 *
 * The commitment binds the answer to the participant and the bounty:
 *
 *      commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
 *
 * Including `msg.sender` and `bountyId` means a copied commitment is useless to
 * anyone else: they cannot reveal it because the hash would be computed with
 * *their* address and would not match.
 *
 * Only valid, revealed answers are eligible for batch AI judging via the Ritual
 * LLM precompile. A human owner finalizes the single winner and the payout.
 */
contract CommitRevealAIJudge is PrecompileConsumer {
    // --------------------------------------------------------------------- //
    //                              Constants                                //
    // --------------------------------------------------------------------- //

    /// @notice Max number of commitments accepted per bounty (bounds gas on reveal/judge).
    uint256 public constant MAX_SUBMISSIONS = 10;

    /// @notice Max length of a revealed answer, in bytes.
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    // --------------------------------------------------------------------- //
    //                                State                                  //
    // --------------------------------------------------------------------- //

    uint256 public nextBountyId = 1;

    /// @dev One participant's commitment for a given bounty.
    struct Commitment {
        bytes32 hash; // keccak256(answer, salt, sender, bountyId)
        bool exists; // true once a commitment was submitted
        bool revealed; // true once successfully revealed
    }

    /// @dev A revealed answer that is eligible for AI judging.
    struct RevealedSubmission {
        address submitter;
        string answer;
    }

    /// @dev Mirrors the Ritual LLM precompile's ConvoHistory return field.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    /// @dev Flat, memory-friendly view of a bounty (returned by {getBounty}).
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 committerCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes aiReview;
    }

    /**
     * @dev A bounty. Note this struct contains a mapping, so it can only live in
     * storage. The auto-generated getter for `bounties` omits the mapping and
     * the dynamic arrays — use the explicit view functions below for those.
     */
    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commit until here
        uint256 revealDeadline; // reveal until here, judge after here
        bool judged;
        bool finalized;
        uint256 winnerIndex; // index into `revealed`
        bytes aiReview; // raw bytes returned by the LLM precompile
        address[] committers; // everyone who committed (for enumeration)
        RevealedSubmission[] revealed; // answers eligible for judging
        mapping(address => Commitment) commitments;
    }

    mapping(uint256 => Bounty) public bounties;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed revealedIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // --------------------------------------------------------------------- //
    //                               Modifiers                               //
    // --------------------------------------------------------------------- //

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // --------------------------------------------------------------------- //
    //                              Lifecycle                                //
    // --------------------------------------------------------------------- //

    /**
     * @notice Create a bounty escrowing `msg.value` as the reward.
     * @param title              Human-readable bounty title.
     * @param rubric             Judging rubric the AI must follow.
     * @param submissionDeadline Unix time; commitments accepted strictly before it.
     * @param revealDeadline     Unix time; reveals accepted in (submission, reveal).
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline in past");
        require(revealDeadline > submissionDeadline, "reveal must follow submission");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /**
     * @notice Phase 1 — submit a commitment hash. The plaintext answer is NOT
     *         revealed and never stored on-chain at this stage.
     * @dev    Compute the commitment off-chain (see {previewCommitment}):
     *         keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
     *
     * Rules:
     * - only before the submission deadline,
     * - one commitment per participant per bounty,
     * - at most MAX_SUBMISSIONS commitments per bounty.
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "submissions closed");
        require(!bounty.commitments[msg.sender].exists, "already committed");
        require(bounty.committers.length < MAX_SUBMISSIONS, "too many submissions");
        require(commitment != bytes32(0), "empty commitment");

        bounty.commitments[msg.sender] = Commitment({
            hash: commitment,
            exists: true,
            revealed: false
        });
        bounty.committers.push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /**
     * @notice Phase 2 — reveal the answer and salt that produced your commitment.
     * @dev    The contract recomputes the commitment with msg.sender + bountyId
     *         folded in, so only the original committer can reveal their entry.
     *
     * Rules:
     * - only after the submission deadline and before the reveal deadline,
     * - the caller must have an unrevealed commitment,
     * - keccak256(answer, salt, sender, bountyId) must equal the commitment.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "reveal not open");
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        Commitment storage c = bounty.commitments[msg.sender];
        require(c.exists, "no commitment");
        require(!c.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == c.hash, "commitment mismatch");

        c.revealed = true;
        bounty.revealed.push(
            RevealedSubmission({submitter: msg.sender, answer: answer})
        );

        emit AnswerRevealed(bountyId, bounty.revealed.length - 1, msg.sender);
    }

    /**
     * @notice Phase 3 — batch-judge all revealed answers with one Ritual LLM call.
     * @dev    `llmInput` is the ABI-encoded LLM request built off-chain. It must
     *         contain exactly the revealed answers (see README for how the
     *         frontend serialises them). The owner cannot judge until the reveal
     *         window has closed, so the input is fixed and auditable.
     *
     *         We do NOT loop one LLM call per submission — all answers go in a
     *         single batched request, per the assignment constraints.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealed.length > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Phase 4 — a human owner finalizes the winner and releases payment.
     * @dev    The AI *recommends* a winner; the owner decides and is the only one
     *         who can move funds. `winnerIndex` indexes into the revealed answers.
     *         Uses checks-effects-interactions (reward zeroed before transfer) to
     *         block reentrancy.
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.revealed.length, "invalid winner index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.revealed[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // --------------------------------------------------------------------- //
    //                              View helpers                             //
    // --------------------------------------------------------------------- //

    /**
     * @notice Pure helper to compute a commitment off-chain or in tests.
     * @dev    Mirrors the exact on-chain hashing used by {revealAnswer}.
     */
    function previewCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    /// @notice Full bounty view (mapping + arrays omitted; counts returned instead).
    /// @dev Returns a single memory struct to avoid stack-too-deep without viaIR.
    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory v) {
        Bounty storage bounty = bounties[bountyId];
        v = BountyView({
            owner: bounty.owner,
            title: bounty.title,
            rubric: bounty.rubric,
            reward: bounty.reward,
            submissionDeadline: bounty.submissionDeadline,
            revealDeadline: bounty.revealDeadline,
            judged: bounty.judged,
            finalized: bounty.finalized,
            committerCount: bounty.committers.length,
            revealedCount: bounty.revealed.length,
            winnerIndex: bounty.winnerIndex,
            aiReview: bounty.aiReview
        });
    }

    /// @notice A participant's commitment status for a bounty.
    function getCommitment(
        uint256 bountyId,
        address submitter
    )
        external
        view
        bountyExists(bountyId)
        returns (bytes32 hash, bool exists, bool revealed)
    {
        Commitment storage c = bounties[bountyId].commitments[submitter];
        return (c.hash, c.exists, c.revealed);
    }

    /// @notice Number of revealed (judging-eligible) answers.
    function getRevealedCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].revealed.length;
    }

    /// @notice Read a single revealed answer (only populated after reveal phase).
    function getRevealedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.revealed.length, "invalid index");
        RevealedSubmission storage s = bounty.revealed[index];
        return (s.submitter, s.answer);
    }
}
