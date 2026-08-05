// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {euint256, e} from "@inco/lightning/src/Lib.sol";

/// @notice Minimal setup check for the Inco Lightning toolchain.
/// @dev Stores one encrypted integer and lets its owner read it back.
///      Not part of the game itself, only used to confirm the environment works.
contract EncryptedCounter {
    using e for uint256;
    using e for euint256;

    euint256 private value;

    constructor(uint256 initialValue) {
        value = initialValue.asEuint256();
        value.allow(msg.sender);
        value.allowThis();
    }

    function getValue() external view returns (euint256) {
        return value;
    }

    function setValue(uint256 newValue) external {
        value = newValue.asEuint256();
        value.allow(msg.sender);
        value.allowThis();
    }
}
