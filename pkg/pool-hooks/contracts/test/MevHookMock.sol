// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {
    IBalancerContractRegistry
} from "@balancer-labs/v3-interfaces/contracts/standalone-utils/IBalancerContractRegistry.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { MevHook } from "../MevHook.sol";

contract MevHookMock is MevHook {
    constructor(IVault vault, IBalancerContractRegistry registry) MevHook(vault, registry) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function calculateSwapFeePercentageExternal(
        uint256 staticSwapFeePercentage,
        uint256 multiplier,
        uint256 threshold
    ) external view returns (uint256 feePercentage) {
        return _calculateSwapFeePercentage(staticSwapFeePercentage, multiplier, threshold);
    }
}
