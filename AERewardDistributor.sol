// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IAETokenRewards {
    function mint(address to, uint256 amount) external;
}

/**
 * @title AERewardDistributor
 * @notice Lets one immutable reward operator mint audited reward batches.
 */
contract AERewardDistributor {
    uint256 public constant MAX_BATCH_SIZE = 200;

    IAETokenRewards public immutable aeToken;
    address public immutable rewardOperator;
    address public immutable pauseAuthority;
    mapping(bytes32 batchId => bool executed) public batchExecuted;
    bool public paused;

    error Unauthorized();
    error InvalidAddress();
    error InvalidBatch();
    error BatchAlreadyExecuted();
    error ContractPaused();
    error AlreadyPaused();
    error NotPaused();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event RewardBatchDistributed(bytes32 indexed batchId, uint256 recipientCount, uint256 totalAmount);

    constructor(address aeToken_, address rewardOperator_, address pauseAuthority_) {
        if (aeToken_ == address(0) || rewardOperator_ == address(0) || pauseAuthority_ == address(0)) {
            revert InvalidAddress();
        }
        aeToken = IAETokenRewards(aeToken_);
        rewardOperator = rewardOperator_;
        pauseAuthority = pauseAuthority_;
    }

    function pause() external {
        if (msg.sender != pauseAuthority) revert Unauthorized();
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != pauseAuthority) revert Unauthorized();
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function distribute(
        bytes32 batchId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        if (msg.sender != rewardOperator) revert Unauthorized();
        if (paused) revert ContractPaused();
        if (batchExecuted[batchId]) revert BatchAlreadyExecuted();
        uint256 length = recipients.length;
        if (batchId == bytes32(0) || length == 0 || length > MAX_BATCH_SIZE || length != amounts.length) {
            revert InvalidBatch();
        }

        batchExecuted[batchId] = true;
        uint256 totalAmount;
        for (uint256 i; i < length; ++i) {
            if (recipients[i] == address(0) || amounts[i] == 0) revert InvalidBatch();
            totalAmount += amounts[i];
            aeToken.mint(recipients[i], amounts[i]);
        }

        emit RewardBatchDistributed(batchId, length, totalAmount);
    }
}
