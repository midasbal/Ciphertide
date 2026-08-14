import { createWalletClient, http, type Account, type WalletClient, type Transport } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
import { chain, rpcUrls } from './chain'
import { readPlayWalletKey } from './playWallet'
import type { Hex } from 'viem'

export type Signer = WalletClient<Transport, typeof baseSepolia, Account>

function buildSigner(key: Hex): Signer {
  const account = privateKeyToAccount(key)
  return createWalletClient({ account, chain, transport: http(rpcUrls[0]) })
}

/**
 * The one seam anything that needs to sign a transaction calls through.
 * The real path is the play-wallet generated and funded at /register,
 * stored in localStorage (see lib/playWallet.ts): if one exists, this
 * signs with it. Returns null, honestly, if neither that nor an explicit
 * dev override is present, rather than fabricating a signer.
 *
 * The explicit "?dev-signer=a" or "?dev-signer=b" query param opts into
 * one of the two funded dev-only test keys the harness also uses (see
 * dev/harness.tsx and .env.example), purely so both sides of a match can
 * be exercised locally without going through registration twice in the
 * same browser. It only activates when the param is present, it is never
 * a silent default, so a play-wallet is always the real path once one
 * exists.
 */
export function getSigner(): Signer | null {
  const devSlot = new URLSearchParams(window.location.search).get('dev-signer')
  if (devSlot === 'a' || devSlot === 'b') {
    const key = (devSlot === 'b' ? import.meta.env.VITE_PLAYER_B_PRIVATE_KEY : import.meta.env.VITE_PLAYER_A_PRIVATE_KEY) as
      | Hex
      | undefined
    if (key) return buildSigner(key)
  }

  const playWalletKey = readPlayWalletKey()
  if (playWalletKey) return buildSigner(playWalletKey)

  return null
}
