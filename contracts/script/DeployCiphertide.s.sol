// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {Ciphertide} from "../src/Ciphertide.sol";

/// @notice Deploys Ciphertide, linked against a CiphertideMechanics address
///         supplied on the command line, not by this file.
/// @dev Ciphertide.sol calls out to CiphertideMechanics as an external
///      library, so its compiled bytecode carries an unresolved library
///      placeholder until the toolchain links it against a real address.
///      Solidity resolves that placeholder at compile time, not at runtime,
///      so this script cannot pick the library address itself the way it
///      picks the deployer key; run this with forge script's own
///      --libraries src/CiphertideMechanics.sol:CiphertideMechanics:<addr>
///      flag, pointing at whatever address DeployMechanics.s.sol produced.
///      deploy.sh wires the two scripts together in the right order.
///      Reads the deployer key from the PRIVATE_KEY environment variable and
///      the RPC from --rpc-url, never a literal in this file. Ciphertide's
///      own Solidity source already points at Inco Lightning's canonical
///      executor address, baked into the inco package's own Lib.sol at the
///      package's build time (the same address on Base Sepolia and Base
///      mainnet, since Inco deploys it through a deterministic CREATE2
///      salt), so this script has no Inco address of its own to wire in.
contract DeployCiphertideScript is Script {
    function run() external returns (address ciphertideAddr) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        Ciphertide game = new Ciphertide();
        vm.stopBroadcast();

        ciphertideAddr = address(game);
        console.log("Ciphertide deployed at", ciphertideAddr);
    }
}
