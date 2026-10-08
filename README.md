# ERC-20 Withdrawal Test Application

A minimal [Cartesi](https://cartesi.io) rollups application that accepts ERC-20 deposits and
processes withdrawals. Its real purpose is to exercise the **accounts drive** feature: a dedicated,
Merkleized flash drive that holds every user's balance so that, if the application ever **forecloses**
(is shut down in cae of emergencies by its guardian), users can prove their balance on-chain and withdraw their
tokens directly from the rollup contracts — without needing the off-chain node to be alive.

The entire application is implemented as a single Bash script (see [`install.sh`](install.sh)) running
inside a Cartesi Machine. There is no compiled backend; the script is installed into the machine image
at build time as the rollup entrypoint.

## Why this exists

In a normal Cartesi rollup, withdrawals are emitted as **vouchers** that the node produces and that the
user executes on-chain once the corresponding epoch is settled. That path depends on a live, honest
node continuing to advance the machine and emit outputs.

The accounts drive provides a **trustless contingency plan**. The application keeps all balances in a single
flash drive laid out as a fixed-size array of account records. The on-chain contracts know the drive's
location and layout, so the drive's contents are committed to in the machine's state hash every epoch.
If the operator stops the application (foreclosure), any user can:

1. Read their account record and its Merkle proof against the last settled accounts-drive root.
2. Submit that proof to the withdrawal contracts.
3. Withdraw the exact balance recorded for their address.

This makes the application's custody of deposited ERC-20 tokens **self-sovereign**: liveness of the node
is not required to recover funds.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Cartesi Machine                                          │
│                                                          │
│  /dev/pmem0  root      → rootfs (busybox, jq, xxd, …)    │
│  /dev/pmem1  accounts  → raw 4 MiB accounts drive        │
│                                                          │
│  entrypoint: /usr/local/bin/erc20-withdrawal-dapp (bash) │
│    • handles ERC-20 deposits (from the ERC-20 Portal)    │
│    • handles withdrawals (debits + emits a voucher)      │
│    • answers balance inspect queries                     │
└──────────────────────────────────────────────────────────┘
```

- **Root drive** (`/dev/pmem0`, label `root`): the standard Cartesi guest rootfs with the tools the
  script needs (`bash`, `busybox`, `jq`, `xxd`, `dd`, `rollup`).
- **Accounts drive** (`/dev/pmem1`, label `accounts`): a raw 4 MiB flash drive created with
  `mke2fs:false` (no filesystem) and owned by the `dapp` user. It is a packed array of account records.
  This is the drive the on-chain withdrawal logic reads from.

### Accounts drive layout

The accounts drive is a contiguous array of fixed-size **32-byte records**, packed from index `0`. The
first all-zero record marks the end of the array.

| Offset | Size     | Field             | Encoding                          |
| ------ | -------- | ----------------- | --------------------------------- |
| 0      | 12 bytes | balance           | `uint96`, little-endian           |
| 12     | 20 bytes | account address   | 20-byte EVM address               |

This is the USD account layout that rollups-contracts v3.0.0-alpha.10 (`LibUsdAccount`) decodes, as
used by Cartesi Rollups Node v2.0.0-alpha.13. The script still does its arithmetic in 64 bits and stores
the balance zero-extended to 12 bytes.

- Capacity: `4 MiB / 32 bytes = 131072` accounts (`2^17`), matching the deploy parameter
  `log2_max_num_of_accounts = 17`.
- Balances are stored and manipulated as 64-bit integers, so deposit/withdraw amounts must fit in a
  positive signed 64-bit value. The deposit handler explicitly rejects any ERC-20 amount that does not
  fit (the high 24 bytes of the `uint256` must be zero and the value must be `< 2^63`).
- The array stays **packed**: when an account's balance reaches zero, it is removed by swapping the last
  record into its slot ("swap-remove") and zeroing the old tail. This keeps proofs and indexing compact.

## Input model

The application processes Cartesi rollup requests in a loop. Each request is either an
`advance_state` (an on-chain input) or an `inspect_state` (a read-only query).

### 1. Deposit — ERC-20 Portal `advance_state`

Deposits arrive as advance inputs **from the trusted ERC-20 Portal**. The handler accepts the input only
if `msg_sender` equals the configured portal address and the embedded token equals the configured token
address. The payload is the standard ERC-20 Portal encoding:

```
| token (20 bytes) | depositor (20 bytes) | amount (uint256, 32 bytes) | …extra data |
```

On success the depositor's balance is credited and the application emits the report `deposit ok`.

### 2. Withdraw — `advance_state`

Withdrawals are submitted as a generic input where `msg_sender` is the withdrawing address. The payload
is **9 bytes**:

```
| 0x01 (opcode) | amount (uint64, big-endian, 8 bytes) |
```

The handler debits `amount` from the sender's account and emits an ERC-20 `transfer(recipient, amount)`
**voucher** targeting the trusted token. On success it emits the report `withdraw ok`.

> This is the "happy path" voucher-based withdrawal used for testing. The accounts-drive proof path is
> the emergency alternative handled on-chain by the withdrawal contracts, not by this script.

### 3. Balance query — `inspect_state`

Inspect requests carry a UTF-8 text query:

```
balance 0x<40-hex-address>
```

The response is a JSON report, e.g.:

```json
{"type":"erc20_balance","address":"0x….","found":true,"account_index":"0x0","balance":"1000"}
```

Unknown addresses return `found:false` with `balance:"0"`.

### Reports

The script emits short ASCII reports to signal the outcome of each advance:

| Bytes (hex)                  | Meaning      |
| ---------------------------- | ------------ |
| `6465706f736974206f6b`       | `deposit ok` |
| `7769746864726177206f6b`     | `withdraw ok`|
| `62616420696e707574`         | `bad input`  |

Inputs that match neither a valid deposit nor a valid withdrawal are **rejected** with `bad input`.

## Configuration

The build wires two trusted addresses into the machine image as environment variables (see the
`TRUSTED_ERC20_PORTAL` / `TRUSTED_ERC20_TOKEN` exports in [`Makefile`](Makefile)):

| Variable                              | Default (devnet)                              | Meaning                                  |
| ------------------------------------- | --------------------------------------------- | ---------------------------------------- |
| `CARTESI_DEVNET_ERC20_PORTAL_ADDRESS` | `0x3332DE61a8BB9aC84893b2f552Fe81C9a6dC5419`  | Only sender accepted for deposits        |
| `CARTESI_DEVNET_TEST_ERC20_ADDRESS`   | `0x7a051EDffC0884cd88d4a377F4C87BE074CF6c81`  | The single ERC-20 token handled (devnet TestUsdc) |

The ERC-20 portal address is the same on every network that has rollups-contracts v3.0.0-alpha.10. Set
`CARTESI_DEVNET_TEST_ERC20_ADDRESS` to the token of the target network when building for it; the
withdrawal output builder used at deploy time must pay out that same token.

## Building

Building produces a stored Cartesi Machine snapshot under `.cartesi/image/`.

### Prerequisites

- [`cartesi-machine`](https://github.com/cartesi/machine-emulator) (the emulator CLI), v0.21.0 (the
  version Cartesi Rollups Node v2.0.0-alpha.13 runs; snapshots from v0.20 do not load).
- Standard build tools (`make`, `wget`, `shasum`, `jq`).

### Steps

```sh
make
```

This will:

1. Download the kernel and tools rootfs pinned in [`dependencies`](dependencies) (verified against
   [`dependencies.sha256`](dependencies.sha256)).
2. Run `cartesi-machine` with a 128 MiB RAM image, the root flash drive, and a **4 MiB `accounts`
   flash drive** (`mke2fs:false`, `mount:false`, owned by `dapp`).
3. Install [`install.sh`](install.sh) as the machine init, which writes the dApp script to
   `/usr/local/bin/erc20-withdrawal-dapp` and sets it as the entrypoint.
4. Store the final machine to `.cartesi/image/` and print its final hash.

## Deploying

`make deploy-erc20-withdrawal-dapp` deploys the stored image with the **withdrawal configuration** the
on-chain contracts need to validate accounts-drive proofs:

```jsonc
{
  "guardian": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // may foreclose the app
  "log2_leaves_per_account": 0,                              // 1 leaf per account record
  "log2_max_num_of_accounts": 17,                            // up to 131072 accounts
  "accounts_drive_start_index": <derived from config.json>,  // which flash drive holds balances
  "withdrawal_output_builder": "0xB4D253c7a110241561B3eD6d632846dF7d4e9Af7" // devnet TestUsdc builder
}
```

The `accounts_drive_start_index` is computed from the machine's `config.json` by locating the 4 MiB
flash drive, so the contracts read balances from the correct drive. The deploy also sets the snapshot
policy to `EVERY_EPOCH` so the accounts-drive root is committed every epoch.

Override the defaults with environment variables:

| Variable                                          | Purpose                                  |
| ------------------------------------------------- | ---------------------------------------- |
| `APP`                                             | Application name                         |
| `GUARDIAN`                                         | Address allowed to foreclose             |
| `CARTESI_DEVNET_WITHDRAWAL_OUTPUT_BUILDER_ADDRESS` | Withdrawal output builder contract       |

## Continuous integration

[`.github/worlflows/build-and-release.yml`](.github/worlflows/build-and-release.yml) installs the
Cartesi Machine emulator, runs `make` to build the snapshot, and uploads it as the
`erc20-withdrawal-snapshot` artifact. On tags matching `v*` it publishes the snapshot tarball as a
pre-release.

## Implementation notes

- **Single-token, single-portal by design.** The script trusts exactly one portal and one token; this
  keeps the accounts drive a simple `address → balance` map and the on-chain proof straightforward.
- **64-bit amounts.** Balances live in Bash integer arithmetic, capping individual amounts at `2^63 - 1`.
  This is intentional for a test application.
- **Merkle bookkeeping workaround.** The stock `rollup` helper resets `/tmp/merkle.dat` after each
  advance request, but the node compares against the cumulative output tree. Because this shell dApp
  calls the helper once per operation, `accept_request` preserves and restores `merkle.dat` across
  requests so voucher proofs remain valid (see the comment in [`install.sh`](install.sh)).
```