import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import SonarBackdrop from '../components/hero/SonarBackdrop'
import Reveal from '../components/reveal/Reveal'
import { getGameClient } from '../lib/gameClient'
import { getSigner } from '../lib/signer'
import type { CiphertideClient, MatchId } from '../game'
import './Lobby.css'

// Same key Profile.tsx persists the captain-select screen's choice
// under. The lobby does not offer its own captain picker, it just uses
// whatever the player last chose on the profile page, defaulting to the
// starter captain the same way Profile.tsx does.
const SELECTED_CAPTAIN_KEY = 'ciphertide.profile.selectedCaptainId'
const DEFAULT_CAPTAIN_ID = 1

function getSelectedCaptainId(): number {
  try {
    const raw = window.localStorage.getItem(SELECTED_CAPTAIN_KEY)
    if (raw === null) return DEFAULT_CAPTAIN_ID
    const parsed = Number(raw)
    return Number.isInteger(parsed) ? parsed : DEFAULT_CAPTAIN_ID
  } catch {
    return DEFAULT_CAPTAIN_ID
  }
}

const SIGNER_UNAVAILABLE_MESSAGE =
  'Wallet not available yet. Signing goes through a placeholder seam until the play-wallet layer lands.'

type HostState =
  | { status: 'idle' }
  | { status: 'creating' }
  | { status: 'waiting'; matchId: MatchId }
  | { status: 'error'; message: string }

type JoinState = { status: 'idle' } | { status: 'joining' } | { status: 'error'; message: string }

function parseJoinCode(raw: string): { matchId: MatchId } | { error: string } {
  const trimmed = raw.trim()
  if (!trimmed) return { error: 'Enter a match code first.' }
  if (!/^\d+$/.test(trimmed)) return { error: 'That code does not look right. Match codes are numbers only.' }
  const matchId = BigInt(trimmed)
  if (matchId < 1n) return { error: 'That code does not look right. Match codes start at 1.' }
  return { matchId }
}

function describeJoinFailure(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err)
  if (message.includes('cannot play yourself')) return 'You cannot join your own match.'
  if (message.includes('invalid captain id')) return 'Your selected captain is not valid. Pick one on the profile page.'
  return 'Could not join that match. Try again in a moment.'
}

/**
 * The lobby: host a duel and share its join code, or join one with a
 * code from an opponent. Wired to the real CiphertideClient.createMatch
 * and joinMatch, through the getGameClient seam, no simulated success
 * states. See getSigner in lib/signer.ts for why signing can honestly
 * be unavailable right now.
 */
