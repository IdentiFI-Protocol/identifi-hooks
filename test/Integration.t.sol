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
 * @title IntegrationJobberTreasuryTest
 * @notice Test contract for JobberUniversal and IdentiFITreasury integration
 */
contract IntegrationJobberTreasuryTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 tokenTest;
    JobberUniversal jobber;
    IdentiFIHook identiFIHook;
    IdentiFITreasury treasury;

    address treasuryOwner = makeAddr("treasuryOwner");
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address lpA = makeAddr("lpA");
    address lpB = makeAddr("lpB");

    PoolKey integrationTestKey;

    /**
     * @dev Sets up the test environment
     */
    function setUp() public {
        vm.chainId(11155111);
        deployFreshManagerAndRouters();

        vm.deal(address(manager), 100 ether);
        vm.deal(address(this), 1000 ether);
        vm.deal(userA, 100 ether);
        vm.deal(userB, 100 ether);
        vm.deal(treasuryOwner, 100 ether);
        vm.deal(lpA, 100 ether);
        vm.deal(lpB, 100 ether);

        tokenTest = new MockERC20("Test Token", "TEST", 18);
        tokenTest.mint(address(this), 1000 ether);
        tokenTest.approve(address(modifyLiquidityRouter), type(uint256).max);

        // 1. MINING THE HOOK ADDRESS (MANDATORY IN V4)
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(IdentiFIHook).creationCode,
            abi.encode(address(manager))
        );
        identiFIHook = new IdentiFIHook{salt: salt}(manager);

        // 2. REST OF DEPLOYMENT
        jobber = new JobberUniversal(address(manager));
        treasury = new IdentiFITreasury(treasuryOwner);

        vm.prank(treasuryOwner);
        treasury.setAuthorizedSource(address(jobber), true);

        jobber.setTreasury(address(treasury));
        vm.prank(0x33b9B6498b1319B737efC4f5956Cb4611DAbb974);
        identiFIHook.setTrustedRouter(address(jobber), true);

        // 3. START Q1 (TO AVOID "NO VOLUME" AND "ALREADY WITHDRAWN")
        vm.warp(block.timestamp + 91 days);
        vm.prank(treasuryOwner);
        treasury.advanceQuarter();

        (integrationTestKey, ) = initPool(
            Currency.wrap(address(0)),
            Currency.wrap(address(tokenTest)),
            identiFIHook,
            3000,
            60,
            SQRT_PRICE_1_1
        );

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            integrationTestKey,
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
     * @dev Tests the proportional user claims
     */
    function test_Integration_ProportionalUserClaims() public {
        // NOW WE DEPOSIT AND WITHDRAW EVERYTHING INSIDE Q1
        _depositViaJobber(address(0), 1 ether, userA, address(0));
        _depositViaJobber(address(0), 3 ether, userB, address(0));

        uint256 balA_before = userA.balance;
        vm.prank(userA);
        treasury.claimUserShare(address(0));
        assertEq(
            userA.balance - balA_before,
            0.165 ether,
            "User A should receive 1/4"
        );

        uint256 balB_before = userB.balance;
        vm.prank(userB);
        treasury.claimUserShare(address(0));
        assertEq(
            userB.balance - balB_before,
            0.495 ether,
            "User B should receive 3/4"
        );
    }

    /**
     * @dev Tests the proportional LP claims
     */
    function test_Integration_ProportionalLPClaims() public {
        _depositViaJobber(address(0), 1 ether, userA, lpA);
        _depositViaJobber(address(0), 1 ether, userA, lpB);

        uint256 balLpA_before = lpA.balance;
        vm.prank(lpA);
        treasury.claimLPShare(address(0));
        assertEq(
            lpA.balance - balLpA_before,
            0.165 ether,
            "LP A should receive 50%"
        );

        uint256 balLpB_before = lpB.balance;
        vm.prank(lpB);
        treasury.claimLPShare(address(0));
        assertEq(
            lpB.balance - balLpB_before,
            0.165 ether,
            "LP B should receive 50%"
        );
    }

    /**
     * @dev Tests the owner's withdrawal of 67% of the fees
     */
    function test_Integration_OwnerWithdraws67Percent() public {
        _depositViaJobber(address(0), 10 ether, userA, lpA);
        uint256 ownerBefore = treasuryOwner.balance;
        vm.prank(treasuryOwner);
        treasury.withdrawProtocolShare(address(0));
        assertEq(treasuryOwner.balance - ownerBefore, 6.7 ether);
    }

    /**
     * @dev Tests the quarterly cycle anti-bot mechanism
     */
    function test_Integration_QuarterlyCycle() public {
        // 1. WITHDRAWAL OK ( WE ARE IN Q1)
        _depositViaJobber(address(0), 1 ether, userA, address(0));
        vm.prank(userA);
        treasury.claimUserShare(address(0));

        // 2. ANTI-BOT: FAILURE IN THE SAME QUARTER
        vm.prank(userA);
        vm.expectRevert("already withdrawn this quarter");
        treasury.claimUserShare(address(0));

        // 3. ADVANCE TO Q2
        vm.warp(block.timestamp + 91 days);
        vm.prank(treasuryOwner);
        treasury.advanceQuarter();

        // 4. NEW DEPOSIT AND NEW SUCCESSFUL WITHDRAWAL IN Q2
        _depositViaJobber(address(0), 1 ether, userA, address(0));
        vm.prank(userA);
        treasury.claimUserShare(address(0));
    }

    /**
     * @dev Deposit liquidity via Jobber
     */
    function _depositViaJobber(
        address token,
        uint256 amount,
        address user,
        address lp
    ) private {
        if (token == address(0)) {
            vm.deal(address(jobber), amount);
            vm.prank(address(jobber));
            treasury.deposit{value: amount}(address(0), amount, user, lp);
        } else {
            tokenTest.mint(address(jobber), amount);
            vm.prank(address(jobber));
            treasury.deposit(token, amount, user, lp);
        }
    }
}
