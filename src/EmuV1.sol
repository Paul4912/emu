// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { LiquidityAmounts } from "./libraries/uniswap/LiquidityAmounts.sol";
import { INonfungiblePositionManager } from
  "./interface/uniswap/INonfungiblePositionManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract EmuV1 {
  ERC20 public COLLATERAL_TOKEN;
  ERC20 public DEBT_TOKEN;
  INonfungiblePositionManager public _uniV3Manager;
}
