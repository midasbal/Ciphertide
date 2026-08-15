import type { Address } from 'viem'

// The deployed Ciphertide address on Base Sepolia. Public information,
// not a secret: the same address is already committed in
// contracts/deployments/baseSepolia.json and verified on Basescan.
// Committed here as a default so the app builds and runs cleanly on a
// fresh Vercel deploy with no required env var, while VITE_CIPHERTIDE_ADDRESS
// still overrides it if the contract is ever redeployed without a code
// change.
export const DEFAULT_CIPHERTIDE_ADDRESS: Address = '0xbf4469258DD6ACb1f5F13E488f02Ea25D7958C44'
