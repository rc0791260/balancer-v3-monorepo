// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRouterCommon } from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import {
    AddLiquidityKind,
    RemoveLiquidityKind,
    SwapKind,
    HooksConfig
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {
    ReentrancyGuardTransient
} from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/ReentrancyGuardTransient.sol";

import { PoolHooksMock } from "../../../../contracts/test/PoolHooksMock.sol";
import { BasePoolMath } from "../../../../contracts/BasePoolMath.sol";
import { BaseVaultTest } from "../../utils/BaseVaultTest.sol";
import { Router } from "../../../../contracts/Router.sol";

contract RouterMutationTest is BaseVaultTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256[] internal amountsIn = [poolInitAmount, poolInitAmount].toMemoryArray();

    function setUp() public virtual override {
        BaseVaultTest.setUp();
    }

    function testInitializeHookWhenNotVault() public {
        IRouter.InitializeHookParams memory hookParams = IRouter.InitializeHookParams(
            msg.sender,
            pool,
            tokens,
            amountsIn,
            0,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.initializeHook(hookParams);
    }

    function testInitializeHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyInitializeHook();
    }

    function testAddLiquidityHookWhenNotVault() public {
        IRouterCommon.AddLiquidityHookParams memory hookParams = IRouterCommon.AddLiquidityHookParams(
            msg.sender,
            pool,
            amountsIn,
            0,
            AddLiquidityKind.PROPORTIONAL,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.addLiquidityHook(hookParams);
    }

    function testAddLiquidityHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyAddLiquidityHook();
    }

    function testRemoveLiquidityHookWhenNotVault() public {
        IRouterCommon.RemoveLiquidityHookParams memory params = IRouterCommon.RemoveLiquidityHookParams(
            msg.sender,
            pool,
            [uint256(0), uint256(0)].toMemoryArray(),
            0,
            RemoveLiquidityKind.PROPORTIONAL,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.removeLiquidityHook(params);
    }

    function testRemoveLiquidityHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyRemoveLiquidityHook();
    }

    function testRemoveLiquidityRecoveryHookWhenNotVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.removeLiquidityRecoveryHook(pool, msg.sender, amountsIn[0]);
    }

    function testRemoveLiquidityRecoveryHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyRemoveLiquidityRecoveryHook();
    }

    function testSwapSingleTokenHookWhenNotVault() public {
        IRouter.SwapSingleTokenHookParams memory params = IRouter.SwapSingleTokenHookParams(
            msg.sender,
            SwapKind.EXACT_IN,
            pool,
            IERC20(dai),
            IERC20(usdc),
            amountsIn[0],
            amountsIn[0],
            block.timestamp + 10,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.swapSingleTokenHook(params);
    }

    function testSwapSingleTokenHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancySwapSingleTokenHook();
    }

    function testAddLiquidityToBufferHookWhenNotVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.addLiquidityToBufferHook(IERC4626(address(0)), 0, address(0));
    }

    function testAddLiquidityToBufferHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyAddLiquidityToBufferHook();
    }

    function testQuerySwapHookWhenNotVault() public {
        IRouter.SwapSingleTokenHookParams memory params = IRouter.SwapSingleTokenHookParams(
            msg.sender,
            SwapKind.EXACT_IN,
            pool,
            IERC20(dai),
            IERC20(usdc),
            amountsIn[0],
            0,
            block.timestamp + 10,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.querySwapHook(params);
    }

    function testQuerySwapHookReentrancy() public {
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.manualReentrancyQuerySwapHook();
    }

    function testQueryAddLiquidityHookWhenNotVault() public {
        IRouterCommon.AddLiquidityHookParams memory hookParams = IRouterCommon.AddLiquidityHookParams(
            msg.sender,
            pool,
            amountsIn,
            0,
            AddLiquidityKind.PROPORTIONAL,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.queryAddLiquidityHook(hookParams);
    }

    function testQueryRemoveLiquidityHookWhenNotVault() public {
        IRouterCommon.RemoveLiquidityHookParams memory params = IRouterCommon.RemoveLiquidityHookParams(
            msg.sender,
            pool,
            amountsIn,
            0,
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            false,
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.queryRemoveLiquidityHook(params);
    }

    function testQueryRemoveLiquidityRecoveryHookWhenNoVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        router.queryRemoveLiquidityRecoveryHook(pool, msg.sender, 10);
    }
}
