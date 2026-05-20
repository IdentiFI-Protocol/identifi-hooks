// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import { BeforeSwapDelta,BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams,ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IMsgSender} from "v4-periphery/interfaces/IMsgSender.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IdentiFI Hook
 * @notice Sovereign Proof Validator using IMsgSender and Transient Storage for Uniswap v4 swaps.
 * @dev Implements ECDSA signature validation (hookData) to authenticate the original transaction sender.
 * @dev CRITICAL: Hook is the ONLY component that validates proofs. All other components are proof-agnostic.
 */
contract IdentiFIHook is IHooks, Ownable, Pausable, ReentrancyGuard {
    IPoolManager public immutable poolManager;

    // ============ Custom Errors ============
    error InvalidSignature();
    error InvalidHookData();
    error ReplayAttack();
    error NotPoolManager();
    error RouterNotSupported();
    error UntrustedRouter();
    error ProofExpired();
    error InvalidSignerAddress();
    error InvalidNonceValue();
    error ZeroUserAddress();

    // ============ State Variables ============
    address public constant IDENTIFI_SIGNER =
        0x7a4462add2847DA5063337Cbf60bD2796b7510eb;

    /// @notice Tracks executed signatures to prevent replay attacks.
    mapping(bytes32 => bool) public usedSignatures;

    /// @notice Whitelist of routers allowed to propagate identity.
    mapping(address => bool) public isTrustedRouter;

    /// @notice Expected length of hookData (5 slots of 32 bytes each = 160 bytes).
    uint256 public constant HOOK_DATA_LENGTH = 160;

    /// @notice Maximum nonce value to prevent overflow issues (2^64 - 1).
    uint256 public constant MAX_NONCE = type(uint64).max;

    /// @notice Minimum deadline buffer to ensure proof has reasonable lifespan (60 seconds).
    uint256 public constant MIN_DEADLINE_BUFFER = 60 seconds;

    // ============ Events ============
    event LogSetTrustedRouter(address indexed router, bool status);
    event ProofValidated(
        address indexed user,
        address indexed router,
        uint256 indexed nonce
    );
    event SignatureValidationFailed(
        address indexed user,
        address indexed router,
        string reason
    );

    /**
     * @notice Creates a owner of the IdentiFIHook.
     * @param _poolManager The Uniswap v4 Pool Manager address.
     */
    constructor(
        IPoolManager _poolManager
    ) Ownable(0x33b9B6498b1319B737efC4f5956Cb4611DAbb974) {
        poolManager = _poolManager;
    }

    /**
     * @notice Updates the trust status of a router.
     * @param router The address of the router.
     * @param status True to trust, false to revoke.
     */
    function setTrustedRouter(address router, bool status) external onlyOwner {
        if (router == address(0)) revert InvalidHookData();
        isTrustedRouter[router] = status;
        emit LogSetTrustedRouter(router, status);
    }

    /**
     * @notice Pauses the hook to prevent swaps during emergency.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes the hook after emergency pause.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Returns the hook permissions required for Uniswap v4.
     */
    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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
     * @dev CRITICAL: This is the ONLY place where hookData is validated.
     * @dev This function:
     *      1. Retrieves real user via IMsgSender (transient storage)
     *      2. Validates ECDSA proof against IDENTIFI_SIGNER
     *      3. Prevents replay attacks via nonce tracking
     *      4. Returns success → Swap proceeds → Jobber collects fees → Treasury records
     * @dev If validation fails, the entire swap reverts (security first)
     *
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
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (hookData.length != HOOK_DATA_LENGTH) revert InvalidHookData();

        // 0. Verify the router is trusted before interacting with it.
        if (!isTrustedRouter[sender]) revert UntrustedRouter();

        // 1. Retrieve the real user identity via IMsgSender from the Router.
        address user;
        try IMsgSender(sender).msgSender() returns (address _user) {
            if (_user == address(0)) revert ZeroUserAddress();
            user = _user;
        } catch {
            revert RouterNotSupported();
        }
        // 2. Decode the proof components (Nonce + Signature R, S, V + Deadline).
        (
            uint256 proofNonce,
            bytes32 r,
            bytes32 s,
            uint8 v,
            uint256 deadline
        ) = _decodeHookData(hookData);

        // 2.1 Validate deadline
        if (block.timestamp > deadline) {
            emit SignatureValidationFailed(user, sender, "ProofExpired");
            revert ProofExpired();
        }

        // 2.2 Validate nonce is within expected bounds
        if (proofNonce > MAX_NONCE) {
            emit SignatureValidationFailed(user, sender, "InvalidNonceValue");
            revert InvalidNonceValue();
        }

        // 3. Prevent Replay Attacks by checking if the exact signature has been used.
        bytes32 sigHash = keccak256(abi.encodePacked(r, s, v));
        if (usedSignatures[sigHash]) {
            emit SignatureValidationFailed(user, sender, "ReplayAttack");
            revert ReplayAttack();
        }

        // 4. Validate ECDSA Signature: The proof must be signed by IDENTIFI_SIGNER and bound to this user, router, and contract.
        if (
            _recoverSigner(user, proofNonce, deadline, r, s, v) !=
            IDENTIFI_SIGNER
        ) {
            emit SignatureValidationFailed(user, sender, "InvalidSignature");
            revert InvalidSignature();
        }

        // 5. Invalidate the signature for future swaps.
        usedSignatures[sigHash] = true;

        // 6. Emit validation success event for off-chain monitoring.
        emit ProofValidated(user, sender, proofNonce);

        //  PROOF VALIDATED → Swap proceeds → Jobber → Treasury (trust chain established)
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /**
     * @notice Helper function for external validation (Off-chain or Tests).
     */
    function validateHookData(
        address user,
        bytes calldata hookData
    ) external view returns (bool) {
        if (hookData.length != HOOK_DATA_LENGTH) return false;
        if (user == address(0)) return false;

        (
            uint256 proofNonce,
            bytes32 r,
            bytes32 s,
            uint8 v,
            uint256 deadline
        ) = _decodeHookData(hookData);

        if (block.timestamp > deadline) return false;
        if (proofNonce > MAX_NONCE) return false;
        bytes32 sigHash = keccak256(abi.encodePacked(r, s, v));
        if (usedSignatures[sigHash]) return false;

        return
            _recoverSigner(user, proofNonce, deadline, r, s, v) ==
            IDENTIFI_SIGNER;
    }

    /**
     * @dev Internal function to extract signature components.
     */
    function _decodeHookData(
        bytes calldata hookData
    )
        internal
        pure
        returns (
            uint256 proofNonce,
            bytes32 r,
            bytes32 s,
            uint8 v,
            uint256 deadline
        )
    {
        (proofNonce, r, s, v, deadline) = abi.decode(
            hookData,
            (uint256, bytes32, bytes32, uint8, uint256)
        );

        // Signature Malleability Protection
        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            revert InvalidSignature();
        }

        // V must be 27 or 28
        if (v != 27 && v != 28) revert InvalidSignature();
    }

    /**
     * @dev Recovers the address that signed the hookData.
     */
    function _recoverSigner(
        address user,
        uint256 proofNonce,
        uint256 deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal view returns (address recoveredSigner) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(block.chainid, user, proofNonce, deadline)
        );

        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        recoveredSigner = ecrecover(ethSignedMessageHash, v, r, s);
    }

    // ============ Mandatory v4 Hook Stubs ============
    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }
    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }
    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }
    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function unlockCallback(
        bytes calldata data
    ) external view returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return data;
    }
}
