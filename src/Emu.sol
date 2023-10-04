// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct SliceData {
  uint256 depositIndex;
  uint256 totalBaseDeposit;
  uint256 debtIndex;
  uint256 totalBaseDebt;
  uint256 lastUpdate;
}

contract Emu {
  uint256 constant RAY = 10 ** 27;
  uint256 constant interestRateBPS = 500;
  uint256 constant BPS = 10_000;
  uint256 constant secondsInYear = 31_536_000;

  uint256[] public createdSlices; // Array of prices of slices that have been creted

  mapping(uint256 price => SliceData sliceData) private slices;
  mapping(address user => mapping(uint256 slice => uint256 baseAmount)) private
    lenderDeposits;
  mapping(address user => mapping(uint256 slice => uint256 baseAmount)) private
    borrowerDebts;
  mapping(address user => mapping(uint256 slice => uint256 amount)) private
    collateralDeposits;

  function _accureInterest(uint256 _slice) internal {
    SliceData storage slice = slices[_slice];
    uint256 timePassedSinceLastUpdate = block.timestamp - slice.lastUpdate;
    uint256 totalDebt = _toNominal(slice.totalBaseDebt, slice.debtIndex);
    uint256 interestAccuredPerYear = totalDebt * interestRateBPS / BPS;
    uint256 interestAccured = interestAccuredPerYear / secondsInYear;
    uint256 newTotalDebt = totalDebt + interestAccured;
  }

  function _toNominal(uint256 _baseAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return _baseAmount * _index / RAY;
  }

  function _toBase(uint256 _nominalAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return _nominalAmount * RAY / _index;
  }

  //check liqudate possible
  //create slice
  // deposit in slice
  // borrow from slice + deposit collateral
  // just deposit collateral or just borrow
  // repay loan
  // liquidate
  // accural interest
}
