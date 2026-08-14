import { useEffect, useState } from 'react'
import CipherCell, { type CipherCellState } from '../cipher/CipherCell'
import CoordinateFrame from './CoordinateFrame'
import { BOARD_SIZE } from '../../lib/boardConstants'
import './EnemyBoard.css'

interface EnemyBoardProps {
  /** Known state per cell, from your own shots and skills this session
   * plus getShotsAgainst for cells shot in an earlier session (see
   * MatchScreen's own comment on that narrower gap). Any cell missing
   * from this map is still fully encrypted: hidden. */
  cellStates: Map<number, CipherCellState>
  /** Cells to highlight as the pending target area while aiming a skill,
   * before it fires. Purely a hover-preview affordance. */
  highlightCells?: Set<number>
  interactive?: boolean
  onSelectCell?: (cell: number) => void
}

export default function EnemyBoard({ cellStates, highlightCells, interactive, onSelectCell }: EnemyBoardProps) {
  // One shared idle tick drives every hidden cell's scramble glyph, a
  // single timer instead of 225 independent ones. Frozen for
  // prefers-reduced-motion: still obscured, just not flickering.
  const [tick, setTick] = useState(0)
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const id = window.setInterval(() => setTick((t) => t + 1), 130)
    return () => window.clearInterval(id)
  }, [])

  return (
    <CoordinateFrame size={BOARD_SIZE}>
      <div className="enemy-board" style={{ gridTemplateColumns: `repeat(${BOARD_SIZE}, 1fr)` }}>
        {Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, cell) => {
          const row = Math.floor(cell / BOARD_SIZE)
          const col = cell % BOARD_SIZE
          const state = cellStates.get(cell) ?? 'hidden'
          const isHighlighted = highlightCells?.has(cell) ?? false
          return (
            <div key={cell} className={isHighlighted ? 'enemy-cell-highlight' : undefined}>
              <CipherCell
                row={row}
                col={col}
                state={state}
                tick={tick}
                interactive={interactive && state === 'hidden'}
                onClick={() => onSelectCell?.(cell)}
              />
            </div>
          )
        })}
      </div>
    </CoordinateFrame>
  )
}
