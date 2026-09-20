// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAETokenDeposit is IERC20 {
    function mint(address to, uint256 amount) external;
    function pancakePair() external view returns (address);
}

interface IAEStakingDeposit {
    function stake(address beneficiary, uint256 actualAmount, uint256 rewardPrincipal) external returns (uint256 stakeId);
}

interface IAERBSDeposit {
    function provideDepositLiquidity(uint256 usdtAmount, uint256 priceSnapshot, uint256 userMinAEOut, uint256 deadline) external returns (uint256 liquidity);
}

interface IPancakePairPrice {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/**
 * @title AEDeposit
 * @notice Processes USDT deposits atomically into the fixed 30% receiver,
 *         burned liquidity and a beneficiary AE stake.
 */
contract AEDeposit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant RECEIVER_BPS = 3_000;
    uint256 public constant Q112 = 2 ** 112;
    uint256 public constant MIN_TWAP_PERIOD = 30 minutes;
    uint256 public constant MAX_PRICE_AGE = 2 hours;

    IERC20 public immutable usdt;
    IAETokenDeposit public immutable aeToken;
    IAEStakingDeposit public immutable staking;
    IAERBSDeposit public immutable rbs;
    IPancakePairPrice public immutable pancakePair;
    address public immutable paymentReceiver;
    address public immutable directStakeOperator;
    address public immutable pauseAuthority;
    uint256 public immutable usdtScale;
    uint256 public immutable minimumDeposit;
    bool public immutable aeIsToken0;

    uint256 private _priceCumulativeLast;
    uint32 private _priceTimestampLast;
    uint256 private _averagePriceX112;
    uint64 public lastPriceUpdate;

    bool public paused;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidPrice();
    error PriceNotReady();
    error StalePrice();
    error TwapPeriodTooShort();
    error InvalidDeadline();
    error UnsupportedDecimals();
    error ContractPaused();
    error AlreadyPaused();
    error NotPaused();
    error TransferAmountMismatch();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event PriceUpdated(uint256 price, uint256 elapsed, uint256 timestamp);
    event DirectStakeDeposited(
        address indexed operator,
        address indexed beneficiary,
        uint256 aeAmount,
        uint256 rewardPrincipal,
        uint256 stakeId
    );
    event Deposited(
        address indexed account,
        uint256 usdtAmount,
        uint256 receiverAmount,
        uint256 liquidityUSDT,
        uint256 priceSnapshot,
        uint256 stakedAE,
        uint256 rewardPrincipal,
        uint256 stakeId,
        uint256 liquidity
    );

