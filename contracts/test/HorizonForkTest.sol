// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

/// @title A base for rehearsing a data service against the **deployed** Horizon contracts.
///
/// `forge test` against mocks establishes your arithmetic. It establishes nothing about whether the
/// protocol will pay you, and the gap between those two is where data services die quietly. Two
/// separate fatal defects were found in one contract this way on 2026-08-30, both invisible behind a
/// full green suite:
///
/// 1. It never called `accept()`, which only the data service an agreement names may call. No
///    agreement written for it could be accepted by anybody, so `collect()` could never succeed.
/// 2. Its `collect()` encoded four fields against a six-field `CollectParams`. Every real
///    collection would have reverted.
///
/// Neither showed up because the mock stored the calldata without decoding it and minted. **A mock
/// that accepts any input is not a test of the input**, and it is worse than no mock, because it
/// manufactures confidence.
///
/// Inherit this, then write one test that ends with a balance going **up**.
///
/// ```solidity
/// contract PaidTest is HorizonForkTest {
///     function setUp() public {
///         forkOrSkip();               // skips loudly when no RPC is configured
///         // deploy your service, then:
///         provisionTo(provider, address(ds), 100_000 ether);
///         fundEscrow(payer, RECURRING_COLLECTOR, provider, 50_000 ether);
///     }
/// }
/// ```
///
/// Run with:
///   ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc forge test --match-path test/*Fork*
abstract contract HorizonForkTest is Test {
    // ── Addresses ────────────────────────────────────────────────────────────
    //
    // Arbitrum Sepolia. **Resolved from the Controller, not copied from a table**, because two
    // addresses in wide circulation turned out to be implementations rather than proxies. Calling an
    // implementation does not revert: its storage is uninitialised, so a view returns **zero**,
    // forever, silently. A wrong address here is invisible rather than loud.
    //
    //   cast call <controller> "getContractProxy(bytes32)(address)" $(cast keccak "PaymentsEscrow")
    //
    // Note the registry key for staking is `Staking`, not `HorizonStaking` - the latter resolves to
    // the zero address, which is at least a loud failure.
    address public constant CONTROLLER = 0x9DB3ee191681f092607035d9BDA6e59FbEaCa695;
    address public constant GRT = 0xf8c05dCF59E8B28BFD5eed176C562bEbcfc7Ac04;
    address public constant STAKING = 0x865365C425f3A593Ffe698D9c4E6707D14d51e08;
    address public constant ESCROW = 0x4b5D3Da463F7E076bb7CDF5030960bf123245681;
    address public constant RECURRING_COLLECTOR = 0x0B18beFc60455121Ad66Ae6E4A647955FCde3900;

    /// The protocol refuses a thawing period above roughly this, and the revert is a custom error
    /// carrying two raw numbers and no name, so it reads as opaque until you convert them. 30 days
    /// is over the line; 14 is comfortably inside.
    uint64 public constant SAFE_THAWING_PERIOD = 14 days;

    /// Skips rather than fails when no RPC is configured: a test that cannot reach the network has
    /// discovered nothing, and reporting that as a failure teaches people to ignore it.
    ///
    /// It skips **loudly**. A suite that prints `ok` having executed nothing reads exactly like a
    /// suite that passed.
    function forkOrSkip() internal {
        try vm.envString("ARBITRUM_SEPOLIA_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
            return;
        }
        assertAddressesLookLikeProxies();
    }

    /// A Horizon proxy is a few kilobytes; an implementation is tens. Crude, and it catches the one
    /// mistake whose failure mode is a silent zero.
    function assertAddressesLookLikeProxies() internal view {
        require(STAKING.code.length > 0 && STAKING.code.length < 10_000, "STAKING looks like an implementation");
        require(ESCROW.code.length > 0 && ESCROW.code.length < 10_000, "ESCROW looks like an implementation");
    }

    /// Authorise a payer's **own** key with a collector.
    ///
    /// Needed before any agreement that payer signs will verify, and the least obvious step in the
    /// whole protocol: `_isAuthorized(payer, signer)` requires `authorizations[signer].authorizer ==
    /// payer` and does **not** special-case signer == payer. Skip it and a cryptographically perfect
    /// signature is rejected with an error blaming the signature.
    ///
    /// Note the proof is a plain `eth_sign`, not EIP-712, in a contract whose agreements are EIP-712.
    function authorizeOwnSigner(address collector, address payer, uint256 payerKey) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = keccak256(abi.encodePacked(block.chainid, collector, "authorizeSignerProof", deadline, payer));
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, prefixed);
        vm.prank(payer);
        (bool ok,) = collector.call(
            abi.encodeWithSignature(
                "authorizeSigner(address,uint256,bytes)", payer, deadline, abi.encodePacked(r, s, v)
            )
        );
        require(ok, "authorizeSigner failed");
    }

    /// Stake and provision to a data service.
    ///
    /// **This is what makes a data service payable at all.** The collector checks
    /// `getProviderTokensAvailable(serviceProvider, dataService) > 0` before paying anyone - the
    /// guard against a signer-as-data-service draining somebody's escrow. Without it everything else
    /// is well-formed and the collection is refused.
    function provisionTo(address serviceProvider, address dataService, uint256 tokens) internal {
        deal(GRT, serviceProvider, tokens);
        vm.startPrank(serviceProvider);
        (bool a,) = GRT.call(abi.encodeWithSignature("approve(address,uint256)", STAKING, tokens));
        require(a, "approve failed");
        (bool b,) = STAKING.call(abi.encodeWithSignature("stakeTo(address,uint256)", serviceProvider, tokens));
        require(b, "stakeTo failed");
        (bool c,) = STAKING.call(
            abi.encodeWithSignature(
                "provision(address,address,uint256,uint32,uint64)",
                serviceProvider,
                dataService,
                tokens,
                uint32(500_000),
                SAFE_THAWING_PERIOD
            )
        );
        require(c, "provision failed (thawing period too long?)");
        vm.stopPrank();
    }

    /// Fund escrow for a payer-collector-receiver tuple.
    ///
    /// "Blocked on funded escrow" is true of a **broadcast** and false of a fork: `deal` mints and
    /// the deposit is an ordinary call. Several roadmap items sat blocked on this for days.
    function fundEscrow(address payer, address collector, address receiver, uint256 tokens) internal {
        deal(GRT, payer, tokens);
        vm.startPrank(payer);
        (bool a,) = GRT.call(abi.encodeWithSignature("approve(address,uint256)", ESCROW, tokens));
        require(a, "approve failed");
        (bool b,) =
            ESCROW.call(abi.encodeWithSignature("deposit(address,address,uint256)", collector, receiver, tokens));
        require(b, "escrow deposit failed");
        vm.stopPrank();
    }

    function grtBalance(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory out) = GRT.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        bal = abi.decode(out, (uint256));
    }

    function providerTokensAvailable(address serviceProvider, address dataService)
        internal
        view
        returns (uint256 available)
    {
        (bool ok, bytes memory out) = STAKING.staticcall(
            abi.encodeWithSignature("getProviderTokensAvailable(address,address)", serviceProvider, dataService)
        );
        require(ok, "getProviderTokensAvailable failed");
        available = abi.decode(out, (uint256));
    }
}
