// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IdentiFITreasury} from "../src/IdentiFITreasury.sol";

/**
 * @title IdentiFITreasuryTest
 * @notice Test contract for IdentiFITreasury
 */
contract IdentiFITreasuryTest is Test {
    IdentiFITreasury treasury;
    MockERC20 usdt;
    // Test Users
    address owner = makeAddr("owner");
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address lpA = makeAddr("lpA");

    /**
     * @notice Sets up the test environment
     */
    function setUp() public {
        treasury = new IdentiFITreasury(owner);
        usdt = new MockERC20("USDT", "USDT", 6);

        vm.deal(address(this), 1000 ether);
        usdt.mint(address(this), 1_000_000e6);
        vm.prank(owner);
        treasury.setAuthorizedSource(address(this), true);
        vm.warp(block.timestamp + 91 days);
        vm.prank(owner);
        treasury.advanceQuarter();
    }

    /**
     * TESTE 1, 3 and 4: The Rule of Three of the Volume
     * Scenario:
     * - User A generates 100 of volume (1/4 of the total)
     * - User B generates 300 of volume (3/4 of the total)
     * - Total in the Bucket: 400 ETH
     * - Pool of Users (16.5% of 400) = 66 ETH
     *
     * Expectation:
     * - User A withdraws: 25% of 66 = 16.5 ETH
     * - User B withdraws: 75% of 66 = 49.5 ETH
     */
    /**
     * TEST 1: The Rule of Three of the Volume
     */
    function test_ProportionalVolumeDistribution() public {
        // 1. Deposits (Occur in Q1, since setUp already advanced)
        vm.deal(address(this), 100 ether);
        treasury.deposit{value: 100 ether}(
            address(0),
            100 ether,
            userA,
            address(0)
        );

        vm.deal(address(this), 300 ether);
        treasury.deposit{value: 300 ether}(
            address(0),
            300 ether,
            userB,
            address(0)
        );

        // 2. User A withdraws (1/4 of the volume)
        uint256 balanceABefore = userA.balance;
        vm.prank(userA);
        treasury.claimUserShare(address(0));
        uint256 receivedA = userA.balance - balanceABefore;

        // 3. User B withdraws (3/4 of the volume)
        uint256 balanceBBefore = userB.balance;
        vm.prank(userB);
        treasury.claimUserShare(address(0));
        uint256 receivedB = userB.balance - balanceBBefore;

        // Verifications
        assertEq(
            receivedA,
            16.5 ether,
            "User A should receive 1/4 of the pool of 16.5%"
        );
        assertEq(
            receivedB,
            49.5 ether,
            "User B should receive 3/4 of the pool of 16.5%"
        );
    }

    /**
     * TESTE 2: The Owner withdraws his part
     * Scenario: 400 ETH entered in total.
     * Expectation: Owner withdraws 67% of 400 = 268 ETH.
     */
    function test_OwnerWithdrawsProtocolShare() public {
        // Feed the bucket with 400 ETH
        vm.deal(address(this), 400 ether);
        treasury.deposit{value: 400 ether}(
            address(0),
            400 ether,
            userA,
            address(0)
        );

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        treasury.withdrawProtocolShare(address(0));

        uint256 receivedByOwner = owner.balance - ownerBalanceBefore;
        assertEq(
            receivedByOwner,
            268 ether,
            "Owner should withdraw exactly 67% of the bucket"
        );
    }

    /**
     * TEST EXTRA: Works with Tokens (USDT)
     * Scenario: User A (100 tokens), User B (300 tokens).
     * Pool of 16.5% of 400 tokens = 66 tokens.
     */
    /**
     * TEST EXTRA: Works with Tokens (USDT)
     */
    function test_ProportionalTokenDistribution() public {
        uint256 volA = 100e6;
        uint256 volB = 300e6;

        usdt.approve(address(treasury), 1000e6);

        // Deposits tokens
        treasury.deposit(address(usdt), volA, userA, address(0));
        treasury.deposit(address(usdt), volB, userB, address(0));

        // --- REMOVED: vm.warp and advanceQuarter ---

        // User A withdraws
        vm.prank(userA);
        treasury.claimUserShare(address(usdt));

        // 16.5% of 400 = 66. 25% of 66 = 16.5 tokens
        assertEq(
            usdt.balanceOf(userA),
            16.5e6,
            "User A should receive 16.5 USDT"
        );
    }

    /**
     * TEST EXTRA: Anti-bot (Only one withdrawal per quarter)
     */
    function test_AntiBotOncePerQuarter() public {
        // To pass the first withdrawal, we must be in Q1
        vm.warp(block.timestamp + 91 days);
        vm.prank(owner);
        treasury.advanceQuarter();

        vm.deal(address(this), 100 ether);
        treasury.deposit{value: 100 ether}(
            address(0),
            100 ether,
            userA,
            address(0)
        );

        // First withdrawal: OK (We are in Q1 and the user has withdrawn 0 so far)
        vm.prank(userA);
        treasury.claimUserShare(address(0));

        // Second withdrawal in the same quarter: ERROR (Now it will correctly trigger the revert)
        vm.prank(userA);
        vm.expectRevert("already withdrawn this quarter");
        treasury.claimUserShare(address(0));
    }
}
