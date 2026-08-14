import { loadEnv, type Plugin, type ViteDevServer } from 'vite'
import { handleChatSend, handleChatPoll } from '../server/chatHandler.ts'

async function readBody(req: import('http').IncomingMessage): Promise<string> {
  const chunks: Buffer[] = []
  for await (const chunk of req) chunks.push(chunk as Buffer)
  return Buffer.concat(chunks).toString('utf8')
}

async function sendResponse(res: import('http').ServerResponse, response: Response): Promise<void> {
  res.statusCode = response.status
  response.headers.forEach((value, key) => res.setHeader(key, value))
  res.end(await response.text())
}

/**
 * Wires POST /api/chat/send and GET /api/chat/poll into the Vite dev
 * server so in-match chat can be exercised locally without a separate
 * process. The actual logic lives in server/chatHandler.ts as two plain
 * Request -> Response functions with no Vite dependency, so it drops
 * into serverless functions later (see api/chat/send.ts and
 * api/chat/poll.ts) unchanged. See chatHandler.ts's own comment for why
 * this whole feature needs a real stateful host once it is not just this
 * one long-lived dev server process anymore.
 */
export function chatApiPlugin(): Plugin {
  return {
    name: 'ciphertide-chat-api',
    configureServer(server: ViteDevServer) {
      // Same env bridging fundApi.ts does: makes the unprefixed,
      // server-only env vars (and VITE_CIPHERTIDE_ADDRESS) available on
      // process.env for this Node process, guarded so it is a no-op if
      // another plugin already loaded it.
      const env = loadEnv(server.config.mode, server.config.envDir || process.cwd(), '')
      for (const [key, value] of Object.entries(env)) {
        if (process.env[key] === undefined) process.env[key] = value
      }

      server.middlewares.use('/api/chat/send', async (req, res) => {
        const bodyText = await readBody(req)
        const request = new Request('http://localhost/api/chat/send', {
          method: req.method,
          headers: { 'content-type': 'application/json' },
          body: req.method === 'POST' ? bodyText : undefined,
        })
        await sendResponse(res, await handleChatSend(request))
      })

      server.middlewares.use('/api/chat/poll', async (req, res) => {
        // Connect strips the mounted path prefix from req.url, so what
        // remains is just the query string (or nothing). Resolving it
        // against a base URL handles both a stripped and an unstripped
        // req.url the same way, either way the query string survives.
        const url = new URL(req.url || '', 'http://localhost/')
        const request = new Request(url, { method: req.method })
        await sendResponse(res, await handleChatPoll(request))
      })
    },
  }
}
