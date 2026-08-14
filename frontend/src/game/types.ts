import type { Address, Hex } from 'viem'

// Mirrors Ciphertide.Phase. Index matches the enum's on-chain ordinal.
export const PHASE_NAMES = [
  'WaitingForOpponent',
  'Placing',
  'AwaitingDiceRoll',
  'InProgress',
  'Finished',
] as const
export type PhaseName = (typeof PHASE_NAMES)[number]

export type PlayerIdx = 0 | 1

// One attestation plus its covalidator signatures, ready to submit to a
// confirm call. Shaped to match the ABI's DecryptionAttestation tuple.
export type AttestationResult = {
  attestation: { handle: Hex; value: Hex }
  signatures: Hex[]
}

// A single struck cell's decoded result, shared by every multi-cell skill
// (Barrage, Bombardment, Rake, Salvo, Carpet) and by a plain shot.
export type CellOutcome = {
  cell: number
  hit: boolean
  mine: boolean
  shieldBreak: boolean
}

export type ShotOutcome = {
  cell: number
  hit: boolean
  mine: boolean
  shieldBreak: boolean
  win: boolean
}

export type AreaSkillOutcome = {
  cells: CellOutcome[]
  win: boolean
}

export type SonarOutcome = {
  anyShip: boolean
}

// Reported at each stage of an action's full cycle, so a caller (a UI, or
// this module's own dev harness) can show progress without needing to
// split the action into separate calls. The confirm step runs
// automatically as soon as the reveal is ready, it is not a second thing
// the caller has to trigger, see the module README comment in client.ts.
export type ActionStage = 'sending' | 'mined' | 'revealing' | 'confirming' | 'confirmed'
export type ProgressCallback = (stage: ActionStage, detail?: string) => void

export type MatchId = bigint

export type DecryptedBoard = {
  boardMask: bigint
  mineMask: bigint
}

// A player's real on-chain placement progress, replayed from the
// contract's own placement events (see CiphertideClient.getPlacementProgress).
// 'placed' means PlacementConfirmed has fired, the only real completion
// signal. 'pending' means the final mines-and-reveal step already landed
// on chain and is waiting on its reveal and confirmPlacement, calling
// placeMyBoardStep again in this state reverts. 'in-progress' means some
// number of ship steps (0 up to NUM_SHIPS - 1) have landed and placement
// should resume from shipsDone, not restart from ship 0.
export type PlacementProgress =
  | { kind: 'placed' }
  | { kind: 'pending'; allPlacedHandle: Hex }
  | { kind: 'in-progress'; shipsDone: number }

export type PlayerAddresses = {
  playerA: Address
  playerB: Address
}
