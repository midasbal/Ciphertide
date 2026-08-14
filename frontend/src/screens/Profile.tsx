import { useState } from 'react'
import Reveal from '../components/reveal/Reveal'
import SonarBackdrop from '../components/hero/SonarBackdrop'
import CaptainMark from '../components/captains/CaptainMark'
import { CAPTAINS, type Captain } from './captains'
import './Profile.css'

const STORAGE_KEYS = {
  selected: 'ciphertide.profile.selectedCaptainId',
  unlocked: 'ciphertide.profile.unlockedCaptainIds',
  salvage: 'ciphertide.profile.salvageBalance',
}

const DEFAULT_SELECTED_ID = 1
const DEFAULT_UNLOCKED_IDS = CAPTAINS.filter((c) => c.unlockedByDefault).map((c) => c.id)
const DEFAULT_SALVAGE = 1000

function persist(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // localStorage may be unavailable (private mode, disabled storage), state
    // still updates in memory for the rest of the session.
  }
}

function readSelectedId(): number {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEYS.selected)
    if (raw === null) return DEFAULT_SELECTED_ID
    const parsed = Number(raw)
    return Number.isInteger(parsed) ? parsed : DEFAULT_SELECTED_ID
  } catch {
    return DEFAULT_SELECTED_ID
  }
}

function readUnlockedIds(): number[] {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEYS.unlocked)
    if (raw === null) return DEFAULT_UNLOCKED_IDS
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed) || !parsed.every((n) => Number.isInteger(n))) return DEFAULT_UNLOCKED_IDS
    return parsed
  } catch {
    return DEFAULT_UNLOCKED_IDS
  }
}

function readSalvage(): number {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEYS.salvage)
    if (raw === null) return DEFAULT_SALVAGE
    const parsed = Number(raw)
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : DEFAULT_SALVAGE
  } catch {
    return DEFAULT_SALVAGE
  }
}

/**
 * Captain select. Off-chain and local: the contract stores no profile or
 * currency state, so the selected captain, the unlocked set and the
 * Salvage balance are all read from and written back to localStorage.
 * Earning Salvage from matches is not wired up yet, the seeded balance
 * here is a preview economy, not a live total.
 */
export default function Profile() {
  const [selectedId, setSelectedId] = useState<number>(readSelectedId)
  const [unlockedIds, setUnlockedIds] = useState<number[]>(readUnlockedIds)
  const [salvage, setSalvage] = useState<number>(readSalvage)

  function handleSelect(captain: Captain) {
    if (!unlockedIds.includes(captain.id)) return
    setSelectedId(captain.id)
    persist(STORAGE_KEYS.selected, String(captain.id))
  }

  function handleUnlock(captain: Captain) {
    if (unlockedIds.includes(captain.id) || salvage < captain.cost) return
    const nextSalvage = salvage - captain.cost
    const nextUnlocked = [...unlockedIds, captain.id]
    setSalvage(nextSalvage)
    setUnlockedIds(nextUnlocked)
    persist(STORAGE_KEYS.salvage, String(nextSalvage))
    persist(STORAGE_KEYS.unlocked, JSON.stringify(nextUnlocked))
  }

  return (
    <div className="profile">
      <div className="ct-scanlines" aria-hidden="true" />

      <header className="profile-nav">
        <a className="profile-nav-mark" href="/">
          <span className="profile-nav-glyph" aria-hidden="true">
            &#8225;
          </span>
          <span>CIPHERTIDE</span>
        </a>
        <nav className="profile-nav-links ct-mono" aria-label="Primary">
          <a href="/">Home</a>
          <a href="/?screen=leaderboard">Leaderboard</a>
          <a href="/?screen=match">Console</a>
        </nav>
      </header>

      <main className="profile-main">
        <div className="profile-console-frame">
          <span className="profile-corner profile-corner--tl" aria-hidden="true" />
          <span className="profile-corner profile-corner--tr" aria-hidden="true" />
          <span className="profile-corner profile-corner--bl" aria-hidden="true" />
          <span className="profile-corner profile-corner--br" aria-hidden="true" />

          <Reveal as="div" className="profile-header" delayMs={0}>
            <div className="profile-header-backdrop" aria-hidden="true">
              <SonarBackdrop />
            </div>
            <div className="profile-header-content">
              <div className="profile-header-text">
                <p className="ct-label">Fleet Command // Base Sepolia</p>
                <h1 className="profile-title">Command Roster</h1>
                <p className="profile-sub">
                  Every captain carries Sonar and Barrage. Pick the one whose signature strike fits your fleet.
                </p>
              </div>
              <div className="profile-salvage">
                <span className="ct-label profile-salvage-label">
                  Salvage <span className="profile-salvage-preview">// preview</span>
                </span>
                <span className="profile-salvage-value ct-mono">{salvage.toLocaleString('en-US')}</span>
              </div>
            </div>
          </Reveal>

          <div className="profile-grid">
            {CAPTAINS.map((captain, i) => {
              const isUnlocked = unlockedIds.includes(captain.id)
              const isSelected = selectedId === captain.id
              return (
                <Reveal
                  key={captain.id}
                  delayMs={i * 70}
                  className={`captain-card${isSelected ? ' captain-card--selected' : ''}${isUnlocked ? '' : ' captain-card--locked'}`}
                >
                  <CaptainCard
                    captain={captain}
                    isSelected={isSelected}
                    isUnlocked={isUnlocked}
                    salvage={salvage}
                    onSelect={handleSelect}
                    onUnlock={handleUnlock}
                  />
                </Reveal>
              )
            })}
          </div>
        </div>
      </main>

      <footer className="profile-footer ct-mono">
        <span>Built on Base. Sealed by Inco.</span>
        <span>Base Sepolia testnet &middot; No mainnet deployment</span>
      </footer>
    </div>
  )
}

