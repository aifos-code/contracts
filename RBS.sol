// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAETokenRBS is IERC20 {
    function mint(address to, uint256 amount) external;
    function pancakePair() external view returns (address);
}

interface IPancakeRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

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
 * @title AERBS
 * @notice Holds protocol market assets, receives AE sell fees and executes only
 *         fixed AE/USDT PancakeSwap V2 operations.
 */
contract AERBS is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IAETokenRBS public immutable aeToken;
    IERC20 public immutable usdt;
    IPancakeRouterV2 public immutable router;
    address public immutable pair;
    address public immutable depositContract;
    address public immutable marketOperator;
    address public immutable pauseAuthority;
    uint256 public immutable usdtScale;

    bool public paused;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidDeadline();
    error UnsupportedDecimals();
    error ContractPaused();
    error AlreadyPaused();
    error NotPaused();
    error TransferAmountMismatch();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event DepositLiquidityProvided(
        uint256 usdtReceived,
        uint256 usdtSwapped,
        uint256 aeReceived,
        uint256 usdtAdded,
        uint256 aeAdded,
        uint256 liquidity,
        uint256 aeBurned,
        uint256 usdtRetained
    );
    event MarketSwap(bool indexed soldAE, uint256 amountIn, uint256 amountOut);
    event MarketLiquidityAdded(uint256 aeAmount, uint256 usdtAmount, uint256 liquidity);
    event MarketAEBurned(uint256 amount);
    event MarketAEMinted(uint256 amount);

    constructor(
        address marketOperator_,
        address pauseAuthority_,
        address depositContract_,
        address aeToken_,
        address usdt_,
        address router_
    ) {
        if (
            marketOperator_ == address(0) ||
            pauseAuthority_ == address(0) ||
            depositContract_ == address(0) ||
            aeToken_ == address(0) ||
            usdt_ == address(0) ||
            router_ == address(0)
        ) revert InvalidAddress();

        uint8 usdtDecimals = IERC20Metadata(usdt_).decimals();
        if (usdtDecimals > 18) revert UnsupportedDecimals();

        marketOperator = marketOperator_;
        pauseAuthority = pauseAuthority_;
        depositContract = depositContract_;
        aeToken = IAETokenRBS(aeToken_);
        usdt = IERC20(usdt_);
        router = IPancakeRouterV2(router_);
        pair = IAETokenRBS(aeToken_).pancakePair();
        usdtScale = 10 ** (18 - usdtDecimals);
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyMarketOperator() {
        if (msg.sender != marketOperator) revert Unauthorized();
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
     * @notice Pulls one deposit's 70% allocation, swaps half to AE and burns
     *         the resulting LP. Only the immutable deposit contract may call.
     */
    function provideDepositLiquidity(
        uint256 usdtAmount,
        uint256 priceSnapshot,
        uint256 userMinAEOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 liquidity) {
        if (msg.sender != depositContract) revert Unauthorized();
        if (usdtAmount == 0) revert InvalidAmount();
        if (priceSnapshot == 0) revert InvalidPrice();
        if (deadline < block.timestamp) revert InvalidDeadline();

        uint256 usdtBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        if (usdt.balanceOf(address(this)) - usdtBefore != usdtAmount) {
            revert TransferAmountMismatch();
        }

        uint256 swapAmount = usdtAmount / 2;
        uint256 liquidityUSDT = usdtAmount - swapAmount;
        uint256 expectedAE = Math.mulDiv(
            swapAmount,
            usdtScale * 1e18,
            priceSnapshot
        );
        uint256 protocolMinAE = Math.mulDiv(
            expectedAE,
            BPS_DENOMINATOR - MAX_SLIPPAGE_BPS,
            BPS_DENOMINATOR
        );
        uint256 effectiveMinAE = userMinAEOut > protocolMinAE
            ? userMinAEOut
            : protocolMinAE;

        usdt.forceApprove(address(router), swapAmount);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(aeToken);

        uint256 aeBefore = aeToken.balanceOf(address(this));
        router.swapExactTokensForTokens(
            swapAmount,
            effectiveMinAE,
            path,
            address(this),
            deadline
        );
        uint256 aeReceived = aeToken.balanceOf(address(this)) - aeBefore;
        if (aeReceived < effectiveMinAE) revert TransferAmountMismatch();

        usdt.forceApprove(address(router), liquidityUSDT);
        IERC20(address(aeToken)).forceApprove(address(router), aeReceived);
        (uint256 aeAdded, uint256 usdtAdded, uint256 lpAmount) = router.addLiquidity(
            address(aeToken),
            address(usdt),
            aeReceived,
            liquidityUSDT,
            Math.mulDiv(aeReceived, BPS_DENOMINATOR - MAX_SLIPPAGE_BPS, BPS_DENOMINATOR),
            Math.mulDiv(liquidityUSDT, BPS_DENOMINATOR - MAX_SLIPPAGE_BPS, BPS_DENOMINATOR),
            DEAD_ADDRESS,
            deadline
        );

        uint256 aeDust = aeReceived - aeAdded;
        if (aeDust != 0) IERC20(address(aeToken)).safeTransfer(DEAD_ADDRESS, aeDust);

        uint256 usdtRetained = liquidityUSDT - usdtAdded;
        emit DepositLiquidityProvided(
            usdtAmount,
            swapAmount,
            aeReceived,
            usdtAdded,
            aeAdded,
            lpAmount,
            aeDust,
            usdtRetained
        );
        return lpAmount;
    }

    function marketSwap(
        bool sellAE,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external onlyMarketOperator nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (deadline < block.timestamp) revert InvalidDeadline();

        IERC20 tokenIn = sellAE ? IERC20(address(aeToken)) : usdt;
        tokenIn.forceApprove(address(router), amountIn);

        address[] memory path = new address[](2);
        path[0] = sellAE ? address(aeToken) : address(usdt);
        path[1] = sellAE ? address(usdt) : address(aeToken);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline
        );
        amountOut = amounts[amounts.length - 1];
        emit MarketSwap(sellAE, amountIn, amountOut);
    }

    function marketAddLiquidity(
        uint256 aeAmount,
        uint256 usdtAmount,
        uint256 minAE,
        uint256 minUSDT,
        uint256 deadline
    ) external onlyMarketOperator nonReentrant whenNotPaused returns (uint256 liquidity) {
        if (aeAmount == 0 || usdtAmount == 0) revert InvalidAmount();
        if (deadline < block.timestamp) revert InvalidDeadline();

        IERC20(address(aeToken)).forceApprove(address(router), aeAmount);
        usdt.forceApprove(address(router), usdtAmount);
        (uint256 aeAdded, uint256 usdtAdded, uint256 lpAmount) = router.addLiquidity(
            address(aeToken),
            address(usdt),
            aeAmount,
            usdtAmount,
            minAE,
            minUSDT,
            DEAD_ADDRESS,
            deadline
        );
        emit MarketLiquidityAdded(aeAdded, usdtAdded, lpAmount);
        return lpAmount;
    }

    function burnMarketAE(uint256 amount) external onlyMarketOperator whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        IERC20(address(aeToken)).safeTransfer(DEAD_ADDRESS, amount);
        emit MarketAEBurned(amount);
    }

    function mintForMarket(uint256 amount) external onlyMarketOperator whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        aeToken.mint(address(this), amount);
        emit MarketAEMinted(amount);
    }
}
