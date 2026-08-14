import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { privateKeyToAccount } from 'viem/accounts'
import type { Address, Hex } from 'viem'
import SonarBackdrop from '../components/hero/SonarBackdrop'
import Reveal from '../components/reveal/Reveal'
import { buildFundingMessage } from '../lib/fundingMessage'
import {
  addressForKey,
  generatePlayWalletKey,
  isValidPrivateKey,
  readPlayWalletKey,
  savePlayWalletKey,
} from '../lib/playWallet'
import './Register.css'

type Phase =
  | { kind: 'idle' }
  | { kind: 'generating' }
  | { kind: 'funding'; address: Address }
  | { kind: 'funded'; address: Address; txHash: string }
  | { kind: 'existing'; address: Address }
  | { kind: 'error'; message: string }

async function requestFunding(key: Hex, address: Address): Promise<{ txHash: string } | { error: string }> {
  try {
    const account = privateKeyToAccount(key)
    const timestamp = Date.now()
    const message = buildFundingMessage(address, timestamp)
    const signature = await account.signMessage({ message })

    const res = await fetch('/api/fund', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address, signature, timestamp }),
    })

    let data: { txHash?: string; error?: string } = {}
    try {
      data = await res.json()
    } catch {
      return { error: 'The server sent back something unexpected. Try again in a moment.' }
    }

    if (!res.ok) return { error: data.error || 'Funding was refused.' }
    if (!data.txHash) return { error: 'Funding succeeded but no transaction came back. Try again.' }
    return { txHash: data.txHash }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Network error, check your connection and try again.' }
  }
}

/**
 * The play-wallet on-ramp. A new visitor gets a fresh, browser-generated
 * wallet, funded once by the sponsor endpoint, no faucet needed. A
 * returning visitor is recognized from localStorage and skips straight
 * to an enlisted state. See lib/playWallet.ts for where the key lives
 * and lib/signer.ts for how the rest of the app reads it.
 */
