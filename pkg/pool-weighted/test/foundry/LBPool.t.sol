// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { TokenConfig, PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { PoolHooksMock } from "@balancer-labs/v3-vault/contracts/test/PoolHooksMock.sol";
import { BasePoolTest } from "@balancer-labs/v3-vault/test/foundry/utils/BasePoolTest.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { LBPoolFactory } from "../../contracts/LBPoolFactory.sol";
import { LBPool } from "../../contracts/LBPool.sol";
import "forge-std/console.sol";

contract LBPoolTest is BasePoolTest {
    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 constant DEFAULT_SWAP_FEE = 1e16; // 1%
    uint256 constant TOKEN_AMOUNT = 1e3 * 1e18;

    uint256[] internal weights;

    uint256 daiIdx;
    uint256 usdcIdx;

    function setUp() public virtual override {
        expectedAddLiquidityBptAmountOut = TOKEN_AMOUNT;
        tokenAmountIn = TOKEN_AMOUNT / 4;
        isTestSwapFeeEnabled = false;

        BasePoolTest.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        poolMinSwapFeePercentage = 0.001e16; // 0.001%
        poolMaxSwapFeePercentage = 10e16;
    }

    function createPool() internal override returns (address) {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(dai), address(usdc)].toMemoryArray().asIERC20()
        );
        for (uint256 i = 0; i < sortedTokens.length; i++) {
            poolTokens.push(sortedTokens[i]);
            tokenAmounts.push(TOKEN_AMOUNT);
        }

        factory = new LBPoolFactory(IVault(address(vault)), 365 days, "Factory v1", "Pool v1", address(0), address(router));
        weights = [uint256(50e16), uint256(50e16)].toMemoryArray();

        // Allow pools created by `factory` to use poolHooksMock hooks
        PoolHooksMock(poolHooksContract).allowFactory(address(factory));

        LBPool newPool = LBPool(
            LBPoolFactory(address(factory)).create(
                "LB Pool",
                "LBPOOL",
                vault.buildTokenConfig(sortedTokens),
                weights,
                DEFAULT_SWAP_FEE,
                bob,
                true,
                ZERO_BYTES32
            )
        );
        return address(newPool);
    }

    function testInitialize() public view override {
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));

        for (uint256 i = 0; i < poolTokens.length; ++i) {
            // Tokens are transferred from bob (lp/owner)
            assertEq(
                defaultBalance - poolTokens[i].balanceOf(bob),
                tokenAmounts[i],
                string.concat("LP: Wrong balance for ", Strings.toString(i))
            );

            // Tokens are stored in the Vault
            assertEq(
                poolTokens[i].balanceOf(address(vault)),
                tokenAmounts[i],
                string.concat("LP: Vault balance for ", Strings.toString(i))
            );

            // Tokens are deposited to the pool
            assertEq(
                balances[i],
                tokenAmounts[i],
                string.concat("Pool: Wrong token balance for ", Strings.toString(i))
            );
        }

        // should mint correct amount of BPT poolTokens
        // Account for the precision loss
        assertApproxEqAbs(IERC20(pool).balanceOf(bob), bptAmountOut, DELTA, "LP: Wrong bptAmountOut");
        assertApproxEqAbs(bptAmountOut, expectedAddLiquidityBptAmountOut, DELTA, "Wrong bptAmountOut");
    }

    function initPool() internal override {
        vm.startPrank(bob);
        bptAmountOut = _initPool(
            pool,
            tokenAmounts,
            // Account for the precision loss
            expectedAddLiquidityBptAmountOut - DELTA
        );
        vm.stopPrank();
    }

    // overriding b/c bob needs to be the LP and has contributed double the "normal" amount of tokens
    function testAddLiquidity() public override {
        uint256 oldBptAmount = IERC20(pool).balanceOf(bob);
        vm.prank(bob);
        bptAmountOut = router.addLiquidityUnbalanced(pool, tokenAmounts, tokenAmountIn - DELTA, false, bytes(""));

        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));

        for (uint256 i = 0; i < poolTokens.length; ++i) {
            // Tokens are transferred from Bob
            assertEq(
                defaultBalance - poolTokens[i].balanceOf(bob),
                tokenAmounts[i] * 2, // x2 because bob (as owner) did init join and subsequent join
                string.concat("LP: Wrong token balance for ", Strings.toString(i))
            );

            // Tokens are stored in the Vault
            assertEq(
                poolTokens[i].balanceOf(address(vault)),
                tokenAmounts[i] * 2,
                string.concat("Vault: Wrong token balance for ", Strings.toString(i))
            );

            assertEq(
                balances[i],
                tokenAmounts[i] * 2,
                string.concat("Pool: Wrong token balance for ", Strings.toString(i))
            );
        }

        uint256 newBptAmount = IERC20(pool).balanceOf(bob);

        // should mint correct amount of BPT poolTokens
        assertApproxEqAbs(newBptAmount - oldBptAmount, bptAmountOut, DELTA, "LP: Wrong bptAmountOut");
        assertApproxEqAbs(bptAmountOut, expectedAddLiquidityBptAmountOut, DELTA, "Wrong bptAmountOut");
    }

    // overriding b/c bob has swap fee authority, not governance
    // TODO: why does this test need to change swap fee anyway?
    function testAddLiquidityUnbalanced() public override {
        vm.prank(bob);
        vault.setStaticSwapFeePercentage(pool, 10e16);

        uint256[] memory amountsIn = tokenAmounts;
        amountsIn[0] = amountsIn[0].mulDown(IBasePool(pool).getMaximumInvariantRatio());
        vm.prank(bob);

        router.addLiquidityUnbalanced(pool, amountsIn, 0, false, bytes(""));
    }

    function testRemoveLiquidity() public override {
        vm.startPrank(bob);
        uint256 oldBptAmount = IERC20(pool).balanceOf(bob);
        router.addLiquidityUnbalanced(pool, tokenAmounts, tokenAmountIn - DELTA, false, bytes(""));
        uint256 newBptAmount = IERC20(pool).balanceOf(bob);

        IERC20(pool).approve(address(vault), MAX_UINT256);

        uint256 bptAmountIn = newBptAmount - oldBptAmount;

        uint256[] memory minAmountsOut = new uint256[](poolTokens.length);
        for (uint256 i = 0; i < poolTokens.length; ++i) {
            minAmountsOut[i] = _less(tokenAmounts[i], 1e4);
        }

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            pool,
            bptAmountIn,
            minAmountsOut,
            false,
            bytes("")
        );

        vm.stopPrank();

        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));

        for (uint256 i = 0; i < poolTokens.length; ++i) {
            // Tokens are transferred to Bob
            assertApproxEqAbs(
                poolTokens[i].balanceOf(bob) + TOKEN_AMOUNT, //add TOKEN_AMOUNT to account for init join
                defaultBalance,
                DELTA,
                string.concat("LP: Wrong token balance for ", Strings.toString(i))
            );

            // Tokens are stored in the Vault
            assertApproxEqAbs(
                poolTokens[i].balanceOf(address(vault)),
                tokenAmounts[i],
                DELTA,
                string.concat("Vault: Wrong token balance for ", Strings.toString(i))
            );

            // Tokens are deposited to the pool
            assertApproxEqAbs(
                balances[i],
                tokenAmounts[i],
                DELTA,
                string.concat("Pool: Wrong token balance for ", Strings.toString(i))
            );

            // amountsOut are correct
            assertApproxEqAbs(
                amountsOut[i],
                tokenAmounts[i],
                DELTA,
                string.concat("Wrong token amountOut for ", Strings.toString(i))
            );
        }

        // should return to correct amount of BPT poolTokens
        assertEq(IERC20(pool).balanceOf(bob), oldBptAmount, "LP: Wrong BPT balance");
    }

    function testSwap() public override {
        if (!isTestSwapFeeEnabled) {
            vault.manuallySetSwapFee(pool, 0);
        }

        IERC20 tokenIn = poolTokens[tokenIndexIn];
        IERC20 tokenOut = poolTokens[tokenIndexOut];

        uint256 bobBeforeBalanceTokenOut = tokenOut.balanceOf(bob);
        uint256 bobBeforeBalanceTokenIn = tokenIn.balanceOf(bob);

        vm.prank(bob);
        uint256 amountCalculated = router.swapSingleTokenExactIn(
            pool,
            tokenIn,
            tokenOut,
            tokenAmountIn,
            _less(tokenAmountOut, 1e3),
            MAX_UINT256,
            false,
            bytes("")
        );

        // Tokens are transferred from Bob
        assertEq(tokenOut.balanceOf(bob), bobBeforeBalanceTokenOut + amountCalculated, "LP: Wrong tokenOut balance");
        assertEq(tokenIn.balanceOf(bob), bobBeforeBalanceTokenIn - tokenAmountIn, "LP: Wrong tokenIn balance");

        // Tokens are stored in the Vault
        assertEq(
            tokenOut.balanceOf(address(vault)),
            tokenAmounts[tokenIndexOut] - amountCalculated,
            "Vault: Wrong tokenOut balance"
        );
        assertEq(
            tokenIn.balanceOf(address(vault)),
            tokenAmounts[tokenIndexIn] + tokenAmountIn,
            "Vault: Wrong tokenIn balance"
        );

        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        assertEq(balances[tokenIndexIn], tokenAmounts[tokenIndexIn] + tokenAmountIn, "Pool: Wrong tokenIn balance");
        assertEq(
            balances[tokenIndexOut],
            tokenAmounts[tokenIndexOut] - amountCalculated,
            "Pool: Wrong tokenOut balance"
        );
    }

    function testOnlyOwnerCanBeLP() public {
        uint256[] memory amounts = [TOKEN_AMOUNT, TOKEN_AMOUNT].toMemoryArray();

        vm.startPrank(bob);
        router.addLiquidityUnbalanced(address(pool), amounts, 0, false, "");
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BeforeAddLiquidityHookFailed.selector));
        router.addLiquidityUnbalanced(address(pool), amounts, 0, false, "");
        vm.stopPrank();
    }

    function testSwapRestrictions() public {
        // Ensure swaps are initially enabled
        assertTrue(LBPool(address(pool)).getSwapEnabled(), "Swaps should be enabled initially");

        // Test swap when enabled
        vm.prank(alice);
        router.swapSingleTokenExactIn(
            address(pool),
            IERC20(dai),
            IERC20(usdc),
            TOKEN_AMOUNT / 10,
            0,
            block.timestamp + 1 hours,
            false,
            ""
        );

        // Disable swaps
        vm.prank(bob);
        LBPool(address(pool)).setSwapEnabled(false);

        // Verify swaps are disabled
        assertFalse(LBPool(address(pool)).getSwapEnabled(), "Swaps should be disabled");

        // Test swap when disabled
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BeforeSwapHookFailed.selector));
        router.swapSingleTokenExactIn(
            address(pool),
            IERC20(dai),
            IERC20(usdc),
            TOKEN_AMOUNT / 10,
            0,
            block.timestamp + 1 hours,
            false,
            ""
        );

        // Re-enable swaps
        vm.prank(bob);
        LBPool(address(pool)).setSwapEnabled(true);

        // Verify swaps are re-enabled
        assertTrue(LBPool(address(pool)).getSwapEnabled(), "Swaps should be re-enabled");

        // Test swap after re-enabling
        vm.prank(alice);
        router.swapSingleTokenExactIn(
            address(pool),
            IERC20(dai),
            IERC20(usdc),
            TOKEN_AMOUNT / 10,
            0,
            block.timestamp + 1 hours,
            false,
            ""
        );
    }

}