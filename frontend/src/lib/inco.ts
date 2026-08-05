import { Lightning } from '@inco/lightning-js/lite'
import { rpcUrls } from './chain'

/**
 * Setup-only wiring for the Inco Lightning JS SDK, targeting Base Sepolia
 * testnet only. No game logic here yet, see docs/inco.md for orientation
 * and always check the Inco docs MCP for current API details before
 * building on top of this.
 */
export async function createIncoLightning() {
  return Lightning.baseSepoliaTestnet({ hostChainRpcUrls: rpcUrls })
}
