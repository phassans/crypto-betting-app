// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

contract HelperConfig {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address _usdc;
        address _priceFeed;
        address _botAddress;
        uint256 _botFeeBasisPoints;
    }

    mapping(uint256 => NetworkConfig) public chainIdToNetworkConfig;

    constructor() {
        chainIdToNetworkConfig[421614] = getArbSepoliaEthConfig();
        activeNetworkConfig = chainIdToNetworkConfig[block.chainid];
    }

    function getArbSepoliaEthConfig()
        internal
        pure
        returns (NetworkConfig memory arbsepoliaNetworkConfig)
    {
        arbsepoliaNetworkConfig = NetworkConfig({
            _usdc: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d,
            _priceFeed: 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69,
            _botAddress: 0x98Db3a19Cd45b15d6CF1df29705800B24F466eA5,
            _botFeeBasisPoints: 100
        });
    }
}