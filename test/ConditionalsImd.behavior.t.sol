// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsImd} from "src/ConditionalsImd.sol";

/// @dev A real contract caller, so the constructor must distinguish msg.sender from tx.origin.
contract ConditionalsImdDeploymentProbe {
    function deploy() external returns (ConditionalsImd) {
        return new ConditionalsImd();
    }
}

/// @notice Complements the original suite with rollback, authorization lifecycle and boundary cases.
/// forge-config: default.fuzz.runs = 1000
contract ConditionalsImdBehaviorTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    ConditionalsImd private token;
    address private holder;
    address private spender;
    address private recipient;
    address private outsider;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        holder = makeAddr("COND holder");
        spender = makeAddr("COND spender");
        recipient = makeAddr("COND recipient");
        outsider = makeAddr("COND outsider");
        token = new ConditionalsImd();
    }

    function test_constructorMintsOnceToContractCallerInsteadOfOrigin() public {
        ConditionalsImdDeploymentProbe probe = new ConditionalsImdDeploymentProbe();
        vm.recordLogs();
        vm.prank(holder, outsider);
        ConditionalsImd fresh = probe.deploy();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "constructor must emit exactly one mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(probe)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(address(probe)), SUPPLY);
        assertEq(fresh.balanceOf(holder), 0);
        assertEq(fresh.balanceOf(outsider), 0);
        assertEq(fresh.balanceOf(address(fresh)), 0);
        assertEq(fresh.balanceOf(address(0)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersEmitAndLeaveBalancesAndApprovalUnchanged() public {
        assertTrue(token.approve(spender, 17));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), recipient, 0);
        assertTrue(token.transfer(recipient, 0));

        // Even an empty holder and an unapproved caller may transfer zero to a valid receiver.
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(outsider);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(this), spender), 17);
        assertEq(token.allowance(holder, outsider), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_oneBaseUnitCanBeTransferredAndReturned() public {
        assertTrue(token.transfer(holder, 1));
        assertEq(token.balanceOf(holder), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(holder);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_wholeSupplyCanBePulledOnlyOnceWithExactApproval() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(address(this), spender), 0);

        // Replenish the original owner: the second pull must fail because authorization ran out.
        vm.prank(holder);
        assertTrue(token.transfer(address(this), SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSelfTransferConsumesAllowanceWithoutMovingBalance() public {
        assertTrue(token.approve(spender, 11));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), 7);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 7));
        assertEq(token.allowance(address(this), spender), 4);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ownerAlsoNeedsApprovalToUseTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), recipient, 1);
        assertTrue(token.approve(address(this), 1));
        assertTrue(token.transferFrom(address(this), recipient, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.balanceOf(recipient), 1);
    }

    function test_nearMaximumAllowanceIsFinite() public {
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_infiniteAllowanceCanBeReplacedAndRevoked() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), holder, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max);

        assertTrue(token.approve(spender, 3));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), holder, 2));
        assertEq(token.allowance(address(this), spender), 1);

        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), holder, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(holder), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
    }

    function test_approvalsAreIsolatedByBothOwnerAndSpender() public {
        assertTrue(token.transfer(holder, 10));
        assertTrue(token.approve(spender, 7));
        assertTrue(token.approve(outsider, 9));
        vm.prank(holder);
        assertTrue(token.approve(spender, 3));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, 1));
        vm.prank(outsider);
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 2));

        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.allowance(holder, outsider), 0);
        assertEq(token.allowance(address(this), spender), 7);
        assertEq(token.allowance(address(this), outsider), 9);
        assertEq(token.balanceOf(holder), 8);
        assertEq(token.balanceOf(recipient), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
    }

    function test_failedTransferFromToZeroRestoresFiniteApproval() public {
        assertTrue(token.approve(spender, 7));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 5);
        assertEq(token.allowance(address(this), spender), 7);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);

        // The reverted call must not prevent a later authorized spend of the entire allowance.
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 7));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(recipient), 7);
    }

    function test_failedTransferFromAboveBalanceRestoresFiniteApproval() public {
        assertTrue(token.transfer(holder, 3));
        vm.prank(holder);
        assertTrue(token.approve(spender, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 3, 4));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 4);
        assertEq(token.allowance(holder, spender), 10);
        assertEq(token.balanceOf(holder), 3);
        assertEq(token.balanceOf(recipient), 0);

        assertTrue(token.transfer(holder, 7));
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 10));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 10);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumAmountCannotBypassBalanceChecksEvenWithInfiniteApproval() public {
        assertTrue(token.approve(spender, type(uint256).max));
        bytes memory expected = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
        );
        vm.expectRevert(expected);
        token.transfer(recipient, type(uint256).max);
        vm.expectRevert(expected);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransfersStillRequireSufficientBalance() public {
        assertTrue(token.transfer(holder, 1));
        vm.prank(holder);
        assertTrue(token.approve(spender, 2));
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 1, 2);
        vm.expectRevert(expected);
        vm.prank(holder);
        token.transfer(holder, 2);
        vm.expectRevert(expected);
        vm.prank(spender);
        token.transferFrom(holder, holder, 2);
        assertEq(token.balanceOf(holder), 1);
        assertEq(token.allowance(holder, spender), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAddressesRemainInvalidForZeroValueOperations() public {
        bytes memory invalidReceiver = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        vm.expectRevert(invalidReceiver);
        token.transfer(address(0), 0);
        vm.expectRevert(invalidReceiver);
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);

        // A zero source must fail too; do not depend on which validation rejects it first.
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (address(0), recipient, 0)));
        assertFalse(ok, "zero source accepted");
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_sendingTokensToTokenContractDoesNotBurnThem() public {
        assertTrue(token.transfer(address(token), 1));
        assertTrue(token.approve(spender, SUPPLY - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(token), SUPPLY - 1));
        assertEq(token.balanceOf(address(token)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approveReplacesRatherThanAddsAndIsIdempotent(uint256 first, uint256 replacement) public {
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(outsider, 11));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, replacement);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.allowance(address(this), outsider), 11);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_emptyAccountCanApproveWithoutMintingOrReservingTokens(uint256 allowance) public {
        vm.prank(holder);
        assertTrue(token.approve(spender, allowance));
        assertEq(token.allowance(holder, spender), allowance);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_roundTripRestoresBothFundedAccounts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        assertTrue(token.transfer(holder, held));
        assertTrue(token.transfer(recipient, SUPPLY - held));
        vm.prank(holder);
        assertTrue(token.approve(spender, 13));

        vm.prank(holder);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(holder), held - amount);
        assertEq(token.balanceOf(recipient), SUPPLY - held + amount);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, amount));
        assertEq(token.balanceOf(holder), held);
        assertEq(token.balanceOf(recipient), SUPPLY - held);
        assertEq(token.allowance(holder, spender), 13);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitSpendsCannotExceedCumulativeApproval(uint256 allowance, uint256 first) public {
        allowance = bound(allowance, 1, SUPPLY - 1);
        first = bound(first, 0, allowance);
        assertTrue(token.approve(spender, allowance));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), holder, first));
        assertEq(token.allowance(address(this), spender), allowance - first);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, allowance - first));
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - allowance);
        assertEq(token.balanceOf(holder), first);
        assertEq(token.balanceOf(recipient), allowance - first);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_balanceFailurePreservesEveryApprovedUnit(
        uint256 held,
        uint256 amount,
        uint256 allowance,
        bool infinite
    ) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max - 1);
        allowance = infinite ? type(uint256).max : bound(allowance, amount, type(uint256).max - 1);
        assertTrue(token.transfer(holder, held));
        vm.prank(holder);
        assertTrue(token.approve(spender, allowance));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, held, amount));
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.allowance(holder, spender), allowance);
        assertEq(token.balanceOf(holder), held);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_zeroDestinationFailurePreservesApproval(uint256 allowance, uint256 amount) public {
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        assertTrue(token.approve(spender, allowance));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), allowance);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
