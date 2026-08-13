// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {PlayerSlot} from "./BattleshipTypes.sol";

/// @notice Heavy, reusable FHE mechanics factored out of Battleship into a
///         separately deployed, linked external library, purely to keep
///         Battleship's own deployed bytecode well clear of the EIP-170
///         24576 byte runtime size limit as more captain skills are added
///         on top. Covers area and single-cell mask building, the bounded-
///         attempt random-cell drawing shared by ship placement, mine
///         placement and Barrage, and Barrage's strike resolution and
///         result packing.
/// @dev Every function called from Battleship.sol is declared external, so
///      those calls compile to a delegatecall against this library's own
///      deployed bytecode instead of being inlined into every caller, the
///      way a plain internal library would be. Helper functions used only
///      within this library stay internal, they get inlined into this
///      library's own bytecode, which does not count against Battleship's
///      size limit either way. Behavior is unchanged from the functions
///      this replaces in Battleship.sol, only where the code lives has
///      moved.
///
///      Deploying Battleship for real requires deploying this library
///      first and linking its address into Battleship's bytecode at build
///      or deploy time (for example `forge create --libraries
///      src/BattleshipMechanics.sol:BattleshipMechanics:<address>`, or the
///      equivalent `libraries` entry in a Foundry deploy script). An
///      unlinked Battleship will not deploy.
library BattleshipMechanics {
    using e for euint256;
    using e for ebool;

    /// Fixed game design, not a runtime tunable, mirrors Battleship.BOARD_SIZE.
    uint8 internal constant BOARD_SIZE = 15;

    // ---------------------------------------------------------------
    // Area, row, and single-cell mask building
    // ---------------------------------------------------------------

    /// @dev Plaintext mask for a height x width rectangle anchored at
    ///      (row0, col0) on the BOARD_SIZE x BOARD_SIZE board. Pure
    ///      arithmetic, no encrypted values involved, since the area itself
    ///      is a public choice, only its contents are confidential.
    function rectMask(uint8 row0, uint8 col0, uint8 height, uint8 width) external pure returns (uint256 mask) {
        uint256 rowRun = (uint256(1) << width) - 1;
        for (uint8 r = 0; r < height; r++) {
            mask |= rowRun << ((uint256(row0) + r) * BOARD_SIZE + col0);
        }
    }

    // ---------------------------------------------------------------
    // Ship and mine placement: bounded-attempt random-cell drawing
    // ---------------------------------------------------------------

    /// @dev Tries attemptsPerShip independent random candidate slots for
    ///      one ship of the given length against the cells already
    ///      occupied by previously placed ships, keeping the first
    ///      non-overlapping candidate. Every intermediate value (the random
    ///      draw, decoded row/col/orientation, candidate mask, overlap
    ///      check) is an encrypted handle end to end, nothing plaintext ever
    ///      leaves this function.
    function placeOneShip(uint8 length, euint256 occupiedSoFar, uint8 attemptsPerShip)
        external
        returns (euint256 shipMask, ebool placed)
    {
        uint256 span = uint256(BOARD_SIZE) - length + 1; // valid start offsets along one axis
        uint256 slotsPerOrientation = uint256(BOARD_SIZE) * span;
        uint256 totalSlots = slotsPerOrientation * 2;

        shipMask = e.asEuint256(uint256(0));
        placed = e.asEbool(false);

        for (uint8 attempt = 0; attempt < attemptsPerShip; attempt++) {
            euint256 idx = e.randBounded(totalSlots);
            euint256 candidate = _decodeCandidateMask(idx, length, span, slotsPerOrientation);

            ebool noOverlap = candidate.and(occupiedSoFar).eq(uint256(0));
            ebool accept = placed.not().and(noOverlap);

            occupiedSoFar = accept.select(occupiedSoFar.or(candidate), occupiedSoFar);
            shipMask = accept.select(candidate, shipMask);
            placed = placed.or(accept);
        }
    }

    /// @dev Places minesPerPlayer single-cell mines, each with
    ///      attemptsPerMine independent random candidate cells, avoiding
    ///      every ship cell (shipOccupied) and every previously placed mine
    ///      this call. Same bounded-attempt, first-non-overlapping-
    ///      candidate-wins pattern as ship placement, scoped to a single
    ///      cell instead of a run.
    function placeMines(euint256 shipOccupied, uint8 minesPerPlayer, uint8 attemptsPerMine)
        external
        returns (euint256 mineMask, ebool allPlaced)
    {
        mineMask = e.asEuint256(uint256(0));
        allPlaced = e.asEbool(true);
        euint256 avoid = shipOccupied;

        for (uint8 i = 0; i < minesPerPlayer; i++) {
            ebool placedThisMine = e.asEbool(false);
            euint256 thisMineMask = e.asEuint256(uint256(0));

            for (uint8 attempt = 0; attempt < attemptsPerMine; attempt++) {
                euint256 idx = e.randBounded(uint256(BOARD_SIZE) * uint256(BOARD_SIZE));
                euint256 candidate = e.asEuint256(uint256(1)).shl(idx);

                ebool noOverlap = candidate.and(avoid).eq(uint256(0));
                ebool accept = placedThisMine.not().and(noOverlap);

                avoid = accept.select(avoid.or(candidate), avoid);
                thisMineMask = accept.select(candidate, thisMineMask);
                placedThisMine = placedThisMine.or(accept);
            }

            mineMask = mineMask.or(thisMineMask);
            allPlaced = allPlaced.and(placedThisMine);
        }
    }

    /// @dev Decodes one random draw into a candidate ship mask: orientation,
    ///      row and column all stay encrypted, only the ship length, span
    ///      and slot count (public config, not board state) are plaintext.
    function _decodeCandidateMask(euint256 idx, uint8 length, uint256 span, uint256 slotsPerOrientation)
        internal
        returns (euint256)
    {
        ebool isVertical = idx.div(slotsPerOrientation).eq(uint256(1));
        euint256 slot = idx.rem(slotsPerOrientation);

        // Horizontal: row in [0, BOARD_SIZE), col in [0, span), a
        // contiguous run of `length` bits starting at row*BOARD_SIZE+col.
        euint256 baseH = slot.div(span).mul(uint256(BOARD_SIZE)).add(slot.rem(span));
        euint256 maskH = e.asEuint256((uint256(1) << length) - 1).shl(baseH);

        // Vertical: row in [0, span), col in [0, BOARD_SIZE), cells are
        // BOARD_SIZE bits apart instead of contiguous.
        euint256 baseV = slot.div(uint256(BOARD_SIZE)).mul(uint256(BOARD_SIZE)).add(slot.rem(uint256(BOARD_SIZE)));
        euint256 maskV = _verticalRunMask(baseV, length);

        return isVertical.select(maskV, maskH);
    }

    function _verticalRunMask(euint256 baseBit, uint8 length) internal returns (euint256 mask) {
        mask = e.asEuint256(uint256(0));
        for (uint8 k = 0; k < length; k++) {
            mask = mask.or(e.asEuint256(uint256(1)).shl(baseBit.add(uint256(k) * BOARD_SIZE)));
        }
    }

    // ---------------------------------------------------------------
    // Barrage: strike resolution and result packing
    // ---------------------------------------------------------------

    /// @dev Bundles one barrage slot's outputs into memory instead of three
    ///      separate stack return values, keeping the picking loop's stack
    ///      frame within the EVM's local variable limit.
    struct BarrageSlotResult {
        euint256 newAvoid;
        euint256 packedSlot;
        euint256 struckContribution;
    }

    /// @dev Draws the random count, picks all candidate slots, and folds
    ///      the resulting struck cells into the defender's ship hit
    ///      tracking. If a struck cell is the defender's active shielded
    ///      cell, that slot resolves as a shield break (result code 4): no
    ///      ship damage, and its contribution to the struck mask is zeroed.
    ///      Whether the shield actually broke is only acted on later, once
    ///      the caller reveals and decodes the returned packed value back
    ///      to plaintext, this function only folds the break into the
    ///      encrypted packing, it never reads or writes shieldActive.
    function resolveBarrageStrikes(
        uint8 anchorRow,
        uint8 anchorCol,
        PlayerSlot storage defender,
        uint8 areaSize,
        uint8 minCells,
        uint8 maxCells,
        uint8 attemptsPerCell
    ) external returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) {
        euint256 struckMask;
        (packed, struckMask) =
            _pickAllBarrageSlots(anchorRow, anchorCol, defender, areaSize, minCells, maxCells, attemptsPerCell);
        (newlyDestroyed, allDestroyed) = _applyBarrageShipDamage(defender, struckMask);
    }

    function _pickAllBarrageSlots(
        uint8 anchorRow,
        uint8 anchorCol,
        PlayerSlot storage defender,
        uint8 areaSize,
        uint8 minCells,
        uint8 maxCells,
        uint8 attemptsPerCell
    ) internal returns (euint256 packed, euint256 struckMask) {
        euint256 count = e.randBounded(uint256(maxCells - minCells) + 1).add(uint256(minCells));
        euint256 avoid = e.asEuint256(defender.shotsAgainstMe);
        struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint8 k = 0; k < maxCells; k++) {
            ebool isActive = k < minCells ? e.asEbool(true) : count.gt(uint256(k));
            BarrageSlotResult memory r =
                _pickBarrageSlot(anchorRow, anchorCol, k, isActive, avoid, defender, areaSize, attemptsPerCell);
            avoid = r.newAvoid;
            packed = packed.or(r.packedSlot);
            struckMask = struckMask.or(r.struckContribution);
        }
    }

    /// @dev Folds the struck cells into each ship's hit tracking and
    ///      computes the newly sunk mask and win bit, the same pattern as
    ///      a normal shot but against a multi-bit struck mask instead of a
    ///      single cell.
    function _applyBarrageShipDamage(PlayerSlot storage defender, euint256 struckMask)
        internal
        returns (euint256 newlyDestroyed, ebool allDestroyed)
    {
        allDestroyed = e.asEbool(true);
        newlyDestroyed = e.asEuint256(uint256(0));
        euint256 shipStruckMask = struckMask.and(defender.boardMask);
        for (uint8 i = 0; i < defender.shipMask.length; i++) {
            euint256 oldHits = defender.shipHits[i];
            ebool wasAlreadyDestroyed = oldHits.eq(defender.shipMask[i]);

            euint256 newHits = oldHits.or(defender.shipMask[i].and(shipStruckMask));
            newHits.allowThis();
            defender.shipHits[i] = newHits;

            ebool destroyed = newHits.eq(defender.shipMask[i]);
            allDestroyed = allDestroyed.and(destroyed);

            ebool justSunk = destroyed.and(wasAlreadyDestroyed.not());
            newlyDestroyed = newlyDestroyed.or(justSunk.select(defender.shipMask[i], e.asEuint256(uint256(0))));
        }
    }

    /// @dev Tries attemptsPerCell independent random cells within the
    ///      areaSize x areaSize area for one barrage slot, avoiding every
    ///      cell already claimed by an earlier slot this barrage or already
    ///      shot on a previous action, keeping the first non-overlapping
    ///      candidate. Packs the local position and a result code (0 if
    ///      this slot never found a free candidate or the random count did
    ///      not reach it, 1 miss, 2 ship hit, 3 mine, 4 shield break) into
    ///      one 7 bit value: 4 bit local position plus a 3 bit code.
    function _pickBarrageSlot(
        uint8 anchorRow,
        uint8 anchorCol,
        uint8 slotIndex,
        ebool isActive,
        euint256 avoidSoFar,
        PlayerSlot storage defender,
        uint8 areaSize,
        uint8 attemptsPerCell
    ) internal returns (BarrageSlotResult memory r) {
        euint256 localPos;
        euint256 candidateMask;
        ebool found;
        (r.newAvoid, localPos, candidateMask, found) =
            _findDistinctBarrageCell(anchorRow, anchorCol, avoidSoFar, areaSize, attemptsPerCell);

        ebool trulyActive = isActive.and(found);
        // Same shield check as a normal shot, against this slot's candidate
        // cell instead of a caller-supplied cell index. Whether a shield is
        // active at all is a plain bool, so the encrypted equality check
        // only needs to run when one is actually up.
        ebool shieldBreak =
            defender.shieldActive ? trulyActive.and(candidateMask.eq(defender.shieldCellMask)) : e.asEbool(false);
        euint256 code = _barrageResultCode(trulyActive, shieldBreak, candidateMask, defender.mineMask, defender.boardMask);

        r.packedSlot = localPos.or(code.shl(uint256(4))).shl(uint256(slotIndex) * 7);
        // A broken shield does no damage, exactly like it never happened,
        // so its contribution to the aggregate struck mask is zeroed here
        // even though the slot itself was truly active.
        ebool countsAsStruck = trulyActive.and(shieldBreak.not());
        r.struckContribution = countsAsStruck.select(candidateMask, e.asEuint256(uint256(0)));
    }

    /// @dev Runs the bounded-attempt retry to find one cell in the
    ///      areaSize x areaSize area distinct from every cell in
    ///      avoidSoFar, split out to keep _pickBarrageSlot's stack frame
    ///      small.
    function _findDistinctBarrageCell(
        uint8 anchorRow,
        uint8 anchorCol,
        euint256 avoidSoFar,
        uint8 areaSize,
        uint8 attemptsPerCell
    ) internal returns (euint256 newAvoid, euint256 localPos, euint256 candidateMask, ebool found) {
        localPos = e.asEuint256(uint256(0));
        candidateMask = e.asEuint256(uint256(0));
        found = e.asEbool(false);

        for (uint8 attempt = 0; attempt < attemptsPerCell; attempt++) {
            euint256 idx = e.randBounded(uint256(areaSize) * uint256(areaSize));
            euint256 candidateBit = e.asEuint256(uint256(1)).shl(_localToGlobalCell(idx, anchorRow, anchorCol, areaSize));

            ebool accept = found.not().and(candidateBit.and(avoidSoFar).eq(uint256(0)));

            avoidSoFar = accept.select(avoidSoFar.or(candidateBit), avoidSoFar);
            localPos = accept.select(idx, localPos);
            candidateMask = accept.select(candidateBit, candidateMask);
            found = found.or(accept);
        }
        newAvoid = avoidSoFar;
    }

    /// @dev Classifies one barrage candidate cell into a result code: 0
    ///      inactive, 1 miss, 2 ship hit, 3 mine, 4 shield break. A shield
    ///      break takes priority over every other code: it does not damage
    ///      the ship and is not a mine (mines and ship cells are disjoint
    ///      by placement, and the shield only ever guards a ship cell, so
    ///      this never actually conflicts with the mine code, the check is
    ///      kept explicit to stay safe either way).
    function _barrageResultCode(
        ebool trulyActive,
        ebool shieldBreak,
        euint256 candidateMask,
        euint256 mineMask,
        euint256 boardMask
    ) internal returns (euint256) {
        ebool isMine = candidateMask.and(mineMask).ne(uint256(0)).and(shieldBreak.not());
        ebool isShipHit = candidateMask.and(boardMask).ne(uint256(0)).and(shieldBreak.not());
        euint256 normalCode =
            isMine.select(e.asEuint256(uint256(3)), isShipHit.select(e.asEuint256(uint256(2)), e.asEuint256(uint256(1))));
        euint256 code = shieldBreak.select(e.asEuint256(uint256(4)), normalCode);
        return trulyActive.select(code, e.asEuint256(uint256(0)));
    }

    function _localToGlobalCell(euint256 localIdx, uint8 anchorRow, uint8 anchorCol, uint8 areaSize)
        internal
        returns (euint256)
    {
        euint256 localRow = localIdx.div(uint256(areaSize));
        euint256 localCol = localIdx.rem(uint256(areaSize));
        return localRow.add(uint256(anchorRow)).mul(uint256(BOARD_SIZE)).add(localCol.add(uint256(anchorCol)));
    }
}
