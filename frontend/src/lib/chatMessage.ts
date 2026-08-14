/**
 * The exact message a play-wallet signs to send an in-match chat message,
 * and that the chat server reconstructs to verify that signature. Binds
 * the signature to this exact matchId, sender, timestamp and message
 * text, so a captured signature cannot be replayed against a different
 * match or with different text. Shared by the client (ChatPanel.tsx) and
 * the server (server/chatHandler.ts) so the two can never drift out of
 * sync with each other. Contains no secret, safe in the client bundle:
 * it is a message template, not a key.
 */
export function buildChatSignedMessage(matchId: string, address: string, message: string, timestamp: number): string {
  return `Ciphertide match chat:${matchId}:${address}:${timestamp}:${message}`
}
