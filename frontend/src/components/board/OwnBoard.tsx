import { useMemo } from 'react'
import CoordinateFrame from './CoordinateFrame'
import { BOARD_SIZE, deriveShips, type ShipShape } from '../../lib/boardConstants'
import './OwnBoard.css'

interface OwnBoardProps {
  /** Your decrypted fleet, bit i set means a ship occupies cell i. */
  boardMask: bigint
  /** Your decrypted mines, bit i set means a mine sits at cell i. */
  mineMask: bigint
  /** Cells the opponent has fired at, bit i set means cell i was shot. */
  shotsAgainstMe: bigint
  /** True while placing Shield: clicking one of your own hull cells
   * seals it, matching placeShield's own on-chain validation. */
  interactive?: boolean
  onSelectCell?: (cell: number) => void
}

// Cut a pointed hull polygon into a ship's bounding box, in board-unit
// (one SVG unit per cell) coordinates: a flat stern, a pointed bow, sized
// so the shape sits inset from its footprint's edges instead of filling
// the cells edge to edge.
function hullPolygonPoints(ship: ShipShape): string {
  const marginLong = 0.15
  const marginShort = 0.18
  const taperLen = Math.min(0.85, ship.length * 0.3)

  if (ship.orientation === 'horizontal') {
    const x0 = ship.col + marginLong
    const x1 = ship.col + ship.length - marginLong - taperLen
    const xBow = ship.col + ship.length - marginLong
    const yTop = ship.row + marginShort
    const yBot = ship.row + 1 - marginShort
    const yMid = ship.row + 0.5
    return [
      [x0, yTop],
      [x1, yTop],
      [xBow, yMid],
      [x1, yBot],
      [x0, yBot],
    ]
      .map((p) => p.join(','))
      .join(' ')
  }

  const y0 = ship.row + marginLong
  const y1 = ship.row + ship.length - marginLong - taperLen
  const yBow = ship.row + ship.length - marginLong
  const xLeft = ship.col + marginShort
  const xRight = ship.col + 1 - marginShort
  const xMid = ship.col + 0.5
  return [
    [xLeft, y0],
    [xLeft, y1],
    [xMid, yBow],
    [xRight, y1],
    [xRight, y0],
  ]
    .map((p) => p.join(','))
    .join(' ')
}

// A small deckhouse mark a third of the way back from the bow, purely
// decorative detail so a hull reads as a ship rather than a plain arrow.
function bridgeRect(ship: ShipShape): { x: number; y: number; w: number; h: number } {
  const size = 0.34
  if (ship.orientation === 'horizontal') {
    const x = ship.col + ship.length * 0.62 - size / 2
    const y = ship.row + 0.5 - size / 2
    return { x, y, w: size, h: size }
  }
  const x = ship.col + 0.5 - size / 2
  const y = ship.row + ship.length * 0.62 - size / 2
  return { x, y, w: size, h: size }
}

function ShipHull({ ship }: { ship: ShipShape }) {
  const bridge = bridgeRect(ship)
  return (
    <g className="ship-hull">
      <polygon className="ship-hull-body" points={hullPolygonPoints(ship)} />
      <rect className="ship-hull-bridge" x={bridge.x} y={bridge.y} width={bridge.w} height={bridge.h} rx={0.05} />
    </g>
  )
}

/** Your own waters: the fleet and mines you decrypted yourself, plus
 * whatever the opponent has already struck. Nothing here is encrypted
 * from you, it is only ever hidden from the opponent. Each ship is drawn
 * as a vector hull sized to its real length rather than a flat occupied
 * cell, see deriveShips for how the shapes are reconstructed from the
 * aggregate board mask. */
export default function OwnBoard({ boardMask, mineMask, shotsAgainstMe, interactive, onSelectCell }: OwnBoardProps) {
  const ships = useMemo(() => deriveShips(boardMask), [boardMask])

  return (
    <CoordinateFrame size={BOARD_SIZE}>
      <div className="own-board-stage">
        <svg
          className="own-board-hulls"
          viewBox={`0 0 ${BOARD_SIZE} ${BOARD_SIZE}`}
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          {ships.map((ship) => (
            <ShipHull key={ship.cells[0]} ship={ship} />
          ))}
        </svg>
        <div className="own-board" style={{ gridTemplateColumns: `repeat(${BOARD_SIZE}, 1fr)` }}>
          {Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, cell) => {
            const bit = 1n << BigInt(cell)
            const isShip = (boardMask & bit) !== 0n
            const isMine = (mineMask & bit) !== 0n
            const isStruck = (shotsAgainstMe & bit) !== 0n
            const isDamaged = isShip && isStruck
            const isStruckWater = !isShip && isStruck
            const row = Math.floor(cell / BOARD_SIZE)
            const col = cell % BOARD_SIZE
            const classes = ['own-cell']
            if (isShip) classes.push('own-cell--hull')
            if (isDamaged) classes.push('own-cell--damaged')
            if (isMine) classes.push('own-cell--mine')
            if (isStruckWater) classes.push('own-cell--struck')
            const canSelect = interactive && isShip
            return (
              <button
                type="button"
                key={cell}
                className={classes.join(' ')}
                disabled={!canSelect}
                onClick={() => canSelect && onSelectCell?.(cell)}
                aria-label={`${String.fromCharCode(65 + col)}${row + 1}${isShip ? ', your fleet' : isMine ? ', your mine' : ''}`}
              />
            )
          })}
        </div>
      </div>
    </CoordinateFrame>
  )
}
