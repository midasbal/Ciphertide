// Chat message and rate-limit storage, backed by a real Redis store in
// production and by plain in-memory Maps in local dev.
//
// STATE CAVEAT this replaces: chatHandler.ts used to hold every message
// and the per-sender rate limiter in a module-level Map, which only
// worked because the Vite dev server is one long-lived Node process. A
// Vercel serverless deployment has no such process between invocations,
// each request can land on a fresh instance with empty memory, so
// production storage has to live somewhere every invocation can reach:
// the Redis store linked through Vercel's Storage tab (see DEPLOY.md),
// read here through the standard node-redis client.
//
// Local dev keeps the original in-memory behavior automatically: when
// neither KV_REDIS_URL nor REDIS_URL is set (no store linked), every
// function below falls back to the same Map-based logic this module
// replaces, so `npm run dev` keeps working without a real Redis
// instance.
import { createClient, type RedisClientType } from 'redis'
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

// The Redis store linked in Vercel's Storage tab injects a single
// redis:// connection URL named KV_REDIS_URL, not the REST API URL and
// token pair some Redis integrations use. REDIS_URL is a plain fallback
// for a manually configured store or a local Redis instance.
const redisUrl = process.env.KV_REDIS_URL || process.env.REDIS_URL

// A single module-scoped client, reused across warm serverless
// invocations rather than opened fresh per request. createClient itself
// does not connect, connect() is called lazily on first real use (see
// getConnectedClient), and concurrent callers share the same in-flight
// connect promise so only one connection is ever opened at a time.
let client: RedisClientType | null = null
let connectPromise: Promise<unknown> | null = null

function ensureClient(): RedisClientType {
  if (!client) {
    client = createClient({ url: redisUrl }) as RedisClientType
    client.on('error', (err) => {
      // node-redis requires an error listener or an unhandled connection
      // error crashes the process. Logged, not thrown: a request already
      // in flight surfaces its own failure through the rejected command
      // promise below.
      console.error('Redis client error', err)
    })
  }
  return client
}

async function getConnectedClient(): Promise<RedisClientType> {
  const c = ensureClient()
  if (!c.isOpen) {
    if (!connectPromise) {
      connectPromise = c.connect().finally(() => {
        connectPromise = null
      })
    }
    await connectPromise
  }
  return c
}

function messagesKey(matchId: string): string {
  return `chat:messages:${matchId}`
}
function seqKey(matchId: string): string {
  return `chat:seq:${matchId}`
}
function rateKey(addressLower: string): string {
  return `chat:rate:${addressLower}`
}

function parseStoredMessage(raw: string): ChatMessage {
  return JSON.parse(raw) as ChatMessage
}

// In-memory fallback state, only ever touched when redisUrl is unset.
const memMessagesByMatch = new Map<string, ChatMessage[]>()
const memRecentSendsByAddress = new Map<string, number[]>()
let memNextSeq = 1

/** Appends one message for matchId and returns its assigned sequence number. */
export async function appendMessage(matchId: string, address: Address, message: string, timestamp: number): Promise<number> {
  if (redisUrl) {
    const redis = await getConnectedClient()
    const seq = await redis.incr(seqKey(matchId))
    const entry: ChatMessage = { seq, matchId, address, message, timestamp }
    await redis.rPush(messagesKey(matchId), JSON.stringify(entry))
    await redis.lTrim(messagesKey(matchId), -MAX_MESSAGES_PER_MATCH, -1)
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
  if (redisUrl) {
    const redis = await getConnectedClient()
    const raw = await redis.lRange(messagesKey(matchId), 0, -1)
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

  if (redisUrl) {
    const redis = await getConnectedClient()
    const key = rateKey(addressLower)
    await redis.zRemRangeByScore(key, 0, now - windowMs)
    const count = await redis.zCard(key)
    if (count >= maxMessages) return true
    await redis.zAdd(key, { score: now, value: randomUUID() })
    await redis.pExpire(key, windowMs)
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
