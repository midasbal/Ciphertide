// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {Ciphertide} from "../Ciphertide.sol";

/// @notice Test-only subclass exposing the board-seeding hook and pending
///         handle reads so shot resolution, turn order and win detection
///         can be tested without depending on the real random placement
///         implementation, and without needing to parse event logs (which
///         would conflict with IncoTest's own use of vm.recordLogs()).
contract CiphertideHarness is Ciphertide {
    function setBoardForTesting(
        uint256 matchId,
        uint8 playerIdx,
        uint256 boardMaskPlain,
        uint256[NUM_SHIPS] memory shipMaskPlain
    ) external {
        _setBoardForTesting(matchId, playerIdx, boardMaskPlain, shipMaskPlain);
    }

    function getPendingRoll(uint256 matchId) external view returns (bytes32 rollA, bytes32 rollB) {
        Match storage m = matches[matchId];
        return (euint256.unwrap(m.rollA), euint256.unwrap(m.rollB));
    }

    function getPendingShotHandles(uint256 matchId)
        external
        view
        returns (bytes32 hitHandle, bytes32 allDestroyedHandle, bytes32 mineHitHandle, bytes32 shieldBreakHandle)
    {
        Match storage m = matches[matchId];
        return (
            ebool.unwrap(m.pendingHit),
            ebool.unwrap(m.pendingAllDestroyed),
            ebool.unwrap(m.pendingMineHit),
            ebool.unwrap(m.pendingShieldBreak)
        );
    }

    function setMinesForTesting(uint256 matchId, uint8 playerIdx, uint256 mineMaskPlain, address owner) external {
        _setMinesForTesting(matchId, playerIdx, mineMaskPlain, owner);
    }

    function getPendingPlacementHandle(uint256 matchId, uint8 playerIdx) external view returns (bytes32) {
        return ebool.unwrap(matches[matchId].players[playerIdx].pendingAllPlaced);
    }

    function isPlaced(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].placed;
    }

    function getShipMask(uint256 matchId, uint8 playerIdx, uint8 shipIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].shipMask[shipIdx];
    }

    /// @dev Runs one real placement step starting from a fully occupied
    ///      board on the first call of a round, so every attempt for every
    ///      ship (and the mines) is guaranteed to overlap. Used to
    ///      deterministically exercise the all-attempts-fail retry path
    ///      without relying on the astronomically unlikely real failure
    ///      case. Call this NUM_SHIPS + 1 times in a row, exactly like a
    ///      real caller would call placeMyBoardStep, to reach the final
    ///      reveal.
    function forcePlacementFailureStepForTesting(uint256 matchId, uint8 playerIdx) external {
        _runPlacementStep(matchId, playerIdx, e.asEuint256(type(uint256).max));
    }

    function getPlacementShipsDone(uint256 matchId, uint8 playerIdx) external view returns (uint8) {
        return matches[matchId].players[playerIdx].placementShipsDone;
    }

    function getPendingSonarHandle(uint256 matchId) external view returns (bytes32) {
        return ebool.unwrap(matches[matchId].pendingSonarResult);
    }

    /// @dev Shared by Barrage, Bombardment, Rake and Salvo (never more than
    ///      one at once, gated by pendingAction), the pending fields
    ///      underneath are shared too.
    function getPendingAreaHandles(uint256 matchId)
        external
        view
        returns (bytes32 packedHandle, bytes32 allDestroyedHandle)
    {
        Match storage m = matches[matchId];
        return (euint256.unwrap(m.pendingAreaPacked), ebool.unwrap(m.pendingAreaAllDestroyed));
    }

    function hasSkipNextTurn(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].skipNextTurn;
    }

    /// @dev The cells a pending barrage, bombardment or rake picked with
    ///      public randomness, in the same order their packed result codes
    ///      are bit-packed. Public information from the moment the strike
    ///      fired, exposed here purely so tests can assert against the
    ///      exact cells without re-deriving the seed themselves.
    function getPendingAreaCellsForTesting(uint256 matchId) external view returns (uint8[] memory cells) {
        Match storage m = matches[matchId];
        cells = new uint8[](m.pendingAreaCellCount);
        for (uint8 k = 0; k < m.pendingAreaCellCount; k++) {
            cells[k] = m.pendingAreaCells[k];
        }
    }
}
