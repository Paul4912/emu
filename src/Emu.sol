// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "./library/Math.sol";

struct SliceData {
  //pack struct? do later
  uint256 depositIndex;
  uint256 totalBaseDeposit;
  uint256 debtIndex;
  uint256 totalBaseDebt;
  uint256 depositEpoch;
  uint256 lastUpdate;
}

contract Emu {
  uint256 constant RAY = 10 ** 27;
  uint256 constant interestRateBPS = 500;
  uint256 constant BPS = 10_000;
  uint256 constant secondsInYear = 31_536_000;
  address immutable COLLATERAL_TOKEN;
  address immutable DEBT_TOKEN;

  uint256[] public createdSlices;

  uint256 public claimableCollateralIndex;
  uint256 public claimableDebtTokenIndex;

  mapping(uint256 price => SliceData sliceData) private slices;
  mapping(address user => mapping(uint256 slice => uint256 baseAmount)) private
    lenderDeposits;
  mapping(address user => mapping(uint256 slice => uint256 epoch)) private lenderEpoch;
  mapping(address user => mapping(uint256 slice => uint256 baseAmount)) private
    borrowerDebts;
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    collateralDeposits;
  // struct instead of so many mappings??
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    userClaimableCollateralIndex;
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    userClaimableCollateralAmount;
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    userClaimableDebtTokenIndex;
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    userClaimableDebtTokenAmount;

  function depositDebtTokens(uint256 _slice, uint256 _amount) external {
    _accureInterest(_slice);
    // user claimable amount

    SliceData memory cachedSliceData = slices[_slice];

    if (lenderEpoch[msg.sender][_slice] < cachedSliceData.depositEpoch) {
      lenderDeposits[msg.sender][_slice] = 0;
      lenderEpoch[msg.sender][_slice] = cachedSliceData.depositEpoch;
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);

    lenderDeposits[msg.sender][_slice] += baseAmount;
    slices[_slice].totalBaseDeposit += baseAmount;

    // safe transfer

    //emit event
  }

  function withdrawDebtTokens(uint256 _slice, uint256 _amount) external {
    _accureInterest(_slice);
    // user claimable amount

    SliceData memory cachedSliceData = slices[_slice];

    if (lenderEpoch[msg.sender][_slice] < cachedSliceData.depositEpoch) {
      lenderDeposits[msg.sender][_slice] = 0;
      lenderEpoch[msg.sender][_slice] = cachedSliceData.depositEpoch;
      return;
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);

    lenderDeposits[msg.sender][_slice] -= baseAmount;
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
    collateralDeposits[msg.sender][_slice] += _addedCollateral;
    // transfer collateral token to contract from user

    // Check if slice is below current price

    // check if borrow is too much of their current collateral

    // borrow
    // transfer debt token and events
  }

  function repay(uint256 _slice, uint256 _repayAmount, uint256 _removeCollateral)
    external
  {
    // repay amount

    // transfer debt token

    collateralDeposits[msg.sender][_slice] -= _removeCollateral;
    // transfer collateral token to contract from user

    //event
  }

  function liquidateSlice() external { }

  function liquidateUser() external { }

  function claim() external { }

  function isUserLiquidateable(uint256 _slice, address _user) external view { }

  function isSliceLiquidateable(uint256 _slice, address _user) external view { }

  function createSlice(uint256 _price) internal {
    slices[_price] = SliceData(RAY, 0, RAY, 0, 0, block.timestamp);
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

  // Claim stuff
  // view function
}
