// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {inco} from "@inco/lightning/src/Lib.sol";
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {Ciphertide} from "../Ciphertide.sol";
import {CiphertideHarness} from "./CiphertideHarness.sol";

/// @notice Tests for Bombardment and Carpet's stepped firing sequence:
///         useBombardment and useCarpet each strike more cells in one
///         resolution than fits safely under Base's protocol level
///         per-transaction gas cap (EIP-7825, 2^24 = 16,777,216 gas), so
///         both are split into several calls with the same anchor,
///         mirroring placeMyBoardStep's own stepped design (see
///         Ciphertide.useBombardment's own comment). This file covers what
///         PlacementTest already covers for placement's own steps, applied
///         to these two skills: real step progress, and the turn stays
///         locked to the acting player and the step sequence cannot be
///         skipped, reordered, or hijacked by the opponent.
contract AreaSkillStepsTest is IncoTest {
    CiphertideHarness game;

    function setUp() public override {
        super.setUp();
        game = new CiphertideHarness();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _createAndJoinMatchWithCaptains(address p0, address p1, uint8 p0Captain, uint8 p1Captain)
        internal
        returns (uint256 matchId)
    {
        vm.prank(p0);
        matchId = game.createMatch(p0Captain);
        vm.prank(p1);
        game.joinMatch(matchId, p1Captain);
    }

    /// @dev Non-overlapping test layout on the 15x15 board (row stride 15):
    /// ship k occupies row k, columns 0..len-1. Mirrors
    /// CiphertideTest._standardTestBoard.
    function _standardTestBoard() internal pure returns (uint256 boardMask, uint256[6] memory shipMask) {
        uint8[6] memory lengths = [5, 4, 4, 4, 3, 3];
        for (uint8 i = 0; i < 6; i++) {
            uint256 rowBase = uint256(i) * 15;
            uint256 mask = ((uint256(1) << lengths[i]) - 1) << rowBase;
            shipMask[i] = mask;
            boardMask |= mask;
        }
    }

    function _tinyShipsBoard() internal pure returns (uint256 boardMask, uint256[6] memory shipMask) {
        for (uint8 i = 0; i < 6; i++) {
            uint256 mask = uint256(1) << i;
            shipMask[i] = mask;
            boardMask |= mask;
        }
    }

    function _rollAndConfirmDiceUntilDecided(uint256 matchId, address p0) internal {
        uint256 diceFee = inco.getFee() * 2;
        for (uint256 attempts = 0; attempts < 10; attempts++) {
            vm.prank(p0);
            game.rollDice{value: diceFee}(matchId);
            processAllOperations();

            (bytes32 rollAHandle, bytes32 rollBHandle) = game.getPendingRoll(matchId);
            (DecryptionAttestation memory attA, bytes[] memory sigA) =
                getDecryptionAttestation(p0, HandleWithProof({handle: rollAHandle, proof: _emptyAllowanceProof()}));
            (DecryptionAttestation memory attB, bytes[] memory sigB) =
                getDecryptionAttestation(p0, HandleWithProof({handle: rollBHandle, proof: _emptyAllowanceProof()}));

            vm.prank(p0);
            game.confirmDiceRoll(matchId, attA, sigA, attB, sigB);
            if (game.getPhase(matchId) == Ciphertide.Phase.InProgress) return;
        }
        revert("dice roll did not decide after 10 attempts");
    }

    function _setupInProgressMatchWithCaptains(
        address p0,
        address p1,
        uint8 p0Captain,
        uint8 p1Captain,
        uint256 board0,
        uint256[6] memory ships0
    ) internal returns (uint256 matchId) {
        matchId = _createAndJoinMatchWithCaptains(p0, p1, p0Captain, p1Captain);
        (uint256 board1, uint256[6] memory ships1) = _tinyShipsBoard();
        game.setBoardForTesting(matchId, 0, board0, ships0);
        game.setBoardForTesting(matchId, 1, board1, ships1);
        processAllOperations();

        _rollAndConfirmDiceUntilDecided(matchId, p0);
    }

    function _passTurnWithMiss(uint256 matchId, address shooter, uint8 waterCell) internal {
        vm.prank(shooter);
        game.shoot(matchId, waterCell);
        processAllOperations();
        (bytes32 hitHandle, bytes32 allDestroyedHandle, bytes32 mineHitHandle, bytes32 shieldBreakHandle) =
            game.getPendingShotHandles(matchId);
        (DecryptionAttestation memory hitAtt, bytes[] memory hitSigs) =
            getDecryptionAttestation(shooter, HandleWithProof({handle: hitHandle, proof: _emptyAllowanceProof()}));
        (DecryptionAttestation memory winAtt, bytes[] memory winSigs) = getDecryptionAttestation(
            shooter, HandleWithProof({handle: allDestroyedHandle, proof: _emptyAllowanceProof()})
        );
        (DecryptionAttestation memory mineAtt, bytes[] memory mineSigs) = getDecryptionAttestation(
            shooter, HandleWithProof({handle: mineHitHandle, proof: _emptyAllowanceProof()})
        );
        (DecryptionAttestation memory shieldAtt, bytes[] memory shieldSigs) = getDecryptionAttestation(
            shooter, HandleWithProof({handle: shieldBreakHandle, proof: _emptyAllowanceProof()})
        );
        game.confirmShot(matchId, hitAtt, hitSigs, winAtt, winSigs, mineAtt, mineSigs, shieldAtt, shieldSigs);
    }

    // ---------------------------------------------------------------
    // Bombardment
    // ---------------------------------------------------------------

    function _bombardmentMatch() internal returns (uint256 matchId) {
        uint8 bombardmentCaptain = game.CAPTAIN_BOMBARDMENT();
        uint8 shieldCaptain = game.CAPTAIN_SHIELD();
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        matchId = _setupInProgressMatchWithCaptains(alice, bob, shieldCaptain, bombardmentCaptain, board0, ships0);
        if (game.getTurn(matchId) != bob) {
            _passTurnWithMiss(matchId, alice, 200);
        }
    }

    /// @dev areaSkill.stepsDone should count up by BOMBARDMENT_STEP_SIZE
    /// per step (capped at the total), then reset to 0 once the final step
    /// fires, mirroring PlacementTest.testPlacementStepsProgressCorrectly
    /// for placeMyBoardStep's own step counter.
    function testBombardmentStepsProgressCorrectly() public {
        uint256 matchId = _bombardmentMatch();
        uint8 stepSize = game.BOMBARDMENT_STEP_SIZE();
        uint8 total = game.BOMBARDMENT_STRIKE_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        uint8 done = 0;
        for (uint8 i = 0; i < stepsNeeded; i++) {
            assertEq(game.getAreaSkillStepsDone(matchId), done, "steps done should match steps run so far");
            vm.prank(bob);
            game.useBombardment(matchId, 0, 0);
            processAllOperations();
            uint8 expectedChunk = (total - done) < stepSize ? (total - done) : stepSize;
            done += expectedChunk;
            if (done >= total) {
                assertEq(game.getAreaSkillStepsDone(matchId), 0, "steps done should reset once the sequence fires");
            } else {
                assertEq(game.getAreaSkillStepsDone(matchId), done, "steps done should advance by one chunk per step");
            }
        }
    }

    /// @dev The turn stays on the acting player (bob) throughout every
    /// intermediate step, exactly as it would for a single-transaction
    /// skill: it only moves once confirmBombardment resolves the action.
    /// While bob's bombardment is mid-sequence, alice (whose turn it is
    /// NOT) cannot act at all: any other action she tries reverts with
    /// "previous action not yet confirmed" (pendingAction is still
    /// Bombardment, the same _beginAction gate a normal single-transaction
    /// action already enforces), and even the exact same skill call from
    /// her reverts with "not your turn" instead (see
    /// testBombardmentContinuationRejectsWrongPlayer), proving the
    /// opponent is genuinely locked out both ways, not merely gated by one
    /// specific check.
    function testBombardmentTurnStaysLockedToActorAcrossSteps() public {
        uint256 matchId = _bombardmentMatch();
        uint8 stepSize = game.BOMBARDMENT_STEP_SIZE();
        uint8 total = game.BOMBARDMENT_STRIKE_COUNT();

        vm.prank(bob);
        game.useBombardment(matchId, 0, 0);
        processAllOperations();
        assertLt(stepSize, total, "test assumes bombardment needs more than one step");
        assertEq(game.getTurn(matchId), bob, "turn must stay on the actor mid-sequence, not move early");

        vm.prank(alice);
        vm.expectRevert("previous action not yet confirmed");
        game.shoot(matchId, 210);

        vm.prank(alice);
        vm.expectRevert("previous action not yet confirmed");
        game.useSonar(matchId, 0, 0);
    }

    /// @dev Only the acting player (bob) can submit a bombardment's
    /// continuation steps: alice, the defender whose turn it is not,
    /// cannot hijack the in-flight sequence, even with the exact same
    /// anchor bob used.
    function testBombardmentContinuationRejectsWrongPlayer() public {
        uint256 matchId = _bombardmentMatch();

        vm.prank(bob);
        game.useBombardment(matchId, 0, 0);
        processAllOperations();

        vm.prank(alice);
        vm.expectRevert("not your turn");
        game.useBombardment(matchId, 0, 0);
    }

    /// @dev A continuation step must reuse the exact anchor the opening
    /// step used: a mismatched anchor reverts rather than silently
    /// redirecting the in-flight sequence to a different area.
    function testBombardmentContinuationRejectsMismatchedAnchor() public {
        uint256 matchId = _bombardmentMatch();

        vm.prank(bob);
        game.useBombardment(matchId, 0, 0);
        processAllOperations();

        vm.prank(bob);
        vm.expectRevert("anchor must match the in-progress skill");
        game.useBombardment(matchId, 1, 1);
    }

    /// @dev Once every chunk has resolved and the reveal has been
    /// requested, pendingAction stays Bombardment through the awaiting-
    /// confirmation window too, so a further call must be rejected as
    /// "already fired", not silently treated as a fresh opening call
    /// (which would re-pick cells and desync from what was just revealed).
    function testBombardmentCannotBeCalledAgainWhileAwaitingConfirmation() public {
        uint256 matchId = _bombardmentMatch();
        uint8 stepSize = game.BOMBARDMENT_STEP_SIZE();
        uint8 total = game.BOMBARDMENT_STRIKE_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        for (uint8 i = 0; i < stepsNeeded; i++) {
            vm.prank(bob);
            game.useBombardment(matchId, 0, 0);
            processAllOperations();
        }

        vm.prank(bob);
        vm.expectRevert("skill already fired, awaiting confirmation");
        game.useBombardment(matchId, 0, 0);
    }

    /// @dev The acting player's clock keeps running across steps exactly
    /// as it would for a single-transaction action: elapsed wall-clock
    /// time between steps is charged against bob's remaining time on
    /// every step, not just the first, and the match's lastMoveTimestamp
    /// resets after every step so each step's own elapsed window starts
    /// fresh (mirroring _chargeElapsedTurnTime's own contract, shared with
    /// _beginAction).
    function testBombardmentClockChargesElapsedTimeAcrossEveryStep() public {
        uint256 matchId = _bombardmentMatch();
        uint8 bobIdx = game.getPlayerAddress(matchId, 0) == bob ? 0 : 1;
        uint8 stepSize = game.BOMBARDMENT_STEP_SIZE();
        uint8 total = game.BOMBARDMENT_STRIKE_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        uint256 remainingBefore = game.getRemainingTime(matchId, bobIdx);

        for (uint8 i = 0; i < stepsNeeded; i++) {
            vm.warp(block.timestamp + 7);
            vm.prank(bob);
            game.useBombardment(matchId, 0, 0);
            processAllOperations();
        }

        uint256 remainingAfter = game.getRemainingTime(matchId, bobIdx);
        assertEq(
            remainingBefore - remainingAfter,
            7 * stepsNeeded,
            "elapsed time across every step should be charged, exactly like one continuous action"
        );
    }

    // ---------------------------------------------------------------
    // Carpet
    // ---------------------------------------------------------------

    function _carpetMatch() internal returns (uint256 matchId) {
        uint8 carpetCaptain = game.CAPTAIN_CARPET();
        uint8 shieldCaptain = game.CAPTAIN_SHIELD();
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        matchId = _setupInProgressMatchWithCaptains(alice, bob, carpetCaptain, shieldCaptain, board0, ships0);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }
    }

    function testCarpetStepsProgressCorrectly() public {
        uint256 matchId = _carpetMatch();
        uint8 stepSize = game.CARPET_STEP_SIZE();
        uint8 total = game.CARPET_CELL_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        uint8 done = 0;
        for (uint8 i = 0; i < stepsNeeded; i++) {
            assertEq(game.getAreaSkillStepsDone(matchId), done, "steps done should match steps run so far");
            vm.prank(alice);
            game.useCarpet(matchId, 0, 0);
            processAllOperations();
            uint8 expectedChunk = (total - done) < stepSize ? (total - done) : stepSize;
            done += expectedChunk;
            if (done >= total) {
                assertEq(game.getAreaSkillStepsDone(matchId), 0, "steps done should reset once the sequence fires");
            } else {
                assertEq(game.getAreaSkillStepsDone(matchId), done, "steps done should advance by one chunk per step");
            }
        }
    }

    /// @dev Mirrors testBombardmentTurnStaysLockedToActorAcrossSteps for
    /// Carpet: while alice's carpet is mid-sequence, bob (not his turn)
    /// cannot act at all.
    function testCarpetTurnStaysLockedToActorAcrossSteps() public {
        uint256 matchId = _carpetMatch();
        uint8 stepSize = game.CARPET_STEP_SIZE();
        uint8 total = game.CARPET_CELL_COUNT();

        vm.prank(alice);
        game.useCarpet(matchId, 0, 0);
        processAllOperations();
        assertLt(stepSize, total, "test assumes carpet needs more than one step");
        assertEq(game.getTurn(matchId), alice, "turn must stay on the actor mid-sequence, not move early");

        vm.prank(bob);
        vm.expectRevert("previous action not yet confirmed");
        game.shoot(matchId, 210);

        vm.prank(bob);
        vm.expectRevert("previous action not yet confirmed");
        game.useSonar(matchId, 0, 0);
    }

    function testCarpetContinuationRejectsWrongPlayer() public {
        uint256 matchId = _carpetMatch();

        vm.prank(alice);
        game.useCarpet(matchId, 0, 0);
        processAllOperations();

        vm.prank(bob);
        vm.expectRevert("not your turn");
        game.useCarpet(matchId, 0, 0);
    }

    function testCarpetContinuationRejectsMismatchedAnchor() public {
        uint256 matchId = _carpetMatch();

        vm.prank(alice);
        game.useCarpet(matchId, 0, 0);
        processAllOperations();

        vm.prank(alice);
        vm.expectRevert("anchor must match the in-progress skill");
        game.useCarpet(matchId, 1, 1);
    }

    function testCarpetCannotBeCalledAgainWhileAwaitingConfirmation() public {
        uint256 matchId = _carpetMatch();
        uint8 stepSize = game.CARPET_STEP_SIZE();
        uint8 total = game.CARPET_CELL_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        for (uint8 i = 0; i < stepsNeeded; i++) {
            vm.prank(alice);
            game.useCarpet(matchId, 0, 0);
            processAllOperations();
        }

        vm.prank(alice);
        vm.expectRevert("skill already fired, awaiting confirmation");
        game.useCarpet(matchId, 0, 0);
    }

    function testCarpetClockChargesElapsedTimeAcrossEveryStep() public {
        uint256 matchId = _carpetMatch();
        uint8 aliceIdx = game.getPlayerAddress(matchId, 0) == alice ? 0 : 1;
        uint8 stepSize = game.CARPET_STEP_SIZE();
        uint8 total = game.CARPET_CELL_COUNT();
        uint8 stepsNeeded = (total + stepSize - 1) / stepSize;

        uint256 remainingBefore = game.getRemainingTime(matchId, aliceIdx);

        for (uint8 i = 0; i < stepsNeeded; i++) {
            vm.warp(block.timestamp + 5);
            vm.prank(alice);
            game.useCarpet(matchId, 0, 0);
            processAllOperations();
        }

        uint256 remainingAfter = game.getRemainingTime(matchId, aliceIdx);
        assertEq(
            remainingBefore - remainingAfter,
            5 * stepsNeeded,
            "elapsed time across every step should be charged, exactly like one continuous action"
        );
    }
}
