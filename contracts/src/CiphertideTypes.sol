// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool} from "@inco/lightning/src/Lib.sol";

/// @notice Shared storage layout for a player's match slot.
/// @dev Split out of Ciphertide.sol so CiphertideMechanics can take a
///      storage pointer to it directly, without a circular import between
///      the main contract and the mechanics library (Ciphertide imports the
///      library to call it, so the library cannot in turn import Ciphertide
///      just to reuse this struct). The array length is written as the
///      literal 6 rather than Ciphertide's NUM_SHIPS constant, since a free
///      struct cannot reference a constant declared inside a contract; the
///      fleet size is fixed game design, not a runtime tunable.
struct PlayerSlot {
    address addr;
    uint8 captain; // declared at createMatch or joinMatch, one of the NUM_CAPTAINS ids
    bool placed;
    euint256 boardMask; // OR of all shipMask entries, one bit per cell
    euint256[6] shipMask; // cells occupied by each ship, disjoint
    euint256[6] shipHits; // subset of shipMask hit so far
    euint256 lastDestroyedMask; // the ship (if any) sunk by the most recent shot, else 0, always safe to reveal
    euint256 mineMask; // this player's own mines, never allowed to the opponent
    uint256 shotsAgainstMe; // plain bitmask, cells already shot at on this board
    uint256 remainingTime;
    bool placementPending;
    ebool pendingAllPlaced;
    // Placement is spread across several placeMyBoardStep calls, one ship
    // per call plus a final mines-and-reveal call, so no single transaction
    // needs to run all ~140 random draws at once. 0 means no step has run
    // yet this placement round (the next call starts a fresh round and
    // resets boardMask and placementAllPlacedSoFar), NUM_SHIPS means every
    // ship step is done and the next call places mines and reveals.
    uint8 placementShipsDone;
    // Running AND of every step's placed bit so far this round, encrypted,
    // never revealed until the final step folds in the mine result and
    // reveals the single allPlaced bit into pendingAllPlaced below. Kept
    // separate from pendingAllPlaced, which is the one specific value
    // confirmPlacement's attestation is checked against.
    ebool placementAllPlacedSoFar;
    bool bonusShotAvailable; // set when the opponent triggers one of this player's mines
    bool sonarUsed;
    bool barrageUsed;
    bool bombardmentUsed; // gates useBombardment to once per match, captain 2 only
    bool rakeUsed; // gates useRake to once per match, captain 3 only
    bool salvoUsed; // gates useSalvo to once per match, captain 4 only
    bool carpetUsed; // gates useCarpet to once per match, captain 5 only
    bool shieldUsed; // gates placeShield to once per match, captain 1 only
    // Set on the salvo user once useSalvo resolves, Salvo's forfeit cost.
    // Consumed the next time the turn would land on this player: that turn
    // is skipped once and passes straight back to the opponent, then this
    // flag clears itself, so it can never skip more than the one turn.
    bool skipNextTurn;
    euint256 shieldCellMask; // encrypted single-bit mask of the shielded cell, 0 if none or invalid
    // Public on purpose: whether a shield has been committed is not a
    // secret, only the CELL it guards is. True once placeShield has run,
    // even for an invalid pick, since an invalid pick's shieldCellMask is
    // obliviously zeroed and can therefore never match a real shot,
    // leaving it silently, permanently inert without needing a second
    // encrypted flag. Cleared back to false the moment the shield breaks.
    bool shieldActive;
}

/// @notice Shared pending state for whichever multi-cell area skill
///         (Barrage, Bombardment, Rake, Carpet) is currently in flight for
///         a match, never more than one at once (gated by Ciphertide's own
///         PendingAction). Split out of Ciphertide's own Match struct, the
///         same reasoning as PlayerSlot above: as a free-standing struct
///         (not nested inside the Ciphertide contract) this can be passed
///         to CiphertideMechanics by storage reference, letting the whole
///         stepped-skill orchestration for Bombardment and Carpet (which
///         needs to read and write several of these fields together across
///         several transactions) live in the library instead of
///         Ciphertide's own deployed bytecode, without a circular import.
struct AreaSkillState {
    euint256 packed;
    ebool allDestroyed;
    uint8 anchorRow; // barrage, bombardment, rake, carpet only
    uint8 anchorCol; // barrage, bombardment, rake, carpet only
    // Bombardment and Carpet strike more cells in one resolution than fits
    // safely under Base's per-transaction gas cap, so both are split into
    // a few stepped calls, mirroring PlayerSlot.placementShipsDone's own
    // step counter. 0 before the first step of a firing sequence and reset
    // back to 0 once the final step requests the reveal (Ciphertide's
    // pendingAction stays set to Bombardment or Carpet throughout,
    // including the "fired, awaiting confirmation" window after the final
    // step, so stepsDone alone cannot tell "never started" apart from
    // "just finished firing", see Ciphertide.useBombardment's own comment
    // for how the two are told apart). Unused by Barrage and Rake, which
    // always fit in a single transaction.
    uint8 stepsDone;
    // Struck-cell mask accumulated across a stepped area skill's steps
    // (excluding shield breaks), OR'd in by each step from its own
    // CiphertideMechanics resolve call. Ship damage itself is applied
    // once, on the final step, from this fully accumulated mask, not per
    // step: a partial mid-sequence view is meaningless, and repeating the
    // full per-ship loop on every step would waste gas re-reading and
    // re-writing the same shipHits storage on every step for no benefit.
    // Unused by Barrage and Rake.
    euint256 struckSoFar;
    // Carpet's "any ship cell inside the aimed 3x3" gate, computed once on
    // Carpet's first step and reused unchanged by every later step, so
    // every one of the 9 slots is gated identically regardless of which
    // step resolves it. Unused by Bombardment, Barrage and Rake.
    ebool carpetShipPresent;
}
