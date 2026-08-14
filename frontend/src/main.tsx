import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import './styles/global.css'
import Landing from './screens/Landing.tsx'

// Dev-only route for the throwaway game-client proof harness, never
// linked from the real app. Visit /?harness=1 to reach it. Lazy loaded
// so its two-private-key wiring never ships in the normal bundle path.
const params = new URLSearchParams(window.location.search)
const isHarness = params.has('harness')

// Dev-only route for the in-match sample screen, the visual identity's
// hardest-working screen, rendered with stubbed data, no contract or
// wallet. Visit /?screen=match to reach it.
const isMatchSample = params.get('screen') === 'match'

// The original skill-aiming demo, superseded by the real landing page as
// the default route but kept reachable at /?screen=aiming rather than
// deleted, since it still exercises the OpponentSeaBoard aiming preview.
const isAimingDemo = params.get('screen') === 'aiming'

const DevHarness = lazy(() => import('./dev/harness.tsx'))
const MatchScreen = lazy(() => import('./screens/MatchScreen.tsx'))
const AimingDemo = lazy(() => import('./App.tsx'))

function Root() {
  if (isHarness) {
    return (
      <Suspense fallback={null}>
        <DevHarness />
      </Suspense>
    )
  }
  if (isMatchSample) {
    return (
      <Suspense fallback={null}>
        <MatchScreen />
      </Suspense>
    )
  }
  if (isAimingDemo) {
    return (
      <Suspense fallback={null}>
        <AimingDemo />
      </Suspense>
    )
  }
  return <Landing />
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)
