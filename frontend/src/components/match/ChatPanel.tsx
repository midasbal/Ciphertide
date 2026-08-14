import { useCallback, useEffect, useRef, useState } from 'react'
import type { Address } from 'viem'
import type { MatchId } from '../../game'
import { getSigner } from '../../lib/signer'
import { buildChatSignedMessage } from '../../lib/chatMessage'
import './ChatPanel.css'

const MAX_MESSAGE_LENGTH = 280
const POLL_INTERVAL_MS = 3000

interface ChatMessageView {
  seq: number
  address: Address
  message: string
  timestamp: number
}

interface ChatPollResponse {
  messages: ChatMessageView[]
  cursor: number
}

interface ChatSendResponse {
  seq?: number
  error?: string
}

interface ChatPanelProps {
  matchId: MatchId
  myAddress: Address
  opponentAddress: Address
}

function shortAddress(address: Address): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

/**
 * Real in-match chat, wired to the /api/chat/send and /api/chat/poll
 * endpoints (see server/chatHandler.ts). Every message is signed with
 * the sender's play-wallet and gated server-side to the two real players
 * in this match, see chatHandler.ts's own comment for the full gating
 * and anti-spam rules. Every message body below is rendered as plain
 * React text content, never as HTML, so nothing a sender types can ever
 * execute in either player's browser.
 */
export default function ChatPanel({ matchId, myAddress, opponentAddress }: ChatPanelProps) {
  const [messages, setMessages] = useState<ChatMessageView[]>([])
  const [input, setInput] = useState('')
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cursorRef = useRef(0)
  const bodyRef = useRef<HTMLDivElement | null>(null)
  const matchIdStr = matchId.toString()

  const poll = useCallback(async () => {
    try {
      const res = await fetch(`/api/chat/poll?matchId=${matchIdStr}&since=${cursorRef.current}`)
      if (!res.ok) return
      const data = (await res.json()) as ChatPollResponse
      if (data.messages.length > 0) {
        // Deduplicate by seq: the post-send poll below and this effect's
        // own interval tick can overlap and both read the same stale
        // cursor before either updates it, which would otherwise double
        // up the same message in the list.
        setMessages((prev) => {
          const seen = new Set(prev.map((m) => m.seq))
          const fresh = data.messages.filter((m) => !seen.has(m.seq))
          return fresh.length > 0 ? [...prev, ...fresh] : prev
        })
      }
      cursorRef.current = Math.max(cursorRef.current, data.cursor)
    } catch {
      // Transient network error, the next poll tries again.
    }
  }, [matchIdStr])

  useEffect(() => {
    void poll()
    const id = window.setInterval(poll, POLL_INTERVAL_MS)
    return () => window.clearInterval(id)
  }, [poll])

  useEffect(() => {
    const el = bodyRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages])

  async function handleSend(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = input.trim()
    if (!trimmed || sending) return

    const signer = getSigner()
    if (!signer) {
      setError('No wallet available to sign this message.')
      return
    }

    setSending(true)
    setError(null)
    try {
      const timestamp = Date.now()
      const signedText = buildChatSignedMessage(matchIdStr, signer.account.address, trimmed, timestamp)
      const signature = await signer.signMessage({ account: signer.account, message: signedText })

      const res = await fetch('/api/chat/send', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          matchId: matchIdStr,
          address: signer.account.address,
          message: trimmed,
          timestamp,
          signature,
        }),
      })
      const data = (await res.json()) as ChatSendResponse
      if (!res.ok) {
        setError(data.error || 'Could not send that message.')
        return
      }
      setInput('')
      await poll()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not send that message.')
    } finally {
      setSending(false)
    }
  }

  return (
    <div className="chat-panel">
      <div className="chat-panel-head">
        <p className="ct-label">Comms</p>
        <span className="chat-panel-peer ct-label">{shortAddress(opponentAddress)}</span>
      </div>
      <div className="chat-panel-body" ref={bodyRef}>
        {messages.length === 0 ? (
          <p className="chat-panel-placeholder">No messages yet. Say something to your opponent.</p>
        ) : (
          messages.map((m) => {
            const mine = m.address.toLowerCase() === myAddress.toLowerCase()
            return (
              <div key={m.seq} className={`chat-message${mine ? ' chat-message--mine' : ''}`}>
                <span className="chat-message-sender ct-label">{mine ? 'you' : shortAddress(opponentAddress)}</span>
                <p className="chat-message-text">{m.message}</p>
              </div>
            )
          })
        )}
      </div>
      {error && (
        <div className="chat-panel-error" role="alert">
          <p>{error}</p>
        </div>
      )}
      <form className="chat-panel-input-row" onSubmit={handleSend}>
        <input
          className="chat-panel-input ct-mono"
          type="text"
          placeholder="Message your opponent..."
          value={input}
          maxLength={MAX_MESSAGE_LENGTH}
          disabled={sending}
          onChange={(e) => setInput(e.target.value)}
        />
        <button type="submit" className="chat-panel-send" disabled={sending || input.trim().length === 0}>
          Send
        </button>
      </form>
    </div>
  )
}
