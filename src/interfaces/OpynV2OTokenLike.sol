pragma solidity 0.6.7;

import "./ERC20Like.sol";

abstract contract OpynV2OTokenLike is ERC20Like {
    function getOtokenDetails() virtual external view returns (address, address, address, uint256, uint256, bool);
}
