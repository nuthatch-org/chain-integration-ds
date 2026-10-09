// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ChainIntegrationDataService} from "../src/ChainIntegrationDataService.sol";
import {IRecurringCollector} from "@graphprotocol/interfaces/contracts/horizon/IRecurringCollector.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// The slice of the deployed `RecurringCollector` this test needs.
interface IRC {
    struct RecurringCollectionAgreement {
        uint64 deadline;
        uint64 endsAt;
        address payer;
        address dataService;
        address serviceProvider;
        uint256 maxInitialTokens;
        uint256 maxOngoingTokensPerSecond;
        uint32 minSecondsPerCollection;
        uint32 maxSecondsPerCollection;
        uint16 conditions;
        uint256 nonce;
        bytes metadata;
    }

    error RecurringCollectorUnauthorizedCaller(address unauthorizedCaller, address dataService);

    function accept(RecurringCollectionAgreement calldata rca, bytes calldata signature)
        external
        returns (bytes16 agreementId);
    function hashRCA(RecurringCollectionAgreement calldata rca) external view returns (bytes32);
    function authorizeSigner(address signer, uint256 proofDeadline, bytes calldata proof) external;
}

/// @notice Can `ChainIntegrationDataService` actually be paid by the **deployed**
///         `RecurringCollector`? The 16 unit tests answer a different question.
///
/// Those tests run against a `MockRecurringCollector` whose `collect()` returns a number and models
/// nothing else: not agreement state, not who may call, not the accept step. They establish that
/// the contract's own arithmetic - cuts, registration, provisioning - is right, and they are silent
/// on whether the real counterparty would ever hand it money. That silence is what this file is for.
///
/// Run with:
///   ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --match-path test/ForkCollect.t.sol
contract ForkCollectTest is Test {
    IRC constant COLLECTOR = IRC(0x0B18beFc60455121Ad66Ae6E4A647955FCde3900);

    uint256 payerKey;
    address payer;
    address dataService = makeAddr("chainIntegrationDataService");
    address serviceProvider = makeAddr("integrator");
    address outsider = makeAddr("outsider");

    function setUp() public {
        try vm.envString("ARBITRUM_SEPOLIA_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
        }
        (payer, payerKey) = makeAddrAndKey("payer");
        _authorizeSelf();
    }

    /// A payer must authorise their own key before any RCA they sign will verify: `_isAuthorized`
    /// requires `authorizations[signer].authorizer == payer` and does not special-case signer ==
    /// payer. Established in `nuthatch-org/weaver`, and repeated here because without it every
    /// test below fails for the wrong reason.
    function _authorizeSelf() internal {
        uint256 proofDeadline = block.timestamp + 1 hours;
        bytes32 messageHash = keccak256(
            abi.encodePacked(block.chainid, address(COLLECTOR), "authorizeSignerProof", proofDeadline, payer)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, MessageHashUtils.toEthSignedMessageHash(messageHash));
        vm.prank(payer);
        COLLECTOR.authorizeSigner(payer, proofDeadline, abi.encodePacked(r, s, v));
    }

    function _rca() internal view returns (IRC.RecurringCollectionAgreement memory rca) {
        rca = IRC.RecurringCollectionAgreement({
            deadline: uint64(block.timestamp + 1 days),
            endsAt: uint64(block.timestamp + 365 days),
            payer: payer,
            // The agreement names the data service. Everything below follows from this one field.
            dataService: dataService,
            serviceProvider: serviceProvider,
            maxInitialTokens: 1000 ether,
            maxOngoingTokensPerSecond: 1,
            minSecondsPerCollection: 60,
            maxSecondsPerCollection: 60 days,
            conditions: 0,
            nonce: 1,
            metadata: bytes("caip2:eip155:1")
        });
    }

    function _sign(IRC.RecurringCollectionAgreement memory rca) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, COLLECTOR.hashRCA(rca));
        return abi.encodePacked(r, s, v);
    }

    /// **The finding.** Only the named data service may accept. The payer who wrote and signed the
    /// agreement cannot accept their own.
    function test_thePayerCannotAcceptTheirOwnAgreement() public {
        IRC.RecurringCollectionAgreement memory rca = _rca();
        bytes memory sig = _sign(rca);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IRC.RecurringCollectorUnauthorizedCaller.selector, payer, dataService));
        COLLECTOR.accept(rca, sig);
    }

    /// Nor can anybody else, however valid the signature.
    function test_nobodyElseCanAcceptEither() public {
        IRC.RecurringCollectionAgreement memory rca = _rca();
        bytes memory sig = _sign(rca);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IRC.RecurringCollectorUnauthorizedCaller.selector, outsider, dataService)
        );
        COLLECTOR.accept(rca, sig);

        vm.prank(serviceProvider);
        vm.expectRevert(
            abi.encodeWithSelector(IRC.RecurringCollectorUnauthorizedCaller.selector, serviceProvider, dataService)
        );
        COLLECTOR.accept(rca, sig);
    }

    /// And the data service itself **can**, which is what makes the omission a defect rather than a
    /// protocol limitation. The capability exists; `ChainIntegrationDataService` simply has no
    /// function that reaches it.
    ///
    /// This test is the one that turns "we did not implement accept" into "the only party who could
    /// have, did not". `vm.prank(dataService)` is standing in for a function the contract does not
    /// have.
    function test_onlyTheNamedDataServiceCanAccept() public {
        IRC.RecurringCollectionAgreement memory rca = _rca();
        bytes memory sig = _sign(rca);

        vm.prank(dataService);
        bytes16 id = COLLECTOR.accept(rca, sig);
        assertTrue(id != bytes16(0), "the named data service must be able to accept");
    }

    /// Re-stated as the thing an operator would care about: an agreement written for this data
    /// service is unacceptable by every party that has a reason to try, unless the data service
    /// itself calls `accept`. `ChainIntegrationDataService` exposes `register`, `startService`,
    /// `stopService` and `collect`, and none of them do.
    ///
    /// `startService` takes an `agreementId` as an argument, which reads as though acceptance
    /// happened somewhere else. There is nowhere else.
    function test_theAgreementIsUnreachableWithoutAnAcceptPathOnTheDataService() public {
        IRC.RecurringCollectionAgreement memory rca = _rca();
        bytes memory sig = _sign(rca);

        address[3] memory everyoneWithAReason = [payer, serviceProvider, outsider];
        for (uint256 i = 0; i < everyoneWithAReason.length; i++) {
            vm.prank(everyoneWithAReason[i]);
            (bool ok,) = address(COLLECTOR).call(abi.encodeCall(IRC.accept, (rca, sig)));
            assertFalse(ok, "somebody other than the data service accepted, which would change the finding");
        }
    }

    /// What this file does **not** prove, said plainly.
    ///
    /// It establishes that only the named data service may accept, which is the defect. It does not
    /// exercise the fix end to end on a fork, because doing so needs a real Controller, a staked
    /// provision in HorizonStaking and a registration - a deployment rehearsal rather than a test
    /// of this behaviour. The fix is covered by unit tests against the mock, and the two together
    /// are the argument: the fork says the named data service is the only party who can accept, the
    /// unit tests say this contract now asks it to.
    ///
    /// Wiring the full deployment on a fork is worth doing before mainnet and is not this.
}
