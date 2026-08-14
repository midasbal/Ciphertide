// Headless end-to-end run of a single 1v1 Ciphertide match against a live
// deployment on Base Sepolia. No UI, no frontend dependency. Exercises the
// real two-phase encrypt, call, fetch-attestation, confirm loop against
// genuine Inco Lightning infrastructure, the thing the Foundry test suite's
// mock cannot exercise, and every handle this script needs is fetched the
// way a real client must: from a contract event or a public getter, never
// by reaching into storage the way the test-only harness does.
//
// Ciphertide is a 1v1 game: a match is one game between two players. This
// script plays exactly one match, the way a real game actually happens,
// rather than several throwaway matches to sweep every captain skill (that
// was a test convenience for an earlier audit, not a game mode, and skill
// coverage is already proven by the 81 passing Foundry tests). One match
// is enough to prove three things against real infrastructure: that the
// stepped placement flow broadcasts and confirms, that the two-phase
// action-and-confirm loop works end to end, and the real per-move latency.
//
// Sequence: create and join with two captains, full stepped placement for
// both players (placeMyBoardStep called once per ship plus once for mines
// and the reveal, NUM_SHIPS + 1 calls each, confirmed by confirmPlacement),
// the dice roll and its confirm (retried on a tie the way a real client
// would), a couple of plain shots with their confirms, and one shared
// skill (Barrage) through its confirm.
//
// Usage: fill in e2e/.env (see e2e/.env.example) with a Base Sepolia RPC
// URL, two funded player private keys, and the deployed Ciphertide address,
// then run `npm run e2e` from this directory.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  toHex,
  decodeEventLog,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { Lightning } from "@inco/lightning-js/lite";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ciphertideAbi = JSON.parse(
  readFileSync(join(__dirname, "abi/Ciphertide.json"), "utf8"),
);

const executorAbi = [
  {
    type: "function",
    name: "getFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

// A real run against Base Sepolia showed the covalidator can take longer
// than a modest retry budget to have a handle's ciphertext ready: right
// after the mines and reveal step (20 random draws folded into one
// reveal), attestedReveal failed repeatedly with "ciphertext for handle
// ... not found, it might not have been processed yet" through 8 retries
// at this backoff (about 90 seconds total), then succeeded on a fresh
// call issued about a minute after that. Not a contract or SDK bug, the
// mock's synchronous processAllOperations() has no equivalent delay to
// model, so this only shows up against the real covalidator. Widened
// well past what was actually needed here as a safety margin.
const RETRY = { maxRetries: 14, baseDelayInMs: 2000, backoffFactor: 1.5 };
const ZERO32 = ("0x" + "0".repeat(64)) as Hex;
const nonZero = (h: Hex) => h !== ZERO32;
const PHASE_NAMES = ["WaitingForOpponent", "Placing", "AwaitingDiceRoll", "InProgress", "Finished"];

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) missingEnv.push(name);
  return value ?? "";
}

const missingEnv: string[] = [];
const rpcUrl = requireEnv("BASE_SEPOLIA_RPC_URL");
const playerAKey = requireEnv("PLAYER_A_PRIVATE_KEY") as Hex;
const playerBKey = requireEnv("PLAYER_B_PRIVATE_KEY") as Hex;
const ciphertideAddress = requireEnv("CIPHERTIDE_ADDRESS") as Hex;

if (missingEnv.length > 0) {
  console.error("Missing required environment variables:");
  for (const name of missingEnv) console.error(`  ${name}`);
  console.error("Copy e2e/.env.example to e2e/.env and fill these in.");
  process.exit(1);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function findEventOrNull(receipt: TransactionReceipt, eventName: string): Record<string, unknown> | null {
  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: ciphertideAbi,
        eventName,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === eventName) return decoded.args as Record<string, unknown>;
    } catch {
      // Not this event, keep scanning.
    }
  }
  return null;
}

function findEvent(receipt: TransactionReceipt, eventName: string) {
  const found = findEventOrNull(receipt, eventName);
  if (!found) throw new Error(`event ${eventName} not found in receipt ${receipt.transactionHash}`);
  return found;
}

// Per-transaction gas record, extended with the player whose wallet sent
// it and a coarse category, so gas can be tallied per player and per
// move type afterward (see printPerPlayerGasSummary). player and
// category are filled in by write() itself, inferred from which wallet
// was used and from functionName, so no call site elsewhere in this
// file needs to change.
const gasLog: Array<{
  label: string;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  player: "A" | "B";
  category: string;
}> = [];
const moveLog: Array<{ label: string; ms: number }> = [];

