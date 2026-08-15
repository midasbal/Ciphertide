import { createPublicClient, http, type Address } from 'viem'
import { chain, rpcUrls } from './chain'
import { createIncoLightning } from './inco'
import { getSigner } from './signer'
import { CiphertideClient } from '../game'
import { DEFAULT_CIPHERTIDE_ADDRESS } from './contractAddress'

const ciphertideAddress = (import.meta.env.VITE_CIPHERTIDE_ADDRESS as Address | undefined) || DEFAULT_CIPHERTIDE_ADDRESS

/**
 * Builds a ready-to-use CiphertideClient for the current signer, or null
 * if either the signer or the deployed contract address is not
 * available yet, see getSigner in ./signer for why the signer side of
 * that can be null today. This is the one seam a screen calls through
 * to talk to the deployed contract, never construct a CiphertideClient
 * directly.
 */
export async function getGameClient(): Promise<CiphertideClient | null> {
  const walletClient = getSigner()
  if (!walletClient || !ciphertideAddress) return null

  const publicClient = createPublicClient({ chain, transport: http(rpcUrls[0]) })
  const zap = await createIncoLightning()
  return new CiphertideClient({ address: ciphertideAddress, publicClient, walletClient, zap })
}
