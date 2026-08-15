// Vercel Node.js serverless function for polling an in-match chat's
// messages. See api/chat/send.ts and server/chatHandler.ts for the rest
// of this pair's own notes.
import { handleChatPoll } from '../../server/chatHandler.js'
import { toFetchRequest, sendFetchResponse, type NodeStyleRequest, type NodeStyleResponse } from '../../server/vercelAdapter.js'

export default async function handler(req: NodeStyleRequest, res: NodeStyleResponse): Promise<void> {
  const response = await handleChatPoll(toFetchRequest(req))
  await sendFetchResponse(res, response)
}
