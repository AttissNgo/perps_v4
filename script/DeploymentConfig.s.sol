// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockAggregatorV3} from "test/mock/MockAggregatorV3.sol";
import {ERC20Mock} from "@openzeppelin/mocks/token/ERC20Mock.sol";

contract DeploymentConfig is Script {
    
    struct NetworkConfig {
        address indexPricefeed;
        address collateralPricefeed;
        address collateralToken;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant BTC_INIT_PRICE = 64422e8;
    int256 public constant ETH_INIT_PRICE = 3222e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            // run the testnet of mainnet config
        }
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.indexPricefeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockAggregatorV3 btcPricefeed = new MockAggregatorV3(DECIMALS, BTC_INIT_PRICE);
        MockAggregatorV3 ethPricefeed = new MockAggregatorV3(DECIMALS, ETH_INIT_PRICE); 
        ERC20Mock wethMock = new ERC20Mock();
        vm.stopBroadcast();

        return NetworkConfig({
            indexPricefeed: address(btcPricefeed),
            collateralPricefeed: address(ethPricefeed),
            collateralToken: address(wethMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}

