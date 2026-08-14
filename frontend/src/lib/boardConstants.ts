// Mirrors the constants on Ciphertide.sol. Keep these in sync with the
// contract if the fleet, board size, or skill areas ever change.
export const BOARD_SIZE = 15
export const SONAR_AREA_SIZE = 5
export const BARRAGE_AREA_SIZE = 4

export type SkillId = 'sonar' | 'barrage'

export const SKILL_AREA_SIZE: Record<SkillId, number> = {
  sonar: SONAR_AREA_SIZE,
  barrage: BARRAGE_AREA_SIZE,
}
