// Signer-agnostic game client for Ciphertide: drives the deployed contract
// through a full match using the same real Inco Lightning flow the
// headless e2e/run.ts script already proved against the live Base Sepolia
// deployment (create and join, stepped placement and its confirm, shots
// and every skill with their confirms, tight reveal polling, and
// decrypting a player's own board). Ported rather than imported, since
// e2e/ and frontend/ are two separate npm projects with no workspace
// linking today; keep this in step with e2e/run.ts by hand if the
// contract's flow ever changes, the same way run.ts itself documents its
// own assumptions.
//
// "Background confirms": every action here (shoot, a skill, placement)
// reveals one or more handles, and a separate confirm call submits the
// covalidator attestation for them. Confirms are not sender-gated (the
// contract only checks the attestation matches the pending handle, not
// who calls confirm), so this client does not wait for a second explicit
// call from the caller, it tight-polls for the reveal and submits the
// confirm itself as soon as it is ready. From the caller's side this is
// one awaited method per move; the optional onProgress callback reports
// the 'sending' -> 'mined' -> 'revealing' -> 'confirming' -> 'confirmed'
// stages so a UI can show progress without splitting the call in two.
//
// Signer-agnostic: this class takes a viem WalletClient (any account
// source: a private key for now, an injected browser wallet or a
// sponsored relayer later) and a PublicClient, and never assumes how the
// account was created. See frontend/src/dev/harness.tsx for the only
// place a raw private key is used, gated to a dev-only route and read
// from a gitignored .env, never hardcoded.
import {
  type Abi,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  type Transport,
  type WalletClient,
  decodeEventLog,
} from 'viem'
import { baseSepolia } from 'viem/chains'
import { handleTypes } from '@inco/lightning-js'
import type { Lightning } from '@inco/lightning-js/lite'
import ciphertideAbiJson from './abi/Ciphertide.json'
import { tightPollReveal, sleep } from './reveal'
import type {
  AreaSkillOutcome,
  CellOutcome,
  DecryptedBoard,
  MatchId,
  PlayerIdx,
  ProgressCallback,
  ShotOutcome,
  SonarOutcome,
} from './types'

export const ciphertideAbi = ciphertideAbiJson as Abi

const ZERO32 = ('0x' + '0'.repeat(64)) as Hex
const nonZero = (h: Hex) => h !== ZERO32

// eth_estimateGas badly underestimates the heavy skill calls: a live
// Barrage call once got estimated at only about 1.91 million gas and then
// reverted out of gas, when its real cost, measured from a transaction
// that actually succeeded, is about 11.85 million. Passing an explicit
// gas limit skips estimation entirely for these. Ported from e2e/run.ts,
// see that file's own longer comment on this same map for the full
// reasoning and the RPC per-transaction cap (around 15-20 million on
// Alchemy) these values were sized under.
//
// Barrage: real cost about 11.85 million, 13 million leaves a margin.
// Rake and Salvo strike only 3 cells each through the same per-cell path
// Barrage uses for 4 to 6, so their real cost should scale down roughly
// proportionally (about 7 million); 9 million leaves the same margin.
// Derived, not measured, the same as in e2e/run.ts.
//
// Bombardment (a fixed 15 cells) and Carpet (always evaluates all 9 of
// its cells, even on a silent whiff) are deliberately left WITHOUT an
// override: scaling Barrage's real cost by cell count puts both past the
// RPC's own per-transaction cap, where a large explicit limit would just
// get the transaction rejected before it could even be sent, a worse
// failure than an out-of-gas revert. Both need the contract-side stepped-
// call treatment placement already got, a separate, larger fix.
//
// Sonar and placeShield need no override: neither is a per-cell loop
// over an area, and a live cast estimate for Sonar against the deployed
// contract came back at a plausible 198 thousand gas.
const EXPLICIT_GAS_LIMITS: Record<string, bigint> = {
  useBarrage: 13_000_000n,
  useRake: 9_000_000n,
  useSalvo: 9_000_000n,
}

// Pinned to the concrete baseSepolia chain object (not the bare viem
// Chain type) since this project targets Base Sepolia only, and because
// viem's generic Chain type is missing the OP-stack specific formatter
// fields baseSepolia's own type carries, which otherwise makes TypeScript
// treat a WalletClient built with chain: baseSepolia as incompatible with
// a WalletClient typed against the bare generic Chain.
type Wallet = WalletClient<Transport, typeof baseSepolia, Account>
type Client = PublicClient<Transport, typeof baseSepolia>