export default function Lobby() {
  const navigate = useNavigate()
  const [hostState, setHostState] = useState<HostState>({ status: 'idle' })
  const [joinCode, setJoinCode] = useState('')
  const [joinState, setJoinState] = useState<JoinState>({ status: 'idle' })
  const [copyLabel, setCopyLabel] = useState('Copy')
  const hostClientRef = useRef<CiphertideClient | null>(null)

  // No play-wallet and no explicit dev override means there is nothing
  // to sign with, send the player to enlist first rather than showing a
  // lobby that can never actually create or join anything.
  useEffect(() => {
    if (!getSigner()) navigate('/register', { replace: true })
  }, [navigate])

  useEffect(() => {
    if (hostState.status !== 'waiting') return
    const client = hostClientRef.current
    if (!client) return

    const matchId = hostState.matchId
    let cancelled = false

    const poll = async () => {
      try {
        const phase = await client.getPhase(matchId)
        if (!cancelled && phase !== 0 /* WaitingForOpponent */) {
          navigate(`/match/${matchId}`)
        }
      } catch {
        // A transient read error, the next tick tries again.
      }
    }

    const id = window.setInterval(poll, 3000)
    return () => {
      cancelled = true
      window.clearInterval(id)
    }
  }, [hostState, navigate])

  async function handleCreate() {
    setHostState({ status: 'creating' })
    try {
      const client = await getGameClient()
      if (!client) {
        setHostState({ status: 'error', message: SIGNER_UNAVAILABLE_MESSAGE })
        return
      }
      const matchId = await client.createMatch(getSelectedCaptainId())
      hostClientRef.current = client
      setHostState({ status: 'waiting', matchId })
    } catch (err) {
      setHostState({ status: 'error', message: err instanceof Error ? err.message : String(err) })
    }
  }

  function handleCancelHost() {
    hostClientRef.current = null
    setHostState({ status: 'idle' })
  }

  async function handleCopyCode(matchId: MatchId) {
    try {
      await navigator.clipboard.writeText(matchId.toString())
      setCopyLabel('Copied')
      window.setTimeout(() => setCopyLabel('Copy'), 1500)
    } catch {
      setCopyLabel('Copy failed')
      window.setTimeout(() => setCopyLabel('Copy'), 1500)
    }
  }

  async function handleJoin() {
    const parsed = parseJoinCode(joinCode)
    if ('error' in parsed) {
      setJoinState({ status: 'error', message: parsed.error })
      return
    }

    setJoinState({ status: 'joining' })
    try {
      const client = await getGameClient()
      if (!client) {
        setJoinState({ status: 'error', message: SIGNER_UNAVAILABLE_MESSAGE })
        return
      }

      const nextMatchId = await client.getNextMatchId()
      if (parsed.matchId >= nextMatchId) {
        setJoinState({ status: 'error', message: 'Match not found. Double check the code with your opponent.' })
        return
      }

      const phase = await client.getPhase(parsed.matchId)
      if (phase !== 0 /* WaitingForOpponent */) {
        setJoinState({ status: 'error', message: 'This match is not joinable, it is already full or already started.' })
        return
      }

      await client.joinMatch(parsed.matchId, getSelectedCaptainId())
      navigate(`/match/${parsed.matchId}`)
    } catch (err) {
      setJoinState({ status: 'error', message: describeJoinFailure(err) })
    }
  }

  return (
    <div className="lobby">
      <div className="ct-scanlines" aria-hidden="true" />

      <main className="lobby-main">
        <div className="lobby-console-frame">
          <span className="lobby-corner lobby-corner--tl" aria-hidden="true" />
          <span className="lobby-corner lobby-corner--tr" aria-hidden="true" />
          <span className="lobby-corner lobby-corner--bl" aria-hidden="true" />
          <span className="lobby-corner lobby-corner--br" aria-hidden="true" />

          <Reveal as="div" className="lobby-header" delayMs={0}>
            <div className="lobby-header-backdrop" aria-hidden="true">
              <SonarBackdrop />
            </div>
            <div className="lobby-header-content">
              <p className="ct-label">Matchmaking // Base Sepolia</p>
              <h1 className="lobby-title">Find Your Duel</h1>
              <p className="lobby-sub">Host a duel and share its code, or join one with a code from your opponent.</p>
            </div>
          </Reveal>

          <div className="lobby-paths">
            <Reveal as="div" className="lobby-path" delayMs={70}>
              <p className="ct-label">Host a Duel</p>
              <h2 className="lobby-path-title">Create Match</h2>
              <p className="lobby-path-copy">
                Start a new duel, get a join code, and share it with the player you want to face.
              </p>

              {hostState.status === 'idle' && (
                <button type="button" className="lobby-btn lobby-btn--primary" onClick={handleCreate}>
                  Create Match
                </button>
              )}

              {hostState.status === 'creating' && (
                <div className="lobby-pending" role="status">
                  <SonarPulse />
                  <span className="ct-mono">Creating your duel...</span>
                </div>
              )}

              {hostState.status === 'waiting' && (
                <div className="lobby-waiting">
                  <p className="ct-label">Your join code</p>
                  <div className="lobby-code-row">
                    <span className="lobby-code ct-mono">{hostState.matchId.toString()}</span>
                    <button type="button" className="lobby-btn lobby-btn--ghost" onClick={() => handleCopyCode(hostState.matchId)}>
                      {copyLabel}
                    </button>
                  </div>
                  <p className="lobby-path-copy">Share this code with your opponent.</p>

                  <div className="lobby-pending lobby-pending--waiting" role="status">
                    <SonarPulse />
                    <span className="ct-mono">Waiting for opponent to join...</span>
                  </div>

                  <button type="button" className="lobby-btn lobby-btn--ghost" onClick={handleCancelHost}>
                    Cancel
                  </button>
                </div>
              )}

              {hostState.status === 'error' && (
                <div className="lobby-error" role="alert">
                  <p>{hostState.message}</p>
                  <button type="button" className="lobby-btn lobby-btn--ghost" onClick={handleCancelHost}>
                    Back
                  </button>
                </div>
              )}
            </Reveal>

            <Reveal as="div" className="lobby-path" delayMs={140}>
              <p className="ct-label">Join a Duel</p>
              <h2 className="lobby-path-title">Enter a Code</h2>
              <p className="lobby-path-copy">Have a code from an opponent? Enter it below to join their duel.</p>

              <label className="lobby-field" htmlFor="lobby-join-code">
                <span className="ct-label">Match Code</span>
                <input
                  id="lobby-join-code"
                  className="lobby-input ct-mono"
                  type="text"
                  inputMode="numeric"
                  placeholder="e.g. 42"
                  value={joinCode}
                  disabled={joinState.status === 'joining'}
                  onChange={(e) => {
                    setJoinCode(e.target.value)
                    if (joinState.status === 'error') setJoinState({ status: 'idle' })
                  }}
                />
              </label>

              {joinState.status === 'joining' ? (
                <div className="lobby-pending" role="status">
                  <SonarPulse />
                  <span className="ct-mono">Joining...</span>
                </div>
              ) : (
                <button type="button" className="lobby-btn lobby-btn--primary" onClick={handleJoin}>
                  Join Match
                </button>
              )}

              {joinState.status === 'error' && (
                <div className="lobby-error" role="alert">
                  <p>{joinState.message}</p>
                </div>
              )}
            </Reveal>
          </div>
        </div>
      </main>

      <footer className="lobby-footer ct-mono">
        <span>Built on Base. Sealed by Inco.</span>
        <span>Base Sepolia testnet &middot; No mainnet deployment</span>
      </footer>
    </div>
  )
}

/** The waiting/pending motif: concentric sonar rings with a pulsing
 * return, the same pattern Leaderboard's "Your Command" flourish uses.
 * Reduced-motion aware. */
function SonarPulse() {
  return (
    <div className="lobby-pulse" aria-hidden="true">
      <svg viewBox="0 0 64 64">
        <circle cx="32" cy="32" r="10" />
        <circle cx="32" cy="32" r="20" />
        <circle cx="32" cy="32" r="29" />
        <line x1="32" y1="2" x2="32" y2="10" />
        <line x1="32" y1="54" x2="32" y2="62" />
        <line x1="2" y1="32" x2="10" y2="32" />
        <line x1="54" y1="32" x2="62" y2="32" />
      </svg>
      <span className="lobby-pulse-dot" />
    </div>
  )
}
