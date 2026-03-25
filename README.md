# FreelanceEscrow

> Trustless payment for trustless work — milestone-gated escrow on the Stacks blockchain.

## Overview

FreelanceEscrow is a Clarity smart contract that brings enforceable payment
agreements to freelance work on the Stacks blockchain. Clients lock the full
project budget at engagement creation; that budget is then gated behind a
series of milestones that the freelancer must complete and submit for approval.

No intermediary holds funds. No off-chain platform can freeze your account.
No payment processor can reverse a completed transaction. The contract is the
escrow agent — neutral, always online, and mathematically impartial.

Disputes are resolved by a pre-agreed arbiter (any trusted third party, a
multisig, or a DAO address), whose sole power is to force-release a withheld
milestone payment. The arbiter cannot move money anywhere other than to the
freelancer.

---

## Why FreelanceEscrow?

Traditional freelance platforms extract 10–20% in fees, can suspend accounts
without warning, and hold funds in opaque off-chain systems. Even escrow
alternatives require trusting a centralized custodian.

FreelanceEscrow eliminates these failure points:

- **No platform risk** — the contract code is immutable and open source
- **No custodial risk** — funds are held by the contract, not an operator
- **No counterparty surprise** — all terms (amounts, milestones, arbiter) are
  set in stone at engagement creation
- **Minimal fees** — only Stacks network transaction costs apply

---

## Features

- **Full budget lock at creation** — the client deposits the entire project
  budget in one atomic transaction; no drip-funding or partial deposits
- **Five independent milestones** — each milestone has its own STX amount,
  and releases are fully independent of one another
- **Evidence-hash submission** — freelancers attach a 32-byte hash (e.g. an
  IPFS CID or SHA-256 of a deliverable) when marking work done, creating an
  immutable audit trail
- **Per-milestone dispute flow** — a freelancer can raise a dispute on any
  single milestone without affecting the others
- **Named arbiter** — the arbiter address is fixed at creation and is the only
  entity that can force-release a disputed milestone to the freelancer
- **Bilateral cancellation** — both client and freelancer must signal intent
  to cancel; unilateral exits are not possible
- **Unspent budget return** — cancelled engagements refund all unreleased STX
  to the client immediately
- **Zero-warning Clarity code** — all user-supplied inputs are validated before
  touching any map key or value, satisfying Clarity's taint checker

---

## Architecture

FreelanceEscrow uses three orthogonal maps with no shared keys or nested
structures. Each map owns exactly one domain of concern.

```
┌──────────────────────────────────────────────────────┐
│                FreelanceEscrow Contract               │
├───────────────┬──────────────────┬───────────────────┤
│  engagements  │    milestones    │     disputes       │
│  (uint → {})  │ ({eid,idx} → {}) │  ({eid,idx} → {}) │
└───────────────┴──────────────────┴───────────────────┘
         ▲                ▲                  ▲
         │                │                  │
    engagement         milestone          dispute
    metadata           work unit          record
```

**`engagements`** — top-level record keyed by a monotonically incrementing
integer. Stores parties, budget tracking, cancellation flags, and closed status.

**`milestones`** — keyed by `(eid, idx)` composite. Stores the STX amount,
optional evidence hash, and current lifecycle state for each of the five
milestone slots.

**`disputes`** — keyed by `(eid, idx)`. Created when a freelancer raises a
dispute; stores the block height and a reason hash for off-chain reference.

The `eng-counter` data variable is the only mutable global; it serves as the
engagement ID nonce.

---

## State Machine

Each milestone progresses through states independently:

```
                   submit-milestone
  MS-PENDING  ──────────────────────►  MS-SUBMITTED
                                            │
                               ┌────────────┴────────────┐
                    release-   │                          │  raise-
                    milestone  │                          │  dispute
                               ▼                          ▼
                          MS-RELEASED               MS-DISPUTED
                                                         │
                                              arbiter-release │
                                                         ▼
                                                    MS-FORCED
```

