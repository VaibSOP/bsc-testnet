// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";

// Interface for interacting with PancakeSwap Router
interface IPancakeRouter {
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

    // Swaps Tokens with Other Tokens
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// Interface for interacting with PancakeSwap liquidity pool
interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

// Extended ERC20 interface for approving token spending
interface IERC20UpgradeableExt is IERC20Upgradeable {
    function approve(address spender, uint256 amount) external returns (bool);
}

// Main Contract - SECURED using ReEntrancyGuardUpgradeable
contract GreenHaze is ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Constants for pricing thresholds and fees and security
    uint256 public constant PRICE_THRESHOLD = 1e18; // $1.00
    uint256 public constant PRICE_FLOOR = 1e16; // $0.01
    uint256 public constant FEE_RATE = 6; // 6% liquidity tax
    uint256 public constant USDT_SHARE = 4; // 4% USDT Stablecoin
    uint256 public constant BNB_SHARE = 2; // 2% BNB for gas
    uint256 public constant TREASURY_RATE = 5; // 0.5% Treasury per $0.01 increase
    uint256 public constant SUPPLY_FLOOR = 15; // 15% auto-mint trigger
    uint256 public constant MINT_COOLDOWN = 60; // 60 seconds
    uint256 public constant EXTRA_MINT_PERCENT = 30; // 30% extra mint when supply is low

    // Contract state variables
    address public treasuryWallet;
    address public pancakeRouterAddress;
    address public stablecoinAddress;
    address public bnbAddress;
    IPancakeRouter public pancakeRouter;
    IPancakePair public tokenStablePair;
    uint256 public lastPriceCheckpoint;
    bool public hasMintedSupplyFloor;
    uint256 public lastMintTime;

    // Events for logging important actions
    event SplitTriggered(uint256 mintedAmount);
    event TreasuryFunded(uint256 amount);
    event TokensBurned(uint256 amount);
    event ExtraSupplyMinted(uint256 amount);
    event LiquidityAdded(uint256 tokenAmount, uint256 stablecoinAmount);
    event GasBNBStored(uint256 amount);
    event TokensSwappedForUSDT(uint256 amount);
    event TokensSwappedForBNB(uint256 amount);
    event MintedToResetPrice(uint256 amount);
    event SupplyFloorMinted(uint256 amount);

    // Contract initializer function
    function initialize(
        address _owner,
        address _router,
        address _stablecoin,
        address _bnb
    ) public initializer {
        __ERC20_init("Green Haze", "GREENHAZE");
        __Ownable_init();
        __ReentrancyGuard_init();

        _mint(_owner, 10_000_000 * 10 ** decimals());
        pancakeRouterAddress = _router;
        pancakeRouter = IPancakeRouter(_router);
        stablecoinAddress = _stablecoin;
        bnbAddress = _bnb;
        lastPriceCheckpoint = PRICE_FLOOR; // $0.01 initial checkpoint
    }

    // Function to set the token-stablecoin pair address
    function setTokenStablePair(address _pair) external onlyOwner {
        require(_pair != address(0), "Invalid pair address");
        tokenStablePair = IPancakePair(_pair);
    }

