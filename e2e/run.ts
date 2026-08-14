// Headless end-to-end run of a full Ciphertide match against a live
// deployment on Base Sepolia. No UI, no frontend dependency. Exercises the
// real two-phase encrypt, call, fetch-attestation, confirm loop against
// genuine Inco Lightning infrastructure, the thing the Foundry test suite's
// IncoTest mock cannot exercise: createMatch and joinMatch, real random
// placement plus its confirm, decrypting a player's own board to place a
// real client-encrypted shield, a few shots with their confirms, and one
// area skill (Barrage) with its confirm.
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

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    missingEnv.push(name);
  }
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

  const readConst = async (name: string) =>
    publicClient.readContract({ address: ciphertideAddress, abi: ciphertideAbi, functionName: name }) as Promise<bigint>;

  async function write(wallet: typeof walletA, functionName: string, args: unknown[], value = 0n) {
    const hash = await wallet.writeContract({
      address: ciphertideAddress,
      abi: ciphertideAbi,
      functionName,
      args,
      value,
      chain: baseSepolia,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    gasLog.push({ label: functionName, gasUsed: receipt.gasUsed });
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

  // Step 1: create and join. Player A declares Captain Shield, so the
  // e2e run can later exercise a real client-encrypted input (the shield
  // cell). Player B declares Captain Bombardment, though the skill this
  // run exercises (Barrage) is shared and available to any captain.
  const CAPTAIN_SHIELD = await readConst("CAPTAIN_SHIELD");
  const CAPTAIN_BOMBARDMENT = await readConst("CAPTAIN_BOMBARDMENT");

  console.log("Creating match...");
  const createReceipt = await write(walletA, "createMatch", [CAPTAIN_SHIELD]);
  const { matchId } = findEvent(createReceipt, "MatchCreated") as { matchId: bigint };
  console.log(`Match ${matchId}, gas ${createReceipt.gasUsed}\n`);

  console.log("Joining match...");
  await write(walletB, "joinMatch", [matchId, CAPTAIN_BOMBARDMENT]);

  const addrAtIndex0 = (await read("getPlayerAddress", [matchId, 0])) as Hex;
  const idxOf = (addr: Hex) => (addr.toLowerCase() === addrAtIndex0.toLowerCase() ? 0 : 1);
  const walletOf = (idx: number) => (idx === idxOf(accountA.address) ? walletA : walletB);
  const idxA = idxOf(accountA.address);
  const idxB = idxA === 0 ? 1 : 0;
  console.log(`Player A is index ${idxA}, Player B is index ${idxB}\n`);

  // Step 2: real random placement plus its confirm, for both players.
  const NUM_SHIPS = await readConst("NUM_SHIPS");
  const PLACEMENT_ATTEMPTS_PER_SHIP = await readConst("PLACEMENT_ATTEMPTS_PER_SHIP");
  const MINES_PER_PLAYER = await readConst("MINES_PER_PLAYER");
  const MINE_PLACEMENT_ATTEMPTS = await readConst("MINE_PLACEMENT_ATTEMPTS");
  const placementDraws =
    NUM_SHIPS * PLACEMENT_ATTEMPTS_PER_SHIP + MINES_PER_PLAYER * MINE_PLACEMENT_ATTEMPTS;

  async function placeAndConfirm(wallet: typeof walletA, idx: number, label: string) {
    const fee = (await getFee()) * placementDraws;
    console.log(`${label}: placing board (${placementDraws} random draws, fee ${fee} wei)...`);
    for (let attempt = 0; attempt < 3; attempt++) {
      const receipt = await write(wallet, "placeMyBoard", [matchId], fee);
      console.log(`${label}: placement submitted, gas ${receipt.gasUsed}`);
      const { allPlacedHandle } = findEvent(receipt, "PlacementSubmitted") as { allPlacedHandle: Hex };
      const [{ attestation, signatures }] = await revealAsAttestations([allPlacedHandle]);
      const confirmReceipt = await write(wallet, "confirmPlacement", [matchId, idx, attestation, signatures]);
      const allPlaced = attestation.value !== ("0x" + "0".repeat(64));
      console.log(`${label}: confirmPlacement gas ${confirmReceipt.gasUsed}, allPlaced=${allPlaced}`);
      if (allPlaced) return;
      console.log(`${label}: placement did not find a free slot for every ship, retrying...`);
    }
    throw new Error(`${label}: placement never succeeded after 3 attempts`);
  }

  await placeAndConfirm(walletA, idxA, "Player A");
  await placeAndConfirm(walletB, idxB, "Player B");
  console.log("");

  // Step 3: dice roll to decide who goes first, retried on a tie.
  console.log("Rolling dice...");
  let phase = (await read("getPhase", [matchId])) as number;
  for (let attempt = 0; attempt < 10 && phase !== 3 /* InProgress */; attempt++) {
    const fee = (await getFee()) * 2n;
    const rollReceipt = await write(walletA, "rollDice", [matchId], fee);
    const { rollAHandle, rollBHandle } = findEvent(rollReceipt, "DiceRolled") as {
      rollAHandle: Hex;
      rollBHandle: Hex;
    };
    const [a, b] = await revealAsAttestations([rollAHandle, rollBHandle]);
    await write(walletA, "confirmDiceRoll", [matchId, a.attestation, a.signatures, b.attestation, b.signatures]);
    phase = (await read("getPhase", [matchId])) as number;
  }
  if (phase !== 3) throw new Error("dice roll never decided a starting player");
  console.log("Match in progress.\n");

  // Step 4: decrypt Player A's own board with a wallet-signed attestation
  // (attestedDecrypt, distinct from the public attestedReveal used so far),
  // then place a real shield on one of her own ship cells, a genuine
  // client-encrypted input built with zap.encrypt and consumed on-chain via
  // e.newEuint256. Only meaningful once it is Player A's turn; if Player B
  // goes first, skip this on Player B's own turn instead (shield needs to be
  // placed by CAPTAIN_SHIELD, which only Player A declared).
  async function tryPlaceShield(): Promise<boolean> {
    const turnAddr = (await read("getTurn", [matchId])) as Hex;
    if (turnAddr.toLowerCase() !== accountA.address.toLowerCase()) return false;
    console.log("It is Player A's turn: decrypting her own board to place a real shield...");
    const boardHandle = (await read("getBoardMask", [matchId, idxA])) as Hex;
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
    return true;
  }
  await tryPlaceShield();

  // Step 5: a few shots with their confirms, plus one area skill (Barrage)
  // with its confirm, alternating naturally with whichever player's turn
  // it actually is. Stops early if the match finishes.
  const BARRAGE_MAX_CELLS = await readConst("BARRAGE_MAX_CELLS");
  const BARRAGE_ATTEMPTS_PER_CELL = await readConst("BARRAGE_ATTEMPTS_PER_CELL");
  const barrageDraws = 1n + BARRAGE_MAX_CELLS * BARRAGE_ATTEMPTS_PER_CELL;

  async function nextUnshotCell(defenderIdx: number, from = 0): Promise<number> {
    const shotsAgainst = (await read("getShotsAgainst", [matchId, defenderIdx])) as bigint;
    let cell = from;
    while (((shotsAgainst >> BigInt(cell)) & 1n) === 1n) cell++;
    return cell;
  }

  async function doShot(wallet: typeof walletA, actorIdx: number) {
    const defenderIdx = actorIdx === 0 ? 1 : 0;
    const cell = await nextUnshotCell(defenderIdx);
    console.log(`Shot at cell ${cell}...`);
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
    const nonZero = (h: Hex) => h !== ("0x" + "0".repeat(64));
    console.log(
      `confirmShot gas ${confirmReceipt.gasUsed}, hit=${nonZero(hit.attestation.value)}, ` +
        `mine=${nonZero(mine.attestation.value)}, shieldBreak=${nonZero(shield.attestation.value)}, ` +
        `win=${nonZero(win.attestation.value)}\n`,
    );
    return nonZero(win.attestation.value);
  }

  async function doBarrage(wallet: typeof walletA) {
    console.log("Firing Barrage at (0, 0)...");
    const fee = (await getFee()) * barrageDraws;
    const receipt = await write(wallet, "useBarrage", [matchId, 0, 0], fee);
    console.log(`useBarrage() gas ${receipt.gasUsed}`);
    const { packedHandle, allDestroyedHandle } = findEvent(receipt, "BarrageFired") as {
      packedHandle: Hex;
      allDestroyedHandle: Hex;
    };
    const [packed, win] = await revealAsAttestations([packedHandle, allDestroyedHandle]);
    const confirmReceipt = await write(wallet, "confirmBarrage", [
      matchId,
      packed.attestation,
      packed.signatures,
      win.attestation,
      win.signatures,
    ]);
    console.log(`confirmBarrage gas ${confirmReceipt.gasUsed}, packed=${packed.attestation.value}\n`);
    return win.attestation.value !== ("0x" + "0".repeat(64));
  }

  let finished = false;
  let usedBarrage = false;
  for (let round = 0; round < 6 && !finished; round++) {
    const phaseNow = (await read("getPhase", [matchId])) as number;
    if (phaseNow === 4 /* Finished */) {
      finished = true;
      break;
    }
    const turnAddr = (await read("getTurn", [matchId])) as Hex;
    const actorIdx = idxOf(turnAddr);
    const wallet = walletOf(actorIdx);

    if (!usedBarrage && round === 2) {
      usedBarrage = true;
      finished = await doBarrage(wallet);
    } else {
      finished = await doShot(wallet, actorIdx);
    }
  }

  const finalPhase = (await read("getPhase", [matchId])) as number;
  console.log("Final state:");
  console.log(`  phase: ${["WaitingForOpponent", "Placing", "AwaitingDiceRoll", "InProgress", "Finished"][finalPhase]}`);
  if (finalPhase === 4) {
    const winner = (await read("getWinner", [matchId])) as Hex;
    console.log(`  winner: ${winner}`);
  } else {
    console.log("  no winner yet, this run stopped after a bounded number of rounds");
    console.log("  (a full random-board win typically needs far more shots than this smoke run takes)");
  }

  console.log("\nGas used:");
  for (const { label, gasUsed } of gasLog) console.log(`  ${label}: ${gasUsed}`);
}

main().catch((err) => {
  console.error("\nEnd-to-end run failed:");
  console.error(err);
  process.exit(1);
});
