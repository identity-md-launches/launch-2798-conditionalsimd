# ConditionalsImd (COND)

A fixed-supply ERC-20 for an IMD custom token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `ConditionalsImd` in `src/ConditionalsImd.sol` |
| `name()` | `ConditionalsImd` |
| `symbol()` | `COND` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Initial holder | the deployer (`msg.sender`), which on launch is the IMD ProjectFactory |
| Owner / admin | none |

## Behaviour

- The constructor mints the whole supply once to `msg.sender`. No other code path mints, so the
  supply can never grow.
- Nothing burns either, so the supply stays at exactly 1,000,000,000 COND for good.
- Transfers are plain OpenZeppelin v5.1.0 `ERC20`: no fee, tax, burn, cooldown, limit or hook on
  transfer. Every `transfer`/`transferFrom` moves exactly the amount it names. This keeps the launch
  flows exact (factory → MerkleDistributor, distributor → claimants, factory → Uniswap v4
  PoolManager for the seed, and swaps either way).
- No owner, pause, blacklist, freeze, seize, `burnFrom` or upgrade path. No privileged party can
  move or freeze a holder's balance. The runtime has no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`, and the contract has no `receive`/`fallback`, so it refuses ETH.
- The constructor calls no other contract and does not check whether any address has code.
- No library is linked: the bytecode has no link placeholders.

## Deployment parameters

The launch deploys `ConditionalsImd` from its creation code through `ProjectFactory.launchCustom`
with **no constructor arguments**. The factory is `msg.sender` in the constructor and gets the
whole supply. This project has no application contracts.

These are the launch's values. The manifest step writes them into `launch.json` after this work is
accepted, so this repository does not ship a `launch.json`:

| Item | Value |
| --- | --- |
| Chain | Ethereum, chain id 1 |
| `token.contract` | `ConditionalsImd` |
| `token.name` / `token.symbol` / `token.decimals` | `ConditionalsImd` / `COND` / `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `pool.pairedCurrency` | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| `pool.fee` | `12500` (1.25%, the launch policy's fee) |
| `pool.tickSpacing` | `60` |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only: the deployer derives the opening price from `initialMarketCapWei`) |
| `economics` | `{"poolBps":7000,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xee2aaa315cf7ed169f93148d30d24af9318dbb66"}` |

How the supply is paid out at launch. The factory does all of this; the token does nothing special:

| Leg | Share | COND |
| --- | --- | --- |
| Swarm, sent by the factory to the launch's MerkleDistributor | 10% | 100,000,000 |
| Single-sided pool seed (`poolBps` 7000), opening at a 2,500 IMD market cap | 70% | 700,000,000 |
| Remainder to `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` | 20% | 200,000,000 |

## After launch

Nothing needs setting. The token has no owner-settable values, no outside dependencies and no
admin.

## Assumptions

- "Deployer" in the brief means the launch's ProjectFactory, which deploys the token and pays out the
  whole supply as above. The token does not exempt or whitelist any launch address because it has
  no transfer rules that would need one.
- The brief asks for no transfer rules, taxes, burns, governance or admin features, so none are
  added. A burn, a permit (EIP-2612) or votes would each be a change in behaviour and need a new
  brief.
- The compiler is pinned to solc 0.8.26 with `evm_version = "cancun"`, which Ethereum mainnet
  supports. `bytecode_hash = "none"` makes the build reproducible. The optimizer is on with 200
  runs.

## Operational responsibilities and trust model

- **IMD's deployer** deploys the token through the factory, records it under the name
  `ConditionalsImd`, seeds the pool and funds the MerkleDistributor. This repository holds no keys and
  sends no transactions. Verifying the source on Etherscan after deployment
  (`forge verify-contract`, with the settings in `foundry.toml`) is open for the deployer.
- **The requester** gets the 20% remainder at `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` and holds
  it like any other holder. It gets no privileged power over the token.
- **Holders** only need to trust the code: no one can mint, pause, freeze or move their tokens.
- Standard ERC-20 caveats remain:
  - The `approve` allowance-change race applies. To change a non-zero allowance, set it to 0 first.
  - Tokens sent by mistake to the token contract's own address are stuck for good. There is
    deliberately no rescue function, because one would be a privileged hand on balances.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Tests run with an empty environment, in any order and in parallel. They read no environment
variables and use no `ffi` or filesystem access. They cover:

- `test/ConditionalsImd.t.sol`
  - Metadata, supply and the mint to the deployer, including a CREATE2 deployer contract like the
    factory.
  - The exact launch payout: 10% / 70% / 20% and the distributor claim. The seed pulls by
    `transferFrom`.
  - Transfer, approve and `transferFrom` success paths and events.
  - Failure paths: over balance, over allowance, zero receiver, zero spender, the deployer pulling
    from a holder, and ETH sent to the token.
  - The absence of every common admin selector: mint, ownership, pause, blacklist, freeze, burn,
    upgrade and initialize.
  - A runtime opcode scan.
  - Fuzz tests for conservation, exact allowance spending and arbitrary launch splits.
- `test/ConditionalsImd.invariant.t.sol`: the supply stays fixed and holders' balances always add
  up to the supply under random transfers, approvals and `transferFrom`.

The fuzz suites were run with
`FOUNDRY_FUZZ_SEED=0xfaff44e5a70ad59335f101029409e80b6fb8ffcef220b2a35873f4654c8f04b2`.

Dependencies are vendored as plain files, not submodules:

- `lib/forge-std`: forge-std v1.9.7 (`src/` and licences)
- `lib/openzeppelin-contracts`: OpenZeppelin Contracts v5.1.0 (`contracts/` and licence)

## Security notes

Passing tests are not an audit. Slither and Mythril were not available here and were not run. The
contract is OpenZeppelin's audited `ERC20` with a constructor mint and three constants, and has no
privileged surface. Even so, an independent review before release is still recommended.