function CaptainCard({
  captain,
  isSelected,
  isUnlocked,
  salvage,
  onSelect,
  onUnlock,
}: {
  captain: Captain
  isSelected: boolean
  isUnlocked: boolean
  salvage: number
  onSelect: (captain: Captain) => void
  onUnlock: (captain: Captain) => void
}) {
  const canAfford = salvage >= captain.cost

  return (
    <>
      <button
        type="button"
        className="captain-card-portrait-btn"
        onClick={() => onSelect(captain)}
        disabled={!isUnlocked}
        aria-pressed={isSelected}
        aria-label={`${isSelected ? 'Selected' : 'Select'} ${captain.name}, ${captain.code} ${captain.skillName}`}
      >
        <CaptainPortrait captain={captain} />
        {!isUnlocked && (
          <span className="captain-card-lock-badge ct-mono">
            <LockGlyph />
            LOCKED
          </span>
        )}
        {isSelected && <span className="captain-card-selected-tag ct-label">Selected</span>}
      </button>

      <div className="captain-card-meta">
        <h3 className="captain-card-name">{captain.name}</h3>
        <span className="ct-mono captain-card-label">
          {captain.code} // {captain.skillName.toUpperCase()}
        </span>
        <p className="captain-card-description">{captain.description}</p>
        <div className="captain-card-tags">
          <span className="captain-card-tag ct-label">Sonar</span>
          <span className="captain-card-tag ct-label">Barrage</span>
        </div>

        {!isUnlocked && (
          <div className="captain-card-unlock">
            <span className="captain-card-cost ct-mono">{captain.cost.toLocaleString('en-US')} Salvage</span>
            <button
              type="button"
              className="captain-card-unlock-btn"
              onClick={() => onUnlock(captain)}
              disabled={!canAfford}
            >
              Unlock
            </button>
          </div>
        )}
      </div>
    </>
  )
}

/**
 * The portrait frame. Renders the real captain portrait; the
 * `captain-portrait-placeholder` layer (a per-captain vector sigil over
 * sonar rings, built entirely from design tokens) only shows if the
 * image fails to load, so the frame never goes blank.
 */
function CaptainPortrait({ captain }: { captain: Captain }) {
  const [imageFailed, setImageFailed] = useState(false)

  return (
    <div className="captain-portrait">
      {imageFailed ? (
        <div className="captain-portrait-placeholder">
          <svg
            viewBox="0 0 120 120"
            className="captain-portrait-rings"
            style={{ transform: `rotate(${(captain.id - 1) * 23}deg)` }}
            aria-hidden="true"
          >
            <circle cx="60" cy="60" r="30" />
            <circle cx="60" cy="60" r="46" />
            <circle cx="60" cy="60" r="58" />
            <line x1="60" y1="2" x2="60" y2="14" />
            <line x1="60" y1="106" x2="60" y2="118" />
            <line x1="2" y1="60" x2="14" y2="60" />
            <line x1="106" y1="60" x2="118" y2="60" />
          </svg>
          <CaptainMark kind={captain.mark} className="captain-portrait-mark" />
        </div>
      ) : (
        <img
          className="captain-portrait-image"
          src={captain.portrait}
          alt={captain.name}
          onError={() => setImageFailed(true)}
        />
      )}
    </div>
  )
}

function LockGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="captain-card-lock-glyph" aria-hidden="true">
      <rect x="5" y="11" width="14" height="10" rx="1.5" />
      <path d="M8 11 V8 a4 4 0 0 1 8 0 v3" fill="none" />
    </svg>
  )
}
