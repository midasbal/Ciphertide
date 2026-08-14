// Serverless entry point for sending an in-match chat message, for
// whenever this app is deployed to a real host. Not deployed anywhere
// yet, the host is not decided, so this only re-exports the portable
// core handler as a standard Fetch API Request -> Response function, the
// same shape api/fund.ts already uses. See server/chatHandler.ts for why
// a real deploy of this feature needs a stateful host behind it, not
// just this function's own code.
export { handleChatSend as default } from '../../server/chatHandler.ts'
