# Building with Inco Lightning

Inco Lightning lets Solidity contracts compute over encrypted values (FHE)
on an existing EVM chain, no new language and no separate chain to deploy
to. This project uses it on Base Sepolia testnet only.

## The moving pieces

- `@inco/lightning`: the Solidity library, imported in contracts to get
  encrypted types (`euint256`, `ebool`, `eaddress`, ...) and the `e`
  library of operations on them (`e.add`, `e.sub`, `e.eq`, `e.allow`,
  `e.reveal`, and so on).
- `@inco/lightning-js`: the client SDK used by the frontend to encrypt
  inputs before sending them onchain, and to decrypt (reencrypt) values a
  user is allowed to see.
- Encrypted values live onchain as handles. Reading a handle onchain does
  not reveal the underlying value, decryption/reencryption is a separate,
  permissioned step.
- Inco's covalidator network performs the offchain confidential compute
  and answers reencryption requests from permitted users.

## Where things live in this repo

- `contracts/`: Foundry project with `@inco/lightning` as a dependency.
  `contracts/src/EncryptedCounter.sol` and its test are a minimal, verified
  example (store and read back one encrypted integer), not game logic.
- `frontend/`: React + Vite app with `@inco/lightning-js` and `viem`
  wired for Base Sepolia only, in `frontend/src/lib/chain.ts` and
  `frontend/src/lib/inco.ts`.

## Important

Do not guess Inco type names, function signatures, or SDK APIs from
memory, they change across versions. Always check the Inco docs MCP
server (registered in `.mcp.json` as `inco-docs`) or https://docs.inco.org
directly before writing or changing Inco-specific code.
