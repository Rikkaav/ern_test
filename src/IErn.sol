// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IDex} from "./IDex.sol";
import {IAavePool} from "./IAavePool.sol";

import {IERC20} from "./token/ERC20/IERC20.sol";

/**
 * @title IErn
 * @notice Interface for the Ern contract that deposits an underlying asset into Aave and converts its generated yield to reward tokens.
 * @dev Extends ERC20 standard with additional yield farming functionality. Workflows:
 *      1. deposit():
 *                 - Users deposit an underlying asset into the contract.
 *                 - The contract mints shares (1:1) to the users and the underlying asset is then supplied to Aave.
 *                 - Contract holds aUnderlying tokens.
 *                 - Users are locked for a certain period after deposit.
 *      2. harvest():
 *                 - The contract periodically harvests yield from Aave, converts it to reward tokens using a DEX.
 *                 - Removes a certain percentage as a protocol fee.
 *                 - Calculates remainder reward tokens per share (cumulativeRewardPerShare).
 *      3. claimYield(): Users can claim their reward tokens based on their share of the total supply and the cumulativeRewardPerShare.
 *      4. withdraw():
 *                 - Users can withdraw their underlying asset after a locked period;
 *                 - Contract burns their shares and returns the underlying asset after converting aUnderlying to underlying asset.
 */
interface IErn {
    // --- Structs ---

    /**
     * @notice User information for yield tracking and deposit locking
     * @param lastCumulativeRewardPerShare Last recorded cumulative reward per share for the user
     * @param rewardClaimed Total amount of reward claimed by the user
     * @param depositTimestamp Timestamp of the user's last deposit for lock period calculation
     */
    struct UserInfo {
        uint256 lastCumulativeRewardPerShare;
        uint256 rewardClaimed;
        uint256 depositTimestamp;
    }

    // --- Events ---

    /**
     * @notice Emitted when yield is harvested and converted to reward tokens
     * @param underlyingYield Amount of Underlying yield harvested from Aave
     * @param rewardBought Amount of reward tokens received after swapping Underlying yield
     * @param feeTaken Amount of reward tokens taken as protocol fee
     * @param cumulativeRewardPerShare Updated cumulative reward tokens per share after harvest
     */
    event Harvest(uint256 underlyingYield, uint256 rewardBought, uint256 feeTaken, uint256 cumulativeRewardPerShare);

    /**
     * @notice Emitted when a user claims their reward tokens
     * @param user Address of the user claiming yield
     * @param amount Amount of reward tokens claimed
     */
    event YieldClaimed(address indexed user, uint256 amount);

    /**
     * @notice Emitted when the protocol fee is updated
     * @param newHarvestFee New fee in basis points (1 bp = 0.01%)
     */
    event FeeUpdated(uint256 newHarvestFee);

    /**
     * @notice Emitted when the minimum yield amount is updated
     * @param newMinYieldAmount New minimum yield amount required for harvest
     */
    event MinYieldAmountUpdated(uint256 newMinYieldAmount);

    /**
     * @notice Emitted when the harvest time period is updated
     * @param newHarvestTimePeriod New time period for harvest restriction
     */
    event HarvestTimePeriodUpdated(uint256 newHarvestTimePeriod);

