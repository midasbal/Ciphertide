import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import type { Address, Hex } from 'viem'

/**
 * Where the play-wallet's private key lives in the browser: plain
 * localStorage, on this device only, never sent anywhere except as a
 * signature over the funding message (see fundingMessage.ts) and as the
 * signer for the player's own transactions. Read by both the
 * registration flow (src/screens/Register.tsx) and the real signer path
 * (src/lib/signer.ts), kept here once so both agree on the same key.
 */
export const PLAY_WALLET_STORAGE_KEY = 'ciphertide.playWallet.privateKey'

const PRIVATE_KEY_PATTERN = /^0x[0-9a-fA-F]{64}$/

export function isValidPrivateKey(value: string): value is Hex {
  return PRIVATE_KEY_PATTERN.test(value.trim())
}

export function readPlayWalletKey(): Hex | null {
  try {
    const raw = window.localStorage.getItem(PLAY_WALLET_STORAGE_KEY)
    if (!raw || !isValidPrivateKey(raw)) return null
    return raw as Hex
  } catch {
    return null
  }
}

export function savePlayWalletKey(key: Hex): void {
  window.localStorage.setItem(PLAY_WALLET_STORAGE_KEY, key)
}

export function generatePlayWalletKey(): Hex {
  return generatePrivateKey()
}

export function addressForKey(key: Hex): Address {
  return privateKeyToAccount(key).address
}
