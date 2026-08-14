import { NavLink, useLocation } from 'react-router-dom'
import './TopNav.css'

const NAV_LINKS = [
  { to: '/play', label: 'Play' },
  { to: '/profile', label: 'Profile' },
  { to: '/leaderboard', label: 'Leaderboard' },
]

// Landing-only in-page section anchors. Shown as a secondary row, only
// on the landing route, so the shared nav can carry them without every
// other page inheriting links to sections that do not exist there.
const LANDING_SECTIONS = [
  { href: '#hook', label: 'Brief' },
  { href: '#how', label: 'Protocol' },
  { href: '#captains', label: 'Captains' },
]

/**
 * The one persistent top navigation bar, shared by the landing, play,
 * profile and leaderboard routes via the layout route in main.tsx. The
 * match and dev routes render their own full-bleed console header
 * instead and are never linked from here.
 */
export default function TopNav() {
  const { pathname } = useLocation()
  const isLanding = pathname === '/'

  return (
    <header className="top-nav">
      <div className="top-nav-row">
        <NavLink className="top-nav-mark" to="/">
          <span className="top-nav-glyph" aria-hidden="true">
            &#8225;
          </span>
          <span>CIPHERTIDE</span>
        </NavLink>
        <nav className="top-nav-links ct-mono" aria-label="Primary">
          {NAV_LINKS.map((link) => (
            <NavLink
              key={link.to}
              to={link.to}
              className={({ isActive }) => `top-nav-link${isActive ? ' top-nav-link--active' : ''}`}
            >
              {link.label}
            </NavLink>
          ))}
        </nav>
      </div>

      {isLanding && (
        <nav className="top-nav-secondary ct-mono" aria-label="On this page">
          {LANDING_SECTIONS.map((section) => (
            <a key={section.href} href={section.href}>
              {section.label}
            </a>
          ))}
        </nav>
      )}
    </header>
  )
}
