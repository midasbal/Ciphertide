import { useEffect, useRef, useState } from 'react'
import { CIPHER_GLYPHS } from './cipherGlyphs'
import './DecryptReadout.css'

interface DecryptReadoutProps {
  text: string
}

const REVEAL_MS_PER_CHAR = 42
const HOLD_MS = 1800
const RESET_PAUSE_MS = 420

/**
 * The reveal wait, rendered as a decrypt beat instead of a spinner: the
 * target line resolves left to right out of scrambling ciphertext, the
 * same motion a cell on the enemy board goes through, just spelled out
 * as a status line. This is what "decrypting enemy waters" actually
 * looks like while the covalidator attestation is in flight.
 */
export default function DecryptReadout({ text }: DecryptReadoutProps) {
  const [revealed, setRevealed] = useState(0)
  const [frame, setFrame] = useState(0)
  const startRef = useRef<number>(0)
  const rafRef = useRef<number | undefined>(undefined)

  useEffect(() => {
    let cancelled = false
    let phase: 'revealing' | 'holding' | 'paused' = 'revealing'
    startRef.current = performance.now()

    function tick(now: number) {
      if (cancelled) return
      const elapsed = now - startRef.current

      if (phase === 'revealing') {
        const count = Math.min(text.length, Math.floor(elapsed / REVEAL_MS_PER_CHAR))
        setRevealed(count)
        setFrame((f) => f + 1)
        if (count >= text.length) {
          phase = 'holding'
          startRef.current = now
        }
      } else if (phase === 'holding') {
        if (elapsed >= HOLD_MS) {
          phase = 'paused'
          startRef.current = now
          setRevealed(0)
        }
      } else {
        if (elapsed >= RESET_PAUSE_MS) {
          phase = 'revealing'
          startRef.current = now
        }
        setFrame((f) => f + 1)
      }

      rafRef.current = requestAnimationFrame(tick)
    }

    rafRef.current = requestAnimationFrame(tick)
    return () => {
      cancelled = true
      if (rafRef.current) cancelAnimationFrame(rafRef.current)
    }
  }, [text])

  const chars = text.split('').map((char, i) => {
    if (char === ' ') return ' '
    if (i < revealed) return char
    const n = (i * 2654435761 + frame * 97) >>> 0
    return CIPHER_GLYPHS[n % CIPHER_GLYPHS.length]
  })

  return (
    <div className="decrypt-readout" role="status">
      <span className="decrypt-readout-dot" aria-hidden="true" />
      <span className="decrypt-readout-text ct-mono">{chars.join('')}</span>
    </div>
  )
}