| Code | Constant      | Description                                      |
|------|---------------|--------------------------------------------------|
| `u0` | `MS-PENDING`  | Milestone created, work not yet started          |
| `u1` | `MS-SUBMITTED`| Freelancer marked done, awaiting client approval |
| `u2` | `MS-RELEASED` | Client approved; STX transferred to freelancer   |
| `u3` | `MS-DISPUTED` | Freelancer flagged milestone as withheld          |
| `u4` | `MS-FORCED`   | Arbiter force-released; STX sent to freelancer   |

State transitions are strictly one-directional. There is no path back to
`MS-PENDING` from any other state, and no path from `MS-RELEASED` or
`MS-FORCED` to any other state.

---

## Contract Storage

### `engagements` map

| Field            | Type        | Description                                   |
|------------------|-------------|-----------------------------------------------|
| `client`         | `principal` | Address that created and funded the engagement |
| `freelancer`     | `principal` | Address that will perform the work             |
| `arbiter`        | `principal` | Trusted third party for dispute resolution     |
| `total-budget`   | `uint`      | Total STX locked (sum of all milestones)       |
| `milestone-count`| `uint`      | Always `u5` in current version                 |
| `spent`          | `uint`      | Cumulative STX released so far                 |
| `client-cancel`  | `bool`      | Client has signalled cancellation intent       |
| `worker-cancel`  | `bool`      | Freelancer has signalled cancellation intent   |
| `closed`         | `bool`      | Engagement is terminated; no further writes    |

### `milestones` map — key: `{ eid: uint, idx: uint }`

| Field           | Type                   | Description                          |
|-----------------|------------------------|--------------------------------------|
| `amount`        | `uint`                 | STX allocated to this milestone      |
| `evidence-hash` | `(optional (buff 32))` | Hash attached by freelancer on submit|
| `state`         | `uint`                 | Current lifecycle state code         |

### `disputes` map — key: `{ eid: uint, idx: uint }`

| Field         | Type       | Description                                 |
|---------------|------------|---------------------------------------------|
| `raised-at`   | `uint`     | Block height when dispute was filed         |
| `reason-hash` | `(buff 32)`| Hash of off-chain dispute justification     |

---

## Function Reference

### `create-engagement`

```clarity
(create-engagement freelancer arbiter total-budget m0 m1 m2 m3 m4)
→ (response uint uint)
```

Called by the **client**. Transfers `total-budget` STX to the contract and
creates the engagement plus all five milestone records. Returns the new
engagement ID on success.

- `freelancer` and `arbiter` must differ from each other and from `tx-sender`
- `m0 + m1 + m2 + m3 + m4` must equal `total-budget` exactly
- Any milestone with a zero amount is valid (effectively skipping that slot)

---

### `submit-milestone`

```clarity
(submit-milestone eid idx evidence-hash)
→ (response bool uint)
```

Called by the **freelancer**. Transitions milestone `idx` from `MS-PENDING`
to `MS-SUBMITTED`. The `evidence-hash` (e.g. SHA-256 of a deliverable or an
IPFS CID) is stored on-chain as an immutable proof of delivery claim.

---

### `release-milestone`

```clarity
(release-milestone eid idx)
→ (response bool uint)
```

Called by the **client**. Approves a `MS-SUBMITTED` milestone, transfers its
STX amount directly to the freelancer, and advances state to `MS-RELEASED`.
The `spent` counter on the engagement is incremented accordingly.

---

### `raise-dispute`

```clarity
(raise-dispute eid idx reason-hash)
→ (response bool uint)
```

Called by the **freelancer** on a `MS-SUBMITTED` milestone they believe the
client is wrongfully withholding. Transitions state to `MS-DISPUTED` and
records a `reason-hash` linking to off-chain evidence (e.g. a forum post,
a legal document hash, or an IPFS-hosted statement).

---

### `arbiter-release`

```clarity
(arbiter-release eid idx)
→ (response bool uint)
```

