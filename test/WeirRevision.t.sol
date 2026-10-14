// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, OracleAttestation} from "./WeirTestBase.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Behaviour added by the review revision: recipient acceptance, the bond limit, the live oracle price,
/// deferred settlement payouts and the self-recipient guard.
contract WeirRevisionTest is WeirTestBase {
    // ---------------------------------------------------------------- acceptance

    function test_acceptIsTheRecipientsAloneAndOnce() public {
        uint256 id = _createUnaccepted(token, RATE, AMOUNT);
        assertEq(weir.acceptedAt(id), 0);
        vm.expectRevert(Weir.NotRecipient.selector);
        vm.prank(client);
        weir.accept(id);
        vm.expectRevert(Weir.NotRecipient.selector);
        vm.prank(stranger);
        weir.accept(id);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Accepted(id, recipient, TERMS);
        vm.prank(recipient);
        weir.accept(id);
        assertEq(weir.acceptedAt(id), vm.getBlockTimestamp());
        vm.expectRevert(Weir.AlreadyAccepted.selector);
        vm.prank(recipient);
        weir.accept(id);
        _dispute(id, client);
        _rule(id, false);
        (uint32 clientWon,,,, uint32 clientRaised) = weir.records(client);
        (,,, uint32 recipientLost,) = weir.records(recipient);
        assertEq(clientWon, 1);
        assertEq(clientRaised, 1);
        assertEq(recipientLost, 1);
    }

    function test_withdrawalOrOwnDisputeCountsAsAcceptanceAndAcceptNeedsActive() public {
        uint256 id = _createUnaccepted(token, RATE, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Accepted(id, recipient, TERMS);
        vm.prank(recipient);
        weir.withdraw(id, 1);
        assertEq(weir.acceptedAt(id), vm.getBlockTimestamp());
        uint256 byDispute = _createUnaccepted(token, RATE, AMOUNT);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Accepted(byDispute, recipient, TERMS);
        vm.prank(recipient);
        weir.dispute(byDispute, "unpaid");
        assertEq(weir.acceptedAt(byDispute), vm.getBlockTimestamp());
        _rule(byDispute, true);
        (,, uint32 recipientWon,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(recipientWon, 1);
        assertEq(recipientRaised, 1);
        uint256 other = _createUnaccepted(token, RATE, AMOUNT);
        vm.prank(client);
        weir.void(other);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        vm.prank(recipient);
        weir.accept(other);
        // A withdrawal from a closed stream still records assent but can no longer lead to a dispute.
        vm.prank(recipient);
        weir.withdrawMax(other);
        assertEq(weir.acceptedAt(other), vm.getBlockTimestamp());
    }

    /// @dev A stranger holding WEIR cannot write a record against an address that never engaged with the stream:
    /// the ruling still settles the money but counts for nobody.
    function test_noRecordAgainstRecipientWhoNeverAccepted() public {
        MockToken junk = new MockToken("JUNK", 18);
        junk.mint(stranger, 1);
        vm.prank(stranger);
        junk.approve(address(weir), 1);
        address victim = makeAddr("victim");
        vm.prank(client);
        weir.sponsor(FEE);
        vm.startPrank(stranger);
        uint256 id = weir.createStream(victim, junk, 1, 1, keccak256("terms the victim never saw"), "ipfs://x", 0);
        weir.dispute(id, "Nothing was delivered.");
        vm.stopPrank();
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Verdict(id, weir.streams(id).requestId, a.panelJobId, false, stranger, victim, stranger);
        (bool ok,) = intake.deliver(weir.streams(id).requestId, a, _sign(a));
        assertTrue(ok);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
        (uint32 cw, uint32 cl, uint32 rw, uint32 rl, uint32 raised) = weir.records(victim);
        assertEq(uint256(cw) + cl + rw + rl + raised, 0, "no record for the non-consenting recipient");
        (cw, cl, rw, rl, raised) = weir.records(stranger);
        assertEq(uint256(cw) + cl + rw + rl + raised, 0, "no farmed record for the client either");
        weir.enforce(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
        assertEq(junk.balanceOf(stranger), 1);
        // Accepting later cannot retroactively count that ruling: accept() needs an Active stream.
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        vm.prank(victim);
        weir.accept(id);
    }

    // ---------------------------------------------------------------- bond limit

    function test_bondLimitStopsDepositInflationBetweenQuoteAndDispute() public {
        uint256 id = _create();
        vm.prank(client);
        weir.pause(id);
        uint256 quote = weir.bondFor(id, recipient);
        assertEq(quote, 50e6);
        vm.prank(client);
        weir.deposit(id, 99_000e6);
        uint256 inflated = weir.bondFor(id, recipient);
        assertEq(inflated, 5_000e6);
        vm.expectRevert(abi.encodeWithSelector(Weir.BondExceedsLimit.selector, inflated, quote));
        vm.prank(recipient);
        weir.dispute(id, "late", quote);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        // The recipient may still proceed knowingly, at the inflated bond, with either entry point.
        uint256 before = token.balanceOf(recipient);
        vm.prank(recipient);
        weir.dispute(id, "late", inflated);
        assertEq(before - token.balanceOf(recipient), inflated);
        assertEq(weir.streams(id).bond, inflated);
        _solvent(token);
    }

    function test_bondLimitExactQuoteAndTinyDepositRevertsInsteadOfOverdrawing() public {
        uint256 id = _create();
        uint256 quote = weir.bondFor(id, recipient);
        vm.prank(recipient);
        token.approve(address(weir), quote);
        vm.prank(client);
        weir.deposit(id, 20);
        vm.expectRevert(abi.encodeWithSelector(Weir.BondExceedsLimit.selector, quote + 1, quote));
        vm.prank(recipient);
        weir.dispute(id, "late", quote);
        vm.prank(recipient);
        token.approve(address(weir), quote + 1);
        vm.prank(recipient);
        weir.dispute(id, "late", quote + 1);
        assertEq(weir.streams(id).bond, quote + 1);
    }

    // ---------------------------------------------------------------- live oracle price

    function test_disputePaysTheLiveIntakePriceInEitherDirection() public {
        uint256 id = _create();
        intake.setPrice(4e17);
        assertEq(weir.oraclePrice(), 4e17);
        uint256 before = imd.balanceOf(client);
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(before - imd.balanceOf(client), 4e17);
        assertEq(intake.lastAmount(), 4e17);
        assertEq(intake.approvedAmount(), 4e17);
        assertEq(imd.allowance(address(weir), address(intake)), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        weir.expireDispute(id);
        intake.setPrice(6e17);
        before = imd.balanceOf(recipient);
        vm.prank(recipient);
        weir.dispute(id, "unpaid");
        assertEq(before - imd.balanceOf(recipient), 6e17);
        assertEq(intake.lastAmount(), 6e17);
        _solvent(imd);
    }

    function test_courtFundPaysOnlyWhenItCoversTheLivePrice() public {
        uint256 id = _create();
        vm.prank(stranger);
        weir.sponsor(FEE);
        intake.setPrice(FEE + 1);
        uint256 before = imd.balanceOf(client);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(id, keccak256(abi.encode(address(intake), uint256(1))), client, AMOUNT / 20, false);
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(before - imd.balanceOf(client), FEE + 1);
        assertEq(weir.courtFund(), FEE);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        weir.expireDispute(id);
        intake.setPrice(FEE - 1);
        before = imd.balanceOf(client);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(id, keccak256(abi.encode(address(intake), uint256(2))), client, AMOUNT / 20, true);
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(imd.balanceOf(client), before);
        assertEq(weir.courtFund(), 1);
        _solvent(imd);
    }

    function test_unsoldOrOverpricedActionRevertsClearlyBeforeAnyTransfer() public {
        uint256 id = _create();
        intake.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(Weir.OraclePriceOutOfRange.selector, 0));
        weir.oraclePrice();
        vm.expectRevert(abi.encodeWithSelector(Weir.OraclePriceOutOfRange.selector, 0));
        vm.prank(client);
        weir.dispute(id, "late");
        intake.setPrice(weir.MAX_ORACLE_PRICE() + 1);
        vm.expectRevert(abi.encodeWithSelector(Weir.OraclePriceOutOfRange.selector, 5e18 + 1));
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.streams(id).rate, RATE);
        assertEq(weir.streams(id).bond, 0);
        intake.setPrice(weir.MAX_ORACLE_PRICE());
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(intake.lastAmount(), 5e18);
    }

    // ---------------------------------------------------------------- deferred payouts

    function test_blockedDisputerNoLongerLocksFailureOrExpiry() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, recipient);
        uint256 bond = weir.streams(id).bond;
        token.setBlocked(recipient, true);
        vm.cool(address(weir));
        vm.cool(address(token));
        (bool success,) = intake.failRequest(requestId, 2, "disagreed", 2, 5);
        assertTrue(success, "failure callback must clear the dispute even when the payout is refused");
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.streams(id).bond, 0);
        assertEq(weir.claimable(address(token), recipient), bond);
        assertEq(weir.unclaimed(address(token)), bond);
        _solvent(token);
        // A second dispute (bond pulled while unblocked) and a timed-out exit also defer while the token refuses.
        token.setBlocked(recipient, false);
        bytes32 second = _dispute(id, recipient);
        token.setBlocked(recipient, true);
        assertNotEq(second, requestId);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.PayoutDeferred(id, address(token), recipient, bond);
        vm.prank(stranger);
        weir.expireDispute(id);
        assertEq(weir.claimable(address(token), recipient), 2 * bond);
        // The client's unearned principal is no longer trapped.
        uint256 beforeClient = token.balanceOf(client);
        vm.prank(client);
        weir.void(id);
        assertEq(token.balanceOf(client) - beforeClient, AMOUNT);
        _solvent(token);
        vm.expectRevert("token blocked");
        vm.prank(recipient);
        weir.claim(token);
        token.setBlocked(recipient, false);
        uint256 beforeRecipient = token.balanceOf(recipient);
        vm.prank(recipient);
        weir.claim(token);
        assertEq(token.balanceOf(recipient) - beforeRecipient, 2 * bond);
        assertEq(weir.unclaimed(address(token)), 0);
        vm.expectRevert(Weir.NothingToClaim.selector);
        vm.prank(recipient);
        weir.claim(token);
        assertEq(token.balanceOf(address(weir)), 0);
        _solvent(token);
    }

    function test_deferredPayoutStillRejectsShortTransfers() public {
        uint256 id = _create();
        _dispute(id, recipient);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        token.setTax(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(token)));
        weir.expireDispute(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
        token.setTax(false);
        weir.expireDispute(id);
        assertEq(weir.unclaimed(address(token)), 0);
    }

    function test_claimIsGuardedAgainstReentrancy() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, recipient);
        token.setBlocked(recipient, true);
        intake.failRequest(requestId, 1, "body_refused", 0, 0);
        token.setBlocked(recipient, false);
        token.setHook(address(weir), abi.encodeCall(weir.claim, (token)));
        vm.prank(recipient);
        weir.claim(token);
        assertFalse(token.hookSucceeded());
        assertEq(weir.unclaimed(address(token)), 0);
        _solvent(token);
    }

    // ---------------------------------------------------------------- creation guard

    function test_weirItselfCannotBeTheRecipient() public {
        vm.expectRevert(Weir.InvalidRecipient.selector);
        vm.prank(client);
        weir.createStream(address(weir), token, RATE, AMOUNT, TERMS, URI, bytes32(0));
    }

    // ---------------------------------------------------------------- callback cost

    function test_coldFirstRulingCallbackGasIsLogged() public {
        uint256 id = _create();
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        bytes memory signature = _sign(a);
        vm.cool(address(weir));
        vm.cool(vm.addr(SIGNING_KEY));
        vm.prank(address(intake));
        weir.onOracleResult(receipt, a, signature);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("cold first ruling callee gas", used);
        // The Intake's stipend is 200,000; the README records the measured figure.
        assertLt(used, 200_000);
    }
}
