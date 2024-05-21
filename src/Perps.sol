// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/interfaces/feeds/AggregatorV3Interface.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/utils/math/SignedMath.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract PerpsEvents {
    event LiquidityAdded(address indexed lp, uint256 amount);
    event LiquidityRemoved(address indexed lp, uint256 amount);
    event PositionOpened(address indexed trader, uint256 size, uint256 collateral, bool isLong);
    event PositionIncreased(address indexed trader, uint256 sizeIncrease, uint256 collateralIncrease);
    event PositionDecreased(address indexed trader, uint256 sizeDecrease, uint256 collateralDecrease);
}

contract Perps is PerpsEvents, ERC4626 {

    /*//////////////////////////////////////////////////////////////
                          Custom Data Types
    //////////////////////////////////////////////////////////////*/

    enum Token {
        Index,
        Collateral
    }

    struct Position {
        uint256 size; // in index token with native decimals
        uint256 collateral; // in collateral token with native decimals
        uint256 averagePrice; // in USD with 1e30 precision
        uint256 lastUpdated; // timestamp
        bool isLong;
    }

    /*//////////////////////////////////////////////////////////////
                              Libraries
    //////////////////////////////////////////////////////////////*/

    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                              Constants
    //////////////////////////////////////////////////////////////*/

    uint256 public constant USD_PRECISION = 1e30;
    uint256 public constant MAX_UTILIZATION_PERCENTAGE = 75;
    uint256 public constant MAX_LEVERAGE = 15;
    uint256 public constant BORROWING_FEE_RATE = 315_360_000; // 10% total size per year

    /*//////////////////////////////////////////////////////////////
                           State Variables
    //////////////////////////////////////////////////////////////*/

    ERC20 public immutable collateralToken;

    mapping(Token => AggregatorV3Interface) public pricefeed;
    mapping(Token => uint256) public additionalFeedPrecision;
    mapping(Token => uint256) public toToken;
    mapping(Token => uint256) public toUsd;

    mapping(address => Position) private positions;
    uint256 public openInterestLong; // in COLLATERAL
    uint256 public openInterestShort; // in COLLATERAL token
    uint256 public totalCollateral; // in collateral token

    /*//////////////////////////////////////////////////////////////
                            Custom Errors
    //////////////////////////////////////////////////////////////*/

    error Perps__UnsupportedOperation();
    error Perps__PositionDoesNotExist();
    error Perps__InsufficientSize();
    error Perps__InsufficientCollateral();
    error Perps__TraderHasOpenPosition();
    error Perps__InsufficientLiquidity();
    error Perps__MaxLeverageExceeded();
    error Perps__NoIncrease();
    error Perps__NoDecrease();
    error Perps__PositionNotLiquidatable();
    error Perps__SelfLiquidationProhibited();

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier checkAvailableLiquidity() {
        _;
        if (getReservedLiquidity() > getMaxUtilization()) {
            revert Perps__InsufficientLiquidity();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(
        ERC20 _collateralToken,
        string memory _name,
        string memory _symbol,
        address _indexPricefeed,
        address _collateralPricefeed,
        uint8 _indexTokenDecimals
    ) 
        ERC4626(_collateralToken)
        ERC20(_name, _symbol)
    {
        collateralToken = ERC20(_collateralToken);
        AggregatorV3Interface indexPricefeed = AggregatorV3Interface(_indexPricefeed);
        AggregatorV3Interface collateralPricefeed = AggregatorV3Interface(_collateralPricefeed);
        uint8 indexPricefeedDecimals = indexPricefeed.decimals();
        uint8 collateralPricefeedDecimals = collateralPricefeed.decimals();
        pricefeed[Token.Index] = indexPricefeed;
        pricefeed[Token.Collateral] = collateralPricefeed;
        additionalFeedPrecision[Token.Index] = 10**(30 - indexPricefeedDecimals);
        additionalFeedPrecision[Token.Collateral] = 10**(30 - collateralPricefeedDecimals);
        toToken[Token.Index] = 10**(30 - _indexTokenDecimals);
        toToken[Token.Collateral] = 10**(30 - collateralToken.decimals());
        toUsd[Token.Index] = 10**(_indexTokenDecimals);
        toUsd[Token.Collateral] = 10**(collateralToken.decimals());
    }

    /*//////////////////////////////////////////////////////////////
                              Pricefeed
    //////////////////////////////////////////////////////////////*/

    /**
     * @return usd with 1e30 precision 
     */
    function getPrice(Token token) public view returns (uint256) {
        (, int256 answer,,,) = pricefeed[token].latestRoundData();
        return answer.toUint256() * additionalFeedPrecision[token]; 
    }

    /**
     * @param usdAmount with 1e30 precision
     * @param token token to convert to
     * @param tokenPrice usd price with 1e30 precision
     * @return amount of token in native token precision
     */
    function getAmountInTokens(uint256 usdAmount, Token token, uint256 tokenPrice) public view returns (uint256) {
        return (usdAmount * USD_PRECISION / tokenPrice) / toToken[token];
    }

    /**
     * @param tokenAmount in native token decimals
     * @param token type of token to convert to usd 
     * @param tokenPrice usd price with 1e30 precision
     * @return amount in usd with 1e30 precision
     */
    function getUsdValue(uint256 tokenAmount, Token token, uint256 tokenPrice) public view returns (uint256) {
        return (tokenAmount * tokenPrice) / toUsd[token];
    }

    /**
     * @param inputTokenAmount in native token decimals
     * @param inputToken token to convert from
     * @param inputTokenPrice in usd with 1e30 precision
     * @param outputTokenPrice in usd with 1e30 precision
     * @return amount in output token with native token decimals
     */
    function convertToken(
        uint256 inputTokenAmount, 
        Token inputToken, 
        uint256 inputTokenPrice, 
        uint256 outputTokenPrice
    )
        public 
        view 
        returns (uint256) 
    {
        uint256 inputTokenAmountInUsd = getUsdValue(inputTokenAmount, inputToken, inputTokenPrice);
        Token outputToken = inputToken == Token.Index ? Token.Collateral : Token.Index;
        return getAmountInTokens(inputTokenAmountInUsd, outputToken, outputTokenPrice);
    }

    /*//////////////////////////////////////////////////////////////
                              Liquidity
    //////////////////////////////////////////////////////////////*/
    
    function addLiquidity(uint256 amount) external returns (uint256 shares) {
        shares = super.deposit(amount, msg.sender);
        emit LiquidityAdded(msg.sender, amount);
    }
    
    function removeLiquidity(uint256 shares) external checkAvailableLiquidity returns (uint256 amount) {
        amount = super.redeem(shares, msg.sender, msg.sender);
        emit LiquidityRemoved(msg.sender, amount); 
    }

    /*//////////////////////////////////////////////////////////////
                               Position
    //////////////////////////////////////////////////////////////*/

    /**
     * @param size in index token 
     * @param collateral in collateral token
     */
    function openPosition(
        uint256 size, 
        uint256 collateral, 
        bool isLong
    ) 
        external 
        checkAvailableLiquidity    
    {
        if (size <= 0) revert Perps__InsufficientSize();
        if (collateral <= 0) revert Perps__InsufficientCollateral();

        Position memory position = positions[msg.sender];
        if (position.collateral > 0) revert Perps__TraderHasOpenPosition();

        uint256 indexPrice = getPrice(Token.Index);
        uint256 collateralPrice = getPrice(Token.Collateral);
        _updateOpenInterest(size.toInt256(), isLong, indexPrice, collateralPrice);
        totalCollateral += collateral;

        position.size = size;
        position.collateral = collateral;
        position.averagePrice = indexPrice;
        position.lastUpdated = block.timestamp;
        position.isLong = isLong;
        if (calculateLeverage(position, indexPrice, collateralPrice) > MAX_LEVERAGE) revert Perps__MaxLeverageExceeded();
        
        positions[msg.sender] = position;
        
        collateralToken.safeTransferFrom(msg.sender, address(this), collateral);

        emit PositionOpened(msg.sender, size, collateral, isLong);
    }

    function increasePosition(uint256 sizeIncrease, uint256 collateralIncrease) external checkAvailableLiquidity {
        if (sizeIncrease == 0 && collateralIncrease == 0) revert Perps__NoIncrease();
        Position memory position = getPosition(msg.sender);
        uint256 indexPrice = getPrice(Token.Index);
        uint256 collateralPrice = getPrice(Token.Collateral);

        _applyBorrowingFee(position, collateralPrice);
        
        if (sizeIncrease > 0) {
            uint256 newAvgPrice = calculateAveragePrice(position.size, position.averagePrice, indexPrice, sizeIncrease);
            position.averagePrice = newAvgPrice;        
            position.size += sizeIncrease;
            _updateOpenInterest(sizeIncrease.toInt256(), position.isLong, indexPrice, collateralPrice);
        }
        if (collateralIncrease > 0) {
            position.collateral += collateralIncrease;
            totalCollateral += collateralIncrease;
            collateralToken.safeTransferFrom(msg.sender, address(this), collateralIncrease);
        }

        if (calculateLeverage(position, indexPrice, collateralPrice) > MAX_LEVERAGE) revert Perps__MaxLeverageExceeded();

        positions[msg.sender] = position;

        emit PositionIncreased(msg.sender, sizeIncrease, collateralIncrease);
    }

    function decreasePosition(uint256 sizeDecrease, uint256 collateralDecrease) external {
        if (sizeDecrease <= 0 && collateralDecrease <= 0) revert Perps__NoDecrease();
        Position memory position = getPosition(msg.sender);
        uint256 indexPrice = getPrice(Token.Index);
        uint256 collateralPrice = getPrice(Token.Collateral);
        uint256 positionSizeInCollateralToken = convertToken(position.size, Token.Index, indexPrice, collateralPrice);
        uint256 sizeDecreaseInCollateralToken = convertToken(sizeDecrease, Token.Index, indexPrice, collateralPrice);

        _applyBorrowingFee(position, collateralPrice);

        uint256 collateralToReturn;

        if (sizeDecrease > 0) {
            int256 pnl = calculatePositionPnL(position, indexPrice, collateralPrice);
            if (pnl > 0) {
                uint256 pnlToRealize = (pnl.toUint256() * sizeDecreaseInCollateralToken) / positionSizeInCollateralToken;
                collateralToReturn += pnlToRealize;
            } else {
                uint256 pnlToRealize = (pnl.abs() * sizeDecreaseInCollateralToken) / positionSizeInCollateralToken;
                position.collateral -= pnlToRealize;
                totalCollateral -= pnlToRealize;
            }
            position.size -= sizeDecrease;
            _updateOpenInterest((sizeDecrease.toInt256() * -1), position.isLong, indexPrice, collateralPrice);
        }

        if (collateralDecrease > 0) {
            position.collateral -= collateralDecrease;
            totalCollateral -= collateralDecrease;
            collateralToReturn += collateralDecrease;
        }

        if (calculateLeverage(position, indexPrice, collateralPrice) > MAX_LEVERAGE) revert Perps__MaxLeverageExceeded();
        
        positions[msg.sender] = position;

        if (collateralToReturn > 0) {
            collateralToken.safeTransfer(msg.sender, collateralToReturn);
        }

        emit PositionDecreased(msg.sender, sizeDecrease, collateralDecrease);
    }    


    /*//////////////////////////////////////////////////////////////
                             Liquidations
    //////////////////////////////////////////////////////////////*/

    function liquidate(address trader) public {
        Position memory position = getPosition(trader);
        if (msg.sender == trader) revert Perps__SelfLiquidationProhibited();

        uint256 indexPrice = getPrice(Token.Index);
        uint256 collateralPrice = getPrice(Token.Collateral);
        if (calculateLeverage(position, indexPrice, collateralPrice) <= MAX_LEVERAGE) revert Perps__PositionNotLiquidatable();

        // negative pnl to Lps
        int256 pnl = calculatePositionPnL(position, indexPrice, collateralPrice);
        // borrowing fee to Lps
        // liquidation fee to msg.sender
        // remaining collateral to trader

        // state variables update - delete position!

        // event

    }

    /*//////////////////////////////////////////////////////////////
                          Position Utilities
    //////////////////////////////////////////////////////////////*/

    function calculateLeverage(Position memory position, uint256 indexPrice, uint256 collateralPrice) public view returns (uint256) {
        uint256 sizeInCollateralToken = convertToken(position.size, Token.Index, position.averagePrice, collateralPrice);
        int256 pnl = calculatePositionPnL(position, indexPrice, collateralPrice);
        uint256 remainingCollateral = (position.collateral.toInt256() + pnl).toUint256() - calculateBorrowingFee(position, collateralPrice);
        return sizeInCollateralToken / remainingCollateral;
    }

    /**
     * @return PnL in collateral token
     */
    function calculatePositionPnL(Position memory position, uint256 indexPrice, uint256 collateralPrice) public view returns (int256) {
        int256 currentValueInCollateralToken = convertToken(position.size, Token.Index, indexPrice, collateralPrice).toInt256();
        int256 initialValueInCollateralToken = convertToken(position.size, Token.Index, position.averagePrice, collateralPrice).toInt256();
        if (position.isLong) {
            return currentValueInCollateralToken - initialValueInCollateralToken;        
        } else {
            return initialValueInCollateralToken - currentValueInCollateralToken;
        }
    }

    /**
     * @param oldSize in index token
     * @param oldAveragePrice in usd with 1e30 precision 
     * @param currentIndexPrice in usd with 1e30 precision
     * @param sizeIncrease in index token
     * @return newAveragePrice in usd with 1e30 precision 
     */
    function calculateAveragePrice(
        uint256 oldSize, 
        uint256 oldAveragePrice, 
        uint256 currentIndexPrice,
        uint256 sizeIncrease
    ) 
        public 
        pure        
        returns (uint256 newAveragePrice) 
    {
        newAveragePrice = (oldSize * oldAveragePrice + currentIndexPrice * sizeIncrease) / 
            (oldSize + sizeIncrease);
    }

    /*//////////////////////////////////////////////////////////////
                              Accounting
    //////////////////////////////////////////////////////////////*/

    // converts size delta to collateral token, then adds or subtracts from relevant openInterest state variable
    function _updateOpenInterest(int256 sizeDelta, bool isLong, uint256 indexPrice, uint256 collateralPrice) private {
        bool isIncrease = sizeDelta >= 0;
        uint256 sizeDeltaInCollateralToken = convertToken(sizeDelta.abs(), Token.Index, indexPrice, collateralPrice);
        if(isLong) {
            isIncrease ? openInterestLong += sizeDeltaInCollateralToken : openInterestLong -= sizeDeltaInCollateralToken;
        } else {
            isIncrease ? openInterestShort += sizeDeltaInCollateralToken : openInterestShort -= sizeDeltaInCollateralToken;
        }
    }

    function _applyBorrowingFee(Position memory position, uint256 collateralPrice) private {
        uint256 borrowingFee = calculateBorrowingFee(position, collateralPrice);
        position.collateral -= borrowingFee;
        position.lastUpdated = block.timestamp;
        totalCollateral -= borrowingFee;
    }

    /**
     * @notice calculates borrowing fee owed since last position update
     * @param collateralPrice in usd with 1e30 precision
     * @return borrowing fee owed in collateral token
     */
    function calculateBorrowingFee(Position memory position, uint256 collateralPrice) public view returns (uint256) {
        uint256 positionSizeInUsd = (position.size * position.averagePrice) / toUsd[Token.Index]; // 1e30
        uint256 secondsPassedSinceLastUpdate = block.timestamp - position.lastUpdated;
        uint256 borrowingFeeInUsd = (positionSizeInUsd * secondsPassedSinceLastUpdate * USD_PRECISION) /
            BORROWING_FEE_RATE / USD_PRECISION;
        return getAmountInTokens(borrowingFeeInUsd, Token.Collateral, collateralPrice);
    }

    /*//////////////////////////////////////////////////////////////
                           Public Utilities
    //////////////////////////////////////////////////////////////*/

    function getPosition(address trader) public view returns (Position memory position) {
        position = positions[trader];
        if (position.collateral <= 0) revert Perps__PositionDoesNotExist(); 
    }

    // override totalAssets() to account for held collateral
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - totalCollateral;
    }

    // returns amount of liquidity (in Collateral token) currently reserved for open positions
    function getReservedLiquidity() public view returns (uint256) {
        return openInterestShort + openInterestLong;
    }

    function getMaxUtilization() public view returns (uint256) {
        return (totalAssets() * MAX_UTILIZATION_PERCENTAGE) / 100;
    }
    
    /*//////////////////////////////////////////////////////////////
                     Disabled ERC4626 functions 
    //////////////////////////////////////////////////////////////*/ 

    //disable function
    function redeem(
        uint256,
        /*shares*/ address,
        /*receiver*/ address /*owner*/
    ) public override returns (uint256) {
        revert Perps__UnsupportedOperation();
    }

    //disable function
    function withdraw(
        uint256,
        /*shares*/ address,
        /*receiver*/ address /*owner*/
    ) public override returns (uint256) {
        revert Perps__UnsupportedOperation();
    }

    //disable function
    function mint(
        uint256,
        /*shares*/ address /*receiver*/
    ) public override returns (uint256) {
        revert Perps__UnsupportedOperation();
    }

    //disable function
    function deposit(
        uint256,
        /*shares*/ address /*receiver*/
    ) public override returns (uint256) {
        revert Perps__UnsupportedOperation();
    }

}
