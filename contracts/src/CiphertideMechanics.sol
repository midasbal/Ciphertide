// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {PlayerSlot, AreaSkillState} from "./CiphertideTypes.sol";

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

    /// @dev Shared per-cell result-code computation behind
    ///      resolveChosenAreaStrikes and resolveAreaStrikeSlice: one 3 bit
    ///      result code per cell in `cells`, no local position needed since
    ///      the caller already knows every cell, and no ship damage applied
    ///      here (see applyAreaShipDamage), only the codes and which cells
    ///      count as struck. slotOffset places each cell's code at the
    ///      correct absolute bit position in a packed value that may span
    ///      more cells than this one call resolves, so a stepped caller
    ///      resolving cells in chunks across several transactions can OR
    ///      each chunk's own partial packed value directly into a growing
    ///      accumulator without the bit positions colliding. Whether the
    ///      shield actually broke is only acted on later, once the caller
    ///      reveals and decodes the packed value, this only folds the
    ///      break into the encrypted packing, it never reads or writes
    ///      shieldActive.
    function _resolveCellCodes(uint8[] memory cells, uint8 slotOffset, PlayerSlot storage defender)
        internal
        returns (euint256 packed, euint256 struckMask)
    {
        packed = e.asEuint256(uint256(0));
        struckMask = e.asEuint256(uint256(0));

        for (uint256 k = 0; k < cells.length; k++) {
            uint256 shotBit = uint256(1) << cells[k];
            ebool shieldBreak = defender.shieldActive ? defender.shieldCellMask.eq(shotBit) : e.asEbool(false);
            ebool isMine = defender.mineMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            ebool isShipHit = defender.boardMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            euint256 normalCode = isMine.select(
                e.asEuint256(uint256(3)), isShipHit.select(e.asEuint256(uint256(2)), e.asEuint256(uint256(1)))
            );
            euint256 code = shieldBreak.select(e.asEuint256(uint256(4)), normalCode);

            packed = packed.or(code.shl(uint256(slotOffset + k) * 3));

            ebool countsAsStruck = shieldBreak.not();
            struckMask = struckMask.or(countsAsStruck.select(e.asEuint256(shotBit), e.asEuint256(uint256(0))));
        }
    }

    /// @dev Resolves a set of already public, already chosen cells against
    ///      the defender's hidden board in one pass: cell codes plus ship
    ///      damage applied immediately, for a skill that always fits in a
    ///      single transaction (Barrage and Rake, via their shared caller
    ///      in Ciphertide.sol). Sized to cells.length instead of a fixed
    ///      count, so it covers Barrage's randomized 4 to 6 cells and
    ///      Rake's fixed 3 alike. Bombardment strikes more cells than fits
    ///      safely in one transaction and instead calls
    ///      resolveAreaStrikeSlice per chunk and applyAreaShipDamage once
    ///      at the end, see Ciphertide.useBombardment's own comment.
    function resolveChosenAreaStrikes(uint8[] memory cells, PlayerSlot storage defender)
        external
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        euint256 struckMask;
        (packed, struckMask) = _resolveCellCodes(cells, 0, defender);
        (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckMask);
    }

    /// @notice Runs one full step of a stepped Bombardment firing sequence:
    ///         resolves the next chunk of already publicly picked, already
    ///         stored cells (state.stepsDone through +chunkSize - 1, read
    ///         straight from the match's own stored cell list rather than
    ///         the caller building a memory copy first), accumulates this
    ///         chunk's packed codes and struck mask into state, and
    ///         advances state.stepsDone. On the chunk that reaches
    ///         totalCells, also applies ship damage from the now complete
    ///         struck mask, reveals the packed and win values, and stashes
    ///         them into state ready for confirmBombardment, mirroring
    ///         Ciphertide's own _finalizeAreaPending tail for a
    ///         single-transaction skill. Every piece of this needed a
    ///         defender or state storage pointer already, so folding the
    ///         whole step (not just cell-code resolution) into one library
    ///         call keeps this orchestration out of Ciphertide's own
    ///         deployed bytecode entirely, only the call itself and the
    ///         Fired-vs-StepSubmitted branch stay there.
    /// @dev Splitting cell-code resolution from ship-damage application
    ///      (only running the full per-ship loop on the final chunk, not
    ///      every chunk) avoids redundantly re-reading and re-writing the
    ///      same 6 ship-hit storage slots on every chunk: ship damage only
    ///      needs to see the complete struck mask once, a partial
    ///      mid-sequence view of it is meaningless anyway.
    function stepBombardment(
        AreaSkillState storage state,
        uint8[15] storage cells,
        uint8 stepSize,
        uint8 totalCells,
        PlayerSlot storage defender
    ) external returns (bool finished, uint8 done, ebool allDestroyed) {
        uint8 doneBefore = state.stepsDone;
        uint8 remaining = totalCells - doneBefore;
        uint8 chunkSize = remaining < stepSize ? remaining : stepSize;

        euint256 stepPacked = e.asEuint256(uint256(0));
        euint256 stepStruck = e.asEuint256(uint256(0));
        for (uint8 k = 0; k < chunkSize; k++) {
            uint256 shotBit = uint256(1) << cells[doneBefore + k];
            ebool shieldBreak = defender.shieldActive ? defender.shieldCellMask.eq(shotBit) : e.asEbool(false);
            ebool isMine = defender.mineMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            ebool isShipHit = defender.boardMask.and(shotBit).ne(uint256(0)).and(shieldBreak.not());
            euint256 normalCode = isMine.select(
                e.asEuint256(uint256(3)), isShipHit.select(e.asEuint256(uint256(2)), e.asEuint256(uint256(1)))
            );
            euint256 code = shieldBreak.select(e.asEuint256(uint256(4)), normalCode);

            stepPacked = stepPacked.or(code.shl(uint256(doneBefore + k) * 3));

            ebool countsAsStruck = shieldBreak.not();
            stepStruck = stepStruck.or(countsAsStruck.select(e.asEuint256(shotBit), e.asEuint256(uint256(0))));
        }

        euint256 packedSoFar = state.packed.or(stepPacked);
        euint256 struckSoFar = state.struckSoFar.or(stepStruck);
        packedSoFar.allowThis();
        struckSoFar.allowThis();
        state.packed = packedSoFar;
        state.struckSoFar = struckSoFar;

        done = doneBefore + chunkSize;
        finished = done >= totalCells;
        state.stepsDone = finished ? 0 : done;

        if (finished) {
            euint256 newlyDestroyed;
            (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckSoFar);
            allDestroyed.allowThis();
            newlyDestroyed.allowThis();
            e.reveal(packedSoFar);
            e.reveal(allDestroyed);
            e.reveal(newlyDestroyed);
            defender.lastDestroyedMask = newlyDestroyed;
            state.allDestroyed = allDestroyed;
        }
    }

    /// @notice Copies count cells out of a match's stored cell list into a
    ///         memory array, for Ciphertide.useBombardment's final step to
    ///         build the BombardmentFired event's cell list from storage
    ///         (the original memory array pickAreaCells returned only
    ///         lived in the opening step's own call, long gone by the
    ///         final step). Pulled into the library purely to keep this
    ///         copying loop's bytecode out of Ciphertide's own deployed
    ///         size, the same reasoning as stepBombardment reading storage
    ///         directly.
    function copyCells(uint8[15] storage cells, uint8 count) external view returns (uint8[] memory result) {
        result = new uint8[](count);
        for (uint8 k = 0; k < count; k++) {
            result[k] = cells[k];
        }
    }

    /// @notice Folds a fully accumulated struck mask, every cell across
    ///         every chunk of a strike, single-transaction or stepped
    ///         alike, into the defender's ship hit tracking in one pass.
    /// @dev The same tail half resolveChosenAreaStrikes runs inline for a
    ///      single-transaction skill, exposed as its own external entry
    ///      point so a stepped skill's final chunk (Bombardment, Carpet)
    ///      can call it once, after every earlier chunk's own struck mask
    ///      has already been OR'd into the accumulator the caller passes
    ///      in here.
    function applyAreaShipDamage(PlayerSlot storage defender, euint256 struckMask)
        external
        returns (euint256 newlyDestroyed, ebool allDestroyed)
    {
        return _applyAreaShipDamage(defender, struckMask);
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

    /// @notice Computes Carpet's "any ship cell inside the aimed 3x3" gate
    ///         once, up front: gates every one of the 9 slots identically,
    ///         when false every slot's code stays 0 (inactive) regardless
    ///         of what actually occupies each cell, so a whiff's packed
    ///         result decodes to nothing struck and nothing logged, with
    ///         no separate reveal of the trigger itself needed. The
    ///         caller (Ciphertide.useCarpet) stores this ebool and passes
    ///         it back into every chunk of resolveCarpetStrikeSlice, so
    ///         every slot across every chunk is gated by the exact same
    ///         computation regardless of which step resolves it.
    /// @dev area.width and area.height are always 3 for Carpet, checked by
    ///      the caller before this runs; kept as an AreaGeometry field
    ///      purely to reuse _rectMaskPlain rather than hardcoding 3 twice.
    function beginCarpetShipPresent(AreaGeometry memory area, PlayerSlot storage defender)
        external
        returns (ebool shipPresent)
    {
        uint256 areaMaskPlain = _rectMaskPlain(area.anchorRow, area.anchorCol, area.height, area.width);
        shipPresent = defender.boardMask.and(areaMaskPlain).ne(uint256(0));
    }

    /// @notice Runs one full step of a stepped Carpet firing sequence, the
    ///         same shape stepBombardment uses: resolves the next chunk of
    ///         the 9 fixed local slots (state.stepsDone through +chunkSize
    ///         - 1), gated by shipPresent (computed once up front by
    ///         beginCarpetShipPresent and passed back in unchanged every
    ///         step), accumulates into state, advances state.stepsDone,
    ///         and on the chunk that reaches CARPET_CELL_COUNT also applies
    ///         ship damage, reveals the packed and win values, and stashes
    ///         them into state ready for confirmCarpet. Packs one 3 bit
    ///         result code per cell (0 inactive, 1 miss, 2 ship hit, 3
    ///         mine, 4 shield break) at bit position startSlot + i, no
    ///         local position bits beyond that needed: like Salvo, the
    ///         caller already knows every cell a firing carpet struck, from
    ///         the anchor alone.
    function stepCarpet(
        AreaSkillState storage state,
        AreaGeometry memory area,
        uint8 stepSize,
        uint8 totalCells,
        PlayerSlot storage defender
    ) external returns (bool finished, uint8 done, ebool allDestroyed) {
        ebool shipPresent = state.carpetShipPresent;
        uint8 doneBefore = state.stepsDone;
        uint8 remaining = totalCells - doneBefore;
        uint8 chunkSize = remaining < stepSize ? remaining : stepSize;

        euint256 stepPacked = e.asEuint256(uint256(0));
        euint256 stepStruck = e.asEuint256(uint256(0));
        for (uint8 i = 0; i < chunkSize; i++) {
            uint8 localPos = doneBefore + i;
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

            stepPacked = stepPacked.or(code.shl(uint256(localPos) * 3));

            ebool countsAsStruck = shipPresent.and(shieldBreak.not());
            stepStruck = stepStruck.or(countsAsStruck.select(e.asEuint256(shotBit), e.asEuint256(uint256(0))));
        }

        euint256 packedSoFar = state.packed.or(stepPacked);
        euint256 struckSoFar = state.struckSoFar.or(stepStruck);
        packedSoFar.allowThis();
        struckSoFar.allowThis();
        state.packed = packedSoFar;
        state.struckSoFar = struckSoFar;

        done = doneBefore + chunkSize;
        finished = done >= totalCells;
        state.stepsDone = finished ? 0 : done;

        if (finished) {
            euint256 newlyDestroyed;
            (newlyDestroyed, allDestroyed) = _applyAreaShipDamage(defender, struckSoFar);
            allDestroyed.allowThis();
            newlyDestroyed.allowThis();
            e.reveal(packedSoFar);
            e.reveal(allDestroyed);
            e.reveal(newlyDestroyed);
            defender.lastDestroyedMask = newlyDestroyed;
            state.allDestroyed = allDestroyed;
        }
    }
}
