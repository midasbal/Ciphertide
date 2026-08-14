// Throwaway dev-only harness, not the real game UI. Proves the game
// client module (src/game/) runs in the browser against the live
// deployment: create a match, join it, place both boards, roll dice,
// fire one shot, and show the decrypted own board. Reached at
// /?harness=1, see main.tsx. Uses two raw test private keys read from
// .env purely so this one page can drive both sides of a real match by
// itself, the way e2e/run.ts does headlessly; the real game only ever
// needs one signer per browser tab, from a real wallet or the sponsor
// layer, neither of which exists yet.
import { useState } from 'react'
import { createPublicClient, createWalletClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { chain, rpcUrls } from '../lib/chain'
import { createIncoLightning } from '../lib/inco'
import { CiphertideClient, PHASE_NAMES, type ActionStage } from '../game'

const ciphertideAddress = import.meta.env.VITE_CIPHERTIDE_ADDRESS as `0x${string}` | undefined
const playerAKey = import.meta.env.VITE_PLAYER_A_PRIVATE_KEY as `0x${string}` | undefined
const playerBKey = import.meta.env.VITE_PLAYER_B_PRIVATE_KEY as `0x${string}` | undefined

type LogLine = { text: string; ms?: number }

export default function DevHarness() {
  const [lines, setLines] = useState<LogLine[]>([])
  const [running, setRunning] = useState(false)
  const [board, setBoard] = useState<{ boardMask: bigint; mineMask: bigint } | null>(null)

  const log = (text: string) => setLines((prev) => [...prev, { text }])

  async function run() {
    if (!ciphertideAddress || !playerAKey || !playerBKey) {
      log('Missing VITE_CIPHERTIDE_ADDRESS, VITE_PLAYER_A_PRIVATE_KEY or VITE_PLAYER_B_PRIVATE_KEY in frontend/.env')
      return
    }
    setRunning(true)
    setBoard(null)
    setLines([])

    const started = Date.now()
    const stage = (label: string) => (s: ActionStage, detail?: string) => {
      const ms = Date.now() - started
      log(`  [${(ms / 1000).toFixed(1)}s] ${label}: ${s}${detail ? ` (${detail})` : ''}`)
    }

    try {
      const publicClient = createPublicClient({ chain, transport: http(rpcUrls[0]) })
      const accountA = privateKeyToAccount(playerAKey)
      const accountB = privateKeyToAccount(playerBKey)
      const walletA = createWalletClient({ account: accountA, chain, transport: http(rpcUrls[0]) })
      const walletB = createWalletClient({ account: accountB, chain, transport: http(rpcUrls[0]) })
      log(`Player A: ${accountA.address}`)
      log(`Player B: ${accountB.address}`)

      log('Connecting to Inco Lightning...')
      const zap = await createIncoLightning()
      log(`Inco executor: ${zap.executorAddress}`)

      const clientA = new CiphertideClient({ address: ciphertideAddress, publicClient, walletClient: walletA, zap })
      const clientB = new CiphertideClient({ address: ciphertideAddress, publicClient, walletClient: walletB, zap })

      log('Creating match (captain 2, Bombardment)...')
      const matchId = await clientA.createMatch(2)
      log(`Match ${matchId} created`)

      log('Joining match (captain 3, Rake)...')
      await clientB.joinMatch(matchId, 3)
      log('Joined')

      log('Placing Player A board (7 steps, tight polling the final reveal)...')
      const placedA = await clientA.placeBoard(matchId, stage('Player A placement'))
      log(`Player A allPlaced=${placedA.allPlaced}`)

      log('Placing Player B board (7 steps, tight polling the final reveal)...')
      const placedB = await clientB.placeBoard(matchId, stage('Player B placement'))
      log(`Player B allPlaced=${placedB.allPlaced}`)

      log('Rolling dice...')
      await clientA.rollDiceUntilDecided(matchId, stage('dice roll'))
      const phase = await clientA.getPhase(matchId)
      log(`Phase: ${PHASE_NAMES[phase]}`)

      const turn = await clientA.getTurn(matchId)
      const actor = turn.toLowerCase() === accountA.address.toLowerCase() ? clientA : clientB
      const actorLabel = actor === clientA ? 'Player A' : 'Player B'
      log(`${actorLabel}'s turn, firing a shot at cell 0...`)
      const shot = await actor.shoot(matchId, 0, stage(`${actorLabel} shoot`))
      log(`Shot result: hit=${shot.hit} mine=${shot.mine} shieldBreak=${shot.shieldBreak} win=${shot.win}`)

      log("Decrypting Player A's own board...")
      const decrypted = await clientA.decryptMyBoard(matchId)
      setBoard(decrypted)
      log(`Own board mask: 0x${decrypted.boardMask.toString(16)}`)
      log(`Own mine mask: 0x${decrypted.mineMask.toString(16)}`)

      log(`Done in ${((Date.now() - started) / 1000).toFixed(1)}s total.`)
    } catch (err) {
      log(`Failed: ${err instanceof Error ? err.message : String(err)}`)
      console.error(err)
    } finally {
      setRunning(false)
    }
  }

  return (
    <main style={{ fontFamily: 'monospace', padding: '1rem', maxWidth: '48rem' }}>
      <h1>Ciphertide dev harness</h1>
      <p>
        Throwaway page, not the real UI. Drives a full real match against the live Base Sepolia deployment using two
        test signers, proving src/game/ works in the browser.
      </p>
      <button onClick={run} disabled={running}>
        {running ? 'Running...' : 'Run live match'}
      </button>
      {board && (
        <div style={{ marginTop: '1rem' }}>
          <strong>Decrypted own board</strong>
          <BoardGrid boardMask={board.boardMask} mineMask={board.mineMask} />
        </div>
      )}
      <pre style={{ whiteSpace: 'pre-wrap', marginTop: '1rem', fontSize: '0.85rem' }}>
        {lines.map((l) => l.text).join('\n')}
      </pre>
    </main>
  )
}

function BoardGrid({ boardMask, mineMask }: { boardMask: bigint; mineMask: bigint }) {
  const size = 15
  const rows = []
  for (let r = 0; r < size; r++) {
    const cells = []
    for (let c = 0; c < size; c++) {
      const bit = 1n << BigInt(r * size + c)
      const isShip = (boardMask & bit) !== 0n
      const isMine = (mineMask & bit) !== 0n
      cells.push(
        <span
          key={c}
          style={{
            display: 'inline-block',
            width: '1.2em',
            textAlign: 'center',
            background: isShip ? '#345' : isMine ? '#843' : '#123',
            color: '#fff',
          }}
        >
          {isShip ? 'S' : isMine ? 'M' : '.'}
        </span>,
      )
    }
    rows.push(
      <div key={r} style={{ lineHeight: '1.2em' }}>
        {cells}
      </div>,
    )
  }
  return <div style={{ marginTop: '0.5rem' }}>{rows}</div>
}
