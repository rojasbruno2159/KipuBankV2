// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ========= IMPORTS =========
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./Types.sol";
import "./Decimals.sol";

/// @title KipuBankV2
/// @notice Multi-asset vault with USD-denominated bank cap using Chainlink feeds.
/// @dev Keeps order: variables → events → errors → functions. Uses checks-effects-interactions.
contract KipuBankV2 is AccessControl {
    using SafeERC20 for IERC20;

    // ========= STATE VARIABLES =========

    // --- Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Global immutable configuration
    uint256 public immutable bankCapUsd;             // Global cap in USD (6 decimals, USDC-based)
    uint256 public immutable withdrawLimitPerTxNative; // Per-transaction limit for native ETH (wei)

    // --- Feeds
    AggregatorV3Interface public immutable ethUsdFeed; // ETH/USD price feed (immutable to save gas)

    // --- Asset registry: token => configuration
    mapping(address => Types.AssetConfig) private assetConfigs;

    // --- Nested balances in USDC decimals (6): token => user => balanceUSDC
    mapping(address => mapping(address => uint256)) private balancesUSDC;

    // --- Counters (smaller types for potential packing)
    uint128 public totalDepositCount;
    uint128 public totalWithdrawCount;

    // --- Total USD accounting (in USDC decimals)
    uint256 public totalUsdDeposits;

    // --- Reentrancy lock
    bool private locked;

    // ========= EVENTS =========

    event DepositedNative(address indexed user, uint256 amountWei, uint256 creditedUSDC);
    event DepositedToken(address indexed user, address indexed token, uint256 amount, uint256 creditedUSDC);
    event WithdrawnNative(address indexed user, uint256 amountWei, uint256 debitedUSDC);
    event WithdrawnToken(address indexed user, address indexed token, uint256 amount, uint256 debitedUSDC);
    event AssetConfigured(address indexed token, address indexed priceFeed, bool enabled);

    // ========= ERRORS =========

    error InvalidValue();
    error Reentrancy();
    error BankCapExceeded(uint256 currentTotalUsd, uint256 attemptedUsd, uint256 capUsd);
    error AssetDisabled(address token);
    error InsufficientBalance(uint256 availableUSDC, uint256 requestedUSDC);
    error WithdrawLimitExceeded(uint256 requested, uint256 limit);
    error TransferFailed(address to, uint256 amount);
    error MissingPriceFeed(address token);

    // ========= FUNCTIONS =========

    // ----- MODIFIERS -----

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @dev Ensures the asset is enabled and has a valid price feed.
    modifier assetEnabled(address token) {
        if (!assetConfigs[token].enabled) revert AssetDisabled(token);
        if (address(assetConfigs[token].priceFeed) == address(0)) revert MissingPriceFeed(token);
        _;
    }

    // ----- CONSTRUCTOR -----

    /// @param _bankCapUsd Global cap in USD (6 decimals, e.g., 1_000_000 = 1 USDC)
    /// @param _withdrawLimitPerTxNative Per-transaction withdrawal limit in wei
    /// @param _ethUsdFeed Chainlink ETH/USD feed address
    constructor(
        uint256 _bankCapUsd,               // Set your USD cap (6 decimals)
        uint256 _withdrawLimitPerTxNative, // Per-transaction native withdraw limit in wei
        address _ethUsdFeed                // ETH/USD feed address (Chainlink)
    ) {
        bankCapUsd = _bankCapUsd;
        withdrawLimitPerTxNative = _withdrawLimitPerTxNative;
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // Register native ETH as an asset for consistency
        assetConfigs[Types.NATIVE_TOKEN] = Types.AssetConfig({
            priceFeed: AggregatorV3Interface(_ethUsdFeed),
            enabled: true
        });

        emit AssetConfigured(Types.NATIVE_TOKEN, _ethUsdFeed, true);
    }

    // ----- ADMIN FUNCTIONS -----

    /// @notice Configure or update a token’s Chainlink feed and enablement.
    /// @param token ERC20 token address (use address(0) for native ETH)
    /// @param priceFeed Chainlink AggregatorV3Interface for TOKEN/USD
    /// @param enabled Whether deposits/withdrawals are allowed
    function setAssetConfig(
        address token,
        address priceFeed,
        bool enabled
    ) external onlyRole(ADMIN_ROLE) {
        assetConfigs[token] = Types.AssetConfig({
            priceFeed: AggregatorV3Interface(priceFeed),
            enabled: enabled
        });
        emit AssetConfigured(token, priceFeed, enabled);
    }

    // ----- EXTERNAL (STATE-CHANGING) -----

    /// @notice Deposit native ETH; credits user balance in USDC units (6 decimals).
    function depositNative()
        external
        payable
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
    {
        if (msg.value == 0) revert InvalidValue();

        // Calculate value once to save gas
        uint256 creditedUSDC = _quoteWeiToUSDC(msg.value);

        // Cap check inline to avoid recalculating
        uint256 newTotal = totalUsdDeposits + creditedUSDC;
        if (newTotal > bankCapUsd) revert BankCapExceeded(totalUsdDeposits, creditedUSDC, bankCapUsd);

        unchecked {
            balancesUSDC[Types.NATIVE_TOKEN][msg.sender] += creditedUSDC;
            totalUsdDeposits = newTotal;
            totalDepositCount++;
        }

        emit DepositedNative(msg.sender, msg.value, creditedUSDC);
    }

    /// @notice Deposit ERC20 token; credits user balance in USDC units (6 decimals).
    function depositToken(address token, uint256 amount)
        external
        nonReentrant
        assetEnabled(token)
    {
        if (amount == 0) revert InvalidValue();

        uint256 creditedUSDC = _quoteTokenToUSDC(token, amount);

        uint256 newTotal = totalUsdDeposits + creditedUSDC;
        if (newTotal > bankCapUsd) revert BankCapExceeded(totalUsdDeposits, creditedUSDC, bankCapUsd);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        unchecked {
            balancesUSDC[token][msg.sender] += creditedUSDC;
            totalUsdDeposits = newTotal;
            totalDepositCount++;
        }

        emit DepositedToken(msg.sender, token, amount, creditedUSDC);
    }

    /// @notice Withdraw native ETH, debiting USDC accounting accordingly.
    /// @param amountWei Amount in wei to withdraw (per-transaction limit applies)
    function withdrawNative(uint256 amountWei)
        external
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
    {
        if (amountWei == 0) revert InvalidValue();
        if (amountWei > withdrawLimitPerTxNative) revert WithdrawLimitExceeded(amountWei, withdrawLimitPerTxNative);

        uint256 debitUSDC = _quoteWeiToUSDC(amountWei);
        uint256 availableUSDC = balancesUSDC[Types.NATIVE_TOKEN][msg.sender];
        if (availableUSDC < debitUSDC) revert InsufficientBalance(availableUSDC, debitUSDC);

        unchecked {
            balancesUSDC[Types.NATIVE_TOKEN][msg.sender] = availableUSDC - debitUSDC;
            totalUsdDeposits -= debitUSDC;
            totalWithdrawCount++;
        }

        (bool success, ) = msg.sender.call{value: amountWei}("");
        if (!success) revert TransferFailed(msg.sender, amountWei);

        emit WithdrawnNative(msg.sender, amountWei, debitUSDC);
    }

    /// @notice Withdraw ERC20 token, debiting USDC accounting accordingly.
    /// @param token ERC20 token address
    /// @param amountToken Amount in token units to withdraw
    function withdrawToken(address token, uint256 amountToken)
        external
        nonReentrant
        assetEnabled(token)
    {
        if (amountToken == 0) revert InvalidValue();

        uint256 debitUSDC = _quoteTokenToUSDC(token, amountToken);
        uint256 availableUSDC = balancesUSDC[token][msg.sender];
        if (availableUSDC < debitUSDC) revert InsufficientBalance(availableUSDC, debitUSDC);

        unchecked {
            balancesUSDC[token][msg.sender] = availableUSDC - debitUSDC;
            totalUsdDeposits -= debitUSDC;
            totalWithdrawCount++;
        }

        IERC20(token).safeTransfer(msg.sender, amountToken);

        emit WithdrawnToken(msg.sender, token, amountToken, debitUSDC);
    }

    // ----- VIEW FUNCTIONS -----

    function getBalanceUSDC(address token, address user) external view returns (uint256) {
        return balancesUSDC[token][user];
    }

    function previewWeiToUSDC(uint256 amountWei) external view returns (uint256) {
        return _quoteWeiToUSDC(amountWei);
    }

    function previewTokenToUSDC(address token, uint256 amount) external view returns (uint256) {
        return _quoteTokenToUSDC(token, amount);
    }

    // ----- INTERNAL HELPERS -----

    function _quoteWeiToUSDC(uint256 amountWei) internal view returns (uint256) {
        (, int256 answer,,,) = ethUsdFeed.latestRoundData();
        uint8 pdec = ethUsdFeed.decimals();
        uint8 usdcDec = Decimals.USDC_DECIMALS;

        uint256 usdP = (amountWei * uint256(answer)) / 1e18;

        if (pdec > usdcDec) {
            return usdP / (10 ** (pdec - usdcDec));
        } else {
            return usdP * (10 ** (usdcDec - pdec));
        }
    }

    function _quoteTokenToUSDC(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface feed = assetConfigs[token].priceFeed;
        (, int256 answer,,,) = feed.latestRoundData();
        uint8 pdec = feed.decimals();
        uint8 tdec = IERC20Metadata(token).decimals();
        uint8 usdcDec = Decimals.USDC_DECIMALS;

        uint256 amountUSDCscale = Decimals.toUSDC(amount, tdec);

        if (pdec > usdcDec) {
            return amountUSDCscale * uint256(answer) / (10 ** (pdec - usdcDec));
        } else {
            return amountUSDCscale * uint256(answer) * (10 ** (usdcDec - pdec));
        }
    }

    // receive/fallback intentionally omitted to enforce use of depositNative()
}
