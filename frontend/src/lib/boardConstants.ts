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