// Buckets every contract call by what it is, purely from its function
// name, so write() can tag each gas record without every call site
// needing to say what kind of move it is. "confirm" is its own bucket
// (rather than folded into placement/shot/skill) so the summary can show
// action gas and confirm gas as two distinct, comparable totals.
function categoryFor(functionName: string): string {
  if (functionName === "createMatch" || functionName === "joinMatch") return "createOrJoin";
  if (functionName === "placeMyBoardStep") return "placement";
  if (functionName === "rollDice") return "diceRoll";
  if (functionName === "shoot") return "shot";
  if (functionName.startsWith("confirm")) return "confirm";
  if (functionName.startsWith("use")) return `skill:${functionName.slice(3)}`;
  return "other";
}

// Measures real wall clock time from the start of one full move (an
// action's write, its attestation fetch, and its confirm's write) to the
// confirm landing. This is the number that matters for real UX: how long
// a player actually waits for their move to resolve on screen. Each
// write() call below this already sleeps 1.5s afterward as a defensive
// pause against reading stale state from a load balanced RPC, so every
// measurement here includes about 3.0s of that fixed pause (one after
// the action's write, one after the confirm's write), on top of the real
// network and chain time. Reported as measured, the fixed pause noted
// separately in the summary rather than subtracted out silently.
async function timed<T>(label: string, fn: () => Promise<T>): Promise<T> {
  const start = Date.now();
  const result = await fn();
  const ms = Date.now() - start;
  moveLog.push({ label, ms });
  console.log(`  (${label}: ${(ms / 1000).toFixed(1)}s send to confirm)`);
  return result;
}

