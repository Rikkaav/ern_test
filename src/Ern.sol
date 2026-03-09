// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "./ERC20.sol";
import {Ownable} from "./Ownable.sol";
import {SafeERC20, IERC20} from "./SafeERC20.sol";

import {IErn} from "./IErn.sol";
import {IDex} from "./IDex.sol";
import {IAavePool} from "./IAavePool.sol";
import {IAaveAddressesProvider} from "./IAaveAddressesProvider.sol";

contract Ern is ERC20, Ownable, IErn {
    using SafeERC20 for IERC20;

    // --- Immutable State ---
    IERC20 public immutable REWARD_TOKEN;
    IAaveAddressesProvider public immutable AAVE_ADDRESSES;
    IERC20 public immutable UNDERLYING;
    IDex public immutable DEX;
    uint8 private immutable _decimals;

    // --- Constants ---
    uint256 public constant MAX_HARVEST_FEE_BPS = 1000; // 10% max fee
    uint256 public constant MAX_WITHDRAW_FEE_BPS = 10; // 0.1% max fee

    // --- Mutable State ---
    uint256 public harvestFee = 500; // 5% default fee
    uint256 public withdrawFee = 10; // 0.1% default fee
    uint256 public cumulativeRewardPerShare;
    uint256 public lockPeriod = 48 hours;
    uint256 public hardLockPeriod = 20 seconds;
    uint256 public lastHarvest;
    uint256 public harvestCooldown = 48 hours; // For public harvest
    uint256 public minYieldAmount;
    uint256 public harvestTimePeriod = 24 hours; // Time period for harvest restriction

    mapping(address => bool) private _harvesterSet;

    // --- User Data ---
    mapping(address => UserInfo) public users;

    // --- Errors ---
    error AmountCannotBeZero();
    error HarvestCooldownNotMet();
    error FeeTooHigh();
    error AddressCannotBeZero();
    error TokensAreLocked();
    error NoYieldToClaim();
    error TransferLocked();
    error HarvestConditionsNotMet();
    error MinYieldAmountTooLow();
    error MinYieldAmountTooHigh();
    error HarvestTimePeriodTooShort();
    error HarvestTimePeriodTooLong();
    error InsufficientAllowance();
    error HarvestingNotAllowed();

    constructor(ERC20 _underlying, ERC20 _rewardToken, IAaveAddressesProvider _aaveAddresses, IDex _dex)
        ERC20(
            string.concat(
                // e.g. ern aUSDC to Wrapped BTC
                "ern ",
                ERC20(address(_aaveAddresses.getPool().getReserveAToken(address(_underlying)))).name(),
                " to ",
                _rewardToken.name()
            ),
            // e.g. ern-aUSDC-wBTC
            string.concat(
                "ern-",
                ERC20(address(_aaveAddresses.getPool().getReserveAToken(address(_underlying)))).symbol(),
                "-",
                _rewardToken.symbol()
            )
        )
        Ownable(msg.sender)
    {
        UNDERLYING = _underlying;
        AAVE_ADDRESSES = _aaveAddresses;
        REWARD_TOKEN = _rewardToken;
        DEX = _dex;
        _decimals = _underlying.decimals();
        minYieldAmount = 50 * 10 ** _decimals; // Set minimum yield to 50 tokens in underlying decimals

        // Approve Aave pool to spend underlying tokens
        UNDERLYING.forceApprove(address(getAavePool()), type(uint256).max);
        // Approve DEX to spend underlying tokens for harvest swaps
        UNDERLYING.forceApprove(address(_dex), type(uint256).max);

        lastHarvest = block.timestamp;
        _harvesterSet[msg.sender] = true;
    }

    // --- View Functions ---

    function getAavePool() public view returns (IAavePool) {
        return AAVE_ADDRESSES.getPool();
    }

    function getAaveUnderlying() public view returns (IERC20) {
        return IERC20(AAVE_ADDRESSES.getPool().getReserveAToken(address(UNDERLYING)));
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function totalAssets() external view returns (uint256) {
        return getAaveUnderlying().balanceOf(address(this));
    }

    function isLocked(address user) external view returns (bool) {
        return _isLocked(user);
    }

    function isHardLocked(address user) external view returns (bool) {
        return _isHardLocked(user);
    }

    function unlockTime(address user) external view returns (uint256) {
        return users[user].depositTimestamp + lockPeriod;
    }

    function claimableYield(address user) external view returns (uint256) {
        return _claimableYield(user);
    }

    function isHarvester(address account) external view returns (bool) {
        return _harvesterSet[account];
    }

    // --- State-Changing Functions ---

    function deposit(uint256 amount) external {
        _requireAmountCannotBeZero(amount);

        // Transfer underlying tokens from user
        UNDERLYING.safeTransferFrom(msg.sender, address(this), amount);

        // Supply to Aave
        getAavePool().supply(address(UNDERLYING), amount, address(this), 0);

        uint256 claimable = _claimableYield(msg.sender);
        if (claimable > 0) {
            // Process yield claim before withdrawal
            // TODO: is it necessary to claim yield upon a new deposit?
            _processYield(msg.sender, claimable);
        } else {
            // Update user rewards before minting shares
            _updateUserRewards(msg.sender);
        }

        // Mint shares 1:1 with deposited amount
        _mint(msg.sender, amount);

        // Set deposit timestamp for lock period
        users[msg.sender].depositTimestamp = block.timestamp;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _requireAmountCannotBeZero(amount);
        _requireTokensNotHardLocked(msg.sender);

        uint256 claimable = _claimableYield(msg.sender);
        if (claimable > 0) {
            // Process yield claim before withdrawal
            _processYield(msg.sender, claimable);
        } else {
            // Update user rewards before burning shares
            _updateUserRewards(msg.sender);
        }

        // Burn shares
        _burn(msg.sender, amount);

        // Calculate withdrawal fee
        (uint256 amountAfterFee, uint256 fee) = _calculateApplicableFee(msg.sender, amount);

        // Withdraw from Aave (amount minus fee, fee stays in Aave pool)
        getAavePool().withdraw(address(UNDERLYING), amountAfterFee, msg.sender);

        if (fee > 0) getAavePool().withdraw(address(UNDERLYING), fee, owner());

        emit Withdraw(msg.sender, amountAfterFee, fee);
    }

    function applicableFee(address user, uint256 amount)
        external
        view
        returns (uint256 amountAfterFee, uint256 feeAmount)
    {
        return _calculateApplicableFee(user, amount);
    }

    // if the user is within the lock period, the fee is applicable, otherwise no fee
    function _calculateApplicableFee(address user, uint256 amount)
        internal
        view
        returns (uint256 amountAfterFee, uint256 feeAmount)
    {
        if (_isLocked(user)) {
            feeAmount = (amount * withdrawFee) / 10000;
            amountAfterFee = amount - feeAmount;
        } else {
            amountAfterFee = amount;
            feeAmount = 0;
        }
    }

    function claimYield() external {
        claimYieldOnBehalf(msg.sender);
    }

    function claimYieldOnBehalf(address user) public {
        uint256 claimable = _claimableYield(user);
        if (claimable == 0) revert NoYieldToClaim();

        // Process yield claim
        _processYield(user, claimable);
    }

    function harvest(uint256 minOut) external {
        _requireHarvester(msg.sender);
        (bool _canHarvest,) = canHarvest();

        if (!_canHarvest) {
            revert HarvestConditionsNotMet();
        }

        _performHarvest(minOut);
    }

    function canHarvest() public view returns (bool, uint256) {
        uint256 currentBalance = getAaveUnderlying().balanceOf(address(this));
        uint256 totalSharesSupply = totalSupply();

        // Calculate potential yield amount
        uint256 yieldAmount = currentBalance > totalSharesSupply ? currentBalance - totalSharesSupply : 0;

        // Check if harvest conditions are met
        bool yieldSufficient = yieldAmount >= minYieldAmount;
        bool timePassed = block.timestamp >= lastHarvest + harvestTimePeriod;

        if (!yieldSufficient && !timePassed) {
            return (false, yieldAmount);
        } else {
            return (true, yieldAmount);
        }
    }

    function setHarvestFee(uint256 newHarvestFee) external onlyOwner {
        _requireValidHarvestFee(newHarvestFee);
        harvestFee = newHarvestFee;
        emit FeeUpdated(newHarvestFee);
    }

    function setWithdrawFee(uint256 newWithdrawFee) external onlyOwner {
        _requireValidWithdrawFee(newWithdrawFee);
        withdrawFee = newWithdrawFee;
        emit FeeUpdated(newWithdrawFee);
    }

    function setMinYieldAmount(uint256 newMinYieldAmount) external onlyOwner {
        // Reasonable bounds: minimum 1$, maximum 100,000$
        uint256 min = 1 * 10 ** _decimals;
        uint256 max = 100_000 * 10 ** _decimals;
        if (newMinYieldAmount < min) revert MinYieldAmountTooLow();
        if (newMinYieldAmount > max) revert MinYieldAmountTooHigh();

        minYieldAmount = newMinYieldAmount;
        emit MinYieldAmountUpdated(newMinYieldAmount);
    }

    function setHarvestTimePeriod(uint256 newHarvestTimePeriod) external onlyOwner {
        // Reasonable bounds: minimum 1 hour, maximum 30 days
        if (newHarvestTimePeriod < 1 hours) revert HarvestTimePeriodTooShort();
        if (newHarvestTimePeriod > 30 days) revert HarvestTimePeriodTooLong();

        harvestTimePeriod = newHarvestTimePeriod;
        emit HarvestTimePeriodUpdated(newHarvestTimePeriod);
    }

    function ensureApprovals() external onlyOwner {
        UNDERLYING.forceApprove(address(getAavePool()), type(uint256).max);
        UNDERLYING.forceApprove(address(DEX), type(uint256).max);
    }

    function addHarvester(address newHarvester) external onlyOwner {
        _requireAddressCannotBeZero(newHarvester);
        _harvesterSet[newHarvester] = true;
        emit HarvesterUpdated(newHarvester, true);
    }

    function removeHarvester(address oldHarvester) external onlyOwner {
        _requireAddressCannotBeZero(oldHarvester);
        _harvesterSet[oldHarvester] = false;
        emit HarvesterUpdated(oldHarvester, false);
    }

    // --- Internal Functions ---

    function _update(address from, address to, uint256 value) internal override {
        // Allow minting (from == address(0)) and burning (to == address(0))
        // Block all other transfers
        if (from != address(0) && to != address(0)) {
            revert TransferLocked();
        }

        super._update(from, to, value);
    }

    function _processYield(address user, uint256 amount) internal {
        if (amount == 0) revert NoYieldToClaim();

        // Update user's last cumulative reward tokens per share
        users[user].lastCumulativeRewardPerShare = cumulativeRewardPerShare;
        users[user].rewardClaimed += amount;

        // Transfer reward tokens to user
        REWARD_TOKEN.safeTransfer(user, amount);

        emit YieldClaimed(user, amount);
    }

    function _performHarvest(uint256 minOut) internal {
        uint256 currentBalance = getAaveUnderlying().balanceOf(address(this));
        uint256 totalSharesSupply = totalSupply();

        // Calculate yield (current aToken balance - total shares)
        if (currentBalance <= totalSharesSupply) return; // No yield to harvest

        uint256 yieldAmount = currentBalance - totalSharesSupply;

        // Withdraw yield from Aave
        getAavePool().withdraw(address(UNDERLYING), yieldAmount, address(this));

        // Swap yield to reward tokens
        // NOTE: this assumes the tokens are not the same
        uint256 rewardReceived = DEX.exactInputSingle(
            IDex.ExactInputSingleParams({
                tokenIn: address(UNDERLYING),
                tokenOut: address(REWARD_TOKEN),
                fee: 3000, // 0.3% fee tier
                recipient: address(this),
                deadline: block.timestamp + 300, // 5 minutes
                amountIn: yieldAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Take protocol fee
        uint256 protocolFee = (rewardReceived * harvestFee) / 10000;
        uint256 userRewards = rewardReceived - protocolFee - 1;

        // Send protocol fee to owner
        if (protocolFee > 0) {
            REWARD_TOKEN.safeTransfer(owner(), protocolFee);
        }

        // Update cumulative reward tokens per share
        if (totalSharesSupply > 0) {
            cumulativeRewardPerShare += (userRewards * 1e18) / totalSharesSupply;
        }

        lastHarvest = block.timestamp;

        emit Harvest(yieldAmount, rewardReceived, protocolFee, cumulativeRewardPerShare);
    }

    function _updateUserRewards(address user) internal {
        UserInfo storage userInfo = users[user];
        userInfo.lastCumulativeRewardPerShare = cumulativeRewardPerShare;
    }

    function _isLocked(address _user) private view returns (bool) {
        return block.timestamp < users[_user].depositTimestamp + lockPeriod;
    }

    function _isHardLocked(address _user) private view returns (bool) {
        return block.timestamp < users[_user].depositTimestamp + hardLockPeriod;
    }

    function _claimableYield(address user) private view returns (uint256) {
        UserInfo memory userInfo = users[user];
        uint256 userShares = balanceOf(user);

        if (userShares == 0) return 0;

        uint256 accumulatedReward = (cumulativeRewardPerShare * userShares) / 1e18;
        uint256 userLastAccumulated = (userInfo.lastCumulativeRewardPerShare * userShares) / 1e18;

        return accumulatedReward - userLastAccumulated;
    }

    function _requireAmountCannotBeZero(uint256 amount) private pure {
        if (!(amount > 0)) revert AmountCannotBeZero();
    }

    function _requireAddressCannotBeZero(address a) private pure {
        if (a == address(0x0)) revert AddressCannotBeZero();
    }

    function _requireTokensNotHardLocked(address _owner) private view {
        if (_isHardLocked(_owner)) revert TokensAreLocked();
    }

    function _requireValidHarvestFee(uint256 _harvestFee) private pure {
        if (_harvestFee > MAX_HARVEST_FEE_BPS) revert FeeTooHigh();
    }

    function _requireValidWithdrawFee(uint256 _withdrawFee) private pure {
        if (_withdrawFee > MAX_WITHDRAW_FEE_BPS) revert FeeTooHigh();
    }

    function _requireHarvester(address harvesterAddress) private view {
        if (!_harvesterSet[harvesterAddress]) revert HarvestingNotAllowed();
    }
}