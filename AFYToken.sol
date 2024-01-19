// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract AFYToken is ERC20, Ownable {
    uint256 private constant TOTAL_SUPPLY = 100_000_000 * 10**18;
    address public developmentWallet;
    address public marketingWallet;
    address public liquidityFund;
    address private uniswapRouterAddress;

    mapping (address => bool) public liquidityPools;
    mapping (address => uint256) private lastTransactionBlock;

    bool public tradingEnabled = false;
    uint256 public tradingStartTime;
    uint256 public launchTime;

    IUniswapV2Router02 public uniswapRouter;
    IWETH public weth;
    IUniswapV2Factory public uniswapFactory; // Uniswap Factory interface

    bool inSwapAndLiquify;
    uint256 public liquidityAdditionThreshold = 500 * 10**18;

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    constructor(
        address initialOwner, 
        address _developmentWallet, 
        address _marketingWallet, 
        address _liquidityFund,
        address _uniswapRouterAddress,
        address _wethAddress,
        address _uniswapFactoryAddress // Add the factory address parameter
    ) ERC20("AFYToken", "AFY") Ownable(initialOwner) {
        developmentWallet = _developmentWallet;
        marketingWallet = _marketingWallet;
        liquidityFund = _liquidityFund;
        uniswapRouterAddress = _uniswapRouterAddress;
        weth = IWETH(_wethAddress);

        tradingStartTime = block.timestamp + 5 minutes;
        launchTime = block.timestamp;
        _mint(initialOwner, TOTAL_SUPPLY);

        uniswapRouter = IUniswapV2Router02(_uniswapRouterAddress);
        uniswapFactory = IUniswapV2Factory(_uniswapFactoryAddress); // Initialize the Uniswap Factory
    }

    function enableTrading() public onlyOwner {
        tradingEnabled = true;
    }

 function transfer(address recipient, uint256 amount) public override returns (bool) {
    bool isOwnerInvolved = (msg.sender == owner() || recipient == owner());
    bool isLiquidityTransfer = liquidityPools[msg.sender] || liquidityPools[recipient];
    bool isBuy = liquidityPools[msg.sender]; // Assuming a buy if the sender is a liquidity pool

    if (!isOwnerInvolved && isLiquidityTransfer) {
        uint256 taxAmount = calculateTax(amount, isBuy);
        uint256 amountAfterTax = amount - taxAmount;
        distributeTax(msg.sender, taxAmount); // msg.sender is the sender in transfer
        amount = amountAfterTax;
    }

    return super.transfer(recipient, amount);
}

function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
    bool isOwnerInvolved = (sender == owner() || recipient == owner());
    bool isLiquidityTransfer = liquidityPools[sender] || liquidityPools[recipient];
    bool isBuy = liquidityPools[sender]; // Assuming a buy if the sender is a liquidity pool

    if (!isOwnerInvolved && isLiquidityTransfer) {
        uint256 taxAmount = calculateTax(amount, isBuy);
        uint256 amountAfterTax = amount - taxAmount;
        distributeTax(sender, taxAmount); // sender is the sender in transferFrom
        amount = amountAfterTax;
    }

    return super.transferFrom(sender, recipient, amount);
}

