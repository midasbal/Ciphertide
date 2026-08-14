// Serverless entry point for polling an in-match chat's messages, for
// whenever this app is deployed to a real host. See api/chat/send.ts and
// server/chatHandler.ts for the rest of this pair's own notes.
export { handleChatPoll as default } from '../../server/chatHandler.ts'
