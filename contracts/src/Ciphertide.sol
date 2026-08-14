// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";
import {PlayerSlot} from "./CiphertideTypes.sol";
import {CiphertideMechanics} from "./CiphertideMechanics.sol";

/// @notice Ciphertide: an onchain hidden-fleet naval duel on Base Sepolia,
///         built on Inco Lightning. Encrypted fleet placement, a two phase
///         shoot and confirm loop, mines, the shared Sonar and Barrage
///         skills, Captain 1's Shield, Captain 2's Bombardment, and
///         Captain 3's Rake.
/// @dev Shot resolution, turn order and win detection are built and tested
///      against a board state set through a test-only hook so this piece is
///      not blocked on the placement design decision.
contract Ciphertide {
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
    /// area only has 16 cells and at most 5 are already excluded. A 4x4
    /// area has 16 cells, addressed by exactly 4 bits, see
    /// CiphertideMechanics.resolveAreaStrikes for the packed encoding this
    /// feeds.
    uint8 public constant BARRAGE_AREA_SIZE = 4;
    uint8 public constant BARRAGE_MIN_CELLS = 4;
    uint8 public constant BARRAGE_MAX_CELLS = 6;
    uint8 public constant BARRAGE_ATTEMPTS_PER_CELL = 8;
    uint8 public constant BARRAGE_LOCAL_POS_BITS = 4;

    /// Bombardment: Captain 2's unique skill, one 10x10 area, a fixed 15 of
    /// its 100 cells are struck. Unlike Barrage's randomized 4 to 6, the
    /// count never varies, so it shares the same bounded-attempt drawing
    /// and packing machinery with minCells simply equal to maxCells. A
    /// 10x10 area has 100 cells, needing 7 bits (up to 127) to address a
    /// local position, one bit wider than Barrage's 4 bits.
    uint8 public constant BOMBARDMENT_AREA_SIZE = 10;
    uint8 public constant BOMBARDMENT_STRIKE_COUNT = 15;
    uint8 public constant BOMBARDMENT_ATTEMPTS_PER_CELL = 8;
    uint8 public constant BOMBARDMENT_LOCAL_POS_BITS = 7;

    /// Rake: Captain 3's unique skill, one whole row (BOARD_SIZE cells wide,
    /// a single cell tall), a fixed 3 of its 15 cells are struck. Shares
    /// the same bounded-attempt drawing and packing machinery as Barrage
    /// and Bombardment, with minCells equal to maxCells like Bombardment,
    /// just over a 15x1 area instead of a square. A row has 15 cells,
    /// needing 4 bits (up to 15) to address a local position, same width
    /// as Barrage's.
    uint8 public constant RAKE_ROW_LENGTH = 15;
    uint8 public constant RAKE_STRIKE_COUNT = 3;
    uint8 public constant RAKE_ATTEMPTS_PER_CELL = 8;
    uint8 public constant RAKE_LOCAL_POS_BITS = 4;

    /// Salvo: Captain 4's unique skill, 3 caller chosen specific cells,
    /// struck at once. Unlike Barrage, Bombardment and Rake, the cells are
    /// a direct public choice rather than a random draw within an area, so
    /// Salvo draws no randomness and needs no fee, the same reason Sonar is
    /// free. Costs the user their next turn instead: see PlayerSlot.skipNextTurn.
    uint8 public constant SALVO_CELL_COUNT = 3;

    /// Captain identity, declared per player when entering a match. Every
    /// captain carries the two shared skills, Sonar and Barrage, plus one
    /// unique skill. This contract only records which captain a player
    /// declared, it does not store currency, unlock state, or any other
    /// profile or progression data, and it does not check whether a
    /// captain is unlocked. That is handled entirely off chain in the
    /// frontend profile. Any player may declare any captain.
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

    /// At most one action (a normal shot, sonar, barrage, bombardment, or
    /// rake) can be in flight at a time, awaiting its confirmation before
    /// the next action is allowed.
    enum PendingAction {
        None,
        Shot,
        Sonar,
        Barrage,
        Bombardment,
        Rake,
        Salvo
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
        // Shared by barrage, bombardment, rake and salvo (never more than
        // one at once, gated by pendingAction), the per-slot bit width and
        // encoding differs between the area skills and salvo, see
        // CiphertideMechanics.resolveAreaStrikes and resolveChosenStrikes.
        euint256 pendingAreaPacked;
        ebool pendingAreaAllDestroyed;
        uint8 pendingAreaAnchorRow; // barrage, bombardment, rake only
        uint8 pendingAreaAnchorCol; // barrage, bombardment, rake only
        uint8[3] pendingSalvoCells; // salvo only
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
    event BombardmentFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 anchorRow,
        uint8 anchorCol,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event BombardmentResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    event RakeFired(
        uint256 indexed matchId, address indexed player, uint8 row, bytes32 packedHandle, bytes32 allDestroyedHandle
    );
    event RakeResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    event SalvoFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 cell0,
        uint8 cell1,
        uint8 cell2,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event SalvoResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
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
        _requireFee(totalDraws);

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
            (euint256 shipMask, ebool placedThisShip) =
                CiphertideMechanics.placeOneShip(SHIP_LENGTHS[i], occupied, PLACEMENT_ATTEMPTS_PER_SHIP);
            // shipMask is still the trivial zero handle whenever no attempt
            // succeeded, so folding it into occupied is always safe.
            occupied = occupied.or(shipMask);
            shipMasks[i] = shipMask;
            allPlaced = allPlaced.and(placedThisShip);
        }

        // Mines are placed after the fleet, avoiding every ship cell, so
        // they land on water only. They must never be allowed to the
        // opponent, only to this contract and the owner.
        (euint256 mineMask, ebool allMinesPlaced) =
            CiphertideMechanics.placeMines(occupied, MINES_PER_PLAYER, MINE_PLACEMENT_ATTEMPTS);
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

    /// @dev Shared covalidator attestation check used by every confirm*
    ///      function: verifies the attestation's signatures against the
    ///      given invalid-attestation message, requires its handle to match
    ///      the given pending handle against the given mismatch message,
    ///      then returns the attested value for the caller to decode
    ///      (asBool for an ebool pending value, or a plain uint256 cast for
    ///      a euint256 one). Factored out purely to shrink the contract's
    ///      deployed bytecode: with a low optimizer run count a helper
    ///      called from many sites is emitted once instead of inlined at
    ///      every call site. Every revert message a caller passes in is
    ///      exactly the message that call site used before this helper
    ///      existed.
    function _verifyAttestation(
        bytes32 pendingHandle,
        DecryptionAttestation memory attestation,
        bytes[] memory signatures,
        string memory invalidMessage,
        string memory mismatchMessage
    ) internal view returns (bytes32 value) {
        require(inco.incoVerifier().isValidDecryptionAttestation(attestation, signatures), invalidMessage);
        require(pendingHandle == attestation.handle, mismatchMessage);
        value = attestation.value;
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
        bytes32 attestedValue = _verifyAttestation(
            ebool.unwrap(p.pendingAllPlaced),
            allPlacedAttestation,
            allPlacedSignatures,
            "invalid placement attestation",
            "placement handle mismatch"
        );

        p.placementPending = false;
        bool allPlaced = asBool(attestedValue);

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
        _requireFee(2);

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
        uint256 rollA = uint256(
            _verifyAttestation(
                euint256.unwrap(m.rollA), rollAAttestation, rollASignatures, "invalid rollA attestation", "rollA handle mismatch"
            )
        );
        uint256 rollB = uint256(
            _verifyAttestation(
                euint256.unwrap(m.rollB), rollBAttestation, rollBSignatures, "invalid rollB attestation", "rollB handle mismatch"
            )
        );
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

    /// @dev Shared fee check for every action that spends random draws
    ///      (placement, dice, shield, barrage, bombardment, rake): draws is
    ///      the number of randBounded/rand calls the action is about to
    ///      make, each costing inco.getFee(). Sonar and Salvo make no
    ///      random draws and so never call this.
    function _requireFee(uint256 draws) internal view {
        require(msg.value >= inco.getFee() * draws, "fee not paid");
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

    /// @dev Resolves the turn to hand it to candidateIdx, consuming that
    ///      player's pending Salvo forfeit if one is set: candidateIdx's
    ///      turn is skipped exactly once and the turn stays with the other
    ///      player instead. The flag is cleared the moment it is consumed
    ///      here, so it can never skip more than the one turn it was set
    ///      for, and every call site that hands the turn over routes
    ///      through this, so the forfeit composes with the mine bonus (which
    ///      never calls this, it keeps the turn on the current actor
    ///      instead) without any risk of a deadlock.
    function _advanceTurn(Match storage m, uint8 candidateIdx) internal returns (uint8) {
        if (m.players[candidateIdx].skipNextTurn) {
            m.players[candidateIdx].skipNextTurn = false;
            return 1 - candidateIdx;
        }
        return candidateIdx;
    }

    /// @dev Gates a unique captain skill to the player who declared that
    ///      captain, for example _requireCaptainOwnsSkill(m, playerIdx,
    ///      CAPTAIN_SHIELD) inside placeShield, or CAPTAIN_BOMBARDMENT
    ///      inside useBombardment.
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

        _requireFee(1);
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
        bool hit = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingHit), hitAttestation, hitSignatures, "invalid hit attestation", "hit handle mismatch"
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingAllDestroyed),
                allDestroyedAttestation,
                allDestroyedSignatures,
                "invalid win attestation",
                "win handle mismatch"
            )
        );
        bool mineHit = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingMineHit),
                mineHitAttestation,
                mineHitSignatures,
                "invalid mine attestation",
                "mine handle mismatch"
            )
        );
        bool shieldBreak = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingShieldBreak),
                shieldBreakAttestation,
                shieldBreakSignatures,
                "invalid shield break attestation",
                "shield break handle mismatch"
            )
        );

        _resolveShotOutcome(matchId, m, hit, won, mineHit, shieldBreak);
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
                    m.turn = _advanceTurn(m, 1 - shooterIdx);
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
        uint256 areaMask = CiphertideMechanics.rectMask(anchorRow, anchorCol, SONAR_AREA_SIZE, SONAR_AREA_SIZE);

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
        bool anyShip = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingSonarResult), attestation, signatures, "invalid sonar attestation", "sonar handle mismatch"
            )
        );

        m.pendingAction = PendingAction.None;
        uint8 actor = m.pendingActor;

        // Sonar is the player's whole action for the turn: it always ends
        // the turn afterward, except a pending bonus action from an
        // earlier mine trigger grants one more action here too, exactly
        // like a shot's miss would.
        if (m.players[actor].bonusShotAvailable) {
            m.players[actor].bonusShotAvailable = false;
        } else {
            m.turn = _advanceTurn(m, 1 - actor);
        }
        m.lastMoveTimestamp = block.timestamp;

        emit SonarResolved(matchId, anyShip, m.players[m.turn].addr);
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
    ///      ship placement, entirely on encrypted values, via the shared
    ///      CiphertideMechanics.resolveAreaStrikes (also used by
    ///      Bombardment below). The only reveals are one packed value (six
    ///      7 bit slots: 4 bit local position plus a 3 bit result code, 0
    ///      inactive, 1 miss, 2 hit, 3 mine, 4 shield break), the newly
    ///      sunk ship mask, and the win bit.
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
        _requireFee(totalDraws);

        PlayerSlot storage defender = m.players[1 - m.turn];
        (euint256 packed,, ebool allDestroyed) = _fireAreaStrike(
            m,
            defender,
            CiphertideMechanics.AreaGeometry({
                anchorRow: anchorRow,
                anchorCol: anchorCol,
                width: BARRAGE_AREA_SIZE,
                height: BARRAGE_AREA_SIZE
            }),
            CiphertideMechanics.StrikeConfig({
                minCells: BARRAGE_MIN_CELLS,
                maxCells: BARRAGE_MAX_CELLS,
                attemptsPerCell: BARRAGE_ATTEMPTS_PER_CELL,
                positionBits: BARRAGE_LOCAL_POS_BITS
            })
        );

        m.pendingAction = PendingAction.Barrage;

        emit BarrageFired(
            matchId, msg.sender, anchorRow, anchorCol, euint256.unwrap(packed), ebool.unwrap(allDestroyed)
        );
    }

    /// @notice Captain Bombardment's unique skill: strikes a fixed 15 of
    ///         the 100 cells in a caller chosen 10x10 area, revealing hit
    ///         or miss for each struck cell. Resolves exactly like Barrage
    ///         in every other respect: ship hits burn cells and can sink
    ///         ships, a struck mine still applies its penalty, and a
    ///         struck cell that is the defender's shielded cell resolves
    ///         as a shield break instead (no damage, the cell survives,
    ///         the shield is consumed). Single use per match, and the
    ///         player's whole action for the turn.
    /// @dev Shares CiphertideMechanics.resolveAreaStrikes with Barrage,
    ///      just over a larger area and a fixed strike count (minCells ==
    ///      maxCells == BOMBARDMENT_STRIKE_COUNT) instead of a randomized
    ///      range, so every one of the 15 slots is always active. The
    ///      packed reveal uses BOMBARDMENT_LOCAL_POS_BITS (7) bits per
    ///      local position instead of Barrage's 4, ten bits per slot, see
    ///      resolveAreaStrikes for the full encoding.
    function useBombardment(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        _requireCaptainOwnsSkill(m, m.turn, CAPTAIN_BOMBARDMENT);
        require(
            uint256(anchorRow) + BOMBARDMENT_AREA_SIZE <= BOARD_SIZE
                && uint256(anchorCol) + BOMBARDMENT_AREA_SIZE <= BOARD_SIZE,
            "bombardment area does not fit on the board"
        );

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.bombardmentUsed, "bombardment already used");
        attacker.bombardmentUsed = true;

        uint256 totalDraws = uint256(1) + uint256(BOMBARDMENT_STRIKE_COUNT) * BOMBARDMENT_ATTEMPTS_PER_CELL;
        _requireFee(totalDraws);

        PlayerSlot storage defender = m.players[1 - m.turn];
        (euint256 packed,, ebool allDestroyed) = _fireAreaStrike(
            m,
            defender,
            CiphertideMechanics.AreaGeometry({
                anchorRow: anchorRow,
                anchorCol: anchorCol,
                width: BOMBARDMENT_AREA_SIZE,
                height: BOMBARDMENT_AREA_SIZE
            }),
            CiphertideMechanics.StrikeConfig({
                minCells: BOMBARDMENT_STRIKE_COUNT,
                maxCells: BOMBARDMENT_STRIKE_COUNT,
                attemptsPerCell: BOMBARDMENT_ATTEMPTS_PER_CELL,
                positionBits: BOMBARDMENT_LOCAL_POS_BITS
            })
        );

        m.pendingAction = PendingAction.Bombardment;

        emit BombardmentFired(
            matchId, msg.sender, anchorRow, anchorCol, euint256.unwrap(packed), ebool.unwrap(allDestroyed)
        );
    }

    /// @notice Captain Rake's unique skill: strikes a fixed 3 of the 15
    ///         cells in a caller chosen row, revealing hit or miss for each
    ///         struck cell. Resolves exactly like Barrage and Bombardment
    ///         in every other respect: ship hits burn cells and can sink
    ///         ships, a struck mine still applies its penalty, and a struck
    ///         cell that is the defender's shielded cell resolves as a
    ///         shield break instead (no damage, the cell survives, the
    ///         shield is consumed). Single use per match, and the player's
    ///         whole action for the turn.
    /// @dev Shares CiphertideMechanics.resolveAreaStrikes with Barrage and
    ///      Bombardment, over a RAKE_ROW_LENGTH x 1 area (the whole chosen
    ///      row) with a fixed strike count (minCells == maxCells ==
    ///      RAKE_STRIKE_COUNT), so all 3 slots are always active.
    ///      RAKE_LOCAL_POS_BITS (4) bits per local position, 7 bits per
    ///      slot, see resolveAreaStrikes for the full encoding.
    function useRake(uint256 matchId, uint8 row) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        _requireCaptainOwnsSkill(m, m.turn, CAPTAIN_RAKE);
        require(row < BOARD_SIZE, "invalid row");

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.rakeUsed, "rake already used");
        attacker.rakeUsed = true;

        uint256 totalDraws = uint256(1) + uint256(RAKE_STRIKE_COUNT) * RAKE_ATTEMPTS_PER_CELL;
        _requireFee(totalDraws);

        PlayerSlot storage defender = m.players[1 - m.turn];
        (euint256 packed,, ebool allDestroyed) = _fireAreaStrike(
            m,
            defender,
            CiphertideMechanics.AreaGeometry({anchorRow: row, anchorCol: 0, width: RAKE_ROW_LENGTH, height: 1}),
            CiphertideMechanics.StrikeConfig({
                minCells: RAKE_STRIKE_COUNT,
                maxCells: RAKE_STRIKE_COUNT,
                attemptsPerCell: RAKE_ATTEMPTS_PER_CELL,
                positionBits: RAKE_LOCAL_POS_BITS
            })
        );

        m.pendingAction = PendingAction.Rake;

        emit RakeFired(matchId, msg.sender, row, euint256.unwrap(packed), ebool.unwrap(allDestroyed));
    }

    /// @dev Shared reveal-and-stash tail for every multi-cell strike skill
    ///      (Barrage, Bombardment, Rake, Salvo): allows and reveals the
    ///      resolved packed value and win bit, records the newly destroyed
    ///      mask, and stashes the pending actor and packed/win fields
    ///      shared across all of them. Each caller still sets its own
    ///      area- or salvo-specific pending fields, m.pendingAction and
    ///      emits its own Fired event afterward, since those differ per
    ///      skill.
    function _finalizeAreaPending(
        Match storage m,
        PlayerSlot storage defender,
        euint256 packed,
        euint256 newlyDestroyed,
        ebool allDestroyed
    ) internal {
        packed.allowThis();
        allDestroyed.allowThis();
        newlyDestroyed.allowThis();
        e.reveal(packed);
        e.reveal(allDestroyed);
        e.reveal(newlyDestroyed);
        defender.lastDestroyedMask = newlyDestroyed;

        m.pendingActor = m.turn;
        m.pendingAreaPacked = packed;
        m.pendingAreaAllDestroyed = allDestroyed;
    }

    /// @dev Shared firing step for every area-strike skill (Barrage,
    ///      Bombardment, Rake): calls CiphertideMechanics.resolveAreaStrikes,
    ///      then _finalizeAreaPending, and stashes the aimed area's anchor.
    ///      Each caller still sets its own m.pendingAction and emits its
    ///      own Fired event afterward, since those differ per skill.
    function _fireAreaStrike(
        Match storage m,
        PlayerSlot storage defender,
        CiphertideMechanics.AreaGeometry memory area,
        CiphertideMechanics.StrikeConfig memory config
    ) internal returns (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) {
        (packed, newlyDestroyed, allDestroyed) = CiphertideMechanics.resolveAreaStrikes(area, defender, config);
        _finalizeAreaPending(m, defender, packed, newlyDestroyed, allDestroyed);
        m.pendingAreaAnchorRow = area.anchorRow;
        m.pendingAreaAnchorCol = area.anchorCol;
    }

    /// @dev Decodes an area strike's packed slots (shared by Barrage,
    ///      Bombardment and Rake, actionKind picks which Resolved event to
    ///      emit), marks every active slot's cell as shot except a shield
    ///      break, and emits per-cell results. Returns whether any struck
    ///      cell was a mine, pulled into its own function to keep
    ///      confirmBarrage, confirmBombardment and confirmRake's own stack
    ///      frames small.
    function _applyAreaResults(
        uint256 matchId,
        PlayerSlot storage defender,
        uint256 packed,
        uint8 anchorRow,
        uint8 anchorCol,
        uint8 width,
        uint8 maxCells,
        uint8 positionBits,
        PendingAction actionKind
    ) internal returns (bool anyMineTriggered) {
        uint256 slotBits = uint256(positionBits) + 3;
        uint256 slotMask = (uint256(1) << slotBits) - 1;
        uint256 posMask = (uint256(1) << positionBits) - 1;
        for (uint8 k = 0; k < maxCells; k++) {
            uint256 slotValue = (packed >> (uint256(k) * slotBits)) & slotMask;
            uint256 code = slotValue >> positionBits;
            if (code == 0) continue;

            uint256 localPos = slotValue & posMask;
            uint8 globalCell = uint8((localPos / width + anchorRow) * BOARD_SIZE + (localPos % width + anchorCol));
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
            if (actionKind == PendingAction.Bombardment) {
                emit BombardmentResolved(matchId, globalCell, code == 2, code == 3, code == 4);
            } else if (actionKind == PendingAction.Rake) {
                emit RakeResolved(matchId, globalCell, code == 2, code == 3, code == 4);
            } else {
                emit BarrageResolved(matchId, globalCell, code == 2, code == 3, code == 4);
            }
        }
    }

    /// @dev Shared confirm-step tail for a skill that is the player's whole
    ///      action for the turn (Barrage, Bombardment, and Sonar follows
    ///      the same pending-bonus shape inline): applies the single
    ///      non-stacking mine bonus if any struck cell was a mine, resolves
    ///      a win, or passes the turn, with a pending bonus action from an
    ///      earlier mine trigger consumed here instead when one is due.
    function _finishAreaAction(uint256 matchId, Match storage m, uint8 actorIdx, bool won, bool anyMineTriggered)
        internal
    {
        m.pendingAction = PendingAction.None;
        if (anyMineTriggered) {
            m.players[1 - actorIdx].bonusShotAvailable = true;
        }

        if (won) {
            m.phase = Phase.Finished;
            m.winner = m.players[actorIdx].addr;
            emit MatchWon(matchId, m.players[actorIdx].addr);
        } else {
            if (m.players[actorIdx].bonusShotAvailable) {
                m.players[actorIdx].bonusShotAvailable = false;
            } else {
                m.turn = _advanceTurn(m, 1 - actorIdx);
            }
            m.lastMoveTimestamp = block.timestamp;
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
    /// @dev Shared confirm-step body for Barrage, Bombardment and Rake:
    ///      verifies both attestations (the win handle check reuses the
    ///      same "invalid win attestation" / "win handle mismatch" messages
    ///      every one of them already used, only the packed value's
    ///      messages and area shape differ per skill), decodes and applies
    ///      the results through _applyAreaResults, and finishes through
    ///      _finishAreaAction. Salvo is close to this shape but not quite
    ///      it (it decodes through _applySalvoResults instead, and sets its
    ///      own skipNextTurn flag before finishing), so it keeps its own
    ///      confirmSalvo body rather than being folded in here.
    function _confirmAreaStrike(
        uint256 matchId,
        PendingAction expectedAction,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures,
        string memory noPendingMessage,
        string memory invalidPackedMessage,
        string memory packedMismatchMessage,
        uint8 width,
        uint8 maxCells,
        uint8 positionBits
    ) internal {
        Match storage m = matches[matchId];
        require(m.pendingAction == expectedAction, noPendingMessage);
        uint256 packedValue = uint256(
            _verifyAttestation(
                euint256.unwrap(m.pendingAreaPacked),
                packedAttestation,
                packedSignatures,
                invalidPackedMessage,
                packedMismatchMessage
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingAreaAllDestroyed),
                allDestroyedAttestation,
                allDestroyedSignatures,
                "invalid win attestation",
                "win handle mismatch"
            )
        );

        uint8 actorIdx = m.pendingActor;
        PlayerSlot storage defender = m.players[1 - actorIdx];
        bool anyMineTriggered = _applyAreaResults(
            matchId,
            defender,
            packedValue,
            m.pendingAreaAnchorRow,
            m.pendingAreaAnchorCol,
            width,
            maxCells,
            positionBits,
            expectedAction
        );

        _finishAreaAction(matchId, m, actorIdx, won, anyMineTriggered);
    }

    function confirmBarrage(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        _confirmAreaStrike(
            matchId,
            PendingAction.Barrage,
            packedAttestation,
            packedSignatures,
            allDestroyedAttestation,
            allDestroyedSignatures,
            "no pending barrage",
            "invalid barrage attestation",
            "barrage handle mismatch",
            BARRAGE_AREA_SIZE,
            BARRAGE_MAX_CELLS,
            BARRAGE_LOCAL_POS_BITS
        );
    }

    /// @notice Confirms a pending bombardment: marks every struck cell as
    ///         shot, applies the single non-stacking mine bonus if any
    ///         struck cell was a mine, resolves a shield break if the
    ///         defender's shielded cell was struck, and resolves the win
    ///         or turn pass. Bombardment is the player's whole action for
    ///         the turn, exactly like Barrage.
    /// @dev If a bombardment happens to cover both of the defender's mines
    ///      in one action, both attest as code 3, but the bonus flag below
    ///      is only ever set to true, never incremented, so the owner still
    ///      gets exactly one extra action, not two, matching Barrage.
    function confirmBombardment(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        _confirmAreaStrike(
            matchId,
            PendingAction.Bombardment,
            packedAttestation,
            packedSignatures,
            allDestroyedAttestation,
            allDestroyedSignatures,
            "no pending bombardment",
            "invalid bombardment attestation",
            "bombardment handle mismatch",
            BOMBARDMENT_AREA_SIZE,
            BOMBARDMENT_STRIKE_COUNT,
            BOMBARDMENT_LOCAL_POS_BITS
        );
    }

    /// @notice Confirms a pending rake: marks every struck cell as shot,
    ///         applies the single non-stacking mine bonus if any struck
    ///         cell was a mine, resolves a shield break if the defender's
    ///         shielded cell was struck, and resolves the win or turn pass.
    ///         Rake is the player's whole action for the turn, exactly like
    ///         Barrage and Bombardment.
    /// @dev If a rake happens to cover both of the defender's mines in one
    ///      action, both attest as code 3, but the bonus flag below is only
    ///      ever set to true, never incremented, so the owner still gets
    ///      exactly one extra action, not two, matching Barrage and
    ///      Bombardment.
    function confirmRake(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        _confirmAreaStrike(
            matchId,
            PendingAction.Rake,
            packedAttestation,
            packedSignatures,
            allDestroyedAttestation,
            allDestroyedSignatures,
            "no pending rake",
            "invalid rake attestation",
            "rake handle mismatch",
            RAKE_ROW_LENGTH,
            RAKE_STRIKE_COUNT,
            RAKE_LOCAL_POS_BITS
        );
    }

    /// @notice Captain Salvo's unique skill: strikes 3 caller chosen cells
    ///         on the opponent's board at once, revealing hit or miss for
    ///         each. Resolves like the other multi-cell skills in every
    ///         other respect: ship hits burn cells and can sink ships, a
    ///         struck mine still applies its penalty, and a struck cell
    ///         that is the defender's shielded cell resolves as a shield
    ///         break instead (no damage, the cell survives, the shield is
    ///         consumed). Single use per match, the player's whole action
    ///         for the turn, and its cost: the next time it would become
    ///         this player's turn, that turn is skipped once and passes
    ///         straight back to the opponent.
    /// @dev The 3 cells are a direct public choice, not a random draw, so
    ///      this needs no random draws and no fee, the same reason Sonar is
    ///      free. Cell validity (in range, the 3 distinct, none already
    ///      shot) is checked with plain requires up front rather than
    ///      obliviously, since these are plaintext inputs from the start,
    ///      unlike Shield's own encrypted cell pick.
    function useSalvo(uint256 matchId, uint8 cell0, uint8 cell1, uint8 cell2) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        _requireCaptainOwnsSkill(m, m.turn, CAPTAIN_SALVO);
        require(cell0 < BOARD_CELLS && cell1 < BOARD_CELLS && cell2 < BOARD_CELLS, "cell out of range");
        require(cell0 != cell1 && cell0 != cell2 && cell1 != cell2, "salvo cells must be distinct");

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.salvoUsed, "salvo already used");
        attacker.salvoUsed = true;

        PlayerSlot storage defender = m.players[1 - m.turn];
        require((defender.shotsAgainstMe >> cell0) & 1 == 0, "cell already shot");
        require((defender.shotsAgainstMe >> cell1) & 1 == 0, "cell already shot");
        require((defender.shotsAgainstMe >> cell2) & 1 == 0, "cell already shot");

        uint256[3] memory shotBits = [uint256(1) << cell0, uint256(1) << cell1, uint256(1) << cell2];
        (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) =
            CiphertideMechanics.resolveChosenStrikes(shotBits, defender);
        _finalizeAreaPending(m, defender, packed, newlyDestroyed, allDestroyed);
        m.pendingSalvoCells = [cell0, cell1, cell2];

        m.pendingAction = PendingAction.Salvo;

        emit SalvoFired(matchId, msg.sender, cell0, cell1, cell2, euint256.unwrap(packed), ebool.unwrap(allDestroyed));
    }

    /// @dev Decodes salvo's packed slots (3 bits per cell, no local
    ///      position needed, the caller already chose and stored the 3
    ///      cells in m.pendingSalvoCells), marks every struck cell as shot
    ///      except a shield break, and emits per-cell results. Returns
    ///      whether any struck cell was a mine, the same shape as
    ///      _applyAreaResults, kept separate since salvo's packing has no
    ///      position bits or anchor to decode against.
    function _applySalvoResults(uint256 matchId, PlayerSlot storage defender, uint256 packed, uint8[3] memory cells)
        internal
        returns (bool anyMineTriggered)
    {
        for (uint8 k = 0; k < SALVO_CELL_COUNT; k++) {
            uint256 code = (packed >> (uint256(k) * 3)) & 0x7;
            uint8 cell = cells[k];
            if (code == 4) {
                defender.shieldActive = false;
                emit ShieldBroken(matchId, defender.addr, cell);
            } else {
                defender.shotsAgainstMe |= (uint256(1) << cell);
            }
            if (code == 3) {
                anyMineTriggered = true;
            }
            emit SalvoResolved(matchId, cell, code == 2, code == 3, code == 4);
        }
    }

    /// @notice Confirms a pending salvo: marks each of the 3 struck cells
    ///         as shot, applies the single non-stacking mine bonus if any
    ///         struck cell was a mine, resolves a shield break if the
    ///         defender's shielded cell was among them, resolves the win or
    ///         turn pass, and, if the match continues, sets the caller's
    ///         skipNextTurn flag so their next turn is forfeited once.
    /// @dev The skip flag is set here rather than in useSalvo so it never
    ///      gets set on a salvo that wins the match outright, and shares
    ///      _finishAreaAction with Barrage, Bombardment and Rake for the
    ///      mine bonus, win and turn-pass logic, which itself now routes
    ///      through _advanceTurn so the forfeit takes effect the next time
    ///      the turn would land back on the salvo user.
    function confirmSalvo(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        Match storage m = matches[matchId];
        require(m.pendingAction == PendingAction.Salvo, "no pending salvo");
        uint256 packedValue = uint256(
            _verifyAttestation(
                euint256.unwrap(m.pendingAreaPacked),
                packedAttestation,
                packedSignatures,
                "invalid salvo attestation",
                "salvo handle mismatch"
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.pendingAreaAllDestroyed),
                allDestroyedAttestation,
                allDestroyedSignatures,
                "invalid win attestation",
                "win handle mismatch"
            )
        );

        uint8 actorIdx = m.pendingActor;
        PlayerSlot storage defender = m.players[1 - actorIdx];
        bool anyMineTriggered = _applySalvoResults(matchId, defender, packedValue, m.pendingSalvoCells);

        if (!won) {
            m.players[actorIdx].skipNextTurn = true;
        }
        _finishAreaAction(matchId, m, actorIdx, won, anyMineTriggered);
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

    function hasBombardmentCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].bombardmentUsed;
    }

    function hasRakeCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].rakeUsed;
    }

    function hasShieldCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].shieldUsed;
    }

    function hasSalvoCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].salvoUsed;
    }

    function getShieldCellHandle(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].shieldCellMask;
    }

    function isShieldActive(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].shieldActive;
    }
}
