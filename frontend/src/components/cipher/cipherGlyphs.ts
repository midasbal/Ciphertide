// The noise alphabet a hidden cell scrambles through: hex digits (this is
// literally ciphertext, an encrypted handle on Inco is hex) mixed with a
// few shading and rune-like glyphs so it reads as static and interference,
// not just a spinning counter.
export const CIPHER_GLYPHS = '0123456789ABCDEF▒░▓¤±§¶‡'.split('')

// A tiny deterministic hash so the same (cell index, tick) always picks
// the same glyph within a render, avoiding a fresh Math.random() call
// per cell per tick (225 cells x several renders a second adds up) while
// still looking fully random across the grid.
export function glyphFor(seed: number, tick: number): string {
  const n = (seed * 2654435761 + tick * 40503) >>> 0
  return CIPHER_GLYPHS[n % CIPHER_GLYPHS.length]
}
