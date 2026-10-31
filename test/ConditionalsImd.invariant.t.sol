// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConditionalsImd} from "../src/ConditionalsImd.sol";

/// @notice Drives random transfers, approvals and allowance spends among a fixed set of holders.
contract ConditionalsImdHandler is Test {
    ConditionalsImd public immutable token;
    address[] public actors;

    constructor(ConditionalsImd token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract ConditionalsImdInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant FACTORY = address(0xFAC7);

    ConditionalsImd internal token;
    ConditionalsImdHandler internal handler;

    function setUp() public {
        vm.prank(FACTORY);
        token = new ConditionalsImd();

        address[] memory actors = new address[](5);
        actors[0] = FACTORY;
        actors[1] = address(0xA11CE);
        actors[2] = address(0xB0B);
        actors[3] = address(0xCA201);
        actors[4] = address(0xD157);
        handler = new ConditionalsImdHandler(token, actors);

        targetContract(address(handler));
    }

    /// @dev The supply never changes: nothing mints and nothing burns.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Tokens only move between holders; the holders together always own the whole supply.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }
}
