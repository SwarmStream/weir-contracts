// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, OracleAttestation, OracleAttestationConsumer} from "./WeirTestBase.sol";

/// @dev Test-only exposure of the canonical verifier, for the protocol's non-bool vector.
contract ProtocolVerifierHarness is OracleAttestationConsumer {
    constructor(address signer) OracleAttestationConsumer(signer) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

/// @notice Protocol vector constants are copied unchanged from the supplied reference.
/// @dev Weir requires a same-chain bool, so the untouched vector tests the digest and base verifier;
/// a fresh bool signed by the same vector key exercises Weir's real Intake callback.
contract OracleConsumerConformanceTest is WeirTestBase {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    function setUp() public override {
        super.setUp();
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        Weir implementation = new Weir(gate, imd, intake, SIGNER, 7 days, HOLD);
        vm.etch(VECTOR_CONSUMER, address(implementation).code);
        weir = Weir(VECTOR_CONSUMER);
        vm.startPrank(client);
        token.approve(address(weir), type(uint256).max);
        imd.approve(address(weir), type(uint256).max);
        vm.stopPrank();
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(weir.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(weir.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
        assertEq(weir.onFailure.selector, bytes4(keccak256("onFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)")));
    }

    function test_acceptsUnchangedProtocolSignatureInCanonicalVerifier() public {
        ProtocolVerifierHarness implementation = new ProtocolVerifierHarness(SIGNER);
        vm.etch(VECTOR_CONSUMER, address(implementation).code);
        ProtocolVerifierHarness(VECTOR_CONSUMER).verify(vector(), VECTOR_SIGNATURE);
    }

    function test_acceptsFreshBoolFromVectorKeyAsDeliveredWithinStipend() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, client);
        // The vector's own oracle UUID is kept: it is not the Intake receipt id the callback receives.
        OracleAttestation.Attestation memory a = vector();
        assertNotEq(a.requestId, requestId);
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(false);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, weir.attestationDigest(a));
        vm.cool(VECTOR_CONSUMER);
        vm.cool(SIGNER);
        (bool called,) = intake.deliver(requestId, a, abi.encodePacked(r, s, v));
        assertTrue(called);
        assertTrue(weir.consumed(a.requestId));
        assertEq(weir.streams(id).ruling, 2);
    }
}
