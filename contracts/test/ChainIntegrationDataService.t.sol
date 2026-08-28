// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainIntegrationDataService} from "../src/ChainIntegrationDataService.sol";
import {IChainIntegrationDataService} from "../src/interfaces/IChainIntegrationDataService.sol";
import {IHorizonStakingTypes} from "@graphprotocol/interfaces/contracts/horizon/internal/IHorizonStakingTypes.sol";
import {IGraphPayments} from "@graphprotocol/horizon/interfaces/IGraphPayments.sol";

contract MockGraphToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function burn(uint256 a) external {
        balanceOf[msg.sender] -= a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Stands in for the live RecurringCollector at 0xff0dc731…, paying into this contract so the
///      burn arithmetic has real balance to work on.
contract MockRecurringCollector {
    MockGraphToken public immutable TOKEN;
    uint256 public feeToReturn;
    address public payTo;
    bytes public lastData;

    constructor(MockGraphToken t) {
        TOKEN = t;
    }

    function setPayout(uint256 f, address to) external {
        feeToReturn = f;
        payTo = to;
    }

    function collect(IGraphPayments.PaymentTypes, bytes memory data) external returns (uint256) {
        lastData = data;
        TOKEN.mint(payTo, feeToReturn);
        return feeToReturn;
    }
}

contract MockStaking {
    mapping(address => IHorizonStakingTypes.Provision) public provisions;
    mapping(address => bool) public authorized;

    function setProvision(address sp, uint256 tokens, uint64 thawing) external {
        provisions[sp] = IHorizonStakingTypes.Provision({
            tokens: tokens,
            tokensThawing: 0,
            sharesThawing: 0,
            maxVerifierCut: 1_000_000,
            thawingPeriod: thawing,
            createdAt: uint64(block.timestamp),
            maxVerifierCutPending: 0,
            thawingPeriodPending: 0,
            lastParametersStagedAt: 0,
            thawingNonce: 0
        });
    }

    function getProvision(address sp, address) external view returns (IHorizonStakingTypes.Provision memory) {
        return provisions[sp];
    }

    function isAuthorized(address sp, address, address operator) external pure returns (bool) {
        return sp == operator;
    }
    function slash(address, uint256, uint256, address) external {}
    function acceptProvisionParameters(address) external {}
}

contract MockController {
    mapping(bytes32 => address) private _c;

    constructor(address staking, address token) {
        address d = address(1);
        _c[keccak256("GraphToken")] = token;
        _c[keccak256("Staking")] = staking;
        _c[keccak256("GraphPayments")] = d;
        _c[keccak256("PaymentsEscrow")] = d;
        _c[keccak256("EpochManager")] = d;
        _c[keccak256("RewardsManager")] = d;
        _c[keccak256("GraphTokenGateway")] = d;
        _c[keccak256("GraphProxyAdmin")] = d;
        _c[keccak256("Curation")] = d;
    }

    function getContractProxy(bytes32 id) external view returns (address) {
        return _c[id];
    }
}

contract ChainIntegrationDataServiceTest is Test {
    ChainIntegrationDataService svc;
    MockStaking staking;
    MockGraphToken token;
    MockRecurringCollector collector;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address integrator = makeAddr("integrator");
    address dest = makeAddr("dest");

    string constant ARB = "eip155:42161";
    string constant SOL = "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp";
    bytes16 constant AGREEMENT = bytes16(uint128(0xabc));
    uint256 constant PROVISION = 20_000e18;

    function setUp() public {
        staking = new MockStaking();
        token = new MockGraphToken();
        collector = new MockRecurringCollector(token);
        MockController controller = new MockController(address(staking), address(token));

        ChainIntegrationDataService impl = new ChainIntegrationDataService(address(controller), address(collector));
        svc = ChainIntegrationDataService(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ChainIntegrationDataService.initialize, (owner, guardian))
                )
            )
        );

        staking.setProvision(integrator, PROVISION, 14 days);
        vm.prank(owner);
        svc.enableChain(ARB, 0);
    }

    function _register() internal {
        vm.prank(integrator);
        svc.register(integrator, abi.encode("ipfs://integrator", dest));
    }

    function _start(string memory caip2) internal {
        vm.prank(integrator);
        svc.startService(integrator, abi.encode(caip2, AGREEMENT));
    }

    // ── The design decision, asserted ────────────────────────────────────────

    /// The whole point: this settles through the recurring collector, not a per-query one.
    function test_settlesThroughTheRecurringCollector() public {
        _register();
        _start(ARB);
        collector.setPayout(100e18, dest);
        vm.prank(integrator);
        uint256 fees = svc.collect(
            integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(AGREEMENT, uint256(100e18), ARB)
        );
        assertEq(fees, 100e18);
        assertEq(token.balanceOf(dest), 100e18, "the collector must be the one that paid");
    }

    /// The protocol has no integration-fee payment type, so IndexingFee is borrowed. Anything
    /// else must be refused rather than silently mis-settled.
    function test_onlyTheBorrowedIndexingFeeTypeIsAccepted() public {
        _register();
        _start(ARB);
        vm.startPrank(integrator);
        vm.expectRevert(IChainIntegrationDataService.InvalidPaymentType.selector);
        svc.collect(integrator, IGraphPayments.PaymentTypes.QueryFee, abi.encode(AGREEMENT, uint256(1), ARB));
        vm.expectRevert(IChainIntegrationDataService.InvalidPaymentType.selector);
        svc.collect(integrator, IGraphPayments.PaymentTypes.IndexingRewards, abi.encode(AGREEMENT, uint256(1), ARB));
        vm.stopPrank();
    }

    /// Revenue must be attributable per chain from the event alone, with no second registry.
    function test_collectionEmitsTheCaip2SoRevenueIsAQueryNotAReconciliation() public {
        _register();
        _start(ARB);
        collector.setPayout(42e18, dest);
        vm.expectEmit(true, false, true, true);
        emit IChainIntegrationDataService.IntegrationFeesCollected(integrator, ARB, AGREEMENT, 42e18);
        vm.prank(integrator);
        svc.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(AGREEMENT, uint256(42e18), ARB));
    }

    // ── Governance holds the cut, not the source ─────────────────────────────

    function test_cutsAreGovernanceParametersNotConstants() public {
        assertEq(svc.burnCutPpm(), svc.DEFAULT_BURN_CUT_PPM());
        vm.prank(owner);
        svc.setCuts(50_000, 20_000);
        assertEq(svc.burnCutPpm(), 50_000);
        assertEq(svc.dataServiceCutPpm(), 20_000);
    }

    function test_cutsCannotExceedTheHardCeiling() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IChainIntegrationDataService.CutsTooLarge.selector, uint32(100_001), uint32(100_000))
        );
        svc.setCuts(100_000, 1);
    }

    function test_onlyOwnerMovesTheCut() public {
        vm.prank(integrator);
        vm.expectRevert();
        svc.setCuts(0, 0);
    }

    function test_burnIsProportionalToTheConfiguredCut() public {
        _register();
        _start(ARB);
        vm.prank(owner);
        svc.setCuts(30_000, 10_000); // 3:1 burn:retain
        // The collector pays the service 40 of a 1000 collect; 30 of that should burn.
        collector.setPayout(1000e18, address(svc));
        vm.prank(integrator);
        svc.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(AGREEMENT, uint256(1000e18), ARB));
        assertEq(token.balanceOf(address(svc)), 250e18, "1000 received, 3/4 burned");
    }

    // ── Chain allowlist ──────────────────────────────────────────────────────

    function test_cannotIntegrateAChainGovernanceHasNotEnabled() public {
        _register();
        vm.prank(integrator);
        vm.expectRevert(abi.encodeWithSelector(IChainIntegrationDataService.ChainNotSupported.selector, SOL));
        svc.startService(integrator, abi.encode(SOL, AGREEMENT));
    }

    /// Disabling stops NEW agreements. Pulling support from under a paying chain is the
    /// collector's cancel(), not ours.
    function test_disablingAChainDoesNotStopExistingIntegrations() public {
        _register();
        _start(ARB);
        vm.prank(owner);
        svc.disableChain(ARB);
        assertEq(svc.activeIntegrationCount(integrator), 1);
        collector.setPayout(1e18, dest);
        vm.prank(integrator);
        svc.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(AGREEMENT, uint256(1e18), ARB));
    }

    function test_perChainProvisionFloorIsEnforced() public {
        vm.prank(owner);
        svc.enableChain(SOL, PROVISION + 1);
        _register();
        vm.prank(integrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainIntegrationDataService.InsufficientProvision.selector, PROVISION + 1, PROVISION
            )
        );
        svc.startService(integrator, abi.encode(SOL, AGREEMENT));
    }

    function test_emptyCaip2IsRejectedRatherThanStoredAsABlankChain() public {
        vm.prank(owner);
        vm.expectRevert(IChainIntegrationDataService.EmptyCaip2.selector);
        svc.enableChain("", 0);
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /// Restarting must reactivate rather than push, or the array grows without bound across
    /// start/stop churn and activeIntegrationCount() stops being gas-bounded.
    function test_restartingAnIntegrationReactivatesRatherThanAppending() public {
        _register();
        _start(ARB);
        vm.prank(integrator);
        svc.stopService(integrator, abi.encode(ARB));
        assertEq(svc.activeIntegrationCount(integrator), 0);
        _start(ARB);
        assertEq(svc.getIntegrations(integrator).length, 1, "one entry, reactivated");
        assertEq(svc.activeIntegrationCount(integrator), 1);
    }

    function test_cannotDeregisterWithLiveIntegrations() public {
        _register();
        _start(ARB);
        vm.prank(integrator);
        vm.expectRevert(
            abi.encodeWithSelector(IChainIntegrationDataService.ActiveIntegrationsExist.selector, integrator)
        );
        svc.deregister(integrator, "");
    }

    function test_unregisteredIntegratorCannotCollect() public {
        vm.prank(integrator);
        vm.expectRevert(
            abi.encodeWithSelector(IChainIntegrationDataService.IntegratorNotRegistered.selector, integrator)
        );
        svc.collect(integrator, IGraphPayments.PaymentTypes.IndexingFee, abi.encode(AGREEMENT, uint256(1), ARB));
    }

    function test_paymentsDestinationDefaultsToTheIntegratorAndIsChangeable() public {
        vm.prank(integrator);
        svc.register(integrator, abi.encode("ipfs://x", address(0)));
        assertEq(svc.paymentsDestination(integrator), integrator);
        vm.prank(integrator);
        svc.setPaymentsDestination(dest);
        assertEq(svc.paymentsDestination(integrator), dest);
    }

    // ── The gap we are not pretending to close ───────────────────────────────

    /// There is no verification primitive for "a chain integration was delivered", so slashing is
    /// deliberately absent rather than quietly stubbed to succeed.
    function test_slashingIsRefusedNotSilentlyAccepted() public {
        vm.expectRevert("slashing not supported");
        svc.slash(integrator, "");
    }
}
