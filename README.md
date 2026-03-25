# FreelanceEscrow

Trustless payment for trustless work.

FreelanceEscrow lets clients lock STX into milestone-gated escrow accounts.
Freelancers complete work, submit evidence hashes, and clients release each
milestone independently. A built-in dispute window lets freelancers challenge
a withheld release before a neutral arbiter steps in.

---

## Features

- Client creates an engagement with N milestones upfront
- Full budget locked at engagement creation
- Per-milestone release flow: submit → approve → transfer
- Freelancer can raise a dispute on any approved-but-unpaid milestone
- Arbiter (set at creation) can force-release disputed milestones
- Client can reclaim unstarted milestones if engagement is cancelled
- Both parties must agree to cancel an active engagement

---

## Architecture
```
engagements      → top-level contract metadata
milestones       → (eng-id, index) → work unit state
disputes         → (eng-id, index) → dispute record
```

Milestone lifecycle:
```
PENDING → SUBMITTED → RELEASED
                └──→ DISPUTED → FORCE-RELEASED
```

State codes: `u0`=pending, `u1`=submitted, `u2`=released, `u3`=disputed, `u4`=force-released

---

## Function Reference

| Function | Caller | Action |
|---|---|---|
| `create-engagement` | Client | Lock STX, define milestones |
| `submit-milestone` | Freelancer | Mark work done, attach evidence hash |
| `release-milestone` | Client | Approve and pay out one milestone |
| `raise-dispute` | Freelancer | Flag a submitted milestone as withheld |
| `arbiter-release` | Arbiter | Force-pay a disputed milestone |
| `propose-cancel` | Either party | Signal intent to cancel |
| `confirm-cancel` | Other party | Finalise cancellation, return unspent budget |
| `get-engagement` | Anyone | Read engagement state |
| `get-milestone` | Anyone | Read individual milestone |

---

## Security Considerations

- Total budget is locked atomically at creation; no partial deposits
- Arbiter address is immutable after creation
- Dispute can only be raised on a `SUBMITTED` milestone, not `RELEASED`
- Cancellation requires both parties to consent — no unilateral exits
- Force-release only available to the designated arbiter, not the freelancer
