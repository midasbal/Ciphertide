// Real-time in-match chat's core logic. Two plain Request -> Response
// functions with no dependency on Vite, Express, or any specific host,
// so they wire into the Vite dev server today (see
// vite-plugins/chatApi.ts) and drop into whatever serverless platform is
// chosen later (see api/chat/send.ts and api/chat/poll.ts) with only a
// thin adapter, the same pattern server/fundHandler.ts already uses.
//
// Message storage and the per-sender rate limiter both live in
// chatStore.ts, backed by Redis on a real deploy and by an in-memory Map
// in local dev, see that file's own comment for why a serverless
// deployment cannot hold either in plain module memory the way this file
// once did.
import { createPublicClient, http, isAddress, recoverMessageAddress, type Address, type Hex } from 'viem'
import { baseSepolia } from 'viem/chains'
import { buildChatSignedMessage } from '../src/lib/chatMessage.js'
import { DEFAULT_CIPHERTIDE_ADDRESS } from '../src/lib/contractAddress.js'
import { appendMessage, isRateLimited, messagesSince } from './chatStore.js'

const MAX_MESSAGE_LENGTH = 280
const RATE_LIMIT_WINDOW_MS = 10_000
const RATE_LIMIT_MAX_MESSAGES = 5
// A signed send request older than this (or from the future, clock skew
// or a replay attempt) is refused, the same freshness pattern
// server/fundHandler.ts uses for its own signed request.
const FRESHNESS_WINDOW_MS = 5 * 60 * 1000

function rpcUrl(): string {
  return (
    process.env.VITE_BASE_SEPOLIA_RPC_URL ||
    process.env.BASE_SEPOLIA_RPC_URL ||
    baseSepolia.rpcUrls.default.http[0]
  )
    .split(',')[0]
    .trim()
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

// Only the one read this handler needs, inlined rather than importing the
// full contract ABI, the same minimal-ABI pattern server/fundHandler.ts
// uses for the executor's getFee.
const getPlayerAddressAbi = [
  {
    type: 'function',
    name: 'getPlayerAddress',
    stateMutability: 'view',
    inputs: [
      { name: 'matchId', type: 'uint256' },
      { name: 'playerIdx', type: 'uint8' },
    ],
    outputs: [{ type: 'address' }],
  },
] as const

async function isMatchPlayer(matchId: bigint, address: Address): Promise<boolean> {
  const contractAddress = (process.env.VITE_CIPHERTIDE_ADDRESS as Address | undefined) || DEFAULT_CIPHERTIDE_ADDRESS
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(rpcUrl()) })
  const [playerA, playerB] = await Promise.all([
    publicClient.readContract({
      address: contractAddress,
      abi: getPlayerAddressAbi,
      functionName: 'getPlayerAddress',
      args: [matchId, 0],
    }),
    publicClient.readContract({
      address: contractAddress,
      abi: getPlayerAddressAbi,
      functionName: 'getPlayerAddress',
      args: [matchId, 1],
    }),
  ])
  const lower = address.toLowerCase()
  return playerA.toLowerCase() === lower || playerB.toLowerCase() === lower
}

type SendRequestBody = {
  matchId?: string
  address?: string
  message?: string
  timestamp?: number
  signature?: string
}

export async function handleChatSend(request: Request): Promise<Response> {
  if (request.method !== 'POST') {
    return jsonResponse(405, { error: 'method not allowed' })
  }

  let body: SendRequestBody
  try {
    body = (await request.json()) as SendRequestBody
  } catch {
    return jsonResponse(400, { error: 'invalid JSON body' })
  }

  const { matchId, address, message, timestamp, signature } = body
  if (!matchId || !/^\d+$/.test(matchId)) {
    return jsonResponse(400, { error: 'missing or invalid matchId' })
  }
  if (!address || !isAddress(address)) {
    return jsonResponse(400, { error: 'missing or invalid address' })
  }
  if (typeof message !== 'string' || message.trim().length === 0) {
    return jsonResponse(400, { error: 'message cannot be empty' })
  }
  if (message.length > MAX_MESSAGE_LENGTH) {
    return jsonResponse(400, { error: `message is too long, ${MAX_MESSAGE_LENGTH} characters max` })
  }
  if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) {
    return jsonResponse(400, { error: 'missing or invalid timestamp' })
  }
  if (!signature || typeof signature !== 'string') {
    return jsonResponse(400, { error: 'missing signature' })
  }

  const age = Date.now() - timestamp
  if (age < 0 || age > FRESHNESS_WINDOW_MS) {
    return jsonResponse(400, { error: 'request timestamp is stale or in the future, request a fresh one' })
  }

  // 1. Signature-ownership: the message is only accepted if it was really
  // signed by the address claiming to send it, over these exact
  // contents, so neither the text nor the sender can be forged.
  const signedText = buildChatSignedMessage(matchId, address, message, timestamp)
  let recovered: Address
  try {
    recovered = await recoverMessageAddress({ message: signedText, signature: signature as Hex })
  } catch {
    return jsonResponse(400, { error: 'could not recover a signer from that signature' })
  }
  if (recovered.toLowerCase() !== address.toLowerCase()) {
    return jsonResponse(401, { error: 'signature does not match the requested address' })
  }

  // 2. Match membership: only the two real players in this match can
  // speak in it, read straight from the deployed contract so it can
  // never be spoofed from the client.
  let belongsToMatch: boolean
  try {
    belongsToMatch = await isMatchPlayer(BigInt(matchId), address)
  } catch {
    return jsonResponse(502, { error: 'could not verify match membership on chain, try again' })
  }
  if (!belongsToMatch) {
    return jsonResponse(403, { error: 'this address is not a player in this match' })
  }

  // 3. Anti-spam: a per-sender rate limit.
  if (await isRateLimited(address.toLowerCase(), RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX_MESSAGES)) {
    return jsonResponse(429, { error: 'sending too fast, slow down and try again' })
  }

  const seq = await appendMessage(matchId, address, message, timestamp)
  return jsonResponse(200, { seq })
}

export async function handleChatPoll(request: Request): Promise<Response> {
  if (request.method !== 'GET') {
    return jsonResponse(405, { error: 'method not allowed' })
  }

  const url = new URL(request.url)
  const matchId = url.searchParams.get('matchId')
  const sinceParam = url.searchParams.get('since')
  if (!matchId || !/^\d+$/.test(matchId)) {
    return jsonResponse(400, { error: 'missing or invalid matchId' })
  }
  const since = sinceParam && /^\d+$/.test(sinceParam) ? Number(sinceParam) : 0

  const { messages, cursor } = await messagesSince(matchId, since)
  return jsonResponse(200, { messages, cursor })
}
