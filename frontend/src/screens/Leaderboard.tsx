import { useMemo, useState } from 'react'
import Reveal from '../components/reveal/Reveal'
import DecryptReadout from '../components/cipher/DecryptReadout'
import SonarBackdrop from '../components/hero/SonarBackdrop'
import { FLEET_ACTIVITY, RECENT_ENGAGEMENTS, getStandings, type LeaderboardPeriod } from './leaderboardMock'
import './Leaderboard.css'

const PERIODS: Array<{ key: LeaderboardPeriod; label: string }> = [
  { key: 'allTime', label: 'All-time' },
  { key: 'season', label: 'Season' },
  { key: 'week', label: 'Week' },
]

export default function Leaderboard() {
  const [period, setPeriod] = useState<LeaderboardPeriod>('allTime')
  const standings = useMemo(() => getStandings(period), [period])
  const you = standings.find((row) => row.isYou)

  return (
    <div className="leaderboard">
      <div className="ct-scanlines" aria-hidden="true" />

      <header className="leaderboard-nav">
        <a className="leaderboard-nav-mark" href="/">
          <span className="leaderboard-nav-glyph" aria-hidden="true">
            &#8225;
          </span>
          <span>CIPHERTIDE</span>
        </a>
        <nav className="leaderboard-nav-links ct-mono" aria-label="Primary">
          <a href="/">Home</a>
          <a href="/?screen=match">Console</a>
        </nav>
      </header>

      <main className="leaderboard-main">
        <div className="leaderboard-console-frame">
          <span className="console-corner console-corner--tl" aria-hidden="true" />
          <span className="console-corner console-corner--tr" aria-hidden="true" />
          <span className="console-corner console-corner--bl" aria-hidden="true" />
          <span className="console-corner console-corner--br" aria-hidden="true" />

          <Reveal as="div" className="leaderboard-rail leaderboard-rail--command" delayMs={0}>
            <p className="ct-label">Your Command</p>
            <div className="command-flourish" aria-hidden="true">
              <svg viewBox="0 0 64 64">
                <circle cx="32" cy="32" r="10" />
                <circle cx="32" cy="32" r="20" />
                <circle cx="32" cy="32" r="29" />
                <line x1="32" y1="2" x2="32" y2="10" />
                <line x1="32" y1="54" x2="32" y2="62" />
                <line x1="2" y1="32" x2="10" y2="32" />
                <line x1="54" y1="32" x2="62" y2="32" />
              </svg>
              <span className="command-flourish-dot" />
            </div>
            <p className="command-callsign">KESTREL</p>
            <p className="command-address ct-mono">0x83e2...17c9</p>

            {you && (
              <div className="command-stats">
                <div className="command-rank">
                  <span className="command-rank-label ct-label">Rank</span>
                  <span className="command-rank-number ct-mono">{String(you.rank).padStart(2, '0')}</span>
                </div>
                <div className="command-readout-row">
                  <span className="command-readout-label ct-label">Record</span>
                  <span className="command-readout-value ct-mono">
                    {you.wins}-{you.losses}
                  </span>
                </div>
                <div className="command-readout-row">
                  <span className="command-readout-label ct-label">Win rate</span>
                  <span className="command-readout-value ct-mono">{you.winRate}%</span>
                </div>
                <div className="command-readout-row">
                  <span className="command-readout-label ct-label">Streak</span>
                  <span className="command-readout-value ct-mono">{you.streak}</span>
                </div>
              </div>
            )}
          </Reveal>

          <Reveal as="section" className="leaderboard-core" delayMs={80}>
            <div className="leaderboard-core-header">
              <div className="leaderboard-core-header-backdrop" aria-hidden="true">
                <SonarBackdrop />
              </div>
              <div className="leaderboard-core-header-content">
                <p className="ct-label">Standings // Base Sepolia</p>
                <h1 className="leaderboard-core-title">The Admiralty</h1>
                <p className="leaderboard-core-sub">Ranked by record. Sample standings, testnet preview.</p>
                <div className="leaderboard-core-readout">
                  <DecryptReadout text="SAMPLE DATA // TESTNET PREVIEW" />
                </div>
              </div>
            </div>

            <div className="leaderboard-segmented" role="tablist" aria-label="Standings period">
              {PERIODS.map((p) => (
                <button
                  key={p.key}
                  type="button"
                  role="tab"
                  aria-selected={period === p.key}
                  className={`leaderboard-segmented-btn${period === p.key ? ' leaderboard-segmented-btn--active' : ''}`}
                  onClick={() => setPeriod(p.key)}
                >
                  {p.label}
                </button>
              ))}
            </div>

            <div className="leaderboard-table-scroll">
              <div className="leaderboard-table" role="table" aria-label="Fleet standings">
                <div className="leaderboard-row leaderboard-row--head" role="row">
                  <span className="leaderboard-cell leaderboard-cell--rank" role="columnheader">
                    Rank
                  </span>
                  <span className="leaderboard-cell leaderboard-cell--callsign" role="columnheader">
                    Callsign
                  </span>
                  <span className="leaderboard-cell leaderboard-cell--num" role="columnheader">
                    W
                  </span>
                  <span className="leaderboard-cell leaderboard-cell--num" role="columnheader">
                    L
                  </span>
                  <span className="leaderboard-cell leaderboard-cell--num" role="columnheader">
                    Win rate
                  </span>
                  <span className="leaderboard-cell leaderboard-cell--num" role="columnheader">
                    Streak
                  </span>
                </div>

                {standings.map((row) => (
                  <div
                    key={row.address}
                    className={`leaderboard-row${row.rank <= 3 ? ' leaderboard-row--top' : ''}${row.isYou ? ' leaderboard-row--you' : ''}`}
                    role="row"
                  >
                    <span className="leaderboard-cell leaderboard-cell--rank" role="cell">
                      <span className="leaderboard-rank-number ct-mono">{String(row.rank).padStart(2, '0')}</span>
                    </span>
                    <span className="leaderboard-cell leaderboard-cell--callsign" role="cell">
                      <span className="leaderboard-callsign-row">
                        <span className="leaderboard-callsign">{row.callsign}</span>
                        {row.isYou && <span className="leaderboard-you-tag ct-label">You</span>}
                      </span>
                      <span className="leaderboard-address ct-mono">{row.address}</span>
                    </span>
                    <span className="leaderboard-cell leaderboard-cell--num ct-mono" role="cell">
                      {row.wins}
                    </span>
                    <span className="leaderboard-cell leaderboard-cell--num ct-mono" role="cell">
                      {row.losses}
                    </span>
                    <span
                      className="leaderboard-cell leaderboard-cell--num ct-mono leaderboard-cell--rate"
                      role="cell"
                    >
                      {row.winRate}%
                    </span>
                    <span className="leaderboard-cell leaderboard-cell--num ct-mono" role="cell">
                      {row.streak}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </Reveal>

          <Reveal as="div" className="leaderboard-rail leaderboard-rail--side" delayMs={160}>
            <div className="side-panel">
              <p className="ct-label">Fleet Activity</p>
              <div className="side-activity-list">
                {FLEET_ACTIVITY.map((stat) => (
                  <div key={stat.label} className="side-activity-row">
                    <div className="side-activity-labels">
                      <span className="side-activity-label">{stat.label}</span>
                      <span className="side-activity-value ct-mono">{stat.value}</span>
                    </div>
                    <div className="side-activity-meter">
                      <div className="side-activity-meter-fill" style={{ width: `${stat.meterPercent}%` }} />
                    </div>
                  </div>
                ))}
              </div>
            </div>

            <div className="side-panel">
              <p className="ct-label">Recent Engagements</p>
              <div className="side-engagements-list">
                {RECENT_ENGAGEMENTS.map((line) => (
                  <div key={line} className="side-engagement-row">
                    <DecryptReadout text={line} />
                  </div>
                ))}
              </div>
            </div>
          </Reveal>
        </div>
      </main>

      <footer className="leaderboard-footer ct-mono">
        <span>Built on Base. Sealed by Inco.</span>
        <span>Base Sepolia testnet &middot; No mainnet deployment</span>
      </footer>
    </div>
  )
}
