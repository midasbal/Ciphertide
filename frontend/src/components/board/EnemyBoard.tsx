import { useEffect, useRef, useState } from 'react'
import CipherCell, { type CipherCellState } from '../cipher/CipherCell'
import CoordinateFrame from './CoordinateFrame'
import './EnemyBoard.css'

const BOARD_SIZE = 15

function key(row: number, col: number) {
  return `${row}:${col}`
}

// Stubbed fog-of-war state for the sample screen: everything unknown by
// default, a handful of cells already resolved from earlier shots this
// match, and one cell that continuously replays the decrypt cycle so the
// motif is visibly alive on the page rather than a single static frame.
const STATIC_MISSES: Array<[number, number]> = [
  [1, 2],
  [2, 11],
  [4, 4],
  [6, 13],
  [8, 1],
  [9, 9],
  [12, 3],
  [13, 12],
]
const STATIC_HITS: Array<[number, number]> = [
  [3, 8],
  [10, 5],
]
const STATIC_MINE: [number, number] = [5, 9]
const DEMO_CELL: [number, number] = [7, 6]

const DEMO_SEQUENCE: Array<{ state: CipherCellState; holdMs: number }> = [
  { state: 'hidden', holdMs: 3400 },
  { state: 'decrypting', holdMs: 640 },
  { state: 'hit', holdMs: 2600 },
  { state: 'hidden', holdMs: 2200 },
  { state: 'decrypting', holdMs: 640 },
  { state: 'miss', holdMs: 2600 },
]

interface EnemyBoardProps {
  onSelectCell?: (row: number, col: number) => void
  interactive?: boolean
}

export default function EnemyBoard({ onSelectCell, interactive }: EnemyBoardProps) {
  // One shared idle tick drives every hidden cell's scramble glyph, a
  // single timer instead of 225 independent ones.
  const [tick, setTick] = useState(0)
  useEffect(() => {
    const id = window.setInterval(() => setTick((t) => t + 1), 130)
    return () => window.clearInterval(id)
  }, [])

  // The demo cell loops through the full decrypt cycle on its own clock
  // so the reveal motion is actually playing when this screen is viewed,
  // not just described.
  const [demoIndex, setDemoIndex] = useState(0)
  const timeoutRef = useRef<number | undefined>(undefined)
  useEffect(() => {
    const step = DEMO_SEQUENCE[demoIndex]
    timeoutRef.current = window.setTimeout(() => {
      setDemoIndex((i) => (i + 1) % DEMO_SEQUENCE.length)
    }, step.holdMs)
    return () => window.clearTimeout(timeoutRef.current)
  }, [demoIndex])

  const missSet = new Set(STATIC_MISSES.map(([r, c]) => key(r, c)))
  const hitSet = new Set(STATIC_HITS.map(([r, c]) => key(r, c)))
  const mineKey = key(...STATIC_MINE)
  const demoKey = key(...DEMO_CELL)
  const demoState = DEMO_SEQUENCE[demoIndex].state

  function stateFor(row: number, col: number): CipherCellState {
    const k = key(row, col)
    if (k === demoKey) return demoState
    if (k === mineKey) return 'mine'
    if (hitSet.has(k)) return 'hit'
    if (missSet.has(k)) return 'miss'
    return 'hidden'
  }

  return (
    <CoordinateFrame size={BOARD_SIZE}>
      <div className="enemy-board" style={{ gridTemplateColumns: `repeat(${BOARD_SIZE}, 1fr)` }}>
        {Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, index) => {
          const row = Math.floor(index / BOARD_SIZE)
          const col = index % BOARD_SIZE
          const state = stateFor(row, col)
          const k = key(row, col)
          return (
            <CipherCell
              key={k === demoKey ? `${k}:${demoState}` : k}
              row={row}
              col={col}
              state={state}
              tick={tick}
              interactive={interactive && state === 'hidden'}
              onClick={() => onSelectCell?.(row, col)}
            />
          )
        })}
      </div>
    </CoordinateFrame>
  )
}
