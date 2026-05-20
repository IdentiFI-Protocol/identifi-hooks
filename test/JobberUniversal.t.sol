// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {JobberUniversal} from "../src/JobberUniversal.sol";
import {IdentiFIHook} from "../src/IdentiFIHook.sol";
import {IdentiFITreasury} from "../src/IdentiFITreasury.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title TestJobberUniversal
 * @notice Test contract for JobberUniversal
 */
contract TestJobberUniversal is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token;
    JobberUniversal jobber;
    IdentiFIHook identiFIHook;
    IdentiFITreasury treasury;

    address testUser = 0x92ad5e4c48751Fc44eA7e9Fad90d55E577Ee837C;

    /**
     * @dev Sets up the test environment
     */
    function setUp() public {
        vm.chainId(11155111);
        deployFreshManagerAndRouters();

        vm.deal(address(manager), 100 ether);
        vm.deal(address(this), 100 ether);
        vm.deal(testUser, 100 ether);

        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(address(this), 1000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(IdentiFIHook).creationCode,
            abi.encode(address(manager))
        );
        identiFIHook = new IdentiFIHook{salt: salt}(manager);

        jobber = new JobberUniversal(address(manager));

        // --- New: Treasury Configuration ---
        treasury = new IdentiFITreasury(jobber.owner());

        vm.startPrank(jobber.owner());

        jobber.setTreasury(address(treasury));
        treasury.setAuthorizedSource(address(jobber), true);

        vm.stopPrank();

        vm.prank(0x33b9B6498b1319B737efC4f5956Cb4611DAbb974);
        identiFIHook.setTrustedRouter(address(jobber), true);

        vm.prank(address(jobber));
        token.approve(address(manager), type(uint256).max);

        (key, ) = initPool(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            identiFIHook,
            3000,
            60,
            SQRT_PRICE_1_1
        );

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /**
     * @notice Swap Test Validating the Flow: Jobber -> Treasury
     */
    function testUniversalSwapWithValidProofAndTreasury() public {
        vm.chainId(11155111);
        uint256 amountToSwap = 0.1 ether;

        // Valid HookData
        bytes
            memory realHookData = hex"00000000000000000000000000000000000000000000000000000000d4065b13cc2fe64c8ec3b13ede455a5dd1f98b10fdd77c8ca3a2776856d4282bf059b6712824215fc5d82536f3b03f3d1ffe97e1dcc1678c3c4cae56d34a686667fe502a000000000000000000000000000000000000000000000000000000000000001b000000000000000000000000000000000000000000000000000000006a0655ae";
        uint256 userTokenBalanceBefore = token.balanceOf(testUser);
        address owner = jobber.owner();
        uint256 ownerEthBalanceBefore = owner.balance;

        // Executes the swap
        vm.prank(testUser);
        jobber.settlement{value: amountToSwap}(
            key,
            amountToSwap,
            true,
            0,
            realHookData
        );

        // 1. Check if the swap occurred
        assertGt(
            token.balanceOf(testUser),
            userTokenBalanceBefore,
            "User should receive tokens"
        );

        // 2. Check the fee (0.066% of 0.1 ether)
        uint256 expectedFee = (amountToSwap * 660) / 1_000_000;

        // 3. CRITICAL VERIFICATION:
        // The Owner's balance should NOT have increased
        assertEq(
            owner.balance,
            ownerEthBalanceBefore,
            "Owner should NOT receive fees directly when treasury is active"
        );

        // The Treasury balance should have increased exactly by the fee
        assertEq(
            address(treasury).balance,
            expectedFee,
            "Fees must be routed to Treasury"
        );
    }
}
