pragma solidity ^0.8.17;

import "test/base/BaseTest.t.sol";
import { Emu } from "src/Emu.sol";
import { EEmu } from "src/interface/EEmu.sol";
import { AggregatorV2V3Interface } from "src/interface/AggregatorV2V3Interface.sol";
import { MockERC20 } from "test/mock/contract/MockERC20.sol";

contract EmuTest is BaseTest, EEmu {
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

    debtToken.mint(lenderA, 1_000_000e18);
    debtToken.mint(lenderB, 1_000_000e18);
    collateralToken.mint(borrowerA, 1_000_000e18);
    collateralToken.mint(borrowerB, 1_000_000e18);

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

  //   function _expectDecreaseDebt(address module, address _user, uint256 _debt) internal {
  //     vm.expectCall(
  //       module, abi.encodeWithSelector(IInterestModule.decreaseDebt.selector, _user, _debt)
  //     );
  //   }

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
      abi.encodeWithSelector(AggregatorV2V3Interface.getAnswer.selector),
      abi.encode(_price)
    );
  }
}
