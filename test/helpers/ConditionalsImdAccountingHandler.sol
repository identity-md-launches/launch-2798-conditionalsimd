// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsImd} from "src/ConditionalsImd.sol";

/// @notice Drives valid and rejected operations with an independent ledger of requested movements.
/// @dev All four actors start with SUPPLY / 4. The token itself is a fifth, passive recipient:
/// the handler never impersonates it to recover tokens. Bounds use the model, not token balances,
/// so an incorrect implementation cannot silently reduce the amounts the harness attempts.
contract ConditionalsImdAccountingHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    uint256 public constant ACTOR_COUNT = 4;

    ConditionalsImd public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    // Used by the deterministic handler smoke test to prove that it exercises real value movement.
    uint256 public nonzeroTransfers;
    uint256 public nonzeroDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor(ConditionalsImd token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            expectedBalance[actors_[i]] = SUPPLY / ACTOR_COUNT;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _recipient(toSeed), _amount(amountSeed, expectedBalance[from]));
    }

    function selfTransfer(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        _transfer(actor, actor, _amount(amountSeed, expectedBalance[actor]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 mode = amountSeed % 5;
        uint256 amount = amountSeed;
        if (mode == 0) amount = 0;
        else if (mode == 1) amount = type(uint256).max;
        else if (mode == 2) amount = type(uint256).max - 1;
        else if (mode == 3) amount = bound(amountSeed, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _recipient(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 held = expectedBalance[owner];
        uint256 amount = _amount(amountSeed, allowance < held ? allowance : held);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "authorized pull returned false");
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _recordMovement(owner, to, amount);
        assertEq(token.allowance(owner, spender), expectedAllowance[owner][spender], "incorrect allowance spend");
        if (amount > 0 && owner != to) ++nonzeroDelegatedTransfers;
    }

    function roundTrip(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 fromIndex = fromSeed % ACTOR_COUNT;
        address from = actors[fromIndex];
        address to = actors[(fromIndex + 1 + toSeed % (ACTOR_COUNT - 1)) % ACTOR_COUNT];
        uint256 beforeFrom = expectedBalance[from];
        uint256 beforeTo = expectedBalance[to];
        uint256 amount = _amount(amountSeed, beforeFrom);
        _transfer(from, to, amount);
        _transfer(to, from, amount);
        assertEq(token.balanceOf(from), beforeFrom, "round trip changed sender balance");
        assertEq(token.balanceOf(to), beforeTo, "round trip changed receiver balance");
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        _expectFailure(
            from,
            abi.encodeCall(token.transfer, (_recipient(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
        );
    }

    function transferAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        // Infinite approvals have no "one more" value; replace them with a finite approval first.
        if (allowance == type(uint256).max) {
            allowance = SUPPLY;
            _approve(owner, spender, allowance);
        }
        uint256 amount = bound(amountSeed, allowance + 1, type(uint256).max);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
    }

    function approvedTransferAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        _approve(owner, spender, amount);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
        );
        assertEq(token.allowance(owner, spender), amount, "failed pull consumed authorization");
    }

    function transferToZero(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _expectFailure(
            owner,
            abi.encodeCall(token.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        uint256 allowance = infinite ? type(uint256).max : amount + 1;
        _approve(owner, spender, allowance);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        assertEq(token.allowance(owner, spender), allowance, "invalid destination consumed authorization");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        _expectFailure(
            _actor(ownerSeed),
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        _recordMovement(from, to, amount);
        if (amount > 0 && from != to) ++nonzeroTransfers;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval returned false");
        expectedAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount, "approval was not replaced exactly");
    }

    function _recordMovement(address from, address to, uint256 amount) private {
        // Sequential debit/credit also models self-transfers without double-counting their balance.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        assertEq(token.balanceOf(from), expectedBalance[from], "incorrect debit");
        assertEq(token.balanceOf(to), expectedBalance[to], "incorrect credit");
    }

    function _expectFailure(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success, "invalid operation succeeded");
        assertEq(result, expectedError, "operation reverted for an unexpected reason");
        ++rejectedCalls;
        // No ghost update: the invariants check that every balance and allowance stayed intact.
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % (ACTOR_COUNT + 1);
        return index == ACTOR_COUNT ? address(token) : actors[index];
    }

    /// @dev Exercise zero, one base unit, full balance, one below full, and arbitrary amounts often.
    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        if (limit == 0 || seed % 6 == 0) return 0;
        if (seed % 6 == 1) return 1;
        if (seed % 6 == 2) return limit;
        if (seed % 6 == 3) return limit - 1;
        return bound(seed, 0, limit);
    }
}
