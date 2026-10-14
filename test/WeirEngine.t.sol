// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, IERC20, IIntake} from "./WeirTestBase.sol";
import {MockToken, NoReturnToken, FalseReturnToken} from "./mocks/MockToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleText} from "../src/libraries/OracleText.sol";

contract WeirEngineTest is WeirTestBase {
    function test_createAccrueWithdrawAndRefundSixDecimals() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        vm.warp(vm.getBlockTimestamp() + 40);
        assertEq(weir.streamed(id), 40e6);
        vm.prank(recipient);
        weir.withdraw(id, 30e6);
        assertEq(weir.withdrawable(id), 10e6);
        vm.prank(client);
        weir.refund(id, 500e6);
        assertEq(weir.refundable(id), 460e6);
        _solvent(token);
    }

    function test_exhaustionDepositDoesNotBackfill() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(weir.streamed(id), AMOUNT);
        vm.prank(recipient);
        weir.withdrawMax(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(client);
        weir.deposit(id, 100e6);
        assertEq(weir.withdrawable(id), 0);
        assertEq(weir.refundable(id), 100e6);
        vm.warp(vm.getBlockTimestamp() + 7);
        assertEq(weir.withdrawable(id), 7e6);
        _solvent(token);
    }

    function test_pauseRestartAdjustSnapshotBeforeChangingRate() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(client);
        weir.pause(id);
        assertEq(weir.streams(id).pausedRate, RATE);
        vm.warp(vm.getBlockTimestamp() + 1000);
        assertEq(weir.streamed(id), 10e6);
        vm.prank(client);
        weir.restart(id, 2e6);
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(client);
        weir.adjust(id, 3e6);
        vm.warp(vm.getBlockTimestamp() + 4);
        assertEq(weir.streamed(id), 32e6);
        _solvent(token);
    }

    function test_refundMaxKeepsEarnedFundsAndDepositResumes() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(client);
        weir.refundMax(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(weir.streamed(id), 10e6);
        vm.prank(client);
        weir.deposit(id, 20e6);
        assertEq(weir.withdrawable(id), 10e6);
        vm.warp(vm.getBlockTimestamp() + 3);
        assertEq(weir.withdrawable(id), 13e6);
        _solvent(token);
    }

    function test_voidLeavesRecipientClaimAndStopsAccrual() public {
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 17);
        vm.prank(client);
        weir.void(id);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Closed));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(weir.withdrawable(id), 17e6);
        assertEq(weir.refundable(id), 0);
        vm.prank(recipient);
        weir.withdrawMax(id);
        _solvent(token);
        assertEq(token.balanceOf(address(weir)), 0);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Closed));
        vm.prank(client);
        weir.deposit(id, 1);
    }

    function test_holdGateOnlyAppliesToCreateAndDispute() public {
        gate.burn(client, 1);
        vm.expectRevert(Weir.HoldRequired.selector);
        _createUnaccepted(token, RATE, AMOUNT);
        gate.mint(client, 1);
        uint256 id = _create();
        gate.burn(client, HOLD);
        assertFalse(weir.canUse(client));
        vm.startPrank(client);
        weir.deposit(id, 1);
        weir.pause(id);
        weir.restart(id, RATE);
        weir.adjust(id, 2e6);
        weir.refund(id, 1);
        vm.expectRevert(Weir.HoldRequired.selector);
        weir.dispute(id, "review");
        weir.void(id);
        vm.stopPrank();
    }

    function test_createValidationAndMissingTokenCode() public {
        vm.startPrank(client);
        vm.expectRevert(Weir.InvalidRecipient.selector);
        weir.createStream(client, token, RATE, AMOUNT, TERMS, URI, 0);
        vm.expectRevert(Weir.InvalidRecipient.selector);
        weir.createStream(address(0), token, RATE, AMOUNT, TERMS, URI, 0);
        vm.expectRevert(Weir.ZeroRate.selector);
        weir.createStream(recipient, token, 0, AMOUNT, TERMS, URI, 0);
        vm.expectRevert(Weir.ZeroAmount.selector);
        weir.createStream(recipient, token, RATE, 0, TERMS, URI, 0);
        vm.expectRevert(Weir.ZeroTermsHash.selector);
        weir.createStream(recipient, token, RATE, AMOUNT, 0, URI, 0);
        vm.expectRevert(Weir.ZeroAddress.selector);
        weir.createStream(recipient, IERC20(address(0)), RATE, AMOUNT, TERMS, URI, 0);
        vm.expectRevert();
        weir.createStream(recipient, IERC20(stranger), RATE, AMOUNT, TERMS, URI, 0);
        vm.stopPrank();
        assertEq(weir.streamCount(), 0);
    }

    function test_accessControlAndAvailabilityBounds() public {
        uint256 id = _create();
        vm.startPrank(stranger);
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
        vm.expectRevert(Weir.NotRecipient.selector);
        weir.withdrawMax(id);
        vm.expectRevert(Weir.NotRecipient.selector);
        weir.withdraw(id, 0);
        vm.expectRevert(Weir.NotParty.selector);
        weir.dispute(id, "review");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(Weir.AmountExceedsAvailable.selector, RATE + 1, RATE));
        vm.prank(recipient);
        weir.withdraw(id, RATE + 1);
        vm.expectRevert(abi.encodeWithSelector(Weir.AmountExceedsAvailable.selector, AMOUNT, AMOUNT - RATE));
        vm.prank(client);
        weir.refund(id, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Weir.UnknownStream.selector, 999));
        weir.withdrawMax(999);
    }

    function test_pauseAndRestartRejectInvalidRatesAndStates() public {
        uint256 id = _create();
        vm.startPrank(client);
        vm.expectRevert(Weir.NotPaused.selector);
        weir.restart(id, RATE);
        vm.expectRevert(Weir.ZeroRate.selector);
        weir.adjust(id, 0);
        vm.expectRevert(Weir.ZeroAmount.selector);
        weir.deposit(id, 0);
        weir.pause(id);
        vm.expectRevert(Weir.AlreadyPaused.selector);
        weir.pause(id);
        vm.expectRevert(Weir.AlreadyPaused.selector);
        weir.adjust(id, RATE);
        vm.expectRevert(Weir.ZeroRate.selector);
        weir.restart(id, 0);
        vm.stopPrank();
    }

    function test_tokenTaxRejectedOnIncomingAndOutgoing() public {
        token.setTax(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(token)));
        _createUnaccepted(token, RATE, AMOUNT);
        assertEq(weir.streamCount(), 0);
        token.setTax(false);
        uint256 id = _create();
        vm.warp(vm.getBlockTimestamp() + 10);
        token.setTax(true);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(token)));
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(weir.streams(id).withdrawn, 0);
        vm.expectRevert(abi.encodeWithSelector(Weir.TransferMismatch.selector, address(token)));
        vm.prank(client);
        weir.deposit(id, 100);
        assertEq(weir.streams(id).balance, AMOUNT);
        _solvent(token);
    }

    function test_noReturnERC20WorksAndFalseReturnReverts() public {
        NoReturnToken legacy = new NoReturnToken();
        legacy.mint(client, AMOUNT);
        vm.prank(client);
        legacy.approve(address(weir), AMOUNT);
        uint256 id = _createWith(IERC20(address(legacy)), RATE, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(client);
        weir.void(id);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(legacy.balanceOf(client), AMOUNT - 2 * RATE);
        assertEq(legacy.balanceOf(recipient), 2 * RATE);
        FalseReturnToken bad = new FalseReturnToken();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        _createUnaccepted(IERC20(address(bad)), RATE, AMOUNT);
    }

    function test_reentrancyBlockedAcrossIncomingAndOutgoingPaths() public {
        token.setHook(address(weir), abi.encodeCall(weir.sponsor, (1)));
        uint256 id = _create();
        assertFalse(token.hookSucceeded());
        assertEq(token.hookError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.warp(vm.getBlockTimestamp() + 5);
        token.setHook(address(weir), abi.encodeCall(weir.pause, (id)));
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertFalse(token.hookSucceeded());
        assertEq(token.hookError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _solvent(token);
    }

    function test_constructorIsFlatImmutableAndCallsNoDependencies() public {
        Weir isolated = new Weir(IERC20(client), IERC20(recipient), IIntake(stranger), client, 7 days, HOLD);
        assertEq(address(isolated.weir()), client);
        assertEq(address(isolated.imd()), recipient);
        assertEq(address(isolated.intake()), stranger);
        assertEq(isolated.oracleSigner(), client);
        assertEq(isolated.disputeTimeout(), 7 days);
        assertEq(isolated.minHold(), HOLD);
        vm.expectRevert(Weir.InvalidConfiguration.selector);
        new Weir(gate, imd, intake, client, 0, HOLD);
        vm.expectRevert(Weir.InvalidConfiguration.selector);
        new Weir(gate, imd, intake, client, 1, 0);
        vm.expectRevert(Weir.ZeroAddress.selector);
        new Weir(IERC20(address(0)), imd, intake, client, 1, HOLD);
    }

    function test_extremeTimestampCapsWithoutOverflow() public {
        uint256 id = _createWith(token, type(uint128).max, AMOUNT);
        vm.warp(type(uint256).max);
        assertEq(weir.streamed(id), AMOUNT);
        vm.prank(recipient);
        weir.withdrawMax(id);
        _solvent(token);
    }

    function test_fullWidthBalanceAndBondQuoteDoNotOverflow() public {
        MockToken large = new MockToken("large", 0);
        large.mint(client, type(uint256).max);
        vm.prank(client);
        large.approve(address(weir), type(uint256).max);
        uint256 id = _createWith(large, type(uint128).max, 1);
        vm.prank(client);
        weir.deposit(id, type(uint256).max - 1);
        uint256 expectedBond = type(uint256).max / 10_000 * 500 + type(uint256).max % 10_000 * 500 / 10_000;
        assertEq(weir.bondFor(id, client), expectedBond);
        vm.warp(type(uint256).max);
        assertEq(weir.streamed(id), type(uint256).max);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(large.balanceOf(recipient), type(uint256).max);
        _solvent(large);
    }

    function test_runtimeFitsLaunchAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(weir).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden escape opcode");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_snapshotConservation(
        uint128 principal,
        uint128 firstRate,
        uint128 secondRate,
        uint32 dt,
        uint32 dt2
    ) public {
        principal = uint128(bound(principal, 1, 1e24));
        firstRate = uint128(bound(firstRate, 1, 1e18));
        secondRate = uint128(bound(secondRate, 1, 1e18));
        uint256 id = _createWith(token, firstRate, principal);
        vm.warp(vm.getBlockTimestamp() + dt);
        uint256 earned = uint256(firstRate) * dt;
        if (earned > principal) earned = principal;
        vm.prank(client);
        weir.adjust(id, secondRate);
        vm.warp(vm.getBlockTimestamp() + dt2);
        earned += uint256(secondRate) * dt2;
        if (earned > principal) earned = principal;
        assertEq(weir.streamed(id), earned);
        uint256 clientBefore = token.balanceOf(client);
        uint256 recipientBefore = token.balanceOf(recipient);
        vm.prank(client);
        weir.void(id);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(token.balanceOf(client) - clientBefore + token.balanceOf(recipient) - recipientBefore, principal);
        _solvent(token);
    }
}
