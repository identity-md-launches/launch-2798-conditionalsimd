# ConditionalsImd test properties

These tests extend the original deployment, launch-transfer, ERC-20 and conservation tests.
They use the existing vendored dependencies and require no network, fork, environment reads,
FFI, or changes to the implementation or Foundry configuration.

## Discovery and grounding

The five discovery passes from the supplied Pashov reference were applied to this token:

| Pass | Relevant properties | Basis |
| --- | --- | --- |
| Conservation | Fixed supply; the complete recipient set accounts for every unit; individual credits equal requested transfers | `src/ConditionalsImd.sol:18-21`; ERC20 `_update` |
| State transitions | Approvals replace prior values; finite spends consume exactly the amount; revocation prevents further positive spends; failures roll back balances and allowances | ERC20 `approve`, `transferFrom`, `_approve`, `_spendAllowance` |
| Round trips | Sending an amount and returning it restores both accounts exactly, including one base unit and the full balance | No fee or burn override in ConditionalsImd; ERC20 `_transfer` and `_update` |
| Adversarial sequences | Self-transfers cannot bypass balance/allowance checks; repeated spends cannot reuse exhausted authorization; infinite approval cannot bypass balance checks | ERC20 `_update` and `_spendAllowance` |
| Token-specific | Zero transfers emit Transfer; zero destinations/spenders are rejected; self-transfers preserve balances; delegated self-transfers still consume finite approval | ERC20 transfer/approval implementation and events |

These are expected properties of this fixed-supply token and its inherited ERC-20 behavior.
The maximum uint256 allowance sentinel is specifically OpenZeppelin behavior. The tests
do not assume approvals are limited by a holder's balance, or that the deployer has special powers.
There are no vault conversions, yield, fees, governance, or configurable lifecycle states to test.

## Stateful accounting

`ConditionalsImd.accounting.invariant.t.sol` explicitly targets twelve actions in
`helpers/ConditionalsImdAccountingHandler.sol`. Four actors receive equal portions through real
transfers. The token contract is an additional passive recipient, included in conservation checks
but never impersonated to make withdrawals.

The handler maintains expected balances and all sixteen owner/spender allowances, initialized
from the known distribution and updated from requested operations. It does not copy the token's
reported state into its model or use reported balances to constrain subsequent inputs.

After each random handler call, the invariants check:

- Every tracked balance equals its expected balance, their sum is exactly `1e27`, and total supply
  remains `1e27`. The zero address never receives tokens.
- Every approval equals the last owner-authorized value less successful finite spends. Unrelated
  approvals remain unchanged, infinite approvals persist until replaced, and failed calls consume
  nothing. The token contract and zero spender never acquire unintended authorization.
- Name, symbol and decimals remain `ConditionalsImd`, `COND` and `18`.

Direct transfers, approvals, revocations, delegated transfers, self-transfers and round trips are
interleaved with over-balance, over-allowance and zero-address attempts. Expected reverts are
checked using low-level calls with exact error data; they leave the model unchanged. Unexpected
handler reverts fail the campaign. Amount generation frequently selects zero, one, full balance,
one below full, infinite/near-infinite approvals and arbitrary bounded values.

A deterministic mixed-sequence test exercises every handler action and checks that nonzero direct
and delegated movements actually occur, including full-balance draining. Individual unit and fuzz
tests pin the approval lifecycle, rejection rollback, constructor mint event, and arithmetic
boundaries independently. They also check that authorization remains usable after rejected calls.

Inline settings specify 1,000 cases for each new stateless fuzz test and 256 invariant sequences
of depth 128. The original suites retain their existing settings.

## Local verification

Build artifacts can stay within the disposable scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xfaff44e5a70ad59335f101029409e80b6fb8ffcef220b2a35873f4654c8f04b2 forge test --out test/scratch/out --cache-path test/scratch/cache
```

The delivered Solidity files never import anything from `test/scratch/`. Ordinary `forge test`
also discovers them. The supplied protected launch checks were reviewed as acceptance inputs;
these local tests do not simulate or claim to execute the unavailable factory/Uniswap deployment
harness. Existing launch-transfer tests and the protected integration suite cover different layers.
