import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import SonarBackdrop from '../components/hero/SonarBackdrop'
import Reveal from '../components/reveal/Reveal'
import CipherCell from '../components/cipher/CipherCell'
import DecryptReadout from '../components/cipher/DecryptReadout'
import CaptainMark from '../components/captains/CaptainMark'
import { CAPTAINS, type Captain } from './captains'
import './Landing.css'

const PROCESS_STEPS: Array<{
  code: string
  title: string
  body: string
  cellState: 'hidden' | 'decrypting' | 'hit' | 'miss'
}> = [
  {
    code: '01',
    title: 'Deploy',
    body: 'Your fleet is placed and encrypted onchain through Inco. Not hidden behind a login, a private database, or an honor system. Sealed as ciphertext only a secure enclave can open.',
    cellState: 'hidden',
  },
  {
    code: '02',
    title: 'Fire',
    body: 'You call a coordinate. It is checked against your hidden board inside a secure enclave, never exposed to you, your opponent, or anyone watching the chain.',
    cellState: 'decrypting',
  },
  {
    code: '03',
    title: 'Decrypt',
    body: 'Only that single cell resolves. Hit or miss, attested by the covalidator and settled onchain. The rest of the board stays sealed. Fog of war is not a UI trick here, it is literal encrypted state.',
    cellState: 'hit',
  },
  {
    code: '04',
    title: 'Verify',
    body: 'Every resolution is checked onchain against a signed attestation, not a server’s word. There is no operator who could have looked at your board even if they wanted to.',
    cellState: 'miss',
  },
]

const FOOTER_LINKS = [
  { label: 'Profile', href: '/profile', external: false },
  { label: 'Docs', href: 'https://docs.inco.org', external: true },
  { label: 'GitHub', href: 'https://github.com/midasbal/Ciphertide', external: true },
  { label: 'Inco', href: 'https://inco.org', external: true },
  { label: 'Base', href: 'https://base.org', external: true },
]

/**
 * The front door. Everything here is stubbed and static, no contract, no
 * wallet: the job of this screen is to sell the one true thing about
 * Ciphertide (your board is encrypted, not merely hidden by convention)
 * in the same sonar-console voice the in-match screen already speaks.
 */
