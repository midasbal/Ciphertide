// Vercel Node.js serverless function for sending an in-match chat
// message. Adapts Vercel's req/res shape to the portable Fetch handler
// in server/chatHandler.ts, the same handler the Vite dev server calls
// directly in local dev (see vite-plugins/chatApi.ts).
import { handleChatSend } from '../../server/chatHandler.js'
import { toFetchRequest, sendFetchResponse, type NodeStyleRequest, type NodeStyleResponse } from '../../server/vercelAdapter.js'

export default async function handler(req: NodeStyleRequest, res: NodeStyleResponse): Promise<void> {
  const response = await handleChatSend(toFetchRequest(req))
  await sendFetchResponse(res, response)
}
