// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

/// @title IChainIntegrationDataService
/// @notice A Horizon data service whose unit of service is *supporting a chain*, not answering a
///         request. Settles through `RecurringCollector` rather than `GraphTallyCollector`,
///         because a chain integration is a commitment held over time, not a query.
/// @dev See docs/design.md for why, and for the two upstream limitations this surfaces.
interface IChainIntegrationDataService {
    /// @notice A chain this service will accept integration agreements for.
    /// @param caip2 CAIP-2 chain id (GIP-0047), e.g. "eip155:42161".
    /// @param enabled Whether new agreements may be accepted for it.
    /// @param minProvisionTokens Minimum GRT an integrator must provision to serve this chain.
    struct ChainConfig {
        string caip2;
        bool enabled;
        uint256 minProvisionTokens;
    }

    /// @notice An integrator's commitment to support one chain.
    /// @param caip2 The chain, denormalised from the agreement's `metadata` at acceptance so that
    ///        consumers never have to parse RCA metadata themselves.
    /// @param agreementId The RecurringCollector agreement backing it.
    /// @param active False once stopped; kept for history.
    struct Integration {
        string caip2;
        bytes16 agreementId;
        bool active;
    }

    // ── Events ───────────────────────────────────────────────────────────────

    event ChainEnabled(string caip2, uint256 minProvisionTokens);
    event ChainDisabled(string caip2);
    event IntegratorRegistered(address indexed integrator, string metadataURI);
    event IntegratorDeregistered(address indexed integrator);
    event IntegrationStarted(address indexed integrator, string caip2, bytes16 indexed agreementId);
    event IntegrationStopped(address indexed integrator, string caip2, bytes16 indexed agreementId);
    event PaymentsDestinationSet(address indexed integrator, address destination);

    /// @param caip2 The chain the payment is attributed to. Indexing this event is the whole
    ///        point: per-chain integration revenue becomes a query, not a reconciliation.
    event IntegrationFeesCollected(
        address indexed integrator, string caip2, bytes16 indexed agreementId, uint256 tokens
    );
    event FeesBurned(address indexed integrator, uint256 tokens);
    event FeesWithdrawn(address indexed to, uint256 tokens);

    /// @param burnCutPpm Share of collected fees burned, in PPM.
    /// @param dataServiceCutPpm Share retained by this contract, in PPM.
    event CutsSet(uint32 burnCutPpm, uint32 dataServiceCutPpm);

    // ── Errors ───────────────────────────────────────────────────────────────

    error ChainNotSupported(string caip2);
    error IntegratorNotRegistered(address integrator);
    error ActiveIntegrationsExist(address integrator);
    error IntegrationNotFound(address integrator, string caip2);
    error InvalidPaymentType();
    error InvalidServiceProvider(address expected, address actual);
    error InsufficientProvision(uint256 required, uint256 actual);
    error ThawingPeriodTooShort(uint64 required, uint64 provided);
    /// @dev Guards governance against setting a combined cut the protocol would reject.
    error CutsTooLarge(uint32 combinedPpm, uint32 maxPpm);
    error EmptyCaip2();

    // ── Views ────────────────────────────────────────────────────────────────

    /// @dev `IDataService` has `register` but no `deregister`, so it is declared here.
    function deregister(address serviceProvider, bytes calldata data) external;

    function isRegistered(address integrator) external view returns (bool);
    function getIntegrations(address integrator) external view returns (Integration[] memory);
    function activeIntegrationCount(address integrator) external view returns (uint256);
    function chainConfig(string calldata caip2) external view returns (ChainConfig memory);
}
