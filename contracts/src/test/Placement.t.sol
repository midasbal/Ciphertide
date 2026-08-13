// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {console} from "forge-std/console.sol";
import {Ciphertide} from "../Ciphertide.sol";
import {CiphertideHarness} from "./CiphertideHarness.sol";

/// @notice Tests for the random encrypted placement (Option A: bounded
///         per-ship arithmetic placement). Covers validity of the produced
///         layout across many independent matches, that the layout stays
///         unreadable to the opponent, and the all-attempts-fail retry path.
contract PlacementTest is IncoTest {
    using e for euint256;
    using e for ebool;

    CiphertideHarness game;
    uint8 constant NUM_SHIPS = 6;
    uint8 constant BOARD_SIZE = 15;

    function setUp() public override {
        super.setUp();
        game = new CiphertideHarness();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _createAndJoinMatch(address p0, address p1) internal returns (uint256 matchId) {
        // Cache the captain ids before pranking, calling a view function
        // while building the next call would consume the prank early.
        uint8 p0Captain = game.CAPTAIN_SHIELD();
        uint8 p1Captain = game.CAPTAIN_BOMBARDMENT();
        vm.prank(p0);
        matchId = game.createMatch(p0Captain);
        vm.prank(p1);
        game.joinMatch(matchId, p1Captain);
    }

    function _placementFee() internal view returns (uint256) {
        uint256 shipDraws = uint256(NUM_SHIPS) * game.PLACEMENT_ATTEMPTS_PER_SHIP();
        uint256 mineDraws = uint256(game.MINES_PER_PLAYER()) * game.MINE_PLACEMENT_ATTEMPTS();
        return inco.getFee() * (shipDraws + mineDraws);
    }

    /// @dev Submits a placement and confirms it, returning whether the
    /// attested allPlaced bit was true.
    function _placeAndConfirm(uint256 matchId, address player) internal returns (bool allPlaced) {
        uint256 fee = _placementFee();
        vm.prank(player);
        game.placeMyBoard{value: fee}(matchId);
        processAllOperations();

        uint8 playerIdx = game.getPlayerAddress(matchId, 0) == player ? 0 : 1;
        bytes32 handle = game.getPendingPlacementHandle(matchId, playerIdx);
        (DecryptionAttestation memory att, bytes[] memory sigs) =
            getDecryptionAttestation(player, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));

        // No prank: confirmPlacement is authorized by the attestation
        // matching playerIdx's pending handle, not by msg.sender, so the
        // test contract itself standing in for a relayer is enough.
        game.confirmPlacement(matchId, playerIdx, att, sigs);
        allPlaced = uint256(att.value) != 0;
    }

    function testPlacementProducesValidNonOverlappingInGridLayoutAcrossManySeeds() public {
        uint8[6] memory lengths = [5, 4, 4, 4, 3, 3];

        // Each createMatch/placeMyBoard call advances the mock's internal
        // randomness counter, so running this across many independent
        // matches exercises many different sets of random draws.
        // Kept modest: each round replays ~120 mock Inco operations, and the
        // mock's op log grows unbounded within a single test's memory limit.
        for (uint256 round = 0; round < 3; round++) {
            uint256 matchId = _createAndJoinMatch(alice, bob);
            bool allPlaced = _placeAndConfirm(matchId, alice);
            assertTrue(allPlaced, "placement should succeed within the attempt budget");
            assertTrue(game.isPlaced(matchId, 0), "player should be marked placed");

            uint256 seenMask = 0;
            uint256 totalBits = 0;
            for (uint8 i = 0; i < NUM_SHIPS; i++) {
                euint256 shipMaskHandle = game.getShipMask(matchId, 0, i);
                uint256 shipMask = getUint256Value(shipMaskHandle);

                assertEq(_popcount(shipMask), lengths[i], "ship should occupy exactly its configured length");
                assertTrue(_isValidStraightRun(shipMask, lengths[i]), "ship should form an in-grid straight run");
                assertEq(seenMask & shipMask, 0, "ships should never overlap each other");

                seenMask |= shipMask;
                totalBits += lengths[i];
            }

            euint256 boardHandle = game.getBoardMask(matchId, 0);
            uint256 board = getUint256Value(boardHandle);
            assertEq(board, seenMask, "board mask should be exactly the union of ship masks");
            assertEq(_popcount(board), totalBits, "board should have exactly the fleet's total cell count");
        }
    }

    /// @dev Isolates just the placeMyBoard call's own gas cost, separate
    /// from IncoTest's one-time mock infrastructure deployment in setUp().
    function testPlacementGasUsage() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);
        uint256 fee = _placementFee();

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        game.placeMyBoard{value: fee}(matchId);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("placeMyBoard gas used (6 ships x 20 attempts):", gasUsed);
    }

    /// @dev confirmPlacement takes an explicit playerIdx and authorizes via
    /// the attestation matching that slot's pending handle, not msg.sender,
    /// so a third party (a relayer, or the frontend acting on the player's
    /// behalf) can submit it.
    function testConfirmPlacementCanBeSubmittedByAThirdParty() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);
        uint256 fee = _placementFee();

        vm.prank(alice);
        game.placeMyBoard{value: fee}(matchId);
        processAllOperations();

        bytes32 handle = game.getPendingPlacementHandle(matchId, 0);
        // carol requests the attestation and submits it, alice never calls
        // confirmPlacement herself.
        (DecryptionAttestation memory att, bytes[] memory sigs) =
            getDecryptionAttestation(carol, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));

        vm.prank(carol);
        game.confirmPlacement(matchId, 0, att, sigs);

        assertTrue(game.isPlaced(matchId, 0));
    }

    function testPlacementNotReadableByOpponent() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);
        _placeAndConfirm(matchId, alice);

        euint256 boardHandle = game.getBoardMask(matchId, 0);
        assertTrue(inco.isAllowed(euint256.unwrap(boardHandle), alice), "owner should be able to read their own board");
        assertFalse(inco.isAllowed(euint256.unwrap(boardHandle), bob), "opponent must not be able to read the board");

        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            euint256 shipHandle = game.getShipMask(matchId, 0, i);
            assertFalse(
                inco.isAllowed(euint256.unwrap(shipHandle), bob), "opponent must not be able to read any ship mask"
            );
        }
    }

    function testMinesLandOnWaterOnlyAndAreNotReadableByOpponent() public {
        for (uint256 round = 0; round < 3; round++) {
            uint256 matchId = _createAndJoinMatch(alice, bob);
            _placeAndConfirm(matchId, alice);

            euint256 mineHandle = game.getMineMask(matchId, 0);
            assertTrue(inco.isAllowed(euint256.unwrap(mineHandle), alice), "owner should be able to read their mines");
            assertFalse(inco.isAllowed(euint256.unwrap(mineHandle), bob), "opponent must not be able to read the mines");

            uint256 mineMask = getUint256Value(mineHandle);
            assertEq(_popcount(mineMask), game.MINES_PER_PLAYER(), "should place exactly the configured mine count");

            uint256 boardMask = getUint256Value(game.getBoardMask(matchId, 0));
            assertEq(mineMask & boardMask, 0, "mines should never land on a ship cell");
        }
    }

    function testPlacementRetryPathAfterAllAttemptsFail() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);

        // Placement fees are paid from the contract's own balance regardless
        // of how it got funded, fund it directly since this test-only entry
        // point is not payable.
        vm.deal(address(game), 1 ether);

        vm.prank(alice);
        game.forcePlacementFailureForTesting(matchId, 0);
        processAllOperations();

        bytes32 handle = game.getPendingPlacementHandle(matchId, 0);
        (DecryptionAttestation memory att, bytes[] memory sigs) =
            getDecryptionAttestation(alice, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));
        assertEq(uint256(att.value), 0, "placement against a full board must fail every attempt");

        game.confirmPlacement(matchId, 0, att, sigs);
        assertFalse(game.isPlaced(matchId, 0), "player should not be marked placed after a failed attempt");

        // Retry with a normal, empty starting board should succeed.
        bool allPlaced = _placeAndConfirm(matchId, alice);
        assertTrue(allPlaced, "retry against an empty board should succeed");
        assertTrue(game.isPlaced(matchId, 0));
    }

    function _popcount(uint256 x) internal pure returns (uint8 count) {
        while (x != 0) {
            count += uint8(x & 1);
            x >>= 1;
        }
    }

    /// @dev Checks that the set bits of `mask` form a single contiguous
    /// horizontal or vertical run of exactly `length` cells within the
    /// BOARD_SIZE x BOARD_SIZE grid (row-major, row stride BOARD_SIZE).
    function _isValidStraightRun(uint256 mask, uint8 length) internal pure returns (bool) {
        uint16[] memory positions = new uint16[](length);
        uint8 found = 0;
        for (uint16 pos = 0; pos < uint16(BOARD_SIZE) * uint16(BOARD_SIZE); pos++) {
            if ((mask >> pos) & 1 == 1) {
                if (found >= length) return false; // more bits than expected
                positions[found] = pos;
                found++;
            }
        }
        if (found != length) return false;

        uint16 row0 = positions[0] / BOARD_SIZE;
        uint16 col0 = positions[0] % BOARD_SIZE;

        bool horizontalOk = true;
        bool verticalOk = true;
        for (uint8 i = 0; i < length; i++) {
            uint16 row = positions[i] / BOARD_SIZE;
            uint16 col = positions[i] % BOARD_SIZE;
            if (!(row == row0 && col == col0 + i)) horizontalOk = false;
            if (!(col == col0 && row == row0 + i)) verticalOk = false;
        }
        return horizontalOk || verticalOk;
    }
}
