// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { BaseEmu } from "./BaseEmu.sol";

contract StandardEmu is BaseEmu {
  constructor(
    address _collateralToken,
    address _debtToken,
    uint256 _liquidationFee,
    address _oracle,
    uint256 _sliceInterval
  ) BaseEmu(_collateralToken, _debtToken, _liquidationFee, _oracle, _sliceInterval) { }

  function depositDebtTokens(uint256 _slice, uint256 _amount) external {
    _depositDebtTokens(msg.sender, _slice, _amount);
  }

  function withdrawDebtTokens(uint256 _slice, uint256 _amount) external {
    _withdrawDebtTokens(msg.sender, _slice, _amount);
  }

  function borrow(uint256 _slice, uint256 _borrowAmount, uint256 _addedCollateral)
    external
  {
    _borrow(msg.sender, _slice, _borrowAmount, _addedCollateral);
  }

  function repayAll(uint256 _slice) external {
    _repayAll(msg.sender, _slice);
  }

  function repay(uint256 _slice, uint256 _repayAmount, uint256 _removeCollateral)
    external
  {
    _repay(msg.sender, _slice, _repayAmount, _removeCollateral);
  }

  function liquidateUser(address _user, uint256 _slice) external {
    _liquidateUser(_user, _slice);
  }

  function claimBonusCollateral(uint256 _slice) external {
    _claimBonusCollateral(msg.sender, _slice);
  }
}
