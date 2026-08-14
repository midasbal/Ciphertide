import DecryptReadout from '../cipher/DecryptReadout'
import './StatusDivider.css'

interface ClockProps {
  label: string
  seconds: number
  running: boolean
  isTurn: boolean
}

function formatClock(totalSeconds: number): string {
  const clamped = Math.max(0, Math.round(totalSeconds))
  const m = Math.floor(clamped / 60)
  const s = clamped % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

function Clock({ label, seconds, running, isTurn }: ClockProps) {
  const low = seconds <= 30
  return (
    <div className={`match-clock${isTurn ? ' match-clock--turn' : ''}${low ? ' match-clock--low' : ''}`}>
      <span className="ct-label">{label}</span>
      <span className="match-clock-value ct-mono">{formatClock(seconds)}</span>
      {running && <span className="match-clock-live" aria-hidden="true" />}
    </div>
  )
}

interface StatusDividerProps {
  phaseLabel: string
  turnLabel: string
  myLabel: string
  opponentLabel: string
  mySeconds: number
  opponentSeconds: number
  myClockRunning: boolean
  opponentClockRunning: boolean
  readoutText: string | null
}

/**
 * The seam between the two maps: not empty space, the live instrument
 * cluster that makes this read as one console instead of two stacked
 * grids. Turn, both chess clocks, phase, and the last-action reveal
 * beat all live here.
 */
export default function StatusDivider({
  phaseLabel,
  turnLabel,
  myLabel,
  opponentLabel,
  mySeconds,
  opponentSeconds,
  myClockRunning,
  opponentClockRunning,
  readoutText,
}: StatusDividerProps) {
  return (
    <div className="status-divider">
      <div className="status-divider-row">
        <div className="status-divider-item">
          <span className="ct-label">Phase</span>
          <span className="status-divider-value">{phaseLabel}</span>
        </div>
        <div className="status-divider-item">
          <span className="ct-label">Turn</span>
          <span className="status-divider-value status-divider-value--accent">{turnLabel}</span>
        </div>
      </div>

      <div className="status-divider-clocks">
        <Clock label={opponentLabel} seconds={opponentSeconds} running={opponentClockRunning} isTurn={opponentClockRunning} />
        <span className="status-divider-clock-glyph" aria-hidden="true">
          &#8225;
        </span>
        <Clock label={myLabel} seconds={mySeconds} running={myClockRunning} isTurn={myClockRunning} />
      </div>

      {readoutText && (
        <div className="status-divider-readout">
          <DecryptReadout text={readoutText} />
        </div>
      )}
    </div>
  )
}
