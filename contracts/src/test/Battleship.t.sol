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
        // Cache the captain ids before pranking, calling a view function
        // while building the next call would consume the prank early.
        uint8 p0Captain = game.CAPTAIN_SHIELD();
        uint8 p1Captain = game.CAPTAIN_BOMBARDMENT();
        vm.prank(p0);
        matchId = game.createMatch(p0Captain);
        vm.prank(p1);
        game.joinMatch(matchId, p1Captain);
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

    function _confirmPendingSonar(uint256 matchId, address requester) internal {
        bytes32 handle = game.getPendingSonarHandle(matchId);
        (DecryptionAttestation memory att, bytes[] memory sigs) =
            getDecryptionAttestation(requester, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));
        game.confirmSonar(matchId, att, sigs);
    }

    function _confirmPendingBarrage(uint256 matchId, address requester) internal returns (uint256 packedValue) {
        (bytes32 packedHandle, bytes32 allDestroyedHandle) = game.getPendingBarrageHandles(matchId);
        (DecryptionAttestation memory packedAtt, bytes[] memory packedSigs) =
            getDecryptionAttestation(requester, HandleWithProof({handle: packedHandle, proof: _emptyAllowanceProof()}));
        (DecryptionAttestation memory winAtt, bytes[] memory winSigs) = getDecryptionAttestation(
            requester, HandleWithProof({handle: allDestroyedHandle, proof: _emptyAllowanceProof()})
        );
        game.confirmBarrage(matchId, packedAtt, packedSigs, winAtt, winSigs);
        packedValue = uint256(packedAtt.value);
    }

    /// @dev Decodes one 7 bit barrage slot (4 bit local position, 3 bit
    /// result code: 0 inactive, 1 miss, 2 ship hit, 3 mine, 4 shield break)
    /// from the packed value, mirroring the contract's own packing.
    function _decodeBarrageSlot(uint256 packedValue, uint8 slotIndex) internal pure returns (uint256 code) {
        uint256 slotValue = (packedValue >> (uint256(slotIndex) * 7)) & 0x7F;
        code = slotValue >> 4;
    }

    /// @dev Fetches the attestation for one of a pending shot's four handles
    /// (0 hit, 1 allDestroyed, 2 mineHit, 3 shieldBreak), re-fetching the
    /// handle set each call. Split out so _confirmPendingShot never holds
    /// more than one attestation pair as a bare local at a time, which
    /// would otherwise overflow the EVM's local variable limit alongside
    /// confirmShot's own four attestation-plus-signatures parameters.
    function _shotHandleAttestation(uint256 matchId, address requester, uint8 which)
        internal
        returns (DecryptionAttestation memory, bytes[] memory)
    {
        (bytes32 hitHandle, bytes32 allDestroyedHandle, bytes32 mineHitHandle, bytes32 shieldBreakHandle) =
            game.getPendingShotHandles(matchId);
        bytes32 handle = which == 0
            ? hitHandle
            : which == 1 ? allDestroyedHandle : which == 2 ? mineHitHandle : shieldBreakHandle;
        return getDecryptionAttestation(requester, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));
    }

    function _confirmPendingShot(uint256 matchId, address requester) internal returns (bool hit, bool shieldBreak) {
        (DecryptionAttestation memory hitAtt, bytes[] memory hitSigs) = _shotHandleAttestation(matchId, requester, 0);
        (DecryptionAttestation memory winAtt, bytes[] memory winSigs) =
            _shotHandleAttestation(matchId, requester, 1);
        (DecryptionAttestation memory mineAtt, bytes[] memory mineSigs) =
            _shotHandleAttestation(matchId, requester, 2);
        (DecryptionAttestation memory shieldAtt, bytes[] memory shieldSigs) =
            _shotHandleAttestation(matchId, requester, 3);
        game.confirmShot(matchId, hitAtt, hitSigs, winAtt, winSigs, mineAtt, mineSigs, shieldAtt, shieldSigs);
        hit = uint256(hitAtt.value) != 0;
        shieldBreak = uint256(shieldAtt.value) != 0;
    }

    function testCreateAndJoinMatch() public {
        uint256 matchId = _createAndJoinMatch(alice, bob);
        assertEq(uint256(game.getPhase(matchId)), uint256(Battleship.Phase.Placing));
        assertEq(game.getPlayerAddress(matchId, 0), alice);
        assertEq(game.getPlayerAddress(matchId, 1), bob);
    }

    function testCannotJoinOwnMatch() public {
        uint8 captain = game.CAPTAIN_SHIELD();
        vm.prank(alice);
        uint256 matchId = game.createMatch(captain);
        vm.prank(alice);
        vm.expectRevert("cannot play yourself");
        game.joinMatch(matchId, captain);
    }

    /// @dev Each player declares their captain independently, including
    /// both players declaring the same one, and getCaptain returns exactly
    /// what was declared for each player slot.
    function testCaptainsAreRecordedAndReturnedPerPlayer() public {
        uint8 aliceCaptain = game.CAPTAIN_RAKE();
        uint8 bobCaptain = game.CAPTAIN_SALVO();

        vm.prank(alice);
        uint256 matchId = game.createMatch(aliceCaptain);
        vm.prank(bob);
        game.joinMatch(matchId, bobCaptain);

        assertEq(game.getCaptain(matchId, 0), aliceCaptain);
        assertEq(game.getCaptain(matchId, 1), bobCaptain);
    }

    function testBothPlayersCanDeclareTheSameCaptain() public {
        uint8 sharedCaptain = game.CAPTAIN_CARPET();

        vm.prank(alice);
        uint256 matchId = game.createMatch(sharedCaptain);
        vm.prank(bob);
        game.joinMatch(matchId, sharedCaptain);

        assertEq(game.getCaptain(matchId, 0), sharedCaptain);
        assertEq(game.getCaptain(matchId, 1), sharedCaptain);
    }

    function testCreateMatchRevertsOnOutOfRangeCaptain() public {
        uint8 numCaptains = game.NUM_CAPTAINS();
        vm.prank(alice);
        vm.expectRevert("invalid captain id");
        game.createMatch(numCaptains + 1);
    }

    function testCreateMatchRevertsOnZeroCaptain() public {
        vm.prank(alice);
        vm.expectRevert("invalid captain id");
        game.createMatch(0);
    }

    function testJoinMatchRevertsOnOutOfRangeCaptain() public {
        uint8 validCaptain = game.CAPTAIN_SHIELD();
        uint8 numCaptains = game.NUM_CAPTAINS();
        vm.prank(alice);
        uint256 matchId = game.createMatch(validCaptain);

        vm.prank(bob);
        vm.expectRevert("invalid captain id");
        game.joinMatch(matchId, numCaptains + 1);
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

    /// @dev shoot() computes the mine check unconditionally every call
    /// (Inco ops can't branch on encrypted state), so a shot that actually
    /// lands on a mine costs the same as any other shot. Measured
    /// separately anyway to have a concrete number for a real mine hit.
    function testShootGasUsageOnAMineCell() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;
        uint8 defenderIdx = game.getPlayerAddress(matchId, 0) == defender ? 0 : 1;

        game.setMinesForTesting(matchId, defenderIdx, uint256(1) << 220, defender);
        processAllOperations();

        vm.prank(shooter);
        uint256 gasBefore = gasleft();
        game.shoot(matchId, 220);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("shoot() gas used, mine cell:", gasUsed);
    }

    function testSonarGasUsage() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address user = game.getTurn(matchId);

        vm.prank(user);
        uint256 gasBefore = gasleft();
        game.useSonar(matchId, 0, 0);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("useSonar() gas used:", gasUsed);
    }

    function testBarrageGasUsage() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address user = game.getTurn(matchId);

        vm.deal(user, 1 ether);
        uint256 fee = _barrageFee();
        vm.prank(user);
        uint256 gasBefore = gasleft();
        game.useBarrage{value: fee}(matchId, 0, 0);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("useBarrage() gas used (6 slots x 8 attempts + 1 count draw):", gasUsed);
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

    /// @dev A shot landing on a mine reads as a miss (it still passes the
    /// turn immediately, mines do not protect the current shot) but grants
    /// the mine's owner a bonus action on their next turn: their first miss
    /// on that turn does not end it. The bonus is spent after being
    /// consulted once, whether that first action was a hit or a miss.
    function testMineTriggerReadsAsMissAndGrantsBonusShot() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;
        uint8 defenderIdx = game.getPlayerAddress(matchId, 0) == defender ? 0 : 1;

        // Cell 220 is empty on both test boards, seed it as the defender's
        // only mine.
        game.setMinesForTesting(matchId, defenderIdx, uint256(1) << 220, defender);
        processAllOperations();

        vm.prank(shooter);
        game.shoot(matchId, 220);
        processAllOperations();
        _confirmPendingShot(matchId, shooter);

        assertEq(game.getTurn(matchId), defender, "a mine still reads as a miss, turn passes normally");
        assertTrue(game.hasBonusShot(matchId, defenderIdx), "triggering the mine should grant the owner a bonus");

        // Defender's first shot on their next turn is a genuine miss (cell
        // 221 is empty on both boards). The bonus should keep their turn.
        vm.prank(defender);
        game.shoot(matchId, 221);
        processAllOperations();
        _confirmPendingShot(matchId, defender);

        assertEq(game.getTurn(matchId), defender, "the bonus should keep the turn through the first miss");
        assertFalse(game.hasBonusShot(matchId, defenderIdx), "the bonus should be spent after being used once");

        // A second miss with no bonus left should pass the turn normally.
        vm.prank(defender);
        game.shoot(matchId, 222);
        processAllOperations();
        _confirmPendingShot(matchId, defender);

        assertEq(game.getTurn(matchId), shooter, "with the bonus spent, a miss passes the turn again");
    }

    function testSonarReturnsCorrectYesAndDoesNotExposeTheBoard() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address user = game.getTurn(matchId);
        address opponent = user == alice ? bob : alice;
        uint8 userIdx = game.getPlayerAddress(matchId, 0) == user ? 0 : 1;

        // Rows 0..4, cols 0..4 definitely contain a ship cell on the
        // standard test board (row 0 is a length 5 ship across cols 0..4).
        vm.prank(user);
        game.useSonar(matchId, 0, 0);
        processAllOperations();
        _confirmPendingSonar(matchId, user);

        assertEq(game.getTurn(matchId), opponent, "sonar is the whole action for the turn, it should pass");
        assertFalse(game.hasSonarCharge(matchId, userIdx), "sonar's single charge should now be spent");

        uint8 opponentIdx = 1 - userIdx;
        euint256 opponentBoard = game.getBoardMask(matchId, opponentIdx);
        assertFalse(inco.isAllowed(euint256.unwrap(opponentBoard), user), "sonar must not expose the full board");
    }

    function testSonarReturnsCorrectNoAndCannotBeReused() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address user = game.getTurn(matchId);
        address opponent = user == alice ? bob : alice;

        // Rows 10..14, cols 10..14 are empty on both test boards.
        vm.prank(user);
        game.useSonar(matchId, 10, 10);
        processAllOperations();

        bytes32 handle = game.getPendingSonarHandle(matchId);
        (DecryptionAttestation memory att, bytes[] memory sigs) =
            getDecryptionAttestation(user, HandleWithProof({handle: handle, proof: _emptyAllowanceProof()}));
        assertEq(uint256(att.value), 0, "an empty area should attest to no");
        game.confirmSonar(matchId, att, sigs);

        // Sonar always passes the turn, so it is now the opponent's turn.
        // Have them take a genuine miss (cell 224 is empty on both test
        // boards) to pass the turn back to the original sonar user.
        vm.prank(opponent);
        game.shoot(matchId, 224);
        processAllOperations();
        _confirmPendingShot(matchId, opponent);
        assertEq(game.getTurn(matchId), user);

        vm.prank(user);
        vm.expectRevert("sonar already used");
        game.useSonar(matchId, 0, 0);
    }

    function _barrageFee() internal view returns (uint256) {
        uint256 draws = uint256(1) + uint256(game.BARRAGE_MAX_CELLS()) * game.BARRAGE_ATTEMPTS_PER_CELL();
        return inco.getFee() * draws;
    }

    function testBarrageStrikesFourToSixCellsAndRevealsEach() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address user = game.getTurn(matchId);

        vm.deal(user, 1 ether);
        uint256 fee = _barrageFee();
        vm.prank(user);
        game.useBarrage{value: fee}(matchId, 0, 0);
        processAllOperations();
        uint256 packed = _confirmPendingBarrage(matchId, user);

        uint256 activeCount = 0;
        for (uint8 k = 0; k < game.BARRAGE_MAX_CELLS(); k++) {
            if (_decodeBarrageSlot(packed, k) != 0) activeCount++;
        }
        assertGe(activeCount, game.BARRAGE_MIN_CELLS(), "barrage should strike at least the minimum cell count");
        assertLe(activeCount, game.BARRAGE_MAX_CELLS(), "barrage should never strike more than the maximum");
    }

    function testBarrageConsumesChargeAndPassesTurn() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address user = game.getTurn(matchId);
        address opponent = user == alice ? bob : alice;
        uint8 userIdx = game.getPlayerAddress(matchId, 0) == user ? 0 : 1;

        vm.deal(user, 1 ether);
        uint256 fee = _barrageFee();
        vm.prank(user);
        game.useBarrage{value: fee}(matchId, 0, 0);
        processAllOperations();
        _confirmPendingBarrage(matchId, user);

        assertEq(game.getTurn(matchId), opponent, "barrage is the whole action for the turn, it should pass");
        assertFalse(game.hasBarrageCharge(matchId, userIdx), "barrage's single charge should now be spent");

        // Pass the turn back so it is user's turn again before checking reuse.
        vm.prank(opponent);
        game.shoot(matchId, 224);
        processAllOperations();
        _confirmPendingShot(matchId, opponent);
        assertEq(game.getTurn(matchId), user);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert("barrage already used");
        game.useBarrage{value: fee}(matchId, 5, 5);
    }

    /// @dev A barrage covering a mine still applies the mine penalty even
    /// when the same barrage also lands ship hits, and the penalty is not
    /// waived by concurrent hits. The area is seeded half mines, half ship
    /// cells (checkerboard) so a random 4 to 6 cell strike is likely to hit
    /// both within a handful of independent matches; this loops until it
    /// observes that co-occurrence at least once and checks the bonus
    /// fires correctly on every single match along the way.
    function testBarrageMinePenaltyAppliesAlongsideShipHits() public {
        uint256[6] memory ships;
        uint256 shipMask;
        uint256 mineMask;
        for (uint8 i = 0; i < 16; i++) {
            uint8 localRow = i / 4;
            uint8 localCol = i % 4;
            uint256 bit = uint256(1) << (localRow * 15 + localCol);
            if (i % 2 == 0) {
                mineMask |= bit;
            } else {
                shipMask |= bit;
            }
        }
        ships[0] = shipMask;

        bool sawBothInSameBarrage = false;
        for (uint256 round = 0; round < 10 && !sawBothInSameBarrage; round++) {
            uint256 matchId = _createAndJoinMatch(alice, bob);
            game.setBoardForTesting(matchId, 0, shipMask, ships);
            (uint256 board1, uint256[6] memory ships1) = _tinyShipsBoard();
            game.setBoardForTesting(matchId, 1, board1, ships1);
            game.setMinesForTesting(matchId, 0, mineMask, alice);
            processAllOperations();
            _rollAndConfirmDiceUntilDecided(matchId, alice);

            // Force alice's board (the mined, half ship checkerboard) to be
            // the defender: only proceed with rounds where bob is on turn.
            if (game.getTurn(matchId) != bob) continue;

            vm.deal(bob, 1 ether);
            uint256 fee = _barrageFee();
            vm.prank(bob);
            game.useBarrage{value: fee}(matchId, 0, 0);
            processAllOperations();
            uint256 packed = _confirmPendingBarrage(matchId, bob);

            bool sawShipHit = false;
            bool sawMine = false;
            for (uint8 k = 0; k < game.BARRAGE_MAX_CELLS(); k++) {
                uint256 code = _decodeBarrageSlot(packed, k);
                if (code == 2) sawShipHit = true;
                if (code == 3) sawMine = true;
            }

            if (sawMine) {
                assertTrue(game.hasBonusShot(matchId, 0), "a struck mine should always grant the owner a bonus");
            } else {
                assertFalse(game.hasBonusShot(matchId, 0), "no mine struck should mean no bonus granted");
            }

            if (sawShipHit && sawMine) {
                sawBothInSameBarrage = true;
            }
        }

        assertTrue(sawBothInSameBarrage, "expected at least one barrage to land both a ship hit and a mine");
    }

    /// @dev Fires a shot known to miss (an empty cell on the defender's
    /// board) purely to pass the turn, and confirms it.
    function _passTurnWithMiss(uint256 matchId, address shooter, uint8 waterCell) internal {
        vm.prank(shooter);
        game.shoot(matchId, waterCell);
        processAllOperations();
        _confirmPendingShot(matchId, shooter);
    }

    function _shieldCiphertext(uint256 cellMaskValue, address owner) internal view returns (bytes memory) {
        return fakePrepareEuint256Ciphertext(cellMaskValue, owner, address(game));
    }

    /// @dev Places a shield on cellIdx as player, fee and ciphertext built
    /// before the prank so the prank is not consumed by the intermediate
    /// inco.getFee() call (see _rollDiceOnce for the same pattern).
    function _placeShield(uint256 matchId, address player, uint8 cellIdx) internal {
        uint256 fee = inco.getFee();
        bytes memory ciphertext = _shieldCiphertext(uint256(1) << cellIdx, player);
        vm.deal(player, 1 ether);
        vm.prank(player);
        game.placeShield{value: fee}(matchId, ciphertext);
    }

    /// @dev The break is a distinct, revealed outcome (hit=false and
    /// shieldBreak=true), not a disguised miss: no ship damage, the cell
    /// survives (it is not logged into shotsAgainstMe), and the turn passes
    /// like a miss. A later shot on the same cell is then a normal hit that
    /// destroys the ship and keeps the turn.
    function testShieldBreaksAsDistinctOutcomeCellSurvivesAndTurnPasses() public {
        // alice is CAPTAIN_SHIELD in _createAndJoinMatch. Give her the tiny
        // ships board so cell 0 is a real, single-cell ship: a genuine hit
        // destroys it outright, making a break (no damage) easy to tell
        // apart from a real hit (ship destroyed).
        (uint256 board0, uint256[6] memory ships0) = _tinyShipsBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }
        assertEq(game.getTurn(matchId), alice, "expected alice's turn before placing the shield");

        _placeShield(matchId, alice, 0);
        processAllOperations();
        assertTrue(game.isShieldActive(matchId, 0), "shield should be active once committed");

        // placeShield is a free action, alice still has the turn; spend it
        // on a genuine miss against bob's tiny-ships board so the turn
        // passes to bob, who then fires at the shielded cell.
        _passTurnWithMiss(matchId, alice, 100);
        assertEq(game.getTurn(matchId), bob, "turn should have passed to bob");

        vm.prank(bob);
        game.shoot(matchId, 0);
        processAllOperations();
        (bool hit, bool shieldBreak) = _confirmPendingShot(matchId, bob);

        assertFalse(hit, "a shield break must not read as a ship hit");
        assertTrue(shieldBreak, "the break must be its own revealed outcome");
        assertEq(game.getTurn(matchId), alice, "a break resolves like a miss, the turn passes");
        assertFalse(game.isShieldActive(matchId, 0), "the shield should be consumed by the break");

        uint256 revealedAfterBreak = getUint256Value(game.getLastDestroyedMask(matchId, 0));
        assertEq(revealedAfterBreak, 0, "a shield break must not sink the ship it is guarding");

        // The cell survived (it was not logged), so alice can pass the turn
        // back and bob can hit cell 0 again, this time for real.
        _passTurnWithMiss(matchId, alice, 101);
        assertEq(game.getTurn(matchId), bob, "turn should have passed back to bob");

        vm.prank(bob);
        game.shoot(matchId, 0);
        processAllOperations();
        (bool secondHit, bool secondBreak) = _confirmPendingShot(matchId, bob);

        assertTrue(secondHit, "the second shot on the same cell should resolve as a real hit");
        assertFalse(secondBreak, "the shield is already gone, this shot cannot break it again");
        assertEq(game.getTurn(matchId), bob, "a genuine hit keeps the shooter's turn");

        uint256 revealedAfterRealHit = getUint256Value(game.getLastDestroyedMask(matchId, 0));
        assertEq(revealedAfterRealHit, uint256(1), "the real hit should destroy the single-cell ship at cell 0");
    }

    function testShieldIsSingleUsePerMatch() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }

        _placeShield(matchId, alice, 0);
        processAllOperations();

        assertFalse(game.hasShieldCharge(matchId, 0), "shield charge should be spent after one placement");

        uint256 fee = inco.getFee();
        bytes memory ciphertext = _shieldCiphertext(uint256(1) << 1, alice);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("shield already used");
        game.placeShield{value: fee}(matchId, ciphertext);
    }

    function testOpponentCannotReadTheShieldedCellHandleBeforeItBreaks() public {
        (uint256 board0, uint256[6] memory ships0) = _tinyShipsBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }

        _placeShield(matchId, alice, 0);
        processAllOperations();

        euint256 handle = game.getShieldCellHandle(matchId, 0);
        assertTrue(e.isAllowed(alice, handle), "the owning player should keep access to their own shielded cell");
        assertFalse(e.isAllowed(bob, handle), "the opponent must never be allowed to read the shielded cell");

        // Break it, and confirm raw handle access is still never granted:
        // only the derived hit/break booleans are ever revealed, the which-
        // cell information the shooter learns comes from the plaintext cell
        // argument they themselves passed to shoot(), not from the handle.
        _passTurnWithMiss(matchId, alice, 100);
        vm.prank(bob);
        game.shoot(matchId, 0);
        processAllOperations();
        _confirmPendingShot(matchId, bob);

        assertFalse(e.isAllowed(bob, handle), "the opponent must never be allowed to read the raw handle");
    }

    function testOnlyCaptainShieldCanPlaceShield() public {
        uint8 bombardment = game.CAPTAIN_BOMBARDMENT();
        uint8 shieldCaptain = game.CAPTAIN_SHIELD();
        vm.prank(alice);
        uint256 matchId = game.createMatch(bombardment);
        vm.prank(bob);
        game.joinMatch(matchId, shieldCaptain);

        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        (uint256 board1, uint256[6] memory ships1) = _tinyShipsBoard();
        game.setBoardForTesting(matchId, 0, board0, ships0);
        game.setBoardForTesting(matchId, 1, board1, ships1);
        processAllOperations();
        _rollAndConfirmDiceUntilDecided(matchId, alice);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }

        uint256 fee = inco.getFee();
        bytes memory ciphertext = _shieldCiphertext(uint256(1) << 0, alice);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("captain does not own this skill");
        game.placeShield{value: fee}(matchId, ciphertext);
    }

    /// @dev shieldActive is public and set once a shield is committed, even
    /// for an invalid pick; validity is enforced entirely through the
    /// obliviously zeroed shieldCellMask, which can then never equal a real
    /// shot bit, so an invalid pick's shield never breaks.
    function testInvalidWaterPickIsCommittedButNeverBreaksTheShield() public {
        (uint256 board0, uint256[6] memory ships0) = _tinyShipsBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }

        // Cell 200 is water on alice's tiny ships board, an invalid pick
        // for the ship-cell-only shield.
        _placeShield(matchId, alice, 200);
        processAllOperations();
        assertTrue(game.isShieldActive(matchId, 0), "shieldActive reflects commitment, not pick validity");

        _passTurnWithMiss(matchId, alice, 100);
        assertEq(game.getTurn(matchId), bob, "turn should have passed to bob");

        // A real ship cell should still resolve as a genuine hit, never a
        // break, proving the invalid pick can never match a real shot.
        vm.prank(bob);
        game.shoot(matchId, 0);
        processAllOperations();
        (bool hit, bool shieldBreak) = _confirmPendingShot(matchId, bob);

        assertTrue(hit, "an unshielded ship cell should hit normally");
        assertFalse(shieldBreak, "the invalid pick must never break as a shield");
        assertEq(game.getTurn(matchId), bob, "a genuine hit keeps the turn");
    }

    function testPlacingShieldDoesNotPassTurnOrChargeTheClock() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        if (game.getTurn(matchId) != alice) {
            _passTurnWithMiss(matchId, bob, 200);
        }

        uint256 remainingBefore = game.getRemainingTime(matchId, 0);
        uint256 lastMoveBefore = game.getLastMoveTimestamp(matchId);

        vm.warp(block.timestamp + 10);
        _placeShield(matchId, alice, 0);
        processAllOperations();

        assertEq(game.getTurn(matchId), alice, "placing a shield should not pass the turn");
        assertEq(game.getRemainingTime(matchId, 0), remainingBefore, "placing a shield should not charge the clock");
        assertEq(game.getLastMoveTimestamp(matchId), lastMoveBefore, "placing a shield should not reset the clock");
    }

    /// @dev Since the shield rework restored logging for every resolved
    /// shot, a plain miss now burns its cell again exactly like it did
    /// before that rework, so it can never be re-shot either.
    function testPlainMissCannotBeReshotNowThatMissesAreLoggedAgain() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;

        // Cell 200 is empty on both test boards.
        vm.prank(shooter);
        game.shoot(matchId, 200);
        processAllOperations();
        _confirmPendingShot(matchId, shooter);

        // A miss passes the turn to the defender. Hand it back to the
        // original shooter with a genuine miss of their own (cell 201 is
        // empty on both test boards too) so the reshoot attempt below
        // targets the same board cell 200 was logged on.
        vm.prank(defender);
        game.shoot(matchId, 201);
        processAllOperations();
        _confirmPendingShot(matchId, defender);

        assertEq(game.getTurn(matchId), shooter, "turn should be back with the original shooter");
        vm.prank(shooter);
        vm.expectRevert("cell already shot");
        game.shoot(matchId, 200);
    }

    /// @dev A mine cell is logged into shotsAgainstMe exactly like a plain
    /// miss, so the two are indistinguishable in the public log: both show
    /// up as a logged cell that can never be shot again.
    function testMineCellIsLoggedLikeAMissInThePublicLog() public {
        (uint256 board0, uint256[6] memory ships0) = _standardTestBoard();
        uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);

        address shooter = game.getTurn(matchId);
        address defender = shooter == alice ? bob : alice;
        uint8 defenderIdx = game.getPlayerAddress(matchId, 0) == defender ? 0 : 1;

        // Cell 220 is empty on both test boards, seed it as the defender's
        // only mine.
        game.setMinesForTesting(matchId, defenderIdx, uint256(1) << 220, defender);
        processAllOperations();

        vm.prank(shooter);
        game.shoot(matchId, 220);
        processAllOperations();
        _confirmPendingShot(matchId, shooter);

        assertEq(
            (game.getShotsAgainst(matchId, defenderIdx) >> 220) & 1,
            1,
            "a mine cell must be logged in the public shot log, just like a miss"
        );

        // Spend the defender's mine bonus (cell 221 miss keeps the turn,
        // cell 222 miss then passes it) so the turn returns to the
        // original shooter to try re-targeting the mine cell.
        vm.prank(defender);
        game.shoot(matchId, 221);
        processAllOperations();
        _confirmPendingShot(matchId, defender);

        vm.prank(defender);
        game.shoot(matchId, 222);
        processAllOperations();
        _confirmPendingShot(matchId, defender);

        assertEq(game.getTurn(matchId), shooter, "turn should be back with the original shooter");
        vm.prank(shooter);
        vm.expectRevert("cell already shot");
        game.shoot(matchId, 220);
    }

    /// @dev A barrage that strikes the shielded cell breaks it exactly once
    /// (no damage, cell survives, shield consumed), while any other struck
    /// cells resolve normally. The strike area is random, so this retries
    /// across fresh matches until it lands on the shielded cell, the same
    /// pattern testBarrageMinePenaltyAppliesAlongsideShipHits uses.
    function testBarrageBreaksShieldOnceWithoutDestroyingShip() public {
        bool observedBreak = false;
        for (uint256 round = 0; round < 10 && !observedBreak; round++) {
            // Cells 0-3 are all real single-cell ships on the tiny ships
            // board, and all fall within the barrage's (0,0) anchored 4x4
            // area (local row 0, columns 0-3), so any of them works as the
            // shielded cell. Rotated per round so each round's placeShield
            // ciphertext differs, the fake ciphertext used in tests is
            // deterministic per (value, owner, contract), and reusing the
            // exact same one across matches collides in the mock Inco
            // handle store.
            uint8 cellIdx = uint8(round % 4);

            (uint256 board0, uint256[6] memory ships0) = _tinyShipsBoard();
            uint256 matchId = _setupInProgressMatch(alice, bob, board0, ships0);
            if (game.getTurn(matchId) != alice) {
                _passTurnWithMiss(matchId, bob, 200);
            }

            _placeShield(matchId, alice, cellIdx);
            processAllOperations();

            // Hand the turn to bob so he can fire the barrage at alice's
            // board. Cell 100 is water on both test boards.
            _passTurnWithMiss(matchId, alice, 100);

            vm.deal(bob, 1 ether);
            uint256 fee = _barrageFee();
            vm.prank(bob);
            // Anchored at (0,0), the 4x4 area covers cells 0-3 among others.
            game.useBarrage{value: fee}(matchId, 0, 0);
            processAllOperations();
            uint256 packed = _confirmPendingBarrage(matchId, bob);

            uint256 breakCount = 0;
            bool shieldedCellWasBreak = false;
            for (uint8 k = 0; k < game.BARRAGE_MAX_CELLS(); k++) {
                uint256 code = _decodeBarrageSlot(packed, k);
                if (code != 4) continue;
                breakCount++;
                uint256 localPos = ((packed >> (uint256(k) * 7)) & 0x7F) & 0xF;
                if (localPos == cellIdx) shieldedCellWasBreak = true;
            }
            if (!shieldedCellWasBreak) continue;
            observedBreak = true;

            assertEq(breakCount, 1, "the shield covers exactly one cell, at most one barrage slot can break it");
            assertFalse(game.isShieldActive(matchId, 0), "the shield should be consumed by the barrage break");

            uint256 revealed = getUint256Value(game.getLastDestroyedMask(matchId, 0));
            assertEq(revealed & (uint256(1) << cellIdx), 0, "the shield break must not sink the ship it is guarding");
            assertEq(
                game.getShotsAgainst(matchId, 0) & (uint256(1) << cellIdx), 0, "a shield break must not burn the cell"
            );

            _passTurnWithMiss(matchId, alice, 101);
            assertEq(game.getTurn(matchId), bob, "turn should have passed back to bob");

            vm.prank(bob);
            game.shoot(matchId, cellIdx);
            processAllOperations();
            (bool hit, bool shieldBreak) = _confirmPendingShot(matchId, bob);

            assertTrue(hit, "the cell should now resolve as a real hit, the shield is already gone");
            assertFalse(shieldBreak, "the shield cannot break twice");
        }

        assertTrue(observedBreak, "expected at least one barrage to strike the shielded cell");
    }
}