async function main() {
  console.log("Ciphertide headless end-to-end run, Base Sepolia, single 1v1 match\n");

  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(rpcUrl) });
  const accountA = privateKeyToAccount(playerAKey);
  const accountB = privateKeyToAccount(playerBKey);
  const walletA = createWalletClient({ account: accountA, chain: baseSepolia, transport: http(rpcUrl) });
  const walletB = createWalletClient({ account: accountB, chain: baseSepolia, transport: http(rpcUrl) });
  console.log(`Player A: ${accountA.address}`);
  console.log(`Player B: ${accountB.address}`);
  console.log(`Ciphertide: ${ciphertideAddress}\n`);

  const zap = await Lightning.baseSepoliaTestnet({ hostChainRpcUrls: [rpcUrl] });
  console.log(`Inco executor: ${zap.executorAddress}\n`);

  const getFee = async () =>
    publicClient.readContract({ address: zap.executorAddress as Hex, abi: executorAbi, functionName: "getFee" });

  async function logBalances(label: string) {
    const balA = await publicClient.getBalance({ address: accountA.address });
    const balB = await publicClient.getBalance({ address: accountB.address });
    console.log(`${label}: Player A balance ${balA} wei, Player B balance ${balB} wei\n`);
  }

  // Every constant this script reads is a uint8 or uint16 on the Solidity
  // side. viem decodes integer return types 48 bits or narrower as a plain
  // JS number, not a bigint, so without this explicit BigInt(...) coercion
  // the result would silently be a number, and mixing that into bigint
  // arithmetic elsewhere in this script (fee * draws, and so on) would
  // throw a TypeError at runtime the moment it happened, not at compile
  // time (the return type here is asserted, not actually checked).
  const readConst = async (name: string): Promise<bigint> => {
    const value = await publicClient.readContract({ address: ciphertideAddress, abi: ciphertideAbi, functionName: name });
    return BigInt(value as number | bigint);
  };

  // A hosted RPC's own writeContract gas estimation step can land on a
  // node that has not yet caught up with a previous write (a join, a
  // confirm, and so on) if the endpoint is load balanced across several
  // backend nodes with no session affinity, and revert against that stale
  // view even though the real current chain state is fine, the same class
  // of staleness the sleep after a write below guards against on the read
  // side. This never actually broadcasts a transaction when estimation
  // itself fails, so retrying costs no gas, only a little wall clock time.
  async function writeContractWithRetry(wallet: typeof walletA, callArgs: any): Promise<Hex> {
    let lastError: unknown;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        return await wallet.writeContract(callArgs);
      } catch (err) {
        lastError = err;
        console.log(`  (retrying ${String(callArgs.functionName)} after a likely stale-node estimation failure)`);
        await sleep(2000 * (attempt + 1));
      }
    }
    throw lastError;
  }

  // eth_estimateGas caps its own search well under the real block gas
  // limit (1.2 billion on Base Sepolia), a common RPC safety cap unrelated
  // to what the chain itself allows. A call that runs many real Inco
  // random draws in one transaction (each one a real operation against the
  // live executor, not the cheap mock) can need real gas at or past that
  // estimation cap, so estimateGas itself fails silently low rather than
  // reverting: a live Barrage call once got estimated at only about 1.91
  // million gas and then reverted out of gas, when its real cost, measured
  // from a transaction that actually succeeded, is about 11.85 million.
  // Passing an explicit gas limit skips estimation entirely.
  //
  // The note this replaces claimed Barrage no longer needed an override
  // because its real cost sat comfortably under the hosted RPC's own
  // per-transaction cap (found to sit around 15-20 million on Alchemy, see
  // writeContractWithRetry above); that claim was correct about the cap
  // but wrong about estimation being safe to rely on regardless, and the
  // resulting override-free code is exactly what produced the out-of-gas
  // Barrage revert above. Restoring an explicit limit here, sized between
  // the real measured cost and that RPC cap, not blindly reusing the old
  // 60/80 million values (an earlier, overly conservative override from
  // when placement was one single call): those exceeded Alchemy's cap
  // outright and got the transaction rejected before it could even be
  // sent, a worse failure than an out-of-gas revert.
  //
  // Placement itself still needs no override (placeMyBoardStep keeps
  // every call to roughly 10 million real gas or less).
  //
  // Barrage: real cost measured live at about 11.85 million gas (see
  // above), 13 million here leaves a margin while staying well under the
  // RPC cap.
  //
  // Rake and Salvo strike only 3 cells each through the same per-cell
  // confidential resolution path Barrage uses for its 4 to 6, so their
  // real cost should scale down from Barrage's roughly proportionally
  // (about 3/5 of it, so roughly 7 million); 9 million here leaves the
  // same kind of margin. Derived, not measured: no prior override existed
  // for either, and sending a real transaction to measure them directly
  // was avoided to save the limited funded wallets' gas.
  //
  // Bombardment and Carpet are also left WITHOUT an override, for the
  // opposite reason placement needs none: both are now stepped on the
  // contract side (BOMBARDMENT_STEP_SIZE and CARPET_STEP_SIZE cells per
  // call), so each individual useBombardment/useCarpet call only resolves
  // a few cells and stays well under default estimation's reach, exactly
  // like placeMyBoardStep.
  //
  // Sonar and placeShield need no override: Sonar does one confidential
  // comparison over a single area mask, and placeShield does one
  // ciphertext ingestion plus a handful of fixed operations, neither one
  // a per-cell loop over an area, and a live cast estimate for Sonar
  // against this deployment's actual state came back at a plausible
  // (uncapped-looking) 198 thousand gas, consistent with it not tripping
  // the same estimator problem.
  const explicitGasLimits: Record<string, bigint> = {
    useBarrage: 13_000_000n,
    useRake: 9_000_000n,
    useSalvo: 9_000_000n,
  };

  async function write(wallet: typeof walletA, functionName: string, args: unknown[], value = 0n) {
    const gas = explicitGasLimits[functionName];
    const hash = await writeContractWithRetry(wallet, {
      address: ciphertideAddress,
      abi: ciphertideAbi,
      functionName,
      args,
      value,
      chain: baseSepolia,
      ...(gas ? { gas } : {}),
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    const player = wallet.account.address.toLowerCase() === accountA.address.toLowerCase() ? "A" : "B";
    gasLog.push({
      label: functionName,
      gasUsed: receipt.gasUsed,
      effectiveGasPrice: receipt.effectiveGasPrice,
      player,
      category: categoryFor(functionName),
    });
    // A read right after a mined write can land on a different, load
    // balanced backend node that has not caught up yet. A short pause
    // here is cheap next to the several seconds a Base Sepolia
    // confirmation already takes, and avoids a false failure on a state
    // check that is actually correct on chain.
    await sleep(1500);
    return receipt;
  }

  async function read(functionName: string, args: unknown[] = []) {
    return publicClient.readContract({ address: ciphertideAddress, abi: ciphertideAbi, functionName, args });
  }

  // The SDK's own backoffConfig retries a "ciphertext not found yet"
  // response, but a real run showed the covalidator can also answer a
  // freshly revealed handle with a "PermissionDenied: acl disallowed"
  // response instead, seemingly for the same underlying reason (the
  // reveal grant has not finished processing on the covalidator's side
  // yet), and the SDK does not retry that response on its own, it comes
  // straight back as a thrown error. This wraps the whole reveal call in
  // its own outer retry so either shape of "not ready yet" response gets
  // the same patience, since both were observed to resolve within a
  // couple of minutes without anything else changing.
  async function revealAsAttestations(handles: Hex[]) {
    let lastError: unknown;
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const results = await zap.attestedReveal(handles, { backoffConfig: RETRY });
        const byHandle = new Map(results.map((r: any) => [r.handle.toLowerCase(), r]));
        return handles.map((h) => {
          const r: any = byHandle.get(h.toLowerCase());
          if (!r) throw new Error(`no attestation returned for handle ${h}`);
          return {
            attestation: { handle: r.handle as Hex, value: toHex(r.plaintext.value, { size: 32 }) as Hex },
            signatures: r.covalidatorSignatures.map((s: Uint8Array) => toHex(s)) as Hex[],
          };
        });
      } catch (err) {
        lastError = err;
        console.log(`  (reveal attempt ${attempt + 1}/5 failed, the covalidator may still be catching up, waiting...)`);
        await sleep(15000 * (attempt + 1));
      }
    }
    throw lastError;
  }

  const readyLog: Array<{ label: string; ms: number }> = [];

  // Precisely measures the true reveal-ready time: from action tx mined to
  // the first genuine attestedReveal success, polled every 1.5s with
  // exactly one real network attempt per poll (maxRetries: 1, not 0: the
  // SDK's retryWithBackoff loop runs while attempt < maxRetries, so 0
  // iterates zero times and throws immediately without ever calling the
  // covalidator). This is the number that isolates real covalidator
  // latency from the coarse exponential backoff revealAsAttestations
  // above uses for its retries, which overstates true latency for fast
  // reveals since its own growing delay dominates. Returns the same
  // attestation shape as revealAsAttestations so the result can be used
  // directly in the following confirm call, no second fetch needed.
  async function tightPollReveal(label: string, handles: Hex[]) {
    const minedAt = Date.now();
    console.log(`  (${label}: tight polling attestedReveal every 1.5s, one real attempt per poll...)`);
    for (let attempt = 1; attempt <= 150; attempt++) {
      try {
        const results = await zap.attestedReveal(handles, {
          backoffConfig: { maxRetries: 1, baseDelayInMs: 0, backoffFactor: 1 },
        });
        if (results.length === handles.length) {
          const readyMs = Date.now() - minedAt;
          readyLog.push({ label, ms: readyMs });
          console.log(`  (${label}: true reveal-ready ${(readyMs / 1000).toFixed(1)}s, ${attempt} tight-poll attempts)`);
          const byHandle = new Map(results.map((r: any) => [r.handle.toLowerCase(), r]));
          return handles.map((h) => {
            const r: any = byHandle.get(h.toLowerCase());
            return {
              attestation: { handle: r.handle as Hex, value: toHex(r.plaintext.value, { size: 32 }) as Hex },
              signatures: r.covalidatorSignatures.map((s: Uint8Array) => toHex(s)) as Hex[],
            };
          });
        }
      } catch {
        // Not ready yet, the loop's own 1.5s spacing is the only delay.
      }
      await sleep(1500);
    }
    throw new Error(`${label}: tight poll gave up after 150 attempts`);
  }

  // Player A always creates, Player B always joins, so player index 0 is
  // always A and index 1 is always B for this match.
  const idxOf = (addr: Hex) => (addr.toLowerCase() === accountA.address.toLowerCase() ? 0 : 1);
  const walletOf = (idx: number) => (idx === 0 ? walletA : walletB);

  const NUM_SHIPS = await readConst("NUM_SHIPS");
  const PLACEMENT_ATTEMPTS_PER_SHIP = await readConst("PLACEMENT_ATTEMPTS_PER_SHIP");
  const MINES_PER_PLAYER = await readConst("MINES_PER_PLAYER");
  const MINE_PLACEMENT_ATTEMPTS = await readConst("MINE_PLACEMENT_ATTEMPTS");
  const CAPTAIN_BOMBARDMENT = await readConst("CAPTAIN_BOMBARDMENT");
  const CAPTAIN_CARPET = await readConst("CAPTAIN_CARPET");

  // Placement is spread across NUM_SHIPS + 1 separate placeMyBoardStep
  // calls, one ship per call, then a final call that places both mines
  // and reveals the single allPlaced bit, so no single transaction ever
  // needs to run more than PLACEMENT_ATTEMPTS_PER_SHIP (or the mine
  // equivalent) random draws. Only the final step emits PlacementSubmitted
  // and needs an attestation and a confirmPlacement call, the ship steps
  // are single phase, nothing to reveal or confirm for those. On a false
  // allPlaced the contract has already reset its own step counter back to
  // the first ship, so retrying just means running the same NUM_SHIPS + 1
  // calls again from the start.
  async function placeAndConfirm(matchId: bigint, wallet: typeof walletA, idx: number, label: string) {
    for (let attempt = 0; attempt < 3; attempt++) {
      console.log(`${label}: placing board across ${NUM_SHIPS + 1n} steps (one per ship, then mines)...`);
      for (let step = 1n; step <= NUM_SHIPS; step++) {
        const shipFee = (await getFee()) * PLACEMENT_ATTEMPTS_PER_SHIP;
        await timed(`${label} ship step ${step}/${NUM_SHIPS}`, async () => {
          const receipt = await write(wallet, "placeMyBoardStep", [matchId], shipFee);
          console.log(`${label}: ship step ${step}/${NUM_SHIPS} submitted, gas ${receipt.gasUsed}`);
        });
      }

      const mineFee = (await getFee()) * MINES_PER_PLAYER * MINE_PLACEMENT_ATTEMPTS;
      const { confirmReceipt, allPlaced } = await timed(`${label} mines and reveal`, async () => {
        const receipt = await write(wallet, "placeMyBoardStep", [matchId], mineFee);
        console.log(`${label}: mines and reveal step submitted, gas ${receipt.gasUsed}`);
        const { allPlacedHandle } = findEvent(receipt, "PlacementSubmitted") as { allPlacedHandle: Hex };
        const [{ attestation, signatures }] = await tightPollReveal(`${label} placement`, [allPlacedHandle]);
        const confirmReceipt = await write(wallet, "confirmPlacement", [matchId, idx, attestation, signatures]);
        return { confirmReceipt, allPlaced: nonZero(attestation.value) };
      });
      console.log(`${label}: confirmPlacement gas ${confirmReceipt.gasUsed}, allPlaced=${allPlaced}`);
      if (allPlaced) return;
      console.log(`${label}: placement did not find a free slot for every ship, retrying from the first ship...`);
    }
    throw new Error(`${label}: placement never succeeded after 3 attempts`);
  }

  // Retried exactly the way a real client has to: a tie leaves the match in
  // AwaitingDiceRoll with no revert, so the only way to observe it is to
  // keep rolling until the phase actually advances. Base Sepolia's real
  // randomness cannot be forced to tie on demand, so this exercises the
  // reroll path for real whenever a tie happens to land, and otherwise
  // still proves the confirm step works on the first real roll.
  async function rollDiceUntilDecided(matchId: bigint) {
    console.log("Rolling dice...");
    let phase = (await read("getPhase", [matchId])) as number;
    let attempts = 0;
    while (phase !== 3 /* InProgress */ && attempts < 10) {
      attempts++;
      const fee = (await getFee()) * 2n;
      await timed("dice roll", async () => {
        const rollReceipt = await write(walletA, "rollDice", [matchId], fee);
        const { rollAHandle, rollBHandle } = findEvent(rollReceipt, "DiceRolled") as {
          rollAHandle: Hex;
          rollBHandle: Hex;
        };
        const [a, b] = await revealAsAttestations([rollAHandle, rollBHandle]);
        await write(walletA, "confirmDiceRoll", [matchId, a.attestation, a.signatures, b.attestation, b.signatures]);
      });
      // The write() above already waits 1.5s after confirmDiceRoll lands,
      // but a real run showed that margin was not always enough: a phase
      // read immediately after can still land on a lagging backend node
      // and appear to still be AwaitingDiceRoll when the real state has
      // already moved to InProgress (a non-tied roll), which then made a
      // spurious extra rollDice call revert on chain with "not ready for
      // dice roll" (a genuine, avoidable revert, not a tie). A short extra
      // pause plus a second confirming read closes that gap before this
      // loop trusts a "still AwaitingDiceRoll" reading enough to reroll.
      phase = (await read("getPhase", [matchId])) as number;
      if (phase !== 3) {
        await sleep(3000);
        phase = (await read("getPhase", [matchId])) as number;
      }
      if (phase !== 3) console.log(`Dice tied on attempt ${attempts}, rerolling (the real reroll on tie path)...`);
    }
    if (phase !== 3) throw new Error("dice roll never decided a starting player");
    console.log(`Match in progress after ${attempts} roll${attempts === 1 ? "" : "s"}.\n`);
  }

  async function nextUnshotCells(matchId: bigint, defenderIdx: number, count: number): Promise<number[]> {
    const shotsAgainst = (await read("getShotsAgainst", [matchId, defenderIdx])) as bigint;
    const cells: number[] = [];
    let cell = 0;
    while (cells.length < count) {
      if (((shotsAgainst >> BigInt(cell)) & 1n) === 0n && !cells.includes(cell)) cells.push(cell);
      cell++;
    }
    return cells;
  }

  async function doShot(matchId: bigint, actorIdx: number): Promise<boolean> {
    const wallet = walletOf(actorIdx);
    const defenderIdx = actorIdx === 0 ? 1 : 0;
    const [cell] = await nextUnshotCells(matchId, defenderIdx, 1);
    console.log(`Shot at cell ${cell} (player index ${actorIdx})...`);
    const won = await timed("shoot", async () => {
      const receipt = await write(wallet, "shoot", [matchId, cell]);
      console.log(`shoot() gas ${receipt.gasUsed}`);
      const { hitHandle, allDestroyedHandle, mineHitHandle, shieldBreakHandle } = findEvent(receipt, "ShotFired") as {
        hitHandle: Hex;
        allDestroyedHandle: Hex;
        mineHitHandle: Hex;
        shieldBreakHandle: Hex;
      };
      const [hit, win, mine, shield] = await tightPollReveal("shoot", [
        hitHandle,
        allDestroyedHandle,
        mineHitHandle,
        shieldBreakHandle,
      ]);
      const confirmReceipt = await write(wallet, "confirmShot", [
        matchId,
        hit.attestation,
        hit.signatures,
        win.attestation,
        win.signatures,
        mine.attestation,
        mine.signatures,
        shield.attestation,
        shield.signatures,
      ]);
      console.log(
        `confirmShot gas ${confirmReceipt.gasUsed}, hit=${nonZero(hit.attestation.value)}, ` +
          `mine=${nonZero(mine.attestation.value)}, shieldBreak=${nonZero(shield.attestation.value)}, ` +
          `win=${nonZero(win.attestation.value)}\n`,
      );
      return nonZero(win.attestation.value);
    });
    return won;
  }

  // Barrage and Rake pick their struck cells with public randomness
  // instead of a confidential draw (see CiphertideMechanics.pickAreaCells),
  // so neither takes a fee anymore and both share this same single-call
  // fire-then-confirm shape, only the function names, event name and call
  // args (an anchor for Barrage, a row for Rake) differ. Bombardment and
  // Carpet pick their cells the same public way but are stepped, so they
  // use useSteppedAreaSkillAndConfirm below instead.
  async function useAreaSkillAndConfirm(
    matchId: bigint,
    wallet: typeof walletA,
    label: string,
    useFn: string,
    useArgs: unknown[],
    firedEvent: string,
    confirmFn: string,
  ): Promise<boolean> {
    return timed(label, async () => {
      const receipt = await write(wallet, useFn, useArgs);
      console.log(`${useFn}() gas ${receipt.gasUsed}`);
      const { packedHandle, allDestroyedHandle } = findEvent(receipt, firedEvent) as {
        packedHandle: Hex;
        allDestroyedHandle: Hex;
      };
      const [packed, win] = await tightPollReveal(label, [packedHandle, allDestroyedHandle]);
      const confirmReceipt = await write(wallet, confirmFn, [
        matchId,
        packed.attestation,
        packed.signatures,
        win.attestation,
        win.signatures,
      ]);
      console.log(
        `${confirmFn} gas ${confirmReceipt.gasUsed}, packed=${packed.attestation.value}, ` +
          `win=${nonZero(win.attestation.value)}\n`,
      );
      return nonZero(win.attestation.value);
    });
  }

  // Bombardment and Carpet are stepped on the contract side: useBombardment
  // and useCarpet must each be called repeatedly with the exact same
  // matchId, anchorRow and anchorCol until a receipt carries the fired
  // event instead of the step event. Each call is still logged through
  // write() individually, tagged by function name, so the per-step gas
  // this run measures live comes straight out of gasLog, no separate
  // bookkeeping needed.
  async function useSteppedAreaSkillAndConfirm(
    matchId: bigint,
    wallet: typeof walletA,
    label: string,
    useFn: string,
    useArgs: unknown[],
    stepEvent: string,
    firedEvent: string,
    confirmFn: string,
  ): Promise<boolean> {
    return timed(label, async () => {
      let receipt: TransactionReceipt;
      let step = 0;
      for (;;) {
        step++;
        receipt = await write(wallet, useFn, useArgs);
        const fired = findEventOrNull(receipt, firedEvent);
        if (fired) {
          console.log(`${useFn}() step ${step} (final) gas ${receipt.gasUsed}`);
          break;
        }
        const { cellsDone, totalCells } = findEvent(receipt, stepEvent) as { cellsDone: number; totalCells: number };
        console.log(`${useFn}() step ${step} gas ${receipt.gasUsed} (${cellsDone}/${totalCells} cells)`);
      }
      const { packedHandle, allDestroyedHandle } = findEvent(receipt, firedEvent) as {
        packedHandle: Hex;
        allDestroyedHandle: Hex;
      };
      const [packed, win] = await tightPollReveal(label, [packedHandle, allDestroyedHandle]);
      const confirmReceipt = await write(wallet, confirmFn, [
        matchId,
        packed.attestation,
        packed.signatures,
        win.attestation,
        win.signatures,
      ]);
      console.log(
        `${confirmFn} gas ${confirmReceipt.gasUsed}, packed=${packed.attestation.value}, ` +
          `win=${nonZero(win.attestation.value)}\n`,
      );
      return nonZero(win.attestation.value);
    });
  }

  const useBarrageAndConfirm = (matchId: bigint, wallet: typeof walletA) =>
    useAreaSkillAndConfirm(matchId, wallet, "useBarrage", "useBarrage", [matchId, 0, 0], "BarrageFired", "confirmBarrage");
  const useBombardmentAndConfirm = (matchId: bigint, wallet: typeof walletA) =>
    useSteppedAreaSkillAndConfirm(
      matchId,
      wallet,
      "useBombardment",
      "useBombardment",
      [matchId, 0, 0],
      "BombardmentStepSubmitted",
      "BombardmentFired",
      "confirmBombardment",
    );
  const useCarpetAndConfirm = (matchId: bigint, wallet: typeof walletA) =>
    useSteppedAreaSkillAndConfirm(
      matchId,
      wallet,
      "useCarpet",
      "useCarpet",
      [matchId, 0, 0],
      "CarpetStepSubmitted",
      "CarpetFired",
      "confirmCarpet",
    );

  // The single 1v1 match. Player A gets captain Bombardment, Player B gets
  // captain Carpet, so this run exercises both newly stepped skills in one
  // match, the real proof a mock cannot give: that useBombardment and
  // useCarpet each fire their full step sequence and confirm against the
  // live Base Sepolia deployment, with real measured per-step gas under
  // the chain's per-transaction cap.
  console.log(`Creating match (Player A captain ${CAPTAIN_BOMBARDMENT}, Player B captain ${CAPTAIN_CARPET})...`);
  const createReceipt = await write(walletA, "createMatch", [CAPTAIN_BOMBARDMENT]);
  const { matchId } = findEvent(createReceipt, "MatchCreated") as { matchId: bigint };
  console.log(`Match ${matchId}, gas ${createReceipt.gasUsed}\n`);

  await write(walletB, "joinMatch", [matchId, CAPTAIN_CARPET]);
  const addr0 = (await read("getPlayerAddress", [matchId, 0])) as Hex;
  if (addr0.toLowerCase() !== accountA.address.toLowerCase()) {
    throw new Error("player index assignment did not match the assumed A=0, B=1 convention");
  }

  await logBalances("Balances before placement");
  await placeAndConfirm(matchId, walletA, 0, "Player A");
  await placeAndConfirm(matchId, walletB, 1, "Player B");
  await logBalances("Balances after placement");

  await rollDiceUntilDecided(matchId);

  // A read of getTurn right after a write can land on a load balanced
  // backend node that has not caught up with that write yet, the same
  // class of staleness worked around elsewhere in this script. write()
  // already sleeps 1.5s after every call; this adds a further pause
  // before trusting a getTurn read used to decide the next move, since a
  // real board now means a real mine can grant a bonus action and break a
  // simple always-alternates assumption.
  async function currentActorIdx(): Promise<number> {
    await sleep(2000);
    return idxOf((await read("getTurn", [matchId])) as Hex);
  }

  let finished = false;
  let actorIdx = await currentActorIdx();
  finished = await doShot(matchId, actorIdx);

  if (!finished) {
    actorIdx = await currentActorIdx();
    finished = await useBarrageAndConfirm(matchId, walletOf(actorIdx));
  }

  let bombardmentDone = false;
  let carpetDone = false;
  for (let i = 0; i < 4 && !finished && (!bombardmentDone || !carpetDone); i++) {
    actorIdx = await currentActorIdx();
    if (actorIdx === 0 && !bombardmentDone) {
      finished = await useBombardmentAndConfirm(matchId, walletA);
      bombardmentDone = true;
    } else if (actorIdx === 1 && !carpetDone) {
      finished = await useCarpetAndConfirm(matchId, walletB);
      carpetDone = true;
    } else {
      // Turn landed on the captain whose unique skill is already used
      // (a mine bonus can do this): spend it on a plain miss so the turn
      // passes and the loop can try the other captain's skill next.
      finished = await doShot(matchId, actorIdx);
    }
  }

  const finalPhase = (await read("getPhase", [matchId])) as number;
  console.log(`Final phase: ${PHASE_NAMES[finalPhase]}`);
  if (finalPhase === 4) console.log(`Winner: ${await read("getWinner", [matchId])}`);
  console.log("");

  await logBalances("Balances after the match");

  console.log("Placement (both players, all steps), dice roll, a shot, Barrage, Bombardment and Carpet each");
  console.log("completed their action-and-confirm cycle using only handles fetched from events and public");
  console.log("getters, the same way a real client has to.\n");

  console.log("Gas used:");
  for (const { label, gasUsed } of gasLog) console.log(`  ${label}: ${gasUsed}`);

  console.log("\nMove latency, send to confirm landing (includes about 3.0s of this script's own");
  console.log("defensive pause, 1.5s after the action write and 1.5s after the confirm write):");
  for (const { label, ms } of moveLog) console.log(`  ${label}: ${(ms / 1000).toFixed(1)}s`);
  if (moveLog.length > 0) {
    const avgMs = moveLog.reduce((sum, m) => sum + m.ms, 0) / moveLog.length;
    console.log(`  average: ${(avgMs / 1000).toFixed(1)}s over ${moveLog.length} moves`);
  }

  console.log("\nTrue reveal-ready time, tight polled every 1.5s (one real attempt per poll), action tx");
  console.log("mined to first genuine attestedReveal success, no fixed pause included:");
  for (const { label, ms } of readyLog) console.log(`  ${label}: ${(ms / 1000).toFixed(1)}s`);

  await printPerPlayerGasSummary(publicClient);
}

