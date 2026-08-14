import { useEffect, useRef } from 'react'
import { CIPHER_GLYPHS } from '../cipher/cipherGlyphs'
import './SonarBackdrop.css'

interface Particle {
  x: number // fraction of width, 0..1
  y: number // fraction of height, 0..1
  vx: number
  vy: number
  char: string
  charTimer: number
  charInterval: number
  opacity: number
  size: number
}

const PARTICLE_COUNT = 48

function randomChar(): string {
  return CIPHER_GLYPHS[Math.floor(Math.random() * CIPHER_GLYPHS.length)]
}

function makeParticle(): Particle {
  return {
    x: Math.random(),
    y: Math.random(),
    vx: (Math.random() - 0.5) * 0.05,
    vy: -(0.03 + Math.random() * 0.07),
    char: randomChar(),
    charTimer: 0,
    charInterval: 1800 + Math.random() * 2600,
    opacity: 0.06 + Math.random() * 0.2,
    size: 11 + Math.random() * 8,
  }
}

/**
 * The hero's living backdrop. A field of ciphertext motes drifts slowly
 * upward through dark water, like phosphorescence, occasionally
 * flickering to a new glyph, the ambient version of the same encrypted
 * noise a hidden board cell shows up close. Canvas driven so 48 moving,
 * mutating characters cost nothing per frame. Layered on top in CSS: a
 * slow rotating sonar sweep, static range rings, and two staggered pings
 * expanding outward. Scroll parallax drifts the rings and sweep a few
 * percent slower than the page, just enough to read as depth.
 *
 * A visitor who has asked for less motion gets one still frame of the
 * glyph field and no sweep, ping or parallax at all.
 */
export default function SonarBackdrop() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  const parallaxRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return

    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

    let width = 0
    let height = 0
    const dpr = Math.min(window.devicePixelRatio || 1, 2)

    function resize() {
      const parent = canvas!.parentElement
      if (!parent) return
      const rect = parent.getBoundingClientRect()
      width = rect.width
      height = rect.height
      canvas!.width = Math.max(1, Math.floor(width * dpr))
      canvas!.height = Math.max(1, Math.floor(height * dpr))
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0)
    }
    resize()
    window.addEventListener('resize', resize)

    const particles: Particle[] = Array.from({ length: PARTICLE_COUNT }, makeParticle)

    function draw() {
      ctx!.clearRect(0, 0, width, height)
      for (const p of particles) {
        const px = p.x * width
        const py = p.y * height
        ctx!.font = `${p.size}px "JetBrains Mono", monospace`
        ctx!.fillStyle = `rgba(111, 155, 255, ${p.opacity})`
        ctx!.fillText(p.char, px, py)
      }
    }

    if (reduceMotion) {
      draw()
      return () => window.removeEventListener('resize', resize)
    }

    let raf = 0
    let last = performance.now()

    function frame(now: number) {
      const dt = Math.min(now - last, 64)
      last = now

      for (const p of particles) {
        p.x += (p.vx * dt) / 1000
        p.y += (p.vy * dt) / 1000
        p.charTimer += dt
        if (p.charTimer > p.charInterval) {
          p.charTimer = 0
          p.char = randomChar()
        }
        if (p.y < -0.03) {
          p.y = 1.03
          p.x = Math.random()
        }
        if (p.x < -0.03) p.x = 1.03
        if (p.x > 1.03) p.x = -0.03
      }

      draw()
      raf = requestAnimationFrame(frame)
    }

    raf = requestAnimationFrame(frame)
    return () => {
      window.removeEventListener('resize', resize)
      cancelAnimationFrame(raf)
    }
  }, [])

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return

    let raf = 0
    function onScroll() {
      if (raf) return
      raf = requestAnimationFrame(() => {
        raf = 0
        const node = parallaxRef.current
        if (node) node.style.transform = `translateY(${window.scrollY * 0.12}px)`
      })
    }
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <div className="sonar-backdrop" aria-hidden="true">
      <canvas ref={canvasRef} className="sonar-backdrop-canvas" />
      <div ref={parallaxRef} className="sonar-backdrop-parallax">
        <svg viewBox="0 0 600 600" className="sonar-backdrop-rings">
          <circle cx="300" cy="300" r="120" />
          <circle cx="300" cy="300" r="220" />
          <circle cx="300" cy="300" r="300" />
          <line x1="6" y1="300" x2="594" y2="300" />
          <line x1="300" y1="6" x2="300" y2="594" />
        </svg>
        <div className="sonar-backdrop-sweep" />
      </div>
      <div className="sonar-backdrop-ping sonar-backdrop-ping--a" />
      <div className="sonar-backdrop-ping sonar-backdrop-ping--b" />
    </div>
  )
}
