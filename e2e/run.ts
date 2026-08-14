// Headless end-to-end run of full Ciphertide matches against a live
// deployment on Base Sepolia. No UI, no frontend dependency. Exercises the
// real two-phase encrypt, call, fetch-attestation, confirm loop against
// genuine Inco Lightning infrastructure, the thing the Foundry test suite's
// mock cannot exercise, and every handle this script needs is fetched the
// way a real client must: from a contract event or a public getter, never
// by reaching into storage the way the test-only harness does.
//
// This script itself already caught one real gap this way: confirmShot
// used to require a mineHit attestation that ShotFired never emitted and
// no getter exposed, so no real client could ever have completed a shot's
// confirm. That is fixed now (ShotFired emits mineHitHandle). This version
// covers every two phase action and confirm pair, not just placement, shot
// and Barrage, specifically so a future regression of the same shape would
// show up here as a hard failure instead of silently shipping.
//
// Runs three short matches back to back, since each match only has two
// captain slots and there are five captain-owned unique skills (Shield,
// Bombardment, Rake, Salvo, Carpet) plus two shared ones (Sonar, Barrage):
//   Match 1: Shield vs Bombardment, exercises Shield, Sonar, Barrage,
//            Bombardment, and a plain shot.
//   Match 2: Rake vs Salvo, exercises Rake, Salvo, and a plain shot.
//   Match 3: Carpet vs Shield, exercises Carpet and a plain shot.
// Each match also drives placement plus its confirm for both players, and
// dice roll plus its confirm, retried the same way a real client would
// retry on a tie, since Base Sepolia's real randomness cannot be forced to
// tie on demand.
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
import { handleTypes } from "@inco/lightning-js";

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

const RETRY = { maxRetries: 8, baseDelayInMs: 1500, backoffFactor: 1.7 };
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

function findEvent(receipt: TransactionReceipt, eventName: string) {
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
  throw new Error(`event ${eventName} not found in receipt ${receipt.transactionHash}`);
}

