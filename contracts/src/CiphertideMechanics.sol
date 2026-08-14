// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {PlayerSlot} from "./CiphertideTypes.sol";

/// @notice Heavy, reusable FHE mechanics factored out of Ciphertide into a
///         separately deployed, linked external library, purely to keep
///         Ciphertide's own deployed bytecode well clear of the EIP-170
///         24576 byte runtime size limit as more captain skills are added
///         on top. Covers area and single-cell mask building, the bounded-
///         attempt random-cell drawing shared by ship placement, mine
///         placement, Barrage and Bombardment, and the area-strike
///         resolution and result packing shared by Barrage, Bombardment,
///         and any later skill with the same aim-strike-reveal shape.
/// @dev Every function called from Ciphertide.sol is declared external, so
///      those calls compile to a delegatecall against this library's own
///      deployed bytecode instead of being inlined into every caller, the
///      way a plain internal library would be. Helper functions used only
///      within this library stay internal, they get inlined into this
///      library's own bytecode, which does not count against Ciphertide's
///      size limit either way. Behavior is unchanged from the functions
///      this replaces in Ciphertide.sol, only where the code lives has
///      moved.
///
///      Deploying Ciphertide for real requires deploying this library
///      first and linking its address into Ciphertide's bytecode at build
///      or deploy time (for example `forge create --libraries
///      src/CiphertideMechanics.sol:CiphertideMechanics:<address>`, or the
///      equivalent `libraries` entry in a Foundry deploy script). An
///      unlinked Ciphertide will not deploy.
library CiphertideMechanics {
    using e for euint256;
    using e for ebool;

    /// Fixed game design, not a runtime tunable, mirrors Ciphertide.BOARD_SIZE.
    uint8 internal constant BOARD_SIZE = 15;

    // ---------------------------------------------------------------
    // Area, row, and single-cell mask building
    // ---------------------------------------------------------------

    /// @dev Plaintext mask for a height x width rectangle anchored at
    ///      (row0, col0) on the BOARD_SIZE x BOARD_SIZE board. Pure
    ///      arithmetic, no encrypted values involved, since the area itself
    ///      is a public choice, only its contents are confidential.
    function rectMask(uint8 row0, uint8 col0, uint8 height, uint8 width) external pure returns (uint256 mask) {
        return _rectMaskPlain(row0, col0, height, width);
    }

    /// @dev Shared plaintext computation behind rectMask, also used by
    ///      resolveCarpetStrike to test whether any ship cell lies inside
    ///      its 3x3 area without needing a self call back into this same
    ///      library's own external rectMask.
    function _rectMaskPlain(uint8 row0, uint8 col0, uint8 height, uint8 width) internal pure returns (uint256 mask) {
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
    // Area strikes: strike resolution and result packing, shared by
    // Barrage, Bombardment, and any later skill with the same shape (aim
    // a rectangle, strike some random distinct cells inside it, reveal
    // each one).
    // ---------------------------------------------------------------

    /// @dev Bundles one area-strike slot's outputs into memory instead of
    ///      three separate stack return values, keeping the picking loop's
    ///      stack frame within the EVM's local variable limit.
    struct AreaSlotResult {
        euint256 newAvoid;
        euint256 packedSlot;
        euint256 struckContribution;
    }

    /// @dev The rectangle a skill aims: width x height anchored at
    ///      (anchorRow, anchorCol). Bundled into one memory struct, instead
    ///      of four separate parameters threaded through every helper
    ///      below, to keep each function's stack frame within the EVM's
    ///      local variable limit.
    struct AreaGeometry {
        uint8 anchorRow;
        uint8 anchorCol;
        uint8 width;
        uint8 height;
    }

    /// @dev How many cells an area strike draws and how it packs them, kept
    ///      in one memory struct for the same stack frame reason as
    ///      AreaGeometry. minCells and maxCells set the randomized strike
    ///      count's range (equal for a fixed count, like Bombardment's 15).
    ///      positionBits must be wide enough to address width * height
    ///      distinct local positions (Barrage: 4 bits for a 4x4, 16 cell
    ///      area. Bombardment: 7 bits for a 10x10, 100 cell area).
    struct StrikeConfig {
        uint8 minCells;
        uint8 maxCells;
        uint8 attemptsPerCell;
        uint8 positionBits;
    }

    /// @dev Draws the strike count (randomized between minCells and
    ///      maxCells, or fixed when minCells == maxCells, which still
    ///      spends one random draw so the fee accounting stays uniform),
    ///      picks all candidate slots inside the given area, and folds the
    ///      resulting struck cells into the defender's ship hit tracking.
    ///      If a struck cell is the defender's active shielded cell, that
    ///      slot resolves as a shield break (result code 4): no ship
    ///      damage, and its contribution to the struck mask is zeroed.
    ///      Whether the shield actually broke is only acted on later, once
    ///      the caller reveals and decodes the returned packed value back
    ///      to plaintext, this function only folds the break into the
    ///      encrypted packing, it never reads or writes shieldActive.
    ///
    ///      Packs one result code (0 inactive, 1 miss, 2 ship hit, 3 mine,
    ///      4 shield break) and a local cell position per slot into a
    ///      single euint256: config.positionBits bits of local position,
    ///      then 3 bits of code, (positionBits + 3) bits per slot, one slot
    ///      per possible strike (config.maxCells slots total). Barrage: 4
    ///      position bits, 7 bits per slot, 6 slots, 42 bits total.
    ///      Bombardment: 7 position bits, 10 bits per slot, 15 slots, 150
    ///      bits total. Both comfortably inside a single euint256's 256
    ///      bits.
    function resolveAreaStrikes(AreaGeometry memory area, PlayerSlot storage defender, StrikeConfig memory config)
        external
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        euint256 struckMask;
        (packed, struckMask) = _pickAllAreaSlots(area, defender, config);
        (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckMask);
    }

    function _pickAllAreaSlots(AreaGeometry memory area, PlayerSlot storage defender, StrikeConfig memory config)
        internal
        returns (euint256 packed, euint256 struckMask)
    {
        euint256 count = e.randBounded(uint256(config.maxCells - config.minCells) + 1).add(uint256(config.minCells));
        euint256 avoid = e.asEuint256(defender.shotsAgainstMe);
        struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint8 k = 0; k < config.maxCells; k++) {
            ebool isActive = k < config.minCells ? e.asEbool(true) : count.gt(uint256(k));
            AreaSlotResult memory r = _pickAreaSlot(area, k, isActive, avoid, defender, config);
            avoid = r.newAvoid;
            packed = packed.or(r.packedSlot);
            struckMask = struckMask.or(r.struckContribution);
        }
    }

    /// @dev Folds the struck cells into each ship's hit tracking and
    ///      computes the newly sunk mask and win bit, the same pattern as
    ///      a normal shot but against a multi-bit struck mask instead of a
    ///      single cell.
    function _applyAreaShipDamage(PlayerSlot storage defender, euint256 struckMask)
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

    /// @dev Tries config.attemptsPerCell independent random cells within
    ///      the area for one slot, avoiding every cell already claimed by
    ///      an earlier slot this action or already shot on a previous
    ///      action, keeping the first non-overlapping candidate. Packs the
    ///      local position and a result code (0 if this slot never found a
    ///      free candidate or the random count did not reach it, 1 miss, 2
    ///      ship hit, 3 mine, 4 shield break) into one
    ///      (config.positionBits + 3) bit value: config.positionBits bits
    ///      of local position plus a 3 bit code.
    function _pickAreaSlot(
        AreaGeometry memory area,
        uint8 slotIndex,
        ebool isActive,
        euint256 avoidSoFar,
        PlayerSlot storage defender,
        StrikeConfig memory config
    ) internal returns (AreaSlotResult memory r) {
        euint256 localPos;
        euint256 candidateMask;
        ebool found;
        (r.newAvoid, localPos, candidateMask, found) = _findDistinctAreaCell(area, avoidSoFar, config.attemptsPerCell);

        ebool trulyActive = isActive.and(found);
        // Same shield check as a normal shot, against this slot's candidate
        // cell instead of a caller-supplied cell index. Whether a shield is
        // active at all is a plain bool, so the encrypted equality check
        // only needs to run when one is actually up.
        ebool shieldBreak =
            defender.shieldActive ? trulyActive.and(candidateMask.eq(defender.shieldCellMask)) : e.asEbool(false);
        euint256 code = _areaResultCode(trulyActive, shieldBreak, candidateMask, defender.mineMask, defender.boardMask);

        r.packedSlot = localPos.or(code.shl(uint256(config.positionBits))).shl(
            uint256(slotIndex) * (uint256(config.positionBits) + 3)
        );
        // A broken shield does no damage, exactly like it never happened,
        // so its contribution to the aggregate struck mask is zeroed here
        // even though the slot itself was truly active.
        ebool countsAsStruck = trulyActive.and(shieldBreak.not());
        r.struckContribution = countsAsStruck.select(candidateMask, e.asEuint256(uint256(0)));
    }

    /// @dev Runs the bounded-attempt retry to find one cell in the area
    ///      distinct from every cell in avoidSoFar, split out to keep
    ///      _pickAreaSlot's stack frame small.
    function _findDistinctAreaCell(AreaGeometry memory area, euint256 avoidSoFar, uint8 attemptsPerCell)
        internal
        returns (euint256 newAvoid, euint256 localPos, euint256 candidateMask, ebool found)
    {
        localPos = e.asEuint256(uint256(0));
        candidateMask = e.asEuint256(uint256(0));
        found = e.asEbool(false);

        for (uint8 attempt = 0; attempt < attemptsPerCell; attempt++) {
            euint256 idx = e.randBounded(uint256(area.width) * uint256(area.height));
            euint256 candidateBit = e.asEuint256(uint256(1)).shl(_localToGlobalCell(idx, area));

            ebool accept = found.not().and(candidateBit.and(avoidSoFar).eq(uint256(0)));

            avoidSoFar = accept.select(avoidSoFar.or(candidateBit), avoidSoFar);
            localPos = accept.select(idx, localPos);
            candidateMask = accept.select(candidateBit, candidateMask);
            found = found.or(accept);
        }
        newAvoid = avoidSoFar;
    }

    /// @dev Classifies one area-strike candidate cell into a result code: 0
    ///      inactive, 1 miss, 2 ship hit, 3 mine, 4 shield break. A shield
    ///      break takes priority over every other code: it does not damage
    ///      the ship and is not a mine (mines and ship cells are disjoint
    ///      by placement, and the shield only ever guards a ship cell, so
    ///      this never actually conflicts with the mine code, the check is
    ///      kept explicit to stay safe either way).
    function _areaResultCode(
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

    /// @dev area.width is the area's row stride for decoding a local index
    ///      back into a local row and column, area.height only bounded the
    ///      random draw that produced localIdx in _findDistinctAreaCell.
    function _localToGlobalCell(euint256 localIdx, AreaGeometry memory area) internal returns (euint256) {
        euint256 localRow = localIdx.div(uint256(area.width));
        euint256 localCol = localIdx.rem(uint256(area.width));
        return
            localRow.add(uint256(area.anchorRow)).mul(uint256(BOARD_SIZE)).add(localCol.add(uint256(area.anchorCol)));
    }

    // ---------------------------------------------------------------
    // Salvo: strike 3 caller chosen, already validated cells at once. No
    // randomness is involved, the cells are a public choice like the area
    // skills' aim rectangle, only their contents are confidential, so this
    // draws no random cells and needs no bounded-attempt search. Packs one
    // 3 bit result code per cell (0 unused, 1 miss, 2 ship hit, 3 mine, 4
    // shield break, the same codes resolveAreaStrikes uses) into a single
    // euint256, 3 bits per slot, no local position needed since the caller
    // already knows which cells it chose.
    // ---------------------------------------------------------------

    /// @dev shotBits holds each chosen cell's single-bit mask
    ///      (1 << cell), computed in plaintext by the caller since the
    ///      cells themselves are public inputs. Cell validity (in range,
    ///      distinct, not already shot) is the caller's responsibility,
    ///      checked in plain requires before this runs. Reuses
    ///      _applyAreaShipDamage for ship hit tracking and the newly sunk
    ///      and win detection, exactly like one call to resolveAreaStrikes.
    function resolveChosenStrikes(uint256[3] memory shotBits, PlayerSlot storage defender)
        external
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        euint256 struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint8 k = 0; k < 3; k++) {
            uint256 shotBit = shotBits[k];
            ebool shieldBreak = defender.shieldActive ? defender.shieldCellMask.eq(shotBit) : e.asEbool(false);
            ebool isMine = defender.mineMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            ebool isShipHit = defender.boardMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            euint256 normalCode = isMine.select(
                e.asEuint256(uint256(3)), isShipHit.select(e.asEuint256(uint256(2)), e.asEuint256(uint256(1)))
            );
            euint256 code = shieldBreak.select(e.asEuint256(uint256(4)), normalCode);

            packed = packed.or(code.shl(uint256(k) * 3));

            ebool countsAsStruck = shieldBreak.not();
            struckMask = struckMask.or(countsAsStruck.select(e.asEuint256(shotBit), e.asEuint256(uint256(0))));
        }

        (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckMask);
    }

    // ---------------------------------------------------------------
    // Carpet: Captain 5's unique skill. The 3x3 area is a public choice
    // like the other skills' aim, but whether it strikes at all is
    // conditional on encrypted board state: a single "any ship cell
    // inside the area" ebool, computed once and used to gate all 9 fixed
    // local slots at once, obliviously (a select, never a branch on the
    // encrypted result). No random draws and no per slot avoid-collision
    // search are needed, unlike Barrage, Bombardment and Rake: every
    // slot's cell is fixed by the anchor, not drawn. Packs one 3 bit
    // result code per cell (0 inactive, 1 miss, 2 ship hit, 3 mine, 4
    // shield break, the same codes resolveAreaStrikes and
    // resolveChosenStrikes use), 9 slots, no local position bits needed:
    // like Salvo, the caller already knows every cell a firing carpet
    // struck, from the anchor alone.
    // ---------------------------------------------------------------

    /// @dev area.width and area.height are always 3 for Carpet, checked by
    ///      the caller before this runs; kept as AreaGeometry fields
    ///      purely to reuse _rectMaskPlain rather than hardcoding 3 twice.
    ///      shipPresent gates every one of the 9 slots identically: when
    ///      it is false every slot's code stays 0 (inactive) regardless of
    ///      what actually occupies each cell, so a whiff's packed result
    ///      decodes to nothing struck and nothing logged, with no separate
    ///      reveal of the trigger itself needed, the silent whiff falls
    ///      straight out of the same packing and apply path every other
    ///      multi-cell skill already uses.
    function resolveCarpetStrike(AreaGeometry memory area, PlayerSlot storage defender)
        external
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        uint256 areaMaskPlain = _rectMaskPlain(area.anchorRow, area.anchorCol, area.height, area.width);
        ebool shipPresent = defender.boardMask.and(areaMaskPlain).ne(uint256(0));

        euint256 struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint8 localPos = 0; localPos < 9; localPos++) {
            uint256 globalCell = (uint256(area.anchorRow) + localPos / area.width) * BOARD_SIZE
                + (uint256(area.anchorCol) + localPos % area.width);
            uint256 shotBit = uint256(1) << globalCell;

            ebool shieldBreak =
                defender.shieldActive ? shipPresent.and(defender.shieldCellMask.eq(shotBit)) : e.asEbool(false);
            ebool isMine = shipPresent.and(defender.mineMask.and(shotBit).ne(uint256(0))).and(shieldBreak.not());
            ebool isShipHit = shipPresent.and(defender.boardMask.and(shotBit).ne(uint256(0))).and(shieldBreak.not());
            euint256 normalCode = isMine.select(
                e.asEuint256(uint256(3)), isShipHit.select(e.asEuint256(uint256(2)), e.asEuint256(uint256(1)))
            );
            euint256 code =
                shipPresent.select(shieldBreak.select(e.asEuint256(uint256(4)), normalCode), e.asEuint256(uint256(0)));

            packed = packed.or(code.shl(uint256(localPos) * 3));

            ebool countsAsStruck = shipPresent.and(shieldBreak.not());
            struckMask = struckMask.or(countsAsStruck.select(e.asEuint256(shotBit), e.asEuint256(uint256(0))));
        }

        (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckMask);
    }
}
