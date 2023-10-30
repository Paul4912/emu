// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "./library/Math.sol";

// chuck into models folder
struct SliceData {
  //pack struct? do later
  uint256 depositIndex;
  uint256 totalBaseDeposit;
  uint256 debtIndex;
  uint256 totalBaseDebt;
  uint256 totalCollateralDeposit;
  uint256 depositEpoch;
  uint256 borrowingEpoch;
  uint256 lastUpdate;
}

struct ClaimableData {
  uint256 claimableCollateralIndex;
  uint256 claimableDebtTokenIndex;
}

struct UserLendingData {
  uint256 baseAmount;
  uint256 epoch;
  uint256 claimableCollateralIndex;
  uint256 claimableCollateralAmount;
  uint256 claimableDebtTokenIndex;
  uint256 claimableDebtTokenAmount;
}

struct UserBorrowingData {
  uint256 debtBaseAmount;
  uint256 collateralDeposit;
  uint256 epoch;
}

contract Emu {
  uint256 constant RAY = 10 ** 27;
  uint256 constant interestRateBPS = 500;
  uint256 constant BPS = 10_000;
  uint256 constant secondsInYear = 31_536_000;
  address public COLLATERAL_TOKEN; //MAKE IMMUTABLE
  address public DEBT_TOKEN;
  // TODO fee system.

  uint256[] public createdSlices;
  mapping(uint256 price => SliceData sliceData) private slices;
  mapping(uint256 slice => mapping(uint256 epoch => ClaimableData data)) private
    claimableData; // initalise to ray at start of each epoch

  mapping(address user => mapping(uint256 slice => UserLendingData data)) private
    userLendingData;
  mapping(address user => mapping(uint256 slice => UserBorrowingData data)) private
    userBorrowingData;

  function depositDebtTokens(uint256 _slice, uint256 _amount) external {
    _accureInterest(_slice);

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[msg.sender][_slice];

    _updateClaimableDetails(msg.sender, _slice, userData.epoch);

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

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[msg.sender][_slice];

    _updateClaimableDetails(msg.sender, _slice, userData.epoch);

    if (userData.epoch < cachedSliceData.depositEpoch) {
      userData.baseAmount = 0;
      userData.epoch = cachedSliceData.depositEpoch;
      return;
    }

    if (
      _amount + _toNominal(cachedSliceData.totalBaseDebt, cachedSliceData.debtIndex)
        > _toNominal(cachedSliceData.totalBaseDeposit, cachedSliceData.depositIndex)
    ) {
      //throw error
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);

    userData.baseAmount -= baseAmount;
    slices[_slice].totalBaseDeposit -= baseAmount;

    // trasnfer
    //emit event
  }

  function borrow(uint256 _slice, uint256 _borrowAmount, uint256 _addedCollateral)
    external
  {
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[msg.sender][_slice];
    SliceData storage sliceData = slices[_slice];
    uint256 currentPrice = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    if (_slice >= currentPrice) {
      // throw error cant borrow
    }

    // use memory for epoch for gas saving?
    if (userData.epoch < sliceData.borrowingEpoch) {
      userData.debtBaseAmount = 0;
      userData.collateralDeposit = 0;
      userData.epoch = sliceData.borrowingEpoch;
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
    uint256 currentPrice = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    // use memory for epoch for gas saving?
    if (userData.epoch < sliceData.borrowingEpoch) {
      userData.debtBaseAmount = 0;
      userData.collateralDeposit = 0;
      userData.epoch = sliceData.borrowingEpoch;
      return;
    }

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

  function liquidateSlice(uint256 _slice) public {
    _accureInterest(_slice);

    if (!isSliceLiquidateable(_slice)) {
      //throw error not liquidatable
    }

    SliceData storage liquidatedSliceData = slices[_slice];

    uint256 cachedTotalBaseDeposit = liquidatedSliceData.totalBaseDeposit;
    uint256 cachedTotalDebtLiquidated =
      _toNominal(liquidatedSliceData.totalBaseDebt, liquidatedSliceData.debtIndex);

    claimableData[_slice][liquidatedSliceData.depositEpoch].claimableCollateralIndex +=
      Math.mulDiv(liquidatedSliceData.totalCollateralDeposit, RAY, cachedTotalBaseDeposit);

    if (
      cachedTotalDebtLiquidated
        >= _toNominal(cachedTotalBaseDeposit, liquidatedSliceData.depositIndex)
    ) {
      liquidatedSliceData.depositIndex = RAY;
      liquidatedSliceData.totalBaseDeposit = 0;
      ++liquidatedSliceData.depositEpoch;
      claimableData[_slice][liquidatedSliceData.depositEpoch].claimableCollateralIndex =
        RAY;
      claimableData[_slice][liquidatedSliceData.depositEpoch].claimableDebtTokenIndex =
        RAY;
    } else {
      liquidatedSliceData.depositIndex -=
        Math.mulDiv(cachedTotalDebtLiquidated, RAY, cachedTotalBaseDeposit);
    }

    liquidatedSliceData.totalCollateralDeposit = 0;
    liquidatedSliceData.totalBaseDebt = 0;
    liquidatedSliceData.debtIndex = RAY;
    ++liquidatedSliceData.borrowingEpoch;
  }

  function liquidateUser(address _user, uint256 _slice) external {
    _accureInterest(_slice);

    if (!isUserLiquidateable(_slice, _user)) {
      //throw error not liquidatable
    }

    UserBorrowingData storage userData = userBorrowingData[_user][_slice];
    SliceData storage liquidatedSliceData = slices[_slice];

    uint256 cachedTotalBaseDeposit = liquidatedSliceData.totalBaseDeposit;
    uint256 cachedTotalDebtLiquidated =
      _toNominal(userData.debtBaseAmount, liquidatedSliceData.debtIndex);

    if (
      cachedTotalDebtLiquidated
        >= _toNominal(cachedTotalBaseDeposit, liquidatedSliceData.depositIndex)
    ) {
      liquidateSlice(_slice);
      return;
    }

    liquidatedSliceData.depositIndex -=
      Math.mulDiv(cachedTotalDebtLiquidated, RAY, cachedTotalBaseDeposit);
    claimableData[_slice][liquidatedSliceData.depositEpoch].claimableCollateralIndex +=
      Math.mulDiv(userData.collateralDeposit, RAY, cachedTotalBaseDeposit);

    liquidatedSliceData.totalCollateralDeposit -= userData.collateralDeposit;
    userData.collateralDeposit = 0;
    liquidatedSliceData.totalBaseDebt -= userData.debtBaseAmount;
    userData.debtBaseAmount = 0;
  }

  function claimBonusAndFees(uint256 _slice) external {
    UserLendingData storage userData = userLendingData[msg.sender][_slice];
    _updateClaimableDetails(msg.sender, _slice, userData.epoch);

    uint256 amountCollateralToTransfer = userData.claimableCollateralAmount;
    uint256 amountDebtTokenToTransfer = userData.claimableDebtTokenAmount;

    userData.claimableCollateralAmount = 0;
    userData.claimableDebtTokenAmount = 0;

    if (amountCollateralToTransfer > 0) {
      // transfer
    }

    if (amountDebtTokenToTransfer > 0) {
      // transfer
    }
  }

  function createSlice(uint256 _price) internal {
    slices[_price] = SliceData(RAY, 0, RAY, 0, 0, 0, 0, block.timestamp);
    claimableData[_price][0] = ClaimableData(RAY, RAY);
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

  function _updateClaimableDetails(address _user, uint256 _slice, uint256 _epoch)
    internal
  {
    uint256 sliceClaimableCollateralIndex =
      claimableData[_slice][_epoch].claimableCollateralIndex;
    uint256 sliceClaimableDebtIndex =
      claimableData[_slice][_epoch].claimableDebtTokenIndex;

    UserLendingData storage userData = userLendingData[_user][_slice];
    uint256 userBaseDeposit = userData.baseAmount;

    userData.claimableCollateralAmount += (
      sliceClaimableCollateralIndex - userData.claimableCollateralIndex
    ) * userBaseDeposit;
    userData.claimableCollateralIndex = sliceClaimableCollateralIndex;

    userData.claimableDebtTokenAmount +=
      (sliceClaimableDebtIndex - userData.claimableDebtTokenIndex) * userBaseDeposit;
    userData.claimableDebtTokenIndex = sliceClaimableDebtIndex;
  }

  function isUserLiquidateable(uint256 _slice, address _user) public view returns (bool) {
    uint256 currentPrice = _getCurrentPrice();
    if (_slice >= currentPrice) return true;

    UserBorrowingData memory userData = userBorrowingData[_user][_slice];
    SliceData memory slice = slices[_slice];

    // not current epoc

    if (userData.epoch < slice.borrowingEpoch) {
      return false;
    }

    uint256 timePassedSinceLastUpdate = block.timestamp - slice.lastUpdate;
    uint256 totalDebt = _toNominal(slice.totalBaseDebt, slice.debtIndex);
    uint256 interestAccuredPerYear = Math.mulDiv(totalDebt, interestRateBPS, BPS);
    uint256 interestAccured =
      Math.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);
    uint256 actualDebtIndex =
      slice.debtIndex + Math.mulDiv(interestAccured, RAY, slice.totalBaseDebt);

    if (
      _toNominal(userData.debtBaseAmount, actualDebtIndex)
        >= userData.collateralDeposit * currentPrice
    ) {
      return true;
    }

    return false;
  }

  function isSliceLiquidateable(uint256 _slice) public view returns (bool) {
    return _slice >= _getCurrentPrice();
  }

  // temporary. TODO: get price from standardised oracle interface
  function _getCurrentPrice() internal view returns (uint256) {
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
