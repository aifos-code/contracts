// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AEStaking
 * @notice Record-based AE staking with fixed operators and whole-record,
 *         90-day redemptions.
 */
contract AEStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REDEMPTION_BURN_BPS = 3_000;
    uint256 public constant LOCK_DURATION = 90 days;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable aeToken;
    mapping(address operator => bool allowed) public isStakingOperator;
    address[] private _stakingOperators;

    enum StakeStatus { Active, PendingWithdrawal, Withdrawn }

    struct StakeRecord {
        address beneficiary;
        address operator;
        uint256 actualAmount;
        uint256 rewardPrincipal;
        uint64 unlockTime;
        StakeStatus status;
    }

    StakeRecord[] private _stakeRecords;
    mapping(address account => uint256[] recordIds) private _userRecordIds;
    mapping(address account => uint256 amount) public stakedAmount;
    mapping(address account => uint256 amount) public rewardPrincipal;
    uint256 public totalStaked;
    uint256 public totalRewardPrincipal;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error EmptyOperators();
    error DuplicateOperator(address operator);
    error InvalidStakeId();
    error NotBeneficiary();
    error StakeNotActive();
    error WithdrawalNotPending();
    error RedemptionLocked(uint256 unlockTime);
    error TransferAmountMismatch();

    event Staked(uint256 indexed stakeId, address indexed operator, address indexed beneficiary, uint256 actualAmount, uint256 rewardPrincipal);
    event RedemptionRequested(uint256 indexed stakeId, address indexed beneficiary, uint256 actualAmount, uint256 rewardPrincipal, uint256 burnedAmount, uint256 unlockTime);
    event Withdrawn(uint256 indexed stakeId, address indexed beneficiary, uint256 amount);

    constructor(address aeToken_, address[] memory stakingOperators_) {
        if (aeToken_ == address(0)) revert InvalidAddress();
        if (stakingOperators_.length == 0) revert EmptyOperators();
        aeToken = IERC20(aeToken_);

        for (uint256 i; i < stakingOperators_.length; ++i) {
            address operator = stakingOperators_[i];
            if (operator == address(0)) revert InvalidAddress();
            if (isStakingOperator[operator]) revert DuplicateOperator(operator);
            isStakingOperator[operator] = true;
            _stakingOperators.push(operator);
        }
    }

    function stakingOperators() external view returns (address[] memory) {
        return _stakingOperators;
    }

    function stake(address beneficiary, uint256 actualAmount, uint256 rewardPrincipal_) external nonReentrant returns (uint256 stakeId) {
        if (!isStakingOperator[msg.sender]) revert Unauthorized();
        if (beneficiary == address(0)) revert InvalidAddress();
        if (actualAmount == 0 || rewardPrincipal_ == 0) revert InvalidAmount();

        uint256 balanceBefore = aeToken.balanceOf(address(this));
        aeToken.safeTransferFrom(msg.sender, address(this), actualAmount);
        if (aeToken.balanceOf(address(this)) - balanceBefore != actualAmount) revert TransferAmountMismatch();

        stakeId = _stakeRecords.length;
        _stakeRecords.push(StakeRecord({
            beneficiary: beneficiary,
            operator: msg.sender,
            actualAmount: actualAmount,
            rewardPrincipal: rewardPrincipal_,
            unlockTime: 0,
            status: StakeStatus.Active
        }));
        _userRecordIds[beneficiary].push(stakeId);

        stakedAmount[beneficiary] += actualAmount;
        rewardPrincipal[beneficiary] += rewardPrincipal_;
        totalStaked += actualAmount;
        totalRewardPrincipal += rewardPrincipal_;

        emit Staked(stakeId, msg.sender, beneficiary, actualAmount, rewardPrincipal_);
    }

    function requestRedemption(uint256 stakeId) external nonReentrant {
        StakeRecord storage record = _getStakeRecord(stakeId);
        if (record.beneficiary != msg.sender) revert NotBeneficiary();
        if (record.status != StakeStatus.Active) revert StakeNotActive();

        uint256 burnedAmount = (record.actualAmount * REDEMPTION_BURN_BPS) / BPS_DENOMINATOR;
        record.unlockTime = uint64(block.timestamp + LOCK_DURATION);
        record.status = StakeStatus.PendingWithdrawal;

        stakedAmount[msg.sender] -= record.actualAmount;
        rewardPrincipal[msg.sender] -= record.rewardPrincipal;
        totalStaked -= record.actualAmount;
        totalRewardPrincipal -= record.rewardPrincipal;

        aeToken.safeTransferFrom(msg.sender, DEAD_ADDRESS, burnedAmount);

        emit RedemptionRequested(stakeId, msg.sender, record.actualAmount, record.rewardPrincipal, burnedAmount, record.unlockTime);
    }

    function withdraw(uint256 stakeId) external nonReentrant {
        StakeRecord storage record = _getStakeRecord(stakeId);
        if (record.beneficiary != msg.sender) revert NotBeneficiary();
        if (record.status != StakeStatus.PendingWithdrawal) revert WithdrawalNotPending();
        if (block.timestamp < record.unlockTime) revert RedemptionLocked(record.unlockTime);

        record.status = StakeStatus.Withdrawn;
        aeToken.safeTransfer(msg.sender, record.actualAmount);
        emit Withdrawn(stakeId, msg.sender, record.actualAmount);
    }

    function stakeRecordCount() external view returns (uint256) { return _stakeRecords.length; }
    function stakeRecord(uint256 stakeId) external view returns (StakeRecord memory) { return _getStakeRecord(stakeId); }
    function userStakeRecordCount(address account) external view returns (uint256) { return _userRecordIds[account].length; }
    function userStakeRecordIds(address account) external view returns (uint256[] memory) { return _userRecordIds[account]; }

    function _getStakeRecord(uint256 stakeId) private view returns (StakeRecord storage record) {
        if (stakeId >= _stakeRecords.length) revert InvalidStakeId();
        return _stakeRecords[stakeId];
    }
}
