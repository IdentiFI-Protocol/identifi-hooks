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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title IIdentiFITreasury
 * @notice Interface for the IdentiFI Treasury acting as a Unified Revenue Bucket.
 */
interface IIdentiFITreasury {
    /**
     * @notice Deposits fees into the global revenue pool.
     * @param token Address of the token being deposited (address(0) for ETH).
     * @param amount The amount of fees to deposit.
     * @param user The user who generated the volume.
     * @param lp The LP provider associated with the swap (if any).
     */
    function deposit(
        address token,
        uint256 amount,
        address user,
        address lp
    ) external payable;
}

/**
 * @title Jobber Universal Router
 * @notice Acts as a middleware for Uniswap v4 swaps, handling fee collection and identity propagation.
 * @dev This contract implements IMsgSender to allow Hooks to identify the original caller via transient storage.
 * @dev It routes collected fees either to a unified Treasury contract or directly to the owner.
 */
contract JobberUniversal is IUnlockCallback, IMsgSender {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Denominator for fee calculation in PPM (Parts Per Million).
    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;
    
    /// @notice Transient storage slot for the original msg.sender.
    bytes32 private constant MSG_SENDER_SLOT = keccak256("IDFI_MSG_SENDER");
    
    /// @notice Transient storage slot to flag that identity has been set.
    bytes32 private constant IDENTITY_SET_SLOT = keccak256("IDFI_IDENTITY_SET");

    error TooLittleOut();
    error CallerNotManager();
    error InsufficientValue();
    error FeeTransferFailed();
    error TokenTransferFailed();
    error OwnershipError();
    error InvalidOwner();
    error InvalidFee();
    error InvalidTreasuryAddress();

    /// @notice Uniswap v4 Pool Manager address.
    IPoolManager public immutable manager;
    
    /// @notice Current owner of the Jobber router.
    address public owner;
    
    /// @notice Protocol fee in PPM (e.g., 660 = 0.066%).
    uint24 public feePPM = 660;
    
    /// @notice Address of the unified treasury for revenue distribution.
    IIdentiFITreasury public treasury;
    
    /// @notice Toggle to route fees to the treasury instead of the owner.
    bool public treasuryEnabled = false;

    event FeeUpdated(uint24 newFee);
    event OwnerUpdated(address indexed newOwner);
    event SwapExecuted(address indexed user, address indexed inputToken, address indexed outputToken, uint256 amountIn, uint256 amountOut);
    event FeeCollected(address indexed inputToken, uint256 amount);
    event FeeRoutedToTreasury(address indexed token, uint256 amount, address indexed user);
    event EmergencyWithdraw(address indexed token, address indexed recipient, uint256 amount);
    event TreasurySet(address indexed newTreasury);

    /**
     * @notice Data passed to the unlock callback for swap execution.
     */
    struct CallbackData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        uint256 netAmountIn;
        uint256 minAmountOut;
        bytes hookData;
    }

    constructor(address _manager) {
        if (_manager == address(0)) revert InvalidOwner();
        manager = IPoolManager(_manager);
        owner = msg.sender;
    }

    /**
     * @notice Updates the protocol fee in PPM.
     * @param _feePPM New fee (max 100,000).
     */
    function setFee(uint24 _feePPM) external {
        if (msg.sender != owner) revert OwnershipError();
        if (_feePPM > 100_000) revert InvalidFee();
        feePPM = _feePPM;
        emit FeeUpdated(_feePPM);
    }

    /**
     * @notice Transfers ownership of the Jobber router.
     * @param _owner New owner address.
     */
    function setOwner(address _owner) external {
        if (msg.sender != owner) revert OwnershipError();
        if (_owner == address(0)) revert InvalidOwner();
        owner = _owner;
        emit OwnerUpdated(_owner);
    }

    /**
     * @notice Configures the Treasury contract and enables fee routing.
     * @param _treasury Address of the IdentiFITreasury contract.
     */
    function setTreasury(address _treasury) external {
        if (msg.sender != owner) revert OwnershipError();
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        treasury = IIdentiFITreasury(_treasury);
        treasuryEnabled = true;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Disables fee routing to the treasury, reverting to owner direct payments.
     */
    function disableTreasury() external {
        if (msg.sender != owner) revert OwnershipError();
        treasuryEnabled = false;
    }

    /**
     * @notice Allows the owner to recover tokens trapped in the contract.
     * @param token The token to withdraw (address(0) for ETH).
     * @param amount The amount to withdraw.
     */
    function emergencyWithdraw(address token, uint256 amount) external {
        if (msg.sender != owner) revert OwnershipError();
        if (token == address(0)) {
            (bool success, ) = payable(owner).call{value: amount}("");
            if (!success) revert FeeTransferFailed();
        } else {
            bool success = IERC20(token).transfer(owner, amount);
            if (!success) revert TokenTransferFailed();
        }
        emit EmergencyWithdraw(token, owner, amount);
    }

    /**
     * @notice Returns the original sender stored in transient storage.
     * @return The address of the user who initiated the swap.
     */
    function msgSender() external view returns (address) {
        address stored;
        bytes32 slot = MSG_SENDER_SLOT;
        assembly { stored := tload(slot) }
        return stored;
    }

    /**
     * @notice Entry point for swaps. Calculates fees and unlocks the pool.
     * @param key Pool key.
     * @param amountIn Total input amount.
     * @param zeroForOne True if swapping token0 for token1.
     * @param minAmountOut Minimum expected output.
     * @param hookData Opaque data for Hook validation.
     * @return delta The final balance delta from the swap.
     */
    function settlement(
        PoolKey calldata key,
        uint256 amountIn,
        bool zeroForOne,
        uint256 minAmountOut,
        bytes calldata hookData
    ) external payable returns (BalanceDelta delta) {
        return _settlementInternal(key, amountIn, zeroForOne, minAmountOut, hookData, address(0));
    }

    /**
     * @notice Entry point for swaps including a specific validator address.
     * @param validator The address of the validator to be recorded in the Treasury.
     */
    function settlementWithValidator(
        PoolKey calldata key,
        uint256 amountIn,
        bool zeroForOne,
        uint256 minAmountOut,
        bytes calldata hookData,
        address validator
    ) external payable returns (BalanceDelta delta) {
        return _settlementInternal(key, amountIn, zeroForOne, minAmountOut, hookData, validator);
    }

    /**
     * @dev Internal logic to process fees, handle token transfers and initiate the v4 unlock.
     */
    function _settlementInternal(
        PoolKey calldata key,
        uint256 amountIn,
        bool zeroForOne,
        uint256 minAmountOut,
        bytes calldata hookData,
        address validator
    ) internal returns (BalanceDelta delta) {
        bool success;
        uint256 fee = Math.mulDiv(amountIn, feePPM, PIPS_DENOMINATOR, Math.Rounding.Floor);
        uint256 netAmountIn = amountIn - fee;

        Currency input = zeroForOne ? key.currency0 : key.currency1;
        address inputToken = Currency.unwrap(input);

        if (inputToken == address(0)) {
            if (msg.value < amountIn) revert InsufficientValue();
            if (fee > 0) {
                if (treasuryEnabled && address(treasury) != address(0)) {
                    treasury.deposit{value: fee}(inputToken, fee, msg.sender, validator);
                    emit FeeRoutedToTreasury(inputToken, fee, msg.sender);
                } else {
                    (success, ) = payable(owner).call{value: fee}("");
                    if (!success) revert FeeTransferFailed();
                    emit FeeCollected(inputToken, fee);
                }
            }
        } else {
            if (fee > 0) {
                success = IERC20(inputToken).transferFrom(msg.sender, address(this), fee);
                if (!success) revert TokenTransferFailed();

                if (treasuryEnabled && address(treasury) != address(0)) {
                    IERC20(inputToken).approve(address(treasury), 0);
                    IERC20(inputToken).approve(address(treasury), fee);
                    treasury.deposit(inputToken, fee, msg.sender, validator);
                    emit FeeRoutedToTreasury(inputToken, fee, msg.sender);
                } else {
                    success = IERC20(inputToken).transfer(owner, fee);
                    if (!success) revert TokenTransferFailed();
                    emit FeeCollected(inputToken, fee);
                }
            }
            success = IERC20(inputToken).transferFrom(msg.sender, address(this), netAmountIn);
            if (!success) revert TokenTransferFailed();
            IERC20(inputToken).approve(address(manager), 0);
            IERC20(inputToken).approve(address(manager), netAmountIn);
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

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (success, ) = payable(msg.sender).call{value: ethBalance}("");
            if (!success) revert FeeTransferFailed();
        }

        if (inputToken != address(0)) {
            uint256 tokenBalance = IERC20(inputToken).balanceOf(address(this));
            if (tokenBalance > 0) {
                success = IERC20(inputToken).transfer(msg.sender, tokenBalance);
                if (!success) revert TokenTransferFailed();
            }
        }
    }

    /**
     * @notice Callback called by the PoolManager to execute the swap.
     * @dev Uses TSTORE to propagate the original user identity to Hooks.
     * @param rawData Encoded CallbackData.
     * @return The final balance delta of the swap.
     */
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        bytes32 msgSenderSlot = MSG_SENDER_SLOT;
        bytes32 identitySetSlot = IDENTITY_SET_SLOT;
        address user = data.sender;
        assembly {
            tstore(msgSenderSlot, user)
            tstore(identitySetSlot, 1)
        }
        BalanceDelta delta = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.netAmountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            data.hookData
        );
        (Currency input, Currency output) = data.zeroForOne ? (data.key.currency0, data.key.currency1) : (data.key.currency1, data.key.currency0);
        int128 amountInputDelta = data.zeroForOne ? delta.amount0() : delta.amount1();
        int128 amountOutputDelta = data.zeroForOne ? delta.amount1() : delta.amount0();
        assembly { 
            tstore(msgSenderSlot, 0)
            tstore(identitySetSlot, 0)
        }
        if (amountInputDelta < 0) {
            // casting to 'uint256' is safe because amountInputDelta is confirmed negative, so -amountInputDelta is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountToSettle = uint256(int256(-amountInputDelta));
            input.settle(manager, address(this), amountToSettle, false);
        }
        if (amountOutputDelta > 0) {
            // casting to 'uint256' is safe because amountOutputDelta is confirmed positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountOut = uint256(int256(amountOutputDelta));
            if (amountOut < data.minAmountOut) revert TooLittleOut();
            output.take(manager, data.sender, amountOut, false);
            emit SwapExecuted(data.sender, Currency.unwrap(input), Currency.unwrap(output), data.netAmountIn, amountOut);
        }
        return abi.encode(delta);
    }

    receive() external payable {}
}
