// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IProtocolFeeController } from "../vault/IProtocolFeeController.sol";
import { IProtocolFeeBurner } from "./IProtocolFeeBurner.sol";

interface IProtocolFeeSweeper {
    /**
     * @notice Emitted when the target token is updated.
     * @param token The preferred token for receiving protocol fees
     */
    event TargetTokenSet(IERC20 indexed token);

    /**
     * @notice Emitted when the fee recipient address is verified.
     * @param feeRecipient The final destination of collected protocol fees
     */
    event FeeRecipientSet(address indexed feeRecipient);

    /**
     * @notice Emitted when governance has set the protocol fee burner contract.
     * @param protocolFeeBurner The contract used to "burn" protocol fees (i.e., convert them to the target token)
     */
    event ProtocolFeeBurnerSet(address indexed protocolFeeBurner);

    /**
     * @notice Emitted when a fee token is transferred directly.
     * @dev This can happen if no target token or burner contract was specified, or the fee token is the target token.
     * @param pool The pool the fee was collected on
     * @param feeToken The token the fee was collected in (also the target token in this case; no swap necessary)
     * @param feeTokenAmount The number of feeTokens
     * @param recipient The recipient of the target tokens
     */
    event ProtocolFeeSwept(address indexed pool, IERC20 indexed feeToken, uint256 feeTokenAmount, address recipient);

    /**
     * @notice Withdraw, convert, and forward protocol fees for a given pool.
     * @dev This will withdraw all fee tokens to this contract, and attempt to convert and forward them. There is also
     * a single token pool withdrawal, but that is an edge case not in scope for the sweeper.
     *
     * @param pool The pool from which we're withdrawing fees
     */
    function sweepProtocolFees(address pool) external;

    /**
     * @notice Return the address of the current `ProtocolFeeController` from the Vault.
     * @dev It is not immutable in the Vault, so we need to get it every time.
     * @return protocolFeeController The address of the current `ProtocolFeeController`
     */
    function getProtocolFeeController() external view returns (IProtocolFeeController);

    /**
     * @notice Getter for the target token.
     * @dev This is the token the burner will swap all fee tokens for.
     * @return targetToken The current target token
     */
    function getTargetToken() external view returns (IERC20);

    /**
     * @notice Getter for the current fee recipient.
     * @return feeRecipient The currently active fee recipient
     */
    function getFeeRecipient() external view returns (address);

    /**
     * @notice Getter for the current protocol fee burner.
     * @return protocolFeeBurner The currently active protocol fee burner
     */
    function getProtocolFeeBurner() external view returns (IProtocolFeeBurner);

    /**
     * @notice Update the fee recipient address.
     * @dev This is a permissioned function.
     * @param feeRecipient The address of the new fee recipient
     */
    function setFeeRecipient(address feeRecipient) external;

    /**
     * @notice Set a protocol fee burner, used to convert protocol fees to a target token.
     * @dev This is a permissioned function. If it is not set, the contract will fall back to forwarding the fee tokens
     * directly to the fee recipient.
     *
     * @param protocolFeeBurner The address of the current protocol fee burner
     */
    function setProtocolFeeBurner(IProtocolFeeBurner protocolFeeBurner) external;

    /**
     * @notice Update the address of the target token.
     * @dev This is the token the burner will attempt to swap all collected fee tokens to.
     * @param targetToken The address of the target token
     */
    function setTargetToken(IERC20 targetToken) external;

    /**
     * @notice Retrieve any tokens "stuck" in this contract (e.g., dust, or failed conversions).
     * @dev It will recover the full balance of all the tokens. This can only be called by the `feeRecipient`.
     * @param feeTokens The tokens to recover
     */
    function recoverProtocolFees(IERC20[] memory feeTokens) external;
}
