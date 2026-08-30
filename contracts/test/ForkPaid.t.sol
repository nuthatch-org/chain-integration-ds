// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {HorizonForkTest} from "./HorizonForkTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ChainIntegrationDataService} from "../src/ChainIntegrationDataService.sol";
import {IRecurringCollector} from "@graphprotocol/interfaces/contracts/horizon/IRecurringCollector.sol";
import {IGraphPayments} from "@graphprotocol/horizon/interfaces/IGraphPayments.sol";

interface IColl {
    function authorizeSigner(address signer, uint256 proofDeadline, bytes calldata proof) external;
    function hashRCA(IRecurringCollector.RecurringCollectionAgreement calldata rca) external view returns (bytes32);
}

/// @notice The rehearsal the unit tests cannot do: is this contract paid by the **deployed**
///         Horizon contracts?
///
/// `ForkCollect.t.sol` proved the defect - only the named data service may accept, and this contract
/// had no way to. This proves the fix by going all the way to a balance changing: deploy against the
/// real Controller and RecurringCollector, stake and provision, register, accept a payer-signed
/// agreement, fund escrow, let time pass, collect.
///
/// It exists because `forge test` against `MockRecurringCollector` was green while the contract
/// could not be paid at all. A mock that returns a number and models no rule proves the arithmetic
/// and nothing about the counterparty.
///
/// Run with:
///   ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --match-path test/ForkPaid.t.sol
contract ForkPaidTest is HorizonForkTest {
    string constant CAIP2 = "eip155:42161";
    uint256 constant STAKE = 100_000 ether;
    uint256 constant ESCROWED = 50_000 ether;

    ChainIntegrationDataService ds;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address integrator = makeAddr("integrator");
    address payer;
    uint256 payerKey;

    function setUp() public {
        forkOrSkip();
        (payer, payerKey) = makeAddrAndKey("payer");

        ChainIntegrationDataService impl = new ChainIntegrationDataService(CONTROLLER, RECURRING_COLLECTOR);
        ds = ChainIntegrationDataService(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ChainIntegrationDataService.initialize, (owner, guardian))
                )
            )
        );

        vm.prank(owner);
        ds.enableChain(CAIP2, 0);

        authorizeOwnSigner(RECURRING_COLLECTOR, payer, payerKey);
        provisionTo(integrator, address(ds), STAKE);

        vm.prank(integrator);
        ds.register(integrator, abi.encode("ipfs://integrator", integrator));
    }

    function _rca() internal view returns (IRecurringCollector.RecurringCollectionAgreement memory rca) {
        rca.deadline = uint64(block.timestamp + 1 days);
        rca.endsAt = uint64(block.timestamp + 365 days);
        rca.payer = payer;
        rca.dataService = address(ds);
        rca.serviceProvider = integrator;
        rca.maxInitialTokens = 0;
        rca.maxOngoingTokensPerSecond = 1 ether;
        rca.minSecondsPerCollection = 60;
        rca.maxSecondsPerCollection = 60 days;
        rca.nonce = 1;
        rca.metadata = bytes(CAIP2);
    }

    /// **The whole path, ending in somebody being paid.**
    function test_theContractCanActuallyBePaid() public {
        IRecurringCollector.RecurringCollectionAgreement memory rca = _rca();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, IColl(RECURRING_COLLECTOR).hashRCA(rca));

        // The function the contract shipped without. Before it, this line had no equivalent and
        // nothing below was reachable.
        bytes16 id = ds.acceptAgreement(rca, abi.encodePacked(r, s, v));
        assertTrue(id != bytes16(0), "no agreement id");

        vm.prank(integrator);
        ds.startService(integrator, abi.encode(CAIP2, id));

        fundEscrow(payer, RECURRING_COLLECTOR, integrator, ESCROWED);

        assertGt(
            providerTokensAvailable(integrator, address(ds)),
            0,
            "the provision is what makes a data service payable at all"
        );

        vm.warp(block.timestamp + 1 hours);

        uint256 before = grtBalance(integrator);
        vm.prank(integrator);
        uint256 fees =
            ds.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(id, uint256(100 ether), CAIP2));

        assertGt(fees, 0, "collect returned nothing");
        assertGt(grtBalance(integrator), before, "the integrator was not paid");
    }
}
