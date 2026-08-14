import './CoordinateFrame.css'

interface CoordinateFrameProps {
  size: number
  children: React.ReactNode
}

/** Wraps a grid with a sonar-console coordinate frame: column letters
 * along the top, row numbers down the left, printed in the mono face
 * exactly like the labels on the grid itself. */
export default function CoordinateFrame({ size, children }: CoordinateFrameProps) {
  const cols = Array.from({ length: size }, (_, i) => String.fromCharCode(65 + i))
  const rows = Array.from({ length: size }, (_, i) => i + 1)

  return (
    <div className="coord-frame">
      <div className="coord-frame-corner" aria-hidden="true" />
      <div className="coord-frame-cols" style={{ gridTemplateColumns: `repeat(${size}, 1fr)` }} aria-hidden="true">
        {cols.map((c) => (
          <span key={c}>{c}</span>
        ))}
      </div>
      <div className="coord-frame-rows" style={{ gridTemplateRows: `repeat(${size}, 1fr)` }} aria-hidden="true">
        {rows.map((r) => (
          <span key={r}>{r}</span>
        ))}
      </div>
      <div className="coord-frame-body">{children}</div>
    </div>
  )
}
