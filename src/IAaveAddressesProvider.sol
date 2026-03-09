// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IAavePool} from "./IAavePool.sol";

interface IAaveAddressesProvider {
    function getPool() external view returns (IAavePool);
}