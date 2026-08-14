import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import './styles/global.css'
import App from './App.tsx'

// Dev-only route for the throwaway game-client proof harness, never
// linked from the real app. Visit /?harness=1 to reach it. Lazy loaded
// so its two-private-key wiring never ships in the normal App bundle
// path.
const params = new URLSearchParams(window.location.search)
const isHarness = params.has('harness')

// Dev-only route for the in-match sample screen: the visual identity's
// hardest-working screen, rendered with stubbed data, no contract or
// wallet. Visit /?screen=match to reach it. This is design work, not the
// wired app, so it stays behind the same query-param route pattern as
// the harness rather than replacing the real App entry.
const isMatchSample = params.get('screen') === 'match'

const DevHarness = lazy(() => import('./dev/harness.tsx'))
const MatchScreen = lazy(() => import('./screens/MatchScreen.tsx'))

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
  return <App />
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)
