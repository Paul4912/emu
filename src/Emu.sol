// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "./library/Math.sol";

struct SliceData {
  //pack struct? do later
  uint256 depositIndex;
  uint256 totalBaseDeposit;
  uint256 debtIndex;
  uint256 totalBaseDebt;
  uint256 totalCollateralDeposit;
  uint256 depositEpoch;
  uint256 lastUpdate;
}

struct UserClaimableData {
  uint256 claimableCollateralIndex;
  uint256 claimableCollateralAmount;
  uint256 claimableDebtTokenIndex;
  uint256 claimableDebtTokenAmount;
}

struct UserLendingData {
  uint256 baseAmount;
  uint256 epoch;
}

struct UserBorrowingData {
  uint256 debtBaseAmount;
  uint256 collateralDeposit;
}

contract Emu {
  uint256 constant RAY = 10 ** 27;
  uint256 constant interestRateBPS = 500;
  uint256 constant BPS = 10_000;
  uint256 constant secondsInYear = 31_536_000;
  address immutable COLLATERAL_TOKEN;
  address immutable DEBT_TOKEN;

  uint256[] public createdSlices;
  mapping(uint256 price => SliceData sliceData) private slices;

  uint256 public claimableCollateralIndex;
  uint256 public claimableDebtTokenIndex;

  mapping(address user => mapping(uint256 slice => UserLendingData data)) private
    userLendingData;
  mapping(address user => mapping(uint256 slice => UserBorrowingData data)) private
    userBorrowingData;
  mapping(address user => mapping(uint256 slice => UserClaimableData data)) private
    userClaimableData;

  function depositDebtTokens(uint256 _slice, uint256 _amount) external {
    _accureInterest(_slice);
    // user claimable amount

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[msg.sender][_slice];

    if (userData.epoch < cachedSliceData.depositEpoch) {
      userData.baseAmount = 0;
      userData.epoch = cachedSliceData.depositEpoch;
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);

    userData.baseAmount += baseAmount;
    slices[_slice].totalBaseDeposit += baseAmount;

    // safe transfer

    //emit event
  }

  function withdrawDebtTokens(uint256 _slice, uint256 _amount) external {
    _accureInterest(_slice);
    // user claimable amount

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[msg.sender][_slice];

    if (userData.epoch < cachedSliceData.depositEpoch) {
      userData.baseAmount = 0;
      userData.epoch = cachedSliceData.depositEpoch;
      return;
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);

    userData.baseAmount -= baseAmount;
    slices[_slice].totalBaseDeposit -= baseAmount;

    if (
      _amount + _toNominal(cachedSliceData.totalBaseDebt, cachedSliceData.debtIndex)
        > _toNominal(cachedSliceData.totalBaseDeposit, cachedSliceData.depositIndex)
    ) {
      //throw error
    } else {
      // safe transfer
    }

    //emit event
  }

  function borrow(uint256 _slice, uint256 _borrowAmount, uint256 _addedCollateral)
    external
  {
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[msg.sender][_slice];
    SliceData storage sliceData = slices[_slice];
    uint256 currentPrice = getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    if (_slice >= currentPrice) {
      // throw error cant borrow
    }

    userData.collateralDeposit += _addedCollateral;
    sliceData.totalCollateralDeposit += _addedCollateral;
    // transfer collateral token to contract from user

    uint256 baseBorrowAmount = _toBase(_borrowAmount, debtIndex);
    userData.debtBaseAmount += baseBorrowAmount;
    sliceData.totalBaseDebt += baseBorrowAmount;

    // does use memory here to save gas?
    if (
      _toNominal(userData.debtBaseAmount, debtIndex)
        >= userData.collateralDeposit * currentPrice
    ) {
      // throw error
    }

    // transfer debt token and events
  }

  function repay(uint256 _slice, uint256 _repayAmount, uint256 _removeCollateral)
    external
  {
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[msg.sender][_slice];
    SliceData storage sliceData = slices[_slice];
    uint256 currentPrice = getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    uint256 baseRepayAmount = _toBase(_repayAmount, debtIndex);
    userData.debtBaseAmount -= baseRepayAmount;
    sliceData.totalBaseDebt -= baseRepayAmount;
    // transfer debt token

    userData.collateralDeposit -= _removeCollateral;
    sliceData.totalCollateralDeposit -= _removeCollateral;

    // does use memory here to save gas?
    if (
      _toNominal(userData.debtBaseAmount, debtIndex)
        >= userData.collateralDeposit * currentPrice
    ) {
      // throw error
    }

    //event and transfer collateral to user
  }

  function liquidateSlice() external { }

  function liquidateUser() external { }

  function claim() external { }

  function isUserLiquidateable(uint256 _slice, address _user) external view { }

  function isSliceLiquidateable(uint256 _slice, address _user) external view { }

  function createSlice(uint256 _price) internal {
    slices[_price] = SliceData(RAY, 0, RAY, 0, 0, 0, block.timestamp);
  }

  function _accureInterest(uint256 _slice) internal {
    SliceData storage slice = slices[_slice];

    uint256 timePassedSinceLastUpdate = block.timestamp - slice.lastUpdate;
    uint256 totalDebt = _toNominal(slice.totalBaseDebt, slice.debtIndex);
    uint256 interestAccuredPerYear = Math.mulDiv(totalDebt, interestRateBPS, BPS);
    uint256 interestAccured =
      Math.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);

    slice.debtIndex += Math.mulDiv(interestAccured, RAY, slice.totalBaseDebt);
    slice.depositIndex += Math.mulDiv(interestAccured, RAY, slice.totalBaseDeposit);
    slice.lastUpdate = block.timestamp;
  }

  // temporary. TODO: get price from standardised oracle interface
  function getCurrentPrice() internal view returns (uint256) {
    return 1000 * 1e18;
  }

  function _toNominal(uint256 _baseAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return Math.mulDiv(_baseAmount, _index, RAY);
  }

  function _toBase(uint256 _nominalAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return Math.mulDiv(_nominalAmount, RAY, _index);
  }

  // view function
}
