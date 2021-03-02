pragma solidity 0.6.7;

import "./ERC20Like.sol";

abstract contract OpynV2WhitelistLike {
    function isWhitelistedOtoken(address _otoken) external virtual view returns (bool);
}