Called by the **arbiter** on a `MS-DISPUTED` milestone. Force-transfers the
milestone STX to the freelancer and marks state as `MS-FORCED`. The arbiter
cannot redirect funds anywhere other than the freelancer's address.

---

### `propose-cancel`

```clarity
(propose-cancel eid)
→ (response bool uint)
```

Called by either the **client** or the **freelancer** to signal cancellation
intent. Sets the caller's cancel flag on the engagement. Calling twice from
the same side reverts with `ERR-ALREADY-SIGNALED`.

---

### `confirm-cancel`

```clarity
(confirm-cancel eid)
→ (response bool uint)
```

Finalises cancellation once **both** cancel flags are set. Marks the
engagement `closed` and refunds all unspent STX (`total-budget - spent`)
to the client. If nothing is unspent, returns `(ok true)` with no transfer.

---

### Read-Only Functions

| Function | Returns | Description |
|---|---|---|
| `get-engagement eid` | `(optional {...})` | Full engagement record |
| `get-milestone eid idx` | `(optional {...})` | Single milestone record |
| `get-dispute eid idx` | `(optional {...})` | Dispute record if exists |
| `get-eng-count` | `uint` | Total engagements created |

---

## Error Codes

| Constant               | Code   | Trigger Condition                                |
|------------------------|--------|--------------------------------------------------|
| `ERR-NOT-CLIENT`       | `u700` | Caller is not the engagement client              |
| `ERR-NOT-FREELANCER`   | `u701` | Caller is not the engagement freelancer          |
| `ERR-NOT-ARBITER`      | `u702` | Caller is not the designated arbiter             |
| `ERR-BAD-ENG`          | `u703` | Engagement ID does not exist                     |
| `ERR-BAD-MILESTONE`    | `u704` | Milestone record not found for given eid + idx   |
| `ERR-WRONG-STATE`      | `u705` | Milestone or engagement is in wrong state        |
| `ERR-TRANSFER-FAIL`    | `u706` | STX transfer returned an error                   |
| `ERR-ZERO-VALUE`       | `u707` | Budget is zero, sums don't match, or null hash   |
| `ERR-CANCEL-PENDING`   | `u708` | Reserved for future partial cancel logic         |
| `ERR-NO-CANCEL-SIGNAL` | `u709` | Both cancel flags not set when confirming        |
| `ERR-ALREADY-SIGNALED` | `u710` | Same party called `propose-cancel` twice         |
| `ERR-INVALID-PARTY`    | `u711` | Principal fails address validation checks        |
| `ERR-INVALID-IDX`      | `u712` | Milestone index exceeds MAX-IDX (`u4`)           |

---

## Example Workflows

### Standard happy path

```clarity
;; 1. Client creates engagement: 500 STX split across 5 milestones
(contract-call? .freelance-escrow create-engagement
  'SP2FREELANCER... 'SP3ARBITER...
  u500000000
  u100000000 u100000000 u100000000 u100000000 u100000000)
;; → (ok u1)  — engagement ID 1 created

;; 2. Freelancer submits milestone 0 with evidence hash
(contract-call? .freelance-escrow submit-milestone
  u1 u0 0xabc123...)
;; → (ok true)

;; 3. Client approves and pays out milestone 0
(contract-call? .freelance-escrow release-milestone u1 u0)
;; → (ok true)  — 100 STX sent to freelancer
```

### Dispute and arbiter resolution

```clarity
;; Freelancer believes milestone 2 is wrongfully withheld
(contract-call? .freelance-escrow raise-dispute
  u1 u2 0xdeadbeef...)
;; → (ok true)  — state: MS-DISPUTED

;; Arbiter reviews evidence and releases payment
(contract-call? .freelance-escrow arbiter-release u1 u2)
;; → (ok true)  — 100 STX sent to freelancer
```

### Bilateral cancellation

```clarity
;; Both parties agree to end the engagement early
(contract-call? .freelance-escrow propose-cancel u1)  ;; client
(contract-call? .freelance-escrow propose-cancel u1)  ;; freelancer

;; Either party finalises — unspent STX returns to client
(contract-call? .freelance-escrow confirm-cancel u1)
;; → (ok true)
```