    constructor(
        address usdt_,
        address aeToken_,
        address staking_,
        address rbs_,
        address paymentReceiver_,
        address directStakeOperator_,
        address pauseAuthority_
    ) {
        if (
            usdt_ == address(0) ||
            aeToken_ == address(0) ||
            staking_ == address(0) ||
            rbs_ == address(0) ||
            paymentReceiver_ == address(0) ||
            directStakeOperator_ == address(0) ||
            pauseAuthority_ == address(0)
        ) revert InvalidAddress();

        uint8 usdtDecimals = IERC20Metadata(usdt_).decimals();
        if (usdtDecimals > 18) revert UnsupportedDecimals();

        usdt = IERC20(usdt_);
        aeToken = IAETokenDeposit(aeToken_);
        staking = IAEStakingDeposit(staking_);
        rbs = IAERBSDeposit(rbs_);
        paymentReceiver = paymentReceiver_;
        directStakeOperator = directStakeOperator_;
        pauseAuthority = pauseAuthority_;
        usdtScale = 10 ** (18 - usdtDecimals);
        minimumDeposit = 100 * (10 ** usdtDecimals);

        address pairAddress = IAETokenDeposit(aeToken_).pancakePair();
        if (pairAddress == address(0)) revert InvalidAddress();
        IPancakePairPrice pair = IPancakePairPrice(pairAddress);
        address token0 = pair.token0();
        address token1 = pair.token1();
        if (
            !(
                (token0 == aeToken_ && token1 == usdt_) ||
                (token0 == usdt_ && token1 == aeToken_)
            )
        ) revert InvalidAddress();
        pancakePair = pair;
        aeIsToken0 = token0 == aeToken_;
        (_priceCumulativeLast, _priceTimestampLast) = _currentCumulativePrice();
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

    /**
     * @notice Updates the AE/USDT TWAP from Pancake's cumulative pair price.
     * @dev Permissionless so no privileged oracle operator is required.
     */
    function updatePrice() external returns (uint256 price) {
        (uint256 currentCumulative, uint32 currentTimestamp) = _currentCumulativePrice();
        uint32 elapsed;
        uint256 cumulativeDelta;
        unchecked {
            elapsed = currentTimestamp - _priceTimestampLast;
            cumulativeDelta = currentCumulative - _priceCumulativeLast;
        }
        if (elapsed < MIN_TWAP_PERIOD) revert TwapPeriodTooShort();

        uint256 averagePriceX112 = cumulativeDelta / elapsed;
        if (averagePriceX112 == 0) revert InvalidPrice();

        _averagePriceX112 = averagePriceX112;
        _priceCumulativeLast = currentCumulative;
        _priceTimestampLast = currentTimestamp;
        lastPriceUpdate = uint64(block.timestamp);

        price = _priceFromAverage(averagePriceX112);
        emit PriceUpdated(price, elapsed, block.timestamp);
    }

    /**
     * @return price AE price in USDT with 18-decimal precision.
     */
    function aePrice() public view returns (uint256 price) {
        if (_averagePriceX112 == 0) revert PriceNotReady();
        if (block.timestamp > uint256(lastPriceUpdate) + MAX_PRICE_AGE) {
            revert StalePrice();
        }
        return _priceFromAverage(_averagePriceX112);
    }

    function deposit(
        uint256 amount,
        uint256 minAEOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (amount < minimumDeposit) revert InvalidAmount();
        if (deadline < block.timestamp) revert InvalidDeadline();

        uint256 priceSnapshot = aePrice();

        uint256 balanceBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        if (usdt.balanceOf(address(this)) - balanceBefore != amount) {
            revert TransferAmountMismatch();
        }

        uint256 receiverAmount = Math.mulDiv(amount, RECEIVER_BPS, BPS_DENOMINATOR);
        uint256 liquidityUSDT = amount - receiverAmount;
        usdt.safeTransfer(paymentReceiver, receiverAmount);

        usdt.forceApprove(address(rbs), liquidityUSDT);
        uint256 liquidity = rbs.provideDepositLiquidity(
            liquidityUSDT,
            priceSnapshot,
            minAEOut,
            deadline
        );

        uint256 mintedAE = Math.mulDiv(
            liquidityUSDT,
            usdtScale * 1e18,
            priceSnapshot
        );
        uint256 principal = amount * usdtScale;
        if (mintedAE == 0 || principal == 0) revert InvalidAmount();

        aeToken.mint(address(this), mintedAE);
        IERC20(address(aeToken)).forceApprove(address(staking), mintedAE);
        stakeId = staking.stake(msg.sender, mintedAE, principal);

        emit Deposited(
            msg.sender,
            amount,
            receiverAmount,
            liquidityUSDT,
            priceSnapshot,
            mintedAE,
            principal,
            stakeId,
            liquidity
        );
    }

    /**
     * @notice Pulls AE from the fixed operator and stakes it for a beneficiary.
     * @dev The operator must approve AEDeposit first. No AE is minted by this flow.
     */
    function stakeFromOperator(
        address beneficiary,
        uint256 aeAmount,
        uint256 rewardPrincipal
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (msg.sender != directStakeOperator) revert Unauthorized();
        if (beneficiary == address(0)) revert InvalidAddress();
        if (aeAmount == 0 || rewardPrincipal == 0) revert InvalidAmount();

        uint256 balanceBefore = aeToken.balanceOf(address(this));
        IERC20(address(aeToken)).safeTransferFrom(
            msg.sender,
            address(this),
            aeAmount
        );
        if (aeToken.balanceOf(address(this)) - balanceBefore != aeAmount) {
            revert TransferAmountMismatch();
        }

        IERC20(address(aeToken)).forceApprove(address(staking), aeAmount);
        stakeId = staking.stake(beneficiary, aeAmount, rewardPrincipal);
        IERC20(address(aeToken)).forceApprove(address(staking), 0);

        emit DirectStakeDeposited(
            msg.sender,
            beneficiary,
            aeAmount,
            rewardPrincipal,
            stakeId
        );
        emit Deposited(
            beneficiary,
            0,
            0,
            0,
            0,
            aeAmount,
            rewardPrincipal,
            stakeId,
            0
        );
    }


    function _priceFromAverage(
        uint256 averagePriceX112
    ) private view returns (uint256) {
        return Math.mulDiv(averagePriceX112, usdtScale * 1e18, Q112);
    }

    function _currentCumulativePrice()
        private
        view
        returns (uint256 cumulativePrice, uint32 currentTimestamp)
    {
        cumulativePrice = aeIsToken0
            ? pancakePair.price0CumulativeLast()
            : pancakePair.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 pairTimestamp) = pancakePair
            .getReserves();
        currentTimestamp = uint32(block.timestamp);

        if (pairTimestamp != currentTimestamp && reserve0 != 0 && reserve1 != 0) {
            uint32 elapsed;
            unchecked {
                elapsed = currentTimestamp - pairTimestamp;
                uint256 priceX112 = aeIsToken0
                    ? (uint256(reserve1) << 112) / reserve0
                    : (uint256(reserve0) << 112) / reserve1;
                cumulativePrice += priceX112 * elapsed;
            }
        }
    }
}
