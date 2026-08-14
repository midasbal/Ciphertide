// Mirrors the constants on Ciphertide.sol. Keep these in sync with the
// contract if the fleet, board size, or skill areas ever change.
export const BOARD_SIZE = 15
export const SONAR_AREA_SIZE = 5
export const BARRAGE_AREA_SIZE = 4
export const BOMBARDMENT_AREA_SIZE = 10
export const CARPET_AREA_SIZE = 3
export const RAKE_ROW_LENGTH = 15
export const SALVO_CELL_COUNT = 3

export type SkillId = 'sonar' | 'barrage'

export const SKILL_AREA_SIZE: Record<SkillId, number> = {
  sonar: SONAR_AREA_SIZE,
  barrage: BARRAGE_AREA_SIZE,
}

/** Clamps a hovered/clicked cell into a valid top-left anchor so the full
 * areaSize x areaSize block always fits on the board. */
export function clampAnchor(cell: number, areaSize: number): number {
  return Math.min(Math.max(cell, 0), BOARD_SIZE - areaSize)
}

/** Every cell index set in a bit mask, bit i is cell i (row * BOARD_SIZE + col). */
export function maskToCells(mask: bigint): number[] {
  const cells: number[] = []
  for (let cell = 0; cell < BOARD_SIZE * BOARD_SIZE; cell++) {
    if ((mask & (1n << BigInt(cell))) !== 0n) cells.push(cell)
  }
  return cells
}

export interface ShipShape {
  cells: number[]
  row: number
  col: number
  length: number
  orientation: 'horizontal' | 'vertical'
}

/**
 * Groups a decrypted own-board mask into per-ship shapes for drawing hull
 * art. There is no per-ship placement exposed by the contract, only the
 * aggregate board mask, so this reconstructs ships as 4-directional
 * connected components of ship cells, then reads each component's
 * bounding box as one straight hull: wider than tall reads horizontal,
 * taller than wide reads vertical. Real ships are always a single
 * straight line, so this is exact as long as no two ships sit directly
 * adjacent to each other. If two ships DO abut, they flood-fill into one
 * connected component and this draws one longer hull across both, a
 * known, acceptable simplification for this pass rather than a bug: there
 * is no on-chain signal that would tell two abutting ships apart.
 */
export function deriveShips(boardMask: bigint): ShipShape[] {
  const isShip = (cell: number) => (boardMask & (1n << BigInt(cell))) !== 0n
  const visited = new Set<number>()
  const ships: ShipShape[] = []

  for (let cell = 0; cell < BOARD_SIZE * BOARD_SIZE; cell++) {
    if (!isShip(cell) || visited.has(cell)) continue

    const component: number[] = []
    const stack = [cell]
    visited.add(cell)
    while (stack.length > 0) {
      const current = stack.pop()!
      component.push(current)
      const r = Math.floor(current / BOARD_SIZE)
      const c = current % BOARD_SIZE
      const neighbors: number[] = []
      if (r > 0) neighbors.push(current - BOARD_SIZE)
      if (r < BOARD_SIZE - 1) neighbors.push(current + BOARD_SIZE)
      if (c > 0) neighbors.push(current - 1)
      if (c < BOARD_SIZE - 1) neighbors.push(current + 1)
      for (const neighbor of neighbors) {
        if (isShip(neighbor) && !visited.has(neighbor)) {
          visited.add(neighbor)
          stack.push(neighbor)
        }
      }
    }

    const rows = component.map((c) => Math.floor(c / BOARD_SIZE))
    const cols = component.map((c) => c % BOARD_SIZE)
    const minRow = Math.min(...rows)
    const maxRow = Math.max(...rows)
    const minCol = Math.min(...cols)
    const maxCol = Math.max(...cols)
    const width = maxCol - minCol + 1
    const height = maxRow - minRow + 1
    const orientation: 'horizontal' | 'vertical' = width >= height ? 'horizontal' : 'vertical'
    ships.push({
      cells: component,
      row: minRow,
      col: minCol,
      length: orientation === 'horizontal' ? width : height,
      orientation,
    })
  }

  return ships
}
