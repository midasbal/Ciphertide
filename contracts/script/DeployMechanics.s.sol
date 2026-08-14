// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";

/// @notice Deploys the CiphertideMechanics library standalone, as its own
///         transaction, so its address is known before Ciphertide is built
///         and linked against it in DeployCiphertide.s.sol.
/// @dev CiphertideMechanics is a Solidity library, not a contract, so it
///      cannot be instantiated with a plain `new` expression the way
///      DeployCiphertide.s.sol instantiates Ciphertide. deployCode reads the
///      compiled artifact's own creation bytecode and sends it as a normal
///      contract creation transaction, which works for a library too since a
///      library's creation bytecode is deployed exactly like a contract's,
///      only the runtime code is meant to be delegatecalled into afterward.
///      Reads the deployer key from the PRIVATE_KEY environment variable and
///      the RPC from --rpc-url, never a literal in this file.
contract DeployMechanicsScript is Script {
    function run() external returns (address mechanicsAddr) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        mechanicsAddr = deployCode("CiphertideMechanics.sol:CiphertideMechanics");
        vm.stopBroadcast();

        console.log("CiphertideMechanics deployed at", mechanicsAddr);
    }
}
