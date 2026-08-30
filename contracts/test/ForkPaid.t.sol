// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ChainIntegrationDataService} from "../src/ChainIntegrationDataService.sol";
import {IRecurringCollector} from "@graphprotocol/interfaces/contracts/horizon/IRecurringCollector.sol";
import {IGraphPayments} from "@graphprotocol/horizon/interfaces/IGraphPayments.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStaking {
    function stakeTo(address serviceProvider, uint256 tokens) external;
    function provision(address sp, address verifier, uint256 tokens, uint32 maxVerifierCut, uint64 thawing) external;
    function getProviderTokensAvailable(address sp, address verifier) external view returns (uint256);
}

interface IEscrow {
    function deposit(address collector, address receiver, uint256 tokens) external;
}

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
contract ForkPaidTest is Test {
    // Arbitrum Sepolia, resolved from the Controller rather than copied from a table: two addresses
    // in circulation were implementations, and calling one returns zero from uninitialised storage
    // rather than reverting.
    address constant CONTROLLER = 0x9DB3ee191681f092607035d9BDA6e59FbEaCa695;
    address constant RECURRING_COLLECTOR = 0x0B18beFc60455121Ad66Ae6E4A647955FCde3900;
    IERC20 constant GRT = IERC20(0xf8c05dCF59E8B28BFD5eed176C562bEbcfc7Ac04);
    IStaking constant STAKING = IStaking(0x865365C425f3A593Ffe698D9c4E6707D14d51e08);
    IEscrow constant ESCROW = IEscrow(0x4b5D3Da463F7E076bb7CDF5030960bf123245681);

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
        try vm.envString("ARBITRUM_SEPOLIA_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
            return;
        }
        (payer, payerKey) = makeAddrAndKey("payer");

        // A proxy is a few kilobytes; an implementation is tens.
        assertLt(address(STAKING).code.length, 10_000, "staking looks like an implementation");
        assertLt(address(ESCROW).code.length, 10_000, "escrow looks like an implementation");

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

        _authorizePayerSigner();
        _provisionAndRegister();
    }

    /// A payer must authorise their own key first; the collector does not special-case
    /// signer == payer, and the revert blames the signature.
    function _authorizePayerSigner() internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h =
            keccak256(abi.encodePacked(block.chainid, RECURRING_COLLECTOR, "authorizeSignerProof", deadline, payer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, MessageHashUtils.toEthSignedMessageHash(h));
        vm.prank(payer);
        IColl(RECURRING_COLLECTOR).authorizeSigner(payer, deadline, abi.encodePacked(r, s, v));
    }

    function _provisionAndRegister() internal {
        deal(address(GRT), integrator, STAKE);
        vm.startPrank(integrator);
        GRT.approve(address(STAKING), STAKE);
        STAKING.stakeTo(integrator, STAKE);
        // 14 days, not 30: the thawing period is capped at ~2,418,000 seconds and the refusal is a
        // custom error carrying two raw numbers and no name.
        STAKING.provision(integrator, address(ds), STAKE, 500_000, 14 days);
        ds.register(integrator, abi.encode("ipfs://integrator", integrator));
        vm.stopPrank();
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

        deal(address(GRT), payer, ESCROWED);
        vm.startPrank(payer);
        GRT.approve(address(ESCROW), ESCROWED);
        ESCROW.deposit(RECURRING_COLLECTOR, integrator, ESCROWED);
        vm.stopPrank();

        assertGt(
            STAKING.getProviderTokensAvailable(integrator, address(ds)),
            0,
            "the provision is what makes a data service payable at all"
        );

        vm.warp(block.timestamp + 1 hours);

        uint256 before = GRT.balanceOf(integrator);
        vm.prank(integrator);
        uint256 fees =
            ds.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(id, uint256(100 ether), CAIP2));

        assertGt(fees, 0, "collect returned nothing");
        assertGt(GRT.balanceOf(integrator), before, "the integrator was not paid");
    }
}
