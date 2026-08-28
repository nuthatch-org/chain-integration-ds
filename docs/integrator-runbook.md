# Routing a chain's integration revenue through the protocol

> The reference flow, end to end, for the two parties involved. Nothing here needs The Night's
> Watch: we wrote the contract and will not be running it.

There are two roles and they are not the ones people expect.

- **The payer is the chain.** A chain foundation buying support for its network.
- **The service provider is the integrator.** Whoever does the integration work and keeps it
  working — today that is typically E&N, StreamingFast, Pinax or a team the chain hires.

The money currently flows directly between them and never touches the protocol. This is the same
deal, routed so that the protocol takes a cut and (once Council decides the split) indexers see a
share.

## 0. What governance does first

Nothing can be integrated until a chain is on the allowlist:

```sh
cast send $SERVICE "enableChain(string,uint256)" "eip155:42161" 10000000000000000000000 \
  --private-key $OWNER_KEY --rpc-url $RPC
```

The second argument is the GRT an integrator must provision to serve that chain. `0` falls back to
the contract's `MIN_PROVISION`. Governance also sets the cut, and **should**, because the shipped
default is a placeholder:

```sh
cast send $SERVICE "setCuts(uint32,uint32)" $BURN_PPM $RETAIN_PPM --private-key $OWNER_KEY
```

## 1. The integrator provisions and registers

```sh
# Provision GRT toward this data service in HorizonStaking.
cast send $HORIZON_STAKING "provision(address,address,uint256,uint32,uint64)" \
  $INTEGRATOR $SERVICE 10000000000000000000000 1000000 1209600 --private-key $INTEGRATOR_KEY

# Register. The second argument is (metadataURI, paymentsDestination).
# paymentsDestination = address(0) means "pay me at my own address"; set it to a cold wallet if
# the key registering is a hot operator key.
cast send $SERVICE "register(address,bytes)" $INTEGRATOR \
  $(cast abi-encode "f(string,address)" "ipfs://<integrator-profile>" $COLD_WALLET) \
  --private-key $INTEGRATOR_KEY
```

## 2. The chain and the integrator agree terms off-chain, then sign an RCA

This is the step that carries the commercial deal, and it is a **RecurringCollector** agreement,
not a per-query receipt. The fields map onto the deal directly:

| RCA field | The deal |
|---|---|
| `payer` | the chain's wallet |
| `serviceProvider` | the integrator |
| `dataService` | this contract |
| `maxInitialTokens` | the up-front integration fee |
| `maxOngoingTokensPerSecond` | the ongoing support retainer |
| `endsAt` | the term |
| `minSecondsPerCollection` / `maxSecondsPerCollection` | how often the integrator may invoice |
| `metadata` | the CAIP-2 chain id, e.g. `eip155:42161` |

The chain signs the RCA; the integrator calls `accept()` on the RecurringCollector. Neither of
those is this contract's business, which is the point: settlement is the shared Horizon
machinery, unchanged.

**Put the CAIP-2 id in `metadata`.** It is what makes the revenue attributable per chain without a
separate registry. An agreement with empty metadata still settles, and its revenue is
unattributable forever after.

## 3. The integrator declares the integration

```sh
cast send $SERVICE "startService(address,bytes)" $INTEGRATOR \
  $(cast abi-encode "f(string,bytes16)" "eip155:42161" $AGREEMENT_ID) \
  --private-key $INTEGRATOR_KEY
```

This is where the contract checks the chain is enabled and the provision clears that chain's floor.

## 4. Collecting

```sh
cast send $SERVICE "collect(address,uint8,bytes)" $INTEGRATOR 1 \
  $(cast abi-encode "f(bytes16,uint256,string)" $AGREEMENT_ID $TOKENS "eip155:42161") \
  --private-key $INTEGRATOR_KEY
```

The `1` is `IGraphPayments.PaymentTypes.IndexingFee`. **It is the wrong word**: the protocol has no
integration-fee type and this borrows the recurring one. Anything bucketing protocol revenue by
payment type will file this as an indexing fee until a fourth variant exists.

Every collection emits `IntegrationFeesCollected(integrator, caip2, agreementId, tokens)`. That
event is the revenue record: per-chain integration income becomes a query over logs rather than a
reconciliation against a spreadsheet.

## 5. Stopping

`stopService(integrator, abi.encode(caip2))` ends the declaration. Ending the *money* is
`cancel()` on the RecurringCollector, by whichever side is walking away. Governance disabling a
chain stops new agreements and deliberately does not touch existing ones — pulling support out
from under a chain that is paying would be a strange thing for an allowlist to do.

## What can go wrong, and what it looks like

| Symptom | Cause |
|---|---|
| `ChainNotSupported` | governance has not `enableChain`d it, or has disabled it |
| `InsufficientProvision` | provision is below that chain's floor, not the global one |
| `InvalidPaymentType` | you passed `QueryFee` (0) — it must be `IndexingFee` (1) |
| `IntegratorNotRegistered` | `register()` was never called, or `deregister()` was |
| `ActiveIntegrationsExist` | `stopService` every chain before deregistering |
| revenue shows against no chain | the RCA's `metadata` was empty when the agreement was accepted |

## What this flow cannot do

It cannot make a chain route its revenue through the protocol. That is a commercial conversation
and the Foundation has said it is taking ownership of it. This exists so that when that
conversation succeeds, the rails are already written and audited rather than being specified from
scratch under time pressure.
