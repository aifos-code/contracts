// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPancakeV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/**
 * @title AEToken
 * @notice AE with fixed minters, independent mint allowances and an immutable
 *         5% sell fee. RBS and the reward-liquidity contract are the only
 *         fee-exempt addresses; RBS remains the fee receiver.
 */
contract AEToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant BUY_FEE_BPS = 0;
    uint16 public constant SELL_FEE_BPS = 500;

    address public immutable mintAllowanceManager;
    address public immutable rbs;
    address public immutable rewardLiquidityDeposit;
    address public immutable pancakeFactory;
    address public immutable quoteToken;
    address public immutable pancakePair;

    mapping(address minter => bool allowed) public isMinter;
    mapping(address minter => uint256 amount) public canMintAmount;
    mapping(address minter => uint256 amount) public mintedBy;
    mapping(address pair => bool registered) private _isAmmPair;
    mapping(address quote => address pair) public pairForQuoteToken;
    address[] private _minters;
    address[] private _ammPairs;

    /// @notice Lifetime minted amount. Burning never reduces this value.
    uint256 public totalMinted;
    /// @notice Sum of all minters' currently unused allowances.
    uint256 public totalReservedMintAllowance;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error EmptyMinters();
    error DuplicateMinter(address minter);
    error PairAlreadyRegistered(address pair);
    error PairCreationFailed();
    error MintAllowanceExceeded(uint256 requested, uint256 available);
    error MaxSupplyExceeded(uint256 reservedTotal, uint256 maximum);

    event MinterAllowanceSet(
        address indexed minter,
        uint256 previousAmount,
        uint256 newAmount
    );
    event AmmPairAdded(address indexed quoteToken, address indexed pair);

    constructor(
        address[] memory minters_,
        address mintAllowanceManager_,
        address rbs_,
        address rewardLiquidityDeposit_,
        address pancakeFactory_,
        address quoteToken_
    ) ERC20("Agent Economy Token", "AE") {
        if (minters_.length == 0) revert EmptyMinters();
        if (
            mintAllowanceManager_ == address(0) ||
            rbs_ == address(0) ||
            rewardLiquidityDeposit_ == address(0) ||
            pancakeFactory_ == address(0) ||
            quoteToken_ == address(0)
        ) revert InvalidAddress();

        mintAllowanceManager = mintAllowanceManager_;
        rbs = rbs_;
        rewardLiquidityDeposit = rewardLiquidityDeposit_;
        pancakeFactory = pancakeFactory_;
        quoteToken = quoteToken_;

        for (uint256 i; i < minters_.length; ++i) {
            address minter = minters_[i];
            if (minter == address(0)) revert InvalidAddress();
            if (isMinter[minter]) revert DuplicateMinter(minter);
            isMinter[minter] = true;
            _minters.push(minter);
        }

        IPancakeV2Factory factory = IPancakeV2Factory(pancakeFactory_);
        address pair = factory.getPair(address(this), quoteToken_);
        if (pair == address(0)) pair = factory.createPair(address(this), quoteToken_);
        if (pair == address(0) || pair == rbs_) revert PairCreationFailed();
        pancakePair = pair;
        _registerPair(quoteToken_, pair);
    }

    function minters() external view returns (address[] memory) {
        return _minters;
    }

    function isFeeExempt(address account) external view returns (bool) {
        return account == rbs || account == rewardLiquidityDeposit;
    }

    function isAmmPair(address account) external view returns (bool) {
        return _isAmmPair[account];
    }

    function ammPairCount() external view returns (uint256) {
        return _ammPairs.length;
    }

    function ammPairAt(uint256 index) external view returns (address) {
        return _ammPairs[index];
    }

    /**
     * @notice Creates or registers another AE pair through the immutable factory.
     * @dev Registered pairs cannot be removed, preventing selective fee bypasses.
     */
    function registerTaxablePair(address newQuoteToken) external returns (address pair) {
        if (newQuoteToken == address(0) || newQuoteToken == address(this)) {
            revert InvalidAddress();
        }

        IPancakeV2Factory factory = IPancakeV2Factory(pancakeFactory);
        pair = factory.getPair(address(this), newQuoteToken);
        if (pair == address(0)) {
            pair = factory.createPair(address(this), newQuoteToken);
        }
        if (pair == address(0) || pair == rbs) revert PairCreationFailed();
        _registerPair(newQuoteToken, pair);
    }

    /**
     * @notice Replaces one fixed minter's remaining allowance.
     * @dev Lifetime mints plus every unused allowance can never exceed MAX_SUPPLY.
     */
    function setCanMintAmount(address minter, uint256 newAmount) external {
        if (msg.sender != mintAllowanceManager) revert Unauthorized();
        if (!isMinter[minter]) revert Unauthorized();

        uint256 previousAmount = canMintAmount[minter];
        uint256 newReserved = totalReservedMintAllowance - previousAmount + newAmount;
        uint256 reservedTotal = totalMinted + newReserved;
        if (reservedTotal > MAX_SUPPLY) {
            revert MaxSupplyExceeded(reservedTotal, MAX_SUPPLY);
        }

        canMintAmount[minter] = newAmount;
        totalReservedMintAllowance = newReserved;
        emit MinterAllowanceSet(minter, previousAmount, newAmount);
    }

    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert Unauthorized();
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 available = canMintAmount[msg.sender];
        if (amount > available) revert MintAllowanceExceeded(amount, available);

        canMintAmount[msg.sender] = available - amount;
        totalReservedMintAllowance -= amount;
        totalMinted += amount;
        mintedBy[msg.sender] += amount;
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (
            from == address(0) ||
            to == address(0) ||
            from == rbs ||
            to == rbs ||
            from == rewardLiquidityDeposit ||
            to == rewardLiquidityDeposit ||
            !_isAmmPair[to]
        ) {
            super._update(from, to, amount);
            return;
        }

        uint256 feeAmount = (amount * SELL_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount != 0) super._update(from, rbs, feeAmount);
        super._update(from, to, amount - feeAmount);
    }

    function _registerPair(address pairQuoteToken, address pair) private {
        if (_isAmmPair[pair]) revert PairAlreadyRegistered(pair);
        _isAmmPair[pair] = true;
        pairForQuoteToken[pairQuoteToken] = pair;
        _ammPairs.push(pair);
        emit AmmPairAdded(pairQuoteToken, pair);
    }
}
