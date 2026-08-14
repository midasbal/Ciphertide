import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Navigate, Outlet, Route, Routes } from 'react-router-dom'
import './styles/global.css'
import Landing from './screens/Landing.tsx'
import TopNav from './components/nav/TopNav.tsx'

// Dev-only route for the throwaway game-client proof harness, never
// linked from the real app. Lazy loaded so its two-private-key wiring
// never ships in the normal bundle path.
const DevHarness = lazy(() => import('./dev/harness.tsx'))

// The in-match sample screen, the visual identity's hardest-working
// screen, rendered with stubbed data, no contract or wallet.
const MatchScreen = lazy(() => import('./screens/MatchScreen.tsx'))

// The original skill-aiming demo, superseded by the real landing page as
// the default route but kept reachable at /dev/aiming rather than
// deleted, since it still exercises the OpponentSeaBoard aiming preview.
const AimingDemo = lazy(() => import('./App.tsx'))

// Fleet standings mock, static sample data only, no contract wiring.
const Leaderboard = lazy(() => import('./screens/Leaderboard.tsx'))

// Captain select, off-chain profile state kept in localStorage, no
// contract wiring.
const Profile = lazy(() => import('./screens/Profile.tsx'))

// Matchmaking lobby: create or join a real match through the deployed
// contract.
const Lobby = lazy(() => import('./screens/Lobby.tsx'))

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
            <Route path="/profile" element={<Profile />} />
            <Route path="/leaderboard" element={<Leaderboard />} />
          </Route>
          <Route path="/match/:matchId" element={<MatchScreen />} />
          <Route path="/dev/aiming" element={<AimingDemo />} />
          <Route path="/dev/harness" element={<DevHarness />} />
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