const gasLog: Array<{ label: string; gasUsed: bigint }> = [];
const moveLog: Array<{ label: string; ms: number }> = [];

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
  console.log("Ciphertide headless end-to-end run, Base Sepolia\n");

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

  // sepolia.base.org is a load balanced public endpoint with several
  // backend nodes behind it, no session affinity across separate HTTP
  // requests. writeContract's own gas estimation step can land on a node
  // that has not yet caught up with the previous write (a join, a
  // confirm, and so on), and reverts against that stale view even though
  // the real current chain state is fine, the same class of staleness as
  // the sleep after a write below guards against on the read side. This
  // never actually broadcasts a transaction when estimation itself fails,
  // so retrying costs no gas, only a little wall clock time.
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

  // sepolia.base.org's eth_estimateGas caps its own search well under the
  // real block gas limit (1.2 billion on Base Sepolia), a common public
  // RPC safety cap unrelated to what the chain itself allows. Every call
  // that runs many real Inco random draws in a loop (each one a real
  // operation against the live executor, not the cheap mock) needs real
  // gas in the tens of millions, at or past that estimation cap, so
  // estimateGas itself fails with a bare "execution reverted" before the
  // transaction is ever sent, even though a direct eth_call with an
  // explicit high gas value confirms the call actually succeeds. Passing
  // an explicit gas limit skips estimation entirely.
  //
  // Placement used to need this treatment too (its old single call ran
  // all ~140 draws at once, needing roughly 51 to 55 million real gas),
  // but every hosted RPC tried, free public ones and a paid Alchemy Base
  // Sepolia endpoint alike, also rejects eth_sendRawTransaction itself
  // once the declared gas limit passes a policy ceiling of its own,
  // anywhere from about 15 to 50 million depending on the provider, well
  // short of what one placement call needed. That ceiling is not
  // something this script can work around from the client side, an
  // explicit gas limit does not help once the RPC refuses to broadcast
  // the transaction at all. The real fix was on the contract side:
  // placement is now placeMyBoardStep, one ship (or the mines and reveal)
  // per call, so no single placement transaction needs more than about
  // 10 million real gas, comfortably under every ceiling seen so far, no
  // explicit override needed. Bombardment, Barrage and Rake still run
  // many draws in one call and keep their overrides below.
  const explicitGasLimits: Record<string, bigint> = {
    useBombardment: 80_000_000n,
    useBarrage: 60_000_000n,
    useRake: 60_000_000n,
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
    gasLog.push({ label: functionName, gasUsed: receipt.gasUsed });
    // sepolia.base.org is a load balanced public endpoint: a read right
    // after a mined write can land on a different backend node that has
    // not caught up yet. A short pause here is cheap next to the several
    // seconds a Base Sepolia confirmation already takes, and avoids a
    // false failure on a state check that is actually correct on chain.
    await sleep(1500);
    return receipt;
  }

  async function read(functionName: string, args: unknown[] = []) {
    return publicClient.readContract({ address: ciphertideAddress, abi: ciphertideAbi, functionName, args });
  }

  async function revealAsAttestations(handles: Hex[]) {
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
  }

  // Player A always creates, Player B always joins, so player index 0 is
  // always A and index 1 is always B for every match this script creates.
  // Confirmed once below rather than assumed.
  const idxOf = (addr: Hex) => (addr.toLowerCase() === accountA.address.toLowerCase() ? 0 : 1);
  const walletOf = (idx: number) => (idx === 0 ? walletA : walletB);

  // Constants read once, shared by every match below.
  const NUM_SHIPS = await readConst("NUM_SHIPS");
  const PLACEMENT_ATTEMPTS_PER_SHIP = await readConst("PLACEMENT_ATTEMPTS_PER_SHIP");
  const MINES_PER_PLAYER = await readConst("MINES_PER_PLAYER");
  const MINE_PLACEMENT_ATTEMPTS = await readConst("MINE_PLACEMENT_ATTEMPTS");

  const BARRAGE_MAX_CELLS = await readConst("BARRAGE_MAX_CELLS");
  const BARRAGE_ATTEMPTS_PER_CELL = await readConst("BARRAGE_ATTEMPTS_PER_CELL");
  const barrageDraws = 1n + BARRAGE_MAX_CELLS * BARRAGE_ATTEMPTS_PER_CELL;

  const BOMBARDMENT_STRIKE_COUNT = await readConst("BOMBARDMENT_STRIKE_COUNT");
  const BOMBARDMENT_ATTEMPTS_PER_CELL = await readConst("BOMBARDMENT_ATTEMPTS_PER_CELL");
  const bombardmentDraws = 1n + BOMBARDMENT_STRIKE_COUNT * BOMBARDMENT_ATTEMPTS_PER_CELL;

  const RAKE_STRIKE_COUNT = await readConst("RAKE_STRIKE_COUNT");
  const RAKE_ATTEMPTS_PER_CELL = await readConst("RAKE_ATTEMPTS_PER_CELL");
  const rakeDraws = 1n + RAKE_STRIKE_COUNT * RAKE_ATTEMPTS_PER_CELL;

  const CAPTAIN_SHIELD = await readConst("CAPTAIN_SHIELD");
  const CAPTAIN_BOMBARDMENT = await readConst("CAPTAIN_BOMBARDMENT");
  const CAPTAIN_RAKE = await readConst("CAPTAIN_RAKE");
  const CAPTAIN_SALVO = await readConst("CAPTAIN_SALVO");
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
        const [{ attestation, signatures }] = await revealAsAttestations([allPlacedHandle]);
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
      phase = (await read("getPhase", [matchId])) as number;
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
      const [hit, win, mine, shield] = await revealAsAttestations([
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

  // Repeatedly takes a plain shot from whoever currently holds the turn
  // until it becomes targetIdx's turn, so a captain-gated skill (which can
  // only be used on its owner's own turn) can be reached regardless of
  // which player the dice roll happened to start, and regardless of any
  // turn-forfeit in play (Salvo's own cost included, since this only
  // watches getTurn and does not care why control moved). Bounded so a
  // genuinely stuck match fails loudly instead of looping forever. Returns
  // true if the match finished while passing turns.
  async function passUntilTurnOf(matchId: bigint, targetIdx: number, maxShots = 20): Promise<boolean> {
    for (let i = 0; i < maxShots; i++) {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      if (idxOf(turnAddr) === targetIdx) return false;
      const finished = await doShot(matchId, idxOf(turnAddr));
      if (finished) return true;
    }
    throw new Error(`turn never reached player index ${targetIdx} after ${maxShots} filler shots`);
  }

  // Shared shape for Barrage, Bombardment, Rake, Salvo and Carpet: each
  // fires with its own args, reveals packedHandle and allDestroyedHandle
  // from its own Fired event, and confirms with the same (matchId,
  // packedAttestation, packedSignatures, winAttestation, winSignatures)
  // shape. Returns true if the match finished.
  async function useAreaSkillAndConfirm(
    matchId: bigint,
    wallet: typeof walletA,
    useFnName: string,
    useArgs: unknown[],
    fee: bigint,
    firedEventName: string,
    confirmFnName: string,
  ): Promise<boolean> {
    return timed(useFnName, async () => {
      const receipt = await write(wallet, useFnName, useArgs, fee);
      console.log(`${useFnName}() gas ${receipt.gasUsed}`);
      const { packedHandle, allDestroyedHandle } = findEvent(receipt, firedEventName) as {
        packedHandle: Hex;
        allDestroyedHandle: Hex;
      };
      const [packed, win] = await revealAsAttestations([packedHandle, allDestroyedHandle]);
      const confirmReceipt = await write(wallet, confirmFnName, [
        matchId,
        packed.attestation,
        packed.signatures,
        win.attestation,
        win.signatures,
      ]);
      console.log(
        `${confirmFnName} gas ${confirmReceipt.gasUsed}, packed=${packed.attestation.value}, ` +
          `win=${nonZero(win.attestation.value)}\n`,
      );
      return nonZero(win.attestation.value);
    });
  }

  async function useSonarAndConfirm(matchId: bigint, wallet: typeof walletA): Promise<void> {
    await timed("useSonar", async () => {
      const receipt = await write(wallet, "useSonar", [matchId, 0, 0]);
      console.log(`useSonar() gas ${receipt.gasUsed}`);
      const { resultHandle } = findEvent(receipt, "SonarFired") as { resultHandle: Hex };
      const [result] = await revealAsAttestations([resultHandle]);
      const confirmReceipt = await write(wallet, "confirmSonar", [matchId, result.attestation, result.signatures]);
      console.log(`confirmSonar gas ${confirmReceipt.gasUsed}, anyShip=${nonZero(result.attestation.value)}\n`);
    });
  }

  // Decrypts Player A's own board with a wallet-signed attestation
  // (attestedDecrypt, distinct from the public attestedReveal used
  // everywhere else in this script), then places a real shield on one of
  // her own ship cells: a genuine client-encrypted input built with
  // zap.encrypt and consumed on-chain via e.newEuint256. placeShield is a
  // free action, it does not pass the turn and has no confirm step of its
  // own (the shielded cell is never revealed unless struck), so it is
  // outside the class of bug this script otherwise audits for, but it is
  // still the one truly client-encrypted input in the whole game and worth
  // exercising for real.
  async function placeRealShield(matchId: bigint): Promise<void> {
    console.log("Decrypting Player A's own board to place a real shield...");
    const boardHandle = (await read("getBoardMask", [matchId, 0])) as Hex;
    // Cast to any: @inco/lightning-js bundles its own nested viem version,
    // structurally identical to this project's but a distinct type from
    // TypeScript's point of view, which otherwise rejects a wallet client
    // built from this project's own viem as an argument here. Harmless at
    // runtime, both are plain viem WalletClient objects.
    const [decrypted] = await zap.attestedDecrypt(walletA as any, [boardHandle], { backoffConfig: RETRY });
    const board = decrypted.plaintext.value as bigint;
    let shieldCell = 0;
    while (((board >> BigInt(shieldCell)) & 1n) === 0n) shieldCell++;
    console.log(`Player A's real ship cell chosen for the shield: ${shieldCell}`);

    const ciphertext = await zap.encrypt(1n << BigInt(shieldCell), {
      accountAddress: accountA.address,
      dappAddress: ciphertideAddress,
      handleType: handleTypes.euint256,
    });
    const fee = await getFee();
    const receipt = await write(walletA, "placeShield", [matchId, ciphertext], fee);
    console.log(`Shield placed, gas ${receipt.gasUsed}\n`);
  }

  async function runMatch(
    label: string,
    captainA: bigint,
    captainB: bigint,
    exercises: Array<(matchId: bigint) => Promise<boolean | void>>,
  ) {
    console.log(`=== ${label} ===\n`);
    console.log(`Creating match (Player A captain ${captainA}, Player B captain ${captainB})...`);
    const createReceipt = await write(walletA, "createMatch", [captainA]);
    const { matchId } = findEvent(createReceipt, "MatchCreated") as { matchId: bigint };
    console.log(`Match ${matchId}, gas ${createReceipt.gasUsed}\n`);

    await write(walletB, "joinMatch", [matchId, captainB]);
    const addr0 = (await read("getPlayerAddress", [matchId, 0])) as Hex;
    if (addr0.toLowerCase() !== accountA.address.toLowerCase()) {
      throw new Error("player index assignment did not match the assumed A=0, B=1 convention");
    }

    await placeAndConfirm(matchId, walletA, 0, `${label} Player A`);
    await placeAndConfirm(matchId, walletB, 1, `${label} Player B`);
    await rollDiceUntilDecided(matchId);

    for (const exercise of exercises) {
      const phaseNow = (await read("getPhase", [matchId])) as number;
      if (phaseNow === 4 /* Finished */) {
        console.log(`${label}: match already finished, skipping the remaining exercises for this match.\n`);
        break;
      }
      const finished = await exercise(matchId);
      if (finished) break;
    }

    const finalPhase = (await read("getPhase", [matchId])) as number;
    console.log(`${label} final phase: ${PHASE_NAMES[finalPhase]}`);
    if (finalPhase === 4) console.log(`${label} winner: ${await read("getWinner", [matchId])}`);
    console.log("");
  }

  // Match 1: Shield vs Bombardment. Exercises the one client-encrypted
  // input in the game (Shield), both shared skills (Sonar, Barrage), and
  // Bombardment, plus a plain shot.
  await runMatch("Match 1: Shield vs Bombardment", CAPTAIN_SHIELD, CAPTAIN_BOMBARDMENT, [
    async (matchId) => {
      if (await passUntilTurnOf(matchId, 0)) return true;
      await placeRealShield(matchId);
    },
    async (matchId) => {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      await useSonarAndConfirm(matchId, walletOf(idxOf(turnAddr)));
    },
    async (matchId) => {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      const fee = (await getFee()) * barrageDraws;
      return useAreaSkillAndConfirm(
        matchId,
        walletOf(idxOf(turnAddr)),
        "useBarrage",
        [matchId, 0, 0],
        fee,
        "BarrageFired",
        "confirmBarrage",
      );
    },
    async (matchId) => {
      if (await passUntilTurnOf(matchId, 1)) return true;
      const fee = (await getFee()) * bombardmentDraws;
      return useAreaSkillAndConfirm(
        matchId,
        walletB,
        "useBombardment",
        [matchId, 0, 0],
        fee,
        "BombardmentFired",
        "confirmBombardment",
      );
    },
    async (matchId) => {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      return doShot(matchId, idxOf(turnAddr));
    },
  ]);

  // Match 2: Rake vs Salvo.
  await runMatch("Match 2: Rake vs Salvo", CAPTAIN_RAKE, CAPTAIN_SALVO, [
    async (matchId) => {
      if (await passUntilTurnOf(matchId, 0)) return true;
      const fee = (await getFee()) * rakeDraws;
      return useAreaSkillAndConfirm(matchId, walletA, "useRake", [matchId, 0], fee, "RakeFired", "confirmRake");
    },
    async (matchId) => {
      if (await passUntilTurnOf(matchId, 1)) return true;
      const cells = await nextUnshotCells(matchId, 0, 3);
      return useAreaSkillAndConfirm(
        matchId,
        walletB,
        "useSalvo",
        [matchId, cells[0], cells[1], cells[2]],
        0n,
        "SalvoFired",
        "confirmSalvo",
      );
    },
    async (matchId) => {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      return doShot(matchId, idxOf(turnAddr));
    },
  ]);

  // Match 3: Carpet vs Shield (Shield's own action is not re-exercised
  // here, already covered for real in match 1).
  await runMatch("Match 3: Carpet vs Shield", CAPTAIN_CARPET, CAPTAIN_SHIELD, [
    async (matchId) => {
      if (await passUntilTurnOf(matchId, 0)) return true;
      return useAreaSkillAndConfirm(
        matchId,
        walletA,
        "useCarpet",
        [matchId, 0, 0],
        0n,
        "CarpetFired",
        "confirmCarpet",
      );
    },
    async (matchId) => {
      const turnAddr = (await read("getTurn", [matchId])) as Hex;
      return doShot(matchId, idxOf(turnAddr));
    },
  ]);

  console.log("Every skill's action and confirm pair (Sonar, Barrage, Bombardment, Rake, Salvo, Carpet), plus");
  console.log("placement, dice roll and plain shots, completed using only handles fetched from events and public");
  console.log("getters, the same way a real client has to. No unreachable-handle gap surfaced.\n");

  console.log("Gas used:");
  for (const { label, gasUsed } of gasLog) console.log(`  ${label}: ${gasUsed}`);

  console.log("\nMove latency, send to confirm landing (includes about 3.0s of this script's own");
  console.log("defensive pause, 1.5s after the action write and 1.5s after the confirm write):");
  for (const { label, ms } of moveLog) console.log(`  ${label}: ${(ms / 1000).toFixed(1)}s`);
  if (moveLog.length > 0) {
    const avgMs = moveLog.reduce((sum, m) => sum + m.ms, 0) / moveLog.length;
    console.log(`  average: ${(avgMs / 1000).toFixed(1)}s over ${moveLog.length} moves`);
  }
}

main().catch((err) => {
  console.error("\nEnd-to-end run failed:");
  console.error(err);
  process.exit(1);
});
