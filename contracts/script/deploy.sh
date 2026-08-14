#!/usr/bin/env bash
# Deploys CiphertideMechanics then Ciphertide to Base Sepolia, in that order,
# linking Ciphertide's bytecode against the library's freshly deployed
# address. Two separate forge script invocations, not one, because Solidity
# resolves an external library's address into the caller's bytecode at
# compile time, not at runtime, so the address has to be known before
# Ciphertide is even compiled. See DeployMechanics.s.sol and
# DeployCiphertide.s.sol for the deploy logic itself, this script only
# wires the two together and records the result.
#
# Reads PRIVATE_KEY and BASE_SEPOLIA_RPC_URL from contracts/.env if present,
# otherwise expects them already exported. Never prints the private key.
# Writes the two public deployed addresses to deployments/baseSepolia.json,
# safe to commit, no secrets in it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

if [ -z "${PRIVATE_KEY:-}" ]; then
    echo "Missing PRIVATE_KEY. Set it in contracts/.env (see .env.example) or export it before running this script."
    exit 1
fi
if [ -z "${BASE_SEPOLIA_RPC_URL:-}" ]; then
    echo "Missing BASE_SEPOLIA_RPC_URL. Set it in contracts/.env (see .env.example) or export it before running this script."
    exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Deployer: $DEPLOYER"

BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC_URL")
echo "Balance: $BALANCE wei"
if [ "$BALANCE" = "0" ]; then
    echo "Deployer $DEPLOYER has no Base Sepolia ETH. Fund it from a Base Sepolia faucet, then rerun this script."
    exit 1
fi

CHAIN_ID=$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")
if [ "$CHAIN_ID" != "84532" ]; then
    echo "BASE_SEPOLIA_RPC_URL points at chain id $CHAIN_ID, expected 84532 (Base Sepolia). Refusing to deploy."
    exit 1
fi

echo "Deploying CiphertideMechanics..."
forge script script/DeployMechanics.s.sol \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast

MECHANICS_ADDR=$(jq -r '.transactions[0].contractAddress' broadcast/DeployMechanics.s.sol/84532/run-latest.json)
echo "CiphertideMechanics: $MECHANICS_ADDR"

echo "Deploying Ciphertide, linked against CiphertideMechanics..."
forge script script/DeployCiphertide.s.sol \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --libraries "src/CiphertideMechanics.sol:CiphertideMechanics:$MECHANICS_ADDR"

CIPHERTIDE_ADDR=$(jq -r '.transactions[0].contractAddress' broadcast/DeployCiphertide.s.sol/84532/run-latest.json)
echo "Ciphertide: $CIPHERTIDE_ADDR"

mkdir -p deployments
cat > deployments/baseSepolia.json <<JSON
{
  "chainId": 84532,
  "chainName": "Base Sepolia",
  "deployer": "$DEPLOYER",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
  "contracts": {
    "CiphertideMechanics": "$MECHANICS_ADDR",
    "Ciphertide": "$CIPHERTIDE_ADDR"
  }
}
JSON

echo "Wrote deployments/baseSepolia.json"