export default function Register() {
  const navigate = useNavigate()
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' })
  const [showImport, setShowImport] = useState(false)
  const [importValue, setImportValue] = useState('')
  const [importError, setImportError] = useState<string | null>(null)
  const [revealed, setRevealed] = useState(false)
  const [copyLabel, setCopyLabel] = useState('Copy')

  useEffect(() => {
    const existingKey = readPlayWalletKey()
    if (existingKey) {
      setPhase({ kind: 'existing', address: addressForKey(existingKey) })
    }
  }, [])

  async function handleEnlist() {
    setPhase({ kind: 'generating' })
    const key = generatePlayWalletKey()
    const address = addressForKey(key)
    savePlayWalletKey(key)

    setPhase({ kind: 'funding', address })
    const result = await requestFunding(key, address)
    if ('error' in result) {
      setPhase({ kind: 'error', message: result.error })
      return
    }
    setPhase({ kind: 'funded', address, txHash: result.txHash })
  }

  async function handleRequestFundsAgain(address: Address) {
    const key = readPlayWalletKey()
    if (!key) {
      setPhase({ kind: 'error', message: 'No play-wallet key found in this browser. Enlist again.' })
      return
    }
    setPhase({ kind: 'funding', address })
    const result = await requestFunding(key, address)
    if ('error' in result) {
      setPhase({ kind: 'error', message: result.error })
      return
    }
    setPhase({ kind: 'funded', address, txHash: result.txHash })
  }

  function handleImport() {
    const trimmed = importValue.trim()
    if (!isValidPrivateKey(trimmed)) {
      setImportError('That does not look like a valid private key. It should start with 0x and have 64 hex characters after it.')
      return
    }
    const key = trimmed as Hex
    savePlayWalletKey(key)
    setPhase({ kind: 'existing', address: addressForKey(key) })
    setShowImport(false)
    setImportValue('')
    setImportError(null)
  }

  async function handleCopyKey() {
    const key = readPlayWalletKey()
    if (!key) return
    try {
      await navigator.clipboard.writeText(key)
      setCopyLabel('Copied')
    } catch {
      setCopyLabel('Copy failed')
    }
    window.setTimeout(() => setCopyLabel('Copy'), 1500)
  }

  function handleDownloadKey(address: Address) {
    const key = readPlayWalletKey()
    if (!key) return
    const content =
      `Ciphertide play-wallet backup\n\n` +
      `Address: ${address}\n` +
      `Private key: ${key}\n\n` +
      `This is your identity in Ciphertide, a Base Sepolia testnet wallet with no ` +
      `real-world value. Your Salvage balance and captain unlocks are tied to this ` +
      `key. Keep this file private: anyone who has it can act as you in the game.\n`
    const blob = new Blob([content], { type: 'text/plain' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = 'ciphertide-play-wallet-backup.txt'
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }

  return (
    <div className="register">
      <div className="ct-scanlines" aria-hidden="true" />

      <main className="register-main">
        <div className="register-console-frame">
          <span className="register-corner register-corner--tl" aria-hidden="true" />
          <span className="register-corner register-corner--tr" aria-hidden="true" />
          <span className="register-corner register-corner--bl" aria-hidden="true" />
          <span className="register-corner register-corner--br" aria-hidden="true" />

          <Reveal as="div" className="register-header" delayMs={0}>
            <div className="register-header-backdrop" aria-hidden="true">
              <SonarBackdrop />
            </div>
            <div className="register-header-content">
              <p className="ct-label">Command Registration // Base Sepolia</p>
              <h1 className="register-title">Enlist Your Command</h1>
              <p className="register-sub">
                No wallet, no faucet, no signup form. A fresh play-wallet is generated right here in your browser
                and funded once by the sponsor, enough Base Sepolia testnet ETH to play.
              </p>
            </div>
          </Reveal>

          <Reveal as="div" className="register-body" delayMs={70}>
            {phase.kind === 'idle' && (
              <div className="register-panel">
                <p className="ct-label">New Command</p>
                <h2 className="register-panel-title">Enlist</h2>
                <p className="register-panel-copy">
                  Generates a play-wallet on this device, signs a funding request with it, and the sponsor sends it
                  testnet ETH. Takes a few seconds.
                </p>
                <button type="button" className="register-btn register-btn--primary" onClick={handleEnlist}>
                  Enlist
                </button>

                <div className="register-divider" role="separator" />

                <button type="button" className="register-btn register-btn--ghost" onClick={() => setShowImport((v) => !v)}>
                  Import a Backed Up Key
                </button>
                {showImport && (
                  <ImportForm
                    value={importValue}
                    error={importError}
                    onChange={(v) => {
                      setImportValue(v)
                      setImportError(null)
                    }}
                    onSubmit={handleImport}
                  />
                )}

                <button type="button" className="register-btn register-btn--ghost" disabled title="Coming soon">
                  Connect Your Own Wallet <span className="register-soon ct-label">Coming Soon</span>
                </button>
              </div>
            )}

            {(phase.kind === 'generating' || phase.kind === 'funding') && (
              <div className="register-panel">
                <p className="ct-label">Enlisting</p>
                <div className="register-pending" role="status">
                  <SonarPulse />
                  <span className="ct-mono">
                    {phase.kind === 'generating' ? 'Generating your play-wallet...' : 'Requesting funds from the sponsor...'}
                  </span>
                </div>
              </div>
            )}

            {phase.kind === 'funded' && (
              <div className="register-panel">
                <p className="ct-label">Funded and Ready</p>
                <h2 className="register-panel-title">Command Sealed</h2>
                <p className="register-panel-copy">
                  Your play-wallet is funded and ready. Back it up now, this key is your only way back into this
                  command.
                </p>
                <AddressReadout address={phase.address} />
                <p className="register-tx ct-mono">tx {phase.txHash}</p>
                <KeyBackupPanel
                  revealed={revealed}
                  onToggleReveal={() => setRevealed((v) => !v)}
                  onCopy={handleCopyKey}
                  onDownload={() => handleDownloadKey(phase.address)}
                  copyLabel={copyLabel}
                />
                <button type="button" className="register-btn register-btn--primary" onClick={() => navigate('/play')}>
                  Enter the Console
                </button>
              </div>
            )}

            {phase.kind === 'existing' && (
              <div className="register-panel">
                <p className="ct-label">Command Recognized</p>
                <h2 className="register-panel-title">Welcome Back</h2>
                <p className="register-panel-copy">This browser already holds a play-wallet.</p>
                <AddressReadout address={phase.address} />
                <KeyBackupPanel
                  revealed={revealed}
                  onToggleReveal={() => setRevealed((v) => !v)}
                  onCopy={handleCopyKey}
                  onDownload={() => handleDownloadKey(phase.address)}
                  copyLabel={copyLabel}
                />
                <div className="register-actions">
                  <button type="button" className="register-btn register-btn--primary" onClick={() => navigate('/play')}>
                    Enter the Console
                  </button>
                  <button
                    type="button"
                    className="register-btn register-btn--ghost"
                    onClick={() => handleRequestFundsAgain(phase.address)}
                  >
                    Request Funds
                  </button>
                </div>

                <div className="register-divider" role="separator" />

                <button type="button" className="register-btn register-btn--ghost" onClick={() => setShowImport((v) => !v)}>
                  Use a Different Key
                </button>
                {showImport && (
                  <ImportForm
                    value={importValue}
                    error={importError}
                    onChange={(v) => {
                      setImportValue(v)
                      setImportError(null)
                    }}
                    onSubmit={handleImport}
                  />
                )}
              </div>
            )}

            {phase.kind === 'error' && (
              <div className="register-panel">
                <p className="ct-label">Enlistment Failed</p>
                <div className="register-error" role="alert">
                  <p>{phase.message}</p>
                </div>
                <button type="button" className="register-btn register-btn--ghost" onClick={() => setPhase({ kind: 'idle' })}>
                  Back
                </button>
              </div>
            )}
          </Reveal>
        </div>
      </main>

      <footer className="register-footer ct-mono">
        <span>Built on Base. Sealed by Inco.</span>
        <span>Base Sepolia testnet &middot; No mainnet deployment</span>
      </footer>
    </div>
  )
}

function AddressReadout({ address }: { address: Address }) {
  return (
    <div className="register-address-row">
      <span className="ct-label">Address</span>
      <span className="register-address ct-mono">{address}</span>
    </div>
  )
}

function KeyBackupPanel({
  revealed,
  onToggleReveal,
  onCopy,
  onDownload,
  copyLabel,
}: {
  revealed: boolean
  onToggleReveal: () => void
  onCopy: () => void
  onDownload: () => void
  copyLabel: string
}) {
  const key = readPlayWalletKey()
  return (
    <div className="register-backup">
      <p className="register-backup-warning">
        This key is your identity. Your Salvage balance and captain unlocks are tied to it. It is a Base Sepolia
        testnet key with no real-world value, but if you lose it, you lose this command for good.
      </p>
      <div className="register-key-row">
        <span className="register-key ct-mono">{revealed && key ? key : '•'.repeat(48)}</span>
      </div>
      <div className="register-backup-actions">
        <button type="button" className="register-btn register-btn--ghost" onClick={onToggleReveal}>
          {revealed ? 'Hide' : 'Reveal'}
        </button>
        <button type="button" className="register-btn register-btn--ghost" onClick={onCopy}>
          {copyLabel}
        </button>
        <button type="button" className="register-btn register-btn--ghost" onClick={onDownload}>
          Download
        </button>
      </div>
    </div>
  )
}

function ImportForm({
  value,
  error,
  onChange,
  onSubmit,
}: {
  value: string
  error: string | null
  onChange: (value: string) => void
  onSubmit: () => void
}) {
  return (
    <div className="register-import">
      <label className="register-field" htmlFor="register-import-key">
        <span className="ct-label">Private Key</span>
        <input
          id="register-import-key"
          className="register-input ct-mono"
          type="text"
          placeholder="0x..."
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </label>
      {error && (
        <div className="register-error" role="alert">
          <p>{error}</p>
        </div>
      )}
      <button type="button" className="register-btn register-btn--primary" onClick={onSubmit}>
        Use This Key
      </button>
    </div>
  )
}

/** The waiting motif shared with the lobby: concentric sonar rings with
 * a pulsing return. Reduced-motion aware. */
function SonarPulse() {
  return (
    <div className="register-pulse" aria-hidden="true">
      <svg viewBox="0 0 64 64">
        <circle cx="32" cy="32" r="10" />
        <circle cx="32" cy="32" r="20" />
        <circle cx="32" cy="32" r="29" />
        <line x1="32" y1="2" x2="32" y2="10" />
        <line x1="32" y1="54" x2="32" y2="62" />
        <line x1="2" y1="32" x2="10" y2="32" />
        <line x1="54" y1="32" x2="62" y2="32" />
      </svg>
      <span className="register-pulse-dot" />
    </div>
  )
}
