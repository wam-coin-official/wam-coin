# Treasury custody — the plan, and what it does not solve

**Written 2026-08-28. Reviewed on the first of each month; the date above
changes when the plan does.**

`LAUNCH_CHECKLIST.md` asks for this document by name: *a migration plan to
multi-signature custody exists and is dated.* Here it is, including the
parts that are uncomfortable.

---

## What is actually at risk

| | |
|---|---|
| Rate | 5% of every block subsidy, enforced by consensus rule WAM-1 |
| Ends at | block 400,000 |
| Total | **750,000 WAM**, about 3.41% of the 22,000,000 cap |
| Over | roughly 18 months at two-minute blocks |
| Address | `WdMMqW1DcgWZ6HtyJuEMdce6QkKg4raGmE` |
| Controlled by | **one key, one person, one piece of paper** |

The founder reserve is a separate matter and a separate key: 2,000,000 WAM
locked on-chain until 2027 and released in tranches to 2031. Those coins
cannot move whatever happens to the key, which is the point of locking them.
The treasury has no such protection — it is spendable the moment it arrives.

So the treasury, not the reserve, is the live exposure. It is smaller and it
is the one that can be lost this year.

---

## The constraint that shapes everything below

**The treasury address cannot be changed.** It is compiled into
`src/wam/chainparams.cpp` as the destination every node checks in every
block. Changing it is a consensus change: a hard fork, and every node that
did not upgrade would reject every block afterwards.

So "migrate the treasury to multi-signature" cannot mean *pay it somewhere
else*. Consensus pays where it pays.

What it can mean, and what this plan is:

> Consensus pays into a single-key address. That address is a **doorway, not
> a vault.** On a fixed cadence the balance is swept out to a 2-of-3
> multi-signature address, and the single key holds only what has arrived
> since the last sweep.

That turns a standing liability of 750,000 WAM into a rolling one of
whatever a month accumulates.

---

## The arrangement

**2-of-3.** Three keys, any two of which can spend.

The honest difficulty: this project has one person. Multi-signature is
usually described as protection against one participant going bad, and that
is not the threat here — the threat is a single point of failure in paper,
fire, theft, and death.

So the first stage is 2-of-3 with **all three keys held by the founder, in
three separate physical locations.** It does nothing against coercion and
nothing against a mistake he makes deliberately. It does everything against
the failures that actually kill small projects: one paper destroyed, one
paper stolen, one machine seized.

Adding a key held by someone else is stage two, and it waits until there is
somebody whose loss of the key would not be worse than the risk it removes.
Naming a person before that is theatre.

---

## Dated milestones

| By | What |
|---|---|
| **before 2026-09-15** | this document exists and has been read — done, this is it |
| **2026-09-15** | launch. The treasury address begins receiving **1,800 WAM a day** — 2.5 per block, 720 blocks |
| **within 30 days of launch** | the 2-of-3 keys are generated on the air-gapped machine, by the same ritual as the founder key, and each of the three is written on paper and placed in a different physical location |
| **within 30 days of launch** | the multi-signature address is derived, written down, and **tested with a small amount on testnet first** — a multi-sig nobody has spent from is a multi-sig nobody knows works |
| **first sweep, within 14 days** | the treasury balance is swept to the multi-sig address. The transaction id is published |
| **weekly thereafter** | sweep, and publish what was swept and what the balance is |
| **at block 400,000** | the treasury stops receiving. The single-key address is emptied a final time and never used again |

---

## What this does not solve, said plainly

It does not protect against the founder being coerced. Two of three keys in
one person's control is one person's control.

It does not protect against a mistake in the multi-sig itself — a wrong
derivation path, a lost descriptor, a redeem script nobody recorded. That is
why the milestone above says *tested with a small amount on testnet first*,
and why the descriptor is written down beside the keys rather than assumed
recoverable from them.

It does not make the treasury trustless. The 5% is enforced by consensus;
what it is *spent on* is enforced by nothing except publication. That gap is
named in the whitepaper and in the roadmap, and no amount of key management
closes it.

It does not remove the single-key window entirely. Between one sweep and the
next, the doorway address holds real coins with one key on it.

The cadence is a week, and the number is why. At 1,800 WAM a day, a month
leaves about **54,000 WAM** sitting on one key — 7% of everything the
treasury will ever collect, on one piece of paper. A week is 12,600, which
is still not small and is the point at which more frequent sweeps start
costing more in tired-hands mistakes than they save in exposure.

This was originally written as a month, from an arithmetic error of five
times. The number is stated here rather than the interval alone, so the next
person to read it can redo the judgement instead of inheriting it.

---

## What to publish, and when

The consensus layer proves the treasury is *collected*. Only disclosure
shows what happened to it afterwards, and a treasury nobody reports on is
indistinguishable from a treasury being quietly spent.

- every sweep: the transaction id, the amount, the resulting balance
- monthly: what was spent and on what, in one short note
- never: a key, a descriptor, or a photograph of any part of either

The first sweep is the one that sets the expectation. If it is published
plainly, the ones after it are routine.