---

## Security Considerations

**Budget integrity** — The full `total-budget` is transferred to the contract
in the same transaction as engagement creation. There is no way to create an
engagement with a promised budget that has not already been deposited.

**Arbiter scope limitation** — The arbiter's only callable function is
`arbiter-release`. It cannot transfer money to itself, to the client, or to
any address other than the freelancer named in the engagement record.

**Cancellation atomicity** — `confirm-cancel` checks both flags in a single
`asserts!` and performs the refund transfer in the same call. There is no
window where flags are set but funds are not returned.

**Taint-checker compliance** — All user-supplied inputs (`freelancer`,
`arbiter`, `idx`, `evidence-hash`, `reason-hash`) are explicitly validated
with `asserts!` before appearing in any `map-set` key or value. The contract
compiles with zero Clarity warnings.

**No re-entrancy surface** — Clarity is not susceptible to re-entrancy by
design (no dynamic dispatch). All state mutations happen before any `stx-transfer?`
call via the `merge` + `map-set` pattern.

**Closed flag enforcement** — Once `closed: true` is set, every mutating
function checks `(not (get closed eng))` as its first guard, making all
further writes impossible.

---

## Deployment

```bash
# Clone the repository
git clone https://github.com/your-org/freelance-escrow
cd freelance-escrow

# Install Clarinet
curl -L https://github.com/hirosystems/clarinet/releases/latest \
  /download/clarinet-linux-x64.tar.gz | tar xz

# Check contract for errors and warnings
clarinet check

# Deploy to testnet
clarinet deployments apply --testnet
```

Ensure your `Clarinet.toml` specifies the correct contract name and that
your deployer wallet has sufficient STX for the deployment transaction.

---

## Testing

```bash
# Run the full test suite
clarinet test

# Run a specific test file
clarinet test tests/freelance-escrow_test.ts
```

Recommended test coverage:

- `create-engagement` with mismatched milestone sums → expect `ERR-ZERO-VALUE`
- `submit-milestone` with out-of-range `idx` → expect `ERR-INVALID-IDX`
- `release-milestone` called by non-client → expect `ERR-NOT-CLIENT`
- `raise-dispute` on an already-released milestone → expect `ERR-WRONG-STATE`
- `arbiter-release` called by non-arbiter → expect `ERR-NOT-ARBITER`
- Full happy-path flow across all five milestones
- Cancellation with only one party signalling → expect `ERR-NO-CANCEL-SIGNAL`
- Correct unspent refund amount after partial milestone releases

---

## Limitations & Known Constraints

- **Fixed at five milestones** — the current version hardcodes `u5` milestone
  slots. Engagements with fewer deliverables should set unused milestone
  amounts to `u0`.
- **No partial milestone payment** — each milestone is all-or-nothing; there
  is no mechanism to release a fraction of a milestone's value.
- **Arbiter is not incentivised** — the contract does not compensate the
  arbiter. Fee arrangements must be handled off-chain or in a wrapper contract.
- **No deadline enforcement** — there is no block-height deadline on milestone
  completion. Time pressure must be agreed off-chain.
- **One engagement per call** — clients must call `create-engagement` separately
  for each new project; batch creation is not supported.

---

## Future Roadmap

- [ ] Dynamic milestone count via a list parameter
- [ ] Block-height deadline per milestone with auto-refund on expiry
- [ ] Arbiter fee deducted from disputed milestone amount
- [ ] SIP-010 fungible token support as payment currency
- [ ] Reputation NFT minted to freelancer on full engagement completion
- [ ] Wrapper contract for DAO-based arbitration via governance vote
- [ ] Multi-client co-funding for larger engagements

---

## Contributing

Pull requests are welcome. Please open an issue first to discuss major changes.
All contributions must pass `clarinet check` with zero errors and zero warnings
before review.

Code style: follow the naming conventions and comment structure present in the
existing contract. Use `ERR-` prefixed constants for all new error codes.
