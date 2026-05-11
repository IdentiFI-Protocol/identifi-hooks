// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol"; 
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IdentiFI Hook
 * @notice Sovereign Proof Validator using IMsgSender and Transient Storage for Uniswap v4 swaps.
 * @dev Implements ECDSA signature validation (hookData) to authenticate the original transaction sender.
 */
contract IdentiFIHook is IHooks, Ownable {
    IPoolManager public immutable poolManager;

    error InvalidSignature();
    error InvalidHookData();

    error ReplayAttack();
    error NotPoolManager();
    error RouterNotSupported();
    error UntrustedRouter();

    address public immutable IDENTIFI_SIGNER;
    /// @notice Maps user addresses to their last used nonce to prevent replay attacks.
    mapping(address => uint256) public lastUserNonce;

    /// @notice Whitelist of routers allowed to propagate identity.
    mapping(address => bool) public isTrustedRouter;

    /// @notice Expected length of hookData (4 slots of 32 bytes each = 128 bytes).
    uint256 public constant HOOK_DATA_LENGTH = 128;  

    event LogSetTrustedRouter(address indexed router, bool status);

    /**
          * @param _poolManager The Uniswap v4 Pool Manager address.
     * @param _identiFiSigner The authorized ECDSA signer for the IdentiFI protocol.
     */
    constructor(IPoolManager _poolManager, address _identiFiSigner) Ownable(msg.sender) {
        poolManager = _poolManager;
        IDENTIFI_SIGNER = _identiFiSigner;
    }

    /**
     * @notice Updates the trust status of a router.
          * @param router The address of the router.
     * @param status True to trust, false to revoke.
     */
    function setTrustedRouter(address router, bool status) external onlyOwner {
        isTrustedRouter[router] = status;
        emit LogSetTrustedRouter(router, status);
    }


    /**
     * @notice Returns the hook permissions required for Uniswap v4.
     * @dev This hook only requires the `beforeSwap` flag.
     * @return Permissions struct indicating which callbacks are enabled.
     */
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, 
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Callback executed before a swap occurs in a pool managed by this hook.
     * @dev Validates the `hookData` signature against the actual user address stored in the caller (router).
     * @param sender The address initiating the swap (expected to be a router implementing IMsgSender).
     * @param hookData Encoded proof containing nonce and ECDSA signature.
     * @return selector The function selector for beforeSwap.
     * @return delta The delta to be applied (zero in this implementation).
     * @return fee The swap fee (zero/default in this implementation).
     */
    function beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (hookData.length != HOOK_DATA_LENGTH) revert InvalidHookData();

        // 0. Verify the router is trusted before interacting with it.
        if (!isTrustedRouter[sender]) revert UntrustedRouter();

        // 1. Retrieve the real user identity via IMsgSender from the Router.
        // Reverts if the router does not implement the interface or has no stored identity.
        address user;
        try IMsgSender(sender).msgSender() returns (address _user) {
            user = _user;
        } catch {
            revert RouterNotSupported();
        }

        // 2. Decode the proof components (Nonce + Signature R, S, V).
        (uint256 proofNonce, bytes32 r, bytes32 s, uint8 v) = _decodeHookData(hookData);

        // 3. Prevent Replay Attacks by ensuring nonces are strictly increasing for the real user.
        if (proofNonce <= lastUserNonce[user]) revert ReplayAttack();

        // 4. Validate ECDSA Signature: The proof must be signed by IDENTIFI_SIGNER and bound to this user.
        if (!_isValidSignature(user, proofNonce, r, s, v)) revert InvalidSignature();

        // 5. Update the user's nonce to invalidate this proof for future swaps.
        lastUserNonce[user] = proofNonce;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Helper function for external validation (Off-chain or Tests).
     * @param user The address of the user to validate.
     * @param hookData The proof data to verify.
     * @return True if the signature is valid for the given user.
     */
    function validateHookData(address user, bytes calldata hookData) external view returns (bool) {
        if (hookData.length != HOOK_DATA_LENGTH) return false;
        (uint256 proofNonce, bytes32 r, bytes32 s, uint8 v) = _decodeHookData(hookData);
        if (proofNonce <= lastUserNonce[user]) return false;
        return _isValidSignature(user, proofNonce, r, s, v);
    }

    /// @dev Internal function to extract signature components using assembly for gas efficiency.
    function _decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (uint256 proofNonce, bytes32 r, bytes32 s, uint8 v)
    {
        assembly {
            let ptr := hookData.offset
            proofNonce := calldataload(ptr)          // Slot 0 (0-31): Nonce
            r := calldataload(add(ptr, 32))         // Slot 1 (32-63): R
            s := calldataload(add(ptr, 64))         // Slot 2 (64-95): S
            v := byte(0, calldataload(add(ptr, 96))) // Slot 3 (96-127): V (first byte)
        }
        
        // Protection against Signature Malleability (s must be in the lower half of the curve).
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
    }

    /// @dev Reconstructs the EIP-191 message and recovers the signer.
    function _isValidSignature(
        address user,
        uint256 proofNonce,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal view returns (bool) {
        // Hash includes user address and nonce, binding the proof to a specific wallet and state.
        bytes32 messageHash = keccak256(abi.encodePacked(user, proofNonce));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        address recovered = ecrecover(ethSignedMessageHash, v, r, s);
        return recovered == IDENTIFI_SIGNER;
    }

    // --- Mandatory v4 Hook Stubs ---

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) { return IHooks.beforeInitialize.selector; }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) { return IHooks.afterInitialize.selector; }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) { return IHooks.beforeAddLiquidity.selector; }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) { return IHooks.beforeRemoveLiquidity.selector; }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, int128) { return (IHooks.afterSwap.selector, 0); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { return IHooks.beforeDonate.selector; }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { return IHooks.afterDonate.selector; }
    
    function unlockCallback(bytes calldata data) external view returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return data;
    }
}