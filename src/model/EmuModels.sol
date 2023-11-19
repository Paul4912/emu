// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct SliceData {
  uint256 depositIndex;
  uint256 totalBaseDeposit;
  uint256 debtIndex;
  uint256 totalBaseDebt;
  uint256 totalCollateralDeposit;
  uint128 lastUpdate;
  uint64 depositEpoch;
  uint64 borrowingEpoch;
}

struct UserLendingData {
  uint256 baseAmount;
  uint256 claimableCollateralIndex;
  uint256 claimableCollateralAmount; // pack struct here?
  uint256 epoch;
}

struct UserBorrowingData {
  uint256 baseAmount;
  uint256 collateralDeposit;
}
