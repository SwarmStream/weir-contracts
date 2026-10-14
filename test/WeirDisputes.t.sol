// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, OracleAttestation, OracleAttestationConsumer} from "./WeirTestBase.sol";
import {OracleText} from "../src/libraries/OracleText.sol";

contract WeirDisputesTest is WeirTestBase {
    function test_disputePaysCallerAndFreezesAccrual() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 beforeToken = token.balanceOf(client);
        uint256 beforeIMD = imd.balanceOf(client);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(id, keccak256(abi.encode(address(intake), uint256(1))), client, AMOUNT / 20, false);
        bytes32 requestId = _dispute(id, client);
        Weir.Stream memory s = weir.streams(id);
        assertEq(uint256(s.state), uint256(Weir.State.Disputed));
        assertEq(s.rate, 0);
        assertEq(s.pausedRate, RATE);
        assertEq(s.bond, AMOUNT / 20);
        assertEq(beforeToken - token.balanceOf(client), s.bond);
        assertEq(beforeIMD - imd.balanceOf(client), FEE);
        assertEq(weir.requestStream(requestId), id);
        assertEq(intake.lastAmount(), FEE);
        assertEq(intake.approvedAmount(), FEE);
        assertEq(imd.allowance(address(weir), address(intake)), 0);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastAsset(), address(imd));
        (address callbackTarget, bytes4 callbackSelector) = intake.lastCallback();
        assertEq(callbackTarget, address(weir));
        assertEq(callbackSelector, weir.onOracleResult.selector);
        assertEq(intake.lastFailure(), weir.onFailure.selector);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(weir.streamed(id), 10e6);
        vm.prank(recipient);
        weir.withdrawMax(id);
        vm.prank(client);
        weir.deposit(id, 10e6);
        assertEq(weir.streams(id).bond, s.bond);
        assertEq(weir.withdrawable(id), 0);
        _solvent(token);
        _solvent(imd);
    }

    function test_courtFundPaysOnlyWhenEnoughAndNeverUsesIMDStreamOrBond() public {
        uint256 id = _createWith(imd, RATE, AMOUNT);
        // A large IMD stream alone must never be mistaken for sponsorship.
        uint256 largeId = _createWith(imd, 1e18, 10e18);
        vm.prank(stranger);
        weir.sponsor(FEE - 1);
        uint256 beforeIMD = imd.balanceOf(client);
        uint256 bond = weir.bondFor(largeId, client);
        _dispute(largeId, client);
        assertEq(beforeIMD - imd.balanceOf(client), FEE + bond);
        assertEq(weir.courtFund(), FEE - 1);
        assertEq(imd.balanceOf(address(weir)), weir.escrowed(address(imd)) + FEE - 1);
        vm.prank(stranger);
        weir.sponsor(1);
        beforeIMD = imd.balanceOf(recipient);
        bond = weir.bondFor(id, recipient);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(id, keccak256(abi.encode(address(intake), uint256(2))), recipient, bond, true);
        _dispute(id, recipient);
        assertEq(beforeIMD - imd.balanceOf(recipient), bond);
        assertEq(weir.courtFund(), 0);
        _solvent(imd);
    }

    function test_donatedIMDIsNotCourtFund() public {
        uint256 id = _create();
        vm.prank(stranger);
        imd.transfer(address(weir), 5e18);
        uint256 before = imd.balanceOf(client);
        _dispute(id, client);
        assertEq(before - imd.balanceOf(client), FEE);
        assertEq(weir.courtFund(), 0);
        assertEq(imd.balanceOf(address(weir)), 5e18);
    }

    function test_tierBoundariesAndZeroBondDoNotRequireTokenApproval() public {
        assertEq(weir.tierBps(client), 500);
        gate.mint(client, 100_000e18 - HOLD - 1);
        assertEq(weir.tierBps(client), 500);
        gate.mint(client, 1);
        assertEq(weir.tierBps(client), 250);
        gate.mint(client, 900_000e18 - 1);
        assertEq(weir.tierBps(client), 250);
        gate.mint(client, 1);
        assertEq(weir.tierBps(client), 100);
        gate.mint(client, 9_000_000e18 - 1);
        assertEq(weir.tierBps(client), 100);
        gate.mint(client, 1);
        assertEq(weir.tierBps(client), 0);
        uint256 id = _create();
        vm.prank(client);
        token.approve(address(weir), 0);
        _dispute(id, client);
        assertEq(weir.streams(id).bond, 0);
        _rule(id, false);
        weir.enforce(id);
        _solvent(token);
    }

    function test_zeroStakeRejectedButDustBondMayRoundToZero() public {
        uint256 id = _createWith(token, 1, 19);
        assertEq(weir.bondFor(id, client), 0);
        _dispute(id, client);
        _rule(id, true);
        weir.enforce(id);
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(recipient);
        weir.withdrawMax(id);
        vm.expectRevert(Weir.NoStake.selector);
        _dispute(id, client);
    }

    function test_rulingIsTokenFreeAndCallbackFits200000Gas() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, recipient);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        assertNotEq(a.requestId, requestId);
        bytes memory signature = _sign(a);
        uint256 before = token.balanceOf(address(weir));
        token.setFail(true);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Verdict(id, requestId, a.panelJobId, true, client, recipient, recipient);
        vm.cool(address(weir));
        vm.cool(vm.addr(SIGNING_KEY));
        (bool success,) = intake.deliver(requestId, a, signature);
        assertTrue(success, "ruling must complete within the Intake's 200,000 gas");
        assertEq(token.balanceOf(address(weir)), before);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
        assertEq(weir.streams(id).ruling, 1);
        assertTrue(weir.consumed(a.requestId));
        assertFalse(weir.consumed(requestId));
        (, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientLost, 1);
        assertEq(recipientWon, 1);
        assertEq(clientRaised, 0);
        assertEq(recipientRaised, 1);
        // A refused payout defers the bond to a claim rather than leaving the stream Ruled.
        weir.enforce(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.claimable(address(token), recipient), AMOUNT / 20);
        token.setFail(false);
        vm.prank(recipient);
        weir.claim(token);
        assertEq(weir.unclaimed(address(token)), 0);
        _solvent(token);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_enforcementRoutesBondToWinner(bool accepted, bool clientRaises, uint32 secondsBeforeDispute)
        public
    {
        secondsBeforeDispute = uint32(bound(secondsBeforeDispute, 0, 1000));
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + secondsBeforeDispute);
        address disputer = clientRaises ? client : recipient;
        _dispute(id, disputer);
        uint256 earned = uint256(RATE) * secondsBeforeDispute;
        uint256 bond = weir.streams(id).bond;
        // Withdrawal during the dispute must not alter the original bond.
        vm.prank(recipient);
        weir.withdraw(id, earned / 2);
        vm.prank(client);
        weir.deposit(id, 11e6);
        _rule(id, accepted);
        uint256 beforeClient = token.balanceOf(client);
        uint256 beforeRecipient = token.balanceOf(recipient);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(stranger);
        weir.enforce(id);
        assertEq(weir.streams(id).bond, 0);
        if (accepted) {
            assertEq(token.balanceOf(recipient) - beforeRecipient, bond);
            assertEq(token.balanceOf(client), beforeClient);
            assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
            assertEq(weir.streams(id).rate, RATE);
            assertEq(weir.streamed(id), earned);
            vm.warp(vm.getBlockTimestamp() + 1);
            assertEq(weir.streamed(id), earned + RATE);
        } else {
            assertEq(token.balanceOf(client) - beforeClient, AMOUNT + 11e6 - earned + bond);
            assertEq(token.balanceOf(recipient), beforeRecipient);
            assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
            assertEq(weir.withdrawable(id), earned - earned / 2);
            assertEq(weir.refundable(id), 0);
        }
        _solvent(token);
        _solvent(imd);
        vm.expectRevert(
            abi.encodeWithSelector(Weir.WrongState.selector, accepted ? Weir.State.Active : Weir.State.Closed)
        );
        weir.enforce(id);
    }

    function test_clientRaisedRejectionRecordsBothRolesAndRaisedOnlyOnRuling() public {
        uint256 id = _create();
        _dispute(id, client);
        (,,,, uint32 raised) = weir.records(client);
        assertEq(raised, 0);
        _rule(id, false);
        (uint32 clientWon, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon, uint32 recipientLost, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientWon, 1);
        assertEq(clientLost, 0);
        assertEq(recipientWon, 0);
        assertEq(recipientLost, 1);
        assertEq(clientRaised, 1);
        assertEq(recipientRaised, 0);
    }

    function test_failureIsAuthenticatedAndReleasesOnlyOwnBondWithinStipend() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, recipient);
        uint256 bond = weir.streams(id).bond;
        uint256 before = token.balanceOf(recipient);
        vm.expectRevert(Weir.NotTheIntake.selector);
        weir.onFailure(requestId, 2, "disagreed", 3, 5, "");
        vm.expectRevert(abi.encodeWithSelector(Weir.UnknownRequest.selector, bytes32(uint256(5))));
        vm.prank(address(intake));
        weir.onFailure(bytes32(uint256(5)), 2, "disagreed", 3, 5, "");
        vm.expectRevert(Weir.InvalidFailureStatus.selector);
        vm.prank(address(intake));
        weir.onFailure(requestId, 0, "disagreed", 3, 5, "");
        vm.cool(address(weir));
        vm.cool(address(token));
        (bool success,) = intake.failRequest(requestId, 2, "disagreed", 3, 5);
        assertTrue(success, "failure callback must fit the stipend with a standard token");
        assertEq(token.balanceOf(recipient) - before, bond);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.streams(id).rate, 0);
        assertEq(weir.streams(id).pausedRate, RATE);
        (,,,, uint32 raised) = weir.records(recipient);
        assertEq(raised, 0);
        (success,) = intake.failRequest(requestId, 2, "disagreed", 3, 5);
        assertFalse(success);
        _solvent(token);
    }

    function test_expiryStrictBoundaryAndStaleCallbackCannotAffectNewDispute() public {
        uint256 id = _create();
        bytes32 oldRequest = _dispute(id, client);
        OracleAttestation.Attestation memory oldA = _oracleAttestation(id, true);
        bytes memory oldSignature = _sign(oldA);
        uint256 before = token.balanceOf(client);
        uint256 bond = weir.streams(id).bond;
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(Weir.DisputeNotExpired.selector);
        weir.expireDispute(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        weir.expireDispute(id);
        assertEq(token.balanceOf(client) - before, bond);
        assertEq(weir.streams(id).rate, 0);
        bytes32 freshRequest = _dispute(id, client);
        assertNotEq(freshRequest, oldRequest);
        (bool ok,) = intake.deliver(oldRequest, oldA, oldSignature);
        assertFalse(ok);
        (ok,) = intake.failRequest(oldRequest, 1, "body_refused", 0, 0);
        assertFalse(ok);
        assertEq(weir.streams(id).requestId, freshRequest);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
        _rule(id, true);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.expireDispute(id);
        _solvent(token);
    }

    function test_disputeAlreadyPausedPreservesRateAndAcceptedEnforcementResumesIt() public {
        uint256 id = _create();
        vm.prank(client);
        weir.pause(id);
        _dispute(id, recipient);
        assertEq(weir.streams(id).pausedRate, RATE);
        _rule(id, true);
        weir.enforce(id);
        assertEq(weir.streams(id).rate, RATE);
    }

    function test_disputedAndRuledRestrictClientActionsButAllowRecipientWithdrawals() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 20);
        _dispute(id, client);
        _assertLockedActions(id, Weir.State.Disputed);
        vm.prank(recipient);
        weir.withdraw(id, 10e6);
        _rule(id, false);
        _assertLockedActions(id, Weir.State.Ruled);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.deposit(id, 1);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(weir.withdrawable(id), 0);
        weir.enforce(id);
        _solvent(token);
    }

    function _assertLockedActions(uint256 id, Weir.State state) private {
        bytes memory error = abi.encodeWithSelector(Weir.WrongState.selector, state);
        vm.startPrank(client);
        vm.expectRevert(error);
        weir.pause(id);
        vm.expectRevert(error);
        weir.restart(id, RATE);
        vm.expectRevert(error);
        weir.adjust(id, RATE);
        vm.expectRevert(error);
        weir.refund(id, 1);
        vm.expectRevert(error);
        weir.refundMax(id);
        vm.expectRevert(error);
        weir.void(id);
        vm.expectRevert(error);
        weir.dispute(id, "again");
        vm.stopPrank();
    }

    function test_intakeFailureRollsBackBondFeePauseAndQuestion() public {
        uint256 id = _create();
        vm.prank(stranger);
        weir.sponsor(FEE);
        uint256 beforeToken = token.balanceOf(client);
        intake.setRevert(true);
        vm.expectRevert("intake unavailable");
        _dispute(id, client);
        assertEq(token.balanceOf(client), beforeToken);
        assertEq(weir.courtFund(), FEE);
        assertEq(weir.questionOf(id), bytes32(0));
        assertEq(weir.streams(id).rate, RATE);
        assertEq(weir.streams(id).bond, 0);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        intake.setRevert(false);
        intake.setUnderPull(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(imd)));
        _dispute(id, client);
        assertEq(imd.allowance(address(weir), address(intake)), 0);
        _solvent(token);
        _solvent(imd);
    }

    function test_duplicateIntakeIdRejectedAfterExpiry() public {
        uint256 id = _create();
        bytes32 requestId = _dispute(id, client);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        weir.expireDispute(id);
        intake.setForcedId(requestId);
        vm.expectRevert(abi.encodeWithSelector(Weir.InvalidRequestId.selector, requestId));
        _dispute(id, client);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        _solvent(token);
    }

    function test_intakeAndBondReentrancyAreBlocked() public {
        uint256 id = _create();
        intake.setHook(address(weir), abi.encodeCall(weir.expireDispute, (id)));
        token.setHook(address(weir), abi.encodeCall(weir.enforce, (id)));
        _dispute(id, client);
        assertFalse(intake.hookSucceeded());
        assertFalse(token.hookSucceeded());
        _rule(id, true);
        token.setHook(address(weir), abi.encodeCall(weir.enforce, (id)));
        weir.enforce(id);
        assertFalse(token.hookSucceeded());
        _solvent(token);
    }

    function test_sponsorshipAndDisputeTokenMismatchRollBack() public {
        imd.setTax(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(imd)));
        vm.prank(stranger);
        weir.sponsor(FEE);
        assertEq(weir.courtFund(), 0);
        uint256 id = _create();
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(imd)));
        _dispute(id, client);
        assertEq(weir.streams(id).bond, 0);
        imd.setTax(false);
        token.setTax(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(token)));
        _dispute(id, client);
        assertEq(weir.streams(id).rate, RATE);
        _solvent(token);
    }
}
