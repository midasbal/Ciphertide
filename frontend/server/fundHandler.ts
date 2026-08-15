// The sponsor funding endpoint's core logic. A plain Request -> Response
// function with no dependency on Vite, Express, or any specific host, so
// it can be wired into the Vite dev server (see vite-plugins/fundApi.ts)
// today and dropped into whatever serverless platform is chosen later
// (see api/fund.ts) with only a thin adapter, not a rewrite.
//
// SECURITY: SPONSOR_PRIVATE_KEY is read from process.env only, on this
// server-only module, never from import.meta.env (which is what powers
// the client bundle). It is never logged, never included in a response
// body, and this file is never imported from anything under src/, the
// one-way boundary that keeps it out of the client bundle. Confirmed by
// grepping the built client bundle for the key during verification, see
// the task report.
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  parseEther,
  recoverMessageAddress,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
import { buildFundingMessage } from '../src/lib/fundingMessage'

const FUND_AMOUNT_ETH = '0.005'
// If an address already holds more than this, it counts as already
// funded and a second request is refused. Well under FUND_AMOUNT_ETH so
// a genuinely unfunded address (zero or dust from an unrelated source)
// still qualifies, and a successfully funded address does not.
const ALREADY_FUNDED_THRESHOLD_ETH = '0.001'
// Requests older than this (or from the future, which would only happen
// from clock skew or a replay attempt) are refused.
const FRESHNESS_WINDOW_MS = 5 * 60 * 1000

function rpcUrl(): string {
  return (
    process.env.VITE_BASE_SEPOLIA_RPC_URL ||
    process.env.BASE_SEPOLIA_RPC_URL ||
    baseSepolia.rpcUrls.default.http[0]
  ).split(',')[0].trim()
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

type FundRequestBody = {
  address?: string
  signature?: string
  timestamp?: number
}

export async function handleFundRequest(request: Request): Promise<Response> {
  if (request.method !== 'POST') {
    return jsonResponse(405, { error: 'method not allowed' })
  }

  let body: FundRequestBody
  try {
    body = (await request.json()) as FundRequestBody
  } catch {
    return jsonResponse(400, { error: 'invalid JSON body' })
  }

  const { address, signature, timestamp } = body
  if (!address || !isAddress(address)) {
    return jsonResponse(400, { error: 'missing or invalid address' })
  }
  if (!signature || typeof signature !== 'string') {
    return jsonResponse(400, { error: 'missing signature' })
  }
  if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) {
    return jsonResponse(400, { error: 'missing or invalid timestamp' })
  }

  // Extension point: proof-of-work check goes here, before the checks
  // below, so a request that fails it never reaches the chain reads and
  // the send. Not implemented yet, deliberately left for later.
  //
  // Extension point: per-IP rate limiting for a real deploy also goes
  // here, backed by shared state (a KV store, Redis, and so on), since a
  // serverless function has no long-lived process to hold an in-memory
  // count in. The Vite dev server has exactly that long-lived process,
  // so a basic in-memory per-IP throttle is applied one layer up, in
  // vite-plugins/fundApi.ts, ahead of this function ever being called.

  // 1. Signature-ownership: the request is only honored if it was really
  // signed by the address asking to be funded.
  const message = buildFundingMessage(address, timestamp)
  let recovered: Address
  try {
    recovered = await recoverMessageAddress({ message, signature: signature as Hex })
  } catch {
    return jsonResponse(400, { error: 'could not recover a signer from that signature' })
  }
  if (recovered.toLowerCase() !== address.toLowerCase()) {
    return jsonResponse(401, { error: 'signature does not match the requested address' })
  }

  // 2. Freshness: bounds how long a captured request could be replayed.
  const age = Date.now() - timestamp
  if (age < 0 || age > FRESHNESS_WINDOW_MS) {
    return jsonResponse(400, { error: 'request timestamp is stale or in the future, request a fresh one' })
  }

  const sponsorKey = process.env.SPONSOR_PRIVATE_KEY as Hex | undefined
  if (!sponsorKey) {
    return jsonResponse(500, { error: 'funding is not configured on this server' })
  }

  const url = rpcUrl()
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(url) })

  // 3. Fund-once: refuse an address that already has testnet ETH.
  const existingBalance = await publicClient.getBalance({ address })
  if (existingBalance > parseEther(ALREADY_FUNDED_THRESHOLD_ETH)) {
    return jsonResponse(409, { error: 'this address already holds testnet ETH, funding is once per address' })
  }

  const sponsorAccount = privateKeyToAccount(sponsorKey)
  const sponsorBalance = await publicClient.getBalance({ address: sponsorAccount.address })

  // 4. Hard cap: the stateless bound on total sponsor loss. Below this
  // floor the sponsor wallet stops paying out, full stop, regardless of
  // how well-formed or fresh the request is.
  const floor = parseEther(process.env.SPONSOR_FLOOR_ETH || '0.02')
  if (sponsorBalance <= floor) {
    return jsonResponse(503, { error: 'the sponsor wallet is out of budget, try again later' })
  }

  const walletClient = createWalletClient({ account: sponsorAccount, chain: baseSepolia, transport: http(url) })

  try {
    // account and chain are passed through explicitly even though
    // walletClient already carries both, since viem's sendTransaction
    // has separate overloads for a plain transfer versus an EIP-4844
    // blob transaction, and without an explicit account and chain at
    // the call site TypeScript can resolve to the blob overload, which
    // requires a kzg field this call has no use for.
    const hash = await walletClient.sendTransaction({
      account: sponsorAccount,
      chain: baseSepolia,
      to: address,
      value: parseEther(FUND_AMOUNT_ETH),
    })
    await publicClient.waitForTransactionReceipt({ hash })
    return jsonResponse(200, { txHash: hash })
  } catch {
    return jsonResponse(502, { error: 'the funding transaction failed to send, try again' })
  }
}
