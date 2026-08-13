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

    /// Sonar: one 5x5 area, whole board query, single use per match.
    uint8 public constant SONAR_AREA_SIZE = 5;

    /// Barrage: one 4x4 area, a random 4 to 6 of its 16 cells are struck.
    /// The first BARRAGE_MIN_CELLS slots are always struck (count is at
    /// least that many), the remaining slots are conditionally struck
    /// depending on the random count. Each slot draws BARRAGE_ATTEMPTS_PER_CELL
    /// independent candidates to land on a cell distinct from every other
    /// slot and from cells already shot, few attempts suffice since the
    /// area only has 16 cells and at most 5 are already excluded.
    uint8 public constant BARRAGE_AREA_SIZE = 4;
    uint8 public constant BARRAGE_MIN_CELLS = 4;
    uint8 public constant BARRAGE_MAX_CELLS = 6;
    uint8 public constant BARRAGE_ATTEMPTS_PER_CELL = 8;

    /// Captain identity, declared per player when entering a match. Every
    /// captain carries the two shared skills, Sonar and Barrage, plus one
    /// unique skill that is not implemented yet. This contract only records
    /// which captain a player declared, it does not store currency, unlock
    /// state, or any other profile or progression data, and it does not
    /// check whether a captain is unlocked. That is handled entirely off
    /// chain in the frontend profile. Any player may declare any captain.
    uint8 public constant CAPTAIN_SHIELD = 1;
    uint8 public constant CAPTAIN_BOMBARDMENT = 2;
    uint8 public constant CAPTAIN_RAKE = 3;
    uint8 public constant CAPTAIN_SALVO = 4;
    uint8 public constant CAPTAIN_CARPET = 5;
    uint8 public constant NUM_CAPTAINS = 5;

    enum Phase {
        WaitingForOpponent,
        Placing,
        AwaitingDiceRoll,
        InProgress,
        Finished
    }

    struct PlayerSlot {
        address addr;
        uint8 captain; // declared at createMatch or joinMatch, one of the NUM_CAPTAINS ids
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
        bool shieldUsed; // gates placeShield to once per match, captain 1 only
        euint256 shieldCellMask; // encrypted single-bit mask of the shielded cell, 0 if none or invalid
        // Public on purpose: whether a shield has been committed is not a
        // secret, only the CELL it guards is. True once placeShield has run,
        // even for an invalid pick, since an invalid pick's shieldCellMask
        // is obliviously zeroed and can therefore never match a real shot,
        // leaving it silently, permanently inert without needing a second
        // encrypted flag. Cleared back to false the moment the shield
        // breaks.
        bool shieldActive;
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
        ebool pendingShieldBreak; // shot only
        ebool pendingSonarResult; // sonar only
        euint256 pendingBarragePacked; // barrage only, 7 bits per slot: 4 bit local pos + 3 bit result code
        ebool pendingBarrageAllDestroyed; // barrage only
        uint8 pendingBarrageAnchorRow; // barrage only
        uint8 pendingBarrageAnchorCol; // barrage only
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
        bytes32 newlyDestroyedHandle,
        bytes32 shieldBreakHandle
    );
    event ShotResolved(uint256 indexed matchId, uint8 cell, bool hit, bool shieldBreak, address indexed nextTurn);
    event SonarFired(
        uint256 indexed matchId, address indexed player, uint8 anchorRow, uint8 anchorCol, bytes32 resultHandle
    );
    event SonarResolved(uint256 indexed matchId, bool anyShip, address indexed nextTurn);
    event BarrageFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 anchorRow,
        uint8 anchorCol,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event BarrageResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    event ShieldPlaced(uint256 indexed matchId, address indexed player);
    event ShieldBroken(uint256 indexed matchId, address indexed owner, uint8 cell);
    event MatchWon(uint256 indexed matchId, address indexed winner);
    event TimeoutClaimed(uint256 indexed matchId, address indexed claimant);

    modifier onlyPlayer(uint256 matchId) {
        Match storage m = matches[matchId];
        require(msg.sender == m.players[0].addr || msg.sender == m.players[1].addr, "not a player in this match");
        _;
    }

    /// @notice Creates a new match and declares the creator's captain.
    /// @dev The captain id is only ever checked here for being one of the
    ///      NUM_CAPTAINS valid ids, never for being unlocked. Unlock state
    ///      lives entirely off chain in the frontend profile.
    function createMatch(uint8 captainId) external returns (uint256 matchId) {
        require(captainId >= 1 && captainId <= NUM_CAPTAINS, "invalid captain id");
        matchId = nextMatchId++;
        Match storage m = matches[matchId];
        m.phase = Phase.WaitingForOpponent;
        m.players[0].addr = msg.sender;
        m.players[0].captain = captainId;
        emit MatchCreated(matchId, msg.sender);
    }

    /// @notice Joins an existing match and declares the joiner's captain.
    /// @dev Same validation as createMatch: only checks the id is in range,
    ///      never whether it is unlocked.
    function joinMatch(uint256 matchId, uint8 captainId) external {
        require(captainId >= 1 && captainId <= NUM_CAPTAINS, "invalid captain id");
        Match storage m = matches[matchId];
        require(m.phase == Phase.WaitingForOpponent, "match not joinable");
        require(m.players[0].addr != msg.sender, "cannot play yourself");
        m.players[1].addr = msg.sender;
        m.players[1].captain = captainId;
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

        euint256 zeroShieldCell = e.asEuint256(uint256(0));
        zeroShieldCell.allowThis();
        p.shieldCellMask = zeroShieldCell;
        // shieldActive is a plain bool, its zero value already defaults to
        // false, no encrypted trivial-zero handle is needed for it.

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

        euint256 zeroShieldCell = e.asEuint256(uint256(0));
        zeroShieldCell.allowThis();
        p.shieldCellMask = zeroShieldCell;

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

    /// @dev Not called anywhere yet, the unique captain skills do not exist
    ///      yet. Once a unique skill function is built, it should call this
    ///      first to require the acting player declared the captain that
    ///      owns that skill, for example _requireCaptainOwnsSkill(m,
    ///      playerIdx, CAPTAIN_SHIELD) inside a future useShield function.
    function _requireCaptainOwnsSkill(Match storage m, uint8 playerIdx, uint8 requiredCaptainId) internal view {
        require(m.players[playerIdx].captain == requiredCaptainId, "captain does not own this skill");
    }

    /// @notice Captain Shield's unique skill: commits one of the caller's own
    ///         ship cells as a hidden shield, single use per match. The
    ///         first time any shot lands on that cell the shield breaks: the
    ///         break is its own revealed outcome (not a disguised miss), the
    ///         shot does no damage, and the cell survives so a later shot on
    ///         it is a normal hit.
    /// @dev Free action: no phase change, no pending action, no clock
    ///      charge. Callable only on the caller's own turn by the
    ///      CAPTAIN_SHIELD player, once per match. The chosen cell arrives
    ///      as a client encrypted euint256 input (a single bit mask),
    ///      wrapped here with newEuint256. Validity (exactly one bit, and
    ///      that bit is one of the caller's own ship cells) is checked
    ///      obliviously: an invalid pick never reverts, its shieldCellMask
    ///      is silently zeroed instead, so it can never equal any real shot
    ///      bit and the shield can never break, without ever leaking the
    ///      choice through control flow. shieldActive itself is a plain
    ///      bool (whether a shield was committed is not secret) and is set
    ///      unconditionally here, an invalid pick is simply, silently inert.
    function placeShield(uint256 matchId, bytes calldata shieldCellInput) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.phase == Phase.InProgress, "match not in progress");
        uint8 playerIdx = msg.sender == m.players[0].addr ? 0 : 1;
        require(playerIdx == m.turn, "not your turn");
        _requireCaptainOwnsSkill(m, playerIdx, CAPTAIN_SHIELD);

        PlayerSlot storage p = m.players[playerIdx];
        require(!p.shieldUsed, "shield already used");
        p.shieldUsed = true;

        require(msg.value >= inco.getFee(), "fee not paid");
        euint256 cellMask = e.newEuint256(shieldCellInput, msg.sender);

        ebool isValidPick = _isSingleOwnShipCell(cellMask, p.boardMask);
        euint256 validatedCellMask = isValidPick.select(cellMask, e.asEuint256(uint256(0)));

        validatedCellMask.allowThis();
        validatedCellMask.allow(msg.sender);

        p.shieldCellMask = validatedCellMask;
        p.shieldActive = true;

        emit ShieldPlaced(matchId, msg.sender);
    }

    /// @dev Obliviously checks that candidateMask has exactly one bit set
    ///      (candidateMask != 0 and candidateMask & (candidateMask - 1) == 0,
    ///      the standard single-bit trick) and that this single bit is part
    ///      of ownBoardMask. Never branches or reverts on the encrypted
    ///      result, only returns it for the caller to fold into a select.
    function _isSingleOwnShipCell(euint256 candidateMask, euint256 ownBoardMask) internal returns (ebool) {
        ebool nonZero = candidateMask.ne(uint256(0));
        ebool singleBit = candidateMask.and(candidateMask.sub(uint256(1))).eq(uint256(0));
        ebool isShipCell = candidateMask.and(ownBoardMask).eq(candidateMask);
        return nonZero.and(singleBit).and(isShipCell);
    }

    /// @dev Bundles a shot's shield-break outcome so shoot() only needs one
    ///      local instead of two, keeping its stack frame within the EVM's
    ///      local variable limit.
    struct ShieldCheckResult {
        ebool shieldBreak;
        euint256 effectiveShotBit;
    }

    /// @dev Obliviously checks whether shotBit is the defender's shielded
    ///      cell. Whether a shield is active at all is a plain bool, so this
    ///      only needs to run the encrypted equality check when one is up,
    ///      a plaintext branch, not a branch on ciphertext. effectiveShotBit
    ///      is shotBit unchanged, or 0 on a break, so the caller can fold it
    ///      straight into hit detection and ship hit tracking: a break does
    ///      no damage, exactly like shooting nowhere.
    function _resolveShieldBreak(PlayerSlot storage defender, uint256 shotBit)
        internal
        returns (ShieldCheckResult memory r)
    {
        r.shieldBreak = defender.shieldActive ? defender.shieldCellMask.eq(shotBit) : e.asEbool(false);
        r.shieldBreak.allowThis();
        r.effectiveShotBit = r.shieldBreak.select(e.asEuint256(uint256(0)), e.asEuint256(shotBit));
    }

    function shoot(uint256 matchId, uint8 cell) external onlyPlayer(matchId) {
        require(cell < BOARD_CELLS, "cell out of range");
        Match storage m = matches[matchId];
        _beginAction(m);

        uint8 defenderIdx = 1 - m.turn;
        PlayerSlot storage defender = m.players[defenderIdx];
        require((defender.shotsAgainstMe >> cell) & 1 == 0, "cell already shot");
        // Every resolved shot is logged into shotsAgainstMe in confirmShot,
        // with one exception (a shield break), see the comment there.

        uint256 shotBit = uint256(1) << cell;

        // Obliviously check whether this shot lands on the defender's
        // shielded cell. A break does no damage (effectiveShotBit becomes 0,
        // folded into hit detection and ship hit tracking below, so the
        // ship cell is never marked hit and never sunk from this shot). It
        // still resolves as hit=false so the turn passes like a miss, but
        // shieldBreak is revealed separately below, its own outcome, never
        // disguised as a plain miss, so the shooter learns a ship is there.
        ShieldCheckResult memory shield = _resolveShieldBreak(defender, shotBit);

        ebool hit = defender.boardMask.and(shield.effectiveShotBit).ne(uint256(0));
        hit.allowThis();

        ebool mineHit = defender.mineMask.and(shotBit).ne(uint256(0));
        mineHit.allowThis();

        ebool allDestroyed = e.asEbool(true);
        euint256 newlyDestroyed = e.asEuint256(uint256(0));
        for (uint8 i = 0; i < NUM_SHIPS; i++) {
            euint256 oldHits = defender.shipHits[i];
            ebool wasAlreadyDestroyed = oldHits.eq(defender.shipMask[i]);

            ebool belongsToShip = defender.shipMask[i].and(shield.effectiveShotBit).ne(uint256(0));
            euint256 newHits = belongsToShip.select(oldHits.or(shield.effectiveShotBit), oldHits);
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
        e.reveal(shield.shieldBreak);
        defender.lastDestroyedMask = newlyDestroyed;

        m.pendingAction = PendingAction.Shot;
        m.pendingActor = m.turn;
        m.pendingCell = cell;
        m.pendingHit = hit;
        m.pendingAllDestroyed = allDestroyed;
        m.pendingMineHit = mineHit;
        m.pendingShieldBreak = shield.shieldBreak;

        emit ShotFired(
            matchId,
            msg.sender,
            cell,
            ebool.unwrap(hit),
            ebool.unwrap(allDestroyed),
            euint256.unwrap(newlyDestroyed),
            ebool.unwrap(shield.shieldBreak)
        );
    }

    function confirmShot(
        uint256 matchId,
        DecryptionAttestation memory hitAttestation,
        bytes[] memory hitSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures,
        DecryptionAttestation memory mineHitAttestation,
        bytes[] memory mineHitSignatures,
        DecryptionAttestation memory shieldBreakAttestation,
        bytes[] memory shieldBreakSignatures
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
        require(
            inco.incoVerifier().isValidDecryptionAttestation(shieldBreakAttestation, shieldBreakSignatures),
            "invalid shield break attestation"
        );
        require(ebool.unwrap(m.pendingHit) == hitAttestation.handle, "hit handle mismatch");
        require(ebool.unwrap(m.pendingAllDestroyed) == allDestroyedAttestation.handle, "win handle mismatch");
        require(ebool.unwrap(m.pendingMineHit) == mineHitAttestation.handle, "mine handle mismatch");
        require(
            ebool.unwrap(m.pendingShieldBreak) == shieldBreakAttestation.handle, "shield break handle mismatch"
        );

        _resolveShotOutcome(
            matchId,
            m,
            asBool(hitAttestation.value),
            asBool(allDestroyedAttestation.value),
            asBool(mineHitAttestation.value),
            asBool(shieldBreakAttestation.value)
        );
    }

    /// @dev Applies a confirmed shot's plaintext outcome: logging, the mine
    ///      bonus, win detection and the turn pass. Pulled out of
    ///      confirmShot, which already carries four attestation structs and
    ///      four signature arrays, to keep confirmShot's own stack frame
    ///      within the EVM's local variable limit.
    function _resolveShotOutcome(uint256 matchId, Match storage m, bool hit, bool won, bool mineHit, bool shieldBreak)
        internal
    {
        m.pendingAction = PendingAction.None;
        uint8 shooterIdx = m.pendingActor;
        address shooter = m.players[shooterIdx].addr;
        PlayerSlot storage defender = m.players[1 - shooterIdx];

        // Every resolved shot is logged into shotsAgainstMe, exactly as
        // before the shield rework, with one exception: a shield break is
        // not logged, so that cell can be shot again once the shield is
        // gone. shieldBreak is already a revealed plaintext value here, so
        // this exception is a plain if, not an oblivious operation. Hits,
        // plain misses and mine cells are all logged the same way, so a
        // triggered mine stays indistinguishable from a plain miss in the
        // public log.
        if (shieldBreak) {
            defender.shieldActive = false;
            emit ShieldBroken(matchId, defender.addr, m.pendingCell);
        } else {
            defender.shotsAgainstMe |= (uint256(1) << m.pendingCell);
        }

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
                // A miss, including a shield break, normally passes the
                // turn, unless the shooter has a pending bonus action from
                // a mine they triggered earlier, in which case it is spent
                // here instead, and the shooter keeps the turn for one more
                // action.
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

        emit ShotResolved(matchId, m.pendingCell, hit, shieldBreak, m.players[m.turn].addr);
    }

    /// @notice Queries a 5x5 area of the opponent's board for any ship
    ///         cell, revealing only a yes or no bit, never which cell or
    ///         how many. Consumes the match's single sonar charge and is
    ///         the player's whole action for the turn.
    /// @dev No random draws and no ciphertext inputs are involved (the area
    ///      is a plaintext rectangle the caller picked, and.and()/ne()/
    ///      reveal() are all free), so this needs no fee.
    function useSonar(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        require(
            uint256(anchorRow) + SONAR_AREA_SIZE <= BOARD_SIZE && uint256(anchorCol) + SONAR_AREA_SIZE <= BOARD_SIZE,
            "sonar area does not fit on the board"
        );

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.sonarUsed, "sonar already used");
        attacker.sonarUsed = true;

        PlayerSlot storage defender = m.players[1 - m.turn];
        uint256 areaMask = _rectMask(anchorRow, anchorCol, SONAR_AREA_SIZE, SONAR_AREA_SIZE);

        ebool anyShip = defender.boardMask.and(areaMask).ne(uint256(0));
        anyShip.allowThis();
        e.reveal(anyShip);

        m.pendingAction = PendingAction.Sonar;
        m.pendingActor = m.turn;
        m.pendingSonarResult = anyShip;

        emit SonarFired(matchId, msg.sender, anchorRow, anchorCol, ebool.unwrap(anyShip));
    }

    function confirmSonar(uint256 matchId, DecryptionAttestation memory attestation, bytes[] memory signatures)
        external
    {
        Match storage m = matches[matchId];
        require(m.pendingAction == PendingAction.Sonar, "no pending sonar");
        require(inco.incoVerifier().isValidDecryptionAttestation(attestation, signatures), "invalid sonar attestation");
        require(ebool.unwrap(m.pendingSonarResult) == attestation.handle, "sonar handle mismatch");

        m.pendingAction = PendingAction.None;
        uint8 actor = m.pendingActor;
        bool anyShip = asBool(attestation.value);

        // Sonar is the player's whole action for the turn: it always ends
        // the turn afterward, except a pending bonus action from an
        // earlier mine trigger grants one more action here too, exactly
        // like a shot's miss would.
        if (m.players[actor].bonusShotAvailable) {
            m.players[actor].bonusShotAvailable = false;
        } else {
            m.turn = 1 - actor;
        }
        m.lastMoveTimestamp = block.timestamp;

        emit SonarResolved(matchId, anyShip, m.players[m.turn].addr);
    }

    /// @dev Plaintext mask for a height x width rectangle anchored at
    ///      (row0, col0) on the BOARD_SIZE x BOARD_SIZE board. Pure
    ///      arithmetic, no encrypted values involved, since the area itself
    ///      is a public choice, only its contents are confidential.
    function _rectMask(uint8 row0, uint8 col0, uint8 height, uint8 width) internal pure returns (uint256 mask) {
        uint256 rowRun = (uint256(1) << width) - 1;
        for (uint8 r = 0; r < height; r++) {
            mask |= rowRun << ((uint256(row0) + r) * BOARD_SIZE + col0);
        }
    }

    /// @notice Strikes a random 4 to 6 of the 16 cells in a caller chosen
    ///         4x4 area, revealing hit or miss for each struck cell. Ship
    ///         hits burn cells and can sink ships exactly like a normal
    ///         shot. If a struck cell is a mine, the mine penalty still
    ///         applies alongside any ship hits in the same barrage. If a
    ///         struck cell is the defender's shielded cell, that cell
    ///         resolves as a shield break instead: no damage, the cell
    ///         survives, and the shield is consumed. Consumes the match's
    ///         single barrage charge and is the player's whole action for
    ///         the turn.
    /// @dev The count and the six candidate cells are picked with the same
    ///      bounded-attempt, first-non-overlapping-candidate pattern as
    ///      ship placement, entirely on encrypted values. The only reveals
    ///      are one packed value (six 7 bit slots: 4 bit local position
    ///      plus a 3 bit result code, 0 inactive, 1 miss, 2 hit, 3 mine, 4
    ///      shield break), the newly sunk ship mask, and the win bit.
    function useBarrage(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        require(
            uint256(anchorRow) + BARRAGE_AREA_SIZE <= BOARD_SIZE
                && uint256(anchorCol) + BARRAGE_AREA_SIZE <= BOARD_SIZE,
            "barrage area does not fit on the board"
        );

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.barrageUsed, "barrage already used");
        attacker.barrageUsed = true;

        uint256 totalDraws = uint256(1) + uint256(BARRAGE_MAX_CELLS) * BARRAGE_ATTEMPTS_PER_CELL;
        require(msg.value >= inco.getFee() * totalDraws, "fee not paid");

        PlayerSlot storage defender = m.players[1 - m.turn];
        (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) =
            _resolveBarrageStrikes(anchorRow, anchorCol, defender);

        packed.allowThis();
        allDestroyed.allowThis();
        newlyDestroyed.allowThis();
        e.reveal(packed);
        e.reveal(allDestroyed);
        e.reveal(newlyDestroyed);
        defender.lastDestroyedMask = newlyDestroyed;

        m.pendingAction = PendingAction.Barrage;
        m.pendingActor = m.turn;
        m.pendingBarragePacked = packed;
        m.pendingBarrageAllDestroyed = allDestroyed;
        m.pendingBarrageAnchorRow = anchorRow;
        m.pendingBarrageAnchorCol = anchorCol;

        emit BarrageFired(
            matchId, msg.sender, anchorRow, anchorCol, euint256.unwrap(packed), ebool.unwrap(allDestroyed)
        );
    }

    /// @dev Draws the random count, picks all six candidate slots, and
    ///      folds the resulting struck cells into ship hit tracking. Unlike
    ///      a normal shot, whether the shield broke is not resolved here:
    ///      it stays folded into the per-slot packed code (shield break is
    ///      its own code, see _barrageResultCode) and is only acted on once
    ///      that code is decoded back to plaintext in confirmBarrage.
    ///      Pulled out of useBarrage to keep its own stack frame small.
    function _resolveBarrageStrikes(uint8 anchorRow, uint8 anchorCol, PlayerSlot storage defender)
        internal
        returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed)
    {
        euint256 struckMask;
        (packed, struckMask) = _pickAllBarrageSlots(anchorRow, anchorCol, defender);
        (newlyDestroyed, allDestroyed) = _applyBarrageShipDamage(defender, struckMask);
    }

    /// @dev Draws the random count and picks all six candidate slots.
    ///      Pulled out of _resolveBarrageStrikes to keep its stack frame
    ///      small.
    function _pickAllBarrageSlots(uint8 anchorRow, uint8 anchorCol, PlayerSlot storage defender)
        internal
        returns (euint256 packed, euint256 struckMask)
    {
        euint256 count = e.randBounded(uint256(3)).add(uint256(4));
        euint256 avoid = e.asEuint256(defender.shotsAgainstMe);
        struckMask = e.asEuint256(uint256(0));
        packed = e.asEuint256(uint256(0));

        for (uint8 k = 0; k < BARRAGE_MAX_CELLS; k++) {
            ebool isActive = k < BARRAGE_MIN_CELLS ? e.asEbool(true) : count.gt(uint256(k));
            BarrageSlotResult memory r = _pickBarrageSlot(anchorRow, anchorCol, k, isActive, avoid, defender);
            avoid = r.newAvoid;
            packed = packed.or(r.packedSlot);
            struckMask = struckMask.or(r.struckContribution);
        }
    }

    /// @dev Bundles one barrage slot's outputs into memory instead of three
    ///      separate stack return values, keeping _pickAllBarrageSlots'
    ///      stack frame within the EVM's local variable limit.
    struct BarrageSlotResult {
        euint256 newAvoid;
        euint256 packedSlot;
        euint256 struckContribution;
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
        for (uint8 i = 0; i < NUM_SHIPS; i++) {
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

    /// @dev Tries BARRAGE_ATTEMPTS_PER_CELL independent random cells within
    ///      the 4x4 area for one barrage slot, avoiding every cell already
    ///      claimed by an earlier slot this barrage or already shot on a
    ///      previous action, keeping the first non-overlapping candidate.
    ///      Packs the local position and a result code (0 if this slot
    ///      never found a free candidate or the random count did not reach
    ///      it, 1 miss, 2 ship hit, 3 mine, 4 shield break) into one 7 bit
    ///      value: 4 bit local position plus a 3 bit code, wide enough for
    ///      the shield break code added on top of the original 2 bit range.
    function _pickBarrageSlot(
        uint8 anchorRow,
        uint8 anchorCol,
        uint8 slotIndex,
        ebool isActive,
        euint256 avoidSoFar,
        PlayerSlot storage defender
    ) internal returns (BarrageSlotResult memory r) {
        euint256 localPos;
        euint256 candidateMask;
        ebool found;
        (r.newAvoid, localPos, candidateMask, found) = _findDistinctBarrageCell(anchorRow, anchorCol, avoidSoFar);

        ebool trulyActive = isActive.and(found);
        // Same shield check as a normal shot, against this slot's candidate
        // cell instead of a caller-supplied cell index. Whether a shield is
        // active at all is a plain bool, so the encrypted equality check
        // only needs to run when one is actually up.
        ebool shieldBreak = defender.shieldActive ? trulyActive.and(candidateMask.eq(defender.shieldCellMask)) : e.asEbool(false);
        euint256 code = _barrageResultCode(trulyActive, shieldBreak, candidateMask, defender.mineMask, defender.boardMask);

        r.packedSlot = localPos.or(code.shl(uint256(4))).shl(uint256(slotIndex) * 7);
        // A broken shield does no damage, exactly like it never happened,
        // so its contribution to the aggregate struck mask is zeroed here
        // even though the slot itself was truly active.
        ebool countsAsStruck = trulyActive.and(shieldBreak.not());
        r.struckContribution = countsAsStruck.select(candidateMask, e.asEuint256(uint256(0)));
    }

    /// @dev Runs the bounded-attempt retry to find one cell in the 4x4 area
    ///      distinct from every cell in avoidSoFar, split out to keep
    ///      _pickBarrageSlot's stack frame small.
    function _findDistinctBarrageCell(uint8 anchorRow, uint8 anchorCol, euint256 avoidSoFar)
        internal
        returns (euint256 newAvoid, euint256 localPos, euint256 candidateMask, ebool found)
    {
        localPos = e.asEuint256(uint256(0));
        candidateMask = e.asEuint256(uint256(0));
        found = e.asEbool(false);

        for (uint8 attempt = 0; attempt < BARRAGE_ATTEMPTS_PER_CELL; attempt++) {
            euint256 idx = e.randBounded(uint256(BARRAGE_AREA_SIZE) * uint256(BARRAGE_AREA_SIZE));
            euint256 candidateBit = e.asEuint256(uint256(1)).shl(_localToGlobalCell(idx, anchorRow, anchorCol));

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

    function _localToGlobalCell(euint256 localIdx, uint8 anchorRow, uint8 anchorCol) internal returns (euint256) {
        euint256 localRow = localIdx.div(uint256(BARRAGE_AREA_SIZE));
        euint256 localCol = localIdx.rem(uint256(BARRAGE_AREA_SIZE));
        return localRow.add(uint256(anchorRow)).mul(uint256(BOARD_SIZE)).add(localCol.add(uint256(anchorCol)));
    }

    /// @dev Decodes the six packed slots, marks every active slot's cell as
    ///      shot, and emits per-cell results. Returns whether any struck
    ///      cell was a mine, pulled into its own function to keep
    ///      confirmBarrage's stack frame small.
    function _applyBarrageResults(uint256 matchId, PlayerSlot storage defender, uint256 packed, Match storage m)
        internal
        returns (bool anyMineTriggered)
    {
        for (uint8 k = 0; k < BARRAGE_MAX_CELLS; k++) {
            uint256 slotValue = (packed >> (uint256(k) * 7)) & 0x7F;
            uint256 code = slotValue >> 4;
            if (code == 0) continue;

            uint256 localPos = slotValue & 0xF;
            uint8 globalCell = uint8(
                (localPos / BARRAGE_AREA_SIZE + m.pendingBarrageAnchorRow) * BOARD_SIZE
                    + (localPos % BARRAGE_AREA_SIZE + m.pendingBarrageAnchorCol)
            );
            // Every resolved cell is logged into shotsAgainstMe, exactly as
            // before the shield rework, with one exception: a shield break
            // (code 4) is not logged, so that cell can be struck again once
            // the shield is gone. Hits, plain misses and mines are all
            // logged the same way, so a triggered mine stays
            // indistinguishable from a plain miss in the public log.
            if (code == 4) {
                defender.shieldActive = false;
                emit ShieldBroken(matchId, defender.addr, globalCell);
            } else {
                defender.shotsAgainstMe |= (uint256(1) << globalCell);
            }
            if (code == 3) {
                anyMineTriggered = true;
            }
            // A mine cell always reads as a miss, a ship hit or a shield
            // break are the only codes that report anything else.
            emit BarrageResolved(matchId, globalCell, code == 2, code == 3, code == 4);
        }
    }

    /// @notice Confirms a pending barrage: marks every struck cell as shot,
    ///         applies the single non-stacking mine bonus if any struck
    ///         cell was a mine, and resolves the win or turn pass. Barrage
    ///         is the player's whole action for the turn, so it always
    ///         ends the turn afterward, exactly like sonar, except a
    ///         pending bonus action grants one more action here too.
    /// @dev If a barrage happens to cover both of the defender's mines in
    ///      one action, both attest as code 3, but the bonus flag below is
    ///      only ever set to true, never incremented, so the owner still
    ///      gets exactly one extra action, not two.
    function confirmBarrage(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        Match storage m = matches[matchId];
        require(m.pendingAction == PendingAction.Barrage, "no pending barrage");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(packedAttestation, packedSignatures),
            "invalid barrage attestation"
        );
        require(
            inco.incoVerifier().isValidDecryptionAttestation(allDestroyedAttestation, allDestroyedSignatures),
            "invalid win attestation"
        );
        require(euint256.unwrap(m.pendingBarragePacked) == packedAttestation.handle, "barrage handle mismatch");
        require(ebool.unwrap(m.pendingBarrageAllDestroyed) == allDestroyedAttestation.handle, "win handle mismatch");

        uint8 actorIdx = m.pendingActor;
        address actor = m.players[actorIdx].addr;
        PlayerSlot storage defender = m.players[1 - actorIdx];
        bool won = asBool(allDestroyedAttestation.value);
        bool anyMineTriggered = _applyBarrageResults(matchId, defender, uint256(packedAttestation.value), m);

        m.pendingAction = PendingAction.None;
        if (anyMineTriggered) {
            m.players[1 - actorIdx].bonusShotAvailable = true;
        }

        if (won) {
            m.phase = Phase.Finished;
            m.winner = actor;
            emit MatchWon(matchId, actor);
        } else {
            if (m.players[actorIdx].bonusShotAvailable) {
                m.players[actorIdx].bonusShotAvailable = false;
            } else {
                m.turn = 1 - actorIdx;
            }
            m.lastMoveTimestamp = block.timestamp;
        }
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

    function getCaptain(uint256 matchId, uint8 playerIdx) external view returns (uint8) {
        return matches[matchId].players[playerIdx].captain;
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

    function hasSonarCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].sonarUsed;
    }

    function hasBarrageCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].barrageUsed;
    }

    function hasShieldCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].shieldUsed;
    }

    function getShieldCellHandle(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].shieldCellMask;
    }

    function isShieldActive(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].shieldActive;
    }
}
