// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";
import {PlayerSlot, AreaSkillState} from "./CiphertideTypes.sol";
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
    /// wins. Every confidential randBounded draw costs roughly one second
    /// of real Inco reveal wait once an action lands, so this is set to the
    /// smallest value an empirical sweep found keeps a full placement
    /// almost always succeeding: 0 failures in 150 independent rounds
    /// (CiphertideMechanics.placeOneShip called directly, bypassing the
    /// match state machine, see PlacementTest for the shipped regression
    /// check). The board is only about 10% full even at the last, biggest
    /// ship, so 20 was far more headroom than the real collision rate
    /// needs. Tunable up if the failure rate ever needs to shrink further,
    /// down if gas is too high.
    uint8 public constant PLACEMENT_ATTEMPTS_PER_SHIP = 10;

    /// Two mines per player, placed on water cells only. Fewer attempts
    /// than ship placement since a mine only has to avoid the ship cells
    /// (about 10% of the board) and at most one other mine, a much lower
    /// collision rate than packing a whole fleet. Same empirical approach
    /// as PLACEMENT_ATTEMPTS_PER_SHIP: 0 failures in 200 independent
    /// rounds at this value.
    uint8 public constant MINES_PER_PLAYER = 2;
    uint8 public constant MINE_PLACEMENT_ATTEMPTS = 5;

    /// Sonar: one 5x5 area, whole board query, single use per match.
    uint8 public constant SONAR_AREA_SIZE = 5;

    /// Barrage: one 4x4 area, a random 4 to 6 of its 16 cells are struck.
    /// Which cells get struck is public information the instant a barrage
    /// resolves, so the cells are chosen with plain public randomness (see
    /// _publicStrikeSeed and CiphertideMechanics.pickAreaCells), not a
    /// confidential draw: only the per-cell hit or miss result stays
    /// confidential until reveal. A 4x4 area has 16 cells.
    uint8 public constant BARRAGE_AREA_SIZE = 4;
    uint8 public constant BARRAGE_MIN_CELLS = 4;
    uint8 public constant BARRAGE_MAX_CELLS = 6;

    /// Bombardment: Captain 2's unique skill, one 10x10 area, a fixed 15 of
    /// its 100 cells are struck. Same public cell choice as Barrage, just a
    /// fixed count instead of a randomized 4 to 6.
    uint8 public constant BOMBARDMENT_AREA_SIZE = 10;
    uint8 public constant BOMBARDMENT_STRIKE_COUNT = 15;

    /// Resolving all 15 struck cells in one transaction was projected at
    /// roughly 24 million gas, well past Base's protocol level per-
    /// transaction gas cap (EIP-7825, 2^24 = 16,777,216 gas), so
    /// useBombardment is split into ceil(BOMBARDMENT_STRIKE_COUNT /
    /// BOMBARDMENT_STEP_SIZE) calls, today 3 (5 cells each), mirroring
    /// placeMyBoardStep's own stepped design. See useBombardment's own
    /// comment for the exact call sequence.
    /// @dev Sized conservatively from this project's own REAL measured gas
    /// rather than the Foundry mock's own numbers for this same code
    /// (AreaSkillSteps.t.sol logs those, comfortably under this bound with
    /// room to spare, but the mock is known to run far cheaper than
    /// production, the same gap already documented for Barrage's
    /// eth_estimateGas result in CiphertideClient's own EXPLICIT_GAS_LIMITS
    /// comment: an early live Barrage call estimated at 1.91 million gas
    /// and then reverted out of gas, its real measured cost from a
    /// transaction that actually succeeded was 11.85 million, for 4 to 6
    /// cells plus a full ship-damage pass). 5 cells per step, damage
    /// applied only on the final step, keeps every step at or under that
    /// same proven-safe real shape rather than trusting the mock's
    /// optimistic numbers for a real per-transaction cap this strict.
    uint8 public constant BOMBARDMENT_STEP_SIZE = 5;

    /// Rake: Captain 3's unique skill, one whole row (BOARD_SIZE cells wide,
    /// a single cell tall), a fixed 3 of its 15 cells are struck. Same
    /// public cell choice as Barrage and Bombardment, just over a 15x1 area
    /// instead of a square.
    uint8 public constant RAKE_ROW_LENGTH = 15;
    uint8 public constant RAKE_STRIKE_COUNT = 3;

    /// Salvo: Captain 4's unique skill, 3 caller chosen specific cells,
    /// struck at once. Unlike Barrage, Bombardment and Rake, the cells are
    /// a direct public choice rather than a random draw within an area, so
    /// Salvo draws no randomness and needs no fee, the same reason Sonar is
    /// free. Costs the user their next turn instead: see PlayerSlot.skipNextTurn.
    uint8 public constant SALVO_CELL_COUNT = 3;

    /// Carpet: Captain 5's unique skill, a caller chosen 3x3 area. Unlike
    /// every other skill, whether it strikes at all is conditional: all 9
    /// cells are struck only if at least one of the opponent's ship cells
    /// lies inside the 3x3, otherwise nothing is struck and nothing is
    /// logged, a silent whiff. The area is a public choice and the trigger
    /// check is a single free comparison, no random draws, so like Sonar
    /// and Salvo, Carpet needs no fee.
    uint8 public constant CARPET_AREA_SIZE = 3;
    uint8 public constant CARPET_CELL_COUNT = 9;

    /// Resolving all 9 struck cells in one transaction was projected at
    /// roughly 18.45 million gas, also past Base's protocol level
    /// per-transaction gas cap, so useCarpet is split the same way
    /// useBombardment is, into ceil(CARPET_CELL_COUNT / CARPET_STEP_SIZE)
    /// calls, today 3 (3 cells each). See useCarpet's own comment for the
    /// exact call sequence.
    /// @dev Sized conservatively at 3 cells per step (matching
    /// BOMBARDMENT_STEP_SIZE's own comment on why the mock's numbers alone
    /// are not trusted for this), and specifically matched to Salvo's own
    /// real, currently-working shape: Salvo already strikes exactly 3
    /// cells plus a full ship-damage pass in one single transaction on
    /// live Base Sepolia today, through the same shared per-cell
    /// resolution and damage-application code Carpet's own stepped chunks
    /// now go through, so a Carpet chunk of the same size and shape is
    /// grounded in a real, already-proven-safe transaction, not a
    /// projection.
    uint8 public constant CARPET_STEP_SIZE = 3;

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
        Salvo,
        Carpet
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
        // Shared by barrage, bombardment, rake and carpet (never more than
        // one at once, gated by pendingAction): the packed result, win
        // bit, aimed anchor, and (Bombardment and Carpet only) the
        // stepped-firing progress. See CiphertideTypes.AreaSkillState's own
        // comment for why this is its own free-standing struct rather than
        // loose fields here.
        AreaSkillState areaSkill;
        uint8[3] pendingSalvoCells; // salvo only
        // The cells a public random strike picked (barrage, bombardment,
        // rake only), in the same order their packed result codes are
        // bit-packed, set at fire time and read back at confirm time. Sized
        // to Bombardment's fixed 15, the largest of the three; Barrage uses
        // its first 4 to 6 slots and Rake its first 3, per
        // pendingAreaCellCount.
        uint8[15] pendingAreaCells;
        uint8 pendingAreaCellCount;
        // Mixed into the public seed a barrage, bombardment or rake draws
        // its struck cells from (see _publicStrikeSeed), incremented every
        // time, so the same block cannot produce the same seed twice for
        // this match.
        uint32 randNonce;
    }

    mapping(uint256 => Match) internal matches;
    uint256 public nextMatchId = 1;

    event MatchCreated(uint256 indexed matchId, address indexed creator);
    event MatchJoined(uint256 indexed matchId, address indexed opponent);
    event PlacementStepSubmitted(uint256 indexed matchId, address indexed player, uint8 shipsDone, uint8 totalShips);
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
        bytes32 shieldBreakHandle,
        bytes32 mineHitHandle
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
        uint8[] cells,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event BarrageResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    event BombardmentFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 anchorRow,
        uint8 anchorCol,
        uint8[] cells,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event BombardmentResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    // Emitted after every intermediate useBombardment call (every call
    // except the final one, which emits BombardmentFired instead once the
    // reveal is requested), mirroring PlacementStepSubmitted.
    event BombardmentStepSubmitted(uint256 indexed matchId, address indexed player, uint8 cellsDone, uint8 totalCells);
    event RakeFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 row,
        uint8[] cells,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
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
    event CarpetFired(
        uint256 indexed matchId,
        address indexed player,
        uint8 anchorRow,
        uint8 anchorCol,
        bytes32 packedHandle,
        bytes32 allDestroyedHandle
    );
    event CarpetResolved(uint256 indexed matchId, uint8 cell, bool hit, bool mine, bool shieldBreak);
    // Emitted after every intermediate useCarpet call, mirroring
    // BombardmentStepSubmitted.
    event CarpetStepSubmitted(uint256 indexed matchId, address indexed player, uint8 cellsDone, uint8 totalCells);
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

    /// @notice Randomly and confidentially places one more piece of this
    ///         caller's fleet: either the next ship, or, once every ship's
    ///         step has run, the two mines followed by the single allPlaced
    ///         reveal. Call this NUM_SHIPS + 1 times in a row (6 ship steps,
    ///         then one mine and reveal step) to place a full board.
    /// @dev Split into one ship per call, plus mines and the reveal folded
    ///      into a single final call, so no single transaction ever needs
    ///      to run more than PLACEMENT_ATTEMPTS_PER_SHIP (or the mine
    ///      equivalent) random draws: a hosted RPC's own per-transaction
    ///      gas cap is well under what a full ~140 draw placement needs in
    ///      one call, even though the chain's own block gas limit is not
    ///      the constraint. Ships are placed longest first, each with
    ///      PLACEMENT_ATTEMPTS_PER_SHIP independent random candidate slots;
    ///      the first non-overlapping candidate wins via the select
    ///      multiplexer pattern. Every draw, decoded position, candidate
    ///      mask and overlap check stays on encrypted values end to end.
    ///      The only value ever revealed, at the final step, is a single
    ///      allPlaced success bit, confirmed in confirmPlacement exactly as
    ///      before. On the rare case not every ship or mine found a free
    ///      slot within its attempts, allPlaced reveals false once
    ///      confirmed and placementShipsDone resets to 0, so the caller can
    ///      call this again from the first ship for a fresh, independent
    ///      set of draws.
    function placeMyBoardStep(uint256 matchId) external payable onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.phase == Phase.Placing, "not in placement phase");
        uint8 playerIdx = msg.sender == m.players[0].addr ? 0 : 1;
        PlayerSlot storage p = m.players[playerIdx];
        require(!p.placed, "already placed");
        require(!p.placementPending, "placement already submitted, awaiting confirmation");

        if (p.placementShipsDone < NUM_SHIPS) {
            _requireFee(PLACEMENT_ATTEMPTS_PER_SHIP);
        } else {
            _requireFee(uint256(MINES_PER_PLAYER) * MINE_PLACEMENT_ATTEMPTS);
        }

        _runPlacementStep(matchId, playerIdx, e.asEuint256(uint256(0)));
    }

    /// @dev Runs one placement step, starting a fresh round from
    ///      freshStartOccupied whenever placementShipsDone is 0. Split out
    ///      from placeMyBoardStep so a test harness can start a round from
    ///      a deliberately full board to exercise the all-attempts-fail
    ///      retry path deterministically, without any change to the real
    ///      placement logic itself.
    function _runPlacementStep(uint256 matchId, uint8 playerIdx, euint256 freshStartOccupied) internal {
        Match storage m = matches[matchId];
        PlayerSlot storage p = m.players[playerIdx];

        if (p.placementShipsDone == 0) {
            freshStartOccupied.allowThis();
            p.boardMask = freshStartOccupied;
            ebool trueBit = e.asEbool(true);
            trueBit.allowThis();
            p.placementAllPlacedSoFar = trueBit;
        }

        if (p.placementShipsDone < NUM_SHIPS) {
            uint8 shipIdx = p.placementShipsDone;
            (euint256 shipMask, ebool placedThisShip) =
                CiphertideMechanics.placeOneShip(SHIP_LENGTHS[shipIdx], p.boardMask, PLACEMENT_ATTEMPTS_PER_SHIP);

            // shipMask is still the trivial zero handle whenever no attempt
            // succeeded, so folding it into the occupied mask is always safe.
            euint256 newOccupied = p.boardMask.or(shipMask);
            newOccupied.allowThis();
            newOccupied.allow(msg.sender);
            p.boardMask = newOccupied;

            shipMask.allowThis();
            shipMask.allow(msg.sender);
            p.shipMask[shipIdx] = shipMask;

            euint256 zeroHits = e.asEuint256(uint256(0));
            zeroHits.allowThis();
            p.shipHits[shipIdx] = zeroHits;

            ebool stillAllPlaced = p.placementAllPlacedSoFar.and(placedThisShip);
            stillAllPlaced.allowThis();
            p.placementAllPlacedSoFar = stillAllPlaced;

            p.placementShipsDone = shipIdx + 1;

            emit PlacementStepSubmitted(matchId, msg.sender, p.placementShipsDone, NUM_SHIPS);
            return;
        }

        // Every ship step is done: mines are placed last, avoiding every
        // ship cell, so they land on water only. They must never be
        // allowed to the opponent, only to this contract and the owner.
        (euint256 mineMask, ebool allMinesPlaced) =
            CiphertideMechanics.placeMines(p.boardMask, MINES_PER_PLAYER, MINE_PLACEMENT_ATTEMPTS);
        ebool allPlaced = p.placementAllPlacedSoFar.and(allMinesPlaced);

        mineMask.allowThis();
        mineMask.allow(msg.sender);
        allPlaced.allowThis();
        e.reveal(allPlaced);

        p.mineMask = mineMask;

        euint256 zeroDestroyed = e.asEuint256(uint256(0));
        zeroDestroyed.allowThis();
        p.lastDestroyedMask = zeroDestroyed;

        euint256 zeroShieldCell = e.asEuint256(uint256(0));
        zeroShieldCell.allowThis();
        p.shieldCellMask = zeroShieldCell;
        // shieldActive is a plain bool, its zero value already defaults to
        // false, no encrypted trivial-zero handle is needed for it.

        // Reset for whichever round comes next, a retry after a false
        // allPlaced or, once this one confirms true, never read again.
        p.placementShipsDone = 0;
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
            // Not every ship or mine found a free slot within its attempts.
            // placementShipsDone is already back to 0 (reset at the end of
            // _runPlacementStep's final step), so the player's next
            // placeMyBoardStep call starts a fresh round from the first
            // ship again with a fresh, independent set of random draws.
            emit PlacementRetryNeeded(matchId, p.addr);
        }
    }

    /// @dev Test-only hook to seed a player's board directly, bypassing the
    ///      real random placement, so shot resolution, turn order and win
    ///      detection can be built and tested independently of the
    ///      placement design decision. Not part of the intended production
    ///      surface, callers besides tests should use placeMyBoardStep.
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

    /// @dev Shared fee check for every action that spends confidential
    ///      random draws (placement, dice, shield): draws is the number of
    ///      randBounded/rand calls the action is about to make, each
    ///      costing inco.getFee(). Sonar, Salvo, Carpet, Barrage,
    ///      Bombardment and Rake make no confidential random draws (the
    ///      last three pick their struck cells with plain public
    ///      randomness instead, see _publicStrikeSeed) and so never call
    ///      this.
    function _requireFee(uint256 draws) internal view {
        require(msg.value >= inco.getFee() * draws, "fee not paid");
    }

    /// @dev Derives the public seed a barrage, bombardment or rake draws its
    ///      struck cells from. Which cells get struck becomes public the
    ///      instant the strike resolves anyway, so this only needs to be
    ///      unpredictable to the caller at the moment they send the
    ///      transaction, not confidential afterward: block.prevrandao is
    ///      not known until the block is built and the caller cannot choose
    ///      it, matchId and msg.sender spread the seed across matches and
    ///      players, and the per-match nonce stops the same seed repeating
    ///      if the same player fires another such skill in the same match
    ///      later. Good enough for a game skill's random cell choice on
    ///      testnet; a commit-reveal seed would be worth adding later to
    ///      harden this against a sequencer's influence over
    ///      block.prevrandao.
    function _publicStrikeSeed(Match storage m, uint256 matchId) internal returns (uint256) {
        return uint256(keccak256(abi.encode(block.prevrandao, matchId, msg.sender, m.randNonce++)));
    }

    /// @dev Copies a freshly picked cell list into the match's pending area
    ///      cell storage, shared by barrage, bombardment and rake.
    function _storePendingAreaCells(Match storage m, uint8[] memory cells) internal {
        m.pendingAreaCellCount = uint8(cells.length);
        for (uint8 k = 0; k < cells.length; k++) {
            m.pendingAreaCells[k] = cells[k];
        }
    }

    /// @dev Shared preamble for any player action's OPENING step (shoot,
    ///      sonar, barrage, and the first call of a stepped skill like
    ///      Bombardment or Carpet): requires no other action is currently
    ///      pending, then defers phase, turn and clock bookkeeping to
    ///      _chargeElapsedTurnTime, shared with a stepped skill's
    ///      continuation steps below.
    function _beginAction(Match storage m) internal {
        require(m.pendingAction == PendingAction.None, "previous action not yet confirmed");
        _chargeElapsedTurnTime(m);
    }

    /// @dev The turn-ownership, phase and clock bookkeeping every action
    ///      needs, split out of _beginAction so a stepped skill's
    ///      continuation steps (Bombardment, Carpet) can reuse it without
    ///      also re-requiring pendingAction == None, which is never true
    ///      mid-sequence: the opening step already set pendingAction to
    ///      that skill, precisely to gate any OTHER action from starting
    ///      while this one is still in flight. Checks the match is in
    ///      progress and it really is the caller's turn (m.turn never
    ///      moves until a stepped skill's final step resolves, so this
    ///      alone is what keeps the opponent from acting mid-sequence),
    ///      charges the elapsed wall-clock time since the last step against
    ///      that player's remaining budget, and resets the clock so the
    ///      next step's own elapsed window starts fresh, exactly like a
    ///      single-transaction action's clock would behave.
    function _chargeElapsedTurnTime(Match storage m) internal {
        require(m.phase == Phase.InProgress, "match not in progress");
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
            ebool.unwrap(shield.shieldBreak),
            ebool.unwrap(mineHit)
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
    /// @dev The struck count and cells are picked with plain public
    ///      randomness (CiphertideMechanics.pickAreaCells), not a
    ///      confidential draw: which cells get struck is public information
    ///      the instant a barrage resolves anyway, so drawing them
    ///      confidentially bought no privacy, only reveal latency. Only the
    ///      per-cell hit or miss result (CiphertideMechanics.
    ///      resolveChosenAreaStrikes) stays confidential until reveal: one
    ///      packed value, 3 bits per struck cell (0 inactive, 1 miss, 2
    ///      hit, 3 mine, 4 shield break), the newly sunk ship mask, and the
    ///      win bit.
    function useBarrage(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external onlyPlayer(matchId) {
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

        PlayerSlot storage defender = m.players[1 - m.turn];
        uint8[] memory cells = CiphertideMechanics.pickAreaCells(
            _publicStrikeSeed(m, matchId),
            CiphertideMechanics.AreaGeometry({
                anchorRow: anchorRow,
                anchorCol: anchorCol,
                width: BARRAGE_AREA_SIZE,
                height: BARRAGE_AREA_SIZE
            }),
            BARRAGE_MIN_CELLS,
            BARRAGE_MAX_CELLS,
            defender.shotsAgainstMe
        );

        (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) =
            CiphertideMechanics.resolveChosenAreaStrikes(cells, defender);
        _finalizeAreaPending(m, defender, packed, newlyDestroyed, allDestroyed);
        m.areaSkill.anchorRow = anchorRow;
        m.areaSkill.anchorCol = anchorCol;
        _storePendingAreaCells(m, cells);

        m.pendingAction = PendingAction.Barrage;

        emit BarrageFired(
            matchId, msg.sender, anchorRow, anchorCol, cells, euint256.unwrap(packed), ebool.unwrap(allDestroyed)
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
    /// @dev Resolving all 15 cells in one transaction can exceed Base's
    ///      protocol level per-transaction gas cap (see
    ///      BOMBARDMENT_STEP_SIZE's own comment), so this call is stepped:
    ///      call it repeatedly with the SAME matchId, anchorRow and
    ///      anchorCol until it stops emitting BombardmentStepSubmitted and
    ///      emits BombardmentFired instead, exactly like placeMyBoardStep
    ///      is called NUM_SHIPS + 1 times in a row.
    ///
    ///      The opening call (pendingAction is not already Bombardment for
    ///      this match) does everything a single-transaction call used to
    ///      do up front except resolve cells: validates turn, captain,
    ///      area and single use, and picks and stores all 15 cells at once
    ///      (a cheap, plain public choice, unaffected by stepping, see
    ///      CiphertideMechanics.pickAreaCells). Every call after that must
    ///      reuse that exact anchor, checked against the stored one, so a
    ///      step sequence cannot be redirected partway through, and must
    ///      come from the same caller (enforced by _chargeElapsedTurnTime's
    ///      own turn check, since m.turn never moves until the final step).
    ///      A call once the skill has already fired and is awaiting
    ///      confirmBombardment reverts rather than being treated as a new
    ///      opening call, since pendingAction stays Bombardment through
    ///      that window too (areaSkill.stepsDone alone cannot tell the two
    ///      apart, both read 0, hence the explicit check below).
    ///
    ///      Every call, opening or continuation, charges elapsed clock
    ///      time exactly like a single-transaction action would: the
    ///      acting player's clock keeps running for however long each step
    ///      actually takes them to submit, and the opponent cannot act at
    ///      all while a bombardment is mid-sequence, since the turn itself
    ///      has not moved yet.
    function useBombardment(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        PlayerSlot storage defender = m.players[1 - m.turn];

        if (m.pendingAction == PendingAction.Bombardment) {
            _continueSteppedArea(
                m,
                anchorRow,
                anchorCol,
                "skill already fired, awaiting confirmation",
                "anchor must match the in-progress skill"
            );
        } else {
            _beginSteppedAreaSkill(
                m,
                BOMBARDMENT_AREA_SIZE,
                CAPTAIN_BOMBARDMENT,
                "bombardment area does not fit on the board",
                "bombardment already used",
                anchorRow,
                anchorCol,
                PendingAction.Bombardment
            );

            uint8[] memory cells = CiphertideMechanics.pickAreaCells(
                _publicStrikeSeed(m, matchId),
                CiphertideMechanics.AreaGeometry({
                    anchorRow: anchorRow,
                    anchorCol: anchorCol,
                    width: BOMBARDMENT_AREA_SIZE,
                    height: BOMBARDMENT_AREA_SIZE
                }),
                BOMBARDMENT_STRIKE_COUNT,
                BOMBARDMENT_STRIKE_COUNT,
                defender.shotsAgainstMe
            );
            _storePendingAreaCells(m, cells);
        }

        (bool finished, uint8 done, ebool allDestroyed) = CiphertideMechanics.stepBombardment(
            m.areaSkill, m.pendingAreaCells, BOMBARDMENT_STEP_SIZE, BOMBARDMENT_STRIKE_COUNT, defender
        );

        if (!finished) {
            emit BombardmentStepSubmitted(matchId, msg.sender, done, BOMBARDMENT_STRIKE_COUNT);
            return;
        }

        m.pendingActor = m.turn;
        emit BombardmentFired(
            matchId,
            msg.sender,
            anchorRow,
            anchorCol,
            CiphertideMechanics.copyCells(m.pendingAreaCells, BOMBARDMENT_STRIKE_COUNT),
            euint256.unwrap(m.areaSkill.packed),
            ebool.unwrap(allDestroyed)
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
    /// @dev Same public cell choice and resolution path as Barrage and
    ///      Bombardment, over a RAKE_ROW_LENGTH x 1 area (the whole chosen
    ///      row) with a fixed count (minCells == maxCells ==
    ///      RAKE_STRIKE_COUNT), so all 3 slots are always active.
    function useRake(uint256 matchId, uint8 row) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        _beginAction(m);
        _requireCaptainOwnsSkill(m, m.turn, CAPTAIN_RAKE);
        require(row < BOARD_SIZE, "invalid row");

        PlayerSlot storage attacker = m.players[m.turn];
        require(!attacker.rakeUsed, "rake already used");
        attacker.rakeUsed = true;

        PlayerSlot storage defender = m.players[1 - m.turn];
        uint8[] memory cells = CiphertideMechanics.pickAreaCells(
            _publicStrikeSeed(m, matchId),
            CiphertideMechanics.AreaGeometry({anchorRow: row, anchorCol: 0, width: RAKE_ROW_LENGTH, height: 1}),
            RAKE_STRIKE_COUNT,
            RAKE_STRIKE_COUNT,
            defender.shotsAgainstMe
        );

        (euint256 packed, euint256 newlyDestroyed, ebool allDestroyed) =
            CiphertideMechanics.resolveChosenAreaStrikes(cells, defender);
        _finalizeAreaPending(m, defender, packed, newlyDestroyed, allDestroyed);
        m.areaSkill.anchorRow = row;
        m.areaSkill.anchorCol = 0;
        _storePendingAreaCells(m, cells);

        m.pendingAction = PendingAction.Rake;

        emit RakeFired(matchId, msg.sender, row, cells, euint256.unwrap(packed), ebool.unwrap(allDestroyed));
    }

    /// @dev Shared continuation preamble for a stepped area skill's second
    ///      and later calls (Bombardment, Carpet), factored out of both
    ///      useBombardment and useCarpet purely to keep this identical
    ///      shape's bytecode from being duplicated in each: a call once the
    ///      skill has already fired and is awaiting its confirm reverts
    ///      (pendingAction stays set through that window too, so
    ///      areaSkill.stepsDone, back at 0 by then, is what tells "just
    ///      finished firing" apart from "never started"), a mismatched
    ///      anchor reverts so a step sequence cannot be redirected
    ///      partway through, and otherwise this charges elapsed clock time
    ///      exactly like a fresh action's opening step would.
    function _continueSteppedArea(
        Match storage m,
        uint8 anchorRow,
        uint8 anchorCol,
        string memory alreadyFiredMessage,
        string memory anchorMismatchMessage
    ) internal {
        require(m.areaSkill.stepsDone > 0, alreadyFiredMessage);
        require(
            anchorRow == m.areaSkill.anchorRow && anchorCol == m.areaSkill.anchorCol, anchorMismatchMessage
        );
        _chargeElapsedTurnTime(m);
    }

    /// @dev Shared opening-step preamble for a stepped area skill's first
    ///      call (Bombardment, Carpet), factored out purely to keep this
    ///      identical shape's bytecode from being duplicated across both:
    ///      requires no other action is pending, turn ownership and phase
    ///      (via _beginAction), that the caller's captain owns this skill,
    ///      that the chosen area fits the board, and that this skill has
    ///      not already been used this match (the single-use gate a
    ///      single-transaction skill sets inline; action alone says which
    ///      of PlayerSlot's two stepped-skill used flags to check and set,
    ///      a plain bool cannot be passed by storage reference), then seeds
    ///      the shared pending-area bookkeeping every stepped skill needs:
    ///      the anchor, a fresh zeroed packed and struck accumulator, and
    ///      which skill is now in flight. The caller still does its own
    ///      skill-specific opening work afterward (Bombardment picks and
    ///      stores its cell list, Carpet computes and stores its
    ///      ship-present gate).
    function _beginSteppedAreaSkill(
        Match storage m,
        uint8 areaSize,
        uint8 requiredCaptainId,
        string memory areaFitMessage,
        string memory alreadyUsedMessage,
        uint8 anchorRow,
        uint8 anchorCol,
        PendingAction action
    ) internal {
        _beginAction(m);
        _requireCaptainOwnsSkill(m, m.turn, requiredCaptainId);
        require(
            uint256(anchorRow) + areaSize <= BOARD_SIZE && uint256(anchorCol) + areaSize <= BOARD_SIZE, areaFitMessage
        );

        PlayerSlot storage attacker = m.players[m.turn];
        bool alreadyUsed = action == PendingAction.Bombardment ? attacker.bombardmentUsed : attacker.carpetUsed;
        require(!alreadyUsed, alreadyUsedMessage);
        if (action == PendingAction.Bombardment) {
            attacker.bombardmentUsed = true;
        } else {
            attacker.carpetUsed = true;
        }

        m.areaSkill.anchorRow = anchorRow;
        m.areaSkill.anchorCol = anchorCol;
        m.areaSkill.packed = e.asEuint256(uint256(0));
        m.areaSkill.struckSoFar = e.asEuint256(uint256(0));
        m.pendingAction = action;
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
        m.areaSkill.packed = packed;
        m.areaSkill.allDestroyed = allDestroyed;
    }

    /// @dev Decodes an area strike's packed slots (shared by Barrage,
    ///      Bombardment and Rake, actionKind picks which Resolved event to
    ///      emit): one 3 bit result code per cell in m.pendingAreaCells, no
    ///      local position to decode since those cells were already public
    ///      the moment the strike fired and are read straight from storage.
    ///      Marks every active slot's cell as shot except a shield break,
    ///      and emits per-cell results. Returns whether any struck cell was
    ///      a mine, pulled into its own function to keep confirmBarrage,
    ///      confirmBombardment and confirmRake's own stack frames small.
    function _applyAreaResults(uint256 matchId, Match storage m, PlayerSlot storage defender, uint256 packed, PendingAction actionKind)
        internal
        returns (bool anyMineTriggered)
    {
        uint8 count = m.pendingAreaCellCount;
        for (uint8 k = 0; k < count; k++) {
            uint256 code = (packed >> (uint256(k) * 3)) & 0x7;
            uint8 globalCell = m.pendingAreaCells[k];
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
        string memory packedMismatchMessage
    ) internal {
        Match storage m = matches[matchId];
        require(m.pendingAction == expectedAction, noPendingMessage);
        uint256 packedValue = uint256(
            _verifyAttestation(
                euint256.unwrap(m.areaSkill.packed),
                packedAttestation,
                packedSignatures,
                invalidPackedMessage,
                packedMismatchMessage
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.areaSkill.allDestroyed),
                allDestroyedAttestation,
                allDestroyedSignatures,
                "invalid win attestation",
                "win handle mismatch"
            )
        );

        uint8 actorIdx = m.pendingActor;
        PlayerSlot storage defender = m.players[1 - actorIdx];
        bool anyMineTriggered = _applyAreaResults(matchId, m, defender, packedValue, expectedAction);

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
            "barrage handle mismatch"
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
            "bombardment handle mismatch"
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
            "rake handle mismatch"
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
                euint256.unwrap(m.areaSkill.packed),
                packedAttestation,
                packedSignatures,
                "invalid salvo attestation",
                "salvo handle mismatch"
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.areaSkill.allDestroyed),
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

    /// @notice Captain Carpet's unique skill: aims a 3x3 area, striking all
    ///         9 cells at once only if at least one of the opponent's ship
    ///         cells lies inside it, ship cells outside the 3x3 are
    ///         untouched. If no ship cell is inside, nothing is struck,
    ///         nothing is logged, a silent whiff. Otherwise resolves like
    ///         the other multi-cell skills: ship hits burn cells and can
    ///         sink ships, a struck mine still applies its penalty, and a
    ///         struck cell that is the defender's shielded cell resolves as
    ///         a shield break instead (no damage, the cell survives, the
    ///         shield is consumed). Single use per match, and the player's
    ///         whole action for the turn regardless of whether it triggers.
    /// @dev The 3x3 is a public choice and its trigger check is a single
    ///      free comparison, no random draws, so like Sonar and Salvo this
    ///      needs no fee.
    ///
    ///      Resolving all 9 cells in one transaction can exceed Base's
    ///      protocol level per-transaction gas cap (see CARPET_STEP_SIZE's
    ///      own comment), so this call is stepped exactly like
    ///      useBombardment: call it repeatedly with the SAME matchId,
    ///      anchorRow and anchorCol until it stops emitting
    ///      CarpetStepSubmitted and emits CarpetFired instead.
    ///
    ///      The opening call (pendingAction is not already Carpet for this
    ///      match) validates turn, captain, area and single use, and
    ///      computes the "any ship cell inside the 3x3" gate once (see
    ///      CiphertideMechanics.beginCarpetShipPresent), storing it so
    ///      every later chunk gates its slots identically. Every call
    ///      after that must reuse the exact same anchor, checked against
    ///      the stored one, and a call once the skill has already fired
    ///      and is awaiting confirmCarpet reverts rather than being
    ///      treated as a new opening call, the same distinction
    ///      useBombardment's own comment explains. Every call, opening or
    ///      continuation, charges elapsed clock time exactly like a
    ///      single-transaction action would, and the opponent cannot act
    ///      at all while a carpet is mid-sequence, since m.turn has not
    ///      moved yet.
    function useCarpet(uint256 matchId, uint8 anchorRow, uint8 anchorCol) external onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        PlayerSlot storage defender = m.players[1 - m.turn];
        CiphertideMechanics.AreaGeometry memory area = CiphertideMechanics.AreaGeometry({
            anchorRow: anchorRow,
            anchorCol: anchorCol,
            width: CARPET_AREA_SIZE,
            height: CARPET_AREA_SIZE
        });

        if (m.pendingAction == PendingAction.Carpet) {
            _continueSteppedArea(
                m, anchorRow, anchorCol, "skill already fired, awaiting confirmation", "anchor must match the in-progress skill"
            );
        } else {
            _beginSteppedAreaSkill(
                m,
                CARPET_AREA_SIZE,
                CAPTAIN_CARPET,
                "carpet area does not fit on the board",
                "carpet already used",
                anchorRow,
                anchorCol,
                PendingAction.Carpet
            );

            ebool shipPresent = CiphertideMechanics.beginCarpetShipPresent(area, defender);
            shipPresent.allowThis();
            m.areaSkill.carpetShipPresent = shipPresent;
        }

        (bool finished, uint8 done, ebool allDestroyed) =
            CiphertideMechanics.stepCarpet(m.areaSkill, area, CARPET_STEP_SIZE, CARPET_CELL_COUNT, defender);

        if (!finished) {
            emit CarpetStepSubmitted(matchId, msg.sender, done, CARPET_CELL_COUNT);
            return;
        }

        m.pendingActor = m.turn;
        emit CarpetFired(matchId, msg.sender, anchorRow, anchorCol, euint256.unwrap(m.areaSkill.packed), ebool.unwrap(allDestroyed));
    }

    /// @dev Decodes carpet's packed slots (3 bits per cell, 9 fixed cells
    ///      in anchor row-major order, no local position bits needed, the
    ///      same reasoning as _applySalvoResults: the caller already knows
    ///      every cell a firing carpet struck, from the anchor alone),
    ///      marks every active slot's cell as shot except a shield break,
    ///      and emits per-cell results. Returns whether any struck cell was
    ///      a mine. On a whiff every slot's code is 0, so this loop never
    ///      marks or emits anything, exactly the silent-whiff behavior.
    function _applyCarpetResults(
        uint256 matchId,
        PlayerSlot storage defender,
        uint256 packed,
        uint8 anchorRow,
        uint8 anchorCol
    ) internal returns (bool anyMineTriggered) {
        for (uint8 k = 0; k < CARPET_CELL_COUNT; k++) {
            uint256 code = (packed >> (uint256(k) * 3)) & 0x7;
            if (code == 0) continue;

            uint8 globalCell =
                uint8((uint256(k) / CARPET_AREA_SIZE + anchorRow) * BOARD_SIZE + (uint256(k) % CARPET_AREA_SIZE + anchorCol));
            if (code == 4) {
                defender.shieldActive = false;
                emit ShieldBroken(matchId, defender.addr, globalCell);
            } else {
                defender.shotsAgainstMe |= (uint256(1) << globalCell);
            }
            if (code == 3) {
                anyMineTriggered = true;
            }
            emit CarpetResolved(matchId, globalCell, code == 2, code == 3, code == 4);
        }
    }

    /// @notice Confirms a pending carpet: marks every struck cell as shot
    ///         (none at all, on a whiff), applies the single non-stacking
    ///         mine bonus if any struck cell was a mine, resolves a shield
    ///         break if the defender's shielded cell was among them, and
    ///         resolves the win or turn pass. Carpet is the player's whole
    ///         action for the turn, whether or not it triggered.
    function confirmCarpet(
        uint256 matchId,
        DecryptionAttestation memory packedAttestation,
        bytes[] memory packedSignatures,
        DecryptionAttestation memory allDestroyedAttestation,
        bytes[] memory allDestroyedSignatures
    ) external {
        Match storage m = matches[matchId];
        require(m.pendingAction == PendingAction.Carpet, "no pending carpet");
        uint256 packedValue = uint256(
            _verifyAttestation(
                euint256.unwrap(m.areaSkill.packed),
                packedAttestation,
                packedSignatures,
                "invalid carpet attestation",
                "carpet handle mismatch"
            )
        );
        bool won = asBool(
            _verifyAttestation(
                ebool.unwrap(m.areaSkill.allDestroyed),
                allDestroyedAttestation,
                allDestroyedSignatures,
                "invalid win attestation",
                "win handle mismatch"
            )
        );

        uint8 actorIdx = m.pendingActor;
        PlayerSlot storage defender = m.players[1 - actorIdx];
        bool anyMineTriggered =
            _applyCarpetResults(matchId, defender, packedValue, m.areaSkill.anchorRow, m.areaSkill.anchorCol);

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

    function hasCarpetCharge(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return !matches[matchId].players[playerIdx].carpetUsed;
    }

    function getShieldCellHandle(uint256 matchId, uint8 playerIdx) external view returns (euint256) {
        return matches[matchId].players[playerIdx].shieldCellMask;
    }

    function isShieldActive(uint256 matchId, uint8 playerIdx) external view returns (bool) {
        return matches[matchId].players[playerIdx].shieldActive;
    }
}
