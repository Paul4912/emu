// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "./library/Math.sol";
import {
  SliceData,
  ClaimableData,
  UserLendingData,
  UserBorrowingData
} from "./model/EmuModels.sol";
import { IEmu } from "./interface/IEmu.sol";
import { AggregatorV2V3Interface } from "./interface/AggregatorV2V3Interface.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Emu is IEmu {
  using SafeERC20 for ERC20;

  uint256 constant WAD = 10 ** 18;
  uint256 constant RAY = 10 ** 27;
  uint256 constant interestRateBPS = 500;
  uint256 constant BPS = 10_000;
  uint256 constant secondsInYear = 31_536_000;
  ERC20 immutable COLLATERAL_TOKEN;
  uint256 immutable COLLATERAL_TOKEN_DECIMALS;
  ERC20 immutable DEBT_TOKEN;
  uint256 immutable DEBT_TOKEN_DECIMALS;
  AggregatorV2V3Interface immutable ORACLE;

  address public feeReciever;
  // TODO fee system.

  uint256[] public createdSlices;
  mapping(uint256 price => SliceData sliceData) private slices; // use whatever decimals oracle uses
  mapping(uint256 slice => mapping(uint256 epoch => ClaimableData data)) private
    claimableData;

  mapping(address user => mapping(uint256 slice => UserLendingData data)) private
    userLendingData;
  mapping(address user => mapping(uint256 slice => UserBorrowingData data)) private
    userBorrowingData;

  constructor(
    address _collateralToken,
    address _debtToken,
    address _oracle,
    address _feeReciever
  ) {
    COLLATERAL_TOKEN = ERC20(_collateralToken);
    COLLATERAL_TOKEN_DECIMALS = COLLATERAL_TOKEN.decimals();
    DEBT_TOKEN = ERC20(_debtToken);
    DEBT_TOKEN_DECIMALS = DEBT_TOKEN.decimals();
    ORACLE = AggregatorV2V3Interface(_oracle);
    feeReciever = _feeReciever;
  }

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

    DEBT_TOKEN.transferFrom(msg.sender, address(this), _amount);

    emit LendDebtTokens(msg.sender, _slice, _amount);
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

    DEBT_TOKEN.transfer(msg.sender, _amount);

    emit WithdrawDebtTokens(msg.sender, _slice, _amount);
  }

  function borrow(uint256 _slice, uint256 _borrowAmount, uint128 _addedCollateral)
    external
  {
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[msg.sender][_slice];
    SliceData storage sliceData = slices[_slice];
    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;
    if (_slice >= currentPrice) {
      // throw error cant borrow
    }

    // use memory for epoch for gas saving?
    if (userData.epoch < sliceData.borrowingEpoch) {
      userData.baseAmount = 0;
      userData.collateralDeposit = 0;
      userData.epoch = sliceData.borrowingEpoch;
    }

    userData.collateralDeposit += _addedCollateral;
    sliceData.totalCollateralDeposit += _addedCollateral;

    COLLATERAL_TOKEN.transferFrom(msg.sender, address(this), _addedCollateral);

    uint256 baseBorrowAmount = _toBase(_borrowAmount, debtIndex);
    userData.baseAmount += baseBorrowAmount;
    sliceData.totalBaseDebt += baseBorrowAmount;

    if (
      _isCollateralUnderwater(
        _toNominal(userData.baseAmount, debtIndex),
        userData.collateralDeposit,
        currentPrice,
        decimals
      )
    ) {
      // throw error
    }

    DEBT_TOKEN.transfer(msg.sender, _borrowAmount);

    emit Borrow(msg.sender, _slice, _borrowAmount, _addedCollateral);
  }

  function repay(uint256 _slice, uint256 _repayAmount, uint128 _removeCollateral)
    external
  {
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[msg.sender][_slice];
    SliceData storage sliceData = slices[_slice];
    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    // use memory for epoch for gas saving?
    if (userData.epoch < sliceData.borrowingEpoch) {
      userData.baseAmount = 0;
      userData.collateralDeposit = 0;
      userData.epoch = sliceData.borrowingEpoch;
      return;
    }

    uint256 baseRepayAmount = _toBase(_repayAmount, debtIndex);
    userData.baseAmount -= baseRepayAmount;
    sliceData.totalBaseDebt -= baseRepayAmount;

    DEBT_TOKEN.transferFrom(msg.sender, address(this), _repayAmount);

    userData.collateralDeposit -= _removeCollateral;
    sliceData.totalCollateralDeposit -= _removeCollateral;

    if (
      _isCollateralUnderwater(
        _toNominal(userData.baseAmount, debtIndex),
        userData.collateralDeposit,
        currentPrice,
        decimals
      )
    ) {
      // throw error
    }

    COLLATERAL_TOKEN.transfer(msg.sender, _removeCollateral);

    emit Repay(msg.sender, _slice, _repayAmount, _removeCollateral);
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

    emit SliceLiquidation(_slice);
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
      _toNominal(userData.baseAmount, liquidatedSliceData.debtIndex);

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
    liquidatedSliceData.totalBaseDebt -= userData.baseAmount;
    userData.baseAmount = 0;

    emit UserLiquidation(_user, _slice);
  }

  function claimBonusAndFees(uint256 _slice) external {
    UserLendingData storage userData = userLendingData[msg.sender][_slice];
    _updateClaimableDetails(msg.sender, _slice, userData.epoch);

    uint256 amountCollateralToTransfer = userData.claimableCollateralAmount;
    uint256 amountDebtTokenToTransfer = userData.claimableDebtTokenAmount;

    userData.claimableCollateralAmount = 0;
    userData.claimableDebtTokenAmount = 0;

    if (amountCollateralToTransfer > 0) {
      COLLATERAL_TOKEN.transfer(msg.sender, amountCollateralToTransfer);
    }

    if (amountDebtTokenToTransfer > 0) {
      DEBT_TOKEN.transfer(msg.sender, amountDebtTokenToTransfer);
    }

    emit ClaimBonusAndFees(msg.sender, _slice);
  }

  // change fee reciever

  function createSlice(uint256 _price) internal {
    slices[_price] = SliceData(RAY, 0, RAY, 0, 0, uint128(block.timestamp), 0, 0);
    claimableData[_price][0] = ClaimableData(RAY, RAY);
    createdSlices.push(_price);
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
    slice.lastUpdate = uint128(block.timestamp);
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
    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    if (_slice >= currentPrice) return true;

    UserBorrowingData memory userData = userBorrowingData[_user][_slice];
    SliceData memory slice = slices[_slice];

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
      _isCollateralUnderwater(
        _toNominal(userData.baseAmount, actualDebtIndex),
        userData.collateralDeposit,
        currentPrice,
        decimals
      )
    ) {
      return true;
    }

    return false;
  }

  function isSliceLiquidateable(uint256 _slice) public view returns (bool) {
    (uint256 currentPrice,) = _getCurrentPrice();

    return _slice >= currentPrice;
  }

  function _getCurrentPrice() internal view returns (uint256, uint256) {
    int256 rawLatestAnswer = ORACLE.latestAnswer();
    uint256 latestAnswer = rawLatestAnswer > 0 ? uint256(rawLatestAnswer) : 0;
    return (latestAnswer, uint256(ORACLE.decimals()));
  }

  function _isCollateralUnderwater(
    uint256 _debtAmount,
    uint256 _collateralAmount,
    uint256 _price,
    uint256 _priceDecimals
  ) internal view returns (bool) {
    uint256 normalisedCollateralValue =
      Math.mulDiv(_collateralAmount, _price, COLLATERAL_TOKEN_DECIMALS);
    uint256 normalisedDebtValue =
      Math.mulDiv(_debtAmount, _priceDecimals, DEBT_TOKEN_DECIMALS);

    if (normalisedCollateralValue > normalisedDebtValue) {
      return false;
    }

    return true;
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
