// Thin adapter between Vercel's Node.js function req/res shape and the
// standard Fetch API Request/Response the handlers in this folder are
// written against (see fundHandler.ts and chatHandler.ts). Kept in one
// place so api/fund.ts, api/chat/send.ts and api/chat/poll.ts do not
// each reimplement the same conversion.
//
// Typed structurally rather than against @vercel/node's own types, since
// only the handful of fields and methods these handlers actually touch
// need to match, and Vercel's Node.js req/res objects satisfy this shape
// at runtime regardless of which types package is installed.
export type NodeStyleRequest = {
  method?: string
  url?: string
  headers: Record<string, string | string[] | undefined>
  body?: unknown
}

export type NodeStyleResponse = {
  status(code: number): unknown
  setHeader(name: string, value: string): unknown
  send(body: string): unknown
}

/**
 * Builds a Fetch API Request from a Vercel Node.js function's req. Only
 * carries the content-type header and a JSON-stringified body, since
 * that is all handleFundRequest, handleChatSend and handleChatPoll ever
 * read from a request, the same minimal shape the Vite dev server's own
 * adapters (vite-plugins/fundApi.ts, vite-plugins/chatApi.ts) build.
 */
export function toFetchRequest(req: NodeStyleRequest): Request {
  const host = (Array.isArray(req.headers.host) ? req.headers.host[0] : req.headers.host) || 'localhost'
  const forwardedProto = req.headers['x-forwarded-proto']
  const proto = (Array.isArray(forwardedProto) ? forwardedProto[0] : forwardedProto) || 'https'
  const url = `${proto}://${host}${req.url || ''}`
  const method = req.method || 'GET'
  const hasBody = method !== 'GET' && method !== 'HEAD'

  return new Request(url, {
    method,
    headers: { 'content-type': 'application/json' },
    body: hasBody ? JSON.stringify(req.body ?? {}) : undefined,
  })
}

/** Writes a Fetch API Response onto a Vercel Node.js function's res. */
export async function sendFetchResponse(res: NodeStyleResponse, response: Response): Promise<void> {
  res.status(response.status)
  response.headers.forEach((value, key) => res.setHeader(key, value))
  res.send(await response.text())
}
