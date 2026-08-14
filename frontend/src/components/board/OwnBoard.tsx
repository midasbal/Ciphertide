import CoordinateFrame from './CoordinateFrame'
import { BOARD_SIZE } from '../../lib/boardConstants'
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

/** Your own waters: the fleet and mines you decrypted yourself, plus
 * whatever the opponent has already struck. Nothing here is encrypted
 * from you, it is only ever hidden from the opponent. */
export default function OwnBoard({ boardMask, mineMask, shotsAgainstMe, interactive, onSelectCell }: OwnBoardProps) {
  return (
    <CoordinateFrame size={BOARD_SIZE}>
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
    </CoordinateFrame>
  )
}
