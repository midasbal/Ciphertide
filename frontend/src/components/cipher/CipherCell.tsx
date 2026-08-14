import { useEffect, useState } from 'react'
import { glyphFor } from './cipherGlyphs'
import './CipherCell.css'

export type CipherCellState = 'hidden' | 'decrypting' | 'hit' | 'miss' | 'mine' | 'shield'

interface CipherCellProps {
  row: number
  col: number
  state: CipherCellState
  /** Shared idle scramble tick from the parent board, cheap: one timer
   * for the whole grid instead of one per cell. */
  tick: number
  onClick?: () => void
  interactive?: boolean
}

const RESOLVED_LABEL: Record<string, string> = {
  hit: 'hit',
  miss: 'miss',
  mine: 'mine',
  shield: 'shield break',
}

/**
 * The signature motif: an unknown cell is not blank, it is ENCRYPTED,
 * rendered as scrambling ciphertext. When a shot resolves, the cell
 * visibly decrypts: the noise accelerates, a sweep passes through it,
 * and the true glyph (a hit or a miss) locks into place with a flash.
 * This is not decorative, it mirrors what is actually happening on
 * chain: the cell's true state is encrypted until the covalidator's
 * attestation reveals it.
 */
export default function CipherCell({ row, col, state, tick, onClick, interactive }: CipherCellProps) {
  const seed = row * 31 + col

  // While decrypting, run a faster local scramble than the shared idle
  // tick, so the moment of resolution feels distinct from the ambient
  // fog of war rather than just a color swap.
  const [fastTick, setFastTick] = useState(0)
  useEffect(() => {
    if (state !== 'decrypting') return
    const id = window.setInterval(() => setFastTick((t) => t + 1), 55)
    return () => window.clearInterval(id)
  }, [state])

  const isNoise = state === 'hidden' || state === 'decrypting'
  const glyph = isNoise ? glyphFor(seed, state === 'decrypting' ? fastTick : tick) : glyphSymbolFor(state)

  const label =
    state === 'hidden'
      ? `${coord(row, col)}, unrevealed`
      : state === 'decrypting'
        ? `${coord(row, col)}, decrypting`
        : `${coord(row, col)}, ${RESOLVED_LABEL[state] ?? state}`

  return (
    <button
      type="button"
      className={`cc cc--${state}${interactive ? ' cc--interactive' : ''}`}
      onClick={onClick}
      disabled={!interactive}
      aria-label={label}
      title={label}
    >
      <span className="cc-glyph" aria-hidden="true">
        {glyph}
      </span>
      {state === 'decrypting' && <span className="cc-sweep" aria-hidden="true" />}
    </button>
  )
}

function glyphSymbolFor(state: CipherCellState): string {
  switch (state) {
    case 'hit':
      return '✕'
    case 'miss':
      return '·'
    case 'mine':
      return '✷'
    case 'shield':
      return '◇'
    default:
      return ''
  }
}

function coord(row: number, col: number): string {
  const letter = String.fromCharCode(65 + col)
  return `${letter}${row + 1}`
}
