import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { zeroAddress, type Address } from 'viem'
import DecryptReadout from '../components/cipher/DecryptReadout'
import { cellCoordLabel, type CipherCellState } from '../components/cipher/CipherCell'
import OwnBoard from '../components/board/OwnBoard'
import EnemyBoard from '../components/board/EnemyBoard'
import StatusDivider from '../components/match/StatusDivider'
import SkillsPanel, { type SkillEntry } from '../components/match/SkillsPanel'
import ChatPanel from '../components/match/ChatPanel'
import { getGameClient } from '../lib/gameClient'
import { getSigner } from '../lib/signer'
import { BARRAGE_AREA_SIZE, BOARD_SIZE, SALVO_CELL_COUNT, SONAR_AREA_SIZE, clampAnchor } from '../lib/boardConstants'
import { CAPTAINS } from './captains'
import { PHASE_NAMES, type ActionStage, type AreaSkillOutcome, type CellOutcome, type MatchId, type PlayerIdx } from '../game'
import './MatchScreen.css'

type SkillMode = 'shoot' | 'sonar' | 'barrage' | 'rake' | 'salvo' | 'shield'

type ActionState = { kind: 'idle' } | { kind: 'busy'; label: string; stage: ActionStage; detail?: string } | { kind: 'error'; message: string }

type PlacementState =
  | { kind: 'checking' }
  | { kind: 'placing'; stage: ActionStage; detail?: string }
  | { kind: 'waiting-for-opponent' }
  | { kind: 'error'; message: string }

type DiceState = { kind: 'idle' } | { kind: 'rolling' } | { kind: 'waiting' } | { kind: 'error'; message: string }

const TIME_BUDGET_FALLBACK = 300

function cellStateForOutcome(outcome: CellOutcome): CipherCellState {
  if (outcome.shieldBreak) return 'shield'
  if (outcome.hit) return 'hit'
  if (outcome.mine) return 'mine'
  return 'miss'
}

function shortAddress(address: Address): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

// Turns client.ts's raw placement progress detail ("ship step 4/6",
// "mines and reveal step") into the human label shown while placing.
// Reads straight from the client's own text rather than a separately
// tracked counter, so it can never drift out of sync with what actually
// happened on chain (see runRemainingPlacementSteps's self-correction).
function placementStepLabel(detail: string | undefined): string {
  if (detail === 'mines and reveal step') return 'Sealing your fleet and mines...'
  const match = detail?.match(/^ship step (\d+)\/(\d+)$/)
  if (match) return `Placing ship ${match[1]} of ${match[2]}...`
  return 'Placing your fleet...'
}

function bitsToCells(mask: bigint): Set<number> {
  const cells = new Set<number>()
  for (let cell = 0; cell < BOARD_SIZE * BOARD_SIZE; cell++) {
    if ((mask & (1n << BigInt(cell))) !== 0n) cells.add(cell)
  }
  return cells
}

/**
 * The real in-match view: the opponent's fog of war on top, your own
 * decrypted waters below it, a status divider carrying the turn, both
 * chess clocks and the reveal readout between them, and a skills dock
 * plus a reserved chat panel on the right. Wired end to end to
 * CiphertideClient, the same client the dev harness proves against the
 * live deployment, no invented API and no faked outcome.
 */