function _applyTaxAndTransfer(address sender, address recipient, uint256 amount) private returns (uint256) {
    // Apply Buy or Sell Tax based on whether the transaction is a buy or a sell
    if (liquidityPools[recipient]) { // Sell transaction
        amount = applySellTax(sender, recipient, amount);
    } else if (liquidityPools[sender]) { // Buy transaction
        amount = applyBuyTax(sender, recipient, amount);
    } else {
        super._transfer(sender, recipient, amount);
    }
    return amount;
}

    function applyBuyTax(address sender, address recipient, uint256 amount) private returns (uint256) {
        uint256 tax = calculateTax(amount, true);
        uint256 amountAfterTax = amount - tax;
        distributeTax(sender, tax);
        return amountAfterTax;
    }

    function applySellTax(address sender, address recipient, uint256 amount) private returns (uint256) {
        uint256 tax = calculateTax(amount, false);
        uint256 amountAfterTax = amount - tax;
        distributeTax(sender, tax);
        return amountAfterTax;
    }

    function distributeTax(address sender, uint256 tax) private {
        uint256 devAmount = tax * 2 / 5;  // 40% of tax
        uint256 marketingAmount = tax * 2 / 5;  // 40% of tax
        uint256 liquidityAmount = tax / 5;  // 20% of tax
        super._transfer(sender, developmentWallet, devAmount);
        super._transfer(sender, marketingWallet, marketingAmount);
        super._transfer(sender, liquidityFund, liquidityAmount); // for liquidity
    }

    function calculateTax(uint256 amount, bool isBuy) private view returns (uint256) {
        if (block.timestamp < launchTime + 30 minutes) {
            return amount * (isBuy ? 5 : 20) / 100;
        } else if (block.timestamp < launchTime + 24 hours) {
            return amount * (isBuy ? 5 : 10) / 100;
        } else {
            return amount * 5 / 100;
        }
    }

    function setLiquidityPool(address pool, bool status) public onlyOwner {
        liquidityPools[pool] = status;
    }

    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        require(recipients.length == amounts.length, "Mismatch between recipient and amount length");
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }
    }

    function burnSpecificAmount(uint256 amount) external onlyOwner {
        require(amount > 0 && amount <= balanceOf(msg.sender), "Invalid or excessive amount");
        _burn(msg.sender, amount);
    }

    // Function to create a Uniswap pair
    function createUniswapPair() external onlyOwner {
        require(address(uniswapFactory) != address(0), "Uniswap Factory address not set");
        
        // Create the pair
        uniswapFactory.createPair(address(this), uniswapRouter.WETH());
    }

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    function shouldSwapAndLiquify(address sender) internal view returns (bool) {
        return
            !inSwapAndLiquify &&
            tradingEnabled &&
            sender != uniswapRouterAddress &&
            balanceOf(address(this)) >= liquidityAdditionThreshold;
    }

    function swapAndLiquify() private lockTheSwap {
        uint256 half = liquidityAdditionThreshold / 2;
        uint256 otherHalf = liquidityAdditionThreshold - half;
        uint256 initialBalance = address(this).balance;
        swapTokensForEth(half);
        uint256 newBalance = address(this).balance - initialBalance;
        addLiquidity(otherHalf, newBalance);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();
        _approve(address(this), address(uniswapRouter), tokenAmount);
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(uniswapRouter), tokenAmount);
        uniswapRouter.addLiquidityETH{value: ethAmount}(
            address(this), 
            tokenAmount, 
            0, 
            0, 
            owner(), 
            block.timestamp
        );
    }

    function withdrawETH(uint256 amount) external onlyOwner {
    require(amount <= address(this).balance, "Insufficient balance");
    payable(owner()).transfer(amount);
}

function swapETHForTokens(uint256 minTokens) private {
    address[] memory path = new address[](2);
    path[0] = uniswapRouter.WETH();
    path[1] = address(this);

    uniswapRouter.swapExactETHForTokens{value: address(this).balance}(
        minTokens,
        path,
        address(this),
        block.timestamp
    );
}

function addETHToLiquidity(uint256 minTokensToAdd) external onlyOwner payable {
    // First, swap half of the ETH for tokens
    swapETHForTokens(minTokensToAdd);

    uint256 tokenAmount = balanceOf(address(this));
    uint256 ethAmount = address(this).balance;

    // Approve token transfer to cover all possible scenarios
    _approve(address(this), address(uniswapRouter), tokenAmount);

    // Add liquidity
    uniswapRouter.addLiquidityETH{value: ethAmount}(
        address(this),
        tokenAmount,
        0, // Set slippage tolerance as needed
        0, // Set slippage tolerance as needed
        owner(),
        block.timestamp
    );
}
    receive() external payable {}
}
