// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/**
 * @title Jobber Universal Router
 * @notice Handles swap settlements and identity propagation for IdentiFI hooks via Transient Storage.
 * @dev Implements IMsgSender to allow hooks to retrieve the original caller during the swap execution.
 */
contract JobberUniversal is IUnlockCallback, IMsgSender {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;
    /// @dev Slot for storing the original msg.sender in Transient Storage.
    bytes32 private constant MSG_SENDER_SLOT = keccak256("IDFI_MSG_SENDER");

    IPoolManager public immutable manager;
    address public owner;
    uint24 public feePPM = 660; 

    error TooLittleOut();
    error CallerNotManager();
    error InsufficientValue();

    struct CallbackData {
        address sender;
        PoolKey key;
        uint256 netAmountIn;
        uint256 minAmountOut;
        bytes hookData;
    }

    constructor(address _manager) {
        manager = IPoolManager(_manager);
        owner = msg.sender;
    }

    /**
     * @notice Retrieves the identity of the original caller from Transient Storage.
     * @return stored The address of the original transaction sender.
     */
    function msgSender() external view returns (address) {
        address stored;
        bytes32 slot = MSG_SENDER_SLOT;
        assembly {
            stored := tload(slot)
        }
        return stored;
    }

    /**
     * @notice Main entry point for performing swaps with protocol fee handling.
     * @param key The pool key for the swap.
     * @param amountIn The amount of input token to swap.
     * @param minAmountOut The minimum amount of output token expected.
     * @param hookData Proof data required by the IdentiFI Hook.
     * @return delta The resulting balance delta from the swap.
     */
    function settlement(
        PoolKey calldata key,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata hookData
    ) external payable returns (BalanceDelta delta) {
        uint256 fee = (amountIn * feePPM) / PIPS_DENOMINATOR;
        uint256 netAmountIn = amountIn - fee;

        // Handle native ETH settlement vs ERC20 tokens.
        if (Currency.unwrap(key.currency0) == address(0)) {
            if (msg.value < amountIn) revert InsufficientValue();
            if (fee > 0) {
                (bool success, ) = payable(owner).call{value: fee}("");
                if (!success) revert("Fee transfer failed");
            }
        } else {
            if (fee > 0) {
                key.currency0.settle(manager, msg.sender, fee, false);
                key.currency0.take(manager, owner, fee, false);
            }
            key.currency0.settle(manager, msg.sender, netAmountIn, false);
        }

        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        sender: msg.sender,
                        key: key,
                        netAmountIn: netAmountIn,
                        minAmountOut: minAmountOut,
                        hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );

        // Refund remaining ETH back to the user if any is left in the contract.
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = payable(msg.sender).call{value: ethBalance}("");
            if (!success) revert("Refund failed");
        }
    }

    /**
     * @notice Uniswap v4 unlock callback. Sets up transient identity and executes the swap.
     * @param rawData Encoded CallbackData struct.
     */
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        bytes32 slot = MSG_SENDER_SLOT;
        address user = data.sender;
        assembly {
            tstore(slot, user)
        }

        BalanceDelta delta = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(data.netAmountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            data.hookData
        );

        if (uint256(int256(delta.amount1())) < data.minAmountOut) revert TooLittleOut();

        _settleBalances(data.sender, data.key, delta);

        return abi.encode(delta);
    }

    /// @dev Internal helper to settle currency balances with the Pool Manager.
    function _settleBalances(address sender, PoolKey memory key, BalanceDelta delta) internal {
        int256 delta0 = delta.amount0();
        if (delta0 < 0) {
            key.currency0.settle(manager, address(this), uint256(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(manager, sender, uint256(delta0), false);
        }

        int256 delta1 = delta.amount1();
        if (delta1 < 0) {
            key.currency1.settle(manager, address(this), uint256(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(manager, sender, uint256(delta1), false);
        }
    }

    receive() external payable {}
}