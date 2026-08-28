// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DataService} from "@graphprotocol/horizon/data-service/DataService.sol";
import {
    DataServicePausableUpgradeable
} from "@graphprotocol/horizon/data-service/extensions/DataServicePausableUpgradeable.sol";
import {IGraphPayments} from "@graphprotocol/horizon/interfaces/IGraphPayments.sol";
import {IRecurringCollector} from "@graphprotocol/interfaces/contracts/horizon/IRecurringCollector.sol";

import {IChainIntegrationDataService} from "./interfaces/IChainIntegrationDataService.sol";

/// @title ChainIntegrationDataService
/// @notice Meters chain-integration revenue through the protocol.
///
/// The unit of service is *supporting a chain*, not answering a request, so this settles through
/// `RecurringCollector` (an up-front integration fee plus an ongoing support rate over a term)
/// rather than `GraphTallyCollector` (per-query receipts aggregated into RAVs). See
/// `docs/design.md`; the short version is that the Recurring Collection Agreement already has
/// exactly the fields a chain-integration deal needs, so we did not invent a shape, we noticed one.
///
/// Deliberately thin. It does not implement escrow, vouchers or settlement — the shared Horizon
/// contracts do that, unchanged. It registers integrators, gates them on a governance allowlist of
/// chains, denormalises the CAIP-2 id so revenue is attributable without a second registry, and
/// routes `collect()`.
///
/// @dev Two upstream limitations are surfaced rather than papered over. `PaymentTypes` has no
///      integration-fee variant, so this borrows `IndexingFee`; and there is no verification
///      primitive for "a chain integration was delivered", so `slash()` is a no-op exactly as in
///      every other community data service. Both are written up in docs/design.md.
contract ChainIntegrationDataService is
    OwnableUpgradeable,
    UUPSUpgradeable,
    DataService,
    DataServicePausableUpgradeable,
    IChainIntegrationDataService
{
    /// @notice Floor on the GRT an integrator must provision. Governance may raise it per chain.
    uint256 public constant MIN_PROVISION = 10_000e18;

    /// @notice Floor on the dispute window an integrator's provision must be thawable over.
    uint64 public constant MIN_THAWING_PERIOD = 14 days;

    /// @notice Hard ceiling on burn + data-service cut. Governance may choose anything below it;
    ///         nothing may choose a combined cut the protocol would reject.
    uint32 public constant MAX_COMBINED_CUT_PPM = 100_000; // 10%

    /// @notice Placeholder cuts. **Treat as unset, not as a recommendation.** How much of a
    ///         chain-integration payment burns, is retained, or reaches indexers via DIPS is
    ///         Council policy. Hard-coding a number here would be making that decision in Solidity.
    uint32 public constant DEFAULT_BURN_CUT_PPM = 10_000; // 1%
    uint32 public constant DEFAULT_DATA_SERVICE_CUT_PPM = 10_000; // 1%

    /// @notice Current burn cut, PPM. Owner-settable within MAX_COMBINED_CUT_PPM.
    uint32 public burnCutPpm;
    /// @notice Current retained cut, PPM.
    uint32 public dataServiceCutPpm;

    /// @notice Registered integrators.
    mapping(address => bool) public registeredProviders;

    /// @notice Where each integrator's collected GRT is sent. Lets a hot operator key stay
    ///         separate from the wallet that holds the money.
    mapping(address => address) public paymentsDestination;

    /// @notice Chains governance will accept agreements for, keyed by CAIP-2 id.
    mapping(string => ChainConfig) internal _chains;

    /// @notice Integrations per integrator, active and historical.
    mapping(address => Integration[]) internal _integrations;

    /// @notice The recurring collector this service settles through.
    IRecurringCollector public immutable RECURRING_COLLECTOR;

    /// @notice Governance-adjustable dispute window, floored by MIN_THAWING_PERIOD.
    uint64 public minThawingPeriod;

    /// @dev Reserved for future upgrades.
    uint256[50] private __gap;

    constructor(address controller, address recurringCollector) DataService(controller) {
        RECURRING_COLLECTOR = IRecurringCollector(recurringCollector);
        _disableInitializers();
    }

    function initialize(address owner_, address pauseGuardian) external initializer {
        __Ownable_init(owner_);
        __DataService_init();
        __DataServicePausable_init();

        minThawingPeriod = MIN_THAWING_PERIOD;
        burnCutPpm = DEFAULT_BURN_CUT_PPM;
        dataServiceCutPpm = DEFAULT_DATA_SERVICE_CUT_PPM;
        _setProvisionTokensRange(MIN_PROVISION, type(uint256).max);
        _setThawingPeriodRange(MIN_THAWING_PERIOD, type(uint64).max);
        _setVerifierCutRange(0, uint32(1_000_000));
        _setPauseGuardian(pauseGuardian, true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ── Governance ───────────────────────────────────────────────────────────

    /// @notice Enable a chain and set the provision an integrator must hold to serve it.
    function enableChain(string calldata caip2, uint256 minProvisionTokens) external onlyOwner {
        if (bytes(caip2).length == 0) revert EmptyCaip2();
        _chains[caip2] = ChainConfig({caip2: caip2, enabled: true, minProvisionTokens: minProvisionTokens});
        emit ChainEnabled(caip2, minProvisionTokens);
    }

    /// @notice Stop accepting new agreements for a chain. Existing ones are unaffected: pulling
    ///         support out from under a paying chain is the collector's `cancel()`, not ours.
    function disableChain(string calldata caip2) external onlyOwner {
        _chains[caip2].enabled = false;
        emit ChainDisabled(caip2);
    }

    /// @notice Set the burn and retained cuts. See DEFAULT_* — these are policy, not constants.
    function setCuts(uint32 burnPpm, uint32 dataServicePpm) external onlyOwner {
        uint32 combined = burnPpm + dataServicePpm;
        if (combined > MAX_COMBINED_CUT_PPM) revert CutsTooLarge(combined, MAX_COMBINED_CUT_PPM);
        burnCutPpm = burnPpm;
        dataServiceCutPpm = dataServicePpm;
        emit CutsSet(burnPpm, dataServicePpm);
    }

    function setMinThawingPeriod(uint64 period) external onlyOwner {
        if (period < MIN_THAWING_PERIOD) revert ThawingPeriodTooShort(MIN_THAWING_PERIOD, period);
        minThawingPeriod = period;
    }

    function setPauseGuardian(address guardian, bool allowed) external onlyOwner {
        _setPauseGuardian(guardian, allowed);
    }

    function withdrawFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");
        _graphToken().transfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    // ── Integrator lifecycle ─────────────────────────────────────────────────

    /// @param data ABI-encoded (string metadataURI, address paymentsDestination).
    function register(address serviceProvider, bytes calldata data) external override whenNotPaused {
        _requireAuthorizedForProvision(serviceProvider);
        (string memory metadataURI, address dest) = abi.decode(data, (string, address));
        _checkProvisionTokens(serviceProvider);
        registeredProviders[serviceProvider] = true;
        paymentsDestination[serviceProvider] = dest == address(0) ? serviceProvider : dest;
        emit IntegratorRegistered(serviceProvider, metadataURI);
    }

    /// @dev Not part of `IDataService` — that interface has `register` but no `deregister` — so
    ///      this is our own, declared in `IChainIntegrationDataService`.
    function deregister(address serviceProvider, bytes calldata) external {
        _requireAuthorizedForProvision(serviceProvider);
        if (!registeredProviders[serviceProvider]) revert IntegratorNotRegistered(serviceProvider);
        if (activeIntegrationCount(serviceProvider) > 0) {
            revert ActiveIntegrationsExist(serviceProvider);
        }
        registeredProviders[serviceProvider] = false;
        emit IntegratorDeregistered(serviceProvider);
    }

    function setPaymentsDestination(address destination) external {
        if (!registeredProviders[msg.sender]) revert IntegratorNotRegistered(msg.sender);
        address dest = destination == address(0) ? msg.sender : destination;
        paymentsDestination[msg.sender] = dest;
        emit PaymentsDestinationSet(msg.sender, dest);
    }

    /// @notice Commit to supporting a chain under an existing recurring agreement.
    /// @param data ABI-encoded (string caip2, bytes16 agreementId).
    function startService(address serviceProvider, bytes calldata data) external override whenNotPaused {
        _requireAuthorizedForProvision(serviceProvider);
        (string memory caip2, bytes16 agreementId) = abi.decode(data, (string, bytes16));
        if (!registeredProviders[serviceProvider]) revert IntegratorNotRegistered(serviceProvider);

        ChainConfig storage cfg = _chains[caip2];
        if (!cfg.enabled) revert ChainNotSupported(caip2);

        uint256 provisioned = _getProvision(serviceProvider).tokens;
        uint256 required = cfg.minProvisionTokens == 0 ? MIN_PROVISION : cfg.minProvisionTokens;
        if (provisioned < required) revert InsufficientProvision(required, provisioned);

        // Reactivate a matching stopped entry rather than pushing a new one, so the array is
        // bounded by distinct chains rather than by start/stop churn and the active count stays
        // gas-bounded. (Dispatch learned this one the expensive way.)
        Integration[] storage regs = _integrations[serviceProvider];
        for (uint256 i = 0; i < regs.length; i++) {
            if (keccak256(bytes(regs[i].caip2)) == keccak256(bytes(caip2))) {
                regs[i].active = true;
                regs[i].agreementId = agreementId;
                emit IntegrationStarted(serviceProvider, caip2, agreementId);
                return;
            }
        }
        regs.push(Integration({caip2: caip2, agreementId: agreementId, active: true}));
        emit IntegrationStarted(serviceProvider, caip2, agreementId);
    }

    /// @param data ABI-encoded (string caip2).
    function stopService(address serviceProvider, bytes calldata data) external override {
        _requireAuthorizedForProvision(serviceProvider);
        string memory caip2 = abi.decode(data, (string));
        Integration[] storage regs = _integrations[serviceProvider];
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i].active && keccak256(bytes(regs[i].caip2)) == keccak256(bytes(caip2))) {
                regs[i].active = false;
                emit IntegrationStopped(serviceProvider, caip2, regs[i].agreementId);
                return;
            }
        }
        revert IntegrationNotFound(serviceProvider, caip2);
    }

    // ── Collection ───────────────────────────────────────────────────────────

    /// @notice Collect against a recurring agreement.
    /// @dev `paymentType` must be `IndexingFee`. It is the wrong word for this — the protocol has
    ///      no integration-fee variant — and it is the type the recurring path expects. Any
    ///      accounting that buckets protocol revenue by payment type will file chain-integration
    ///      income as indexing fees until a fourth variant exists. See docs/design.md.
    /// @param data ABI-encoded (bytes16 agreementId, uint256 tokensToCollect, string caip2).
    function collect(address serviceProvider, IGraphPayments.PaymentTypes paymentType, bytes calldata data)
        external
        override
        whenNotPaused
        returns (uint256 fees)
    {
        if (paymentType != IGraphPayments.PaymentTypes.IndexingFee) revert InvalidPaymentType();
        if (!registeredProviders[serviceProvider]) revert IntegratorNotRegistered(serviceProvider);

        (bytes16 agreementId, uint256 tokensToCollect, string memory caip2) =
            abi.decode(data, (bytes16, uint256, string));

        uint256 balanceBefore = _graphToken().balanceOf(address(this));
        fees = RECURRING_COLLECTOR.collect(
            paymentType,
            abi.encode(
                agreementId, tokensToCollect, burnCutPpm + dataServiceCutPpm, paymentsDestination[serviceProvider]
            )
        );

        uint256 received = _graphToken().balanceOf(address(this)) - balanceBefore;
        if (received > 0 && burnCutPpm > 0) {
            uint256 burned = (received * burnCutPpm) / (burnCutPpm + dataServiceCutPpm);
            _graphToken().burn(burned);
            emit FeesBurned(serviceProvider, burned);
        }

        emit IntegrationFeesCollected(serviceProvider, caip2, agreementId, fees);
    }

    /// @notice Not implemented. There is no verification primitive for "a chain integration was
    ///         delivered" — no POI equivalent — so this service has no on-chain dispute path. The
    ///         security is economic: a payer stops paying, and `cancel()` exists on the collector.
    function slash(address, bytes calldata) external pure override {
        revert("slashing not supported");
    }

    function acceptProvisionPendingParameters(address serviceProvider, bytes calldata) external override {
        _requireAuthorizedForProvision(serviceProvider);
        _acceptProvisionParameters(serviceProvider);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function isRegistered(address integrator) external view override returns (bool) {
        return registeredProviders[integrator];
    }

    function getIntegrations(address integrator) external view override returns (Integration[] memory) {
        return _integrations[integrator];
    }

    function activeIntegrationCount(address integrator) public view override returns (uint256 count) {
        Integration[] storage regs = _integrations[integrator];
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i].active) count++;
        }
    }

    function chainConfig(string calldata caip2) external view override returns (ChainConfig memory) {
        return _chains[caip2];
    }
}
