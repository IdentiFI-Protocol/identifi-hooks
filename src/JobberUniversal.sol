// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/**
 * @title Jobber Universal Router
 * @notice Handles swap settlements and identity propagation for IdentiFI hooks via Transient Storage.
 * @dev Implements IMsgSender to allow hooks to retrieve the original caller during the swap execution.
 */
contract JobberUniversal is IUnlockCallback, IMsgSender {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;
    /// @dev Slot for storing the original msg.sender in Transient Storage.
    bytes32 private constant MSG_SENDER_SLOT = keccak256("IDFI_MSG_SENDER");

    IPoolManager public immutable manager;
    address public owner;
    uint24 public feePPM = 660; 

    event FeeUpdated(uint24 newFee);
    event OwnerUpdated(address indexed newOwner);

    error TooLittleOut();
    error CallerNotManager();
    error InsufficientValue();

    struct CallbackData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        uint256 netAmountIn;
        uint256 minAmountOut;
        bytes hookData;
    }

    constructor(address _manager) {
        manager = IPoolManager(_manager);
        owner = msg.sender;
    }

    function setFee(uint24 _feePPM) external {
        if (msg.sender != owner) revert("Not owner");
        feePPM = _feePPM;
        emit FeeUpdated(_feePPM);
    }

    function setOwner(address _owner) external {
        if (msg.sender != owner) revert("Not owner");
        owner = _owner;
        emit OwnerUpdated(_owner);
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
    bool zeroForOne,
    uint256 minAmountOut,
    bytes calldata hookData
) external payable returns (BalanceDelta delta) {
    uint256 fee = (amountIn * feePPM) / PIPS_DENOMINATOR;
    uint256 netAmountIn = amountIn - fee;

    Currency input = zeroForOne ? key.currency0 : key.currency1;

    if (Currency.unwrap(input) == address(0)) {
        if (msg.value < amountIn) revert InsufficientValue();
        if (fee > 0) {
            (bool success, ) = payable(owner).call{value: fee}("");
            if (!success) revert("Fee transfer failed");
        }
    } else {
        if (fee > 0) IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, owner, fee);
        IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), netAmountIn);
        IERC20(Currency.unwrap(input)).approve(address(manager), netAmountIn);
    }

    delta = abi.decode(
        manager.unlock(abi.encode(CallbackData({
            sender: msg.sender,
            key: key,
            zeroForOne: zeroForOne,
            netAmountIn: netAmountIn,
            minAmountOut: minAmountOut,
            hookData: hookData

        }))),
        (BalanceDelta)
    );

    // --- (REFUNDS) ---    
    // 1. ETH refund (Remaining msg.value if Native or residual balance)
    uint256 ethBalance = address(this).balance;
    if (ethBalance > 0) {
        (bool success, ) = payable(msg.sender).call{value: ethBalance}("");
        if (!success) revert("Refund failed");
    }

    // 2. Token Refund (If there is any remaining netAmountIn in the case of ERC20)
    if (Currency.unwrap(input) != address(0)) {
        uint256 tokenBalance = IERC20(Currency.unwrap(input)).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(Currency.unwrap(input)).safeTransfer(msg.sender, tokenBalance);
        }
    }
}
    /**
     * @notice Uniswap v4 unlock callback. Sets up transient identity and executes the swap.
     * @param rawData Encoded CallbackData struct.
     */
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
    if (msg.sender != address(manager)) revert CallerNotManager();
    CallbackData memory data = abi.decode(rawData, (CallbackData));

    // 1. Configure the identity in Transient Storage (IdentiFI Logic)
    bytes32 slot = MSG_SENDER_SLOT;
    address user = data.sender;
    assembly {
        tstore(slot, user)
    }

        BalanceDelta delta = manager.swap(
        data.key,
        SwapParams({
            zeroForOne: data.zeroForOne,
            amountSpecified: -int256(data.netAmountIn),
            sqrtPriceLimitX96: data.zeroForOne 
                ? TickMath.MIN_SQRT_PRICE + 1 
                : TickMath.MAX_SQRT_PRICE - 1
        }),
        data.hookData
    );

    (Currency input, Currency output) = data.zeroForOne 
        ? (data.key.currency0, data.key.currency1) 
        : (data.key.currency1, data.key.currency0);

    int128 amountInputDelta = data.zeroForOne ? delta.amount0() : delta.amount1();
    int128 amountOutputDelta = data.zeroForOne ? delta.amount1() : delta.amount0();

    if (amountInputDelta < 0) {
        uint256 amountToSettle = uint256(int256(-amountInputDelta));
        input.settle(manager, address(this), amountToSettle, false);
    }

    if (amountOutputDelta > 0) {
        uint256 amountOut = uint256(int256(amountOutputDelta));
        if (amountOut < data.minAmountOut) revert TooLittleOut();
        output.take(manager, data.sender, amountOut, false);
    }

    // Security: Clears the transient identity
    assembly { tstore(slot, 0) }

    return abi.encode(delta);
}


    receive() external payable {}
}
