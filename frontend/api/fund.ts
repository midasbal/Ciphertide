// Vercel Node.js serverless function for the sponsor funding endpoint.
// Adapts Vercel's req/res shape to the portable Fetch handler in
// server/fundHandler.ts, the same handler the Vite dev server calls
// directly in local dev (see vite-plugins/fundApi.ts), so both paths run
// the exact same logic and cannot drift apart.
import { handleFundRequest } from '../server/fundHandler'
import { toFetchRequest, sendFetchResponse, type NodeStyleRequest, type NodeStyleResponse } from '../server/vercelAdapter'

export default async function handler(req: NodeStyleRequest, res: NodeStyleResponse): Promise<void> {
  const response = await handleFundRequest(toFetchRequest(req))
  await sendFetchResponse(res, response)
}