// wei -> ETH, printed to 9 decimals, enough precision for testnet-sized
// amounts (a few hundredths of a cent) to stay legible rather than
// rounding to 0.000000.
function formatEth(wei: bigint): string {
  return (Number(wei) / 1e18).toFixed(9);
}

// Totals every gas record per player and per category, including that
// player's own confirms (the conservative case: the play-wallet pays for
// everything it does, both the action and its confirm). This is the
// number that matters for sizing how much a sponsor must fund each
// play-wallet, the categories underneath it are for understanding what
// that total is made of.
async function printPerPlayerGasSummary(publicClient: { getGasPrice: () => Promise<bigint> }) {
  console.log("\nPer-player gas accounting (includes that player's own confirms):");
  for (const player of ["A", "B"] as const) {
    const entries = gasLog.filter((e) => e.player === player);
    const sumOf = (category: string) => entries.filter((e) => e.category === category).reduce((s, e) => s + e.gasUsed, 0n);
    const countOf = (category: string) => entries.filter((e) => e.category === category).length;

    const totalGas = entries.reduce((sum, e) => sum + e.gasUsed, 0n);
    const totalWei = entries.reduce((sum, e) => sum + e.gasUsed * e.effectiveGasPrice, 0n);
    const avgGasPrice = entries.length > 0 ? totalWei / totalGas : 0n;

    console.log(`\nPlayer ${player} (${entries.length} transactions):`);
    console.log(`  total gas used: ${totalGas}`);
    console.log(`  total spent: ${formatEth(totalWei)} ETH (${totalWei} wei)`);
    console.log(`  average effective gas price: ${avgGasPrice} wei (${(Number(avgGasPrice) / 1e9).toFixed(4)} gwei)`);

    console.log(`  createOrJoin: ${sumOf("createOrJoin")} gas (${countOf("createOrJoin")} tx)`);
    console.log(`  placement (all steps): ${sumOf("placement")} gas (${countOf("placement")} tx)`);
    console.log(`  diceRoll: ${sumOf("diceRoll")} gas (${countOf("diceRoll")} tx)`);

    const shotCount = countOf("shot");
    const shotTotal = sumOf("shot");
    const avgPerShot = shotCount > 0 ? Math.round(Number(shotTotal) / shotCount) : 0;
    console.log(`  shots: ${shotCount} shot(s), ${shotTotal} gas total, ${avgPerShot} gas average per shot`);

    const skillCategories = [...new Set(entries.map((e) => e.category).filter((c) => c.startsWith("skill:")))];
    if (skillCategories.length === 0) {
      console.log("  skills used: none");
    } else {
      for (const cat of skillCategories) {
        console.log(`  ${cat.slice(6)}: ${sumOf(cat)} gas (${countOf(cat)} tx)`);
      }
    }

    console.log(`  confirms: ${sumOf("confirm")} gas (${countOf("confirm")} tx)`);
  }

  const currentGasPrice = await publicClient.getGasPrice();
  console.log(`\nCurrent Base Sepolia gas price at report time: ${currentGasPrice} wei (${(Number(currentGasPrice) / 1e9).toFixed(4)} gwei)`);
}

main().catch((err) => {
  console.error("\nEnd-to-end run failed:");
  console.error(err);
  process.exit(1);
});
