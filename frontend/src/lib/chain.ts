import { baseSepolia } from 'viem/chains'

/**
 * This project targets Base Sepolia testnet only.
 * Do not add mainnet or other chains here.
 */
export const chain = baseSepolia

export const rpcUrls = (import.meta.env.VITE_BASE_SEPOLIA_RPC_URL ?? baseSepolia.rpcUrls.default.http[0])
  .split(',')
  .map((url: string) => url.trim())