export default function Landing() {
  const [tick, setTick] = useState(0)
  useEffect(() => {
    const id = window.setInterval(() => setTick((t) => t + 1), 260)
    return () => window.clearInterval(id)
  }, [])

  return (
    <div className="landing">
      <div className="ct-scanlines" aria-hidden="true" />

      <a className="landing-skip" href="#main-hook">
        Skip to content
      </a>

      <section className="landing-hero">
        <SonarBackdrop />
        <div className="landing-hero-content">
          <p className="landing-hero-kicker ct-label">Base Sepolia &middot; Confidential naval duel</p>
          <h1 className="landing-hero-title">
            CIPHER<span className="landing-hero-title-accent">TIDE</span>
          </h1>
          <p className="landing-hero-tagline">
            Nobody sees your fleet. Not your enemy. Not a server. Not us.
          </p>
          <p className="landing-hero-sub">
            A 1v1 naval duel where your board is encrypted the moment you place it, and stays that way until a
            shot forces a single cell to speak. Built on Base, sealed by Inco.
          </p>
          <div className="landing-hero-actions">
            <Link className="landing-cta landing-cta--primary" to="/play">
              Deploy Your Fleet
            </Link>
            <a className="landing-cta landing-cta--ghost" href="#how">
              How it holds
            </a>
          </div>
          <div className="landing-hero-readout">
            <DecryptReadout text="CIPHERTIDE ONLINE // BASE SEPOLIA" />
          </div>
        </div>
        <div className="landing-hero-fade" aria-hidden="true" />
      </section>

      <main id="main-hook">
        <Reveal as="section" className="landing-section landing-hook" delayMs={0}>
          <div className="landing-section-frame">
            <p className="ct-label" id="hook">
              The Brief
            </p>
            <h2 className="landing-section-title">No board to trust. Only a signature to check.</h2>
            <p className="landing-section-lede">
              A hidden-fleet naval duel usually runs on the honor system: you trust your opponent not to peek, or you
              trust a server to referee. Ciphertide removes both. Your fleet is encrypted onchain the instant you place it.
              No operator holds a plaintext copy. No opponent can infer your board by watching contract state. A
              shot is resolved inside sealed hardware, and only the outcome of that one cell is ever revealed.
            </p>
            <p className="landing-section-lede landing-section-lede--muted">
              This is not a promise written into the rules. It is enforced by sealed hardware and checked onchain
              against a signature. The fog of war you
              see on the console is not an art direction choice, it is the literal encrypted state of your
              opponent's board, rendered honestly.
            </p>
          </div>
        </Reveal>

        <section className="landing-section landing-how" id="how" aria-label="How it works">
          <Reveal className="landing-section-frame landing-section-frame--wide">
            <p className="ct-label">The Protocol</p>
            <h2 className="landing-section-title">Encrypted from deployment to decrypt</h2>
            <p className="landing-section-lede">
              Four moves, the same four moves every match runs on. Each one keeps the board sealed until the exact
              instant it has to open.
            </p>
          </Reveal>

          <div className="landing-process">
            {PROCESS_STEPS.map((step, i) => (
              <Reveal key={step.code} delayMs={i * 90} className="landing-process-step">
                <div className="landing-process-glyph">
                  <CipherCell row={i} col={i} state={step.cellState} tick={tick} />
                </div>
                <span className="landing-process-code ct-mono">{step.code}</span>
                <h3 className="landing-process-title">{step.title}</h3>
                <p className="landing-process-body">{step.body}</p>
              </Reveal>
            ))}
          </div>
        </section>

        <section className="landing-section landing-captains" id="captains" aria-label="Captains">
          <Reveal className="landing-section-frame">
            <p className="ct-label">Captains</p>
            <h2 className="landing-section-title">Every captain carries one signature strike</h2>
            <p className="landing-section-lede">
              Past the standard shot, one captain and one tactic per match. A wide sweep, a saturating volley, a
              precision cut down a row.
            </p>
          </Reveal>

          <div className="landing-captain-grid">
            {CAPTAINS.map((captain, i) => (
              <Reveal key={captain.code} delayMs={i * 70} className="captain-slot">
                <div className="captain-slot-art">
                  <CaptainPortrait captain={captain} />
                </div>
                <div className="captain-slot-meta">
                  <span className="ct-mono captain-slot-code">{captain.code}</span>
                  <h3 className="captain-slot-name">{captain.name}</h3>
                  <p className="captain-slot-skill-name ct-mono">{captain.skillName}</p>
                  <p className="captain-slot-skill">{captain.teaser}</p>
                </div>
              </Reveal>
            ))}
          </div>
        </section>

        <Reveal as="section" className="landing-section landing-closing" aria-label="Enter">
          <div className="landing-closing-frame">
            <p className="ct-label">Final Bearing</p>
            <h2 className="landing-section-title">The tide is encrypted. Command it.</h2>
            <p className="landing-section-lede">
              Your waters are waiting. Nobody else can see them, not until you decide who gets to.
            </p>
            <Link className="landing-cta landing-cta--primary landing-cta--large" to="/play">
              Deploy Your Fleet
            </Link>
          </div>
        </Reveal>
      </main>

      <footer className="landing-footer">
        <div className="landing-footer-top">
          <div className="landing-footer-mark">
            <span className="landing-nav-glyph" aria-hidden="true">
              &#8225;
            </span>
            <span>CIPHERTIDE</span>
          </div>
          <nav className="landing-footer-links ct-mono" aria-label="Footer">
            {FOOTER_LINKS.map((link) =>
              link.external ? (
                <a key={link.label} href={link.href} target="_blank" rel="noreferrer">
                  {link.label}
                </a>
              ) : (
                <Link key={link.label} to={link.href}>
                  {link.label}
                </Link>
              ),
            )}
          </nav>
        </div>
        <div className="landing-footer-bottom ct-mono">
          <span>Built on Base. Sealed by Inco.</span>
          <span>Base Sepolia testnet &middot; No mainnet deployment</span>
        </div>
      </footer>
    </div>
  )
}

/**
 * Renders the real captain portrait; falls back to the vector sigil mark
 * only if the image fails to load. Lazy loaded since the captains
 * section sits below the fold.
 */
function CaptainPortrait({ captain }: { captain: Captain }) {
  const [imageFailed, setImageFailed] = useState(false)

  if (imageFailed) {
    return <CaptainMark kind={captain.mark} />
  }

  return (
    <img
      className="captain-slot-image"
      src={captain.portrait}
      alt={captain.name}
      loading="lazy"
      decoding="async"
      onError={() => setImageFailed(true)}
    />
  )
}
