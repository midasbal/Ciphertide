import CoordinateFrame from './CoordinateFrame'
import './OwnBoard.css'

const BOARD_SIZE = 15

function key(row: number, col: number) {
  return `${row}:${col}`
}

function horizontalRun(row: number, col: number, length: number): Array<[number, number]> {
  return Array.from({ length }, (_, i) => [row, col + i] as [number, number])
}

function verticalRun(row: number, col: number, length: number): Array<[number, number]> {
  return Array.from({ length }, (_, i) => [row + i, col] as [number, number])
}

// A stubbed fleet layout, lengths [5, 4, 4, 4, 3, 3], the same shape
// Ciphertide.sol's SHIP_LENGTHS deals for a real match. Fixed for the
// mockup, purely to demonstrate the decrypted own-board rendering.
const FLEET: Array<Array<[number, number]>> = [
  horizontalRun(2, 2, 5),
  verticalRun(1, 9, 4),
  horizontalRun(6, 1, 4),
  verticalRun(6, 12, 4),
  horizontalRun(10, 2, 3),
  verticalRun(10, 7, 3),
]

const OWN_MINES: Array<[number, number]> = [
  [4, 13],
  [13, 4],
]

// One segment of the flagship already took a hit this match, so damage
// on your own hull reads exactly like damage anywhere else: ember, hard.
const DAMAGED: [number, number] = [2, 4]
const STRUCK_WATER: Array<[number, number]> = [
  [0, 0],
  [7, 7],
  [11, 11],
]

export default function OwnBoard() {
  const shipCells = new Set(FLEET.flat().map(([r, c]) => key(r, c)))
  const mineCells = new Set(OWN_MINES.map(([r, c]) => key(r, c)))
  const damagedKey = key(...DAMAGED)
  const struckKeys = new Set(STRUCK_WATER.map(([r, c]) => key(r, c)))

  return (
    <CoordinateFrame size={BOARD_SIZE}>
      <div className="own-board" style={{ gridTemplateColumns: `repeat(${BOARD_SIZE}, 1fr)` }}>
        {Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, index) => {
          const row = Math.floor(index / BOARD_SIZE)
          const col = index % BOARD_SIZE
          const k = key(row, col)
          const isShip = shipCells.has(k)
          const isMine = mineCells.has(k)
          const isDamaged = k === damagedKey
          const isStruckWater = struckKeys.has(k)
          const classes = ['own-cell']
          if (isShip) classes.push('own-cell--hull')
          if (isDamaged) classes.push('own-cell--damaged')
          if (isMine) classes.push('own-cell--mine')
          if (isStruckWater) classes.push('own-cell--struck')
          return (
            <div
              key={k}
              className={classes.join(' ')}
              aria-label={`${String.fromCharCode(65 + col)}${row + 1}${isShip ? ', your fleet' : isMine ? ', your mine' : ''}`}
            />
          )
        })}
      </div>
    </CoordinateFrame>
  )
}
