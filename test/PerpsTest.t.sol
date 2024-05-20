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
        uint256 expectedOpenInterestShort;
        for (uint i; i < traders.length; ++i) {
            Perps.Position memory position = perps.getPosition(traders[i]);
            if (!position.isLong) {
                expectedOpenInterestShort += perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
            }
        }
        assertEq(expectedOpenInterestShort, perps.openInterestShort());
        assertEq(
            perps.getReservedLiquidity(), 
            perps.openInterestShort() + perps.convertToken(perps.openInterestLong(), Perps.Token.Index, indexPrice, collateralPrice)
        );
        // check available liquidity
        uint256 remainingLiquidity = perps.getMaxUtilization() - perps.getReservedLiquidity();
        uint256 remainingLiquidityInIndexToken = perps.convertToken(remainingLiquidity, Perps.Token.Collateral, collateralPrice, indexPrice);
        // console.log(remainingLiquidityInIndexToken);
        address newTrader = makeAddr("newTrader");
        wethMock.mint(newTrader, remainingLiquidity);
        vm.startPrank(newTrader);
        wethMock.approve(address(perps), wethMock.balanceOf(newTrader));
        vm.expectRevert(Perps.Perps__InsufficientLiquidity.selector);
        perps.openPosition(remainingLiquidityInIndexToken + 1, remainingLiquidityInIndexToken / 10, false);
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

    function test_getPositionPnL() public addLiquidity createPositions {
        Perps.Position memory position = perps.getPosition(trader1);
        int256 initialPricefeedAnswer = indexPricefeedMock.latestAnswer();
        // no change in price should return 0
        uint256 indexPrice = perps.getPrice(Perps.Token.Index);
        uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
        uint256 initialValueInCollateralToken = perps.convertToken(position.size, Perps.Token.Index, indexPrice, collateralPrice);
        assertEq(perps.getPositionPnL(position), 0);

        // 10% reduction in current price should return -10% value in collateral tokens
        int256 newPrice = (initialPricefeedAnswer * 90) / 100;
        indexPricefeedMock.updateAnswer(newPrice);
        int256 expectedPnL = ((initialValueInCollateralToken * 10) / 100).toInt256() * -1;
        assertEq(perps.getPositionPnL(position), expectedPnL);

        // 20% increase in current price should return +20% value in collateral tokens
        newPrice = (initialPricefeedAnswer + ((initialPricefeedAnswer *20) / 100));
        indexPricefeedMock.updateAnswer(newPrice);
        expectedPnL = ((initialValueInCollateralToken * 20) / 100).toInt256();
        assertApproxEqAbs(perps.getPositionPnL(position), expectedPnL, 1);  
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

    // function test_openPosition() public addLiquidity {

    // }

    // function test_gas_internal() public {
    //     uint256 calculatedInteranally = (1e8 * 664422e30) / perps.toUsd(Perps.Token.Index);
    //     console.log(calculatedInteranally);
    // }

    // function test_gas_external() public {
    //     uint256 calculatedFromPricefeed = perps.getUsdValue(1e8, Perps.Token.Index);
    //     console.log(calculatedFromPricefeed); 
    // }

    // function test_gas_two_calls() public returns (uint256, uint256) {
    //     uint256 indexPrice = perps.getPrice(Perps.Token.Index);
    //     uint256 collateralPrice = perps.getPrice(Perps.Token.Collateral);
    //     return (indexPrice, collateralPrice);
    // }

    // function test_gas_one_call() public returns (uint256, uint256) {
    //     return (perps.getPrice(Perps.Token.Index), perps.getPrice(Perps.Token.Collateral));
    // }


    // function test_sandbox() public {
    //     // 10000 usd should buy 0.2 BTC or 2e7
    //     uint256 usd = 10_000e30;
    //     uint256 btcPrice = 50_000e8;
    //     uint256 btcDivisor = 1e14; // 1e30(usd precision) - 1e8(pricefeed answer) - 1e14(mult) = 1e8;
    //     console.log(usd/btcPrice/btcDivisor);

    //     // 100000 usd should buy 2 BTC or 2e8
    //     usd = 100_000e30;
    //     console.log(usd/btcPrice/btcDivisor);

    //     usd = 1_000_000e30;
    //     console.log(usd/btcPrice/btcDivisor);

    //     // 10000 usd should buy 5 ETH or 5e18
    //     usd = 10_000e30;
    //     uint256 ethPrice = 2000e8;
    //     uint256 div = 30 - 8 - 18;
    //     uint256 ethDivisor = 10**div;
    //     console.log(usd/ethPrice/ethDivisor);

    //     // 100 usd should buy 0.05 ETH of 5e16
    //     usd = 100 * 10**30;
    //     console.log(usd/ethPrice/ethDivisor);

    //     // 6 ETH (6e18) should be worth 12_000 usd (12_000e30)
    //     uint256 value = 6e18 * ethPrice * ethDivisor; // (tokens * price) * divisor
    //     assertEq(value, 12_000e30);

    //     /// .... so must represent USD in higher decimals so we always divide by 1eX to get the proper token decimals
    // }
}
