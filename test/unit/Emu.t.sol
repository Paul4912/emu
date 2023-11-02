pragma solidity ^0.8.17;

import "test/base/BaseTest.t.sol";
import "forge-std/console.sol";
import { Emu } from "src/Emu.sol";
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

  Emu private underTest;

  function setUp() external prankAs(owner) {
    debtToken = new MockERC20("debtToken", "USDC", 18);
    collateralToken = new MockERC20("collateralToken", "ETH", 18);
    underTest =
    new Emu(address(collateralToken), address(debtToken), address(mockOracle), owner, 50e18, 0);

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
    assertEq(address(underTest.feeReciever()), owner);
    assertEq(underTest.SLICE_INTERVAL(), 50e18);
    assertEq(underTest.feeBPS(), 0);
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

    underTest.repayAll(currentSlice, collateralDepositAmount);

    vm.startPrank(lenderA);

    expectExactEmit();
    emit WithdrawDebtTokens(lenderA, currentSlice, expectedwithdrawnAmount);

    assertEq(debtToken.balanceOf(lenderA), 999_000e18);
    underTest.withdrawDebtTokens(currentSlice, expectedwithdrawnAmount);

    assertEq(0, underTest.getUserDebtTokenDeposit(lenderA, currentSlice));
    assertEq(0, underTest.getUserLendingData(lenderA, currentSlice).baseAmount);
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

  //depost also update claimining details
  //epoch diff
  // multiple users deposits
  // multiple slices
  // cannot deposit if slice doesn't exist

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
