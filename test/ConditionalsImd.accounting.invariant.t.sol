// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConditionalsImd} from "src/ConditionalsImd.sol";
import {ConditionalsImdAccountingHandler} from "./helpers/ConditionalsImdAccountingHandler.sol";

/// @notice Independent balance and authorization accounting after random successful and rejected calls.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ConditionalsImdAccountingInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    ConditionalsImd private token;
    ConditionalsImdAccountingHandler private handler;
    address[4] private actors;

    function setUp() public {
        actors[0] = makeAddr("COND invariant deployer");
        actors[1] = makeAddr("COND invariant holder one");
        actors[2] = makeAddr("COND invariant holder two");
        actors[3] = makeAddr("COND invariant holder three");
        vm.prank(actors[0]);
        token = new ConditionalsImd();

        // Fund everyone using actual transfers; never use storage writes or token balance cheats.
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(actors[0]);
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        handler = new ConditionalsImdAccountingHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.selfTransfer.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.revoke.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.roundTrip.selector;
        selectors[6] = handler.transferAboveBalance.selector;
        selectors[7] = handler.transferAboveAllowance.selector;
        selectors[8] = handler.approvedTransferAboveBalance.selector;
        selectors[9] = handler.transferToZero.selector;
        selectors[10] = handler.transferFromToZero.selector;
        selectors[11] = handler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyAndEveryBalanceMatchRequestedMovements() public view {
        uint256 total = token.balanceOf(address(token));
        assertEq(total, handler.expectedBalance(address(token)), "tokens held by the token were lost");
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]), "actor balance diverged from requests");
            total += balance;
        }
        assertEq(total, SUPPLY, "tracked balances do not conserve the original mint");
        assertEq(token.totalSupply(), SUPPLY, "supply changed after construction");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
    }

    function invariant_allowancesMatchOnlyApprovalsAndSuccessfulSpends() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "authorization changed outside its owner's approval or successful spend"
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0, "invalid spender acquired authorization");
            assertEq(token.allowance(address(token), actors[i]), 0, "token contract granted authorization");
        }
    }

    function invariant_metadataDoesNotChange() public view {
        assertEq(token.name(), "ConditionalsImd");
        assertEq(token.symbol(), "COND");
        assertEq(token.decimals(), 18);
    }

    /// @dev Pin a mixed sequence as a harness check: every selector runs, with nonzero direct and
    /// delegated transfers, a passive contract recipient, a full-balance move, and expected failures.
    function test_handlerExercisesMixedSequenceAndAllInvariants() public {
        handler.transfer(0, 1, 1);
        handler.selfTransfer(1, 2);
        handler.approve(1, 2, 13);
        handler.transferFrom(1, 2, 3, 4);
        assertEq(token.allowance(actors[1], actors[2]), 9);
        _checkInvariants();

        handler.approve(1, 2, 1); // infinite
        handler.transferFrom(1, 2, 4, 1); // one base unit to the token itself
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max);
        assertEq(token.balanceOf(address(token)), 1);
        handler.revoke(1, 2);
        handler.transferAboveAllowance(1, 2, 1);
        _checkInvariants();

        handler.roundTrip(3, 1, 2);
        handler.transferAboveBalance(0, 3, type(uint256).max);
        handler.approvedTransferAboveBalance(2, 3, type(uint256).max);
        handler.transferToZero(0, 0);
        handler.transferFromToZero(0, 1, 2, false);
        handler.transferFromToZero(0, 1, 1, true);
        handler.approveZeroSpender(3, type(uint256).max);
        _checkInvariants();

        handler.transfer(0, 1, 2); // full balance, followed by an attempt from the empty owner
        assertEq(token.balanceOf(actors[0]), 0);
        handler.transferAboveBalance(0, 1, 1);
        assertGt(handler.nonzeroTransfers(), 0);
        assertGt(handler.nonzeroDelegatedTransfers(), 0);
        assertEq(handler.rejectedCalls(), 8);
        _checkInvariants();
    }

    function _checkInvariants() private view {
        invariant_supplyAndEveryBalanceMatchRequestedMovements();
        invariant_allowancesMatchOnlyApprovalsAndSuccessfulSpends();
        invariant_metadataDoesNotChange();
    }
}
