pragma solidity 0.6.7;

abstract contract UniswapV2Router02Like {
    function getAmountsIn(uint amountOut, address[] memory path) public view virtual returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external virtual returns (uint[] memory amounts);
}