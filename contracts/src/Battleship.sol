// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";

/// @notice Core 1v1 onchain Battleship loop on Base Sepolia, built on Inco
///         Lightning. Step 1 scope only: a single core match loop, no mines,
///         no skills, no captains, no NFTs.
/// @dev Random encrypted ship placement is not implemented yet, see
///      placeMyBoard(). Shot resolution, turn order and win detection are
///      built and tested against a board state set through a test-only hook
///      so this piece is not blocked on the placement design decision.
contract Battleship {
    using e for euint256;
    using e for ebool;

    uint8 public constant BOARD_SIZE = 15;
    uint16 public constant BOARD_CELLS = 225;
    uint8 public constant NUM_SHIPS = 6;

    /// Fleet config: two ships of length 3, three of length 4, one of length
    /// 5. Kept as a single tunable array so the fleet can be retuned later
    /// without touching placement or shot resolution logic. Solidity does
    /// not support constant fixed-size arrays, so this is a regular state
    /// variable set once at declaration and never written to afterward.
    uint8[NUM_SHIPS] public SHIP_LENGTHS = [5, 4, 4, 4, 3, 3];

    /// Per-player decision time budget, and a buffer added on top before a
    /// timeout can be claimed, so testnet confirmation latency never costs
    /// a player their turn.
    uint256 public constant TIME_BUDGET_SECONDS = 5 minutes;
    uint256 public constant TURN_CONFIRMATION_BUFFER_SECONDS = 30 seconds;

    /// Bounded-attempt random placement: per ship, this many independent
    /// random candidate slots are tried, the first non-overlapping one
    /// wins. Tunable up if the failure rate needs to shrink further, down
    /// if gas is too high.
    uint8 public constant PLACEMENT_ATTEMPTS_PER_SHIP = 20;

    /// Two mines per player, placed on water cells only. Fewer attempts
    /// than ship placement since a mine only has to avoid the ship cells
    /// (about 10% of the board) and at most one other mine, a much lower
    /// collision rate than packing a whole fleet.
    uint8 public constant MINES_PER_PLAYER = 2;
    uint8 public constant MINE_PLACEMENT_ATTEMPTS = 10;

    enum Phase {
        WaitingForOpponent,
        Placing,
        AwaitingDiceRoll,
        InProgress,
        Finished
    }

    struct PlayerSlot {
        address addr;
        bool placed;
        euint256 boardMask; // OR of all shipMask entries, one bit per cell
        euint256[NUM_SHIPS] shipMask; // cells occupied by each ship, disjoint
        euint256[NUM_SHIPS] shipHits; // subset of shipMask hit so far
        euint256 lastDestroyedMask; // the ship (if any) sunk by the most recent shot, else 0, always safe to reveal
        euint256 mineMask; // this player's own mines, never allowed to the opponent
        uint256 shotsAgainstMe; // plain bitmask, cells already shot at on this board
        uint256 remainingTime;
        bool placementPending;
        ebool pendingAllPlaced;
        bool bonusShotAvailable; // set when the opponent triggers one of this player's mines
        bool sonarUsed;
        bool barrageUsed;
    }

    /// At most one action (a normal shot, sonar, or barrage) can be in
    /// flight at a time, awaiting its confirmation before the next action
    /// is allowed.
    enum PendingAction {
        None,
        Shot,
        Sonar,
        Barrage
    }

    struct Match {
        Phase phase;
        PlayerSlot[2] players;
        uint8 turn; // index into players of whose turn it is
        uint256 lastMoveTimestamp;
        address winner;
        euint256 rollA;
        euint256 rollB;
        bool dicePending;
        PendingAction pendingAction;
        uint8 pendingActor; // index of the player who took the pending action
        uint8 pendingCell; // shot only
        ebool pendingHit; // shot only
        ebool pendingAllDestroyed; // shot only
        ebool pendingMineHit; // shot only
    }

    mapping(uint256 => Match) internal matches;
    uint256 public nextMatchId = 1;

    event MatchCreated(uint256 indexed matchId, address indexed creator);
    event MatchJoined(uint256 indexed matchId, address indexed opponent);
    event PlacementSubmitted(uint256 indexed matchId, address indexed player, bytes32 allPlacedHandle);
    event PlacementConfirmed(uint256 indexed matchId, address indexed player);
    event PlacementRetryNeeded(uint256 indexed matchId, address indexed player);
    event DiceRolled(uint256 indexed matchId, bytes32 rollAHandle, bytes32 rollBHandle);
    event GameStarted(uint256 indexed matchId, address indexed firstPlayer);
    event ShotFired(
        uint256 indexed matchId,
        address indexed shooter,
        uint8 cell,
        bytes32 hitHandle,
        bytes32 allDestroyedHandle,
        bytes32 newlyDestroyedHandle
    );
    event ShotResolved(uint256 indexed matchId, uint8 cell, bool hit, address indexed nextTurn);
    event MatchWon(uint256 indexed matchId, address indexed winner);
    event TimeoutClaimed(uint256 indexed matchId, address indexed claimant);

    modifier onlyPlayer(uint256 matchId) {
        Match storage m = matches[matchId];
        require(msg.sender == m.players[0].addr || msg.sender == m.players[1].addr, "not a player in this match");
        _;
    }

    function createMatch() external returns (uint256 matchId) {
        matchId = nextMatchId++;
        Match storage m = matches[matchId];
        m.phase = Phase.WaitingForOpponent;
        m.players[0].addr = msg.sender;
        emit MatchCreated(matchId, msg.sender);
    }

    function joinMatch(uint256 matchId) external {
        Match storage m = matches[matchId];
        require(m.phase == Phase.WaitingForOpponent, "match not joinable");
        require(m.players[0].addr != msg.sender, "cannot play yourself");
        m.players[1].addr = msg.sender;
        m.phase = Phase.Placing;
        emit MatchJoined(matchId, msg.sender);
    }

    /// @notice Randomly and confidentially places this caller's fleet.
    /// @dev Ships are placed longest first, each with PLACEMENT_ATTEMPTS_PER_SHIP
    ///      independent random candidate slots; the first non-overlapping
    ///      candidate wins via the select multiplexer pattern. Every draw,
    ///      decoded position, candidate mask and overlap check stays on
    ///      encrypted values end to end. The only value ever revealed is a
    ///      single allPlaced success bit, confirmed in confirmPlacement. On
    ///      the rare case not every ship found a free slot within its
    ///      attempts, allPlaced reveals false and nothing is written to the
    ///      committed board state, so the caller can call this again for a
    ///      fresh, independent set of draws.
    function placeMyBoard(uint256 matchId) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.phase == Phase.Placing, "not in placement phase");
        uint8 playerIdx = msg.sender == m.players[0].addr ? 0 : 1;
        PlayerSlot storage p = m.players[playerIdx];
        require(!p.placed, "already placed");
        require(!p.placementPending, "placement already submitted, awaiting confirmation");

        uint256 totalDraws =
            uint256(NUM_SHIPS) * PLACEMENT_ATTEMPTS_PER_SHIP + uint256(MINES_PER_PLAYER) * MINE_PLACEMENT_ATTEMPTS;
        require(msg.value >= inco.getFee() * totalDraws, "fee not paid");

        _runPlacement(matchId, playerIdx, e.asEuint256(uint256(0)));
    }

    /// @dev Runs the placement loop starting from a given occupied mask and
    ///      submits the result. Split out from placeMyBoard so a test
    ///      harness can start from a deliberately full board to exercise the
    ///      all-attempts-fail retry path deterministically, without any
    ///      change to the real placement logic itself.
    function _runPlacement(uint256 matchId, uint8 playerIdx, euint256 startingOccupied) internal {
        Match storage m = matches[matchId];
        PlayerSlot storage p = m.players[playerIdx];

        euint256 occupied = startingOccupied;
        ebool allPlaced = e.asEbool(true);
        euint256[NUM_SHIPS] memory shipMasks;

        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            (euint256 shipMask, ebool placedThisShip) = _placeOneShip(SHIP_LENGTHS[i], occupied);
            // shipMask is still the trivial zero handle whenever no attempt
            // succeeded, so folding it into occupied is always safe.
            occupied = occupied.or(shipMask);
            shipMasks[i] = shipMask;
            allPlaced = allPlaced.and(placedThisShip);
        }

        // Mines are placed after the fleet, avoiding every ship cell, so
        // they land on water only. They must never be allowed to the
        // opponent, only to this contract and the owner.
        (euint256 mineMask, ebool allMinesPlaced) = _placeMines(occupied);
        allPlaced = allPlaced.and(allMinesPlaced);

        occupied.allowThis();
        occupied.allow(msg.sender);
        mineMask.allowThis();
        mineMask.allow(msg.sender);
        allPlaced.allowThis();
        e.reveal(allPlaced);

        p.boardMask = occupied;
        p.mineMask = mineMask;
        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            shipMasks[i].allowThis();
            shipMasks[i].allow(msg.sender);
            p.shipMask[i] = shipMasks[i];

            euint256 zero = e.asEuint256(uint256(0));
            zero.allowThis();
            p.shipHits[i] = zero;
        }
        euint256 zeroDestroyed = e.asEuint256(uint256(0));
        zeroDestroyed.allowThis();
        p.lastDestroyedMask = zeroDestroyed;

        p.placementPending = true;
        p.pendingAllPlaced = allPlaced;

        emit PlacementSubmitted(matchId, msg.sender, ebool.unwrap(allPlaced));
    }

    /// @dev Places MINES_PER_PLAYER single-cell mines, each with
    ///      MINE_PLACEMENT_ATTEMPTS independent random candidate cells,
    ///      avoiding every ship cell (shipOccupied) and every previously
    ///      placed mine this call. Same bounded-attempt, first-non-
    ///      overlapping-candidate-wins pattern as ship placement, scoped to
    ///      a single cell instead of a run.
    function _placeMines(euint256 shipOccupied) internal returns (euint256 mineMask, ebool allPlaced) {
        mineMask = e.asEuint256(uint256(0));
        allPlaced = e.asEbool(true);
        euint256 avoid = shipOccupied;

        for (uint8 i = 0; i < MINES_PER_PLAYER; i++) {
            ebool placedThisMine = e.asEbool(false);
            euint256 thisMineMask = e.asEuint256(uint256(0));

            for (uint8 attempt = 0; attempt < MINE_PLACEMENT_ATTEMPTS; attempt++) {
                euint256 idx = e.randBounded(uint256(BOARD_CELLS));
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

    /// @dev Tries PLACEMENT_ATTEMPTS_PER_SHIP independent random candidate
    ///      slots for one ship of the given length against the cells already
    ///      occupied by previously placed ships, keeping the first
    ///      non-overlapping candidate. Every intermediate value (the random
    ///      draw, decoded row/col/orientation, candidate mask, overlap
    ///      check) is an encrypted handle end to end, nothing plaintext ever
    ///      leaves this function.
    function _placeOneShip(uint8 length, euint256 occupiedSoFar) internal returns (euint256 shipMask, ebool placed) {
        uint256 span = uint256(BOARD_SIZE) - length + 1; // valid start offsets along one axis
        uint256 slotsPerOrientation = uint256(BOARD_SIZE) * span;
        uint256 totalSlots = slotsPerOrientation * 2;

        shipMask = e.asEuint256(uint256(0));
        placed = e.asEbool(false);

        for (uint8 attempt = 0; attempt < PLACEMENT_ATTEMPTS_PER_SHIP; attempt++) {
            euint256 idx = e.randBounded(totalSlots);
            euint256 candidate = _decodeCandidateMask(idx, length, span, slotsPerOrientation);

            ebool noOverlap = candidate.and(occupiedSoFar).eq(uint256(0));
            ebool accept = placed.not().and(noOverlap);

            occupiedSoFar = accept.select(occupiedSoFar.or(candidate), occupiedSoFar);
            shipMask = accept.select(candidate, shipMask);
            placed = placed.or(accept);
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

    /// @notice Confirms a submitted placement, or leaves it unplaced so the
    ///         player can retry, based on the covalidator-attested allPlaced
    ///         bit. Only that single bit is ever attested, never the layout.
    /// @dev Authorized entirely by the attestation matching the specific
    ///      pending handle for playerIdx's slot, not by msg.sender, so a
    ///      relayer or the frontend itself can submit this on the player's
    ///      behalf without needing their key.
    function confirmPlacement(
        uint256 matchId,
        uint8 playerIdx,
        DecryptionAttestation memory allPlacedAttestation,
        bytes[] memory allPlacedSignatures
    ) external {
        require(playerIdx < 2, "invalid player index");
        Match storage m = matches[matchId];
        PlayerSlot storage p = m.players[playerIdx];
        require(p.placementPending, "no pending placement");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(allPlacedAttestation, allPlacedSignatures),
            "invalid placement attestation"
        );
        require(ebool.unwrap(p.pendingAllPlaced) == allPlacedAttestation.handle, "placement handle mismatch");

        p.placementPending = false;
        bool allPlaced = asBool(allPlacedAttestation.value);

        if (allPlaced) {
            p.placed = true;
            emit PlacementConfirmed(matchId, p.addr);
            if (m.players[0].placed && m.players[1].placed) {
                m.phase = Phase.AwaitingDiceRoll;
            }
        } else {
            // Not every ship found a free slot within its attempts. Nothing
            // is committed, the player can call placeMyBoard again for a
            // fresh, independent set of random draws.
            emit PlacementRetryNeeded(matchId, p.addr);
        }
    }

    /// @dev Test-only hook to seed a player's board directly, bypassing the
    ///      real random placement, so shot resolution, turn order and win
    ///      detection can be built and tested independently of the
    ///      placement design decision. Not part of the intended production
    ///      surface, callers besides tests should use placeMyBoard.
    ///      Takes plain masks and trivially encrypts them here, in this
    ///      contract's own context, so this contract is the one that ends
    ///      up allowed on the resulting handles (a handle trivially
    ///      encrypted by a caller grants that caller no access on its own).
    function _setBoardForTesting(
        uint256 matchId,
        uint8 playerIdx,
        uint256 boardMaskPlain,
        uint256[NUM_SHIPS] memory shipMaskPlain
    ) internal {
        Match storage m = matches[matchId];
        PlayerSlot storage p = m.players[playerIdx];

        euint256 boardMask = e.asEuint256(boardMaskPlain);
        boardMask.allowThis();
        p.boardMask = boardMask;
        p.placed = true;

        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            euint256 shipMask = e.asEuint256(shipMaskPlain[i]);
            shipMask.allowThis();
            p.shipMask[i] = shipMask;

            euint256 zero = e.asEuint256(uint256(0));
            zero.allowThis();
            p.shipHits[i] = zero;
        }
        euint256 zeroDestroyed = e.asEuint256(uint256(0));
        zeroDestroyed.allowThis();
        p.lastDestroyedMask = zeroDestroyed;

        euint256 zeroMines = e.asEuint256(uint256(0));
        zeroMines.allowThis();
        p.mineMask = zeroMines;

        if (m.players[0].placed && m.players[1].placed) {
            m.phase = Phase.AwaitingDiceRoll;
        }
    }

    /// @dev Test-only hook to seed a player's mines directly on top of an
    ///      already-seeded board, so mine trigger and bonus shot behavior
    ///      can be tested with known mine positions.
    function _setMinesForTesting(uint256 matchId, uint8 playerIdx, uint256 mineMaskPlain, address owner) internal {
        PlayerSlot storage p = matches[matchId].players[playerIdx];
        euint256 mineMask = e.asEuint256(mineMaskPlain);
        mineMask.allowThis();
        mineMask.allow(owner);
        p.mineMask = mineMask;
    }

    function rollDice(uint256 matchId) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.phase == Phase.AwaitingDiceRoll, "not ready for dice roll");
        require(msg.value >= inco.getFee() * 2, "fee not paid");

        euint256 a = e.randBounded(uint256(6)).add(uint256(1));
        euint256 b = e.randBounded(uint256(6)).add(uint256(1));
        a.allowThis();
        b.allowThis();
        e.reveal(a);
        e.reveal(b);

        m.rollA = a;
        m.rollB = b;
        m.dicePending = true;
        emit DiceRolled(matchId, euint256.unwrap(a), euint256.unwrap(b));
    }

    /// @dev No onlyPlayer restriction: the roll state is match-level, not
    ///      keyed by caller, and authorization comes entirely from the
    ///      attestations matching the stored roll handles, so a relayer or
    ///      the frontend itself can submit this on either player's behalf.
    function confirmDiceRoll(
        uint256 matchId,
        DecryptionAttestation memory rollAAttestation,
        bytes[] memory rollASignatures,
        DecryptionAttestation memory rollBAttestation,
        bytes[] memory rollBSignatures
    ) external {
        Match storage m = matches[matchId];
        require(m.dicePending, "no pending dice roll");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(rollAAttestation, rollASignatures),
            "invalid rollA attestation"
        );
        require(
            inco.incoVerifier().isValidDecryptionAttestation(rollBAttestation, rollBSignatures),
            "invalid rollB attestation"
        );
        require(euint256.unwrap(m.rollA) == rollAAttestation.handle, "rollA handle mismatch");
        require(euint256.unwrap(m.rollB) == rollBAttestation.handle, "rollB handle mismatch");

        uint256 rollA = uint256(rollAAttestation.value);
        uint256 rollB = uint256(rollBAttestation.value);
        m.dicePending = false;

        if (rollA == rollB) {
            // Tie, the match stays in AwaitingDiceRoll so either player can
            // call rollDice again with fresh randomness rather than falling
            // back to a deterministic tiebreak.
            return;
        }

        m.turn = rollA > rollB ? 0 : 1;
        m.lastMoveTimestamp = block.timestamp;
        m.players[0].remainingTime = TIME_BUDGET_SECONDS;
        m.players[1].remainingTime = TIME_BUDGET_SECONDS;
        m.phase = Phase.InProgress;
        emit GameStarted(matchId, m.players[m.turn].addr);
    }

    /// @dev Shared preamble for any player action (shoot, sonar, barrage):
    ///      checks phase, turn, that no other action is pending, charges the
    ///      elapsed decision time against the clock, and resets the clock so
    ///      the awaiting-confirmation window starts fresh.
    function _beginAction(Match storage m) internal {
        require(m.phase == Phase.InProgress, "match not in progress");
        require(m.pendingAction == PendingAction.None, "previous action not yet confirmed");
        require(msg.sender == m.players[m.turn].addr, "not your turn");

        uint256 elapsed = block.timestamp - m.lastMoveTimestamp;
        require(
            elapsed <= m.players[m.turn].remainingTime + TURN_CONFIRMATION_BUFFER_SECONDS,
            "you are out of time, opponent can claim a timeout win"
        );
        m.players[m.turn].remainingTime =
            elapsed >= m.players[m.turn].remainingTime ? 0 : m.players[m.turn].remainingTime - elapsed;
        m.lastMoveTimestamp = block.timestamp;
    }

    function shoot(uint256 matchId, uint8 cell) external onlyPlayer(matchId) {
        require(cell < BOARD_CELLS, "cell out of range");
        Match storage m = matches[matchId];
        _beginAction(m);

        uint8 defenderIdx = 1 - m.turn;
        PlayerSlot storage defender = m.players[defenderIdx];
        require((defender.shotsAgainstMe >> cell) & 1 == 0, "cell already shot");
        defender.shotsAgainstMe |= (uint256(1) << cell);

        uint256 shotBit = uint256(1) << cell;
        ebool hit = defender.boardMask.and(shotBit).ne(uint256(0));
        hit.allowThis();

        ebool mineHit = defender.mineMask.and(shotBit).ne(uint256(0));
        mineHit.allowThis();

        ebool allDestroyed = e.asEbool(true);
        euint256 newlyDestroyed = e.asEuint256(uint256(0));
        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            euint256 oldHits = defender.shipHits[i];
            ebool wasAlreadyDestroyed = oldHits.eq(defender.shipMask[i]);

            ebool belongsToShip = defender.shipMask[i].and(shotBit).ne(uint256(0));
            euint256 newHits = belongsToShip.select(oldHits.or(shotBit), oldHits);
            newHits.allowThis();
            defender.shipHits[i] = newHits;

            ebool destroyed = newHits.eq(defender.shipMask[i]);
            allDestroyed = allDestroyed.and(destroyed);

            // A cell belongs to at most one ship, so at most one ship's
            // destroyed status can flip on this shot. ORing the masked
            // values together is therefore exactly that one ship's cells
            // when one is freshly sunk, and zero otherwise, never leaking
            // more than the single ship this particular shot completed.
            ebool justSunk = destroyed.and(wasAlreadyDestroyed.not());
            newlyDestroyed = newlyDestroyed.or(justSunk.select(defender.shipMask[i], e.asEuint256(uint256(0))));
        }
        allDestroyed.allowThis();
        newlyDestroyed.allowThis();
        e.reveal(hit);
        e.reveal(mineHit);
        e.reveal(allDestroyed);
        e.reveal(newlyDestroyed);
        defender.lastDestroyedMask = newlyDestroyed;

        m.pendingAction = PendingAction.Shot;
        m.pendingActor = m.turn;
        m.pendingCell = cell;
        m.pendingHit = hit;
        m.pendingAllDestroyed = allDestroyed;
        m.pendingMineHit = mineHit;

        emit ShotFired(
            matchId, msg.sender, cell, ebool.unwrap(hit), ebool.unwrap(allDestroyed), euint256.unwrap(newlyDestroyed)
        );
    }

    function confirmShot(
        uint256 matchId,
        DecryptionAttestation memory hitAttestation,
        bytes[] memory hitSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures,
        DecryptionAttestation memory mineHitAttestation,
        bytes[] memory mineHitSignatures
    ) external {
        Match storage m = matches[matchId];
        require(m.pendingAction == PendingAction.Shot, "no pending shot");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(hitAttestation, hitSignatures), "invalid hit attestation"
        );
        require(
            inco.incoVerifier().isValidDecryptionAttestation(allDestroyedAttestation, allDestroyedSignatures),
            "invalid win attestation"
        );
        require(
            inco.incoVerifier().isValidDecryptionAttestation(mineHitAttestation, mineHitSignatures),
            "invalid mine attestation"
        );
        require(ebool.unwrap(m.pendingHit) == hitAttestation.handle, "hit handle mismatch");
        require(ebool.unwrap(m.pendingAllDestroyed) == allDestroyedAttestation.handle, "win handle mismatch");
        require(ebool.unwrap(m.pendingMineHit) == mineHitAttestation.handle, "mine handle mismatch");

        bool hit = asBool(hitAttestation.value);
        bool won = asBool(allDestroyedAttestation.value);
        bool mineHit = asBool(mineHitAttestation.value);

        m.pendingAction = PendingAction.None;
        uint8 shooterIdx = m.pendingActor;
        address shooter = m.players[shooterIdx].addr;

        if (mineHit) {
            // Grants the defender (the mine's owner) one extra action on
            // their next turn. A mine triggers once, then this cell can
            // never be shot again (shotsAgainstMe), so it cannot retrigger.
            m.players[1 - shooterIdx].bonusShotAvailable = true;
        }

        if (won) {
            m.phase = Phase.Finished;
            m.winner = shooter;
            emit MatchWon(matchId, shooter);
        } else {
            if (!hit) {
                // A miss normally passes the turn, unless the shooter has a
                // pending bonus action from a mine they triggered earlier,
                // in which case it is spent here instead, and the shooter
                // keeps the turn for one more action.
                if (m.players[shooterIdx].bonusShotAvailable) {
                    m.players[shooterIdx].bonusShotAvailable = false;
                } else {
                    m.turn = 1 - shooterIdx;
                }
            } else if (m.players[shooterIdx].bonusShotAvailable) {
                // A hit already keeps the turn on its own; a pending bonus
                // is still spent here so it cannot carry over to a later
                // turn.
                m.players[shooterIdx].bonusShotAvailable = false;
            }
            m.lastMoveTimestamp = block.timestamp;
        }

        emit ShotResolved(matchId, m.pendingCell, hit, m.players[m.turn].addr);
    }

    function claimTimeout(uint256 matchId) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.phase == Phase.InProgress, "match not in progress");
        require(msg.sender == m.players[1 - m.turn].addr, "only the waiting player can claim a timeout");
        require(
            block.timestamp > m.lastMoveTimestamp + m.players[m.turn].remainingTime + TURN_CONFIRMATION_BUFFER_SECONDS,
            "opponent has not timed out yet"
        );
        m.phase = Phase.Finished;
        m.winner = msg.sender;
        emit MatchWon(matchId, msg.sender);
        emit TimeoutClaimed(matchId, msg.sender);
    }

    function getPhase(uint256 matchId) external view returns (Phase) {
        return matches[matchId].phase;
    }

    function getTurn(uint256 matchId) external view returns (address) {
        Match storage m = matches[matchId];
        return m.players[m.turn].addr;
    }

    function getWinner(uint256 matchId) external view returns (address) {
        return matches[matchId].winner;
    }

    function getPlayerAddress(uint256 matchId, uint8 playerIdx) external view returns (address) {
        return matches[matchId].players[playerIdx].addr;
    }

    function getRemainingTime(uint256 matchId, uint8 playerIdx) external view returns (uint256) {
        return matches[matchId].players[playerIdx].remainingTime;
    }

    function getLastMoveTimestamp(uint256 matchId) external view returns (uint256) {
        return matches[matchId].lastMoveTimestamp;
    }

    function getBoardMask(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].boardMask;
    }

    function getLastDestroyedMask(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].lastDestroyedMask;
    }

    function getShotsAgainst(uint256 matchId, uint8 playerIdx) external view returns (uint256) {
        return matches[matchId].players[playerIdx].shotsAgainstMe;
    }

    function getMineMask(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].mineMask;
    }

    function hasBonusShot(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].bonusShotAvailable;
    }
}
