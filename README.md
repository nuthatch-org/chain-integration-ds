# chain-integration-ds

**A Horizon data service whose unit of service is supporting a chain, not answering a request.**

The Graph Foundation's position is that "revenue generated from chain integrations is largely
captured outside the protocol". A chain that wants to be supported pays an integrator, and none of
it touches the protocol: no cut, no share to indexers, no rail for either. This is that rail,
published as a reference implementation.

**We are not going to run it.** The Night's Watch builds these services; operating them is a
different business. Any integrator can register.

## A defect the unit tests could not see

`RecurringCollector.accept()` is callable **only by the data service an agreement names**. This
contract had no function that called it, so an RCA written for it could be accepted by nobody: not
the payer who signed it, not the integrator who benefits, not a third party. `collect()` could
therefore never succeed, and sixteen passing tests said nothing about it, because they ran against a
`MockRecurringCollector` whose `collect()` returned a number and modelled no rule at all.

Established against the **deployed** collector on Arbitrum Sepolia rather than argued
(`test/ForkCollect.t.sol`): the payer is refused, every third party is refused, and the named data
service succeeds. The capability existed the whole time; this contract simply could not reach it.

`acceptAgreement()` closes it, and is deliberately permissionless: the payer's signature is the
authorisation and the collector checks it, so requiring a particular caller would add a second party
who must act before a payer's own intention takes effect, and would buy nothing. The mock now
enforces the one rule that matters, so the omission could not recur silently.

What is still not proven: the fix has not been driven end to end on a fork, because that needs a
real Controller, a staked provision and a registration - a deployment rehearsal rather than a test
of this behaviour. Worth doing before mainnet, and said here rather than left to be assumed.

## The one design decision that matters

It settles through **`RecurringCollector`**, not `GraphTallyCollector`.

Every other community data service meters per request. Supporting a chain is not a request — it is
a commitment held over time, and a chain with no query volume still costs the integrator money.
The protocol already has the right instrument, live on Arbitrum One at
`0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee`, built for DIPS. Its Recurring Collection Agreement
carries `maxInitialTokens` (the integration fee), `maxOngoingTokensPerSecond` (the support
retainer), a term, a payer, a provider and a bounded collection cadence.

We did not design that shape. We noticed it already existed. Full reasoning in
[`docs/design.md`](docs/design.md).

## What it does, and does not, decide

The CAIP-2 chain id (GIP-0047) is denormalised out of the agreement metadata at acceptance and
emitted on every collection, so **per-chain revenue is a query over events rather than a
reconciliation against a registry somebody has to remember to update**.

The cut is a **governance parameter with a placeholder default that should be treated as unset**.
How much burns, how much is retained, and how much reaches indexers via DIPS is Council policy.
Hard-coding it would be making that decision in Solidity.

## Two upstream limitations this surfaces

1. **There is no integration-fee payment type.** `IGraphPayments.PaymentTypes` is
   `{ QueryFee, IndexingFee, IndexingRewards }`. This borrows `IndexingFee` because that is what
   the recurring path expects, and it is semantically wrong: revenue bucketed by payment type will
   file chain-integration income as indexing fees.
2. **There is no verification primitive.** No POI equivalent exists for "a chain integration was
   delivered", so `slash()` reverts rather than being stubbed to succeed. Same gap as every other
   community data service.

## Using it

[`docs/integrator-runbook.md`](docs/integrator-runbook.md) is the end-to-end flow for the two
parties: governance enables a chain and sets the cut, the integrator provisions and registers, the
chain and integrator sign a Recurring Collection Agreement with the CAIP-2 id in its metadata, and
the integrator collects against it.

`contracts/script/Deploy.s.sol` deploys implementation + proxy with an atomic initialise. Testnet
first; the canonical `RecurringCollector` addresses for both networks are in its header.

**Not deployed anywhere yet.** The contract is a reference implementation with no live instance.

## Build

```sh
cd contracts && forge test
```

16 tests. **Note the dependency pin.** `graphprotocol/contracts` must be at
`2629e6463f6474f076396a32f51c9799490ea503` (main) rather than the `@graphprotocol/horizon@1.1.0`
commit that `horizon-skills` documents: `IRecurringCollector` does not exist at that older pin.
That newer ref also replaces the `onlyAuthorizedForProvision` modifier with a
`_requireAuthorizedForProvision()` call and drops `deregister` from `IDataService`. Both are
gotchas worth carrying back to `horizon-skills`.

Apache-2.0.
