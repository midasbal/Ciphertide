import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Navigate, Outlet, Route, Routes } from 'react-router-dom'
import './styles/global.css'
import Landing from './screens/Landing.tsx'
import TopNav from './components/nav/TopNav.tsx'

// The in-match sample screen, the visual identity's hardest-working
// screen, rendered with stubbed data, no contract or wallet.
const MatchScreen = lazy(() => import('./screens/MatchScreen.tsx'))

// Dev-only routes: the throwaway game-client proof harness (reads the
// VITE_PLAYER_A/B_PRIVATE_KEY dev keys) and the original skill-aiming
// demo, never linked from the real app. Guarded by import.meta.env.DEV,
// a compile-time constant Vite replaces with a literal true or false, so
// a production build's dead code elimination drops the lazy() call and
// its dynamic import() entirely, not just the route that would render
// it: neither chunk, and neither dev key, ends up in a production dist/.
const DevHarness = import.meta.env.DEV ? lazy(() => import('./dev/harness.tsx')) : null
const AimingDemo = import.meta.env.DEV ? lazy(() => import('./App.tsx')) : null

// Fleet standings mock, static sample data only, no contract wiring.
const Leaderboard = lazy(() => import('./screens/Leaderboard.tsx'))

// Captain select, off-chain profile state kept in localStorage, no
// contract wiring.
const Profile = lazy(() => import('./screens/Profile.tsx'))

// Matchmaking lobby: create or join a real match through the deployed
// contract.
const Lobby = lazy(() => import('./screens/Lobby.tsx'))

// Play-wallet on-ramp: generates and funds a fresh wallet, or recognizes
// one already saved in this browser.
const Register = lazy(() => import('./screens/Register.tsx'))

// Shared layout for the main, user-facing routes: the persistent top
// nav plus whichever page is active. The match and dev routes render
// their own header instead and sit outside this layout.
function MainLayout() {
  return (
    <>
      <TopNav />
      <Outlet />
    </>
  )
}

function Root() {
  return (
    <BrowserRouter>
      <Suspense fallback={null}>
        <Routes>
          <Route element={<MainLayout />}>
            <Route path="/" element={<Landing />} />
            <Route path="/play" element={<Lobby />} />
            <Route path="/register" element={<Register />} />
            <Route path="/profile" element={<Profile />} />
            <Route path="/leaderboard" element={<Leaderboard />} />
          </Route>
          <Route path="/match/:matchId" element={<MatchScreen />} />
          {AimingDemo && <Route path="/dev/aiming" element={<AimingDemo />} />}
          {DevHarness && <Route path="/dev/harness" element={<DevHarness />} />}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Suspense>
    </BrowserRouter>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)
