pragma solidity 0.6.7;

pragma experimental ABIEncoderV2;

enum ActionTypeLike {
    OpenVault,
    MintShortOption,
    BurnShortOption,
    DepositLongOption,
    WithdrawLongOption,
    DepositCollateral,
    WithdrawCollateral,
    SettleVault,
    Redeem,
    Call
}

struct ActionArgsLike {
    ActionTypeLike actionType;
    address owner;
    address secondAddress;
    address asset;
    uint256 vaultId;
    uint256 amount;
    uint256 index;
    bytes data;
}

abstract contract OpynV2ControllerLike {
    function operate(ActionArgsLike[] calldata _actions) virtual external;
    function getPayout(address _otoken, uint256 _amount) virtual public view returns (uint256);
}