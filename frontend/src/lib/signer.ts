import { createWalletClient, http, type Account, type WalletClient, type Transport } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
import { chain, rpcUrls } from './chain'

export type Signer = WalletClient<Transport, typeof baseSepolia, Account>

/**
 * The one seam anything that needs to sign a transaction calls through.
 * The real play-wallet layer (a browser wallet or a sponsor relayer)
 * does not exist yet, so this currently reads the same dev-only test
 * private key the harness uses (see dev/harness.tsx and .env.example).
 * Returns null, honestly, if no key is configured, rather than
 * fabricating a signer. Swapping in the real wallet layer later only
 * means changing this function, not any of its callers.
 *
 * The optional "dev-signer=b" query param lets a second browser tab act
 * as the other funded dev key, purely so the host and join paths can
 * both be exercised locally before a real wallet exists. It has no
 * effect once this function is pointed at a real wallet.
 */
export function getSigner(): Signer | null {
  const slot = new URLSearchParams(window.location.search).get('dev-signer') === 'b' ? 'b' : 'a'
  const key = (slot === 'b' ? import.meta.env.VITE_PLAYER_B_PRIVATE_KEY : import.meta.env.VITE_PLAYER_A_PRIVATE_KEY) as
    | `0x${string}`
    | undefined
  if (!key) return null

  const account = privateKeyToAccount(key)
  return createWalletClient({ account, chain, transport: http(rpcUrls[0]) })
}
