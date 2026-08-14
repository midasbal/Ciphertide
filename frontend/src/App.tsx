import './App.css'
import OpponentSeaBoard from './components/OpponentSeaBoard'
import type { SkillId } from './lib/boardConstants'

function App() {
  function handleUseSkill(skill: SkillId, anchorRow: number, anchorCol: number) {
    // Placeholder until wallet and contract wiring lands: this is where
    // useSonar/useBarrage would be called with (anchorRow, anchorCol).
    console.log(`use ${skill} at anchor (${anchorRow}, ${anchorCol})`)
  }

  return (
    <main>
      <h1>Ciphertide</h1>
      <p>
        A confidential onchain naval duel on Base Sepolia, built with Inco Lightning. Wallet and live contract
        wiring are not implemented yet, this demonstrates the Sonar and Barrage aiming preview only. See the visual
        identity sample at <code>/match/1</code>.
      </p>
      <p>Select a skill, then hover the opponent's sea to preview the area it would cover before committing.</p>
      <OpponentSeaBoard onUseSkill={handleUseSkill} />
    </main>
  )
}

export default App
