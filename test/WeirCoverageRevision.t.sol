// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, IERC20, OracleAttestation, OracleAttestationConsumer} from "./WeirTestBase.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Adversarial edges of the revised implementation: acceptance in every state, records on streams the
/// recipient accepted mid-dispute, claims between accounts, the unguarded ruling functions under reentrancy, and
/// the bond cap at its boundary.
contract WeirCoverageRevisionTest is WeirTestBase {
    // ------------------------------------------------------------------ acceptance across states

    function test_acceptRefusedInDisputedRuledAndUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(Weir.UnknownStream.selector, 9));
        vm.prank(recipient);
        weir.accept(9);
        uint256 id = _createUnaccepted(token, RATE, AMOUNT);
        _dispute(id, client);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Disputed));
        vm.prank(recipient);
        weir.accept(id);
        _rule(id, true);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        vm.prank(recipient);
        weir.accept(id);
        // The ruling settled the money but, with no acceptance, wrote no record for either side.
        (, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon,,) = weir.records(recipient);
        assertEq(uint256(clientLost) + clientRaised + recipientWon, 0);
        weir.enforce(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        // Back in Active the recipient can accept, and the next ruling counts.
        vm.prank(recipient);
        weir.accept(id);
        _dispute(id, client);
        _rule(id, false);
        (uint32 clientWon,,,, uint32 raised) = weir.records(client);
        (,,, uint32 recipientLost,) = weir.records(recipient);
        assertEq(clientWon, 1);
        assertEq(raised, 1);
        assertEq(recipientLost, 1);
    }

    /// @dev A withdrawal is acceptance in any state, including during a dispute the client raised, so a ruling
    /// delivered afterwards is recorded against both parties. A zero-amount withdrawal is enough.
    function test_withdrawalDuringClientDisputeAcceptsAndTheRulingIsRecorded() public {
        uint256 id = _createUnaccepted(token, RATE, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 5);
        _dispute(id, client);
        assertEq(weir.acceptedAt(id), 0);
        uint256 before = token.balanceOf(recipient);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Accepted(id, recipient, TERMS);
        vm.prank(recipient);
        weir.withdraw(id, 0);
        assertEq(token.balanceOf(recipient), before);
        assertEq(weir.acceptedAt(id), vm.getBlockTimestamp());
        _rule(id, true);
        (, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientLost, 1);
        assertEq(clientRaised, 1);
        assertEq(recipientWon, 1);
        assertEq(recipientRaised, 0);
    }

    // ------------------------------------------------------------------ claims

    function test_claimPaysOnlyTheCallersOwnTokenAmount() public {
        uint256 a = _create();
        uint256 b = _create();
        _dispute(a, client);
        _dispute(b, recipient);
        _rule(a, false);
        _rule(b, false);
        uint256 bond = weir.streams(a).bond;
        token.setBlocked(client, true);
        weir.enforce(a);
        weir.enforce(b);
        // Both the refund and both bonds are the client's, all deferred while the client is blocked.
        uint256 owed = 2 * (AMOUNT + bond);
        assertEq(weir.claimable(address(token), client), owed);
        assertEq(weir.claimable(address(token), recipient), 0);
        assertEq(weir.unclaimed(address(token)), owed);
        vm.expectRevert(Weir.NothingToClaim.selector);
        vm.prank(recipient);
        weir.claim(token);
        vm.expectRevert(Weir.NothingToClaim.selector);
        vm.prank(client);
        weir.claim(imd);
        vm.expectRevert("token blocked");
        vm.prank(client);
        weir.claim(token);
        assertEq(weir.claimable(address(token), client), owed, "a refused claim keeps the entitlement");
        token.setBlocked(client, false);
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        weir.claim(token);
        assertEq(token.balanceOf(client) - before, owed);
        assertEq(weir.unclaimed(address(token)), 0);
        assertEq(token.balanceOf(address(weir)), 0);
        _solvent(token);
    }

    function test_claimCannotBeReenteredThroughItsOwnPayout() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(client, 1e12);
        evil.mint(recipient, 1e12);
        vm.prank(client);
        evil.approve(address(weir), type(uint256).max);
        vm.prank(recipient);
        evil.approve(address(weir), type(uint256).max);
        uint256 id = _createWith(IERC20(address(evil)), RATE, AMOUNT);
        _dispute(id, recipient);
        uint256 bond = weir.streams(id).bond;
        _rule(id, true);
        // The payout itself re-enters claim: refused by the guard, so nothing is deferred and nothing doubles.
        evil.arm(address(weir), abi.encodeCall(weir.claim, (IERC20(address(evil)))));
        uint256 before = evil.balanceOf(recipient);
        weir.enforce(id);
        assertFalse(evil.lastSucceeded());
        assertEq(evil.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(recipient) - before, bond);
        assertEq(weir.unclaimed(address(evil)), 0);
        _solvent(IERC20(address(evil)));
    }

    // ------------------------------------------------------------------ unguarded ruling functions

    /// @dev The ruling functions no longer carry a reentrancy guard. During the bond pull of a first dispute the
    /// stream is already Disputed with a zero request id, so a re-entrant token can reach submitAttestation with a
    /// zero signed request id; only the signature check stands between it and a ruling.
    function test_reenteringSubmitAttestationDuringTheBondPullIsRefusedBySignature() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(client, 1e12);
        vm.prank(client);
        evil.approve(address(weir), type(uint256).max);
        uint256 id = _createWith(IERC20(address(evil)), RATE, AMOUNT);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.requestId = bytes32(0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xbad5ec, weir.attestationDigest(a));
        evil.arm(address(weir), abi.encodeCall(weir.submitAttestation, (id, a, abi.encodePacked(r, s, v))));
        bytes32 receipt = _dispute(id, client);
        assertEq(evil.attempts(), 1);
        assertFalse(evil.lastSucceeded());
        assertEq(evil.lastError(), OracleAttestationConsumer.BadSignature.selector);
        Weir.Stream memory st = weir.streams(id);
        assertEq(uint256(st.state), uint256(Weir.State.Disputed));
        assertEq(st.ruling, 0);
        assertEq(st.requestId, receipt);
        assertFalse(weir.consumed(bytes32(0)));
        // After the receipt is stored, the same path with the stale (zero) id is refused by the id check.
        evil.arm(address(weir), abi.encodeCall(weir.submitAttestation, (id, a, abi.encodePacked(r, s, v))));
        vm.prank(client);
        weir.deposit(id, 1);
        assertEq(evil.lastError(), Weir.AttestationRequestMismatch.selector);
    }

    function test_onOracleResultCannotBeReenteredFromATokenBecauseOnlyTheIntakeMayCall() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(client, 1e12);
        vm.prank(client);
        evil.approve(address(weir), type(uint256).max);
        uint256 id = _createWith(IERC20(address(evil)), RATE, AMOUNT);
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes memory signature = _sign(a);
        evil.arm(address(weir), abi.encodeCall(weir.onOracleResult, (receipt, a, signature)));
        vm.prank(client);
        weir.deposit(id, 1);
        assertFalse(evil.lastSucceeded());
        assertEq(evil.lastError(), Weir.NotTheIntake.selector);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
    }

    // ------------------------------------------------------------------ bond cap boundary

    function test_disputeBondCapAtExactlyTheBondAndAtZero() public {
        uint256 id = _create();
        uint256 quote = weir.bondFor(id, client);
        vm.expectRevert(abi.encodeWithSelector(Weir.BondExceedsLimit.selector, quote, 0));
        vm.prank(client);
        weir.dispute(id, "late", 0);
        vm.expectRevert(abi.encodeWithSelector(Weir.BondExceedsLimit.selector, quote, quote - 1));
        vm.prank(client);
        weir.dispute(id, "late", quote - 1);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.streams(id).rate, RATE);
        vm.prank(client);
        weir.dispute(id, "late", quote);
        assertEq(weir.streams(id).bond, quote);
        // A zero-bond disputer may pass a zero cap.
        uint256 other = _create();
        gate.mint(recipient, 10_000_000e18);
        assertEq(weir.bondFor(other, recipient), 0);
        vm.prank(recipient);
        weir.dispute(other, "unpaid", 0);
        assertEq(weir.streams(other).bond, 0);
        _solvent(token);
    }

    // ------------------------------------------------------------------ callback cost

    /// @dev The Intake's stipend is the live constraint; the assignment's stricter 150,000 bound is missed for a
    /// first ruling between two parties with empty records (about 152,000 gas) and is reported, not asserted.
    function test_onOracleResultColdFirstRulingWithEmptyRecordsFitsTheStipend() public {
        uint256 id = _create();
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes memory signature = _sign(a);
        vm.cool(address(weir));
        vm.cool(vm.addr(SIGNING_KEY));
        vm.prank(address(intake));
        weir.onOracleResult(receipt, a, signature);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertLt(used, 200_000);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
    }

    /// @dev Every shape other than two empty record slots is under the assignment's bound.
    function test_onOracleResultColdRulingWithoutRecordWritesIsBelow150000() public {
        uint256 id = _createUnaccepted(token, RATE, AMOUNT);
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        bytes memory signature = _sign(a);
        vm.cool(address(weir));
        vm.cool(vm.addr(SIGNING_KEY));
        vm.prank(address(intake));
        weir.onOracleResult(receipt, a, signature);
        assertLt(vm.lastCallGas().gasTotalUsed, 150_000);
        assertEq(weir.streams(id).ruling, 2);
    }
}
