// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IdentiFI Treasury
 * @notice Acts as a Unified Revenue Bucket for the IdentiFI protocol.
 * @dev Implements a 67/33 split: 67% for the protocol (Owner) and 33% for the community.
 * The community share is further split 50/50 between Users and Liquidity Providers (LPs),
 * resulting in 16.5% for Users and 16.5% for LPs.
 *
 * Distribution is proportional: Users/LPs who generate more volume receive a larger
 * share of their respective 16.5% pool.
 */
contract IdentiFITreasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Protocol share percentage (67%)
    uint256 public constant PROTOCOL_SHARE = 67;
    /// @notice Total community share percentage (33%)
    uint256 public constant COMMUNITY_SHARE = 33;

    /// @notice Current active quarter for volume tracking and claims
    uint256 public currentQuarter = 1;
    /// @notice Timestamp marking the start of the current distribution window
    uint256 public quarterStartTime;

    /**
     * @dev The "Money Bucket": Tracks total assets accumulated per token per quarter.
     * Mapping: quarter => token => total_amount
     */
    mapping(uint256 => mapping(address => uint256)) public quarterlyBucket;

    /**
     * @dev Access control for deposit sources (e.g., Jobber Universal Router).
     */
    mapping(address => bool) public authorizedSources;

    /**
     * @dev Volume registries to calculate proportional shares (Rule of Three).
     * userVolume: quarter => token => user => volume_generated
     * lpVolume: quarter => token => lp => volume_generated
     */
    mapping(uint256 => mapping(address => mapping(address => uint256)))
        public userVolume;
    mapping(uint256 => mapping(address => mapping(address => uint256)))
        public lpVolume;

    /**
     * @dev Total volumes per quarter used as the denominator for proportional claims.
     */
    mapping(uint256 => mapping(address => uint256)) public totalUserVolume;
    mapping(uint256 => mapping(address => uint256)) public totalLPVolume;

    /**
     * @dev Anti-bot tracking: records the last quarter a user claimed tokens.
     * Mapping: user => token => quarter_id
     */
    mapping(address => mapping(address => uint256)) public lastClaimQuarter;

    event Deposited(address indexed token, uint256 amount, uint256 quarter);
    event Claimed(address indexed user, address indexed token, uint256 amount);

    constructor(address _owner) Ownable(_owner) {
        quarterStartTime = block.timestamp;
    }

    /**
     * @notice Deposits funds into the treasury and records volume for future distribution.
     * @dev Only authorized sources (like Jobber) or the owner can call this function.
     * @param token Address of the token being deposited (address(0) for ETH).
     * @param amount The amount of assets to deposit.
     * @param user The user associated with the volume generation.
     * @param lp The LP provider associated with the volume generation.
     */
    function deposit(
        address token,
        uint256 amount,
        address user,
        address lp
    ) external payable {
        require(
            authorizedSources[msg.sender] || msg.sender == owner(),
            "Not authorized"
        );

        if (token == address(0)) {
            require(msg.value == amount, "Send ETH");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Update the global bucket for the current quarter
        quarterlyBucket[currentQuarter][token] += amount;

        // Record user volume for proportional distribution
        if (user != address(0)) {
            userVolume[currentQuarter][token][user] += amount;
            totalUserVolume[currentQuarter][token] += amount;
        }
        // Record LP volume for proportional distribution
        if (lp != address(0)) {
            lpVolume[currentQuarter][token][lp] += amount;
            totalLPVolume[currentQuarter][token] += amount;
        }

        emit Deposited(token, amount, currentQuarter);
    }

    /**
     * @notice Withdraws the protocol's 67% share of current assets.
     * @dev This function is not bound by quarterly restrictions; the owner can withdraw at any time.
     * @param token Address of the token to withdraw (address(0) for ETH).
     */
    function withdrawProtocolShare(address token) external onlyOwner {
        uint256 balance = (token == address(0))
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        uint256 share = (balance * PROTOCOL_SHARE) / 100;

        _transfer(token, owner(), share);
    }

    /**
     * @notice Allows users to claim their proportional share of the 16.5% user pool.
     * @dev Formula: (User Volume / Total Volume) * (Quarterly Bucket * 16.5%)
     * @param token Address of the token to claim.
     */
    function claimUserShare(address token) external nonReentrant {
        require(block.timestamp <= quarterStartTime + 90 days, "window closed");
        require(
            lastClaimQuarter[msg.sender][token] < currentQuarter,
            "already withdrawn this quarter"
        );

        uint256 myVol = userVolume[currentQuarter][token][msg.sender];
        uint256 totalVol = totalUserVolume[currentQuarter][token];
        require(myVol > 0, "no volume");

        // Calculate proportional share: (My Vol / Total Vol) * (33% of bucket / 2)
        uint256 communityPool = (quarterlyBucket[currentQuarter][token] *
            COMMUNITY_SHARE) / 100;
        uint256 userPool = communityPool / 2; // 16.5%

        uint256 amountToClaim = (myVol * userPool) / totalVol;

        // Mark as claimed for this quarter (Anti-bot) and reset volume credit
        lastClaimQuarter[msg.sender][token] = currentQuarter;
        userVolume[currentQuarter][token][msg.sender] = 0;

        _transfer(token, msg.sender, amountToClaim);
        emit Claimed(msg.sender, token, amountToClaim);
    }

    /**
     * @notice Allows LP providers to claim their proportional share of the 16.5% LP pool.
     * @dev Formula: (LP Volume / Total LP Volume) * (Quarterly Bucket * 16.5%)
     * @param token Address of the token to claim.
     */
    function claimLPShare(address token) external nonReentrant {
        require(block.timestamp <= quarterStartTime + 90 days, "window closed");
        require(
            lastClaimQuarter[msg.sender][token] < currentQuarter,
            "already withdrawn this quarter"
        );

        uint256 myVol = lpVolume[currentQuarter][token][msg.sender];
        uint256 totalVol = totalLPVolume[currentQuarter][token];
        require(myVol > 0, "no volume");

        uint256 communityPool = (quarterlyBucket[currentQuarter][token] *
            COMMUNITY_SHARE) / 100;
        uint256 lpPool = communityPool / 2; // 16.5%

        uint256 amountToClaim = (myVol * lpPool) / totalVol;

        lastClaimQuarter[msg.sender][token] = currentQuarter;
        lpVolume[currentQuarter][token][msg.sender] = 0;

        _transfer(token, msg.sender, amountToClaim);
        emit Claimed(msg.sender, token, amountToClaim);
    }

    /**
     * @notice Advances the protocol to the next quarter.
     * @dev Resets the 90-day distribution window and increments the quarter ID.
     */
    function advanceQuarter() external onlyOwner {
        currentQuarter++;
        quarterStartTime = block.timestamp;
    }

    /**
     * @dev Internal helper to handle both ETH and ERC20 transfers.
     */
    function _transfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Sets whether a specific address (e.g., Jobber Router) is authorized to deposit fees.
     * @param source The address to authorize/unauthorize.
     * @param status True to authorize, false to revoke.
     */
    function setAuthorizedSource(
        address source,
        bool status
    ) external onlyOwner {
        authorizedSources[source] = status;
    }

    receive() external payable {}
}
