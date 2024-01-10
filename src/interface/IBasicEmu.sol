// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { EBasicEmu } from "./EBasicEmu.sol";
import { SliceData, UserLendingData, UserBorrowingData } from "../model/EmuModels.sol";

interface IBasicEmu is EBasicEmu {
  function depositDebtTokens(uint256 _slice, uint256 _amount) external;

  function withdrawDebtTokens(uint256 _slice, uint256 _amount) external;

  function borrow(uint256 _slice, uint256 _borrowAmount, uint256 _addedCollateral)
    external;

  function repayAll(uint256 _slice) external;

  function repay(uint256 _slice, uint256 _repayAmount, uint256 _removeCollateral)
    external;

  function liquidateUser(address _user, uint256 _slice) external;

  function claimBonusCollateral(uint256 _slice) external;

  function isUserLiquidateable(uint256 _slice, address _user)
    external
    view
    returns (bool);

  function getSliceData(uint256 _slice) external view returns (SliceData memory);

  function getClaimableData(uint256 _slice, uint256 _epoch)
    external
    view
    returns (uint256);

  function getUserLendingData(address _user, uint256 _slice)
    external
    view
    returns (UserLendingData memory);

  function getUserBorrowingData(address _user, uint256 _slice)
    external
    view
    returns (UserBorrowingData memory);

  function getSliceLiquidity(uint256 _slice)
    external
    view
    returns (
      uint256 totalDebtTokenDeposits_,
      uint256 totalDebt_,
      uint256 totalUnlentLiquidity_
    );

  function getUserDebtTokenDeposit(address _user, uint256 _slice)
    external
    view
    returns (uint256);

  function getUserCollateral(address _user, uint256 _slice)
    external
    view
    returns (uint256);

  function getUserDebt(address _user, uint256 _slice) external view returns (uint256);

  function getClaimableAmount(address _user, uint256 _slice)
    external
    view
    returns (uint256 collateral_);

  function doesSliceExists(uint256 _slice) external view returns (bool);

  function getExistingSlices() external view returns (uint256[] memory);
}
