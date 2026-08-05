# Confidential Battleship

Fully onchain 1v1 PvP Battleship, built with Inco Lightning (FHE) on Base
Sepolia testnet.

## Stack

- Contracts: Solidity + Foundry, in `contracts/`, using `@inco/lightning`.
- Frontend: React + Vite + TypeScript, in `frontend/`, using
  `@inco/lightning-js` and `viem`.
- Network: Base Sepolia testnet only.

## Ground rules

- Never use em dashes anywhere, including docs, code comments, and commit
  messages.
- Target Base Sepolia testnet only. Do not configure, deploy to, or
  reference mainnet.
- Do not create a git remote or push anywhere until the user gives you the
  remote. Local commits are fine.
- Author all git commits under the user's own git identity only. Do not
  add a Claude or AI co-author trailer or a "Generated with" line.
- For anything Inco-specific, consult the Inco docs MCP server
  (`inco-docs` in `.mcp.json`) and https://docs.inco.org. Do not guess or
  invent Inco types or function signatures from memory, read the real
  ones.

## Source of truth

`docs/game-design.md` is the source of truth for game rules and scope.
`docs/hackathon.md` has the jam requirements and deadline.
`docs/inco.md` is a short orientation on building with Inco Lightning.

## Current state

Game mechanics are still being designed and are not implemented yet. Only
project setup and scaffolding exist so far: the Foundry contracts project
with one minimal, verified Inco Lightning example
(`contracts/src/EncryptedCounter.sol`), and a React frontend shell wired
for Base Sepolia. Do not add game logic until `docs/game-design.md` is
filled in and the user asks for it.
