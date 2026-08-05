// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {Battleship} from "../Battleship.sol";

/// @notice Test-only subclass exposing the board-seeding hook and pending
///         handle reads so shot resolution, turn order and win detection
///         can be tested without depending on the real random placement
///         implementation, and without needing to parse event logs (which
///         would conflict with IncoTest's own use of vm.recordLogs()).
contract BattleshipHarness is Battleship {
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
        returns (bytes32 hitHandle, bytes32 allDestroyedHandle)
    {
        Match storage m = matches[matchId];
        return (ebool.unwrap(m.pendingHit), ebool.unwrap(m.pendingAllDestroyed));
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

    /// @dev Runs the real placement loop starting from a fully occupied
    ///      board, so every attempt for every ship is guaranteed to
    ///      overlap. Used to deterministically exercise the all-attempts-
    ///      fail retry path without relying on the astronomically unlikely
    ///      real failure case.
    function forcePlacementFailureForTesting(uint256 matchId, uint8 playerIdx) external {
        _runPlacement(matchId, playerIdx, e.asEuint256(type(uint256).max));
    }
}
