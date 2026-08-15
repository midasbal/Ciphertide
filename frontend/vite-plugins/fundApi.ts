import { loadEnv, type Plugin, type ViteDevServer } from 'vite'
import { handleFundRequest } from '../server/fundHandler'

// Basic per-IP throttle, dev-only: refuses a second request from the
// same address within this window. A real deploy needs this backed by
// shared state (a KV store, Redis, and so on), since a serverless
// function has no long-lived process to hold this map in, this in-memory
// map only works because the Vite dev server is one long-lived process.
// See the rate-limit extension point noted in server/fundHandler.ts.
const RATE_LIMIT_WINDOW_MS = 3000
const lastRequestByIp = new Map<string, number>()

/**
 * Wires POST /api/fund into the Vite dev server so the funding endpoint
 * can be exercised locally without a separate process. The actual logic
 * lives in server/fundHandler.ts as a plain Request -> Response function
 * with no Vite dependency, so it drops into a serverless function later
 * (see api/fund.ts) unchanged.
 */
export function fundApiPlugin(): Plugin {
  return {
    name: 'ciphertide-fund-api',
    configureServer(server: ViteDevServer) {
      // Vite's own env loading only powers import.meta.env for client
      // code, it does not populate process.env for the dev server's own
      // Node process. Loading here with an empty prefix (not just
      // VITE_) is what makes the unprefixed, server-only
      // SPONSOR_PRIVATE_KEY available to fundHandler.ts, the same way a
      // real serverless host injects env vars into process.env at
      // runtime.
      const env = loadEnv(server.config.mode, server.config.envDir || process.cwd(), '')
      for (const [key, value] of Object.entries(env)) {
        if (process.env[key] === undefined) process.env[key] = value
      }

      server.middlewares.use('/api/fund', async (req, res) => {
        if (req.method !== 'POST') {
          res.statusCode = 405
          res.end('method not allowed')
          return
        }

        const ip = req.socket.remoteAddress || 'unknown'
        const now = Date.now()
        const last = lastRequestByIp.get(ip)
        if (last !== undefined && now - last < RATE_LIMIT_WINDOW_MS) {
          res.statusCode = 429
          res.setHeader('content-type', 'application/json')
          res.end(JSON.stringify({ error: 'too many requests, slow down and try again' }))
          return
        }
        lastRequestByIp.set(ip, now)

        const chunks: Buffer[] = []
        for await (const chunk of req) chunks.push(chunk as Buffer)
        const bodyText = Buffer.concat(chunks).toString('utf8')

        const request = new Request('http://localhost/api/fund', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: bodyText,
        })

        const response = await handleFundRequest(request)
        res.statusCode = response.status
        response.headers.forEach((value, key) => res.setHeader(key, value))
        res.end(await response.text())
      })
    },
  }
}
