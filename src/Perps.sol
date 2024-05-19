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
    uint256 public openInterestLong; // in index token
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

// thirty zeroes: 000000000000000000000000000000
    /*//////////////////////////////////////////////////////////////
                              Liquidity
    //////////////////////////////////////////////////////////////*/
    
    function addLiquidity(uint256 amount) external returns (uint256 shares) {
        shares = super.deposit(amount, msg.sender);
        emit LiquidityAdded(msg.sender, amount);
    }
    
    // function removeLiquidity(uint256 shares) external checkAvailableLiquidity returns (uint256 amount) {
    //     amount = super.redeem(shares, msg.sender, msg.sender);
    //     emit LiquidityRemoved(msg.sender, amount); 
    // }

    /*//////////////////////////////////////////////////////////////
                               Position
    //////////////////////////////////////////////////////////////*/


    // function openPosition(
    //     uint256 size, 
    //     uint256 collateral, 
    //     bool isLong
    // ) 
    //     external 
    //     checkAvailableLiquidity    
    // {
    //     // check inputs - no zero inputs
    //     if (size <= 0) revert Perps__InsufficientSize();
    //     if (collateral <= 0) revert Perps__InsufficientCollateral();

    //     // check if user has open position
    //     Position memory position = positions[msg.sender];
    //     if (position.collateral > 0) revert Perps__TraderHasOpenPosition();

    //     // update open interest & collateral
    //     _updateOpenInterest(size.toInt256(), isLong);
    //     totalCollateral += collateral;

    //     // store data
    //     position.size = size;
    //     position.collateral = collateral;
    //     position.averagePrice = getPrice(Token.Index);
    //     position.lastUpdated = block.timestamp;
    //     position.isLong = isLong;
    //     positions[msg.sender] = position;

    //     // TODO: check leverage

    //     // transfer
    //     collateralToken.safeTransferFrom(msg.sender, address(this), collateral);

    //     // event
    //     emit PositionOpened(msg.sender, size, collateral, isLong);
    // }

    /*//////////////////////////////////////////////////////////////
                          Position Utilities
    //////////////////////////////////////////////////////////////*/

    // function calculateLeverage(Position calldata position, uint256 currentIndexPrice) public pure returns (uint256) {
    //     // convert size to collateral token
    //     // collateral + pnl
    //     // size in collateral token / (collateral + pnl) 
    // }

    // // returns PnL in collateral token
    // function calculatePnL(Position calldata position) public view returns (int256 pnlInCollateralToken) {
    //     int256 pnlInUsd;
    //     int256 currentValue = ((position.size * getPrice(Token.Index)) / toUsd[Token.Index]).toInt256();
    //     int256 valueWhenCreated = ((position.size * position.averagePrice) / toUsd[Token.Index]).toInt256();
    //     if (position.isLong) {
    //         pnlInUsd = currentValue - valueWhenCreated;
    //     } else {
    //         pnlInUsd = valueWhenCreated - currentValue;
    //     }
    //     uint256 pnlInCollateralAbs = getAmountInTokens(pnlInUsd.abs(), Token.Collateral);
    //     pnlInCollateralToken = (pnlInUsd < 0) ? (pnlInCollateralAbs.toInt256() * -1) : pnlInCollateralAbs.toInt256();
    // }

    // // returns USD 1e30
    // function calculateAveragePrice(
    //     uint256 oldSize, 
    //     uint256 oldAveragePrice, 
    //     uint256 sizeIncrease
    // ) 
    //     public 
    //     view 
    //     returns (uint256 newAveragePrice) 
    // {
    //     newAveragePrice = (oldSize * oldAveragePrice + getPrice(Token.Index) * sizeIncrease) / 
    //         (oldSize + sizeIncrease);
    // }

    /*//////////////////////////////////////////////////////////////
                              Accounting
    //////////////////////////////////////////////////////////////*/

    // // if long, simply add or subtract size delta in index token
    // // if short, convert to collateral token and handle
    // function _updateOpenInterest(int256 sizeDelta, bool isLong) private {
    //     if (isLong) {
    //         openInterestLong = (openInterestLong.toInt256() + sizeDelta).toUint256();
    //     } else {
    //         uint256 sizeDeltaInCollateralToken = convertToken(sizeDelta.abs(), Token.Index);
    //         if (sizeDelta > 0) {
    //             openInterestShort += sizeDeltaInCollateralToken;
    //         } else {
    //             openInterestShort -= sizeDeltaInCollateralToken;
    //         }
    //     }
    // }

    // // returns borrowing fee owed in collateral token
    // function calculateBorrowingFee(Position calldata position) public view returns (uint256) {
    //     uint256 positionSizeInUsd = (position.size * position.averagePrice) / toUsd[Token.Index]; // 1e30
    //     uint256 secondsPassedSinceLastUpdate = block.timestamp - position.lastUpdated;
    //     uint256 borrowingFeeInUsd = (positionSizeInUsd * secondsPassedSinceLastUpdate * USD_PRECISION) /
    //         BORROWING_FEE_RATE / USD_PRECISION;
    //     return getAmountInTokens(borrowingFeeInUsd, Token.Collateral);
    // }

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
    // function getReservedLiquidity() public view returns (uint256) {
    //     // TODO: get both token prices and pass to convertToken()
    //     uint256 longOpenInterestInCollateralToken = convertToken(openInterestLong, Token.Index); 
    //     return openInterestShort + longOpenInterestInCollateralToken;
    // }

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