    // New setter function to manually set the treasury wallet address
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != address(0), "Invalid treasury address");
        treasuryWallet = _treasuryWallet;
    }

    // Set decimals to 2 (tick size 0.01)
    function decimals() public view virtual override returns (uint8) {
        return 2; // Tick size of 0.01
    }

    // Override transfer function to include fee processing and price checks
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _processFees(_msgSender(), amount);
        _checkPriceAdjustments();
        uint256 transferAmount = _calculateTransferAmount(amount);
        _transfer(_msgSender(), recipient, transferAmount);
        return true;
    }

    // Process liquidity tax and swap tokens for USDT and BNB
    function _processFees(address sender, uint256 amount) private {
        uint256 totalFee = (amount * FEE_RATE) / 100;
        uint256 usdtAmount = (totalFee * USDT_SHARE) / FEE_RATE;
        uint256 bnbAmount = totalFee - usdtAmount;

        _transfer(sender, address(this), totalFee);
        _swapTokensForUSDT(usdtAmount);
        _swapTokensForBNB(bnbAmount);
        _addLiquidity();
    }

    // Swap tokens for USDT - Secured using nonReentrant() and safeApprove()
    function _swapTokensForUSDT(uint256 amount) private nonReentrant {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = stablecoinAddress;
        IERC20Upgradeable(address(this)).safeApprove(pancakeRouterAddress, amount);
        pancakeRouter.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
        emit TokensSwappedForUSDT(amount);
    }

    // Swap tokens for BNB - Secured using nonReentrant() and safeApprove()
    function _swapTokensForBNB(uint256 amount) private nonReentrant {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = bnbAddress;
        IERC20Upgradeable(address(this)).safeApprove(pancakeRouterAddress, amount);
        pancakeRouter.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
        emit TokensSwappedForBNB(amount);
    }

    // Calculate Fees per Transaction
    function _calculateTransferAmount(uint256 amount) private pure returns (uint256) {
        uint256 totalFee = (amount * FEE_RATE) / 100;
        return amount - totalFee;
    }

    // Add liquidity to PancakeSwap pool & Burn LP Tokens - SECURED using safeIncreaseAllowance()
    function _addLiquidity() private nonReentrant {
        uint256 tokenBalance = balanceOf(address(this));
        uint256 stableBalance = IERC20Upgradeable(stablecoinAddress).balanceOf(address(this));

        if (tokenBalance > 0 && stableBalance > 0) {
            IERC20Upgradeable(address(this)).safeIncreaseAllowance(pancakeRouterAddress, tokenBalance);
            IERC20Upgradeable(stablecoinAddress).safeIncreaseAllowance(pancakeRouterAddress, stableBalance);
            (,, uint256 liquidity) = pancakeRouter.addLiquidity(
                address(this),
                stablecoinAddress,
                tokenBalance,
                stableBalance,
                0,
                0,
                address(this),
                block.timestamp
            );

            // Burn the LP tokens
            IERC20Upgradeable(address(tokenStablePair)).safeTransfer(0x000000000000000000000000000000000000dEaD, liquidity);

            emit LiquidityAdded(tokenBalance, stableBalance);
            emit TokensBurned(liquidity); // Log LP token burn
        }
    }

    // Check price adjustments and trigger dynamic mechanisms
    function _checkPriceAdjustments() private {
        (uint112 reserve0, uint112 reserve1,) = tokenStablePair.getReserves();
        uint256 price = (reserve1 * 1e18) / reserve0;

        // Transfer 0.5% of reserve tokens to treasury on every $0.01 price increase
        if (price > lastPriceCheckpoint + PRICE_FLOOR) {
            uint256 remainingReserveTokens = reserve0 - balanceOf(treasuryWallet);  // Exclude treasury balance
            uint256 treasuryAmount = remainingReserveTokens / 200; // 0.5% of remaining reserve

            if (treasuryAmount > 0) {
                _transfer(address(this), treasuryWallet, treasuryAmount);
                emit TreasuryFunded(treasuryAmount);
            }

            lastPriceCheckpoint = price;
        }

        // Dynamic Mint Ceiling: Mint tokens to reset price to $0.01 if it reaches $1.00
        if (price >= PRICE_THRESHOLD) {
            _mintToResetPrice();
        }

        // Dynamic Burn Floor: Burn excess tokens to restore price to $0.01
        if (price < PRICE_FLOOR) {
            uint256 requiredTokens = (reserve1 * 1e18) / PRICE_FLOOR;
            uint256 excessTokens = reserve0 - requiredTokens;

            if (excessTokens > 0) {
                uint256 burnAmount = excessTokens > balanceOf(address(this)) ? balanceOf(address(this)) : excessTokens;
                _burn(address(this), burnAmount);
                emit TokensBurned(burnAmount);
            }
        }

        // Dynamic Supply Floor: Auto-mint 30% extra when total supply hits 15% of reserves
        uint256 supplyFloorThreshold = (reserve0 * SUPPLY_FLOOR) / 100;
        if (totalSupply() <= supplyFloorThreshold && !hasMintedSupplyFloor) {
            uint256 mintAmount = (totalSupply() * EXTRA_MINT_PERCENT) / 100; // Mint 30% extra tokens
            _mint(address(this), mintAmount);
            hasMintedSupplyFloor = true;
            emit SupplyFloorMinted(mintAmount);
        }

        // Reset flag if supply recovers above 15% threshold
        if (totalSupply() > supplyFloorThreshold) {
            hasMintedSupplyFloor = false;
        }
    }

    // Mint tokens to reset price to $0.01 if it reaches $1.00
    function _mintToResetPrice() internal {
        require(block.timestamp >= lastMintTime + MINT_COOLDOWN, "Minting too soon");

        (uint112 reserve0, uint112 reserve1, ) = tokenStablePair.getReserves();
        uint256 tokenReserves = uint256(reserve0);
        uint256 stableReserves = uint256(reserve1);

        if (tokenReserves == 0 || stableReserves == 0) return;

        // Calculate how many tokens are needed to reset the price to $0.01
        uint256 requiredTokens = (stableReserves / PRICE_FLOOR) * 1e18; // Ensures new ratio is correct

        if (requiredTokens > tokenReserves) {
            uint256 mintAmount = requiredTokens - tokenReserves;

            // Mint the tokens to the contract
            _mint(address(this), mintAmount);
            emit MintedToResetPrice(mintAmount);

            // Inject these tokens into the liquidity pool
            _addLiquidity();

            // Update the last mint time
            lastMintTime = block.timestamp;
        }
    }
}

