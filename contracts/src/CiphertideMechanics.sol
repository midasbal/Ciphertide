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
    // a rectangle, strike some distinct cells inside it, reveal each one).
    // Which cells get struck is public information the instant a strike
    // resolves, so the cells themselves are chosen with plain public
    // randomness (pickAreaCells below), not a confidential draw, and only
    // the per-cell hit or miss result stays confidential until reveal.
    // ---------------------------------------------------------------

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

    /// @dev Picks which cells a public random strike hits (Barrage,
    ///      Bombardment, Rake): entirely plaintext arithmetic, no
    ///      encrypted values or random draws involved. Which cells a
    ///      strike hits is going to be revealed the instant it resolves
    ///      regardless, so spending a confidential randBounded draw per
    ///      candidate cell (as an earlier version of this contract did)
    ///      bought no privacy, only extra reveal latency: on Inco each
    ///      confidential draw costs roughly one second of reveal wait once
    ///      the action lands, so a 6 cell strike at 8 attempts each cost
    ///      about 48 seconds just to pick cells nobody needed kept secret.
    ///      This costs zero draws.
    ///
    ///      seed must come from a block value the caller cannot freely
    ///      choose (see Ciphertide's _publicStrikeSeed), mixed with the
    ///      match, the caller and a per-action nonce, so a player cannot
    ///      predict or steer which cells their own strike will land on
    ///      before sending the transaction.
    ///
    ///      Builds the list of in-area cells not already in shotsAgainstMe,
    ///      draws the strike count from seed when minCells < maxCells (a
    ///      fixed count when they are equal still consumes no seed bits for
    ///      the count), then runs a partial Fisher-Yates shuffle over the
    ///      free candidates, reseeding with keccak256 every draw so no
    ///      single block value is reused across choices. If the area has
    ///      fewer free cells than the chosen count (only possible once most
    ///      of it has already been shot), the count is clamped down to
    ///      however many free cells remain rather than reverting.
    /// @dev A commit-reveal seed would hardened this further against a
    ///      sequencer influencing block.prevrandao to bias outcomes; not
    ///      needed for a game skill's cell choice on testnet today, worth
    ///      revisiting if this ever needs a stronger fairness guarantee.
    function pickAreaCells(uint256 seed, AreaGeometry memory area, uint8 minCells, uint8 maxCells, uint256 shotsAgainstMe)
        external
        pure
        returns (uint8[] memory cells)
    {
        uint256 areaSize = uint256(area.width) * uint256(area.height);
        uint8[] memory candidates = new uint8[](areaSize);
        uint256 freeCount = 0;
        for (uint256 i = 0; i < areaSize; i++) {
            uint256 globalCell =
                (uint256(area.anchorRow) + i / area.width) * BOARD_SIZE + (uint256(area.anchorCol) + i % area.width);
            if ((shotsAgainstMe >> globalCell) & 1 == 0) {
                candidates[freeCount] = uint8(globalCell);
                freeCount++;
            }
        }

        uint8 count = minCells;
        if (maxCells > minCells) {
            seed = uint256(keccak256(abi.encode(seed, uint256(0))));
            count = minCells + uint8(seed % (uint256(maxCells - minCells) + 1));
        }
        if (uint256(count) > freeCount) {
            count = uint8(freeCount);
        }

        cells = new uint8[](count);
        for (uint8 k = 0; k < count; k++) {
            seed = uint256(keccak256(abi.encode(seed, uint256(k) + 1)));
            uint256 remaining = freeCount - k;
            uint256 j = k + (seed % remaining);
            (candidates[k], candidates[j]) = (candidates[j], candidates[k]);
            cells[k] = candidates[k];
        }
    }

    /// @dev Resolves a set of already public, already chosen cells against
    ///      the defender's hidden board: identical resolution shape to
    ///      resolveChosenStrikes below (one 3 bit result code per cell, no
    ///      local position needed since the caller already knows every
    ///      cell), just sized to cells.length instead of Salvo's fixed 3,
    ///      so it also covers Barrage's randomized 4 to 6 count and
    ///      Bombardment's and Rake's fixed counts. Whether the shield
    ///      actually broke is only acted on later, once the caller reveals
    ///      and decodes the returned packed value, this function only
    ///      folds the break into the encrypted packing, it never reads or
    ///      writes shieldActive.
    function resolveChosenAreaStrikes(uint8[] memory cells, PlayerSlot storage defender)
        external
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        euint256 struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint256 k = 0; k < cells.length; k++) {
            uint256 shotBit = uint256(1) << cells[k];
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
