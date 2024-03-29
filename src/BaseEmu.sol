// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { FullMath } from "./libraries/FullMath.sol";
import { SliceData, UserLendingData, UserBorrowingData } from "./model/EmuModels.sol";
import { IBasicEmu } from "./interface/IBasicEmu.sol";
import { AggregatorV2V3Interface } from "./interface/AggregatorV2V3Interface.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

abstract contract BaseEmu is IBasicEmu, Ownable {
  using SafeERC20 for ERC20;

  uint256 internal constant RAY = 10 ** 27;
  uint256 internal constant interestRateBPS = 500;
  uint256 internal constant BPS = 10_000;
  uint256 internal constant secondsInYear = 31_536_000;

  uint256 public immutable SLICE_INTERVAL;
  ERC20 public immutable COLLATERAL_TOKEN;
  uint256 public immutable COLLATERAL_TOKEN_DECIMALS;
  ERC20 public immutable DEBT_TOKEN;
  uint256 public immutable DEBT_TOKEN_DECIMALS;
  uint256 public immutable LIQUIDATION_FEE; // Priced in debt tokens
  AggregatorV2V3Interface public immutable ORACLE;

  uint256[] public createdSlices;
  mapping(uint256 price => SliceData sliceData) internal slices; // uses whatever decimals oracle uses
  mapping(uint256 slice => mapping(uint256 epoch => uint256 data)) internal claimableData;
  mapping(address user => mapping(uint256 slice => UserLendingData data)) internal
    userLendingData;
  mapping(address user => mapping(uint256 slice => UserBorrowingData data)) internal
    userBorrowingData;
  mapping(uint256 slice => uint256 totalFees) internal heldLiquidationFee;

  constructor(
    address _collateralToken,
    address _debtToken,
    uint256 _liquidationFee,
    address _oracle,
    uint256 _sliceInterval
  ) Ownable(msg.sender) {
    COLLATERAL_TOKEN = ERC20(_collateralToken);
    COLLATERAL_TOKEN_DECIMALS = COLLATERAL_TOKEN.decimals();
    DEBT_TOKEN = ERC20(_debtToken);
    DEBT_TOKEN_DECIMALS = DEBT_TOKEN.decimals();
    LIQUIDATION_FEE = _liquidationFee;
    ORACLE = AggregatorV2V3Interface(_oracle);
    SLICE_INTERVAL = _sliceInterval;
  }

  function _depositDebtTokens(address _user, uint256 _slice, uint256 _amount)
    internal
    virtual
  {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[_user][_slice];

    _updateClaimableDetails(_user, _slice, userData.epoch);

    if (userData.epoch < cachedSliceData.depositEpoch) {
      userData.baseAmount = 0;
      userData.epoch = cachedSliceData.depositEpoch;
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);
    userData.baseAmount += baseAmount;
    slices[_slice].totalBaseDeposit += baseAmount;

    if (_amount > 0) {
      DEBT_TOKEN.safeTransferFrom(_user, address(this), _amount);
    }

    emit LendDebtTokens(_user, _slice, _amount);
  }

  function _withdrawDebtTokens(address _user, uint256 _slice, uint256 _amount)
    internal
    virtual
  {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    SliceData memory cachedSliceData = slices[_slice];
    UserLendingData storage userData = userLendingData[_user][_slice];

    _updateClaimableDetails(_user, _slice, userData.epoch);

    if (userData.epoch < cachedSliceData.depositEpoch) {
      userData.baseAmount = 0;
      userData.epoch = cachedSliceData.depositEpoch;
      return;
    }

    if (
      _amount + _toNominal(cachedSliceData.totalBaseDebt, cachedSliceData.debtIndex)
        + heldLiquidationFee[_slice]
        > _toNominal(cachedSliceData.totalBaseDeposit, cachedSliceData.depositIndex)
    ) {
      revert InsufficientUnlentLiquidity();
    }

    uint256 baseAmount = _toBase(_amount, cachedSliceData.depositIndex);
    userData.baseAmount -= baseAmount;
    slices[_slice].totalBaseDeposit -= baseAmount;

    if (_amount > 0) {
      DEBT_TOKEN.safeTransfer(_user, _amount);
    }

    emit WithdrawDebtTokens(_user, _slice, _amount);
  }

  function _borrow(
    address _user,
    uint256 _slice,
    uint256 _borrowAmount,
    uint256 _addedCollateral
  ) internal virtual {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[_user][_slice];
    SliceData storage sliceData = slices[_slice];
    (uint256 currentPrice, uint8 decimals) = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    if (currentPrice <= _slice) {
      revert SliceIsLiquidatable();
    }

    userData.collateralDeposit += _addedCollateral;
    sliceData.totalCollateralDeposit += _addedCollateral;

    COLLATERAL_TOKEN.safeTransferFrom(_user, address(this), _addedCollateral);

    if (userData.baseAmount == 0) {
      heldLiquidationFee[_slice] += LIQUIDATION_FEE;
    }

    uint256 baseBorrowAmount = _toBase(_borrowAmount - LIQUIDATION_FEE, debtIndex);
    userData.baseAmount += baseBorrowAmount;
    sliceData.totalBaseDebt += baseBorrowAmount;

    if (
      _isCollateralLiquidatable(
        _toNominal(userData.baseAmount, debtIndex),
        userData.collateralDeposit,
        currentPrice,
        decimals
      )
    ) {
      revert PositionIsLiquidatable();
    }

    if (
      _toNominal(sliceData.totalBaseDebt, debtIndex) + heldLiquidationFee[_slice]
        > _toNominal(sliceData.totalBaseDeposit, sliceData.depositIndex)
    ) {
      revert InsufficientUnlentLiquidity();
    }

    DEBT_TOKEN.safeTransfer(_user, _borrowAmount);

    emit Borrow(_user, _slice, _borrowAmount, _addedCollateral);
  }

  function _repayAll(address _user, uint256 _slice) internal virtual {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[_user][_slice];
    SliceData storage sliceData = slices[_slice];

    uint256 baseRepayAmount = userData.baseAmount;
    userData.baseAmount = 0;
    sliceData.totalBaseDebt -= baseRepayAmount;

    uint256 nominalRepayAmount = _toNominal(baseRepayAmount, slices[_slice].debtIndex);
    DEBT_TOKEN.safeTransferFrom(_user, address(this), nominalRepayAmount);

    uint256 collateralToWithdraw = userData.collateralDeposit;
    userData.collateralDeposit = 0;
    sliceData.totalCollateralDeposit -= collateralToWithdraw;

    heldLiquidationFee[_slice] -= LIQUIDATION_FEE;

    COLLATERAL_TOKEN.safeTransfer(_user, collateralToWithdraw);

    emit Repay(_user, _slice, nominalRepayAmount, collateralToWithdraw);
  }

  function _repay(
    address _user,
    uint256 _slice,
    uint256 _repayAmount,
    uint256 _removeCollateral
  ) internal virtual {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    UserBorrowingData storage userData = userBorrowingData[_user][_slice];
    SliceData storage sliceData = slices[_slice];
    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    uint256 debtIndex = slices[_slice].debtIndex;

    uint256 baseRepayAmount = _toBase(_repayAmount, debtIndex);
    if (baseRepayAmount > userData.baseAmount) {
      _repayAll(_user, _slice);
      return;
    } else {
      userData.baseAmount -= baseRepayAmount;
      sliceData.totalBaseDebt -= baseRepayAmount;
    }

    DEBT_TOKEN.safeTransferFrom(_user, address(this), _repayAmount);

    userData.collateralDeposit -= _removeCollateral;
    sliceData.totalCollateralDeposit -= _removeCollateral;

    if (
      _isCollateralLiquidatable(
        _toNominal(userData.baseAmount, debtIndex),
        userData.collateralDeposit,
        currentPrice,
        decimals
      )
    ) {
      revert PositionIsLiquidatable();
    }

    COLLATERAL_TOKEN.safeTransfer(_user, _removeCollateral);

    emit Repay(_user, _slice, _repayAmount, _removeCollateral);
  }

  function _liquidateUser(address _user, uint256 _slice) internal virtual {
    _checkSliceExists(_slice);
    _accureInterest(_slice);

    if (!isUserLiquidateable(_slice, _user)) {
      revert PositionCannotBeLiquidated();
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
      liquidatedSliceData.depositIndex = RAY;
      liquidatedSliceData.totalBaseDeposit = 0;
      ++liquidatedSliceData.depositEpoch;
      claimableData[_slice][liquidatedSliceData.depositEpoch] = RAY;
    } else {
      liquidatedSliceData.depositIndex -=
        FullMath.mulDiv(cachedTotalDebtLiquidated, RAY, cachedTotalBaseDeposit);
    }

    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    uint256 userCollateralLiquidated =
      FullMath.mulDiv(cachedTotalDebtLiquidated, currentPrice, decimals);
    userCollateralLiquidated = userCollateralLiquidated < userData.collateralDeposit
      ? userCollateralLiquidated
      : userData.collateralDeposit;
    claimableData[_slice][liquidatedSliceData.depositEpoch] +=
      FullMath.mulDiv(userCollateralLiquidated, RAY, cachedTotalBaseDeposit);

    liquidatedSliceData.totalCollateralDeposit -= userCollateralLiquidated;
    userData.collateralDeposit -= userCollateralLiquidated;
    liquidatedSliceData.totalBaseDebt -= userData.baseAmount;
    userData.baseAmount = 0;

    heldLiquidationFee[_slice] -= LIQUIDATION_FEE;
    DEBT_TOKEN.safeTransfer(msg.sender, LIQUIDATION_FEE);

    emit UserLiquidation(_user, _slice);
  }

  function _claimBonusCollateral(address _user, uint256 _slice) internal virtual {
    _checkSliceExists(_slice);

    UserLendingData storage userData = userLendingData[_user][_slice];
    _updateClaimableDetails(_user, _slice, userData.epoch);

    uint256 amountCollateralToTransfer = userData.claimableCollateralAmount;
    userData.claimableCollateralAmount = 0;

    if (amountCollateralToTransfer > 0) {
      COLLATERAL_TOKEN.safeTransfer(_user, amountCollateralToTransfer);
    }

    emit BonusCollateralClaimed(_user, _slice);
  }

  function _createSlice(uint256 _price) internal virtual {
    if (_price % SLICE_INTERVAL > 0) {
      revert InvalidSlicePosition();
    }

    if (slices[_price].lastUpdate > 0) {
      revert SliceAlreadyExists();
    }

    slices[_price] = SliceData(RAY, 0, RAY, 0, 0, uint128(block.timestamp), 0, 0);
    claimableData[_price][0] = RAY;
    createdSlices.push(_price);
  }

  function _accureInterest(uint256 _slice) internal {
    SliceData storage slice = slices[_slice];
    uint256 totalBaseDebt = slice.totalBaseDebt;
    uint256 totalBaseDeposit = slice.totalBaseDeposit;

    if (totalBaseDebt == 0 || totalBaseDeposit == 0) {
      return;
    }

    uint256 timePassedSinceLastUpdate = block.timestamp - slice.lastUpdate;
    uint256 totalDebt = _toNominal(totalBaseDebt, slice.debtIndex);
    uint256 interestAccuredPerYear = FullMath.mulDiv(totalDebt, interestRateBPS, BPS);
    uint256 interestAccured =
      FullMath.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);

    slice.debtIndex += FullMath.mulDiv(interestAccured, RAY, totalBaseDebt);
    slice.depositIndex += FullMath.mulDiv(interestAccured, RAY, totalBaseDeposit);
    slice.lastUpdate = uint128(block.timestamp);
  }

  function _updateClaimableDetails(address _user, uint256 _slice, uint256 _epoch)
    internal
  {
    uint256 sliceClaimableCollateralIndex = claimableData[_slice][_epoch];

    UserLendingData storage userData = userLendingData[_user][_slice];
    uint256 userBaseDeposit = userData.baseAmount;

    userData.claimableCollateralAmount += FullMath.mulDiv(
      (sliceClaimableCollateralIndex - userData.claimableCollateralIndex),
      userBaseDeposit,
      RAY
    );
    userData.claimableCollateralIndex = sliceClaimableCollateralIndex;
  }

  function isUserLiquidateable(uint256 _slice, address _user) public view returns (bool) {
    (uint256 currentPrice, uint256 decimals) = _getCurrentPrice();
    if (_slice >= currentPrice) return true;

    UserBorrowingData memory userData = userBorrowingData[_user][_slice];
    SliceData memory slice = slices[_slice];

    if (userData.baseAmount == 0) {
      return false;
    }

    uint256 timePassedSinceLastUpdate = block.timestamp - slice.lastUpdate;
    uint256 totalDebt = _toNominal(slice.totalBaseDebt, slice.debtIndex);
    uint256 interestAccuredPerYear = FullMath.mulDiv(totalDebt, interestRateBPS, BPS);
    uint256 interestAccured =
      FullMath.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);
    uint256 actualDebtIndex =
      slice.debtIndex + FullMath.mulDiv(interestAccured, RAY, slice.totalBaseDebt);

    if (
      _isCollateralLiquidatable(
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

  function getSliceData(uint256 _slice) external view returns (SliceData memory) {
    return slices[_slice];
  }

  function getClaimableData(uint256 _slice, uint256 _epoch)
    external
    view
    returns (uint256)
  {
    return claimableData[_slice][_epoch];
  }

  function getUserLendingData(address _user, uint256 _slice)
    external
    view
    returns (UserLendingData memory)
  {
    return userLendingData[_user][_slice];
  }

  function getUserBorrowingData(address _user, uint256 _slice)
    external
    view
    returns (UserBorrowingData memory)
  {
    return userBorrowingData[_user][_slice];
  }

  function getSliceLiquidity(uint256 _slice)
    external
    view
    returns (
      uint256 totalDebtTokenDeposits_,
      uint256 totalDebt_,
      uint256 totalUnlentLiquidity_
    )
  {
    SliceData memory sliceData = slices[_slice];
    totalDebtTokenDeposits_ =
      _toNominal(sliceData.totalBaseDeposit, sliceData.depositIndex);
    totalDebt_ = _toNominal(sliceData.totalBaseDebt, sliceData.debtIndex);
    totalUnlentLiquidity_ = totalDebtTokenDeposits_ - totalDebt_;
  }

  function getUserDebtTokenDeposit(address _user, uint256 _slice)
    external
    view
    returns (uint256)
  {
    SliceData memory sliceData = slices[_slice];
    UserLendingData memory userData = userLendingData[_user][_slice];

    if (userData.epoch < sliceData.depositEpoch) {
      return 0;
    }

    uint256 actualDepositIndex;

    if (sliceData.totalBaseDeposit > 0) {
      uint256 timePassedSinceLastUpdate = block.timestamp - sliceData.lastUpdate;
      uint256 totalDebt = _toNominal(sliceData.totalBaseDebt, sliceData.debtIndex);
      uint256 interestAccuredPerYear = FullMath.mulDiv(totalDebt, interestRateBPS, BPS);
      uint256 interestAccured =
        FullMath.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);
      actualDepositIndex = sliceData.depositIndex
        + FullMath.mulDiv(interestAccured, RAY, sliceData.totalBaseDeposit);
    } else {
      actualDepositIndex = sliceData.depositIndex;
    }

    return _toNominal(userData.baseAmount, actualDepositIndex);
  }

  function getUserCollateral(address _user, uint256 _slice)
    external
    view
    returns (uint256)
  {
    return userBorrowingData[_user][_slice].collateralDeposit;
  }

  function getUserDebt(address _user, uint256 _slice) external view returns (uint256) {
    SliceData memory sliceData = slices[_slice];
    UserBorrowingData memory userData = userBorrowingData[_user][_slice];

    uint256 actualDebtIndex;

    if (sliceData.totalBaseDebt > 0) {
      uint256 timePassedSinceLastUpdate = block.timestamp - sliceData.lastUpdate;
      uint256 totalDebt = _toNominal(sliceData.totalBaseDebt, sliceData.debtIndex);
      uint256 interestAccuredPerYear = FullMath.mulDiv(totalDebt, interestRateBPS, BPS);
      uint256 interestAccured =
        FullMath.mulDiv(interestAccuredPerYear, timePassedSinceLastUpdate, secondsInYear);
      actualDebtIndex = sliceData.debtIndex
        + FullMath.mulDiv(interestAccured, RAY, sliceData.totalBaseDebt);
    } else {
      actualDebtIndex = sliceData.debtIndex;
    }

    return _toNominal(userData.baseAmount, actualDebtIndex);
  }

  function getClaimableAmount(address _user, uint256 _slice)
    external
    view
    returns (uint256 collateral_)
  {
    UserLendingData storage userData = userLendingData[_user][_slice];
    collateral_ = userData.claimableCollateralAmount;
    uint256 userBaseDeposit = userData.baseAmount;

    uint256 sliceClaimableCollateralIndex = claimableData[_slice][userData.epoch];

    collateral_ += FullMath.mulDiv(
      (sliceClaimableCollateralIndex - userData.claimableCollateralIndex),
      userBaseDeposit,
      RAY
    );
  }

  function doesSliceExists(uint256 _slice) external view returns (bool) {
    if (slices[_slice].lastUpdate > 0) {
      return true;
    }
    return false;
  }

  function getExistingSlices() external view returns (uint256[] memory) {
    return createdSlices;
  }

  function _checkSliceExists(uint256 _slice) internal view {
    if (slices[_slice].lastUpdate == 0) {
      revert SliceDoesNotExist();
    }
  }

  function _getCurrentPrice() internal view returns (uint256, uint8) {
    int256 rawLatestAnswer = ORACLE.latestAnswer();
    uint256 latestAnswer = rawLatestAnswer > 0 ? uint256(rawLatestAnswer) : 0;
    return (latestAnswer, ORACLE.decimals());
  }

  function _isCollateralLiquidatable(
    uint256 _debtAmountNominal,
    uint256 _collateralAmountNominal,
    uint256 _price,
    uint256 _priceDecimals
  ) internal view returns (bool) {
    uint256 normalisedCollateralValue =
      FullMath.mulDiv(_collateralAmountNominal, _price, COLLATERAL_TOKEN_DECIMALS);
    uint256 normalisedDebtValue =
      FullMath.mulDiv(_debtAmountNominal, _priceDecimals, DEBT_TOKEN_DECIMALS);

    if (normalisedCollateralValue > normalisedDebtValue + LIQUIDATION_FEE) {
      return false;
    }

    return true;
  }

  function _toNominal(uint256 _baseAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return FullMath.mulDiv(_baseAmount, _index, RAY);
  }

  function _toBase(uint256 _nominalAmount, uint256 _index)
    internal
    pure
    returns (uint256)
  {
    return FullMath.mulDiv(_nominalAmount, RAY, _index);
  }
}
