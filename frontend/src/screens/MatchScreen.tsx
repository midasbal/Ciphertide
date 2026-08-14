import { useParams } from 'react-router-dom'
import DecryptReadout from '../components/cipher/DecryptReadout'
import OwnBoard from '../components/board/OwnBoard'
import EnemyBoard from '../components/board/EnemyBoard'
import './MatchScreen.css'

const SKILLS: Array<{ id: string; label: string; charges: number }> = [
  { id: 'sonar', label: 'Sonar', charges: 1 },
  { id: 'barrage', label: 'Barrage', charges: 1 },
  { id: 'rake', label: 'Rake', charges: 1 },
]

const LOG_LINES = [
  { text: 'A7 // NO CONTACT', tone: 'miss' as const },
  { text: 'D11 // CONTACT, HULL BREACH', tone: 'hit' as const },
  { text: 'C4 // NO CONTACT', tone: 'miss' as const },
  { text: 'AWAITING COVALIDATOR ATTESTATION', tone: 'live' as const },
]

/**
 * The in-match view, Ciphertide's identity working hardest: your own
 * decrypted waters on one side, the enemy's encrypted fog of war on the
 * other, a live shot resolving in real time. The board and skill data
 * here is still a static mockup, no contract or wallet reads yet, only
 * the match id in the header comes from the real route.
 */
export default function MatchScreen() {
  const { matchId } = useParams<{ matchId: string }>()

  return (
    <div className="match-screen">
      <div className="ct-scanlines" aria-hidden="true" />

      <header className="console-header">
        <div className="wordmark">
          <span className="wordmark-glyph" aria-hidden="true">
            ‡
          </span>
          <span className="wordmark-text">CIPHERTIDE</span>
        </div>
        <div className="console-header-meta ct-mono">
          <span className="ct-label">MATCH</span>
          <span>{matchId}</span>
        </div>
      </header>

      <div className="status-bar">
        <div className="status-item">
          <span className="ct-label">Phase</span>
          <span className="status-value status-value--live">IN PROGRESS</span>
        </div>
        <div className="status-item">
          <span className="ct-label">Turn</span>
          <span className="status-value status-value--accent">YOUR TURN</span>
        </div>
        <div className="status-item">
          <span className="ct-label">Clock</span>
          <span className="status-value ct-mono">04:12</span>
        </div>
        <div className="status-item">
          <span className="ct-label">Captain</span>
          <span className="status-value">RAKE</span>
        </div>
      </div>

      <main className="board-theater">
        <section className="board-panel" aria-label="Your waters">
          <div className="board-panel-head">
            <h2>Your Waters</h2>
            <span className="ct-label">decrypted, yours to see</span>
          </div>
          <OwnBoard />
        </section>

        <section className="board-panel board-panel--enemy" aria-label="Enemy waters">
          <div className="board-panel-head">
            <h2>Enemy Waters</h2>
            <span className="ct-label">encrypted until you fire</span>
          </div>
          <div className="enemy-panel-body">
            <div className="sonar-sweep" aria-hidden="true" />
            <EnemyBoard />
          </div>
          <DecryptReadout text="DECRYPTING ENEMY WATERS // G7" />
        </section>
      </main>

      <footer className="console-footer">
        <div className="skill-dock">
          {SKILLS.map((skill) => (
            <div key={skill.id} className="skill-chip">
              <span className="skill-chip-label">{skill.label}</span>
              <span className="skill-chip-charge ct-mono">{skill.charges}</span>
            </div>
          ))}
        </div>
        <div className="sonar-log ct-mono" aria-label="Sonar log">
          {LOG_LINES.map((line, i) => (
            <span key={i} className={`sonar-log-line sonar-log-line--${line.tone}`}>
              {line.text}
            </span>
          ))}
        </div>
      </footer>
    </div>
  )
}
