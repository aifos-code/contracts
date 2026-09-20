// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAETokenRewardDeposit is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IAEStakingRewardDeposit {
    function stake(
        address beneficiary,
        uint256 actualAmount,
        uint256 rewardPrincipal
    ) external returns (uint256 stakeId);
}

interface IPancakeRewardRouterV2 {
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/**
 * @title AERewardLiquidityDeposit
 * @notice Mints an authorized AE reward, stakes 80%, and converts the other
 *         20% into permanently burned SOL/AG liquidity.
 */
contract AERewardLiquidityDeposit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant STAKE_BPS = 8_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    IAETokenRewardDeposit public immutable aeToken;
    IERC20 public immutable usdt;
    IERC20 public immutable solToken;
    IERC20 public immutable agToken;
    IAEStakingRewardDeposit public immutable staking;
    IPancakeRewardRouterV2 public immutable router;
    address public immutable rewardOperator;
    address public immutable pauseAuthority;

    bool public paused;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error ContractPaused();
    error AlreadyPaused();
    error NotPaused();
    error TransferAmountMismatch();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event RewardDeposited(
        address indexed operator,
        address indexed beneficiary,
        uint256 aeAmount,
        uint256 stakedAE,
        uint256 rewardPrincipal,
        uint256 marketAE,
        uint256 solReceived,
        uint256 solAdded,
        uint256 agAdded,
        uint256 liquidity,
        uint256 stakeId
    );

    constructor(
        address aeToken_,
        address usdt_,
        address solToken_,
        address agToken_,
        address staking_,
        address router_,
        address rewardOperator_,
        address pauseAuthority_
    ) {
        if (
            aeToken_ == address(0) ||
            usdt_ == address(0) ||
            solToken_ == address(0) ||
            agToken_ == address(0) ||
            staking_ == address(0) ||
            router_ == address(0) ||
            rewardOperator_ == address(0) ||
            pauseAuthority_ == address(0)
        ) revert InvalidAddress();
        if (
            aeToken_ == usdt_ ||
            aeToken_ == solToken_ ||
            aeToken_ == agToken_ ||
            usdt_ == solToken_ ||
            usdt_ == agToken_ ||
            solToken_ == agToken_
        ) revert InvalidAddress();

        aeToken = IAETokenRewardDeposit(aeToken_);
        usdt = IERC20(usdt_);
        solToken = IERC20(solToken_);
        agToken = IERC20(agToken_);
        staking = IAEStakingRewardDeposit(staking_);
        router = IPancakeRewardRouterV2(router_);
        rewardOperator = rewardOperator_;
        pauseAuthority = pauseAuthority_;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
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

    function depositReward(
        uint256 aeAmount,
        address beneficiary
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (msg.sender != rewardOperator) revert Unauthorized();
        if (beneficiary == address(0)) revert InvalidAddress();
        if (aeAmount < 10) revert InvalidAmount();

        uint256 stakedAE = Math.mulDiv(aeAmount, STAKE_BPS, BPS_DENOMINATOR);
        uint256 marketAE = aeAmount - stakedAE;
        if (stakedAE == 0 || marketAE < 2) revert InvalidAmount();

        aeToken.mint(address(this), aeAmount);

        IERC20(address(aeToken)).forceApprove(address(staking), stakedAE);
        stakeId = staking.stake(beneficiary, stakedAE, aeAmount);
        IERC20(address(aeToken)).forceApprove(address(staking), 0);

        uint256 deadline = block.timestamp;
        uint256 solReceived = _swapAEForSOL(marketAE, deadline);
        uint256 solForAG = solReceived / 2;
        uint256 solForLiquidity = solReceived - solForAG;
        if (solForAG == 0 || solForLiquidity == 0) revert InvalidAmount();

        uint256 agReceived = _swapSOLForAG(solForAG, deadline);
        (
            uint256 solAdded,
            uint256 agAdded,
            uint256 liquidity
        ) = _addLiquidity(solForLiquidity, agReceived, deadline);

        uint256 solDust = solForLiquidity - solAdded;
        uint256 agDust = agReceived - agAdded;
        if (solDust != 0) solToken.safeTransfer(DEAD_ADDRESS, solDust);
        if (agDust != 0) agToken.safeTransfer(DEAD_ADDRESS, agDust);

        emit RewardDeposited(
            msg.sender,
            beneficiary,
            aeAmount,
            stakedAE,
            aeAmount,
            marketAE,
            solReceived,
            solAdded,
            agAdded,
            liquidity,
            stakeId
        );
    }

    function _swapAEForSOL(
        uint256 aeAmount,
        uint256 deadline
    ) private returns (uint256 received) {
        address[] memory path = new address[](3);
        path[0] = address(aeToken);
        path[1] = address(usdt);
        path[2] = address(solToken);

        uint256 expected = _quote(aeAmount, path);
        uint256 minimum = Math.mulDiv(
            expected,
            BPS_DENOMINATOR - MAX_SLIPPAGE_BPS,
            BPS_DENOMINATOR
        );

        IERC20(address(aeToken)).forceApprove(address(router), aeAmount);
        uint256 balanceBefore = solToken.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            aeAmount,
            minimum,
            path,
            address(this),
            deadline
        );
        IERC20(address(aeToken)).forceApprove(address(router), 0);

        received = solToken.balanceOf(address(this)) - balanceBefore;
        if (received < minimum) revert TransferAmountMismatch();
    }

    function _swapSOLForAG(
        uint256 solAmount,
        uint256 deadline
    ) private returns (uint256 received) {
        address[] memory path = new address[](2);
        path[0] = address(solToken);
        path[1] = address(agToken);

        uint256 expected = _quote(solAmount, path);
        uint256 minimum = Math.mulDiv(
            expected,
            BPS_DENOMINATOR - MAX_SLIPPAGE_BPS,
            BPS_DENOMINATOR
        );

        solToken.forceApprove(address(router), solAmount);
        uint256 balanceBefore = agToken.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            solAmount,
            minimum,
            path,
            address(this),
            deadline
        );
        solToken.forceApprove(address(router), 0);

        received = agToken.balanceOf(address(this)) - balanceBefore;
        if (received < minimum) revert TransferAmountMismatch();
    }

    function _addLiquidity(
        uint256 solAmount,
        uint256 agAmount,
        uint256 deadline
    ) private returns (uint256 solAdded, uint256 agAdded, uint256 liquidity) {
        solToken.forceApprove(address(router), solAmount);
        agToken.forceApprove(address(router), agAmount);
        (solAdded, agAdded, liquidity) = router.addLiquidity(
            address(solToken),
            address(agToken),
            solAmount,
            agAmount,
            Math.mulDiv(solAmount, BPS_DENOMINATOR - MAX_SLIPPAGE_BPS, BPS_DENOMINATOR),
            Math.mulDiv(agAmount, BPS_DENOMINATOR - MAX_SLIPPAGE_BPS, BPS_DENOMINATOR),
            DEAD_ADDRESS,
            deadline
        );
        solToken.forceApprove(address(router), 0);
        agToken.forceApprove(address(router), 0);
    }

    function _quote(
        uint256 amountIn,
        address[] memory path
    ) private view returns (uint256 amountOut) {
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        if (amounts.length != path.length) revert TransferAmountMismatch();
        amountOut = amounts[amounts.length - 1];
        if (amountOut == 0) revert InvalidAmount();
    }
}
