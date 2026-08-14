/**
 * The exact message a play-wallet signs to prove it controls the address
 * requesting sponsor funds, and that the funding server reconstructs to
 * verify that signature. Shared by the client (src/screens/Register.tsx)
 * and the server (server/fundHandler.ts) so the two can never drift out
 * of sync with each other. Contains no secret, safe in the client
 * bundle: it is a message template, not a key.
 */
export function buildFundingMessage(address: string, timestamp: number): string {
  return `Ciphertide play-wallet funding request:${address}:${timestamp}`
}
