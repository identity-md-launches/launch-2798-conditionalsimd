// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ConditionalsImd (COND)
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 COND (18 decimals) is minted once,
/// in the constructor, to the deployer (`msg.sender`), which on launch is the IMD ProjectFactory.
/// @dev Deliberately minimal: no owner, no admin, no mint after construction, no pause, no blacklist,
/// no fee or burn on transfer. Every transfer moves exactly the amount it names, so the factory's
/// distributor transfer, the pool seed and swaps through the Uniswap v4 PoolManager arrive whole.
contract ConditionalsImd is ERC20 {
    /// @notice Name returned by `name()`.
    string public constant TOKEN_NAME = "ConditionalsImd";
    /// @notice Symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "COND";
    /// @notice The fixed total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
