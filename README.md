# Ciphertide

A fully onchain 1v1 hidden-fleet naval duel on Base Sepolia. Two players
place a fleet on a 15x15 board, then take turns firing at each other.
Nobody, not even the contract owner, can see either player's fleet layout
until a shot actually lands on it. The game runs entirely through smart
contract calls, confidentiality included: there is no off-chain server
holding a hidden state.

Built for the Inco Track of the Summer Game Jam.

## What makes this confidential

Fleet placement, per-ship layout, and mine positions all live onchain as
encrypted values, computed on and compared against each other without
ever being decrypted, using [Inco Lightning](https://docs.inco.org).

Inco Lightning is not FHE and not zk. It is Trusted Execution Environment
(TEE) based confidential compute for the EVM. Concretely, in this game:

- A player's board and mine masks are stored onchain as `euint256`
  handles: opaque references to ciphertext that lives off-chain. Reading
  the handle reveals nothing.
- Placement itself is confidential end to end: the contract draws random
  ship positions, checks them for overlap, and folds them into the
  board mask, all as encrypted operations over encrypted values, so even
  the placement logic never sees a plaintext layout.
- When something needs to become known (a shot's hit/miss result, a
  sonar sweep's yes/no, whether a whole fleet is destroyed), the contract
  calls `e.reveal` on that single encrypted value. Inco's covalidator
  network picks this up, decrypts it inside a secure enclave, and returns
  a signed attestation.
- The contract verifies that attestation's signatures and that it matches
  the pending handle before trusting the revealed value (see every
  `confirm*` function in `contracts/src/Ciphertide.sol`). "Provably fair"
  here means a verified covalidator attestation, not a cryptographic
  proof.
- Only the specific bit the game rules call for is ever revealed: did
  this cell hit, did this mine trigger, did this sonar sweep find a
  ship, is the whole fleet destroyed. The board layout and mine
  positions themselves are never decrypted, they only ever get OR'd,
  AND'd, and compared against other encrypted values onchain.

See `contracts/src/CiphertideMechanics.sol` for the confidential
placement and shot-resolution logic, and `frontend/src/game/client.ts`
for the client side of the reveal-and-confirm flow.

## Gameplay

- **Board**: 15x15 (225 cells), coordinates like `G7`.
- **Fleet**: 6 ships, lengths 5, 4, 4, 4, 3, 3, placed automatically and
  confidentially by the contract (not by the player dragging ships
  around). Each player also gets 2 mines, placed on water cells only.
- **Clock**: a 300 second chess clock per player. Time is only charged
  for the seconds actually spent between the start of one action and the
  start of the next, so the clock is not running during the covalidator
  reveal wait.
- **Turns**: a hit keeps the turn, a miss passes it. Triggering an
  opponent's mine grants that mine's owner one bonus action on their
  next turn, spent automatically the next time their turn comes around.
- **Captains**: pick one of 5 before a match. Every captain shares two
  shared skills, plus one unique skill of their own, each usable once
  per match:
  - **Shield** (starter): seal one of your own cells against the next
    hit that finds it.
  - **Bombardment** (starter): mark a 10x10 zone and strike 15 cells
    inside it at random. *Temporarily disabled, see Known Limitations.*
  - **Rake** (starter): strike three random cells along a chosen row.
  - **Salvo** (unlockable): name three exact cells and hit all three,
    then forfeit your next turn.
  - **Carpet** (unlockable): strike a 3x3 block, and only ever reveals
    anything if a ship was actually inside it.
  - **Sonar** (shared): sweep a 5x5 area for a yes/no "any ship inside"
    signal, no cells revealed.
  - **Barrage** (shared): strike 4 to 6 random cells inside a 4x4 area.
    *Temporarily disabled, see Known Limitations.*

## Architecture

```
contracts/   Foundry project: Ciphertide.sol (game contract),
             CiphertideMechanics.sol (confidential placement and shot
             resolution library), CiphertideTypes.sol (shared storage
             layout), plus @inco/lightning as a dependency.
frontend/    React + TypeScript + Vite app, wired for Base Sepolia only.
e2e/         A headless script that plays a full match against the live
             deployment through the real Inco Lightning flow, used to
             prove the contract end to end without a browser.
```

Inside `frontend/`:

- `src/game/client.ts`: a signer-agnostic `CiphertideClient`. Takes any
  viem `WalletClient` (a raw key today, an injected wallet or a
  sponsored relayer later) and drives the full match flow: create and
  join, stepped placement, shots, every skill, and the reveal-then-
  confirm dance each of those needs. This is the one seam every screen
  talks to the contract through.
- `src/screens/MatchScreen.tsx`: the real match screen, wired end to end
  to `CiphertideClient`, no mocked state.
- `server/fundHandler.ts` + `vite-plugins/fundApi.ts` + `api/fund.ts`:
  the play-wallet sponsor funding endpoint. A player's browser generates
  a fresh wallet, signs a funding request, and this endpoint sends it a
  small amount of Base Sepolia test ETH, once per address. **In-memory
  rate limiting only**, served by the Vite dev server's own long-lived
  process. A production deploy needs this backed by a real stateful
  host (Redis, a KV store, and so on), not this repo's dev setup.
- `server/chatHandler.ts` + `vite-plugins/chatApi.ts` + `api/chat/`: the
  in-match chat relay. Every message is signed by the sender's
  play-wallet and checked server-side against the match's two real
  player addresses read straight from the contract, with a per-sender
  rate limit and a message length cap. **Also in-memory only**, same
  production caveat as the funding endpoint: messages live in a
  module-level map that only survives as long as the one dev server
  process does.

## Running locally

Prerequisites: Node.js, a Base Sepolia RPC URL (a free tier from a
provider like Alchemy or Infura works), and two funded Base Sepolia
test accounts if you want to try a full two-sided match locally.

```bash
cd frontend
cp .env.example .env
```

Fill in `.env` (see `frontend/.env.example` for the full list and what
each variable is for, never commit real values):

- `VITE_BASE_SEPOLIA_RPC_URL`: your RPC URL.
- `VITE_CIPHERTIDE_ADDRESS`: the deployed contract address (see Deployed
  Contracts below).
- `VITE_PLAYER_A_PRIVATE_KEY` / `VITE_PLAYER_B_PRIVATE_KEY`: optional,
  two funded test accounts, only used by the dev-only `?dev-signer=a`
  and `?dev-signer=b` overrides described below.
- `SPONSOR_PRIVATE_KEY` / `SPONSOR_FLOOR_ETH`: optional locally, needed
  only to exercise the `/register` play-wallet funding flow yourself.

Then:

```bash
npm install
npm run dev
```

This starts the Vite dev server (with the sponsor funding and chat
endpoints wired in) at `http://localhost:5173`.

### Trying a full match locally

The normal path is `/register` (generates and funds a play-wallet) then
`/play` (create or join a match). To drive both sides of a match from
one machine without registering twice, open two tabs with the dev-only
signer override:

```
http://localhost:5173/play?dev-signer=a
http://localhost:5173/play?dev-signer=b
```

Create a match in the first tab, copy its join code, join it from the
second tab. Both `?dev-signer=` accounts need Base Sepolia test ETH.
This override only exists in development builds: `import.meta.env.DEV`
gates it out of a production build entirely, along with the two env
vars it reads.

Other scripts: `contracts/` is a Foundry project (`forge build`,
`forge test`), and `e2e/` runs a full headless match against a live
deployment (`npm run e2e`, needs its own `.env`, see
`e2e/.env.example`).

## Deployed contracts (Base Sepolia)

| Contract | Address |
| --- | --- |
| Ciphertide | `0xbf4469258DD6ACb1f5F13E488f02Ea25D7958C44` |
| CiphertideMechanics | `0x8d9146F7B947a6e6372416f354EfA7DA368c9BA0` |

Chain: Base Sepolia (chain id 84532). This project targets Base Sepolia
only, no mainnet deployment exists or is planned.

## Known limitations

- **The play-wallet sponsor funding and in-match chat backends are
  in-memory only.** Both work today because the Vite dev server is one
  long-lived Node process. Neither survives a serverless cold start or a
  restart, and a production deploy needs a real stateful host (Redis, a
  KV store, or similar) behind both, not just this repo's dev-time
  wiring.
