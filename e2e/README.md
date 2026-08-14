# Ciphertide end-to-end run

Headless script that plays a full Ciphertide match against a live deployment
on Base Sepolia, no UI. It exercises the real Inco Lightning loop the
Foundry test suite's mock cannot: real random placement plus its confirm,
decrypting a player's own board to place a real client-encrypted shield,
a few shots with their confirms, and one area skill (Barrage) with its
confirm.

## Setup

1. Deploy the contracts first: `cd ../contracts && ./script/deploy.sh`, or
   copy the addresses from `contracts/deployments/baseSepolia.json` if
   already deployed.
2. `npm install`
3. `cp .env.example .env` and fill in a Base Sepolia RPC URL, two funded
   Base Sepolia player private keys, and the deployed Ciphertide address.
4. `npm run e2e`

## What it proves

Every confirm step in this run submits a real covalidator attestation
fetched over the network from Inco's live infrastructure, verified on
chain by the deployed contract's own signature check, not a local mock.
A successful run is direct evidence the whole encrypt, call,
fetch-attestation, confirm loop works against genuine Inco Lightning on
Base Sepolia.

It does not attempt to play out a full win: ship placement is randomized
server side and hidden from both players and from this script, so sinking
an entire fleet would need far more shots than a smoke run is worth. It
stops after a bounded number of rounds and reports the final phase, the
winner if the match happened to finish, and the gas used by each
transaction along the way.