function findEvent(abi: Abi, receipt: TransactionReceipt, eventName: string) {
  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({ abi, eventName, data: log.data, topics: log.topics })
      if (decoded.eventName === eventName) return decoded.args as unknown as Record<string, unknown>
    } catch {
      // Not this event, keep scanning.
    }
  }
  throw new Error(`event ${eventName} not found in receipt ${receipt.transactionHash}`)
}

// Decodes one struck cell's 3 bit result code from a skill's packed
// reveal (0 inactive, 1 miss, 2 hit, 3 mine, 4 shield break), the same
// packing CiphertideMechanics.resolveChosenAreaStrikes and
// resolveChosenStrikes use on-chain.
function decodeSlotCode(packed: bigint, slot: number): number {
  return Number((packed >> BigInt(slot * 3)) & 0x7n)
}

function codeToOutcome(cell: number, code: number): CellOutcome {
  return { cell, hit: code === 2, mine: code === 3, shieldBreak: code === 4 }
}

export type CiphertideClientOptions = {
  address: Address
  publicClient: Client
  walletClient: Wallet
  zap: Lightning
}

export class CiphertideClient {
  readonly address: Address
  readonly publicClient: Client
  readonly walletClient: Wallet
  readonly zap: Lightning
  readonly account: Address

  constructor(opts: CiphertideClientOptions) {
    this.address = opts.address
    this.publicClient = opts.publicClient
    this.walletClient = opts.walletClient
    this.zap = opts.zap
    this.account = opts.walletClient.account.address
  }

  // ---------------------------------------------------------------
  // Low level helpers, ported from e2e/run.ts's write/read/
  // writeContractWithRetry.
  // ---------------------------------------------------------------

