// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, IERC20, OracleAttestation} from "./WeirTestBase.sol";
import {ReentrantToken, FeeOnTransferToken, FalseReturningToken} from "./mocks/ReentrantToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Hold gate, bond tiers, accrual, the state matrix, dispute parties, the court fund and the body.
contract WeirCoverageEngineTest is WeirTestBase {
    // ------------------------------------------------------------------ hold gate

    function test_holdGateBelowAtAboveForCreate() public {
        gate.burn(client, 1);
        assertFalse(weir.canUse(client));
        vm.expectRevert(Weir.HoldRequired.selector);
        _createUnaccepted(token, RATE, AMOUNT);
        assertEq(weir.streamCount(), 0);
        gate.mint(client, 1);
        assertTrue(weir.canUse(client));
        assertEq(_create(), 1);
        gate.mint(client, 1);
        assertEq(_create(), 2);
    }

    function test_holdGateBelowAtAboveForDisputeByEachParty() public {
        uint256 id = _create();
        gate.burn(client, 1);
        vm.prank(client);
        vm.expectRevert(Weir.HoldRequired.selector);
        weir.dispute(id, "below");
        gate.burn(recipient, HOLD);
        vm.prank(recipient);
        vm.expectRevert(Weir.HoldRequired.selector);
        weir.dispute(id, "zero");
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        gate.mint(client, 1);
        _dispute(id, client);
        uint256 other = _create();
        gate.mint(recipient, HOLD + 1);
        _dispute(other, recipient);
        assertEq(uint256(weir.streams(other).state), uint256(Weir.State.Disputed));
    }

    function test_holdGateIsNotAppliedToTheRecipientOnCreate() public {
        gate.burn(recipient, HOLD);
        uint256 id = _create();
        assertEq(weir.streams(id).recipient, recipient);
    }

    // ------------------------------------------------------------------ bond tiers

    function test_bondForEveryTierBoundary() public {
        uint256 id = _create();
        uint256 stakeNow = weir.stake(id);
        assertEq(stakeNow, AMOUNT);
        uint256[8] memory holdings = [
            uint256(0),
            100_000e18 - 1,
            100_000e18,
            1_000_000e18 - 1,
            1_000_000e18,
            10_000_000e18 - 1,
            10_000_000e18,
            type(uint128).max
        ];
        uint16[8] memory bps = [uint16(500), 500, 250, 250, 100, 100, 0, 0];
        for (uint256 i; i < holdings.length; ++i) {
            _setHolding(stranger, holdings[i]);
            assertEq(weir.tierBps(stranger), bps[i], "tier");
            assertEq(weir.bondFor(id, stranger), stakeNow * bps[i] / 10_000, "bond");
        }
    }

    function test_bondForTracksStakeNotBalance() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(weir.bondFor(id, client), AMOUNT * 500 / 10_000);
        vm.prank(recipient);
        weir.withdraw(id, 100e6);
        assertEq(weir.stake(id), AMOUNT - 100e6);
        assertEq(weir.bondFor(id, client), (AMOUNT - 100e6) * 500 / 10_000);
        vm.prank(client);
        weir.refund(id, 400e6);
        assertEq(weir.bondFor(id, client), (AMOUNT - 500e6) * 500 / 10_000);
        assertEq(weir.bondFor(id, stranger), weir.bondFor(id, client));
        assertEq(weir.bondFor(999, client), 0);
    }

    function test_bondPulledAtEachTierAndHeldOutsideStreamAccounting() public {
        uint256[4] memory holdings = [uint256(HOLD), 100_000e18, 1_000_000e18, 10_000_000e18];
        uint16[4] memory bps = [uint16(500), 250, 100, 0];
        for (uint256 i; i < holdings.length; ++i) {
            uint256 id = _create();
            _setHolding(recipient, holdings[i]);
            uint256 expectedBond = uint256(AMOUNT) * bps[i] / 10_000;
            uint256 beforeRecipient = token.balanceOf(recipient);
            uint256 beforeWeir = token.balanceOf(address(weir));
            uint256 escrowBefore = weir.escrowed(address(token));
            _dispute(id, recipient);
            Weir.Stream memory s = weir.streams(id);
            assertEq(s.bond, expectedBond);
            assertEq(beforeRecipient - token.balanceOf(recipient), expectedBond);
            assertEq(token.balanceOf(address(weir)) - beforeWeir, expectedBond);
            assertEq(weir.escrowed(address(token)) - escrowBefore, expectedBond);
            // The bond is not part of the stream.
            assertEq(s.balance, AMOUNT);
            assertEq(weir.stake(id), AMOUNT);
            assertEq(weir.refundable(id), AMOUNT);
            assertEq(weir.withdrawable(id), 0);
            // The original bond is kept even if the disputer's tier changes afterwards.
            _setHolding(recipient, 0);
            assertEq(weir.streams(id).bond, expectedBond);
        }
        _solvent(token);
    }

    // ------------------------------------------------------------------ accrual

    function test_accrualAcrossDepositPauseRestartAdjustRefundWithWarps() public {
        uint256 id = _create();
        _expectBuckets(id, 0, 0, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 100);
        _expectBuckets(id, 100e6, 100e6, AMOUNT - 100e6);

        vm.prank(client);
        weir.deposit(id, 500e6);
        _expectBuckets(id, 100e6, 100e6, AMOUNT + 400e6);
        vm.warp(vm.getBlockTimestamp() + 50);
        _expectBuckets(id, 150e6, 150e6, AMOUNT + 350e6);

        vm.prank(client);
        weir.pause(id);
        vm.warp(vm.getBlockTimestamp() + 10_000);
        _expectBuckets(id, 150e6, 150e6, AMOUNT + 350e6);
        assertEq(weir.streams(id).pausedRate, RATE);

        vm.prank(client);
        weir.restart(id, 2e6);
        _expectBuckets(id, 150e6, 150e6, AMOUNT + 350e6);
        vm.warp(vm.getBlockTimestamp() + 25);
        _expectBuckets(id, 200e6, 200e6, AMOUNT + 300e6);

        vm.prank(client);
        weir.adjust(id, 4e6);
        vm.warp(vm.getBlockTimestamp() + 25);
        _expectBuckets(id, 300e6, 300e6, AMOUNT + 200e6);

        vm.prank(recipient);
        weir.withdraw(id, 120e6);
        _expectBuckets(id, 300e6, 180e6, AMOUNT + 200e6);

        vm.prank(client);
        weir.refund(id, 1_000e6);
        _expectBuckets(id, 300e6, 180e6, 200e6);
        vm.warp(vm.getBlockTimestamp() + 10);
        _expectBuckets(id, 340e6, 220e6, 160e6);

        vm.prank(client);
        weir.refundMax(id);
        _expectBuckets(id, 340e6, 220e6, 0);
        vm.warp(vm.getBlockTimestamp() + 10);
        _expectBuckets(id, 340e6, 220e6, 0);
        _conserved(id);
        _solvent(token);
    }

    function test_accrualExhaustionThenLaterDepositResumesWithoutBackfill() public {
        uint256 id = _createWith(token, 10e6, 100e6);
        vm.warp(vm.getBlockTimestamp() + 7);
        _expectBuckets(id, 70e6, 70e6, 30e6);
        vm.warp(vm.getBlockTimestamp() + 3);
        _expectBuckets(id, 100e6, 100e6, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _expectBuckets(id, 100e6, 100e6, 0);
        vm.prank(client);
        weir.deposit(id, 50e6);
        // Nothing of the gap is backfilled: the new money starts streaming from the deposit.
        _expectBuckets(id, 100e6, 100e6, 50e6);
        vm.warp(vm.getBlockTimestamp() + 2);
        _expectBuckets(id, 120e6, 120e6, 30e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _expectBuckets(id, 150e6, 150e6, 0);
        vm.prank(recipient);
        weir.withdrawMax(id);
        _expectBuckets(id, 150e6, 0, 0);
        _solvent(token);
    }

    function test_accrualAcrossVoid() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 30);
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        weir.void(id);
        assertEq(token.balanceOf(client) - before, AMOUNT - 30e6);
        _expectBuckets(id, 30e6, 30e6, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _expectBuckets(id, 30e6, 30e6, 0);
        vm.prank(recipient);
        weir.withdraw(id, 10e6);
        _expectBuckets(id, 30e6, 20e6, 0);
        vm.prank(recipient);
        weir.withdrawMax(id);
        _expectBuckets(id, 30e6, 0, 0);
        assertEq(weir.stake(id), 0);
        assertEq(token.balanceOf(address(weir)), 0);
    }

    function test_accrualFrozenDuringDisputeAndRuledThenResumesOnlyAfterAcceptedEnforce() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, client);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _expectBuckets(id, 10e6, 10e6, AMOUNT - 10e6);
        _rule(id, true);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _expectBuckets(id, 10e6, 10e6, AMOUNT - 10e6);
        weir.enforce(id);
        _expectBuckets(id, 10e6, 10e6, AMOUNT - 10e6);
        vm.warp(vm.getBlockTimestamp() + 5);
        _expectBuckets(id, 15e6, 15e6, AMOUNT - 15e6);
    }

    /// forge-config: default.fuzz.runs = 600
    function testFuzz_accrualNeverExceedsBalanceOrGoesBackwards(uint128 rate, uint128 amount, uint32 dt1, uint32 dt2)
        public
    {
        rate = uint128(bound(rate, 1, 1e20));
        amount = uint128(bound(amount, 1, 1e30));
        uint256 id = _createWith(token, rate, amount);
        vm.warp(vm.getBlockTimestamp() + dt1);
        uint256 first = weir.streamed(id);
        assertEq(first, Math_min(uint256(rate) * dt1, amount));
        vm.warp(vm.getBlockTimestamp() + dt2);
        uint256 second = weir.streamed(id);
        assertGe(second, first);
        assertLe(second, amount);
        _conserved(id);
    }

    // ------------------------------------------------------------------ state matrix

    function test_unknownStreamRefusesEveryFunction() public {
        bytes memory err = abi.encodeWithSelector(Weir.UnknownStream.selector, 7);
        vm.startPrank(client);
        vm.expectRevert(err);
        weir.deposit(7, 1);
        vm.expectRevert(err);
        weir.pause(7);
        vm.expectRevert(err);
        weir.restart(7, 1);
        vm.expectRevert(err);
        weir.adjust(7, 1);
        vm.expectRevert(err);
        weir.refund(7, 1);
        vm.expectRevert(err);
        weir.refundMax(7);
        vm.expectRevert(err);
        weir.void(7);
        vm.expectRevert(err);
        weir.withdraw(7, 1);
        vm.expectRevert(err);
        weir.withdrawMax(7);
        vm.expectRevert(err);
        weir.dispute(7, "x");
        vm.expectRevert(err);
        weir.enforce(7);
        vm.expectRevert(err);
        weir.expireDispute(7);
        vm.expectRevert(err);
        weir.questionFor(7, client, "x");
        vm.expectRevert(err);
        weir.expectedBody(7, client, "x");
        vm.stopPrank();
        assertEq(uint256(weir.streams(7).state), uint256(Weir.State.None));
    }

    function test_activeStateAllowsEveryClientAndRecipientFunction() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.startPrank(client);
        weir.deposit(id, 1e6);
        weir.pause(id);
        weir.restart(id, RATE);
        weir.adjust(id, 2 * RATE);
        weir.refund(id, 1e6);
        vm.stopPrank();
        vm.startPrank(recipient);
        weir.withdraw(id, 1e6);
        weir.withdrawMax(id);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Active));
        weir.enforce(id);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Active));
        weir.expireDispute(id);
        vm.prank(client);
        weir.refundMax(id);
        vm.prank(client);
        weir.void(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
    }

    function test_disputedStateMatrix() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, recipient);
        _refuseClientRateRefundVoidAndDispute(id, Weir.State.Disputed);
        vm.prank(client);
        weir.deposit(id, 5e6);
        assertEq(weir.streams(id).balance, AMOUNT + 5e6);
        vm.prank(recipient);
        weir.withdraw(id, 4e6);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(weir.streams(id).withdrawn, 10e6);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Disputed));
        weir.enforce(id);
        vm.expectRevert(Weir.DisputeNotExpired.selector);
        weir.expireDispute(id);
        _solvent(token);
    }

    function test_ruledStateMatrix() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, client);
        _rule(id, true);
        _refuseClientRateRefundVoidAndDispute(id, Weir.State.Ruled);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.deposit(id, 1);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.expireDispute(id);
        vm.prank(recipient);
        weir.withdraw(id, 3e6);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(weir.streams(id).withdrawn, 10e6);
        vm.prank(stranger);
        weir.enforce(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
    }

    function test_closedStateMatrix() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(client);
        weir.void(id);
        _refuseClientRateRefundVoidAndDispute(id, Weir.State.Closed);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        weir.deposit(id, 1);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        weir.enforce(id);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        weir.expireDispute(id);
        vm.prank(recipient);
        weir.withdraw(id, 1e6);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(token.balanceOf(address(weir)), 0);
        // A closed stream never reopens: the recipient has nothing more to withdraw and no action reopens it.
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Weir.AmountExceedsAvailable.selector, 1, 0));
        weir.withdraw(id, 1);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
    }

    function test_wrongCallerRefusedInEveryState() public {
        uint256 id = _create();
        _refuseWrongCallers(id, Weir.State.Active);
        _dispute(id, client);
        _refuseWrongCallers(id, Weir.State.Disputed);
        _rule(id, false);
        _refuseWrongCallers(id, Weir.State.Ruled);
        weir.enforce(id);
        _refuseWrongCallers(id, Weir.State.Closed);
    }

    // ------------------------------------------------------------------ dispute parties and stake

    function test_disputeByClientByRecipientAndByStranger() public {
        uint256 a = _create();
        uint256 b = _create();
        vm.prank(stranger);
        vm.expectRevert(Weir.NotParty.selector);
        weir.dispute(a, "stranger");
        _setHolding(stranger, 10_000_000e18);
        vm.prank(stranger);
        vm.expectRevert(Weir.NotParty.selector);
        weir.dispute(a, "stranger with a large holding");
        _dispute(a, client);
        assertEq(weir.streams(a).disputer, client);
        _dispute(b, recipient);
        assertEq(weir.streams(b).disputer, recipient);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Disputed));
        weir.dispute(a, "second");
    }

    function test_disputeWithZeroStakeRefusedForBothParties() public {
        uint256 id = _createWith(token, 10e6, 10e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(weir.stake(id), 0);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        vm.prank(client);
        vm.expectRevert(Weir.NoStake.selector);
        weir.dispute(id, "nothing left");
        vm.prank(recipient);
        vm.expectRevert(Weir.NoStake.selector);
        weir.dispute(id, "nothing left");
        // Stake that is entirely earned but not yet withdrawn can still be disputed.
        uint256 other = _createWith(token, 10e6, 10e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(weir.refundable(other), 0);
        _dispute(other, client);
        assertEq(weir.streams(other).bond, 10e6 * 500 / 10_000);
    }

    function test_disputeChecksHoldBeforeStakeAndPartyBeforeHold() public {
        uint256 id = _create();
        gate.burn(stranger, HOLD);
        vm.prank(stranger);
        vm.expectRevert(Weir.NotParty.selector);
        weir.dispute(id, "x");
    }

    // ------------------------------------------------------------------ court fund

    function test_courtFundUsedWhenAtLeastHalfIMDElseCallerPays() public {
        uint256 a = _create();
        uint256 b = _create();
        uint256 c = _create();
        vm.prank(stranger);
        weir.sponsor(FEE - 1);
        assertEq(weir.courtFund(), FEE - 1);
        uint256 before = imd.balanceOf(client);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(a, keccak256(abi.encode(address(intake), uint256(1))), client, AMOUNT / 20, false);
        _dispute(a, client);
        assertEq(before - imd.balanceOf(client), FEE, "caller pays below the price");
        assertEq(weir.courtFund(), FEE - 1);

        vm.prank(stranger);
        weir.sponsor(1);
        assertEq(weir.courtFund(), FEE);
        before = imd.balanceOf(recipient);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Disputed(b, keccak256(abi.encode(address(intake), uint256(2))), recipient, AMOUNT / 20, true);
        _dispute(b, recipient);
        assertEq(before - imd.balanceOf(recipient), 0, "fund pays exactly at the price");
        assertEq(weir.courtFund(), 0);

        vm.prank(stranger);
        weir.sponsor(3 * FEE);
        before = imd.balanceOf(client);
        _dispute(c, client);
        assertEq(before - imd.balanceOf(client), 0, "fund pays above the price");
        assertEq(weir.courtFund(), 2 * FEE);
        assertEq(imd.balanceOf(address(intake)), 3 * FEE);
        _solvent(imd);
    }

    function test_courtFundPayerHasNoIMDAndNoApprovalOnceFunded() public {
        uint256 id = _create();
        vm.prank(stranger);
        weir.sponsor(FEE);
        imd.burn(client, imd.balanceOf(client));
        vm.prank(client);
        imd.approve(address(weir), 0);
        _dispute(id, client);
        assertEq(weir.courtFund(), 0);
        assertEq(imd.balanceOf(address(intake)), FEE);
    }

    function test_sponsorZeroRefusedAndFundOnlyLeavesThroughTheIntake() public {
        vm.prank(stranger);
        vm.expectRevert(Weir.ZeroAmount.selector);
        weir.sponsor(0);
        vm.prank(stranger);
        weir.sponsor(10e18);
        assertEq(weir.courtFund(), 10e18);
        assertEq(weir.escrowed(address(imd)), 0);
        uint256 id = _create();
        _dispute(id, client);
        assertEq(weir.courtFund(), 10e18 - FEE);
        assertEq(imd.balanceOf(address(weir)), 10e18 - FEE);
        _rule(id, false);
        weir.enforce(id);
        assertEq(imd.balanceOf(address(weir)), 10e18 - FEE, "ruling never touches the fund");
    }

    // ------------------------------------------------------------------ body

    function test_bodyBytesEqualExpectedBodyForBothPartiesAndJobId() public {
        vm.prank(client);
        uint256 id = weir.createStream(recipient, token, RATE, AMOUNT, TERMS, URI, keccak256("job-7"));
        bytes memory expectedClient = weir.expectedBody(id, client, "late");
        bytes memory expectedRecipient = weir.expectedBody(id, recipient, "done");
        assertNotEq(keccak256(expectedClient), keccak256(expectedRecipient));
        vm.prank(client);
        weir.dispute(id, "late");
        assertEq(intake.lastBody(), expectedClient);
        assertEq(weir.questionOf(id), keccak256(bytes(weir.questionFor(id, client, "late"))));
        uint256 other = _create();
        bytes memory expectedOther = weir.expectedBody(other, recipient, "done");
        vm.prank(recipient);
        weir.dispute(other, "done");
        assertEq(intake.lastBody(), expectedOther);
        assertEq(intake.lastAction(), weir.ORACLE_ACTION());
        assertEq(intake.lastAmount(), weir.ORACLE_PRICE());
    }

    function test_bodyChangesWithBlockNumberAndStrangerCannotPreview() public {
        uint256 id = _create();
        bytes memory before = weir.expectedBody(id, client, "n");
        vm.roll(vm.getBlockNumber() + 1);
        assertNotEq(keccak256(before), keccak256(weir.expectedBody(id, client, "n")));
        vm.expectRevert(Weir.NotParty.selector);
        weir.expectedBody(id, stranger, "n");
        vm.prank(stranger);
        vm.expectRevert(Weir.NotParty.selector);
        weir.expectedBody(id, "n");
    }

    // ------------------------------------------------------------------ enforce and records

    function test_acceptedEnforceRestartsAndRoutesBondForClientDisputer() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, client);
        uint256 bond = weir.streams(id).bond;
        assertGt(bond, 0);
        _rule(id, true);
        uint256 clientBefore = token.balanceOf(client);
        uint256 recipientBefore = token.balanceOf(recipient);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Enforced(id, true, recipient, bond);
        vm.prank(stranger);
        weir.enforce(id);
        assertEq(token.balanceOf(recipient) - recipientBefore, bond, "loser's bond goes to the recipient");
        assertEq(token.balanceOf(client), clientBefore);
        Weir.Stream memory s = weir.streams(id);
        assertEq(uint256(s.state), uint256(Weir.State.Active));
        assertEq(s.rate, RATE);
        assertEq(s.pausedRate, 0);
        assertEq(s.bond, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(weir.streamed(id), 11e6);
        (, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientLost, 1);
        assertEq(recipientWon, 1);
        assertEq(clientRaised, 1);
        assertEq(recipientRaised, 0);
        _solvent(token);
    }

    function test_acceptedEnforceReturnsBondForRecipientDisputer() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, recipient);
        uint256 bond = weir.streams(id).bond;
        _rule(id, true);
        uint256 clientBefore = token.balanceOf(client);
        uint256 recipientBefore = token.balanceOf(recipient);
        weir.enforce(id);
        assertEq(token.balanceOf(recipient) - recipientBefore, bond, "winner's bond returns");
        assertEq(token.balanceOf(client), clientBefore);
        assertEq(weir.streams(id).rate, RATE);
        (, uint32 clientLost,,, uint32 clientRaised) = weir.records(client);
        (,, uint32 recipientWon,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientLost, 1);
        assertEq(recipientWon, 1);
        assertEq(clientRaised, 0);
        assertEq(recipientRaised, 1);
    }

    function test_rejectedEnforceRefundsExactlyRefundableForClientDisputer() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, client);
        uint256 bond = weir.streams(id).bond;
        vm.prank(client);
        weir.deposit(id, 100e6);
        vm.prank(recipient);
        weir.withdraw(id, 4e6);
        _rule(id, false);
        uint256 refundable = weir.refundable(id);
        assertEq(refundable, AMOUNT + 100e6 - 10e6);
        uint256 clientBefore = token.balanceOf(client);
        uint256 recipientBefore = token.balanceOf(recipient);
        vm.expectEmit(true, true, true, true, address(weir));
        emit Weir.Enforced(id, false, client, bond);
        weir.enforce(id);
        assertEq(token.balanceOf(client) - clientBefore, refundable + bond);
        assertEq(token.balanceOf(recipient), recipientBefore);
        Weir.Stream memory s = weir.streams(id);
        assertEq(uint256(s.state), uint256(Weir.State.Closed));
        assertEq(s.rate, 0);
        assertEq(s.pausedRate, 0);
        assertEq(s.bond, 0);
        assertEq(weir.refundable(id), 0);
        assertEq(weir.withdrawable(id), 6e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(weir.withdrawable(id), 6e6, "closed stream does not accrue");
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(token.balanceOf(recipient) - recipientBefore, 6e6, "the recipient still withdraws what was earned");
        assertEq(token.balanceOf(address(weir)), 0);
        (uint32 clientWon,,,, uint32 clientRaised) = weir.records(client);
        (,,, uint32 recipientLost, uint32 recipientRaised) = weir.records(recipient);
        assertEq(clientWon, 1);
        assertEq(recipientLost, 1);
        assertEq(clientRaised, 1);
        assertEq(recipientRaised, 0);
        _solvent(token);
    }

    function test_rejectedEnforceSendsRecipientDisputerBondToClient() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        _dispute(id, recipient);
        uint256 bond = weir.streams(id).bond;
        _rule(id, false);
        uint256 refundable = weir.refundable(id);
        uint256 clientBefore = token.balanceOf(client);
        uint256 recipientBefore = token.balanceOf(recipient);
        weir.enforce(id);
        assertEq(token.balanceOf(client) - clientBefore, refundable + bond);
        assertEq(token.balanceOf(recipient), recipientBefore);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(token.balanceOf(recipient) - recipientBefore, 10e6);
        (,,,, uint32 recipientRaised) = weir.records(recipient);
        assertEq(recipientRaised, 1);
        _solvent(token);
    }

    function test_recordsAccumulateAcrossRulingsAndStreams() public {
        uint256 a = _create();
        uint256 b = _create();
        _dispute(a, client);
        _rule(a, true);
        weir.enforce(a);
        _dispute(b, recipient);
        _rule(b, false);
        weir.enforce(b);
        _dispute(a, recipient);
        _rule(a, true);
        (uint32 cw, uint32 cl, uint32 rw, uint32 rl, uint32 raised) = weir.records(client);
        assertEq(cw, 1);
        assertEq(cl, 2);
        assertEq(rw, 0);
        assertEq(rl, 0);
        assertEq(raised, 1);
        (cw, cl, rw, rl, raised) = weir.records(recipient);
        assertEq(cw, 0);
        assertEq(cl, 0);
        assertEq(rw, 2);
        assertEq(rl, 1);
        assertEq(raised, 2);
        (cw, cl, rw, rl, raised) = weir.records(stranger);
        assertEq(cw + cl + rw + rl + raised, 0);
    }

    // ------------------------------------------------------------------ malicious tokens

    function test_feeOnTransferTokenCannotEnterAStream() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        taxed.mint(client, 1e12);
        vm.prank(client);
        taxed.approve(address(weir), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(taxed)));
        _createUnaccepted(IERC20(address(taxed)), RATE, AMOUNT);
        assertEq(taxed.balanceOf(address(weir)), 0);
        assertEq(weir.streamCount(), 0);
    }

    function test_falseReturningTokenIsRefused() public {
        FalseReturningToken bad = new FalseReturningToken();
        bad.mint(client, 1e12);
        vm.prank(client);
        bad.approve(address(weir), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        _createUnaccepted(IERC20(address(bad)), RATE, AMOUNT);
        assertEq(bad.balanceOf(address(weir)), 0);
        assertEq(bad.balanceOf(client), 1e12);
    }

    function test_reentrantTokenIsBlockedOnEveryPath() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(client, 1e12);
        evil.mint(recipient, 1e12);
        vm.prank(client);
        evil.approve(address(weir), type(uint256).max);
        vm.prank(recipient);
        evil.approve(address(weir), type(uint256).max);

        // Re-enter createStream from the first pull.
        evil.arm(address(weir), abi.encodeCall(weir.sponsor, (1)));
        uint256 id = _createWith(IERC20(address(evil)), RATE, AMOUNT);
        _assertReentryRefused(evil);

        vm.warp(vm.getBlockTimestamp() + 10);
        evil.arm(address(weir), abi.encodeCall(weir.withdrawMax, (id)));
        vm.prank(recipient);
        weir.withdraw(id, 1e6);
        _assertReentryRefused(evil);
        assertEq(weir.streams(id).withdrawn, 1e6);

        evil.arm(address(weir), abi.encodeCall(weir.refundMax, (id)));
        vm.prank(client);
        weir.refund(id, 1e6);
        _assertReentryRefused(evil);

        evil.arm(address(weir), abi.encodeCall(weir.deposit, (id, 1)));
        vm.prank(client);
        weir.deposit(id, 5e6);
        _assertReentryRefused(evil);

        // The bond pull re-enters dispute and withdraw.
        evil.arm(address(weir), abi.encodeCall(weir.withdrawMax, (id)));
        _dispute(id, recipient);
        _assertReentryRefused(evil);
        _rule(id, false);

        evil.arm(address(weir), abi.encodeCall(weir.enforce, (id)));
        weir.enforce(id);
        _assertReentryRefused(evil);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));

        evil.arm(address(weir), abi.encodeCall(weir.withdrawMax, (id)));
        vm.prank(recipient);
        weir.withdrawMax(id);
        _assertReentryRefused(evil);
        assertEq(evil.attempts(), 7);
        _solvent(IERC20(address(evil)));
    }

    function test_reentrantTokenCannotReenterVoidOrExpireOrFailure() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(client, 1e12);
        vm.prank(client);
        evil.approve(address(weir), type(uint256).max);
        uint256 id = _createWith(IERC20(address(evil)), RATE, AMOUNT);
        bytes32 requestId = _dispute(id, client);
        evil.arm(address(weir), abi.encodeWithSignature("dispute(uint256,string)", id, "again"));
        vm.prank(address(intake));
        weir.onFailure(requestId, 2, "disagreed", 3, 5, "");
        _assertReentryRefused(evil);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        _dispute(id, client);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        evil.arm(address(weir), abi.encodeCall(weir.void, (id)));
        weir.expireDispute(id);
        _assertReentryRefused(evil);
        evil.arm(address(weir), abi.encodeCall(weir.refundMax, (id)));
        vm.prank(client);
        weir.void(id);
        _assertReentryRefused(evil);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
    }

    // ------------------------------------------------------------------ helpers

    function _assertReentryRefused(ReentrantToken evil) private view {
        assertFalse(evil.lastSucceeded(), "re-entrant call must be refused");
        assertEq(evil.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _setHolding(address account, uint256 amount) private {
        uint256 current = gate.balanceOf(account);
        if (amount > current) gate.mint(account, amount - current);
        else gate.burn(account, current - amount);
    }

    function _expectBuckets(
        uint256 id,
        uint256 streamedExpected,
        uint256 withdrawableExpected,
        uint256 refundableExpected
    ) private view {
        assertEq(weir.streamed(id), streamedExpected, "streamed");
        assertEq(weir.withdrawable(id), withdrawableExpected, "withdrawable");
        assertEq(weir.refundable(id), refundableExpected, "refundable");
        _conserved(id);
    }

    function _refuseClientRateRefundVoidAndDispute(uint256 id, Weir.State state) private {
        bytes memory err = abi.encodeWithSelector(Weir.WrongState.selector, state);
        vm.startPrank(client);
        vm.expectRevert(err);
        weir.pause(id);
        vm.expectRevert(err);
        weir.restart(id, RATE);
        vm.expectRevert(err);
        weir.adjust(id, RATE);
        vm.expectRevert(err);
        weir.refund(id, 1);
        vm.expectRevert(err);
        weir.refundMax(id);
        vm.expectRevert(err);
        weir.void(id);
        vm.expectRevert(err);
        weir.dispute(id, "again");
        vm.stopPrank();
        vm.prank(recipient);
        vm.expectRevert(err);
        weir.dispute(id, "again");
    }

    function _refuseWrongCallers(uint256 id, Weir.State state) private {
        vm.startPrank(recipient);
        vm.expectRevert(Weir.NotClient.selector);
        weir.deposit(id, 1);
        vm.expectRevert(Weir.NotClient.selector);
        weir.pause(id);
        vm.expectRevert(Weir.NotClient.selector);
        weir.restart(id, RATE);
        vm.expectRevert(Weir.NotClient.selector);
        weir.adjust(id, RATE);
        vm.expectRevert(Weir.NotClient.selector);
        weir.refund(id, 1);
        vm.expectRevert(Weir.NotClient.selector);
        weir.refundMax(id);
        vm.expectRevert(Weir.NotClient.selector);
        weir.void(id);
        vm.stopPrank();
        vm.startPrank(client);
        vm.expectRevert(Weir.NotRecipient.selector);
        weir.withdraw(id, 1);
        vm.expectRevert(Weir.NotRecipient.selector);
        weir.withdrawMax(id);
        vm.stopPrank();
        vm.startPrank(stranger);
        vm.expectRevert(Weir.NotClient.selector);
        weir.deposit(id, 1);
        vm.expectRevert(Weir.NotRecipient.selector);
        weir.withdrawMax(id);
        // The state check precedes the party check, so a stranger learns only that the stream is not Active.
        if (state == Weir.State.Active) vm.expectRevert(Weir.NotParty.selector);
        else vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, state));
        weir.dispute(id, "x");
        vm.stopPrank();
    }

    function Math_min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
