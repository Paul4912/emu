// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface EEmu {
  event LendDebtTokens(address indexed user, uint256 indexed slice, uint256 amount);
  event WithdrawDebtTokens(address indexed user, uint256 indexed slice, uint256 amount);
  event Borrow(
    address indexed user,
    uint256 indexed slice,
    uint256 amountBorrowed,
    uint256 collateralAdded
  );
  event Repay(
    address indexed user,
    uint256 indexed slice,
    uint256 amountRepayed,
    uint256 collateralRemoved
  );
  event SliceLiquidation(uint256 indexed slice);
  event UserLiquidation(address indexed user, uint256 indexed slice);
  event ClaimBonusAndFees(address indexed user, uint256 indexed slice);
}