  private async writeContractWithRetry(callArgs: Parameters<Wallet['writeContract']>[0]): Promise<Hex> {
    let lastError: unknown
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        return await this.walletClient.writeContract(callArgs)
      } catch (err) {
        // A hosted RPC's own writeContract gas estimation step can land
        // on a node that has not yet caught up with a previous write if
        // the endpoint is load balanced across several backend nodes
        // with no session affinity, and revert against that stale view
        // even though the real current chain state is fine. This never
        // actually broadcasts a transaction when estimation itself
        // fails, so retrying costs no gas, only a little wall clock
        // time.
        lastError = err
        await sleep(2000 * (attempt + 1))
      }
    }
    throw lastError
  }

  private async write(functionName: string, args: unknown[], value = 0n): Promise<TransactionReceipt> {
    const gas = EXPLICIT_GAS_LIMITS[functionName]
    const hash = await this.writeContractWithRetry({
      address: this.address,
      abi: ciphertideAbi,
      functionName,
      args,
      value,
      account: this.walletClient.account,
      chain: this.walletClient.chain,
      ...(gas ? { gas } : {}),
    } as never)
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash })
    // A read right after a mined write can land on a different, load
    // balanced backend node that has not caught up yet. A short pause
    // here is cheap next to the several seconds a Base Sepolia
    // confirmation already takes, and avoids a false failure on a state
    // check that is actually correct on chain.
    await sleep(1500)
    return receipt
  }

  private async read<T>(functionName: string, args: unknown[] = []): Promise<T> {
    return this.publicClient.readContract({
      address: this.address,
      abi: ciphertideAbi,
      functionName,
      args,
    } as never) as Promise<T>
  }

  private async readConst(name: string): Promise<bigint> {
    const value = await this.read<number | bigint>(name)
    return BigInt(value)
  }

  private async getFee(): Promise<bigint> {
    const executorAbi = [
      { type: 'function', name: 'getFee', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    ] as const
    return this.publicClient.readContract({
      address: this.zap.executorAddress as Address,
      abi: executorAbi,
      functionName: 'getFee',
    })
  }

  private async tightPollReveal(handles: Hex[], onProgress?: ProgressCallback) {
    onProgress?.('revealing')
    return tightPollReveal(this.zap, handles)
  }

  // ---------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------

  async getPhase(matchId: MatchId): Promise<number> {
    return this.read<number>('getPhase', [matchId])
  }

  async getTurn(matchId: MatchId): Promise<Address> {
    return this.read<Address>('getTurn', [matchId])
  }

  async getWinner(matchId: MatchId): Promise<Address> {
    return this.read<Address>('getWinner', [matchId])
  }

  async getPlayerAddress(matchId: MatchId, idx: PlayerIdx): Promise<Address> {
    return this.read<Address>('getPlayerAddress', [matchId, idx])
  }

  // The captain id a player declared at create or join time, 1 through
  // NUM_CAPTAINS, see screens/captains.ts for the id-to-captain table.
  async getCaptain(matchId: MatchId, idx: PlayerIdx): Promise<number> {
    return this.read<number>('getCaptain', [matchId, idx])
  }

  // Seconds left on a player's chess clock right now. Only changes
  // between actions (see Ciphertide.sol's _beginAction), so a UI can
  // safely tick this down locally between reads without drifting far,
  // and should stop ticking entirely once it is not that player's turn
  // or their move is mid-flight, since the real clock is not moving then
  // either.
  async getRemainingTime(matchId: MatchId, idx: PlayerIdx): Promise<bigint> {
    return this.read<bigint>('getRemainingTime', [matchId, idx])
  }

  async getTimeBudgetSeconds(): Promise<bigint> {
    return this.readConst('TIME_BUDGET_SECONDS')
  }

  // Whether this player has already placed a board this match. There is
  // no direct "placed" getter, so this reads the same signal
  // placeMyBoardStep itself is gated on: the board mask handle is the
  // placeholder zero handle until the first placement step runs, and a
  // real (non-zero) ciphertext handle from then on, finished or not. Used
  // to skip a redundant placement attempt after a reload once a player
  // has already placed, not to distinguish "finished" from "mid-flight",
  // see placeBoard's own comment for that narrower gap.
  async hasStartedPlacement(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    const handle = await this.read<Hex>('getBoardMask', [matchId, idx])
    return nonZero(handle)
  }

  // The next match id the contract will hand out. Since match ids are
  // handed out sequentially starting at 1 (see createMatch), any id from
  // 1 up to but excluding this value has been created at least once;
  // anything else is a code that was never issued.
  async getNextMatchId(): Promise<MatchId> {
    return this.read<bigint>('nextMatchId')
  }

  // Resolves which player index (0 or 1) this client's own account is in
  // the given match, needed for confirmPlacement and for reading the
  // right side's own board.
  async getMyPlayerIndex(matchId: MatchId): Promise<PlayerIdx> {
    const addr0 = await this.getPlayerAddress(matchId, 0)
    return addr0.toLowerCase() === this.account.toLowerCase() ? 0 : 1
  }

  async getShotsAgainst(matchId: MatchId, idx: PlayerIdx): Promise<bigint> {
    return this.read<bigint>('getShotsAgainst', [matchId, idx])
  }

  async hasBarrageCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasBarrageCharge', [matchId, idx])
  }

  async hasBombardmentCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasBombardmentCharge', [matchId, idx])
  }

  async hasRakeCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasRakeCharge', [matchId, idx])
  }

  async hasSalvoCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasSalvoCharge', [matchId, idx])
  }

  async hasCarpetCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasCarpetCharge', [matchId, idx])
  }

  async hasSonarCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasSonarCharge', [matchId, idx])
  }

  async hasShieldCharge(matchId: MatchId, idx: PlayerIdx): Promise<boolean> {
    return this.read<boolean>('hasShieldCharge', [matchId, idx])
  }

  // Decrypts this client's own board and mine masks. Unlike the public
  // match-flow reveals (attestedReveal, used everywhere else in this
  // file), a player's own board is never made public: it is only ever
  // allowed to its owner, so reading it back needs attestedDecrypt, which
  // signs an EIP-712 request with the wallet to prove ownership, rather
  // than a plain public reveal.
  async decryptMyBoard(matchId: MatchId): Promise<DecryptedBoard> {
    const idx = await this.getMyPlayerIndex(matchId)
    const [boardHandle, mineHandle] = await Promise.all([
      this.read<Hex>('getBoardMask', [matchId, idx]),
      this.read<Hex>('getMineMask', [matchId, idx]),
    ])
    const [boardResult, mineResult] = await this.zap.attestedDecrypt(this.walletClient, [boardHandle, mineHandle])
    return {
      boardMask: boardResult.plaintext.value as bigint,
      mineMask: mineResult.plaintext.value as bigint,
    }
  }

  // ---------------------------------------------------------------
  // Match setup
  // ---------------------------------------------------------------

  async createMatch(captainId: number): Promise<MatchId> {
    const receipt = await this.write('createMatch', [captainId])
    const { matchId } = findEvent(ciphertideAbi, receipt, 'MatchCreated') as { matchId: bigint }
    return matchId
  }

  async joinMatch(matchId: MatchId, captainId: number): Promise<void> {
    await this.write('joinMatch', [matchId, captainId])
  }

  // ---------------------------------------------------------------
  // Placement: NUM_SHIPS ship steps, then a final mines and reveal step,
  // confirmed once the allPlaced bit is ready. Ported from e2e/run.ts's
  // placeAndConfirm.
  //
  // Resuming after a reload mid-placement: each placeMyBoardStep call
  // asks the contract to place whichever ship (or the mines) its own
  // stored progress says comes next, it does not trust a step number
  // from the caller, so calling this again after an interruption
  // resumes correctly on its own. The one call that does NOT resume, and
  // reverts instead, is calling this again once the player has already
  // fully placed (the contract's own placed flag, see
  // hasStartedPlacement's comment for why that specific finished-or-not
  // distinction is not read ahead of time here).
  // ---------------------------------------------------------------

  async placeBoard(matchId: MatchId, onProgress?: ProgressCallback): Promise<{ allPlaced: boolean }> {
    const idx = await this.getMyPlayerIndex(matchId)
    const NUM_SHIPS = await this.readConst('NUM_SHIPS')
    const PLACEMENT_ATTEMPTS_PER_SHIP = await this.readConst('PLACEMENT_ATTEMPTS_PER_SHIP')
    const MINES_PER_PLAYER = await this.readConst('MINES_PER_PLAYER')
    const MINE_PLACEMENT_ATTEMPTS = await this.readConst('MINE_PLACEMENT_ATTEMPTS')

    for (let attempt = 0; attempt < 3; attempt++) {
      for (let step = 1n; step <= NUM_SHIPS; step++) {
        onProgress?.('sending', `ship step ${step}/${NUM_SHIPS}`)
        const shipFee = (await this.getFee()) * PLACEMENT_ATTEMPTS_PER_SHIP
        await this.write('placeMyBoardStep', [matchId], shipFee)
        onProgress?.('mined', `ship step ${step}/${NUM_SHIPS}`)
      }

      onProgress?.('sending', 'mines and reveal step')
      const mineFee = (await this.getFee()) * MINES_PER_PLAYER * MINE_PLACEMENT_ATTEMPTS
      const receipt = await this.write('placeMyBoardStep', [matchId], mineFee)
      onProgress?.('mined', 'mines and reveal step')

      const { allPlacedHandle } = findEvent(ciphertideAbi, receipt, 'PlacementSubmitted') as { allPlacedHandle: Hex }
      const [{ attestation, signatures }] = await this.tightPollReveal([allPlacedHandle], onProgress)

      onProgress?.('confirming')
      await this.write('confirmPlacement', [matchId, idx, attestation, signatures])
      onProgress?.('confirmed')

      const allPlaced = nonZero(attestation.value)
      if (allPlaced) return { allPlaced: true }
      // The contract has already reset its own step counter back to the
      // first ship on a false allPlaced, so retrying just means running
      // the same NUM_SHIPS + 1 calls again from the start.
    }
    return { allPlaced: false }
  }

  // ---------------------------------------------------------------
  // Dice roll: retried exactly the way a real client has to, a tie
  // leaves the match in AwaitingDiceRoll with no revert.
  // ---------------------------------------------------------------

  async rollDiceUntilDecided(matchId: MatchId, onProgress?: ProgressCallback): Promise<void> {
    let phase = await this.getPhase(matchId)
    let attempts = 0
    while (phase !== 3 /* InProgress */ && attempts < 10) {
      attempts++
      onProgress?.('sending', `roll attempt ${attempts}`)
      const fee = (await this.getFee()) * 2n
      const rollReceipt = await this.write('rollDice', [matchId], fee)
      onProgress?.('mined', `roll attempt ${attempts}`)
      const { rollAHandle, rollBHandle } = findEvent(ciphertideAbi, rollReceipt, 'DiceRolled') as {
        rollAHandle: Hex
        rollBHandle: Hex
      }
      const [a, b] = await this.tightPollReveal([rollAHandle, rollBHandle], onProgress)
      onProgress?.('confirming')
      await this.write('confirmDiceRoll', [matchId, a.attestation, a.signatures, b.attestation, b.signatures])
      onProgress?.('confirmed')

      // A read right after a write can land on a lagging backend node
      // and still show the pre-write state (see write()'s own 1.5s
      // pause). A short extra pause plus a second confirming read closes
      // that gap before this loop trusts a "still AwaitingDiceRoll"
      // reading enough to reroll, avoiding a spurious extra rollDice
      // call that would revert on chain.
      phase = await this.getPhase(matchId)
      if (phase !== 3) {
        await sleep(3000)
        phase = await this.getPhase(matchId)
      }
    }
    if (phase !== 3) throw new Error('dice roll never decided a starting player')
  }

  // ---------------------------------------------------------------
  // Shot
  // ---------------------------------------------------------------

  async shoot(matchId: MatchId, cell: number, onProgress?: ProgressCallback): Promise<ShotOutcome> {
    onProgress?.('sending')
    const receipt = await this.write('shoot', [matchId, cell])
    onProgress?.('mined')

    const { hitHandle, allDestroyedHandle, mineHitHandle, shieldBreakHandle } = findEvent(
      ciphertideAbi,
      receipt,
      'ShotFired',
    ) as {
      hitHandle: Hex
      allDestroyedHandle: Hex
      mineHitHandle: Hex
      shieldBreakHandle: Hex
    }
    const [hit, win, mine, shield] = await this.tightPollReveal(
      [hitHandle, allDestroyedHandle, mineHitHandle, shieldBreakHandle],
      onProgress,
    )

    onProgress?.('confirming')
    await this.write('confirmShot', [
      matchId,
      hit.attestation,
      hit.signatures,
      win.attestation,
      win.signatures,
      mine.attestation,
      mine.signatures,
      shield.attestation,
      shield.signatures,
    ])
    onProgress?.('confirmed')

    return {
      cell,
      hit: nonZero(hit.attestation.value),
      mine: nonZero(mine.attestation.value),
      shieldBreak: nonZero(shield.attestation.value),
      win: nonZero(win.attestation.value),
    }
  }

  // ---------------------------------------------------------------
  // Sonar: single reveal, no struck cells.
  // ---------------------------------------------------------------

  async useSonar(matchId: MatchId, anchorRow: number, anchorCol: number, onProgress?: ProgressCallback): Promise<SonarOutcome> {
    onProgress?.('sending')
    const receipt = await this.write('useSonar', [matchId, anchorRow, anchorCol])
    onProgress?.('mined')

    const { resultHandle } = findEvent(ciphertideAbi, receipt, 'SonarFired') as { resultHandle: Hex }
    const [result] = await this.tightPollReveal([resultHandle], onProgress)

    onProgress?.('confirming')
    await this.write('confirmSonar', [matchId, result.attestation, result.signatures])
    onProgress?.('confirmed')

    return { anyShip: nonZero(result.attestation.value) }
  }

  // ---------------------------------------------------------------
  // Barrage, Bombardment and Rake: public cell choice, a packed reveal
  // covering every struck cell plus a win reveal. Shares one
  // implementation, only the function names, event name and call args
  // differ, the same shape e2e/run.ts's useAreaSkillAndConfirm uses.
  // ---------------------------------------------------------------

  private async fireAreaSkill(
    matchId: MatchId,
    useFn: string,
    useArgs: unknown[],
    firedEvent: string,
    confirmFn: string,
    onProgress?: ProgressCallback,
  ): Promise<AreaSkillOutcome> {
    onProgress?.('sending')
    const receipt = await this.write(useFn, useArgs)
    onProgress?.('mined')

    const { cells, packedHandle, allDestroyedHandle } = findEvent(ciphertideAbi, receipt, firedEvent) as {
      cells: readonly number[]
      packedHandle: Hex
      allDestroyedHandle: Hex
    }
    const [packed, win] = await this.tightPollReveal([packedHandle, allDestroyedHandle], onProgress)

    onProgress?.('confirming')
    await this.write(confirmFn, [matchId, packed.attestation, packed.signatures, win.attestation, win.signatures])
    onProgress?.('confirmed')

    const packedValue = BigInt(packed.attestation.value)
    const outcomes = cells.map((cell, slot) => codeToOutcome(cell, decodeSlotCode(packedValue, slot)))
    return { cells: outcomes, win: nonZero(win.attestation.value) }
  }

  async useBarrage(matchId: MatchId, anchorRow: number, anchorCol: number, onProgress?: ProgressCallback): Promise<AreaSkillOutcome> {
    return this.fireAreaSkill(matchId, 'useBarrage', [matchId, anchorRow, anchorCol], 'BarrageFired', 'confirmBarrage', onProgress)
  }

  async useBombardment(matchId: MatchId, anchorRow: number, anchorCol: number, onProgress?: ProgressCallback): Promise<AreaSkillOutcome> {
    return this.fireAreaSkill(
      matchId,
      'useBombardment',
      [matchId, anchorRow, anchorCol],
      'BombardmentFired',
      'confirmBombardment',
      onProgress,
    )
  }

  async useRake(matchId: MatchId, row: number, onProgress?: ProgressCallback): Promise<AreaSkillOutcome> {
    return this.fireAreaSkill(matchId, 'useRake', [matchId, row], 'RakeFired', 'confirmRake', onProgress)
  }

  // ---------------------------------------------------------------
  // Salvo: 3 caller chosen cells, no local position packed since the
  // caller already knows which cells it chose.
  // ---------------------------------------------------------------

  async useSalvo(
    matchId: MatchId,
    cell0: number,
    cell1: number,
    cell2: number,
    onProgress?: ProgressCallback,
  ): Promise<AreaSkillOutcome> {
    onProgress?.('sending')
    const receipt = await this.write('useSalvo', [matchId, cell0, cell1, cell2])
    onProgress?.('mined')

    const { packedHandle, allDestroyedHandle } = findEvent(ciphertideAbi, receipt, 'SalvoFired') as {
      packedHandle: Hex
      allDestroyedHandle: Hex
    }
    const [packed, win] = await this.tightPollReveal([packedHandle, allDestroyedHandle], onProgress)

    onProgress?.('confirming')
    await this.write('confirmSalvo', [matchId, packed.attestation, packed.signatures, win.attestation, win.signatures])
    onProgress?.('confirmed')

    const packedValue = BigInt(packed.attestation.value)
    const cells = [cell0, cell1, cell2].map((cell, slot) => codeToOutcome(cell, decodeSlotCode(packedValue, slot)))
    return { cells, win: nonZero(win.attestation.value) }
  }

  // ---------------------------------------------------------------
  // Carpet: a caller chosen 3x3 area, always 9 fixed local slots in
  // row-major order from the anchor, whether it triggers at all is
  // conditional on encrypted board state (a silent whiff decodes every
  // slot to code 0, which codeToOutcome reports as no hit, no mine, no
  // shield break, exactly like a genuine miss).
  // ---------------------------------------------------------------

  async useCarpet(matchId: MatchId, anchorRow: number, anchorCol: number, onProgress?: ProgressCallback): Promise<AreaSkillOutcome> {
    onProgress?.('sending')
    const receipt = await this.write('useCarpet', [matchId, anchorRow, anchorCol])
    onProgress?.('mined')

    const { packedHandle, allDestroyedHandle } = findEvent(ciphertideAbi, receipt, 'CarpetFired') as {
      packedHandle: Hex
      allDestroyedHandle: Hex
    }
    const [packed, win] = await this.tightPollReveal([packedHandle, allDestroyedHandle], onProgress)

    onProgress?.('confirming')
    await this.write('confirmCarpet', [matchId, packed.attestation, packed.signatures, win.attestation, win.signatures])
    onProgress?.('confirmed')

    const packedValue = BigInt(packed.attestation.value)
    const CARPET_AREA_SIZE = Number(await this.readConst('CARPET_AREA_SIZE'))
    const BOARD_SIZE = Number(await this.readConst('BOARD_SIZE'))
    const cells: CellOutcome[] = []
    for (let localPos = 0; localPos < CARPET_AREA_SIZE * CARPET_AREA_SIZE; localPos++) {
      const globalCell =
        (anchorRow + Math.floor(localPos / CARPET_AREA_SIZE)) * BOARD_SIZE + (anchorCol + (localPos % CARPET_AREA_SIZE))
      cells.push(codeToOutcome(globalCell, decodeSlotCode(packedValue, localPos)))
    }
    return { cells, win: nonZero(win.attestation.value) }
  }

  // ---------------------------------------------------------------
  // Shield: the one action that itself needs a client-encrypted input
  // (the chosen cell), rather than only revealing handles the contract
  // already produced. zap.encrypt embeds the caller and contract address
  // into the ciphertext so it can only be submitted by this account
  // against this contract. No confirm step, the placement lands directly.
  // ---------------------------------------------------------------

  async placeShield(matchId: MatchId, cell: number, onProgress?: ProgressCallback): Promise<void> {
    onProgress?.('sending')
    const cellMask = 1n << BigInt(cell)
    const ciphertext = await this.zap.encrypt(cellMask, {
      accountAddress: this.account,
      dappAddress: this.address,
      handleType: handleTypes.euint256,
    })
    const fee = await this.getFee()
    await this.write('placeShield', [matchId, ciphertext], fee)
    onProgress?.('confirmed')
  }
}
