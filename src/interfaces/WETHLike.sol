pragma solidity 0.6.7;

import "./ERC20Like.sol";

abstract contract WETHLike is ERC20Like {
    function deposit() public virtual payable;
    function withdraw(uint wad) public virtual;
}