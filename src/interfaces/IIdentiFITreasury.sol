// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IIdentiFITreasury
 * @notice Standard interface for IdentiFI Treasury revenue hub.
 * @dev All revenue sources use these standardized functions.
 */
interface IIdentiFITreasury {
    // ============ Multi-Source Deposits ============
    
    /**
     * @notice Deposit swap fees from Hook/Jobber.
     * @param token Token address (address(0) for ETH)
     * @param amount Total fee amount
     * @param user User who performed swap
     * @param lp LP provider (can be address(0))
     */
    function depositFromHook(
        address token,
        uint256 amount,
        address user,
        address lp
    ) external payable;

    /**
     * @notice Deposit transaction fees from SDK partners.
     */
    function depositFromSDK(
        address token,
        uint256 amount,
        address user,
        address lp
    ) external payable;

    /**
     * @notice Deposit USDT/USDC from site fuel verification.
     * @param token USDT or USDC token
     * @param amount Payment amount (session ID)
     * @param user User who made payment
     */
    function depositFromSite(
        address token,
        uint256 amount,
        address user
    ) external;

    // ============ Quarterly Claims ============

    /**
     * @notice Claim user's 16.5% share for current quarter.
     * @dev Only available during 90-day window, once per quarter.
     */
    function claimUserShare(address token) external;

    /**
     * @notice Claim LP's 16.5% share for current quarter.
     */
    function claimLPShare(address token) external;

    /**
     * @notice Claim protocol's 67% share for current quarter.
     */
    function claimTreasuryShare(address token) external;

    // ============ View Functions ============

    function getUserBalance(address token, address user) external view returns (uint256);
    function getLPBalance(address token, address lp) external view returns (uint256);
    function getTreasuryBalance(address token) external view returns (uint256);
    function isDistributionWindowOpen() external view returns (bool);
    function getDistributionWindowEnd() external view returns (uint256);
    function getTimeRemainingInWindow() external view returns (uint256);
    function currentQuarter() external view returns (uint256);
}