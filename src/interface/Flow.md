Rough outline of flow for frontend. Refer to IBasicEmu.sol for function calls.

Render frontend calls

Getting slice information
-getExistingSlices() to get array of slices. Slices are integers which represent prices.
-getSliceLiquidity() to get details about the slice

For getting a user's positions in a slice
-getUserLendingData() for their lending positions
-getUserBorrowingData() for their borrowing positions // problem i see now is that we don't know which slices they have positions in. Do we need to check every slice or have some way to store it offchain?

For actions users want to take name is self explainatory
-depositDebtTokens()
-withdrawDebtTokens()
-borrow()
-repayAll()
-repay()
-claimBonusCollateral() // This is after borrowers get liquidated lenders can claim some collateral since some of their debt tokens will dissapear

Liquidations related stuff(mostly bots)
-liquidateUser() // anyone can call and get liquidation bonus fee. mostly bots calling this
-isUserLiquidateable
