# Chain integrations as a data service

> Design note, 2026-08-28. A reference implementation, not a proposal to run one.
> Every contract address and interface detail below was read from Arbitrum One or from
> `@graphprotocol/interfaces@0.7.1-dips.0` on that date.

## The problem, in the Foundation's own words

> "revenue generated from chain integrations is largely captured outside the protocol… the
> Foundation will take direct ownership of the Chain Integration Process, thereby aligning revenue
> capture directly with the protocol."

A chain that wants to be supported by The Graph — indexed, served, listed in the Chain Integration
Process (GIP-0057) — pays somebody to make that happen and keep it working. Today that somebody is
an integrator, and the money never touches the protocol. No indexer sees a share of it, and there
is no protocol cut, because there is no rail for one.

This note describes that rail.

## The one design decision that matters

**Settle through `RecurringCollector`, not `GraphTallyCollector`.**

Every existing community data service (Dispatch, compass, Seahorn, SDSCE, Camp) meters
*per request*: a TAP receipt per query, aggregated into RAVs, redeemed through
`GraphTallyCollector`. That instrument is wrong here, and not by a little.

Supporting a chain is not a request. It is a commitment held over time: an up-front integration
effort, then ongoing maintenance for as long as the chain wants support. Nobody sensibly bills that
per query, and a chain with no query volume still costs the integrator money.

The protocol already has the right instrument, and it went live recently enough that it is easy to
miss. `RecurringCollector` is deployed on **Arbitrum One at
`0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee`** (proxy; implementation
`0x69315eb3e779dad209fbd0c70fa838c96fae488e`), built for DIPS. Its Recurring Collection Agreement
is this:

```solidity
struct RecurringCollectionAgreement {
    uint64  deadline;
    uint64  endsAt;
    address payer;
    address dataService;
    address serviceProvider;
    uint256 maxInitialTokens;            // the integration fee
    uint256 maxOngoingTokensPerSecond;   // the support subscription
    uint32  minSecondsPerCollection;
    uint32  maxSecondsPerCollection;
    uint16  conditions;
    uint256 nonce;
    bytes   metadata;
}
```

Read that as a chain-integration deal and it fits without bending: an up-front fee, an ongoing
rate, a term, a payer, a provider, and a bounded collection cadence so neither side can be
surprised. `maxInitialTokens` **is** the integration fee. `maxOngoingTokensPerSecond` **is** the
support retainer. We did not design this shape; we noticed it already existed.

The consequence is that this data service is thin. It does not invent an escrow, a voucher format
or a settlement path. It registers providers, validates that an agreement belongs to a chain the
governance allowlist accepts, and routes `collect()` at the recurring collector, which is the same
posture every other Horizon data service takes toward `GraphTallyCollector`.

## Roles

| RCA field | Who |
|---|---|
| `payer` | the chain foundation, or whoever is buying support for that chain |
| `serviceProvider` | the integrator who does the work and keeps it working |
| `dataService` | `ChainIntegrationDataService` |
| `metadata` | the CAIP-2 chain id (see below) |

## Attribution: CAIP-2 in `metadata`

GIP-0047 already gives The Graph CAIP-2 chain aliases (`eip155:42161`, `solana:5eykt4Us…`). The RCA
carries arbitrary `metadata` bytes and nothing else in the protocol wants them here.

Putting the CAIP-2 id there means **every collection is attributable to a chain without a second
registry to keep in sync**. A revenue dashboard is then a query over collection events, not a
join against a list somebody has to remember to update. Registries that must be maintained
alongside the thing they describe are how you end up with a catalogue claiming a service is live
39 days after it stopped answering.

The contract stores the CAIP-2 id per agreement at acceptance and emits it, so an indexer of these
events never has to parse `metadata` itself.

## What this contract deliberately does not decide

**The cut is a parameter, not a constant.** How much of a chain-integration payment the protocol
keeps, how much burns, and how much reaches indexers via DIPS is Council policy and nobody else's.
The contract exposes `burnCutPpm` and `dataServiceCutPpm` as owner-settable within a hard ceiling,
and **ships with a placeholder default that should be treated as unset**, not as a recommendation.

Any implementation that hard-codes a number here is quietly making a governance decision in
Solidity, and would have to be redeployed the moment governance disagreed.

## Two limitations found while building this

Both are upstream problems this reference implementation surfaces rather than solves.

**1. There is no integration-fee payment type.** `IGraphPayments.PaymentTypes` is
`{ QueryFee, IndexingFee, IndexingRewards }`. A chain-integration payment is none of them. This
contract borrows `IndexingFee`, because that is the type the recurring path expects, and it is
semantically wrong: any accounting that buckets protocol revenue by payment type will silently file
chain-integration income as indexing fees. A fourth variant, or a subtype carried in metadata,
would fix it. Flagged rather than worked around.

**2. There is no verification primitive, again.** What does it mean for a chain integration to be
"delivered"? There is no POI equivalent, so `slash()` is a no-op here exactly as it is in Dispatch,
compass, Seahorn and SDSCE. The security is economic and reputational: a payer stops paying, and
`cancel()` exists on the collector. This is the same protocol-research gap that bounds every
community data service, and it is not made better or worse by this one.

## What is out of scope, permanently

This is a reference implementation published so that whoever ends up owning the Chain Integration
Process can adopt rails rather than rebuild them. It is not a business we intend to run.

- **Setting the cut.** Council.
- **Compelling chains to route revenue through the protocol.** Nobody can, least of all us.
- **Operating a provider.** Any integrator can register; we will not be one.

The Foundation controls the GIP-0089 Innovation Allocation (24.146 GRT per block from
2026-08-31) explicitly for building. Handing them working rails is a better use of this than
racing them to a market we have no intention of serving.
