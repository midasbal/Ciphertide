import './SkillsPanel.css'

export interface SkillEntry {
  id: string
  label: string
  description: string
  /** Can be armed right now: has its charge, and is not gas-capped. */
  usable: boolean
  used: boolean
  /** Shown in place of the description when usable is false and used is
   * also false, for example the gas-cap notice on Bombardment/Carpet. */
  unavailableReason?: string
}

interface SkillsPanelProps {
  skills: SkillEntry[]
  activeSkill: string | null
  onArm: (id: string) => void
  /** True when it is not this player's turn or an action is already in
   * flight: the whole panel goes inert rather than any one skill. */
  disabled: boolean
  /** A short status line under the skill list, for example "2/3 cells
   * selected" while aiming Salvo. */
  progressNote?: string
}

/**
 * The skill dock: one captain's unique strike plus the shared Sonar and
 * Barrage, each a real one-use charge against the deployed contract.
 * Bombardment and Carpet render as a clear unavailable state instead of
 * a working button, they currently exceed Base's per-transaction gas
 * cap and would revert (see game/client.ts's EXPLICIT_GAS_LIMITS
 * comment for the full sizing story).
 */
export default function SkillsPanel({ skills, activeSkill, onArm, disabled, progressNote }: SkillsPanelProps) {
  return (
    <div className="skills-panel">
      <div className="skills-panel-head">
        <p className="ct-label">Skills</p>
      </div>
      <div className="skills-list">
        {skills.map((skill) => {
          const isActive = activeSkill === skill.id
          const isClickable = skill.usable && !skill.used && !disabled
          const classes = ['skill-row']
          if (isActive) classes.push('skill-row--active')
          if (skill.used) classes.push('skill-row--used')
          if (!skill.usable && !skill.used) classes.push('skill-row--unavailable')
          return (
            <button
              key={skill.id}
              type="button"
              className={classes.join(' ')}
              disabled={!isClickable}
              onClick={() => onArm(skill.id)}
              aria-pressed={isActive}
            >
              <span className="skill-row-top">
                <span className="skill-row-label">{skill.label}</span>
                {skill.used && <span className="skill-row-tag ct-label">Used</span>}
                {!skill.usable && !skill.used && <span className="skill-row-tag skill-row-tag--unavailable ct-label">Unavailable</span>}
                {isActive && <span className="skill-row-tag skill-row-tag--active ct-label">Armed</span>}
              </span>
              <span className="skill-row-copy">{!skill.usable && !skill.used && skill.unavailableReason ? skill.unavailableReason : skill.description}</span>
            </button>
          )
        })}
      </div>
      {progressNote && (
        <div className="skills-progress ct-mono" role="status">
          {progressNote}
        </div>
      )}
    </div>
  )
}