export default function MatchScreen() {
  const { matchId: matchIdParam } = useParams<{ matchId: string }>()
  const navigate = useNavigate()

  const clientRef = useRef<Awaited<ReturnType<typeof getGameClient>>>(null)
  const matchId: MatchId | null = matchIdParam && /^\d+$/.test(matchIdParam) ? BigInt(matchIdParam) : null

  const [loadError, setLoadError] = useState<string | null>(null)
  const [notAPlayer, setNotAPlayer] = useState(false)
  const [phase, setPhase] = useState<number | null>(null)
  const [myIdx, setMyIdx] = useState<PlayerIdx | null>(null)
  const [addresses, setAddresses] = useState<[Address, Address] | null>(null)
  const [captainIds, setCaptainIds] = useState<[number, number] | null>(null)

  const [placementState, setPlacementState] = useState<PlacementState>({ kind: 'checking' })
  const [diceState, setDiceState] = useState<DiceState>({ kind: 'idle' })

  const [turn, setTurn] = useState<Address | null>(null)
  const [winner, setWinner] = useState<Address | null>(null)
  const [mySeconds, setMySeconds] = useState(TIME_BUDGET_FALLBACK)
  const [opponentSeconds, setOpponentSeconds] = useState(TIME_BUDGET_FALLBACK)
  const [ownBoard, setOwnBoard] = useState<{ boardMask: bigint; mineMask: bigint } | null>(null)
  const [shotsAgainstMe, setShotsAgainstMe] = useState(0n)
  const [enemyKnown, setEnemyKnown] = useState<Map<number, CipherCellState>>(new Map())
  const [charges, setCharges] = useState<{ sonar: boolean; barrage: boolean; unique: boolean }>({
    sonar: false,
    barrage: false,
    unique: false,
  })

  const [actionState, setActionState] = useState<ActionState>({ kind: 'idle' })
  const [activeSkill, setActiveSkill] = useState<SkillMode>('shoot')
  const [pendingSalvoCells, setPendingSalvoCells] = useState<number[]>([])
  const [readoutText, setReadoutText] = useState<string | null>(null)

  const myIdxRef = useRef<PlayerIdx | null>(null)
  useEffect(() => {
    myIdxRef.current = myIdx
  }, [myIdx])

  // ---------------------------------------------------------------
  // Initial load: the client, both addresses and captains, my index.
  // ---------------------------------------------------------------

  useEffect(() => {
    if (!getSigner()) {
      navigate('/register', { replace: true })
      return
    }
    if (matchId === null) {
      setLoadError('That is not a valid match code.')
      return
    }

    let cancelled = false
    ;(async () => {
      const client = await getGameClient()
      if (!client) {
        navigate('/register', { replace: true })
        return
      }
      clientRef.current = client

      try {
        const [addr0, addr1] = await Promise.all([client.getPlayerAddress(matchId, 0), client.getPlayerAddress(matchId, 1)])
        if (cancelled) return
        if (addr0 === zeroAddress) {
          setLoadError('That match does not exist.')
          return
        }
        const account = client.account.toLowerCase()
        const idx: PlayerIdx | null = addr0.toLowerCase() === account ? 0 : addr1.toLowerCase() === account ? 1 : null
        if (idx === null) {
          setNotAPlayer(true)
          return
        }
        setAddresses([addr0, addr1])
        setMyIdx(idx)

        const [captain0, captain1, budget, currentPhase] = await Promise.all([
          client.getCaptain(matchId, 0),
          client.getCaptain(matchId, 1),
          client.getTimeBudgetSeconds(),
          client.getPhase(matchId),
        ])
        if (cancelled) return
        setCaptainIds([captain0, captain1])
        setMySeconds(Number(budget) || TIME_BUDGET_FALLBACK)
        setOpponentSeconds(Number(budget) || TIME_BUDGET_FALLBACK)
        setPhase(currentPhase)
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Could not load this match.')
      }
    })()

    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [matchIdParam])

  // ---------------------------------------------------------------
  // Placement phase: read the REAL on-chain placement progress first
  // (see CiphertideClient.getPlacementProgress), so a reload mid-
  // placement resumes at the correct next step instead of being treated
  // as finished. Only a real PlacementConfirmed (progress.kind ===
  // 'placed') skips straight to waiting for the opponent.
  // ---------------------------------------------------------------

  useEffect(() => {
    if (phase !== 1 || myIdx === null || matchId === null) return
    const client = clientRef.current
    if (!client) return
    let cancelled = false

    ;(async () => {
      try {
        const progress = await client.getPlacementProgress(matchId, myIdx)
        if (progress.kind === 'placed') {
          if (!cancelled) setPlacementState({ kind: 'waiting-for-opponent' })
          return
        }
        // Reveal and confirm stages report progress with no detail of
        // their own (see client.ts's tightPollReveal call), so the last
        // real detail (which ship, or the mines and reveal step) is
        // carried forward rather than shown as blank while waiting on
        // the reveal that follows it.
        let lastDetail: string | undefined
        const onProgress = (stage: ActionStage, detail?: string) => {
          if (detail) lastDetail = detail
          if (!cancelled) setPlacementState({ kind: 'placing', stage, detail: lastDetail })
        }
        await client.placeBoard(matchId, onProgress)
        if (!cancelled) setPlacementState({ kind: 'waiting-for-opponent' })
      } catch (err) {
        if (!cancelled) setPlacementState({ kind: 'error', message: err instanceof Error ? err.message : 'Placement failed.' })
      }
    })()

    return () => {
      cancelled = true
    }
  }, [phase, myIdx, matchId])

  // Poll phase while waiting on placement, so this player's screen
  // advances the moment both sides have finished, not just when a
  // manual reload happens to check again.
  useEffect(() => {
    if (phase !== 1 || placementState.kind !== 'waiting-for-opponent' || matchId === null) return
    const client = clientRef.current
    if (!client) return
    const id = window.setInterval(async () => {
      try {
        const p = await client.getPhase(matchId)
        setPhase(p)
      } catch {
        // Transient read error, the next tick tries again.
      }
    }, 3000)
    return () => window.clearInterval(id)
  }, [phase, placementState.kind, matchId])

  // ---------------------------------------------------------------
  // Dice roll: either player is allowed to call it on chain, only
  // player 0 actually does from this screen so the two tabs never race
  // each other into the same roll.
  // ---------------------------------------------------------------

  useEffect(() => {
    if (phase !== 2 || myIdx === null || matchId === null) return
    const client = clientRef.current
    if (!client) return
    let cancelled = false

    if (myIdx === 0) {
      setDiceState({ kind: 'rolling' })
      client
        .rollDiceUntilDecided(matchId)
        .then(async () => {
          if (cancelled) return
          const p = await client.getPhase(matchId)
          if (!cancelled) setPhase(p)
        })
        .catch((err) => {
          if (!cancelled) setDiceState({ kind: 'error', message: err instanceof Error ? err.message : 'Dice roll failed.' })
        })
    } else {
      setDiceState({ kind: 'waiting' })
      const id = window.setInterval(async () => {
        try {
          const p = await client.getPhase(matchId)
          setPhase(p)
        } catch {
          // Transient read error, the next tick tries again.
        }
      }, 3000)
      return () => window.clearInterval(id)
    }

    return () => {
      cancelled = true
    }
  }, [phase, myIdx, matchId])

  // ---------------------------------------------------------------
  // Combat: load my decrypted board once, then poll live state so this
  // screen picks up the opponent's moves without a manual reload.
  // ---------------------------------------------------------------

  const refreshLiveState = useCallback(async () => {
    const client = clientRef.current
    const idx = myIdxRef.current
    if (!client || idx === null || matchId === null) return
    const opponentIdx: PlayerIdx = idx === 0 ? 1 : 0
    try {
      const [p, t, w, mySecondsLeft, oppSecondsLeft, myShots, oppShots] = await Promise.all([
        client.getPhase(matchId),
        client.getTurn(matchId),
        client.getWinner(matchId),
        client.getRemainingTime(matchId, idx),
        client.getRemainingTime(matchId, opponentIdx),
        client.getShotsAgainst(matchId, idx),
        client.getShotsAgainst(matchId, opponentIdx),
      ])
      setPhase(p)
      setTurn(t)
      setWinner(w === zeroAddress ? null : w)
      setMySeconds(Number(mySecondsLeft))
      setOpponentSeconds(Number(oppSecondsLeft))
      setShotsAgainstMe(myShots)
      setEnemyKnown((prev) => {
        const next = new Map(prev)
        for (const cell of bitsToCells(oppShots)) {
          if (!next.has(cell)) next.set(cell, 'miss')
        }
        return next
      })
    } catch {
      // Transient read error, the next poll tries again.
    }
  }, [matchId])

  useEffect(() => {
    if (phase !== 3 || myIdx === null || matchId === null) return
    const client = clientRef.current
    if (!client) return
    let cancelled = false

    ;(async () => {
      try {
        const board = await client.decryptMyBoard(matchId)
        if (!cancelled) setOwnBoard(board)
      } catch (err) {
        if (!cancelled) setActionState({ kind: 'error', message: err instanceof Error ? err.message : 'Could not decrypt your board.' })
      }
    })()

    Promise.all([client.hasSonarCharge(matchId, myIdx), client.hasBarrageCharge(matchId, myIdx)])
      .then(([sonar, barrage]) => setCharges((c) => ({ ...c, sonar, barrage })))
      .catch(() => {})

    void refreshLiveState()
    const id = window.setInterval(() => {
      if (actionState.kind === 'busy') return
      void refreshLiveState()
    }, 3000)
    return () => {
      cancelled = true
      window.clearInterval(id)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, myIdx, matchId, refreshLiveState])

  // Refresh the unique-skill charge whenever the captain roster loads.
  useEffect(() => {
    if (phase !== 3 || myIdx === null || matchId === null || !captainIds) return
    const client = clientRef.current
    if (!client) return
    const myCaptainId = captainIds[myIdx]
    const read =
      myCaptainId === 1
        ? client.hasShieldCharge(matchId, myIdx)
        : myCaptainId === 3
          ? client.hasRakeCharge(matchId, myIdx)
          : myCaptainId === 4
            ? client.hasSalvoCharge(matchId, myIdx)
            : null
    if (!read) return
    read.then((has) => setCharges((c) => ({ ...c, unique: has }))).catch(() => {})
  }, [phase, myIdx, matchId, captainIds, actionState])

  // ---------------------------------------------------------------
  // Local clock: ticks the active player down between polls, frozen
  // whenever an action is mid-flight since the real clock is not
  // moving for anyone then either (see StatusDivider's own comment).
  // ---------------------------------------------------------------

  useEffect(() => {
    if (phase !== 3 || !turn || !addresses || actionState.kind === 'busy') return
    const id = window.setInterval(() => {
      const turnIsMine = turn.toLowerCase() === addresses[myIdx ?? 0]?.toLowerCase()
      if (turnIsMine) setMySeconds((s) => Math.max(0, s - 1))
      else setOpponentSeconds((s) => Math.max(0, s - 1))
    }, 1000)
    return () => window.clearInterval(id)
  }, [phase, turn, addresses, myIdx, actionState.kind])

  // ---------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------

  function applyAreaOutcome(outcome: AreaSkillOutcome, label: string) {
    setEnemyKnown((prev) => {
      const next = new Map(prev)
      for (const cellOutcome of outcome.cells) next.set(cellOutcome.cell, cellStateForOutcome(cellOutcome))
      return next
    })
    const hitCount = outcome.cells.filter((c) => c.hit).length
    setReadoutText(`${label} // ${hitCount > 0 ? `${hitCount} HULL CONTACT${hitCount > 1 ? 'S' : ''}` : 'NO CONTACT'}`)
  }

  async function runAction(label: string, fn: (onProgress: (stage: ActionStage, detail?: string) => void) => Promise<void>) {
    setActionState({ kind: 'busy', label, stage: 'sending' })
    try {
      await fn((stage, detail) => setActionState({ kind: 'busy', label, stage, detail }))
      setActionState({ kind: 'idle' })
      setActiveSkill('shoot')
      setPendingSalvoCells([])
      await refreshLiveState()
    } catch (err) {
      setActionState({ kind: 'error', message: err instanceof Error ? err.message : `${label} failed.` })
    }
  }

  async function handleEnemyCellClick(cell: number) {
    const client = clientRef.current
    if (!client || matchId === null || actionState.kind === 'busy') return
    const row = Math.floor(cell / BOARD_SIZE)
    const col = cell % BOARD_SIZE

    if (activeSkill === 'shoot') {
      await runAction('Firing shot', async (onProgress) => {
        const outcome = await client.shoot(matchId, cell, onProgress)
        setEnemyKnown((prev) => new Map(prev).set(cell, cellStateForOutcome(outcome)))
        setReadoutText(`${cellCoordLabel(row, col)} // ${outcome.shieldBreak ? 'SHIELD BREAK' : outcome.hit ? 'CONTACT, HULL BREACH' : outcome.mine ? 'MINE TRIGGERED' : 'NO CONTACT'}`)
      })
      return
    }

    if (activeSkill === 'sonar') {
      const anchorRow = clampAnchor(row, SONAR_AREA_SIZE)
      const anchorCol = clampAnchor(col, SONAR_AREA_SIZE)
      await runAction('Sonar sweep', async (onProgress) => {
        const outcome = await client.useSonar(matchId, anchorRow, anchorCol, onProgress)
        setReadoutText(`SONAR ${cellCoordLabel(anchorRow, anchorCol)} // ${outcome.anyShip ? 'CONTACT DETECTED' : 'NO CONTACT'}`)
      })
      return
    }

    if (activeSkill === 'barrage') {
      const anchorRow = clampAnchor(row, BARRAGE_AREA_SIZE)
      const anchorCol = clampAnchor(col, BARRAGE_AREA_SIZE)
      await runAction('Barrage', async (onProgress) => {
        const outcome = await client.useBarrage(matchId, anchorRow, anchorCol, onProgress)
        applyAreaOutcome(outcome, 'BARRAGE')
      })
      return
    }

    if (activeSkill === 'rake') {
      await runAction('Rake', async (onProgress) => {
        const outcome = await client.useRake(matchId, row, onProgress)
        applyAreaOutcome(outcome, `RAKE ROW ${row + 1}`)
      })
      return
    }

    if (activeSkill === 'salvo') {
      if (pendingSalvoCells.includes(cell)) return
      const next = [...pendingSalvoCells, cell]
      if (next.length < SALVO_CELL_COUNT) {
        setPendingSalvoCells(next)
        return
      }
      setPendingSalvoCells(next)
      await runAction('Salvo', async (onProgress) => {
        const outcome = await client.useSalvo(matchId, next[0], next[1], next[2], onProgress)
        applyAreaOutcome(outcome, 'SALVO')
      })
    }
  }

  async function handleOwnCellClick(cell: number) {
    const client = clientRef.current
    if (!client || matchId === null || activeSkill !== 'shield' || actionState.kind === 'busy') return
    await runAction('Shield', async (onProgress) => {
      await client.placeShield(matchId, cell, onProgress)
      setReadoutText(`SHIELD SEALED // ${cellCoordLabel(Math.floor(cell / BOARD_SIZE), cell % BOARD_SIZE)}`)
    })
  }

  function handleArmSkill(id: string) {
    setActiveSkill((current) => (current === id ? 'shoot' : (id as SkillMode)))
    setPendingSalvoCells([])
  }

  // ---------------------------------------------------------------
  // Derived view data
  // ---------------------------------------------------------------

  if (loadError) {
    return (
      <div className="match-screen match-screen--message">
        <div className="ct-scanlines" aria-hidden="true" />
        <div className="match-message-panel">
          <p className="ct-label">Match Not Found</p>
          <p>{loadError}</p>
          <button type="button" className="match-btn match-btn--primary" onClick={() => navigate('/play')}>
            Back to Lobby
          </button>
        </div>
      </div>
    )
  }

  if (notAPlayer) {
    return (
      <div className="match-screen match-screen--message">
        <div className="ct-scanlines" aria-hidden="true" />
        <div className="match-message-panel">
          <p className="ct-label">Not Your Command</p>
          <p>This wallet is not a player in this match.</p>
          <button type="button" className="match-btn match-btn--primary" onClick={() => navigate('/play')}>
            Back to Lobby
          </button>
        </div>
      </div>
    )
  }

  if (phase === null || myIdx === null || !addresses || !captainIds) {
    return (
      <div className="match-screen match-screen--message">
        <div className="ct-scanlines" aria-hidden="true" />
        <div className="match-message-panel">
          <p className="ct-label">Matchmaking // Base Sepolia</p>
          <p>Loading match {matchIdParam}...</p>
        </div>
      </div>
    )
  }

  const opponentIdx: PlayerIdx = myIdx === 0 ? 1 : 0
  const myCaptain = CAPTAINS.find((c) => c.id === captainIds[myIdx])
  const opponentCaptain = CAPTAINS.find((c) => c.id === captainIds[opponentIdx])
  const isMyTurn = phase === 3 && turn?.toLowerCase() === addresses[myIdx].toLowerCase()

  if (phase === 0) {
    return (
      <div className="match-screen match-screen--message">
        <div className="ct-scanlines" aria-hidden="true" />
        <div className="match-message-panel">
          <p className="ct-label">Waiting</p>
          <p>This match is still waiting for an opponent to join.</p>
          <button type="button" className="match-btn match-btn--primary" onClick={() => navigate('/play')}>
            Back to Lobby
          </button>
        </div>
      </div>
    )
  }

  if (phase === 4) {
    const iWon = winner?.toLowerCase() === addresses[myIdx].toLowerCase()
    return (
      <div className="match-screen match-screen--message">
        <div className="ct-scanlines" aria-hidden="true" />
        <div className={`match-message-panel${iWon ? ' match-message-panel--win' : ' match-message-panel--loss'}`}>
          <p className="ct-label">Match {matchIdParam} // Finished</p>
          <h1 className="match-result-title">{iWon ? 'Victory' : 'Defeat'}</h1>
          <p>{iWon ? 'The enemy fleet is destroyed.' : 'Your fleet has been destroyed.'}</p>
          <button type="button" className="match-btn match-btn--primary" onClick={() => navigate('/play')}>
            Back to Lobby
          </button>
        </div>
      </div>
    )
  }

  const skills: SkillEntry[] = []
  if (phase === 3) {
    skills.push({
      id: 'sonar',
      label: 'Sonar',
      description: 'Sweep a 5x5 area to detect any ship inside it.',
      usable: charges.sonar,
      used: !charges.sonar,
    })
    skills.push({
      id: 'barrage',
      label: 'Barrage',
      description: 'Strike 4 to 6 random cells inside a 4x4 area.',
      usable: charges.barrage,
      used: !charges.barrage,
    })
    if (myCaptain) {
      const captainId = myCaptain.id
      if (captainId === 1) {
        skills.push({ id: 'shield', label: 'Shield', description: 'Seal one of your own cells against the next hit.', usable: charges.unique, used: !charges.unique })
      } else if (captainId === 3) {
        skills.push({ id: 'rake', label: 'Rake', description: 'Strike three random cells along a chosen row.', usable: charges.unique, used: !charges.unique })
      } else if (captainId === 4) {
        skills.push({ id: 'salvo', label: 'Salvo', description: 'Name three exact cells and hit all three.', usable: charges.unique, used: !charges.unique })
      } else {
        skills.push({
          id: myCaptain.mark,
          label: myCaptain.skillName,
          description: myCaptain.description,
          usable: false,
          used: false,
          unavailableReason: 'Exceeds the chain gas cap right now, disabled until it is split into steps.',
        })
      }
    }
  }

  const highlightCells =
    activeSkill === 'salvo'
      ? new Set(pendingSalvoCells)
      : undefined

  return (
    <div className="match-screen">
      <div className="ct-scanlines" aria-hidden="true" />

      <header className="console-header">
        <div className="wordmark">
          <span className="wordmark-glyph" aria-hidden="true">
            &#8225;
          </span>
          <span className="wordmark-text">CIPHERTIDE</span>
        </div>
        <div className="console-header-meta ct-mono">
          <span className="ct-label">MATCH</span>
          <span>{matchIdParam}</span>
        </div>
      </header>

      <main className="match-theater">
        <div className="match-column match-column--boards">
          <section className="board-panel board-panel--enemy" aria-label="Enemy waters">
            <div className="board-panel-head">
              <h2>Enemy Waters</h2>
              <span className="ct-label">{opponentCaptain ? opponentCaptain.skillName : 'encrypted until you fire'}</span>
            </div>
            <div className="enemy-panel-body">
              <div className="sonar-sweep" aria-hidden="true" />
              <EnemyBoard
                cellStates={enemyKnown}
                highlightCells={highlightCells}
                interactive={phase === 3 && isMyTurn && actionState.kind !== 'busy'}
                onSelectCell={handleEnemyCellClick}
              />
            </div>
          </section>

          <StatusDivider
            phaseLabel={placementState.kind !== 'checking' && phase === 1 ? 'PLACING' : PHASE_NAMES[phase].toUpperCase()}
            turnLabel={phase !== 3 ? '-' : isMyTurn ? 'YOUR TURN' : "OPPONENT'S TURN"}
            myLabel="You"
            opponentLabel={shortAddress(addresses[opponentIdx])}
            mySeconds={mySeconds}
            opponentSeconds={opponentSeconds}
            myClockRunning={phase === 3 && isMyTurn && actionState.kind !== 'busy'}
            opponentClockRunning={phase === 3 && !isMyTurn && actionState.kind !== 'busy'}
            readoutText={
              actionState.kind === 'busy'
                ? `${actionState.label.toUpperCase()} // ${actionState.stage.toUpperCase()}${actionState.detail ? ` (${actionState.detail})` : ''}`
                : readoutText
            }
          />

          <section className="board-panel" aria-label="Your waters">
            <div className="board-panel-head">
              <h2>Your Waters</h2>
              <span className="ct-label">
                {myCaptain ? myCaptain.name : ''} // {activeSkill === 'shield' ? 'select a cell to seal' : 'decrypted, yours to see'}
              </span>
            </div>
            {ownBoard ? (
              <OwnBoard
                boardMask={ownBoard.boardMask}
                mineMask={ownBoard.mineMask}
                shotsAgainstMe={shotsAgainstMe}
                interactive={activeSkill === 'shield' && isMyTurn && actionState.kind !== 'busy'}
                onSelectCell={handleOwnCellClick}
              />
            ) : (
              <div className="board-loading ct-mono">decrypting your own waters...</div>
            )}
          </section>
        </div>

        <div className="match-column match-column--side">
          <div className="side-panel side-panel--chat">
            {matchId !== null && (
              <ChatPanel matchId={matchId} myAddress={addresses[myIdx]} opponentAddress={addresses[opponentIdx]} />
            )}
          </div>
          <div className="side-panel side-panel--skills">
            {phase === 1 && <PlacementView state={placementState} />}
            {phase === 2 && <DiceView state={diceState} />}
            {phase === 3 && (
              <SkillsPanel
                skills={skills}
                activeSkill={activeSkill === 'shoot' ? null : activeSkill}
                onArm={handleArmSkill}
                disabled={!isMyTurn || actionState.kind === 'busy'}
                progressNote={activeSkill === 'salvo' ? `${pendingSalvoCells.length}/${SALVO_CELL_COUNT} cells selected` : undefined}
              />
            )}
            {actionState.kind === 'error' && (
              <div className="match-error" role="alert">
                <p>{actionState.message}</p>
                <button type="button" className="match-btn match-btn--ghost" onClick={() => setActionState({ kind: 'idle' })}>
                  Dismiss
                </button>
              </div>
            )}
          </div>
        </div>
      </main>
    </div>
  )
}

function PlacementView({ state }: { state: PlacementState }) {
  if (state.kind === 'checking') {
    return (
      <div className="placement-view">
        <p className="ct-label">Placement</p>
        <p className="placement-copy">Checking match state...</p>
      </div>
    )
  }
  if (state.kind === 'error') {
    return (
      <div className="placement-view">
        <p className="ct-label">Placement Failed</p>
        <div className="match-error" role="alert">
          <p>{state.message}</p>
        </div>
      </div>
    )
  }
  if (state.kind === 'waiting-for-opponent') {
    return (
      <div className="placement-view">
        <p className="ct-label">Placement Sealed</p>
        <p className="placement-copy">Your fleet is placed and encrypted. Waiting for your opponent to finish placing theirs.</p>
        <DecryptReadout text="AWAITING OPPONENT PLACEMENT" />
      </div>
    )
  }
  const stepLabel = placementStepLabel(state.detail)
  return (
    <div className="placement-view">
      <p className="ct-label">Placing Your Fleet</p>
      <p className="placement-copy">{stepLabel}</p>
      <DecryptReadout
        text={
          state.stage === 'revealing'
            ? 'DECRYPTING PLACEMENT ATTESTATION'
            : state.stage === 'confirming'
              ? 'CONFIRMING PLACEMENT'
              : 'ENCRYPTING FLEET POSITIONS'
        }
      />
      <p className="placement-note">
        Placement reveal can take up to about a minute while the covalidator attests your board. This only happens once.
      </p>
    </div>
  )
}

function DiceView({ state }: { state: DiceState }) {
  return (
    <div className="placement-view">
      <p className="ct-label">{state.kind === 'error' ? 'Dice Roll Failed' : 'Deciding First Move'}</p>
      {state.kind === 'error' ? (
        <div className="match-error" role="alert">
          <p>{state.message}</p>
        </div>
      ) : (
        <>
          <p className="placement-copy">Rolling dice to decide who fires first.</p>
          <DecryptReadout text="ROLLING DICE" />
        </>
      )}
    </div>
  )
}
