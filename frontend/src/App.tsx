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
      <h1>Confidential Battleship</h1>
      <p>
        Onchain 1v1 Battleship on Base Sepolia, built with Inco Lightning
        (FHE). Wallet and live contract wiring are not implemented yet, this
        demonstrates the Sonar and Barrage aiming preview only.
      </p>
      <p>
        Select a skill, then hover the opponent's sea to preview the area it
        would cover before committing.
      </p>
      <OpponentSeaBoard onUseSkill={handleUseSkill} />
    </main>
  )
}

export default App
