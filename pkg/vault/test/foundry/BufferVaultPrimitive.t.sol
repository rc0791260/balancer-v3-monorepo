// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBatchRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IBatchRouter.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ERC4626TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC4626TestToken.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseVaultTest } from "./utils/BaseVaultTest.sol";

contract BufferVaultPrimitiveTest is BaseVaultTest {
    using FixedPoint for uint256;

    uint256 private constant _userAmount = 10e6 * 1e18;
    uint256 private constant _wrapAmount = _userAmount / 100;

    function setUp() public virtual override {
        BaseVaultTest.setUp();

        // Authorizes user "admin" to pause/unpause vault's buffer.
        authorizer.grantRole(vault.getActionId(IVaultAdmin.pauseVaultBuffers.selector), admin);
        authorizer.grantRole(vault.getActionId(IVaultAdmin.unpauseVaultBuffers.selector), admin);
        // Authorizes router to call removeLiquidityFromBuffer (trusted router).
        authorizer.grantRole(vault.getActionId(IVaultAdmin.removeLiquidityFromBuffer.selector), address(router));

        initializeLp();
    }

    function initializeLp() private {
        // Create and fund buffer pools
        vm.startPrank(lp);

        // Minting wrong token to wrapped token contracts, to test changing the asset.
        dai.mint(address(waUSDC), _userAmount);
        usdc.mint(address(waDAI), _userAmount);

        vm.stopPrank();
    }

    /********************************************************************************
                                        Asset
    ********************************************************************************/
    function testChangeAssetOfWrappedTokenAddLiquidityToBuffer() public {
        // Change Asset to correct asset.
        waDAI.setAsset(dai);

        vm.prank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);

        // Change Asset to the wrong asset.
        waDAI.setAsset(usdc);

        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.WrongUnderlyingToken.selector, address(waDAI), address(usdc))
        );
        router.addLiquidityToBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);
    }

    function testChangeAssetOfWrappedTokenRemoveLiquidityFromBuffer() public {
        // Change Asset to correct asset.
        waDAI.setAsset(dai);

        vm.prank(lp);
        uint256 lpShares = router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);

        // Change Asset to the wrong asset.
        waDAI.setAsset(usdc);

        // Does not revert: remove liquidity doesn't check whether the asset matches the registered one in order to
        // avoid external calls. You can always exit the buffer, even if the wrapper is corrupt and updated its asset.
        vm.prank(lp);
        vault.removeLiquidityFromBuffer(IERC4626(address(waDAI)), lpShares);
    }

    function testChangeAssetOfWrappedTokenWrapUnwrap() public {
        // Change Asset to correct asset.
        waDAI.setAsset(dai);

        // Wrap token should pass, since there's no liquidity in the buffer.
        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            _wrapAmount,
            0,
            usdc,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        vm.prank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);

        // Change Asset to the wrong asset.
        waDAI.setAsset(usdc);

        // Wrap token should fail, since buffer has liquidity.
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.WrongUnderlyingToken.selector, address(waDAI), address(usdc))
        );
        batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));
    }

    function testExactInOverflow() public {
        // Above permit2 limit of uint160.
        uint256 overflowAmount = type(uint168).max;

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            overflowAmount,
            0,
            usdc,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 160, overflowAmount));
        batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));
    }

    /********************************************************************************
                                        Deposit
    ********************************************************************************/
    function testDepositInteractionWithERC4626Protocol() public {
        // Initializes the buffer with an amount that's not enough to fulfill the deposit operation, so the vault has
        // to interact with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount / 10, waDAI.convertToShares(_wrapAmount / 10));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            _wrapAmount,
            0,
            dai,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsOut, , ) = batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));

        _checkWrapResults(balancesBefore, _wrapAmount, pathAmountsOut[0], SwapKind.EXACT_IN, false);
    }

    function testDepositWithBufferLiquidity() public {
        // Initializes the buffer with an amount that's enough to fulfill the deposit operation without interacting
        // with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), 2 * _wrapAmount, waDAI.convertToShares(2 * _wrapAmount));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            _wrapAmount,
            0,
            dai,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsOut, , ) = batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));

        _checkWrapResults(balancesBefore, _wrapAmount, pathAmountsOut[0], SwapKind.EXACT_IN, true);
    }

    function testDepositMaliciousRouter() public {
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, waDAI.convertToShares(_wrapAmount));
        vm.stopPrank();

        // Deposit will not take the underlying tokens, keeping the approval, so the wrapper can use vault approval to
        // drain the whole vault.
        waDAI.setMaliciousWrapper(true);

        uint256 vaultBalance = dai.balanceOf(address(vault));

        // If a wrapper operation takes less tokens than what the user requested, or returns less tokens than the
        // wrapper informs, that quantities must be settled by the router. So, an approval attack is not possible.
        vm.expectRevert(IVaultErrors.BalanceNotSettled.selector);
        vault.unlock(
            abi.encodeCall(
                BufferVaultPrimitiveTest.erc4626MaliciousHook,
                BufferWrapOrUnwrapParams({
                    kind: SwapKind.EXACT_IN,
                    direction: WrappingDirection.WRAP,
                    wrappedToken: IERC4626(address(waDAI)),
                    amountGivenRaw: vaultBalance,
                    limitRaw: 0,
                    userData: bytes("")
                })
            )
        );
    }

    /********************************************************************************
                                        Mint
    ********************************************************************************/
    function testMintInteractionWithERC4626Protocol() public {
        // Initializes the buffer with an amount that's not enough to fulfill the mint operation, so the vault has
        // to interact with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount / 10, waDAI.convertToShares(_wrapAmount / 10));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountOut[] memory paths = _exactOutWrapUnwrapPath(
            2 * _wrapAmount,
            waDAI.convertToShares(_wrapAmount),
            dai,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsIn, , ) = batchRouter.swapExactOut(paths, MAX_UINT256, false, bytes(""));

        _checkWrapResults(
            balancesBefore,
            pathAmountsIn[0],
            waDAI.convertToShares(_wrapAmount),
            SwapKind.EXACT_OUT,
            false
        );
    }

    function testMintWithBufferLiquidity() public {
        // Initializes the buffer with an amount that's enough to fulfill the mint operation without interacting
        // with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), 2 * _wrapAmount, waDAI.convertToShares(2 * _wrapAmount));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountOut[] memory paths = _exactOutWrapUnwrapPath(
            2 * _wrapAmount,
            waDAI.convertToShares(_wrapAmount),
            dai,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsIn, , ) = batchRouter.swapExactOut(paths, MAX_UINT256, false, bytes(""));

        _checkWrapResults(
            balancesBefore,
            pathAmountsIn[0],
            waDAI.convertToShares(_wrapAmount),
            SwapKind.EXACT_OUT,
            true
        );
    }

    function testMintMaliciousRouter() public {
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, waDAI.convertToShares(_wrapAmount));
        vm.stopPrank();

        // Deposit will not take the underlying tokens, keeping the approval, so the wrapper can use vault approval to
        // drain the whole vault.
        waDAI.setMaliciousWrapper(true);

        vault.unlock(
            abi.encodeCall(
                BufferVaultPrimitiveTest.erc4626MaliciousHook,
                BufferWrapOrUnwrapParams({
                    kind: SwapKind.EXACT_OUT,
                    direction: WrappingDirection.WRAP,
                    wrappedToken: IERC4626(address(waDAI)),
                    amountGivenRaw: PRODUCTION_MIN_WRAP_AMOUNT,
                    limitRaw: MAX_UINT128,
                    userData: bytes("")
                })
            )
        );

        // After a wrap operation, even if the erc4626 token didn't take all the assets it was supposed to deposit,
        // the allowance should be 0 to avoid a malicious wrapper from draining the underlying balance of the vault.
        assertTrue(dai.allowance(address(vault), address(waDAI)) == 0, "Wrong allowance");
    }

    /********************************************************************************
                                        Redeem
    ********************************************************************************/
    function testRedeemInteractionWithERC4626Protocol() public {
        // Initializes the buffer with an amount that's not enough to fulfill the mint operation, so the vault has
        // to interact with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount / 10, waDAI.convertToShares(_wrapAmount / 10));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            waDAI.convertToShares(_wrapAmount),
            0,
            IERC20(address(waDAI)),
            dai,
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsOut, , ) = batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));

        _checkUnwrapResults(
            balancesBefore,
            waDAI.convertToShares(_wrapAmount),
            pathAmountsOut[0],
            SwapKind.EXACT_IN,
            false
        );
    }

    function testRedeemWithBufferLiquidity() public {
        // Initializes the buffer with an amount that's enough to fulfill the mint operation without interacting
        // with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), 2 * _wrapAmount, waDAI.convertToShares(2 * _wrapAmount));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            waDAI.convertToShares(_wrapAmount),
            0,
            IERC20(address(waDAI)),
            dai,
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsOut, , ) = batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));

        _checkUnwrapResults(
            balancesBefore,
            waDAI.convertToShares(_wrapAmount),
            pathAmountsOut[0],
            SwapKind.EXACT_IN,
            true
        );
    }

    /********************************************************************************
                                        Withdraw
    ********************************************************************************/
    function testWithdrawInteractionWithERC4626Protocol() public {
        // Initializes the buffer with an amount that's not enough to fulfill the mint operation, so the vault has
        // to interact with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount / 10, waDAI.convertToShares(_wrapAmount / 10));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountOut[] memory paths = _exactOutWrapUnwrapPath(
            2 * waDAI.convertToShares(_wrapAmount),
            _wrapAmount,
            IERC20(address(waDAI)),
            dai,
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsIn, , ) = batchRouter.swapExactOut(paths, MAX_UINT256, false, bytes(""));

        _checkUnwrapResults(balancesBefore, pathAmountsIn[0], _wrapAmount, SwapKind.EXACT_OUT, false);
    }

    function testWithdrawWithBufferLiquidity() public {
        // Initializes the buffer with an amount that's enough to fulfill the mint operation without interacting
        // with the ERC4626 protocol.
        vm.startPrank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), 2 * _wrapAmount, waDAI.convertToShares(2 * _wrapAmount));
        vm.stopPrank();

        IBatchRouter.SwapPathExactAmountOut[] memory paths = _exactOutWrapUnwrapPath(
            2 * waDAI.convertToShares(_wrapAmount),
            _wrapAmount,
            IERC20(address(waDAI)),
            dai,
            IERC20(address(waDAI))
        );

        (, , IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesBefore = getBalances(lp, tokens);

        vm.prank(lp);
        (uint256[] memory pathAmountsIn, , ) = batchRouter.swapExactOut(paths, MAX_UINT256, false, bytes(""));

        _checkUnwrapResults(balancesBefore, pathAmountsIn[0], _wrapAmount, SwapKind.EXACT_OUT, true);
    }

    /********************************************************************************
                                Disable Vault Buffers
    ********************************************************************************/
    // Make sure only authorized users can disable/enable vault buffers.
    function testDisableVaultBufferAuthentication() public {
        vm.prank(alice);
        // Should revert, since alice has no rights to disable buffer.
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        IVaultAdmin(address(vault)).pauseVaultBuffers();

        vm.prank(admin);
        // Should pass, since admin has access
        IVaultAdmin(address(vault)).pauseVaultBuffers();

        vm.prank(alice);
        // Should revert, since alice has no rights to enable buffer.
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        IVaultAdmin(address(vault)).unpauseVaultBuffers();

        vm.prank(admin);
        // Should pass, since admin has access.
        IVaultAdmin(address(vault)).unpauseVaultBuffers();
    }

    function testDisableVaultBuffer() public {
        vm.prank(lp);
        router.initializeBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);

        vm.prank(admin);
        IVaultAdmin(address(vault)).pauseVaultBuffers();

        IBatchRouter.SwapPathExactAmountIn[] memory paths = _exactInWrapUnwrapPath(
            _wrapAmount,
            0,
            dai,
            IERC20(address(waDAI)),
            IERC20(address(waDAI))
        );

        // Wrap/unwrap, add and remove liquidity should fail, since vault buffers are disabled.
        vm.startPrank(lp);

        vm.expectRevert(IVaultErrors.VaultBuffersArePaused.selector);
        batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));

        vm.expectRevert(IVaultErrors.VaultBuffersArePaused.selector);
        router.addLiquidityToBuffer(IERC4626(address(waDAI)), _wrapAmount, _wrapAmount);

        // Remove liquidity is supposed to pass even with buffers paused, so revert is not expected.
        vault.removeLiquidityFromBuffer(IERC4626(address(waDAI)), _wrapAmount);

        vm.stopPrank();

        vm.prank(admin);
        IVaultAdmin(address(vault)).unpauseVaultBuffers();

        // Deposit should pass, since vault buffers are enabled.
        vm.prank(lp);
        batchRouter.swapExactIn(paths, MAX_UINT256, false, bytes(""));
    }

    /********************************************************************************
                          Add/Remove Liquidity from Buffers
    ********************************************************************************/

    function testAddLiquidityToBuffer() public {
        vm.prank(lp);
        router.initializeBuffer(waDAI, 1e18, 1e18);

        BufferAndLPBalances memory beforeBalances = _measureBuffer();

        uint256 underlyingAmountIn = _wrapAmount;
        uint256 wrappedAmountIn = _wrapAmount.mulDown(2e18);

        uint256 lpSharesBeforeAdd = vault.getBufferOwnerShares(waDAI, lp);
        vm.prank(lp);
        uint256 lpSharesAdded = router.addLiquidityToBuffer(waDAI, underlyingAmountIn, wrappedAmountIn);

        BufferAndLPBalances memory afterBalances = _measureBuffer();

        assertEq(
            afterBalances.buffer.dai,
            beforeBalances.buffer.dai + underlyingAmountIn,
            "Buffer DAI balance is wrong"
        );
        assertEq(
            afterBalances.buffer.waDai,
            beforeBalances.buffer.waDai + wrappedAmountIn,
            "Buffer waDAI balance is wrong"
        );

        assertEq(afterBalances.vault.dai, beforeBalances.vault.dai + underlyingAmountIn, "Vault DAI balance is wrong");
        assertEq(
            afterBalances.vault.waDai,
            beforeBalances.vault.waDai + wrappedAmountIn,
            "Vault waDAI balance is wrong"
        );

        assertEq(
            afterBalances.vaultReserves.dai,
            beforeBalances.vaultReserves.dai + underlyingAmountIn,
            "Vault Reserve DAI balance is wrong"
        );
        assertEq(
            afterBalances.vaultReserves.waDai,
            beforeBalances.vaultReserves.waDai + wrappedAmountIn,
            "Vault Reserve waDAI balance is wrong"
        );

        assertEq(afterBalances.lp.dai, beforeBalances.lp.dai - underlyingAmountIn, "LP DAI balance is wrong");
        assertEq(afterBalances.lp.waDai, beforeBalances.lp.waDai - wrappedAmountIn, "LP waDAI balance is wrong");

        assertEq(
            lpSharesBeforeAdd + lpSharesAdded,
            vault.getBufferOwnerShares(IERC4626(address(waDAI)), lp),
            "LP Buffer shares is wrong"
        );
        assertEq(lpSharesAdded, underlyingAmountIn + waDAI.convertToAssets(wrappedAmountIn), "Issued shares is wrong");
    }

    function testAddLiquidityToBufferWithRateChange() public {
        vm.prank(lp);
        uint256 firstAddLpShares = router.initializeBuffer(waDAI, _wrapAmount, _wrapAmount);
        // After the first add liquidity operation, ending balances are (using 1000 for _wrapAmount for simplicity):
        // [1000 underlying, 1000 wrapped]; total supply is ~2000 (not counting the initialization).

        assertEq(
            firstAddLpShares,
            _wrapAmount + waDAI.convertToAssets(_wrapAmount) - BUFFER_MINIMUM_TOTAL_SUPPLY,
            "Wrong first lpShares added"
        );
        uint256 rate = 2e18;

        // Add [2000 underlying, 0 wrapped] when the rate is 2: (1 wrapped = 2 underlying)
        waDAI.mockRate(rate);

        uint256 secondAddUnderlying = _wrapAmount * 2;

        (uint256 bufferUnderlyingBalance, uint256 bufferWrappedBalance) = vault.getBufferBalance(waDAI);
        uint256 currentInvariant = bufferUnderlyingBalance + bufferWrappedBalance.mulDown(rate);

        // Shares = current supply (= first shares added) times the invariant ratio.
        uint256 expectedSecondAddShares = (vault.getBufferTotalShares(waDAI) * secondAddUnderlying) / currentInvariant;

        vm.prank(lp);
        uint256 secondAddLpShares = router.addLiquidityToBuffer(waDAI, secondAddUnderlying, 0);
        assertEq(secondAddLpShares, expectedSecondAddShares, "Wrong second lpShares added");

        uint256 proportionalWithdrawPct = secondAddLpShares.divDown(vault.getBufferTotalShares(waDAI));
        (bufferUnderlyingBalance, bufferWrappedBalance) = vault.getBufferBalance(waDAI);

        uint256 expectedUnderlyingOut = proportionalWithdrawPct.mulDown(bufferUnderlyingBalance);
        uint256 expectedWrappedOut = proportionalWithdrawPct.mulDown(bufferWrappedBalance);
        // Will get 1333.333/3333.333 = 40% of value:
        // [0.4 * 3000, 0.4 * 1000] = [1200 underlying, 400 wrapped] - worth 2000 = amount in
        vm.prank(lp);
        (uint256 removedUnderlying, uint256 removedWrapped) = vault.removeLiquidityFromBuffer(waDAI, secondAddLpShares);
        assertApproxEqAbs(removedUnderlying, expectedUnderlyingOut, 1e6, "Wrong underlying amount removed");
        assertApproxEqAbs(removedWrapped, expectedWrappedOut, 1e6, "Wrong wrapped amount removed");

        uint256 totalUnderlyingValue = removedUnderlying + rate.mulDown(removedWrapped);
        assertLe(totalUnderlyingValue, secondAddUnderlying, "Value removed > value added");
        assertApproxEqAbs(totalUnderlyingValue, secondAddUnderlying, 3, "Value removed !~ value added");
    }

    // Trying to increase the coverage by splitting into two rate regimes, and limiting the range.
    function testAddLiquidityToBufferWithIncreasedRate_Fuzz(
        uint128 firstDepositUnderlying,
        uint128 firstDepositWrapped,
        uint128 secondDepositUnderlying,
        uint128 secondDepositWrapped,
        uint64 rate
    ) public {
        _addLiquidityToBufferWithRate(
            bound(firstDepositUnderlying, 0, _wrapAmount),
            bound(firstDepositWrapped, 0, _wrapAmount),
            bound(secondDepositUnderlying, 0, _wrapAmount),
            bound(secondDepositWrapped, 0, _wrapAmount),
            bound(rate, 1e18, 10_000e18)
        );
    }

    function testAddLiquidityToBufferWithDecreasedRate_Fuzz(
        uint128 firstDepositUnderlying,
        uint128 firstDepositWrapped,
        uint128 secondDepositUnderlying,
        uint128 secondDepositWrapped,
        uint64 rate
    ) public {
        _addLiquidityToBufferWithRate(
            bound(firstDepositUnderlying, 0, _wrapAmount),
            bound(firstDepositWrapped, 0, _wrapAmount),
            bound(secondDepositUnderlying, 0, _wrapAmount),
            bound(secondDepositWrapped, 0, _wrapAmount),
            bound(rate, 0.0001e18, 1e18)
        );
    }

    function _addLiquidityToBufferWithRate(
        uint256 firstDepositUnderlying,
        uint256 firstDepositWrapped,
        uint256 secondDepositUnderlying,
        uint256 secondDepositWrapped,
        uint256 rate
    ) internal {
        // Ensure we're adding more than the minimum, or it will revert.
        vm.assume(firstDepositUnderlying + waDAI.convertToAssets(firstDepositWrapped) >= BUFFER_MINIMUM_TOTAL_SUPPLY);

        vm.prank(lp);
        uint256 firstAddLpShares = router.initializeBuffer(waDAI, firstDepositUnderlying, firstDepositWrapped);
        assertEq(
            firstAddLpShares,
            firstDepositUnderlying + waDAI.convertToAssets(firstDepositWrapped) - BUFFER_MINIMUM_TOTAL_SUPPLY,
            "Wrong first lpShares added"
        );

        // Change the rate after initialization.
        waDAI.mockRate(rate);

        // Compute the invariant after initialization, and before the second add operation.
        (uint256 bufferUnderlyingBalance, uint256 bufferWrappedBalance) = vault.getBufferBalance(waDAI);
        uint256 invariantBefore = bufferUnderlyingBalance + waDAI.convertToAssets(bufferWrappedBalance);

        // Make the second deposit, at the modified rate.
        vm.prank(lp);
        uint256 secondAddLpShares = router.addLiquidityToBuffer(waDAI, secondDepositUnderlying, secondDepositWrapped);

        // Burn the shares from the second deposit
        vm.prank(lp);
        vault.removeLiquidityFromBuffer(waDAI, secondAddLpShares);

        // Compute the invariant after the add/remove. Should be >= `invariantBefore`
        (bufferUnderlyingBalance, bufferWrappedBalance) = vault.getBufferBalance(waDAI);
        uint256 invariantAfter = bufferUnderlyingBalance + waDAI.convertToAssets(bufferWrappedBalance);

        assertGe(invariantAfter, invariantBefore, "Invariant went down after add/remove");
    }

    function testRemoveLiquidityFromBuffer() public {
        uint256 underlyingAmountIn = _wrapAmount;
        uint256 wrappedAmountIn = _wrapAmount.mulDown(2e18);

        vm.prank(lp);
        uint256 lpShares = router.initializeBuffer(waDAI, underlyingAmountIn, wrappedAmountIn);

        BufferAndLPBalances memory beforeBalances = _measureBuffer();

        vm.expectEmit();
        emit IVaultEvents.BufferSharesBurned(IERC4626(waDAI), lp, lpShares);

        vm.prank(lp);
        (uint256 underlyingRemoved, uint256 wrappedRemoved) = vault.removeLiquidityFromBuffer(waDAI, lpShares);

        // The underlying and wrapped removed are not exactly the same as amountsIn, because part of the first deposit
        // is kept to not deplete the buffer and these shares (POOL_MINIMUM_TOTAL_SUPPLY) are "burned". The remove liquidity operation
        // is proportional to buffer balances, so the amount of burned shares must be discounted proportionally from
        // underlying and wrapped.
        uint256 bufferInvariant = underlyingAmountIn + waDAI.convertToAssets(wrappedAmountIn);
        assertEq(
            underlyingRemoved,
            underlyingAmountIn - BUFFER_MINIMUM_TOTAL_SUPPLY.mulUp(underlyingAmountIn).divUp(bufferInvariant),
            "Underlying removed is wrong"
        );
        assertEq(
            wrappedRemoved,
            wrappedAmountIn - BUFFER_MINIMUM_TOTAL_SUPPLY.mulUp(wrappedAmountIn).divUp(bufferInvariant),
            "Wrapped removed is wrong"
        );

        BufferAndLPBalances memory afterBalances = _measureBuffer();

        assertEq(
            afterBalances.buffer.dai,
            beforeBalances.buffer.dai - underlyingRemoved,
            "Buffer DAI balance is wrong"
        );
        assertEq(
            afterBalances.buffer.waDai,
            beforeBalances.buffer.waDai - wrappedRemoved,
            "Buffer waDAI balance is wrong"
        );

        assertEq(afterBalances.vault.dai, beforeBalances.vault.dai - underlyingRemoved, "Vault DAI balance is wrong");
        assertEq(
            afterBalances.vault.waDai,
            beforeBalances.vault.waDai - wrappedRemoved,
            "Vault waDAI balance is wrong"
        );

        assertEq(
            afterBalances.vaultReserves.dai,
            beforeBalances.vaultReserves.dai - underlyingRemoved,
            "Vault Reserve DAI balance is wrong"
        );
        assertEq(
            afterBalances.vaultReserves.waDai,
            beforeBalances.vaultReserves.waDai - wrappedRemoved,
            "Vault Reserve waDAI balance is wrong"
        );

        assertEq(afterBalances.lp.dai, beforeBalances.lp.dai + underlyingRemoved, "LP DAI balance is wrong");
        assertEq(afterBalances.lp.waDai, beforeBalances.lp.waDai + wrappedRemoved, "LP waDAI balance is wrong");

        assertEq(vault.getBufferOwnerShares(IERC4626(address(waDAI)), lp), 0, "LP Buffer shares is wrong");
        // If math has rounding issues, the rounding occurs in favor of the vault
        // (invariantDelta <= lpShares <= invariantDelta + 2).
        uint256 bufferInvariantDelta = underlyingRemoved + waDAI.convertToAssets(wrappedRemoved);
        assertApproxEqAbs(lpShares, bufferInvariantDelta + 1, 1, "Removed assets are wrong");
    }

    struct BufferTokenBalances {
        uint256 waDai;
        uint256 dai;
    }

    struct BufferAndLPBalances {
        BufferTokenBalances lp;
        BufferTokenBalances buffer;
        BufferTokenBalances vault;
        BufferTokenBalances vaultReserves;
    }

    function _measureBuffer() private view returns (BufferAndLPBalances memory vars) {
        vars.lp.dai = dai.balanceOf(lp);
        vars.lp.waDai = waDAI.balanceOf(lp);

        (vars.buffer.dai, vars.buffer.waDai) = vault.getBufferBalance(IERC4626(address(waDAI)));

        vars.vault.dai = dai.balanceOf(address(vault));
        vars.vault.waDai = waDAI.balanceOf(address(vault));

        vars.vaultReserves.dai = vault.getReservesOf(dai);
        vars.vaultReserves.waDai = vault.getReservesOf(IERC20(address(waDAI)));
    }

    function _exactInWrapUnwrapPath(
        uint256 exactAmountIn,
        uint256 minAmountOut,
        IERC20 tokenFrom,
        IERC20 tokenTo,
        IERC20 wrappedToken
    ) private pure returns (IBatchRouter.SwapPathExactAmountIn[] memory paths) {
        IBatchRouter.SwapPathStep[] memory steps = new IBatchRouter.SwapPathStep[](1);
        paths = new IBatchRouter.SwapPathExactAmountIn[](1);

        steps[0] = IBatchRouter.SwapPathStep({ pool: address(wrappedToken), tokenOut: tokenTo, isBuffer: true });

        paths[0] = IBatchRouter.SwapPathExactAmountIn({
            tokenIn: tokenFrom,
            steps: steps,
            exactAmountIn: exactAmountIn,
            minAmountOut: minAmountOut
        });
    }

    function _exactOutWrapUnwrapPath(
        uint256 maxAmountIn,
        uint256 exactAmountOut,
        IERC20 tokenFrom,
        IERC20 tokenTo,
        IERC20 wrappedToken
    ) private pure returns (IBatchRouter.SwapPathExactAmountOut[] memory paths) {
        IBatchRouter.SwapPathStep[] memory steps = new IBatchRouter.SwapPathStep[](1);
        paths = new IBatchRouter.SwapPathExactAmountOut[](1);

        steps[0] = IBatchRouter.SwapPathStep({ pool: address(wrappedToken), tokenOut: tokenTo, isBuffer: true });

        paths[0] = IBatchRouter.SwapPathExactAmountOut({
            tokenIn: tokenFrom,
            steps: steps,
            maxAmountIn: maxAmountIn,
            exactAmountOut: exactAmountOut
        });
    }

    function _checkWrapResults(
        BaseVaultTest.Balances memory balancesBefore,
        uint256 amountIn,
        uint256 amountOut,
        SwapKind kind,
        bool withBufferLiquidity
    ) private view {
        (uint256 daiIdx, uint256 waDaiIdx, IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesAfter = getBalances(lp, tokens);

        // Check wrap results.
        // For wrap exact out, when the buffer has enough liquidity to fulfill the operation, amountIn increases by
        // conversion factor. Depending on the token rate, the value may change a bit, but it's important that amountIn
        // is bigger than _wrapAmount to make sure the buffer is not drained.
        uint256 convertFactorExactOut = withBufferLiquidity && kind == SwapKind.EXACT_OUT ? vaultConvertFactor : 1;
        assertApproxEqAbs(
            amountIn,
            _wrapAmount + convertFactorExactOut,
            convertFactorExactOut,
            "AmountIn (underlying deposited) is wrong"
        );
        assertApproxEqAbs(
            balancesAfter.lpTokens[daiIdx],
            balancesBefore.lpTokens[daiIdx] - _wrapAmount - convertFactorExactOut,
            convertFactorExactOut,
            "LP balance of underlying token is wrong"
        );
        // For wrap exact out, when the buffer has enough liquidity to fulfill the operation, amountOut decreases by
        // conversion factor. Depending on the token rate, the value may change a bit, but it's important that
        // amountOut is smaller than `waDAI.previewDeposit(_wrapAmount)` to make sure the buffer is not drained.
        uint256 convertFactorExactIn = withBufferLiquidity && kind == SwapKind.EXACT_IN ? vaultConvertFactor : 1;
        uint256 expectedAmountOut = waDAI.previewDeposit(_wrapAmount) - convertFactorExactIn;
        assertApproxEqAbs(amountOut, expectedAmountOut, convertFactorExactIn, "AmountOut (wrapped minted) is wrong");
        assertApproxEqAbs(
            balancesAfter.lpTokens[waDaiIdx],
            balancesBefore.lpTokens[waDaiIdx] + expectedAmountOut,
            convertFactorExactIn,
            "LP balance of wrapped token is wrong"
        );

        // Check Vault reserves. If the wrap operation used the buffer liquidity, the vault reserves should change to
        // reflect more underlying and less wrapped. Else, vault balances should not change.
        assertEq(
            balancesAfter.vaultReserves[daiIdx],
            balancesBefore.vaultReserves[daiIdx] + (withBufferLiquidity ? amountIn : 0),
            "Vault reserves of underlying token is wrong"
        );
        assertEq(
            balancesAfter.vaultReserves[waDaiIdx],
            balancesBefore.vaultReserves[waDaiIdx] - (withBufferLiquidity ? amountOut : 0),
            "Vault reserves of wrapped token is wrong"
        );

        // Check that Vault balances match vault reserves.
        assertEq(
            balancesAfter.vaultReserves[daiIdx],
            balancesAfter.vaultTokens[daiIdx],
            "Vault balance of underlying token is wrong"
        );
        assertEq(
            balancesAfter.vaultReserves[waDaiIdx],
            balancesAfter.vaultTokens[waDaiIdx],
            "Vault balance of wrapped token is wrong"
        );
    }

    function _checkUnwrapResults(
        BaseVaultTest.Balances memory balancesBefore,
        uint256 amountIn,
        uint256 amountOut,
        SwapKind kind,
        bool withBufferLiquidity
    ) private view {
        (uint256 daiIdx, uint256 waDaiIdx, IERC20[] memory tokens) = _getTokenArrayAndIndexesOfWaDaiBuffer();
        BaseVaultTest.Balances memory balancesAfter = getBalances(lp, tokens);

        // Check unwrap results.
        // For unwrap exact out, when the buffer has enough liquidity to fulfill the operation, amountIn increases by
        // conversion factor. Depending on the token rate, the value may change a bit, but it's important that
        // amountIn is bigger than `waDAI.previewDeposit(_wrapAmount)` to make sure the buffer is not drained.
        uint256 convertFactorExactOut = withBufferLiquidity && kind == SwapKind.EXACT_OUT ? vaultConvertFactor : 1;
        uint256 expectedAmountIn = waDAI.previewDeposit(_wrapAmount) + convertFactorExactOut;
        assertApproxEqAbs(amountIn, expectedAmountIn, convertFactorExactOut, "AmountIn (wrapped burned) is wrong");
        assertApproxEqAbs(
            balancesAfter.lpTokens[waDaiIdx],
            balancesBefore.lpTokens[waDaiIdx] - expectedAmountIn,
            convertFactorExactOut,
            "LP balance of wrapped token is wrong"
        );
        // For unwrap exact in, when the buffer has enough liquidity to fulfill the operation, amountOut decreases by
        // conversion factor. Depending on the token rate, the value may change a bit, but it's important that
        // amountOut is smaller than _wrapAmount to make sure the buffer is not drained.
        uint256 convertFactorExactIn = withBufferLiquidity && kind == SwapKind.EXACT_IN ? vaultConvertFactor : 1;
        uint256 expectedAmountOut = _wrapAmount - convertFactorExactIn;
        assertApproxEqAbs(
            amountOut,
            expectedAmountOut,
            convertFactorExactIn,
            "AmountOut (underlying withdrawn) is wrong"
        );
        assertApproxEqAbs(
            balancesAfter.lpTokens[daiIdx],
            balancesBefore.lpTokens[daiIdx] + expectedAmountOut,
            convertFactorExactIn,
            "LP balance of underlying token is wrong"
        );

        // Check Vault reserves. If the unwrap operation used the buffer liquidity, the vault reserves should change to
        // reflect more wrapped and less underlying. Else, vault balances should not change.
        assertEq(
            balancesAfter.vaultReserves[waDaiIdx],
            balancesBefore.vaultReserves[waDaiIdx] + (withBufferLiquidity ? amountIn : 0),
            "Vault reserves of wrapped token is wrong"
        );
        assertEq(
            balancesAfter.vaultReserves[daiIdx],
            balancesBefore.vaultReserves[daiIdx] - (withBufferLiquidity ? amountOut : 0),
            "Vault reserves of underlying token is wrong"
        );

        // Check that Vault balances match vault reserves.
        assertEq(
            balancesAfter.vaultReserves[daiIdx],
            balancesAfter.vaultTokens[daiIdx],
            "Vault balance of underlying token is wrong"
        );
        assertEq(
            balancesAfter.vaultReserves[waDaiIdx],
            balancesAfter.vaultTokens[waDaiIdx],
            "Vault balance of wrapped token is wrong"
        );
    }

    function _getTokenArrayAndIndexesOfWaDaiBuffer()
        private
        view
        returns (uint256 daiIdx, uint256 waDaiIdx, IERC20[] memory tokens)
    {
        (daiIdx, waDaiIdx) = getSortedIndexes(address(dai), address(waDAI));
        tokens = new IERC20[](2);
        tokens[daiIdx] = dai;
        tokens[waDaiIdx] = IERC20(address(waDAI));
    }

    /// @notice Hook used to create a vault approval using a malicious erc4626 and drain the vault.
    function erc4626MaliciousHook(BufferWrapOrUnwrapParams memory params) external {
        (, uint256 amountIn, uint256 amountOut) = vault.erc4626BufferWrapOrUnwrap(params);
        if (params.kind == SwapKind.EXACT_OUT) {
            // When the wrap is EXACT_OUT, a minimum amount of tokens must be wrapped. so, balances need to be settled
            // at the end to not revert the transaction and keep an approval to remove underlying tokens from the
            // vault.
            dai.mint(address(this), amountIn);
            dai.transfer(address(vault), amountIn);
            vault.settle(dai, amountIn);
            vault.sendTo(IERC20(address(waDAI)), address(this), amountOut);
        }
    }
}
