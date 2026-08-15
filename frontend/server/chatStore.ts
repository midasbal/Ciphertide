// Chat message and rate-limit storage, backed by a real Redis store in
// production and by plain in-memory Maps in local dev.
//
// STATE CAVEAT this replaces: chatHandler.ts used to hold every message
// and the per-sender rate limiter in a module-level Map, which only
// worked because the Vite dev server is one long-lived Node process. A
// Vercel serverless deployment has no such process between invocations,
// each request can land on a fresh instance with empty memory, so
// production storage has to live somewhere every invocation can reach:
// a Redis store linked through Vercel's Storage tab (Upstash under the
// hood, see DEPLOY.md), read here through the standard @upstash/redis
// client.
//
// Local dev keeps the original in-memory behavior automatically: when
// neither KV_REST_API_URL/KV_REST_API_TOKEN nor
// UPSTASH_REDIS_REST_URL/UPSTASH_REDIS_REST_TOKEN are set (no store
// linked), every function below falls back to the same Map-based logic
// this module replaces, so `npm run dev` keeps working without a real
// Redis instance.
import { Redis } from '@upstash/redis'
import { randomUUID } from 'node:crypto'
import type { Address } from 'viem'

export type ChatMessage = {
  seq: number
  matchId: string
  address: Address
  message: string
  timestamp: number
}

const MAX_MESSAGES_PER_MATCH = 500

// Vercel's Storage tab injects KV_REST_API_URL / KV_REST_API_TOKEN when a
// Redis store is linked to the project (the naming its Redis product has
// used since before the @vercel/kv package was deprecated in favor of
// talking to the same store through @upstash/redis directly). A manually
// added Upstash Marketplace integration instead injects Upstash's own
// UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN names. Checking both
// covers either path without the owner needing to rename anything.
const redisUrl = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
const redisToken = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN
const redis = redisUrl && redisToken ? new Redis({ url: redisUrl, token: redisToken }) : null

function messagesKey(matchId: string): string {
  return `chat:messages:${matchId}`
}
function seqKey(matchId: string): string {
  return `chat:seq:${matchId}`
}
function rateKey(addressLower: string): string {
  return `chat:rate:${addressLower}`
}

function parseStoredMessage(raw: string | ChatMessage): ChatMessage {
  return typeof raw === 'string' ? (JSON.parse(raw) as ChatMessage) : raw
}

// In-memory fallback state, only ever touched when redis is null.
const memMessagesByMatch = new Map<string, ChatMessage[]>()
const memRecentSendsByAddress = new Map<string, number[]>()
let memNextSeq = 1

/** Appends one message for matchId and returns its assigned sequence number. */
export async function appendMessage(matchId: string, address: Address, message: string, timestamp: number): Promise<number> {
  if (redis) {
    const seq = await redis.incr(seqKey(matchId))
    const entry: ChatMessage = { seq, matchId, address, message, timestamp }
    await redis.rpush(messagesKey(matchId), JSON.stringify(entry))
    await redis.ltrim(messagesKey(matchId), -MAX_MESSAGES_PER_MATCH, -1)
    return seq
  }

  const seq = memNextSeq++
  const entry: ChatMessage = { seq, matchId, address, message, timestamp }
  const list = memMessagesByMatch.get(matchId) || []
  list.push(entry)
  if (list.length > MAX_MESSAGES_PER_MATCH) list.splice(0, list.length - MAX_MESSAGES_PER_MATCH)
  memMessagesByMatch.set(matchId, list)
  return seq
}

/** Every message for matchId with seq greater than since, plus the latest seq as the next poll cursor. */
export async function messagesSince(matchId: string, since: number): Promise<{ messages: ChatMessage[]; cursor: number }> {
  if (redis) {
    const raw = await redis.lrange<string | ChatMessage>(messagesKey(matchId), 0, -1)
    const list = raw.map(parseStoredMessage)
    const messages = list.filter((m) => m.seq > since)
    const cursor = list.length > 0 ? list[list.length - 1].seq : since
    return { messages, cursor }
  }

  const list = memMessagesByMatch.get(matchId) || []
  const messages = list.filter((m) => m.seq > since)
  const cursor = list.length > 0 ? list[list.length - 1].seq : since
  return { messages, cursor }
}

/**
 * True (and rejected) once addressLower has sent maxMessages within the
 * trailing windowMs, independent of matchId so a sender cannot dodge the
 * limit by spraying messages across matches, the same rule the in-memory
 * version enforced.
 */
export async function isRateLimited(addressLower: string, windowMs: number, maxMessages: number): Promise<boolean> {
  const now = Date.now()

  if (redis) {
    const key = rateKey(addressLower)
    await redis.zremrangebyscore(key, 0, now - windowMs)
    const count = await redis.zcard(key)
    if (count >= maxMessages) return true
    await redis.zadd(key, { score: now, member: randomUUID() })
    await redis.pexpire(key, windowMs)
    return false
  }

  const recent = (memRecentSendsByAddress.get(addressLower) || []).filter((t) => now - t < windowMs)
  if (recent.length >= maxMessages) {
    memRecentSendsByAddress.set(addressLower, recent)
    return true
  }
  recent.push(now)
  memRecentSendsByAddress.set(addressLower, recent)
  return false
}
