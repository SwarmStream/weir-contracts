// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, OracleAttestation, OracleAttestationConsumer} from "./WeirTestBase.sol";

contract WeirAttestationTest is WeirTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _create();
        _dispute(id, client);
    }

    function _reject(OracleAttestation.Attestation memory a, bytes memory expectedError) internal {
        bytes memory signature = _sign(a);
        vm.expectRevert(expectedError);
        weir.submitAttestation(id, a, signature);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
    }

    function test_wrongSenderUnknownRequestAndMismatchedAttestation() public {
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes32 receipt = weir.streams(id).requestId;
        bytes memory signature = _sign(a);
        vm.expectRevert(Weir.NotTheIntake.selector);
        weir.onOracleResult(receipt, a, signature);
        // A valid signature for this contract does not help a receipt id this contract never issued.
        vm.expectRevert(abi.encodeWithSelector(Weir.UnknownRequest.selector, bytes32(uint256(1))));
        vm.prank(address(intake));
        weir.onOracleResult(bytes32(uint256(1)), a, signature);
        // The oracle UUID is not a receipt id: the Intake must pair by its own id, not by the signed one.
        vm.expectRevert(abi.encodeWithSelector(Weir.UnknownRequest.selector, a.requestId));
        vm.prank(address(intake));
        weir.onOracleResult(a.requestId, a, signature);
        // The permissionless path only takes a signed id equal to the stored request id.
        _reject(a, abi.encodeWithSelector(Weir.AttestationRequestMismatch.selector));
        a = _attestation(id, true);
        a.chainId = 1;
        _reject(a, abi.encodeWithSelector(Weir.AttestationChainMismatch.selector));
    }

    function test_callbackAcceptsDistinctOracleUUIDForItsOwnReceipt() public {
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes32 receipt = weir.streams(id).requestId;
        assertNotEq(a.requestId, receipt);
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        weir.onOracleResult(receipt, a, signature);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
        assertEq(weir.streams(id).ruling, 1);
        assertTrue(weir.consumed(a.requestId));
        assertFalse(weir.consumed(receipt));
        assertEq(weir.streams(id).requestId, receipt);
        (, uint32 clientLost,,, uint32 raised) = weir.records(client);
        (,, uint32 recipientWon,,) = weir.records(recipient);
        assertEq(clientLost, 1);
        assertEq(recipientWon, 1);
        assertEq(raised, 1);
        vm.prank(stranger);
        weir.enforce(id);
        assertEq(weir.streams(id).rate, RATE);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
    }

    function test_consumedOracleUUIDCannotSettleAnotherStream() public {
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        bytes32 receipt = weir.streams(id).requestId;
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        weir.onOracleResult(receipt, a, signature);
        uint256 other = _create();
        bytes32 otherReceipt = _dispute(other, recipient);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        vm.prank(address(intake));
        weir.onOracleResult(otherReceipt, a, signature);
        assertEq(uint256(weir.streams(other).state), uint256(Weir.State.Disputed));
    }

    function test_callbackRejectsAnswerSignedForAnotherConsumer() public {
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes32 receipt = weir.streams(id).requestId;
        Weir other = new Weir(gate, imd, intake, vm.addr(SIGNING_KEY), 7 days, HOLD);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, other.attestationDigest(a));
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.onOracleResult(receipt, a, signature);
    }

    function test_panelQuorumAndAgreementMinimums() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.panelSize = 4;
        _reject(a, abi.encodeWithSelector(Weir.PanelTooWeak.selector));
        a.panelSize = 5;
        a.quorum = 3;
        _reject(a, abi.encodeWithSelector(Weir.PanelTooWeak.selector));
        a.quorum = 4;
        a.agreed = 3;
        _reject(a, abi.encodeWithSelector(Weir.PanelTooWeak.selector));
        a.agreed = 6;
        _reject(a, abi.encodeWithSelector(Weir.PanelTooWeak.selector));
        a.agreed = 5;
        a.quorum = 5;
        weir.submitAttestation(id, a, _sign(a));
    }

    function test_onlyCanonicalBoolAnswers() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.answerType = 3;
        _reject(a, abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(0), uint8(3)));
        a.answerType = 0;
        a.answer = "";
        _reject(a, abi.encodeWithSelector(Weir.InvalidBoolAnswer.selector));
        a.answer = abi.encode(uint256(2));
        _reject(a, abi.encodeWithSelector(Weir.InvalidBoolAnswer.selector));
        a.answer = abi.encode(true, false);
        _reject(a, abi.encodeWithSelector(Weir.InvalidBoolAnswer.selector));
        a.answer = abi.encode(false);
        weir.submitAttestation(id, a, _sign(a));
        assertEq(weir.streams(id).ruling, 2);
    }

    function test_expiryAndFutureIssuedAtChecks() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        _reject(a, abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        a = _attestation(id, true);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        _reject(a, abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        a = _attestation(id, true);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        weir.submitAttestation(id, a, _sign(a));
    }

    function test_issuedAtToleranceMatchesReference() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 300);
        weir.submitAttestation(id, a, _sign(a));
    }

    function test_tamperedAndWrongSignerAndMalleableSignaturesRejected() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _sign(a);
        a.answer = abi.encode(false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.submitAttestation(id, a, signature);
        a = _attestation(id, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(456, weir.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.submitAttestation(id, a, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(SIGNING_KEY, weir.attestationDigest(a));
        s = bytes32(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 - uint256(s));
        v = v == 27 ? 28 : 27;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.submitAttestation(id, a, abi.encodePacked(r, s, v));
    }

    function test_otherConsumerAndOtherChainDomainsRejected() public {
        OracleAttestation.Attestation memory a = _attestation(id, true);
        Weir other = new Weir(gate, imd, intake, vm.addr(SIGNING_KEY), 7 days, HOLD);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, other.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.submitAttestation(id, a, abi.encodePacked(r, s, v));
        vm.chainId(1);
        bytes memory signature = _sign(a);
        vm.chainId(4663);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        weir.submitAttestation(id, a, signature);
    }

    function test_replayViaBothPathsAndFailureAfterVerdictRejected() public {
        OracleAttestation.Attestation memory a = _attestation(id, false);
        bytes32 receipt = weir.streams(id).requestId;
        bytes memory signature = _sign(a);
        weir.submitAttestation(id, a, signature);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.submitAttestation(id, a, signature);
        (bool ok,) = intake.deliver(receipt, a, signature);
        assertFalse(ok);
        OracleAttestation.Attestation memory b = _oracleAttestation(id, false);
        (ok,) = intake.deliver(receipt, b, _sign(b));
        assertFalse(ok);
        (ok,) = intake.failRequest(receipt, 2, "disagreed", 2, 5);
        assertFalse(ok);
        (uint32 won,,,, uint32 raised) = weir.records(client);
        assertEq(won, 1);
        assertEq(raised, 1);
    }
}
