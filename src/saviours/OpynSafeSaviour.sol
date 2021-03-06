// Copyright (C) 2020 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

pragma experimental ABIEncoderV2;

import "../interfaces/SafeSaviourLike.sol";
import "../interfaces/OpynV2OTokenLike.sol";
import "../interfaces/OpynV2ControllerLike.sol";
import "../interfaces/OpynV2WhitelistLike.sol";
import "../interfaces/UniswapV2Router02Like.sol";
import "../math/SafeMath.sol";

contract OpynSafeSaviour is SafeMath, SafeSaviourLike {
    // --- Variables ---
    // Amount of collateral deposited to cover each SAFE
    mapping(address => uint256) public oTokenCover;
    // oToken type selected by each SAFE
    mapping(address => address) public oTokenSelection;
    // allowed oToken contracts
    mapping(address => uint256) public oTokenWhitelist;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike          public collateralJoin;
    // The collateral token
    ERC20Like                   public collateralToken;
    // The Opyn v2 Controller to interact with oTokens
    OpynV2ControllerLike        public opynV2Controller;
    // The Opyn v2 Whitelist to check oTokens' validity
    OpynV2WhitelistLike         public opynV2Whitelist;
    // The Uniswap v2 router 02 to swap collaterals
    UniswapV2Router02Like       public uniswapV2Router02;

    // --- Events ---
    event Deposit(address indexed caller, address indexed safeHandler, uint256 amount);
    event Withdraw(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 amount);

    event ToggleOToken(address oToken, uint256 whitelistState);

    constructor(
      address collateralJoin_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      address[3] memory opynSaviourDependencies_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_,
      uint256 payoutToSAFESize_,
      uint256 defaultDesiredCollateralizationRatio_
    ) public {
        require(collateralJoin_ != address(0), "OpynSafeSaviour/null-collateral-join");
        require(liquidationEngine_ != address(0), "OpynSafeSaviour/null-liquidation-engine");
        require(oracleRelayer_ != address(0), "OpynSafeSaviour/null-oracle-relayer");
        require(safeManager_ != address(0), "OpynSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "OpynSafeSaviour/null-saviour-registry");
        require(opynSaviourDependencies_[0] != address(0), "OpynSafeSaviour/null-opyn-v2-controller");
        require(opynSaviourDependencies_[1] != address(0), "OpynSafeSaviour/null-opyn-v2-whitelist");
        require(opynSaviourDependencies_[2] != address(0), "OpynSafeSaviour/null-uniswap-v2-router02");
        require(keeperPayout_ > 0, "OpynSafeSaviour/invalid-keeper-payout");
        require(defaultDesiredCollateralizationRatio_ > 0, "OpynSafeSaviour/null-default-cratio");
        require(payoutToSAFESize_ > 1, "OpynSafeSaviour/invalid-payout-to-safe-size");
        require(minKeeperPayoutValue_ > 0, "OpynSafeSaviour/invalid-min-payout-value");

        keeperPayout         = keeperPayout_;
        payoutToSAFESize     = payoutToSAFESize_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        safeEngine           = SAFEEngineLike(collateralJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        collateralToken      = ERC20Like(collateralJoin.collateral());
        opynV2Controller     = OpynV2ControllerLike(opynSaviourDependencies_[0]);
        opynV2Whitelist      = OpynV2WhitelistLike(opynSaviourDependencies_[1]);
        uniswapV2Router02    = UniswapV2Router02Like(opynSaviourDependencies_[2]);

        require(address(safeEngine) != address(0), "OpynSafeSaviour/null-safe-engine");

{
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;
        require(scaledLiquidationRatio > 0, "OpynSafeSaviour/invalid-scaled-liq-ratio");
        require(both(defaultDesiredCollateralizationRatio_ > scaledLiquidationRatio, defaultDesiredCollateralizationRatio_ <= MAX_CRATIO), "OpynSafeSaviour/invalid-default-desired-cratio");
}

        require(collateralJoin.decimals() == 18, "OpynSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "OpynSafeSaviour/join-disabled");

        defaultDesiredCollateralizationRatio = defaultDesiredCollateralizationRatio_;
    }

    // --- Authorization ---
    modifier isSaviourRegistryAuthorized() {
      require(saviourRegistry.authorizedAccounts(msg.sender) == 1, "OpynSafeSaviour/account-not-authorized");
      _;
    }

    /*
    * @notice Whitelist/blacklist an oToken contract
    * @param oToken The oToken contract to whitelist/blacklist
    */
  function toggleOToken(address oToken) external isSaviourRegistryAuthorized() {
    // Check if oToken address is whitelisted Opyn V2
    require(opynV2Whitelist.isWhitelistedOtoken(oToken) == true, "OpynSafeSaviour/otoken-not-whitelisted");

    // Check if oToken collateral asset is WETH and is put option
    ( , , , , , bool isPut) = OpynV2OTokenLike(oToken).getOtokenDetails();

    require(isPut == true, "OpynSafeSaviour/option-not-put");

    if (oTokenWhitelist[oToken] == 0) {
      oTokenWhitelist[oToken] = 1;
    } else {
      oTokenWhitelist[oToken] = 0;
    }
    emit ToggleOToken(oToken, oTokenWhitelist[oToken]);
  }

    // Amount 
    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit oToken in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param oTokenAmount The amount of oToken to deposit
    * @param oTokenType the address of the erc20 contract controlling the oTokens
    */
    function deposit(uint256 safeID, uint256 oTokenAmount, address oTokenType) external liquidationEngineApproved(address(this)) nonReentrant {
        require(oTokenAmount > 0, "OpynSafeSaviour/null-oToken-amount");
        // Check that oToken has been whitelisted by a SaviourRegistry authorized account
        require(oTokenWhitelist[oTokenType] == 1, "OpynSafeSaviour/forbidden-otoken");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "OpynSafeSaviour/null-handler");

        // Check that safe is either protected by provided oToken type or no type at all
        require(either(oTokenSelection[safeHandler] == oTokenType, oTokenSelection[safeHandler] == address(0)), "OpynSafeSaviour/safe-otoken-incompatibility");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "OpynSafeSaviour/safe-does-not-have-debt");

        // Trigger transfer from oToken contract
        require(ERC20Like(oTokenType).transferFrom(msg.sender, address(this), oTokenAmount), "GeneralTokenReserveSafeSaviour/could-not-transfer-collateralToken");
        // Update the collateralToken balance used to cover the SAFE and transfer collateralToken to this contract
        oTokenCover[safeHandler] = add(oTokenCover[safeHandler], oTokenAmount);

        // Check if SAFE oToken selection should be changed
        if (oTokenSelection[safeHandler] == address(0)) {
          oTokenSelection[safeHandler] = oTokenType;
        }

        emit Deposit(msg.sender, safeHandler, oTokenAmount);
    }
    // and if safe has a selected token ofc
    /*
    * @notice Withdraw oToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param oTokenAmount The amount of oToken to withdraw
    */
    function withdraw(uint256 safeID, uint256 oTokenAmount) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(oTokenAmount > 0, "OpynSafeSaviour/null-collateralToken-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(oTokenCover[safeHandler] >= oTokenAmount, "OpynSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        oTokenCover[safeHandler] = sub(oTokenCover[safeHandler], oTokenAmount);
        ERC20Like(oTokenSelection[safeHandler]).transfer(msg.sender, oTokenAmount);

        // Check if balance of selected token 
        if (oTokenCover[safeHandler] == 0) {
          oTokenSelection[safeHandler] = address(0);
        }

        emit Withdraw(msg.sender, safeID, safeHandler, oTokenAmount);
    }

    // --- Adjust Cover Preferences ---
    /*
    * @notice Sets the collateralization ratio that a SAFE should have after it's saved
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to set the desired CRatio for. This ID should be registered inside GebSafeManager
    * @param cRatio The collateralization ratio to set
    */
    function setDesiredCollateralizationRatio(uint256 safeID, uint256 cRatio) external controlsSAFE(msg.sender, safeID) {
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;
        address safeHandler = safeManager.safes(safeID);

        require(scaledLiquidationRatio > 0, "OpynSafeSaviour/invalid-scaled-liq-ratio");
        require(scaledLiquidationRatio < cRatio, "OpynSafeSaviour/invalid-desired-cratio");
        require(cRatio <= MAX_CRATIO, "OpynSafeSaviour/exceeds-max-cratio");

        desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] = cRatio;

        emit SetDesiredCollateralizationRatio(msg.sender, safeID, safeHandler, cRatio);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by adding more collateralToken into it
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being saved
    * @return Whether the SAFE has been saved, the amount of collateralToken added in the SAFE as well as the amount of
    *         collateralToken sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "OpynSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "OpynSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        require(collateralType == collateralJoin.collateralType(), "OpynSafeSaviour/invalid-collateral-type");
        require(oTokenSelection[safeHandler] != address(0), "OpynSafeSaviour/no-selected-otoken");

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "OpynSafeSaviour/small-keeper-payout-value");

        // Compute the amount of collateral that should be added to bring the safe to desired collateral ratio
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);

        // Retrieve the oTokenCollateral address
        (address oTokenCollateralAddress, , , , , ) = OpynV2OTokenLike(oTokenSelection[safeHandler]).getOtokenDetails();

        { // Stack too deep guard #1

          // Check that the amount of collateral locked in the safe is bigger than the keeper's payout
          (uint256 safeLockedCollateral,) =
            SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
          require(safeLockedCollateral >= mul(keeperPayout, payoutToSAFESize), "OpynSafeSaviour/tiny-safe");

        }

          // Compute and check the validity of the amount of collateralToken used to save the SAFE
          require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "OpynSafeSaviour/invalid-tokens-used-to-save");

          // Check if oToken balance is not empty
          require(oTokenCover[safeHandler] > 0, "OpynSafeSaviour/empty-otoken-balance");

          // The actual required collateral to provide is the sum of what is needed to bring the safe to its desired collateral ratio + the keeper reward
          uint256 requiredTokenAmount = add(keeperPayout, tokenAmountUsed);

          // Track balance through redeem / swaps.
          uint256 track;

        { // Stack too deep guard #2

          // This call reverts if not expired. Retrieves the amount of option collateral retrievable
          uint256 oTokenPayout = opynV2Controller.getPayout(oTokenSelection[safeHandler], oTokenCover[safeHandler]);

          // Amount of oToken collateral needed as input for the uniswap call in order to end up
          // with requiredTokenAmount as result
          uint256 amount;

        { // Stack too deep guard #2.1

          // Path argument for the uniswap router
          address[] memory path = new address[](2);
          path[0] = oTokenCollateralAddress;
          path[1] = collateralJoin.collateral();

          uint256[] memory amounts = uniswapV2Router02.getAmountsIn(requiredTokenAmount, path);

          amount = amounts[0];

        }

          // Check that the amount of collateral to swap is retrievable
          require(amount <= oTokenPayout, "OpynSafeSaviour/insufficient-opyn-payout");

          track = div(mul(oTokenCover[safeHandler], amount), oTokenPayout);

          // In the case where 1 oToken would retrieve more than 1 collateral and because integer division would round towards 0
          // ex: 1 oToken retrieves 3 collateral, 5 collateral required, and user owns 2 oToken => (2 * 5) / (2 * 3) => 1.666667 gets rounded to 1, but 2 is required to save
          // To tackle this, if we have a division remainder and spare oTokens, we increase the used oToken balance by 1
          if (mod(mul(oTokenCover[safeHandler], amount), oTokenPayout) != 0) {
            track += 1;
          }

          // Check that there are enough oTokens after rounding fix
          require(track < oTokenCover[safeHandler], "OpynSafeSaviour/insufficient-otokens");

        }


        { // Stack too deep guard #3

            // Build Opyn Action
            ActionArgsLike[] memory redeemAction = new ActionArgsLike[](1);
            redeemAction[0].actionType = ActionTypeLike.Redeem;
            redeemAction[0].owner = address(0);
            redeemAction[0].secondAddress = address(this);
            redeemAction[0].asset = oTokenSelection[safeHandler];
            redeemAction[0].vaultId = 0;
            redeemAction[0].amount = track;

            // Retrieve pre-redeem collateral balance
            uint256 oTokenCollateralBalance = ERC20Like(oTokenCollateralAddress).balanceOf(address(this));

            // Trigger oToken collateral redeem
            opynV2Controller.operate(redeemAction);

            // Update the remaining cover
            oTokenCover[safeHandler] = sub(oTokenCover[safeHandler], track);

            // Update the tracked balance to the amount retrieved. Would overflow and throw if balance decreased
            track = sub(ERC20Like(oTokenCollateralAddress).balanceOf(address(this)), oTokenCollateralBalance);
        }

        { // Stack too deep guard #4

            // Retrieve pre-swap WETH balance
            uint256 wethBalance = ERC20Like(collateralJoin.collateral()).balanceOf(address(this));

            { // Stack too deep guard #4.1

              // Path argument for the uniswap router
              address[] memory path = new address[](2);
              path[0] = oTokenCollateralAddress;
              path[1] = collateralJoin.collateral();

              ERC20Like(oTokenCollateralAddress).approve(address(uniswapV2Router02), track);

              uniswapV2Router02.swapExactTokensForTokens(track, requiredTokenAmount, path, address(this), block.timestamp);
            }

            // Retrieve post-swap WETH balance. Would overflow and throw if balance decreased
            track = sub(ERC20Like(collateralJoin.collateral()).balanceOf(address(this)), wethBalance);

            // Check that balance has increased of at least required amount
            require(track >= requiredTokenAmount, "OpynSafeSaviour/not-enough-otoken-collateral-swapped");

            // Update balance in case of excess
            if (track > requiredTokenAmount) {
              requiredTokenAmount = track;
            }

        }

        // Mark the SAFE in the registry as just being saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Approve collateralToken to the collateral join contract
        collateralToken.approve(address(collateralJoin), 0);
        collateralToken.approve(address(collateralJoin), tokenAmountUsed);

        // Join collateralToken in the system and add it in the saved SAFE
        collateralJoin.join(address(this), tokenAmountUsed);
        safeEngine.modifySAFECollateralization(
          collateralJoin.collateralType(),
          safeHandler,
          address(this),
          address(0),
          int256(tokenAmountUsed),
          int256(0)
        );

        // Send the fee to the keeper, the prize is recomputed to prevent dust
        collateralToken.transfer(keeper, sub(requiredTokenAmount, tokenAmountUsed));

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, tokenAmountUsed);

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    /*
    * @notice Compute whether the value of keeperPayout collateralToken is higher than or equal to minKeeperPayoutValue
    * @dev Used to determine whether it's worth it for the keeper to save the SAFE in exchange for keeperPayout collateralToken
    * @return A bool representing whether the value of keeperPayout collateralToken is >= minKeeperPayoutValue
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(PriceFeedLike(ethFSM).priceSource()).getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return false;
        }

        return (minKeeperPayoutValue <= mul(keeperPayout, priceFeedValue) / WAD);
    }
    /*
    * @notice Return the current value of the keeper payout
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(PriceFeedLike(ethFSM).priceSource()).getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return 0;
        }

        return mul(keeperPayout, priceFeedValue) / WAD;
    }
    /*
    * @notice Determine whether a SAFE can be saved with the current amount of collateralToken deposited as cover for it
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);

        if (tokenAmountUsed == MAX_UINT) {
            return false;
        }

        // Check if oToken balance is not empty
        if (oTokenCover[safeHandler] == 0) {
          return false;
        }

        uint256 payout = opynV2Controller.getPayout(oTokenSelection[safeHandler], oTokenCover[safeHandler]);

        // Check that owned oTokens are able to redeem enough collateral to save SAFE
        return(payout >= add(tokenAmountUsed, keeperPayout));
    }
    /*
    * @notice Calculate the amount of collateralToken used to save a SAFE and bring its CRatio to the desired level
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of collateralToken used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedcollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        // If the SAFE doesn't have debt or if the price feed is faulty, abort
        if (either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue))) {
            tokenAmountUsed = MAX_UINT;
            return tokenAmountUsed;
        }

        // Calculate the value of the debt equivalent to the value of the collateralToken that would need to be in the SAFE after it's saved
        uint256 targetCRatio = (desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] == 0) ?
          defaultDesiredCollateralizationRatio : desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler];
        uint256 scaledDownDebtValue = mul(add(mul(oracleRelayer.redemptionPrice(), safeDebt) / RAY, ONE), targetCRatio) / HUNDRED;

        // Compute the amount of collateralToken the SAFE needs to get to the desired CRatio
        uint256 collateralTokenAmountNeeded = mul(scaledDownDebtValue, WAD) / priceFeedValue;

        // If the amount of collateralToken needed is lower than the amount that's currently in the SAFE, return 0
        if (collateralTokenAmountNeeded <= depositedcollateralToken) {
          return 0;
        } else {
          // Otherwise return the delta
          return sub(collateralTokenAmountNeeded, depositedcollateralToken);
        }
    }
}
