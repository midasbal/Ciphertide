import type { CaptainMarkKind } from '../../screens/captains'

/** Abstract geometric insignia, never a figurative portrait, standing in
 * for captain art that has not been commissioned yet. Each mark is a
 * distinct simple composition in the accent and structure blues so the
 * five captains read as a set without inventing a face for any of them. */
export default function CaptainMark({ kind, className }: { kind: CaptainMarkKind; className?: string }) {
  return (
    <svg
      viewBox="0 0 96 96"
      className={`captain-mark captain-mark--${kind}${className ? ` ${className}` : ''}`}
      aria-hidden="true"
    >
      {kind === 'shield' && <path d="M48 12 L80 24 V48 C80 68 66 82 48 88 C30 82 16 68 16 48 V24 Z" />}
      {kind === 'bombardment' && (
        <g>
          <circle cx="48" cy="48" r="6" />
          <circle cx="24" cy="30" r="4" />
          <circle cx="70" cy="30" r="4" />
          <circle cx="24" cy="66" r="4" />
          <circle cx="70" cy="66" r="4" />
          <circle cx="48" cy="18" r="4" />
          <circle cx="48" cy="78" r="4" />
        </g>
      )}
      {kind === 'rake' && (
        <g>
          <line x1="14" y1="30" x2="82" y2="30" />
          <line x1="14" y1="48" x2="82" y2="48" />
          <line x1="14" y1="66" x2="82" y2="66" />
        </g>
      )}
      {kind === 'salvo' && (
        <g>
          <circle cx="30" cy="34" r="7" />
          <circle cx="66" cy="34" r="7" />
          <circle cx="48" cy="66" r="7" />
        </g>
      )}
      {kind === 'carpet' && <rect x="20" y="20" width="56" height="56" />}
    </svg>
  )
}