    /**
     * @notice Emitted when a user deposits underlying tokens
     * @param user Address of the user depositing
     * @param amount Amount of underlying tokens deposited
     */
    event Deposit(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user withdraws underlying tokens
     * @param user Address of the user withdrawing
     * @param amount Amount of underlying tokens withdrawn
     * @param fee Amount of underlying tokens kept as fee
     */
    event Withdraw(address indexed user, uint256 amount, uint256 fee);

    /**
     * @notice Emitted when the harvester address is updated
     * @param newHarvester Address of the new harvester
     * @param isAuthorized True if the new harvester is authorized, false otherwise
     */
    event HarvesterUpdated(address indexed newHarvester, bool isAuthorized);

    // --- View Functions ---

    /**
     * @notice Returns the reward token contract
     * @return The IERC20 interface of the reward token
     */
    function REWARD_TOKEN() external view returns (IERC20);

    /**
     * @notice Returns the Aave Underlying token (aUnderlying) contract
     * @return The IERC20 interface of the aUnderlying token
     */
    function getAaveUnderlying() external view returns (IERC20);

    /**
     * @notice Returns the Underlying token contract
     * @return The IERC20 interface of the Underlying token
     */
    function UNDERLYING() external view returns (IERC20);

    /**
     * @notice Returns the DEX contract address used for token swaps
     * @return The address of the DEX contract
     */
    function DEX() external view returns (IDex);

    /**
     * @notice Returns the Aave Pool contract address used for lending/borrowing
     * @return The address of the Aave Pool contract
     */
    function getAavePool() external view returns (IAavePool);

    /**
     * @notice Returns the maximum allowed protocol harvest fee
     * @return The maximum fee in basis points (currently 1000 = 10%)
     */
    function MAX_HARVEST_FEE_BPS() external view returns (uint256);

    /**
     * @notice Returns the maximum allowed protocol withdraw fee
     * @return The maximum fee in basis points (currently 10 = 0.1%)
     */
    function MAX_WITHDRAW_FEE_BPS() external view returns (uint256);

    /**
     * @notice Returns the current protocol fee in basis points
     * @return The fee in basis points (1 bp = 0.01%)
     */
    function harvestFee() external view returns (uint256);

    /**
     * @notice Returns the current protocol fee in basis points
     * @return The fee in basis points (1 bp = 0.01%)
     */
    function withdrawFee() external view returns (uint256);

    /**
     * @notice Returns the cumulative reward tokens per share for yield distribution
     * @return The cumulative reward tokens per share value scaled by 1e18
     */
    function cumulativeRewardPerShare() external view returns (uint256);

    /**
     * @notice Returns the lock period duration in seconds
     * @return The lock period duration
     */
    function lockPeriod() external view returns (uint256);

    /**
     * @notice Returns if the given account is an authorized harvester.
     * @return True if the account is allowed, false otherwise.
     */
    function isHarvester(address account) external view returns (bool);

    /**
     * @notice Returns the minimum yield amount required for harvest
     * @return The minimum yield amount
     */
    function minYieldAmount() external view returns (uint256);

    /**
     * @notice Returns the harvest time period restriction
     * @return The time period in seconds
     */
    function harvestTimePeriod() external view returns (uint256);

    /**
     * @notice Calculates the claimable reward yield for a user
     * @param user Address of the user
     * @return The amount of reward tokens the user can claim
     */
    function claimableYield(address user) external view returns (uint256);

    /**
     * @notice Calculates the applicable fee for a withdrawal
     * @param user Address of the user
     * @param amount Amount of underlying tokens to withdraw
     * @return amountAfterFee The amount after applying the fee
     * @return feeAmount The fee amount deducted from the withdrawal
     */
    function applicableFee(address user, uint256 amount)
        external
        view
        returns (uint256 amountAfterFee, uint256 feeAmount);

    /**
     * @notice Returns the total amount of underlying assets managed by the vault
     * @return The total underlying assets (including those deposited in Aave)
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Checks if a user's deposit is still locked
     * @param user Address of the user
     * @return True if the user is still in lock period
     */
    function isLocked(address user) external view returns (bool);

    /**
     * @notice Returns the unlock timestamp for a user
     * @param user Address of the user
     * @return The timestamp when the user can withdraw
     */
    function unlockTime(address user) external view returns (uint256);

    // --- State-Changing Functions ---

    /**
     * @notice Harvests yield from Aave and converts it to reward tokens for distribution
     * @dev Only callable by the contract owner, requires either sufficient yield amount or time period to have passed
     * @param minOut Minimum amount of reward tokens to receive from the swap (slippage protection)
     */
    function harvest(uint256 minOut) external;

    /**
     * @notice Claims accumulated reward yield for the caller
     * @dev Updates the user's checkpoint and transfers claimable reward tokens
     */
    function claimYield() external;

    /**
     * @notice Updates the protocol fee
     * @dev Only callable by the contract owner
     * @param newHarvestFee New fee in basis points, must not exceed MAX_HARVEST_FEE_BPS
     */
    function setHarvestFee(uint256 newHarvestFee) external;

    /**
     * @notice Updates the protocol fee
     * @dev Only callable by the contract owner
     * @param newWithdrawFee New fee in basis points, must not exceed MAX_WITHDRAW_FEE_BPS
     */
    function setWithdrawFee(uint256 newWithdrawFee) external;

    /**
     * @notice Sets a new harvester
     * @dev Only callable by the contract owner
     * @param newHarvester The address of the new harvester
     */
    function addHarvester(address newHarvester) external;

    /**
     * @notice Removes a harvester from the allowed list
     * @dev Only callable by the contract owner
     * @param harvesterToRemove The address of the harvester to remove
     */
    function removeHarvester(address harvesterToRemove) external;

    /**
     * @notice Updates the minimum yield amount required for harvest
     * @dev Only callable by the contract owner
     * @param newMinYieldAmount New minimum yield amount
     */
    function setMinYieldAmount(uint256 newMinYieldAmount) external;

    /**
     * @notice Updates the harvest time period restriction
     * @dev Only callable by the contract owner
     * @param newHarvestTimePeriod New time period for harvest restriction
     */
    function setHarvestTimePeriod(uint256 newHarvestTimePeriod) external;

    /**
     * @notice Deposits underlying tokens into the vault
     * @param amount The amount of underlying tokens to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraws underlying tokens from the vault
     * @param amount The amount of underlying tokens to withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Returns the UserInfo for a given user address
     * @param user The address of the user
     * @return lastCumulativeRewardPerShare The last recorded cumulative reward per share for the user
     * @return rewardClaimed The total amount of reward claimed by the user
     * @return depositTimestamp The timestamp of the user's last deposit
     */
    function users(address user)
        external
        view
        returns (uint256 lastCumulativeRewardPerShare, uint256 rewardClaimed, uint256 depositTimestamp);
}