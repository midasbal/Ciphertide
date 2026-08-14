import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

// Dev-only route for the throwaway game-client proof harness, never
// linked from the real app. Visit /?harness=1 to reach it. Lazy loaded
// so its two-private-key wiring never ships in the normal App bundle
// path.
const isHarness = new URLSearchParams(window.location.search).has('harness')
const DevHarness = lazy(() => import('./dev/harness.tsx'))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {isHarness ? (
      <Suspense fallback={null}>
        <DevHarness />
      </Suspense>
    ) : (
      <App />
    )}
  </StrictMode>,
)
