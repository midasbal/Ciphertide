// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {console} from "forge-std/console.sol";
import {Battleship} from "../Battleship.sol";
import {BattleshipHarness} from "./BattleshipHarness.sol";

/// @notice Tests for the core loop: match creation and join, dice roll,
///         shot resolution, turn handling and win detection. Board state is
///         seeded directly through the test-only harness hook rather than
///         through real random placement, since that piece is still pending
///         a design decision (see the design writeup).
contract BattleshipTest is IncoTest {
    using e for euint256;
    using e for ebool;

    BattleshipHarness game;

    function setUp() public override {
        super.setUp();
        game = new BattleshipHarness();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function _createAndJoinMatch(address p0, address p1) internal returns (uint256 matchId) {
        vm.prank(p0);
        matchId = game.createMatch();
        vm.prank(p1);
        game.joinMatch(matchId);
    }

    /// @dev Non-overlapping test layout on the 15x15 board (row stride 15):
    /// ship k occupies row k, columns 0..len-1. Used for tests where the
    /// exact shape does not need to match SHIP_LENGTHS, only be known and
    /// non-overlapping.
    function _standardTestBoard() internal pure returns (uint256 boardMask, uint256[6] memory shipMask) {
        uint8[6] memory lengths = [5, 4, 4, 4, 3, 3];
        for (uint8 i = 0; i < 6; i++) {
            uint256 rowBase = uint256(i) * 15;
            uint256 mask = ((uint256(1) << lengths[i]) - 1) << rowBase;
            shipMask[i] = mask;
            boardMask |= mask;
        }
    }

    /// @dev Board with six single-cell ships at positions 0..5, used for the
    /// win-detection test so the whole fleet can be sunk in six shots.
    function _tinyShipsBoard() internal pure returns (uint256 boardMask, uint256[6] memory shipMask) {
        for (uint8 i = 0; i < 6; i++) {
            uint256 mask = uint256(1) << i;
            shipMask[i] = mask;
            boardMask |= mask;
        }
    }

    function _setupInProgressMatch(address p0, address p1, uint256 board0, uint256[6] memory ships0)
        internal
        returns (uint256 matchId)
    {
        matchId = _createAndJoinMatch(p0, p1);
        (uint256 board1, uint256[6] memory ships1) = _tinyShipsBoard();
        game.setBoardForTesting(matchId, 0, board0, ships0);
        game.setBoardForTesting(matchId, 1, board1, ships1);
        processAllOperations();

        _rollAndConfirmDiceUntilDecided(matchId, p0);
    }

    function _rollAndConfirmDiceUntilDecided(uint256 matchId, address p0) internal {
        uint256 diceFee = inco.getFee() * 2;
        for (uint256 attempts = 0; attempts < 10; attempts++) {
            _rollDiceOnce(matchId, p0, diceFee);
            if (game.getPhase(matchId) == Battleship.Phase.InProgress) {
                return;
            }
        }
        revert("dice roll did not decide after 10 attempts");
    }

    function _rollDiceOnce(uint256 matchId, address p0, uint256 diceFee) internal {
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
    }

    function _confirmPendingShot(uint256 matchId, address requester) internal {
        (bytes32 hitHandle, bytes32 allDestroyedHandle) = game.getPendingShotHandles(matchId);
        (DecryptionAttestation memory hitAtt, bytes[] memory hitSigs) =
            getDecryptionAttestation(requester, HandleWithProof({handle: hitHandle, proof: _emptyAllowanceProof()}));
        (DecryptionAttestation memory winAtt, bytes[] memory winSigs) = getDecryptionAttestation(
            requester, HandleWithProof({handle: allDestroyedHandle, proof: _emptyAllowanceProof()})
        );
        game.confirmShot(matchId, hitAtt, hitSigs, winAtt, winSigs);
    }

    function testCreateAndJoinMatch() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);
        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.Placing));
        assertEq(game.getPlayerAddress(matchId, 0), alice);
        assertEq(game.getPlayerAddress(matchId, 1), bob);
    }

    function testCannotJoinOwnMatch() public {
        vm.prank(alice);
        uint256 matchId = game.createMatch();
        vm.prank(alice);
        vm.expectRevert("cannot play yourself");
        game.joinMatch(matchId);
    }

    function testDiceRollDecidesTurnAndAdvancesPhase() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address turnPlayer = game.getTurn(matchId);
        assertTrue(turnPlayer == alice || turnPlayer == bob);
        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.InProgress));
    }

    /// @dev confirmDiceRoll is authorized by the attestations matching the
    /// stored roll handles, not by msg.sender, so a third party (a relayer,
    /// or the frontend acting on the player's behalf) can submit it.
    function testConfirmDiceRollCanBeSubmittedByAThirdParty() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _createAndJoinMatch(alice, bob);
        (uint256 board1, uint256[6] memory ships1) = _tinyShipsBoard();
        game.setBoardForTesting(matchId, 0, board0, ships0);
        game.setBoardForTesting(matchId, 1, board1, ships1);
        processAllOperations();

        uint256 diceFee = inco.getFee() * 2;
        for (uint256 attempts = 0; attempts < 10; attempts++) {
            vm.prank(alice);
            game.rollDice{value: diceFee}(matchId);
            processAllOperations();

            (bytes32 rollAHandle, bytes32 rollBHandle) = game.getPendingRoll(matchId);
            (DecryptionAttestation memory attA, bytes[] memory sigA) =
                getDecryptionAttestation(carol, HandleWithProof({handle: rollAHandle, proof: _emptyAllowanceProof()}));
            (DecryptionAttestation memory attB, bytes[] memory sigB) =
                getDecryptionAttestation(carol, HandleWithProof({handle: rollBHandle, proof: _emptyAllowanceProof()}));

            // carol is neither alice nor bob, standing in for a relayer.
            vm.prank(carol);
            game.confirmDiceRoll(matchId, attA, sigA, attB, sigB);

            if (game.getPhase(matchId) == Battleship.Phase.InProgress) {
                assertTrue(game.getTurn(matchId) == alice || game.getTurn(matchId) == bob);
                return;
            }
        }
        revert("dice roll did not decide after 10 attempts");
    }

    function testKnownHitReadsAsHitAndKeepsTurn() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);

        vm.prank(shooter);
        game.shoot(matchId, 0); // cell 0 is occupied on the defender's tiny ships board
        processAllOperations();

        _confirmPendingShot(matchId, shooter);

        assertEq(game.getTurn(matchId), shooter, "shooter should keep the turn after a hit");
        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.InProgress));
    }

    function testShootGasUsage() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address shooter = game.getTurn(matchId);

        vm.prank(shooter);
        uint256 gasBefore = gasleft();
        game.shoot(matchId, 0);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("shoot() gas used (hit + allDestroyed + newlyDestroyed, 3 reveals):", gasUsed);
    }

    function testKnownMissPassesTurn() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;

        // Cell 200 is empty on both test boards (well outside any ship).
        vm.prank(shooter);
        game.shoot(matchId, 200);
        processAllOperations();

        _confirmPendingShot(matchId, shooter);

        assertEq(game.getTurn(matchId), defender, "turn should pass to the defender after a miss");
    }

    function testCannotReshootSameCell() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address shooter = game.getTurn(matchId);

        vm.prank(shooter);
        game.shoot(matchId, 0);
        processAllOperations();
        _confirmPendingShot(matchId, shooter);

        address nextShooter = game.getTurn(matchId);
        vm.prank(nextShooter);
        vm.expectRevert("cell already shot");
        game.shoot(matchId, 0);
    }

    function testHitRevealDoesNotExposeRestOfBoard() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;

        vm.prank(shooter);
        game.shoot(matchId, 0);
        processAllOperations();

        // The shooter can only ever request an attestation for the single
        // revealed hit handle, not for the defender's full board handle,
        // which was never revealed and is not allowed to the shooter.
        uint8 defenderIdx = game.getPlayerAddress(matchId, 0) == defender ? 0 : 1;
        euint256 defenderBoard = game.getBoardMask(matchId, defenderIdx);
        assertFalse(inco.isAllowed(euint256.unwrap(defenderBoard), shooter));
    }

    function testShipDestroyedRevealsMaskOnlyOnceFullyHitAndWinFires() public {
        (uint256 board0, uint256[6] memory ships0) = _tinyShipsBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        uint8 defenderIdx = game.getPlayerAddress(matchId, 0) == shooter ? 1 : 0;

        for (uint8 cell = 0; cell < 6; cell++) {
            address currentShooter = game.getTurn(matchId);
            vm.prank(currentShooter);
            game.shoot(matchId, cell);
            processAllOperations();
            _confirmPendingShot(matchId, currentShooter);

            euint256 revealMask = game.getLastDestroyedMask(matchId, defenderIdx);
            uint256 revealed = getUint256Value(revealMask);
            assertEq(revealed, uint256(1) << cell, "the ship just sunk by this shot should reveal exactly its cell");

            if (cell < 5) {
                assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.InProgress));
            }
        }

        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.Finished));
        assertEq(game.getWinner(matchId), shooter);
    }

    function testClaimTimeoutAfterOpponentStalls() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address waiting = shooter == alice ? bob : alice;

        uint256 budget = game.TIME_BUDGET_SECONDS();
        uint256 buffer = game.TURN_CONFIRMATION_BUFFER_SECONDS();
        vm.warp(block.timestamp + budget + buffer + 1);

        vm.prank(waiting);
        game.claimTimeout(matchId);

        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.Finished));
        assertEq(game.getWinner(matchId), waiting);
    }

    /// @dev Regression test for the clock bug found during review: shoot()
    /// used to leave lastMoveTimestamp unchanged, so claimTimeout compared
    /// "now minus the original turn-start time" against the shooter's
    /// already-reduced remainingTime, double counting the pre-shot decision
    /// time and letting the waiting player claim a timeout win immediately
    /// after a legitimate, on-time shot, before confirmShot was even called.
    function testCannotClaimTimeoutRightAfterAnOnTimeShot() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address waiting = shooter == alice ? bob : alice;

        uint256 budget = game.TIME_BUDGET_SECONDS();

        // Shooter uses almost their whole budget, then shoots right on time.
        vm.warp(block.timestamp + budget - 5);
        vm.prank(shooter);
        game.shoot(matchId, 200); // cell 200 is empty on both test boards

        // No additional time passes at all before the waiting player tries
        // to claim a timeout. The shot just landed on time, this must fail.
        vm.prank(waiting);
        vm.expectRevert("opponent has not timed out yet");
        game.claimTimeout(matchId);

        // The match is still awaiting confirmation, not decided by timeout.
        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.InProgress));
        assertEq(game.getWinner(matchId), address(0));
    }
}
