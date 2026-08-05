// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {EncryptedCounter} from "../EncryptedCounter.sol";
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";

/// @notice Confirms the Inco Lightning toolchain compiles and runs, storing
///         and reading back one encrypted integer. Not a game mechanics test.
contract EncryptedCounterTest is IncoTest {
    EncryptedCounter counter;

    function setUp() public override {
        super.setUp();
        counter = new EncryptedCounter(42);
    }

    function testStoresAndReadsBackEncryptedValue() public {
        processAllOperations();
        uint256 decrypted = getUint256Value(counter.getValue());
        assertEq(decrypted, 42);
    }

    function testSetValueUpdatesEncryptedValue() public {
        counter.setValue(7);
        processAllOperations();
        uint256 decrypted = getUint256Value(counter.getValue());
        assertEq(decrypted, 7);
    }
}
