// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Perps, PerpsEvents} from "src/Perps.sol";
import {ERC20Mock} from "@openzeppelin/mocks/token/ERC20Mock.sol";
import {MockAggregatorV3} from "test/mock/MockAggregatorV3.sol";
import {Deployment} from "script/Deployment.s.sol";
import {DeploymentConfig} from "script/DeploymentConfig.s.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

contract PerpsTest is PerpsEvents, Test {
    using SafeCast for int256;
    using SafeCast for uint256;

    Perps public perps;
    // Deployment public deploymentScript;
    DeploymentConfig public deploymentConfig;    

    MockAggregatorV3 public indexPricefeedMock;
    MockAggregatorV3 public collateralPricefeedMock;
    ERC20Mock public wethMock; 

    uint256 public constant INITIAL_LP_WETH = 100 ether;
    uint256 public constant INITIAL_TRADER_WETH = 10 ether;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address lp3 = makeAddr("lp3");
    address lp4 = makeAddr("lp4");
    address[] lps = [lp1, lp2, lp3, lp4];

    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address trader3 = makeAddr("trader3");
    address trader4 = makeAddr("trader4");
    address[] traders = [trader1, trader2, trader3, trader4];

    /*//////////////////////////////////////////////////////////////
                          Environment setup
    //////////////////////////////////////////////////////////////*/
    
    function setUp() public {
        Deployment deploymentScript = new Deployment();
        (perps, deploymentConfig) = deploymentScript.run();
        (address indexPricefeed, address collateralPricefeed, address collateralToken, ) = deploymentConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            indexPricefeedMock = MockAggregatorV3(indexPricefeed);
            collateralPricefeedMock = MockAggregatorV3(collateralPricefeed);
            wethMock = ERC20Mock(collateralToken);
            _supplyWeth();
        }
    }

    function _supplyWeth() internal {
        for (uint i; i < lps.length; ++i) {
            wethMock.mint(lps[i], INITIAL_LP_WETH);
        }
        for (uint i; i < traders.length; ++i) {
            wethMock.mint(traders[i], INITIAL_TRADER_WETH);
        }
    }

    modifier addLiquidity() {
        for (uint i; i < lps.length; ++i) {
            uint256 amount = wethMock.balanceOf(lps[i]);
            vm.startPrank(lps[i]);
            wethMock.approve(address(perps), amount);
            perps.addLiquidity(amount);
            vm.stopPrank();
        }
        _;
    }

    modifier createPositions() {
        for (uint i; i < traders.length; ++i) {
            uint256 leverage = (i + 1) * 2;
            bool isLong = i % 2 == 0;
            uint256 collateral = wethMock.balanceOf(traders[i]);
            uint256 indexPrice = perps.getPrice(Perps.Token.Index);
            uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
            uint256 collateralInIndex = perps.convertToken(collateral, Perps.Token.Collateral, collateralPrice, indexPrice);
            uint256 size = collateralInIndex * leverage;
            vm.startPrank(traders[i]);
            wethMock.approve(address(perps), collateral);
            perps.openPosition(size, collateral, isLong);
            vm.stopPrank();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    Pricefeed and conversion logic
    //////////////////////////////////////////////////////////////*/

    function test_getAmountInTokens() public {
        uint256 btcPrice = perps.getPrice(Perps.Token.Index);
        uint256 amountInBTC = perps.getAmountInTokens(btcPrice * 2, Perps.Token.Index, btcPrice);
        assertEq(amountInBTC, 2e8);
        amountInBTC = perps.getAmountInTokens(btcPrice / 5, Perps.Token.Index, btcPrice);
        assertEq(amountInBTC, 2e7);
        
        uint256 ethPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 amountInETH = perps.getAmountInTokens(ethPrice * 3, Perps.Token.Collateral, ethPrice);
        assertEq(amountInETH, 3e18);
        amountInETH = perps.getAmountInTokens(ethPrice / 2, Perps.Token.Collateral, ethPrice);
        assertEq(amountInETH, 5e17);
    }

    function test_getUsdValue() public {
        uint256 ethAmount = 1e18;
        uint256 ethPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 usdValue = perps.getUsdValue(ethAmount, Perps.Token.Collateral, ethPrice);
        assertEq(usdValue, 3222e30);
    }

    function test_convertToken() public {
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        // input token is index
        uint256 inputTokenAmount = 2e8; // 2BTC
        uint256 inputTokenAmountInUsd = perps.getUsdValue(inputTokenAmount, Perps.Token.Index, indexPrice);
        assertEq(inputTokenAmountInUsd, perps.getPrice(Perps.Token.Index) * 2);
        uint256 expectedAmountInOutput = perps.getAmountInTokens(inputTokenAmountInUsd, Perps.Token.Collateral, collateralPrice);
        uint256 amountInOutput = perps.convertToken(inputTokenAmount, Perps.Token.Index, indexPrice, collateralPrice);
        assertEq(expectedAmountInOutput, amountInOutput);
        // input token is collateral
        inputTokenAmount = 5e17; // 0.5 ETH
        inputTokenAmountInUsd = perps.getUsdValue(inputTokenAmount, Perps.Token.Collateral, collateralPrice);
        assertEq(inputTokenAmountInUsd, perps.getPrice(Perps.Token.Collateral) / 2);
        expectedAmountInOutput = perps.getAmountInTokens(inputTokenAmountInUsd, Perps.Token.Index, indexPrice);
        amountInOutput = perps.convertToken(inputTokenAmount, Perps.Token.Collateral, collateralPrice, indexPrice);
        assertEq(expectedAmountInOutput, amountInOutput);
    }

    /*//////////////////////////////////////////////////////////////
                    Public utilities & accounting
    //////////////////////////////////////////////////////////////*/

    function test_accountingGetters() public addLiquidity createPositions {
        // total assets
        uint256 contractWethBalance = wethMock.balanceOf(address(perps));
        uint256 totalAssets = perps.totalAssets();
        assertEq(totalAssets, contractWethBalance - perps.totalCollateral());
        // max utilization
        assertEq(perps.getMaxUtilization(), (totalAssets * 75) / 100);
        // open interest
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 expectedOpenInterest;
        for (uint i; i < traders.length; ++i) {
            Perps.Position memory position = perps.getPosition(traders[i]);
            expectedOpenInterest += perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
        }
        assertEq(perps.getReservedLiquidity(), expectedOpenInterest);
        // check available liquidity
        uint256 remainingLiquidity = perps.getMaxUtilization() - perps.getReservedLiquidity();
        uint256 remainingLiquidityInIndexToken = perps.convertToken(remainingLiquidity, Perps.Token.Collateral, collateralPrice, indexPrice);
        address newTrader = makeAddr("newTrader");
        wethMock.mint(newTrader, remainingLiquidity);
        vm.startPrank(newTrader);
        wethMock.approve(address(perps), wethMock.balanceOf(newTrader));
        vm.expectRevert(Perps.Perps__InsufficientLiquidity.selector);
        perps.openPosition(remainingLiquidityInIndexToken + 1, remainingLiquidity / 10, false);
        vm.stopPrank();
    }

    function test_calculateAveragePrice() public {
        indexPricefeedMock.updateAnswer(50_000e8);
        uint256 currentIndexPrice = perps.getPrice(Perps.Token.Index); 
        uint256 oldSize = 1e8;
        uint256 oldAvgPrice = perps.getPrice(Perps.Token.Index);
        assertEq(oldAvgPrice, 50_000e30);

        indexPricefeedMock.updateAnswer(60_000e8);
        currentIndexPrice = perps.getPrice(Perps.Token.Index); 
        uint256 sizeIncrease = 1e8;

        uint256 newAvgPrice = perps.calculateAveragePrice(oldSize, oldAvgPrice, currentIndexPrice, sizeIncrease);
        assertEq(newAvgPrice, 55_000e30);

        indexPricefeedMock.updateAnswer(70_000e8);
        currentIndexPrice = perps.getPrice(Perps.Token.Index); 
        uint256 newOldSize = oldSize + sizeIncrease;
        uint256 newSizeIncrease = 1e8;

        uint256 newerAvgPrice = perps.calculateAveragePrice(newOldSize, newAvgPrice, currentIndexPrice, newSizeIncrease);
        assertEq(newerAvgPrice, 60_000e30);
    }

    function test_calculateBorrowingFee() public addLiquidity createPositions {
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        Perps.Position memory position = perps.getPosition(trader1);
        assertEq(position.lastUpdated, block.timestamp);
        vm.warp(365 days);
        uint256 borrowingFee = perps.calculateBorrowingFee(position, collateralPrice);
        uint256 sizeInCollateralToken = perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
        uint256 maxDelta = 1e12;
        assertApproxEqAbs(borrowingFee, sizeInCollateralToken / 10, maxDelta);
    }

    function test_calculatePositionPnL() public addLiquidity createPositions {
        Perps.Position memory position = perps.getPosition(trader1);
        int256 initialPricefeedAnswer = indexPricefeedMock.latestAnswer();
        // no change in price should return 0
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 initialValueInCollateralToken = perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
        assertEq(perps.calculatePositionPnL(position, indexPrice, collateralPrice), 0);

        // 10% reduction in current price should return -10% value in collateral tokens
        int256 newPrice = (initialPricefeedAnswer * 90) / 100;
        indexPricefeedMock.updateAnswer(newPrice);
        indexPrice = perps.getPrice(Perps.Token.Index);
        int256 expectedPnL = ((initialValueInCollateralToken * 10) / 100).toInt256() * -1;
        assertApproxEqAbs(perps.calculatePositionPnL(position, indexPrice, collateralPrice), expectedPnL, 1); //maxDelta 1 wei!

        // 20% increase in current price should return +20% value in collateral tokens
        newPrice = (initialPricefeedAnswer + ((initialPricefeedAnswer *20) / 100));
        indexPricefeedMock.updateAnswer(newPrice);
        indexPrice = perps.getPrice(Perps.Token.Index);
        expectedPnL = ((initialValueInCollateralToken * 20) / 100).toInt256();
        assertApproxEqAbs(perps.calculatePositionPnL(position, indexPrice, collateralPrice), expectedPnL, 1); // maxDelta 1 wei!
    }

    function test_calculateLeverage() public addLiquidity createPositions {
        int256 initialPricefeedAnswer = indexPricefeedMock.latestAnswer();

        Perps.Position memory position = perps.getPosition(trader4);
        assertEq(position.isLong, false); // this position is a short, meaning it will lose leverage if price increases
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 initialLeverage = perps.calculateLeverage(position, indexPrice, collateralPrice);
        // console.log(initialLeverage);

        // increase price by 10%
        int256 newPrice = initialPricefeedAnswer + ((initialPricefeedAnswer * 10) / 100);
        indexPricefeedMock.updateAnswer(newPrice);
        indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 updatedLeverage = perps.calculateLeverage(position, indexPrice, collateralPrice);
        // console.log(updatedLeverage);

        assertGt(updatedLeverage, initialLeverage);

        assertTrue(perps.isLiquidatable(position));
    }

    /*//////////////////////////////////////////////////////////////
                              Liquidity
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity() public {
        // basic test to check shares
        uint256 sharesBefore = perps.balanceOf(lp1);
        uint256 contractBalBefore = wethMock.balanceOf(address(perps));
        uint256 amount = wethMock.balanceOf(lp1);
        vm.startPrank(lp1);
        wethMock.approve(address(perps), amount);
        vm.expectEmit(address(perps));
        emit PerpsEvents.LiquidityAdded(lp1, amount);
        uint256 shares = perps.addLiquidity(amount);
        vm.stopPrank();

        assertEq(wethMock.balanceOf(address(perps)), contractBalBefore + amount);
        assertEq(perps.balanceOf(lp1), sharesBefore + shares);

        // TODO: test functionality with Positions/PnL/Collateral in the system
    }

    function test_removeLiquidity() public addLiquidity createPositions {
        uint256 lpWethBalBefore = wethMock.balanceOf(lp1);
        uint256 lpSharesBefore = perps.balanceOf(lp1);
        assertEq(lpSharesBefore, INITIAL_LP_WETH);
        uint256 lpAssetsBefore = perps.convertToAssets(lpSharesBefore);
        assertEq(lpSharesBefore, lpAssetsBefore); // no PnL realized yet 
        uint256 reservedLiquidity = perps.getReservedLiquidity();
        assertTrue(reservedLiquidity < perps.getMaxUtilization() - lpAssetsBefore);

        // lp1 removes all liquidity
        vm.startPrank(lp1);
        vm.expectEmit(address(perps));
        emit PerpsEvents.LiquidityRemoved(lp1, lpAssetsBefore);
        perps.removeLiquidity(lpSharesBefore);
        vm.stopPrank();

        assertEq(perps.balanceOf(lp1), 0);
        assertEq(wethMock.balanceOf(lp1), lpWethBalBefore + lpAssetsBefore);

        uint256 lp2Shares = perps.balanceOf(lp2);
        // lp2 withdrawing would exceed max utililzation
        assertFalse(reservedLiquidity < perps.getMaxUtilization() - lp2Shares);
        // protocol will not allow lp2 to withdraw past max utilization threshold
        vm.startPrank(lp2);
        vm.expectRevert(Perps.Perps__InsufficientLiquidity.selector);
        perps.removeLiquidity(lp2Shares);
        vm.stopPrank();
    }


    /*//////////////////////////////////////////////////////////////
                              Postition
    //////////////////////////////////////////////////////////////*/

    function test_openPosition() public addLiquidity {
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);

        address newTrader = makeAddr("newTrader");
        uint256 collateral = 1 ether;
        bool isLong = true;
        uint256 leverage = 10;
        uint256 size = perps.convertToken((collateral * leverage), Perps.Token.Collateral, collateralPrice, indexPrice);
        wethMock.mint(newTrader, collateral);

        uint256 contractWethBefore = wethMock.balanceOf(address(perps));
        uint256 longOpenInterestBefore = perps.openInterestLong();
        uint256 totalCollateralBefore = perps.totalCollateral();

        vm.startPrank(newTrader);
        wethMock.approve(address(perps), collateral);
        vm.expectEmit(address(perps));
        emit PerpsEvents.PositionOpened(newTrader, size, collateral, isLong);
        perps.openPosition(size, collateral, isLong);
        vm.stopPrank();

        Perps.Position memory position = perps.getPosition(newTrader);
        assertEq(position.size, size);
        assertEq(position.collateral, collateral);
        assertEq(position.averagePrice, indexPrice);
        assertEq(position.lastUpdated, block.timestamp);
        assertEq(position.isLong, isLong);

        assertEq(wethMock.balanceOf(address(perps)), contractWethBefore + collateral);
        uint256 sizeInCollateralToken = perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
        assertEq(perps.openInterestLong(), longOpenInterestBefore + sizeInCollateralToken);
        assertEq(perps.totalCollateral(), totalCollateralBefore + collateral);
    }

    function test_openPosition_revert() public addLiquidity {
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        address newTrader = makeAddr("newTrader");
        
        // exceeds max utilization
        uint256 maxUtilization = perps.getMaxUtilization();        
        uint256 exceedingSize = perps.convertToken(maxUtilization, Perps.Token.Collateral, collateralPrice, indexPrice) + 1;
        wethMock.mint(newTrader, maxUtilization);
        uint256 collateral = maxUtilization / 10;
        bool isLong = true;
        vm.startPrank(newTrader);
        wethMock.approve(address(perps), collateral);
        vm.expectRevert(Perps.Perps__InsufficientLiquidity.selector);
        perps.openPosition(exceedingSize, collateral, isLong);
        vm.stopPrank();

        // zero inputs
        vm.prank(newTrader);
        vm.expectRevert(Perps.Perps__InsufficientSize.selector);
        perps.openPosition(0, 1, true);
        vm.prank(newTrader);
        vm.expectRevert(Perps.Perps__InsufficientCollateral.selector);
        perps.openPosition(1,0,true);

        // max leverage exceeded
        uint256 size = 1e8;
        collateral = (perps.convertToken(size, Perps.Token.Index, indexPrice, collateralPrice) / (perps.MAX_LEVERAGE() + 1));
        vm.prank(newTrader);
        vm.expectRevert(Perps.Perps__MaxLeverageExceeded.selector);
        perps.openPosition(size, collateral, false);

        // trader has open position
        collateral = (perps.convertToken(size, Perps.Token.Index, indexPrice, collateralPrice) / 5);
        vm.prank(newTrader);
        perps.openPosition(size, collateral, false);
        vm.prank(newTrader);
        vm.expectRevert(Perps.Perps__TraderHasOpenPosition.selector);
        perps.openPosition(size, collateral, true);
    }

    function test_increasePosition() public addLiquidity createPositions {
        int256 initialAnswer = indexPricefeedMock.latestAnswer();
        Perps.Position memory position = perps.getPosition(trader2);
        assertEq(position.isLong, false);

        vm.warp(5 days);
        
        // price moves down by 5%
        int256 newPrice = initialAnswer - ((initialAnswer * 5) / 100);
        indexPricefeedMock.updateAnswer(newPrice);
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        
        // increase size by 20%
        uint256 sizeIncrease = (position.size * 20) / 100;
        uint256 sizeIncreaseInCollateralToken = perps.convertToken(sizeIncrease, Perps.Token.Index, indexPrice, collateralPrice);
        // increase collateral by 10%
        uint256 collateralIncrease = (position.collateral * 10) / 100;
        wethMock.mint(trader2, collateralIncrease);

        uint256 openInterestBefore = perps.openInterestShort();
        uint256 totalCollateralBefore = perps.totalCollateral();

        uint256 borrowingFee = perps.calculateBorrowingFee(position, collateralPrice);
        uint256 expectedAveragePrice = perps.calculateAveragePrice(position.size, position.averagePrice, indexPrice, sizeIncrease);

        vm.startPrank(trader2);
        wethMock.approve(address(perps), collateralIncrease);
        vm.expectEmit(address(perps));
        emit PerpsEvents.PositionIncreased(trader2, sizeIncrease, collateralIncrease);
        perps.increasePosition(sizeIncrease, collateralIncrease);
        vm.stopPrank();
    
        Perps.Position memory positionUpdated = perps.getPosition(trader2);
        assertEq(positionUpdated.size, position.size + sizeIncrease);
        assertEq(positionUpdated.collateral, position.collateral - borrowingFee + collateralIncrease);
        assertEq(positionUpdated.averagePrice, expectedAveragePrice);
        assertEq(positionUpdated.lastUpdated, block.timestamp);
        assertEq(perps.openInterestShort(), openInterestBefore + sizeIncreaseInCollateralToken);
        assertEq(perps.totalCollateral(), totalCollateralBefore + collateralIncrease - borrowingFee);
    }

    // function test_increasePosition_revert() public addLiquidity createPositions {}

    function test_decreasePosition() public addLiquidity createPositions {
        int256 initialAnswer = indexPricefeedMock.latestAnswer();
        Perps.Position memory position = perps.getPosition(trader1);
        assertEq(position.isLong, true);

        // price moves up by 10%
        int256 newPrice = initialAnswer + ((initialAnswer * 10) / 100);
        indexPricefeedMock.updateAnswer(newPrice);
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);

        int256 pnl = perps.calculatePositionPnL(position, indexPrice, collateralPrice);
        console.logInt(pnl);

        // decrease by half should realize HALF of pnl
        uint256 traderWethBefore = wethMock.balanceOf(trader1);
        vm.prank(trader1);
        perps.decreasePosition(position.size / 2, 0);

        console.logInt(pnl / 2);
        console.log(wethMock.balanceOf(trader1));
    }

}

