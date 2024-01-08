pragma solidity ^0.8.17;

import "test/base/BaseTest.t.sol";
import "forge-std/console.sol";
import { BasicEmu } from "src/BasicEmu.sol";
import { EEmu } from "src/interface/EEmu.sol";
import { AggregatorV2V3Interface } from "src/interface/AggregatorV2V3Interface.sol";
import { MockERC20 } from "test/mock/contract/MockERC20.sol";

contract EmuTest is BaseTest, EEmu {
  uint256 internal constant secondsInYear = 31_536_000;

  address private owner = generateAddress("Owner", false);
  address private borrowerA = generateAddress("borrowerA", false);
  address private borrowerB = generateAddress("borrowerB", false);
  address private lenderA = generateAddress("lenderA", false);
  address private lenderB = generateAddress("lenderB", false);
  address private mockOracle = generateAddress("mockOracle", true);

  MockERC20 private debtToken;
  MockERC20 private collateralToken;

  BasicEmu private underTest;

  function setUp() external prankAs(owner) {
    debtToken = new MockERC20("debtToken", "USDC", 18);
    collateralToken = new MockERC20("collateralToken", "ETH", 18);
    underTest =
    new BasicEmu(address(collateralToken), address(debtToken), 0, address(mockOracle), 50e18);

    _mintInitialTokens();
    _createInitialSlices();

    _mockOraclePrice(2000e18);
    vm.mockCall(
      mockOracle,
      abi.encodeWithSelector(AggregatorV2V3Interface.decimals.selector),
      abi.encode(18)
    );
  }

  function test_constructor_InitialParameteresCorrectlySetup() external prankAs(owner) {
    assertEq(underTest.owner(), owner);
    assertEq(address(underTest.COLLATERAL_TOKEN()), address(collateralToken));
    assertEq(underTest.COLLATERAL_TOKEN_DECIMALS(), 18);
    assertEq(address(underTest.DEBT_TOKEN()), address(debtToken));
    assertEq(underTest.DEBT_TOKEN_DECIMALS(), 18);
    assertEq(address(underTest.ORACLE()), mockOracle);
    assertEq(underTest.SLICE_INTERVAL(), 50e18);
  }

  function test_depositDebtTokens_whenNoBorrowers_AccountingCorrect()
    external
    prankAs(lenderA)
  {
    uint256 currentSlice = 1800e18;
    uint256 depositAmount = 100e18;

    expectTransferFrom(address(debtToken), lenderA, address(underTest), depositAmount);
    expectExactEmit();
    emit LendDebtTokens(lenderA, currentSlice, depositAmount);

    underTest.depositDebtTokens(currentSlice, depositAmount);

    assertEq(depositAmount, underTest.getUserDebtTokenDeposit(lenderA, currentSlice));
    assertEq(
      depositAmount, underTest.getUserLendingData(lenderA, currentSlice).baseAmount
    );
  }

  function test_userCanWithdrawMoreDepositAfterInterestPaid() external prankAs(lenderA) {
    uint256 currentSlice = 1800e18;
    uint256 lenderDepositAmount = 1000e18;
    uint256 collateralDepositAmount = 1e18;
    uint256 initialDebtAmount = 500e18;
    uint256 expectedwithdrawnAmount = 1025e18;

    underTest.depositDebtTokens(currentSlice, lenderDepositAmount);

    vm.startPrank(borrowerA);

    underTest.borrow(currentSlice, initialDebtAmount, collateralDepositAmount);

    skip(secondsInYear);

    underTest.repayAll(currentSlice);

    vm.startPrank(lenderA);

    expectExactEmit();
    emit WithdrawDebtTokens(lenderA, currentSlice, expectedwithdrawnAmount);

    assertEq(debtToken.balanceOf(lenderA), 999_000e18);
    underTest.withdrawDebtTokens(currentSlice, expectedwithdrawnAmount);

    assertEq(0, underTest.getUserDebtTokenDeposit(lenderA, currentSlice));
    assertEq(0, underTest.getUserLendingData(lenderA, currentSlice).baseAmount);
    assertEq(1.05e27, underTest.getSliceData(currentSlice).debtIndex);
    assertEq(debtToken.balanceOf(lenderA), 1_000_025e18);
  }

  function test_borrow_accruesInterestToDepositorOnNextDeposit()
    external
    prankAs(lenderA)
  {
    uint256 currentSlice = 1800e18;
    uint256 lenderDepositAmount = 1000e18;
    uint256 collateralDepositAmount = 1e18;
    uint256 initialDebtAmount = 500e18;

    underTest.depositDebtTokens(currentSlice, lenderDepositAmount);

    vm.startPrank(borrowerA);

    expectTransferFrom(
      address(collateralToken), borrowerA, address(underTest), collateralDepositAmount
    );
    expectTransfer(address(debtToken), borrowerA, initialDebtAmount);
    expectExactEmit();
    emit Borrow(borrowerA, currentSlice, initialDebtAmount, collateralDepositAmount);

    underTest.borrow(currentSlice, initialDebtAmount, collateralDepositAmount);

    assertEq(initialDebtAmount, underTest.getUserDebt(borrowerA, currentSlice));
    assertEq(
      collateralDepositAmount, underTest.getUserCollateral(borrowerA, currentSlice)
    );

    skip(secondsInYear);

    assertEq(525e18, underTest.getUserDebt(borrowerA, currentSlice));
    assertEq(1025e18, underTest.getUserDebtTokenDeposit(lenderA, currentSlice));
  }

  function test_repay_updatesDepositorIndex() external prankAs(lenderA) {
    uint256 currentSlice = 1800e18;
    uint256 lenderDepositAmount = 1000e18;
    uint256 collateralDepositAmount = 1e18;
    uint256 initialDebtAmount = 500e18;

    underTest.depositDebtTokens(currentSlice, lenderDepositAmount);

    vm.startPrank(borrowerA);

    underTest.borrow(currentSlice, initialDebtAmount, collateralDepositAmount);

    skip(secondsInYear);

    expectTransferFrom(
      address(debtToken), borrowerA, address(underTest), initialDebtAmount
    );
    expectExactEmit();
    emit Repay(borrowerA, currentSlice, initialDebtAmount, 0);

    underTest.repay(currentSlice, initialDebtAmount, 0);

    assertEq(25e18, underTest.getUserDebt(borrowerA, currentSlice));
    assertEq(1.025e27, underTest.getSliceData(currentSlice).depositIndex);
  }

  // function test_liquidatesUser_whenNotAllDebtTokensCleared_IndexStillUsable()
  //   external
  //   prankAs(lenderA)
  // {
  //   uint256 currentSlice = 1800e18;
  //   uint256 lenderDepositAmount = 1000e18;
  //   uint256 collateralDepositAmount = 1e18;
  //   uint256 initialDebtAmount = 999e18;

  //   underTest.depositDebtTokens(currentSlice, lenderDepositAmount);

  //   vm.startPrank(borrowerA);

  //   underTest.borrow(currentSlice, initialDebtAmount, collateralDepositAmount);

  //   expectExactEmit();
  //   emit SliceLiquidation(currentSlice);
  //   _mockOraclePrice(1600e18);
  //   underTest.liquidateSlice(currentSlice);

  //   assertEq(1e24, underTest.getSliceData(currentSlice).depositIndex);
  //   assertEq(0, underTest.getSliceData(currentSlice).totalCollateralDeposit);
  //   assertEq(0, underTest.getSliceData(currentSlice).totalBaseDebt);
  //   assertEq(1e27, underTest.getSliceData(currentSlice).debtIndex);
  //   assertEq(1, underTest.getSliceData(currentSlice).borrowingEpoch);
  //   assertEq(1e18, underTest.getUserDebtTokenDeposit(lenderA, currentSlice));

  //   vm.startPrank(lenderB);
  //   underTest.depositDebtTokens(currentSlice, lenderDepositAmount);
  //   assertEq(
  //     lenderDepositAmount, underTest.getUserDebtTokenDeposit(lenderB, currentSlice)
  //   );
  //   assertEq(1000e21, underTest.getUserLendingData(lenderB, currentSlice).baseAmount);
  // }

  // multiple slices
  // cannot deposit if slice doesn't exist
  // updates index

  //withdraw also updates interest
  //withdraw also update claimining details
  //withdraw epoch diff
  // multiple users withdraw
  // multiple slices withdraw
  // cannot withdraw if slice doesn't exist
  // cannot withdraw if insufficient liquidity

  // borrow base case
  // borrow in new epoch
  // borrow multiple slices
  // borrow multiple users

  // cannot borrow if liquidatable
  // cannot borrow if slice liquidatable

  // repay base case
  // repay new epoch doesnt work
  // multiple user and slices repay

  // liquidation slice full
  // liqudation slice not fully utilised.
  //slice not liquidatable
  // slice doesnt exist.

  //   function _expectDecreaseDebt(address module, address _user, uint256 _debt) internal {
  //     vm.expectCall(
  //       module, abi.encodeWithSelector(IInterestModule.decreaseDebt.selector, _user, _debt)
  //     );
  //   }

  function _mintInitialTokens() internal {
    debtToken.mint(lenderA, 1_000_000e18);
    debtToken.mint(lenderB, 1_000_000e18);
    debtToken.mint(borrowerA, 1_000_000e18);
    debtToken.mint(borrowerB, 1_000_000e18);
    collateralToken.mint(borrowerA, 1_000_000e18);
    collateralToken.mint(borrowerB, 1_000_000e18);

    vm.startPrank(lenderA);
    debtToken.approve(address(underTest), 1_000_000e18);
    vm.startPrank(lenderB);
    debtToken.approve(address(underTest), 1_000_000e18);
    vm.startPrank(borrowerA);
    debtToken.approve(address(underTest), 1_000_000e18);
    collateralToken.approve(address(underTest), 1_000_000e18);
    vm.startPrank(borrowerB);
    debtToken.approve(address(underTest), 1_000_000e18);
    collateralToken.approve(address(underTest), 1_000_000e18);
  }

  function _createInitialSlices() internal {
    underTest.createSlice(50e18);
    underTest.createSlice(100e18);
    underTest.createSlice(1000e18);
    underTest.createSlice(1250e18);
    underTest.createSlice(1500e18);
    underTest.createSlice(1700e18);
    underTest.createSlice(1800e18);
    underTest.createSlice(2000e18);
    underTest.createSlice(2200e18);
    assertTrue(underTest.doesSliceExists(1500e18));
  }

  function _mockOraclePrice(uint256 _price) internal {
    vm.mockCall(
      mockOracle,
      abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector),
      abi.encode(_price)
    );
  }
}
