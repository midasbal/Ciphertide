import { toHex, type Hex } from 'viem'
import type { Lightning } from '@inco/lightning-js/lite'
import type { AttestationResult } from './types'

// Ported from e2e/run.ts's revealAsAttestations and tightPollReveal: the
// e2e script proved this against the live deployment first, this module
// is a faithful port rather than a shared package, since the two projects
// have no workspace linking today (see the top comment on client.ts).

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// The SDK types plaintext.value as bigint | boolean, since a revealed
// handle can be either an euint256 (a number) or an ebool (a win flag,
// among others). Every reveal in this module ends up compared against
// zero (nonZero(...)), so a plain 0n/1n coercion for the boolean case
// keeps that comparison correct either way.
type RevealResult = Awaited<ReturnType<Lightning['attestedReveal']>>[number]

function toAttestationResults(results: RevealResult[], handles: Hex[]): AttestationResult[] {
  const byHandle = new Map(results.map((r) => [r.handle.toLowerCase(), r]))
  return handles.map((h) => {
    const r = byHandle.get(h.toLowerCase())
    if (!r) throw new Error(`no attestation returned for handle ${h}`)
    const value = typeof r.plaintext.value === 'boolean' ? (r.plaintext.value ? 1n : 0n) : r.plaintext.value
    return {
      attestation: { handle: r.handle, value: toHex(value, { size: 32 }) },
      signatures: r.covalidatorSignatures.map((s) => toHex(s)),
    }
  })
}

// A real run against Base Sepolia showed the covalidator can take longer
// than a modest retry budget to have a handle's ciphertext ready: right
// after a reveal, attestedReveal can fail repeatedly with "ciphertext for
// handle ... not found, it might not have been processed yet" or, for the
// same underlying reason, "PermissionDenied: acl disallowed" (the SDK's
// own backoff retries the first shape but not the second). This wraps the
// whole reveal call in its own outer retry so either shape gets patience.
const RETRY = { maxRetries: 14, baseDelayInMs: 2000, backoffFactor: 1.5 }

export async function revealAsAttestations(zap: Lightning, handles: Hex[]): Promise<AttestationResult[]> {
  let lastError: unknown
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const results = await zap.attestedReveal(handles, { backoffConfig: RETRY })
      return toAttestationResults(results, handles)
    } catch (err) {
      lastError = err
      await sleep(15000 * (attempt + 1))
    }
  }
  throw lastError
}

// Precisely measures the true reveal-ready time: from action tx mined to
// the first genuine attestedReveal success, polled every 1.5s with
// exactly one real network attempt per poll (maxRetries: 1, not 0: the
// SDK's retryWithBackoff loop runs while attempt < maxRetries, so 0
// iterates zero times and throws immediately without ever calling the
// covalidator). This is the number that isolates real covalidator
// latency from the coarse exponential backoff revealAsAttestations above
// uses for its retries, which overstates true latency for fast reveals
// since its own growing delay dominates.
export async function tightPollReveal(
  zap: Lightning,
  handles: Hex[],
  onAttempt?: (attempt: number, elapsedMs: number) => void,
): Promise<AttestationResult[]> {
  const startedAt = Date.now()
  for (let attempt = 1; attempt <= 150; attempt++) {
    try {
      const results = await zap.attestedReveal(handles, {
        backoffConfig: { maxRetries: 1, baseDelayInMs: 0, backoffFactor: 1 },
      })
      if (results.length === handles.length) {
        onAttempt?.(attempt, Date.now() - startedAt)
        return toAttestationResults(results, handles)
      }
    } catch {
      // Not ready yet, the loop's own 1.5s spacing is the only delay.
    }
    onAttempt?.(attempt, Date.now() - startedAt)
    await sleep(1500)
  }
  throw new Error('tight poll gave up after 150 attempts')
}
