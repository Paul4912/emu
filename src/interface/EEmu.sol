// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface EEmu {
  error InsufficientUnlentLiquidity();
  error SliceIsLiquidatable();
  error PositionIsLiquidatable();
  error PositionCannotBeLiquidated();
  error SliceAlreadyExists();
  error SliceDoesNotExist();
  error InvalidSlicePosition();

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
  event UserLiquidation(address indexed user, uint256 indexed slice);
  event BonusCollateralClaimed(address indexed user, uint256 indexed slice);
}
