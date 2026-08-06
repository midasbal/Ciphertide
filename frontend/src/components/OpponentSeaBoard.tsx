import { useMemo, useState } from 'react'
import { BOARD_SIZE, SKILL_AREA_SIZE, type SkillId } from '../lib/boardConstants'
import './OpponentSeaBoard.css'

type SkillCharges = Record<SkillId, number>

const SKILL_LABEL: Record<SkillId, string> = {
  sonar: 'Sonar',
  barrage: 'Barrage',
}

interface OpponentSeaBoardProps {
  /** Starting charge count per skill, both skills are 1 use per match. */
  initialCharges?: SkillCharges
  /**
   * Called when the player commits a skill on a cell. Anchor is already
   * clamped so the full area fits on the board, matching what the
   * contract's useSonar/useBarrage expect.
   */
  onUseSkill?: (skill: SkillId, anchorRow: number, anchorCol: number) => void
}

/** Clamps a hovered/clicked cell into a valid top-left anchor so the full
 * areaSize x areaSize block always fits on the board. */
function clampAnchor(cell: number, areaSize: number): number {
  return Math.min(Math.max(cell, 0), BOARD_SIZE - areaSize)
}

export default function OpponentSeaBoard({
  initialCharges = { sonar: 1, barrage: 1 },
  onUseSkill,
}: OpponentSeaBoardProps) {
  const [charges, setCharges] = useState<SkillCharges>(initialCharges)
  const [selectedSkill, setSelectedSkill] = useState<SkillId | null>(null)
  const [hovered, setHovered] = useState<{ row: number; col: number } | null>(null)

  const anchor = useMemo(() => {
    if (!selectedSkill || !hovered) return null
    const areaSize = SKILL_AREA_SIZE[selectedSkill]
    return {
      row: clampAnchor(hovered.row, areaSize),
      col: clampAnchor(hovered.col, areaSize),
      areaSize,
    }
  }, [selectedSkill, hovered])

  function isHighlighted(row: number, col: number): boolean {
    if (!anchor) return false
    return (
      row >= anchor.row &&
      row < anchor.row + anchor.areaSize &&
      col >= anchor.col &&
      col < anchor.col + anchor.areaSize
    )
  }

  function handleSelectSkill(skill: SkillId) {
    if (charges[skill] <= 0) return
    setSelectedSkill((current) => (current === skill ? null : skill))
  }

  function handleCellClick(row: number, col: number) {
    if (!selectedSkill || charges[selectedSkill] <= 0) return
    const areaSize = SKILL_AREA_SIZE[selectedSkill]
    const anchorRow = clampAnchor(row, areaSize)
    const anchorCol = clampAnchor(col, areaSize)

    onUseSkill?.(selectedSkill, anchorRow, anchorCol)
    setCharges((current) => ({ ...current, [selectedSkill]: current[selectedSkill] - 1 }))
    setSelectedSkill(null)
    setHovered(null)
  }

  return (
    <div className="opponent-sea-board">
      <div className="skill-bar">
        {(Object.keys(SKILL_LABEL) as SkillId[]).map((skill) => (
          <button
            key={skill}
            type="button"
            className={`skill-button${selectedSkill === skill ? ' skill-button-active' : ''}`}
            disabled={charges[skill] <= 0}
            onClick={() => handleSelectSkill(skill)}
          >
            {SKILL_LABEL[skill]}
            <span className="skill-charge">{charges[skill]}</span>
          </button>
        ))}
      </div>

      <div
        className="sea-grid"
        style={{ gridTemplateColumns: `repeat(${BOARD_SIZE}, 1fr)` }}
        onMouseLeave={() => setHovered(null)}
      >
        {Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, index) => {
          const row = Math.floor(index / BOARD_SIZE)
          const col = index % BOARD_SIZE
          return (
            <button
              key={index}
              type="button"
              className={`sea-cell${isHighlighted(row, col) ? ' sea-cell-highlighted' : ''}`}
              onMouseEnter={() => selectedSkill && setHovered({ row, col })}
              onClick={() => handleCellClick(row, col)}
              aria-label={`row ${row}, column ${col}`}
            />
          )
        })}
      </div>
    </div>
  )
}
