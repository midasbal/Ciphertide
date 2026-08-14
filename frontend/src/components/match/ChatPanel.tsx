import './ChatPanel.css'

/**
 * The chat panel's space, reserved and styled, not wired to real
 * messaging yet. Real-time chat needs its own anti-spam and security
 * pass, a separate piece of work, so this stays a clearly disabled
 * placeholder rather than pretending to work.
 */
export default function ChatPanel() {
  return (
    <div className="chat-panel">
      <div className="chat-panel-head">
        <p className="ct-label">Comms</p>
        <span className="chat-panel-soon ct-label">Coming Soon</span>
      </div>
      <div className="chat-panel-body" aria-hidden="true">
        <p className="chat-panel-placeholder">Match chat is not wired up yet. Callouts, taunts, and gg's land here next.</p>
      </div>
      <div className="chat-panel-input-row">
        <input className="chat-panel-input ct-mono" type="text" placeholder="Chat coming soon" disabled />
        <button type="button" className="chat-panel-send" disabled title="Coming soon">
          Send
        </button>
      </div>
    </div>
  )
}
