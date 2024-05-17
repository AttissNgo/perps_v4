// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentConfig} from "script/DeploymentConfig.s.sol";
import {Perps} from "src/Perps.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract Deployment is Script {
    
    uint8 public constant INDEX_TOKEN_DECIMALS = 8;

    function run() external returns (Perps, DeploymentConfig) {

        DeploymentConfig config = new DeploymentConfig();

        (
            address indexPricefeed, 
            address collateralPricefeed,
            address collateralToken,
            uint256 deployerKey
        ) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);
        Perps perps = new Perps(
            ERC20(collateralToken),
            "WETH Vault",
            "vWeth",
            indexPricefeed,
            collateralPricefeed,
            INDEX_TOKEN_DECIMALS
        );
        vm.stopBroadcast();      

        return (perps, config);  
    }
}