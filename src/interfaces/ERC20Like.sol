pragma solidity 0.6.7;

abstract contract ERC20Like {
    function balanceOf(address guy) virtual public returns (uint256);
    function approve(address guy, uint wad) virtual public returns (bool);
    function transfer(address dst, uint wad) virtual public returns (bool);
    function transferFrom(address src, address dst, uint wad)
        virtual
        public
        returns (bool);
}
