// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsImd} from "../src/ConditionalsImd.sol";

/// @notice Deploys the token with CREATE2 the way the launch factory does, so the constructor's
/// `msg.sender` is a contract rather than an externally owned account.
contract Create2Deployer {
    function deploy(bytes32 salt) external returns (ConditionalsImd token) {
        token = new ConditionalsImd{salt: salt}();
    }
}

contract ConditionalsImdTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    // Launch economics from the brief: 10% swarm, 70% pool seed, 20% remainder.
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 7_000;
    uint256 internal constant BPS = 10_000;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL_MANAGER = address(0x9001);
    address internal constant REMAINDER_TO = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    ConditionalsImd internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(FACTORY);
        token = new ConditionalsImd();
    }

    // ---------------------------------------------------------------- deployment and metadata

    function test_metadata() public view {
        assertEq(token.name(), "ConditionalsImd");
        assertEq(token.symbol(), "COND");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "ConditionalsImd");
        assertEq(token.TOKEN_SYMBOL(), "COND");
    }

    function test_totalSupplyIsOneBillionWith18Decimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        ConditionalsImd fresh = new ConditionalsImd();
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_create2DeployerContractReceivesSupply() public {
        Create2Deployer deployer = new Create2Deployer();
        bytes32 salt = bytes32(uint256(42));
        address predicted =
            vm.computeCreate2Address(salt, keccak256(type(ConditionalsImd).creationCode), address(deployer));
        ConditionalsImd deployed = deployer.deploy(salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_eachDeploymentIsIndependent() public {
        vm.prank(BOB);
        ConditionalsImd second = new ConditionalsImd();
        assertEq(second.balanceOf(BOB), SUPPLY);
        assertEq(second.balanceOf(FACTORY), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    // ---------------------------------------------------------------- launch flows

    /// @dev The factory's payout as the launch performs it: 10% to the distributor, 70% to the
    /// pool manager, 20% to the requester's remainder address. Every leg arrives whole.
    function test_launchDistributionArrivesExactly() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        uint256 remainder = SUPPLY - swarm - pool;
        assertEq(swarm, 100_000_000e18);
        assertEq(pool, 700_000_000e18);
        assertEq(remainder, 200_000_000e18);

        vm.startPrank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm));
        assertTrue(token.transfer(POOL_MANAGER, pool));
        assertTrue(token.transfer(REMAINDER_TO, remainder));
        vm.stopPrank();

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.totalSupply(), SUPPLY);

        // A contributor's claim leaves the distributor whole.
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CAROL, swarm));
        assertEq(token.balanceOf(CAROL), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A pool seed pulls with `transferFrom` after an approval; the pool receives exactly that.
    function test_seedByTransferFromArrivesExactly() public {
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        vm.prank(FACTORY);
        assertTrue(token.approve(POOL_MANAGER, pool));
        vm.prank(POOL_MANAGER);
        assertTrue(token.transferFrom(FACTORY, POOL_MANAGER, pool));
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(FACTORY), SUPPLY - pool);
        assertEq(token.allowance(FACTORY, POOL_MANAGER), 0);
    }

    // ---------------------------------------------------------------- transfer

    function test_transferMovesBalanceAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(FACTORY, ALICE, 123e18);
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 123e18));
        assertEq(token.balanceOf(ALICE), 123e18);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 123e18);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(FACTORY, SUPPLY));
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_transferWholeSupplySucceeds() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(FACTORY), 0);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10e18, 10e18 + 1));
        vm.prank(ALICE);
        token.transfer(BOB, 10e18 + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_RevertWhen_transferMoreThanSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, SUPPLY + 1)
        );
        vm.prank(FACTORY);
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(FACTORY);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- approve and transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(FACTORY, ALICE, 50e18);
        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 50e18));
        assertEq(token.allowance(FACTORY, ALICE), 50e18);

        vm.prank(FACTORY);
        assertTrue(token.approve(ALICE, 0));
        assertEq(token.allowance(FACTORY, ALICE), 0);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 50e18);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(FACTORY, BOB, 20e18);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 20e18));

        assertEq(token.balanceOf(BOB), 20e18);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 20e18);
        assertEq(token.allowance(FACTORY, ALICE), 30e18);
    }

    function test_infiniteAllowanceIsNotDecreased() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 1_000e18);
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, ALICE, 1);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 5e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 5e18, 5e18 + 1));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, 5e18 + 1);
    }

    function test_RevertWhen_transferFromExceedsOwnerBalance() public {
        vm.prank(FACTORY);
        token.transfer(BOB, 3e18);
        vm.prank(BOB);
        token.approve(ALICE, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 3e18, 4e18));
        vm.prank(ALICE);
        token.transferFrom(BOB, CAROL, 4e18);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(FACTORY, address(0), 1e18);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(FACTORY);
        token.approve(address(0), 1);
    }

    /// @dev The deployer gets no special power over a holder's tokens once they have left it.
    function test_RevertWhen_deployerPullsFromHolder() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        vm.prank(FACTORY);
        token.transferFrom(ALICE, FACTORY, 1);
        assertEq(token.balanceOf(ALICE), 1e18);
    }

    // ---------------------------------------------------------------- no privileged surface

    /// @dev Nothing can mint, take ownership, pause or seize: every such call misses the contract's
    /// selectors and reverts, whoever sends it, and leaves the supply and balances as they were.
    function test_noAdminFunctionsExist() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 1e18);

        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setOwner(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        address[2] memory callers = [FACTORY, BOB];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 1e18);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1e18);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1e18));
        assertEq(token.balanceOf(BOB), 1e18);
    }

    function test_RevertWhen_etherSent() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev Reachable runtime code holds no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);

        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount));

        if (to == FACTORY) {
            assertEq(token.balanceOf(FACTORY), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(FACTORY), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertWhen_transferAboveBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);

        vm.prank(FACTORY);
        token.transfer(ALICE, held);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
    }

    function testFuzz_transferFromSpendsExactAllowance(address spender, address to, uint256 allowance, uint256 amount)
        public
    {
        vm.assume(spender != address(0) && to != address(0) && to != FACTORY);
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, allowance);

        vm.prank(FACTORY);
        token.approve(spender, allowance);
        vm.prank(spender);
        assertTrue(token.transferFrom(FACTORY, to, amount));

        assertEq(token.allowance(FACTORY, spender), allowance - amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertWhen_transferFromAboveAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);

        vm.prank(FACTORY);
        token.approve(ALICE, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowance, amount)
        );
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, amount);
    }

    /// @dev Any split of the supply into three legs, as a launch with other economics would pay it,
    /// arrives exactly and sums to the supply.
    function testFuzz_launchSplitArrivesExactly(uint256 swarmBps, uint256 poolBps) public {
        swarmBps = bound(swarmBps, 0, BPS);
        poolBps = bound(poolBps, 0, BPS - swarmBps);
        uint256 swarm = (SUPPLY * swarmBps) / BPS;
        uint256 pool = (SUPPLY * poolBps) / BPS;
        uint256 remainder = SUPPLY - swarm - pool;

        vm.startPrank(FACTORY);
        token.transfer(DISTRIBUTOR, swarm);
        token.transfer(POOL_MANAGER, pool);
        token.transfer(REMAINDER_TO, remainder);
        vm.stopPrank();

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            token.totalSupply()
        );
    }

    function test_interfaceIsPlainErc20() public view {
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.totalSupply(), SUPPLY);
        assertEq(erc20.balanceOf(FACTORY), SUPPLY);
        assertEq(erc20.allowance(FACTORY, ALICE), 0);
    }
}
