# Deploying Ciphertide to Vercel

This is a step by step runbook for taking the already built app live on
Vercel. It assumes no prior Vercel experience. Follow the steps in order.

Ciphertide targets Base Sepolia only, this deploy does not touch
mainnet.

## What you will need before you start

- A Vercel account (sign up at vercel.com with GitHub is easiest).
- The sponsor wallet address and private key printed in the deploy
  report you received alongside this file. The private key goes only
  into a Vercel environment variable in step 4, never anywhere else.
  Never paste it into a file, a chat message you keep, or a browser
  address bar.
- A Base Sepolia RPC URL (for example from Alchemy or Infura, or the
  public `https://sepolia.base.org` endpoint if you do not want to sign
  up for one).

## 1. Import the repository into Vercel

1. Go to vercel.com and log in.
2. Click "Add New..." then "Project".
3. Choose "Import Git Repository" and select the Ciphertide repository
   (github.com/midasbal/Ciphertide).
4. On the "Configure Project" screen, find "Root Directory" and click
   "Edit". Set it to `frontend`. This is required, the Vercel project
   must build from the `frontend/` folder, not the repository root.
5. Leave "Framework Preset" on its detected value (Vite). Do not click
   Deploy yet, continue to step 2 first so the KV store's environment
   variables are ready before the first build.

## 2. Create and link a Redis (KV) store

Chat needs a real shared store because serverless functions do not share
memory between requests.

1. In the Vercel dashboard, open the "Storage" tab (either from the
   project you just configured, or from your account's top-level
   Storage tab).
2. Click "Create Database" and choose the Redis option (Vercel's
   Redis storage, backed by Upstash).
3. Give it a name (for example `ciphertide-chat`) and create it.
4. On the store's own page, find "Connect Project" (or "Projects") and
   link it to the Ciphertide project you configured in step 1.
5. Linking automatically injects `KV_REST_API_URL`, `KV_REST_API_TOKEN`
   and a few related variables into the project's environment. You do
   not need to copy or type these yourself.

## 3. Fund the sponsor wallet

1. Copy the sponsor ADDRESS from your deploy report (not the private
   key).
2. Open a Base Sepolia faucet (for example the Coinbase Developer
   Platform faucet, or any other Base Sepolia faucet you trust) and
   request testnet ETH to that address.
3. A small amount is enough to start. The sponsor pays out 0.005 ETH per
   new play-wallet and stops once its own balance falls to the
   `SPONSOR_FLOOR_ETH` value you set in step 4, so fund it with enough
   testnet ETH above that floor to cover as many new players as you
   expect.
4. You can request more from the faucet later and top up the same
   address at any time, funding is not a one-time step.

## 4. Add the environment variables

Back in the Vercel project, open "Settings" then "Environment
Variables" and add the following. Apply each to all environments
(Production, Preview, Development) unless noted otherwise.

| Name | Value | Secret |
| --- | --- | --- |
| `SPONSOR_PRIVATE_KEY` | The private key from your deploy report | Yes |
| `SPONSOR_FLOOR_ETH` | `0.02` (or your own floor) | No |
| `BASE_SEPOLIA_RPC_URL` | Your Base Sepolia RPC URL | Yes if it embeds an API key, otherwise no |
| `KV_REST_API_URL` | Already set by linking the store in step 2 | No, but treat as internal |
| `KV_REST_API_TOKEN` | Already set by linking the store in step 2 | Yes |
| `VITE_CIPHERTIDE_ADDRESS` | `0xbf4469258DD6ACb1f5F13E488f02Ea25D7958C44` | No |

Notes:

- `VITE_CIPHERTIDE_ADDRESS` is optional. The app already carries this
  same address as a committed default, so the site works without it.
  Only set it if the contract is ever redeployed to a new address and
  you want to update the live site without a code change.
- `BASE_SEPOLIA_RPC_URL` here is read only by the serverless functions
  (the sponsor and chat endpoints), not by the browser. If you leave it
  unset, the functions fall back to Base Sepolia's public RPC endpoint,
  which works but can be slower under load. This is separate from the
  RPC URL the browser itself uses to talk to the chain, which is not
  part of this deploy's required variables and already falls back to
  the same public endpoint on its own.
- `KV_REST_API_URL` and `KV_REST_API_TOKEN` should already be present
  from step 2. Only add them by hand if for some reason linking did not
  inject them, in which case copy both from the store's own "Quickstart"
  or ".env.local" tab on its Storage page.
- Never enter `SPONSOR_PRIVATE_KEY` anywhere except this Vercel
  environment variable field.

Mark `SPONSOR_PRIVATE_KEY`, `KV_REST_API_TOKEN` and (if applicable)
`BASE_SEPOLIA_RPC_URL` as "Sensitive" in the Vercel UI so their values
are hidden after saving.

## 5. Deploy

1. Go back to the project's "Deployments" tab and click "Deploy" (or, if
   you already clicked Deploy earlier, click "Redeploy" now that the
   environment variables are set).
2. Wait for the build to finish. It runs `npm run build` (a TypeScript
   check plus a Vite production build) and should complete in under a
   couple of minutes.
3. Once it says "Ready", click "Visit" to open the live site.

## 6. Post-deploy check

Confirm the whole flow works end to end on the live URL:

1. Open the site. The landing page should load with no console errors.
2. Register a play-wallet (the flow that creates a fresh local wallet
   for you).
3. Confirm the wallet gets funded: after registering, its balance should
   go from zero to about 0.005 Base Sepolia ETH within a few seconds.
   This proves `SPONSOR_PRIVATE_KEY` and the RPC URL are both working.
4. Go to `/play`, create a match, and join it from a second browser (or
   a private/incognito window with a second registration) to play a
   match through placement and a few turns.
5. From inside a match, send a chat message and confirm it appears for
   both players. This proves the Redis store is linked and reachable.

If any of these fail, recheck the environment variables from step 4 and
the store link from step 2, then redeploy.
