// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WeirTestBase, Weir, OracleAttestation, IERC20} from "./WeirTestBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Drives Weir through random sequences with loosely bounded inputs. Reverts are swallowed so the fuzzer
/// also exercises refused calls; ghost counters record what crossed the contract boundary.
contract SolvencyHandler is Test {
    uint256 private constant KEY = 0xfeed1234;
    uint256 private constant FEE = 5e17;

    Weir public immutable weir;
    MockToken public immutable token;
    MockToken public immutable imd;
    MockToken public immutable gate;
    MockIntake public immutable intake;

    address[4] public actors;
    uint256 public sponsored;
    uint256 public disputes;
    uint256 public rulings;
    uint256 public closedCount;
    mapping(uint256 => bool) public everClosed;
    mapping(uint256 => uint256) public paidIn;
    mapping(uint256 => uint256) public paidOut;
    mapping(address => uint256) public pulledFrom;
    /// @dev Deferred payouts later collected through claim(), per asset; they belong to no single stream.
    mapping(address => uint256) public claimed;
    uint256 public deferrals;
    uint256 public calls;

    constructor(Weir weir_, MockToken token_, MockToken imd_, MockToken gate_, MockIntake intake_) {
        weir = weir_;
        token = token_;
        imd = imd_;
        gate = gate_;
        intake = intake_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("solvency actor", i)))));
            actors[i] = actor;
            token_.mint(actor, 1e36);
            imd_.mint(actor, 1e36);
            gate_.mint(actor, 10_000e18);
            vm.startPrank(actor);
            token_.approve(address(weir_), type(uint256).max);
            imd_.approve(address(weir_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(uint8 a, uint8 b, uint128 amount, uint128 rate, bool useIMD) public {
        if (weir.streamCount() >= 12) return;
        address client = actors[a % 4];
        address recipient = actors[b % 4];
        amount = uint128(bound(amount, 0, 1e24));
        rate = uint128(bound(rate, 0, 1e18));
        IERC20 asset = useIMD ? imd : token;
        uint256 before = asset.balanceOf(address(weir));
        vm.prank(client);
        try weir.createStream(recipient, asset, rate, amount, keccak256("terms"), "ipfs://terms", 0) returns (
            uint256 id
        ) {
            paidIn[id] += amount;
            assertEq(asset.balanceOf(address(weir)) - before, amount);
        } catch {}
        ++calls;
    }

    function warp(uint32 dt) public {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 10 days));
    }

    function deposit(uint256 seed, uint128 amount) public {
        (uint256 id, Weir.Stream memory s) = _pick(seed);
        if (id == 0) return;
        amount = uint128(bound(amount, 0, 1e24));
        vm.prank(s.client);
        try weir.deposit(id, amount) {
            paidIn[id] += amount;
        } catch {}
        ++calls;
    }

    function rateChange(uint256 seed, uint128 rate, uint8 kind) public {
        (uint256 id, Weir.Stream memory s) = _pick(seed);
        if (id == 0) return;
        rate = uint128(bound(rate, 0, 1e18));
        vm.startPrank(s.client);
        if (kind % 3 == 0) {
            try weir.pause(id) {} catch {}
        } else if (kind % 3 == 1) {
            try weir.restart(id, rate) {} catch {}
        } else {
            try weir.adjust(id, rate) {} catch {}
        }
        vm.stopPrank();
        ++calls;
    }

    function withdraw(uint256 seed, uint256 amount, bool all) public {
        (uint256 id, Weir.Stream memory s) = _pick(seed);
        if (id == 0) return;
        uint256 before = s.token.balanceOf(s.recipient);
        vm.startPrank(s.recipient);
        if (all) {
            try weir.withdrawMax(id) {} catch {}
        } else {
            amount = bound(amount, 0, weir.withdrawable(id) + 1);
            try weir.withdraw(id, amount) {} catch {}
        }
        vm.stopPrank();
        paidOut[id] += s.token.balanceOf(s.recipient) - before;
        ++calls;
    }

    function refund(uint256 seed, uint256 amount, uint8 kind) public {
        (uint256 id, Weir.Stream memory s) = _pick(seed);
        if (id == 0) return;
        uint256 before = s.token.balanceOf(s.client);
        vm.startPrank(s.client);
        if (kind % 3 == 0) {
            try weir.void(id) {} catch {}
        } else if (kind % 3 == 1) {
            try weir.refundMax(id) {} catch {}
        } else {
            amount = bound(amount, 0, weir.refundable(id) + 1);
            try weir.refund(id, amount) {} catch {}
        }
        vm.stopPrank();
        paidOut[id] += s.token.balanceOf(s.client) - before;
        _noteClosed(id);
        ++calls;
    }

    function sponsor(uint8 a, uint128 amount) public {
        amount = uint128(bound(amount, 0, 3e18));
        vm.prank(actors[a % 4]);
        try weir.sponsor(amount) {
            sponsored += amount;
        } catch {}
        ++calls;
    }

    function holdings(uint8 a, uint8 tier) public {
        address actor = actors[a % 4];
        uint256[6] memory amounts =
            [uint256(10_000e18 - 1), 10_000e18, 100_000e18, 1_000_000e18, 10_000_000e18, 10_000e18];
        uint256 desired = amounts[tier % 6];
        uint256 current = gate.balanceOf(actor);
        if (desired > current) gate.mint(actor, desired - current);
        else gate.burn(actor, current - desired);
    }

    function accept(uint256 seed) public {
        (uint256 id, Weir.Stream memory s) = _pick(seed);
        if (id == 0) return;
        vm.prank(s.recipient);
        try weir.accept(id) {} catch {}
        ++calls;
    }

    /// @dev A token blocklist entry makes every transfer to or from the actor revert, so settlement payouts
    /// to it are deferred into claimable amounts instead of blocking the state change.
    function toggleBlock(uint8 a, bool useIMD, bool on) public {
        MockToken asset = useIMD ? imd : token;
        asset.setBlocked(actors[a % 4], on);
        ++calls;
    }

    function claim(uint8 a, bool useIMD) public {
        address actor = actors[a % 4];
        MockToken asset = useIMD ? imd : token;
        uint256 owed = weir.claimable(address(asset), actor);
        uint256 before = asset.balanceOf(actor);
        vm.prank(actor);
        try weir.claim(asset) {
            uint256 got = asset.balanceOf(actor) - before;
            assertEq(got, owed, "claim pays exactly what was deferred");
            assertEq(weir.claimable(address(asset), actor), 0, "claim leaves nothing behind");
            claimed[address(asset)] += got;
        } catch {
            assertEq(asset.balanceOf(actor), before, "a refused claim moves nothing");
        }
        ++calls;
    }

    function dispute(uint256 seed, bool byClient, bool capped) public {
        (uint256 id, Weir.Stream memory s) = _pickIn(seed, Weir.State.Active);
        if (id == 0) return;
        address actor = byClient ? s.client : s.recipient;
        uint256 bond = weir.bondFor(id, actor);
        uint256 fund = weir.courtFund();
        uint256 beforeIMD = imd.balanceOf(actor);
        uint256 beforeToken = s.token.balanceOf(actor);
        bool ok;
        vm.prank(actor);
        if (capped) {
            // The quote is taken in the same call, so the cap is never exceeded; a lower cap is refused.
            try weir.dispute(id, "fuzzed note", bond) {
                ok = true;
            } catch {}
        } else {
            try weir.dispute(id, "fuzzed note") {
                ok = true;
            } catch {}
        }
        if (ok) {
            paidIn[id] += bond;
            ++disputes;
            assertEq(weir.streams(id).bond, bond, "bond quoted differs from bond pulled");
            if (fund >= FEE) {
                assertEq(weir.courtFund(), fund - FEE, "fund pays the price");
                if (s.token != imd) assertEq(imd.balanceOf(actor), beforeIMD, "payer charged although fund paid");
            } else {
                assertEq(weir.courtFund(), fund, "fund touched although too small");
                if (s.token != imd) assertEq(beforeIMD - imd.balanceOf(actor), FEE, "payer pays the price");
            }
            if (s.token != imd) assertEq(beforeToken - s.token.balanceOf(actor), bond);
        }
        ++calls;
    }

    function rule(uint256 seed, bool accepted, bool viaIntake) public {
        (uint256 id, Weir.Stream memory s) = _pickIn(seed, Weir.State.Disputed);
        if (id == 0) return;
        OracleAttestation.Attestation memory a;
        // The submission branch deliberately fuzzes synthetic ABI inputs. It does not model live recovery:
        // the protocol only produces the distinct, sixteen-byte UUID used by the callback branch.
        a.requestId = viaIntake ? bytes32(bytes16(keccak256(abi.encode("uuid", s.requestId)))) : s.requestId;
        a.chainId = block.chainid;
        a.questionHash = keccak256("doc");
        a.answer = abi.encode(accepted);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 7 days);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(KEY, weir.attestationDigest(a));
        bytes memory signature = abi.encodePacked(r, sg, v);
        uint256 before = s.token.balanceOf(address(weir));
        if (viaIntake) {
            vm.prank(address(intake));
            try weir.onOracleResult(s.requestId, a, signature) {
                ++rulings;
            } catch {}
        } else {
            try weir.submitAttestation(id, a, signature) {
                ++rulings;
            } catch {}
        }
        assertEq(s.token.balanceOf(address(weir)), before, "a ruling must move no tokens");
        ++calls;
    }

    function enforce(uint256 seed) public {
        (uint256 id, Weir.Stream memory s) = _pickIn(seed, Weir.State.Ruled);
        if (id == 0) return;
        uint256 beforeClient = s.token.balanceOf(s.client);
        uint256 beforeRecipient = s.token.balanceOf(s.recipient);
        uint256 beforeUnclaimed = weir.unclaimed(address(s.token));
        try weir.enforce(id) {
            uint256 paid = s.token.balanceOf(s.client) - beforeClient;
            if (s.client != s.recipient) paid += s.token.balanceOf(s.recipient) - beforeRecipient;
            paidOut[id] += paid;
            uint256 deferred = weir.unclaimed(address(s.token)) - beforeUnclaimed;
            if (deferred != 0) ++deferrals;
            if (s.ruling == 1) {
                assertEq(paid + deferred, s.bond, "accepted ruling pays only the bond");
            } else {
                assertEq(
                    paid + deferred,
                    s.bond + (s.balance - weir.streamed(id)),
                    "rejected ruling refunds unearned plus bond"
                );
            }
        } catch {}
        _noteClosed(id);
        ++calls;
    }

    function clear(uint256 seed, bool expire) public {
        (uint256 id, Weir.Stream memory s) = _pickIn(seed, Weir.State.Disputed);
        if (id == 0) return;
        uint256 before = s.token.balanceOf(s.disputer);
        uint256 beforeUnclaimed = weir.unclaimed(address(s.token));
        bool ok;
        if (expire) {
            try weir.expireDispute(id) {
                ok = true;
            } catch {}
        } else {
            vm.prank(address(intake));
            try weir.onFailure(s.requestId, 2, "disagreed", 3, 5, "") {
                ok = true;
            } catch {}
        }
        if (ok) {
            uint256 paid = s.token.balanceOf(s.disputer) - before;
            uint256 deferred = weir.unclaimed(address(s.token)) - beforeUnclaimed;
            if (deferred != 0) ++deferrals;
            paidOut[id] += paid;
            assertEq(paid + deferred, s.bond, "a cleared dispute returns exactly the bond");
            assertEq(weir.streams(id).bond, 0);
        }
        ++calls;
    }

    function _pick(uint256 seed) private view returns (uint256 id, Weir.Stream memory s) {
        uint256 count = weir.streamCount();
        if (count == 0) return (0, s);
        id = seed % count + 1;
        s = weir.streams(id);
    }

    /// @dev Starts at the seeded stream and walks forward to the first one in `wanted`, so the rarer states are
    /// reached often; falls back to the seeded stream when none is, which exercises the refusal.
    function _pickIn(uint256 seed, Weir.State wanted) private view returns (uint256 id, Weir.Stream memory s) {
        uint256 count = weir.streamCount();
        if (count == 0) return (0, s);
        uint256 start = seed % count;
        for (uint256 i; i < count; ++i) {
            id = (start + i) % count + 1;
            s = weir.streams(id);
            if (s.state == wanted) return (id, s);
        }
        id = start + 1;
        s = weir.streams(id);
    }

    function _noteClosed(uint256 id) private {
        if (!everClosed[id] && weir.streams(id).state == Weir.State.Closed) {
            everClosed[id] = true;
            ++closedCount;
        }
    }

    function checkInvariants() external view {
        uint256 owedToken;
        uint256 owedIMD;
        uint256 netToken;
        uint256 netIMD;
        uint256 count = weir.streamCount();
        for (uint256 id = 1; id <= count; ++id) {
            Weir.Stream memory s = weir.streams(id);
            uint256 streamed = weir.streamed(id);
            assertLe(s.withdrawn, streamed, "withdrawn above streamed");
            assertLe(streamed, s.balance, "streamed above balance");
            assertEq(weir.withdrawable(id) + weir.refundable(id), s.balance - s.withdrawn, "buckets");
            assertEq(weir.stake(id), s.balance - s.withdrawn, "stake");
            assertLe(paidOut[id], paidIn[id], "stream paid out more than was paid in");
            // A deferred payout stays in custody for its claimant, so a stream's net inflow is at least what
            // its own accounting still holds; the difference is exactly the unclaimed total, checked below.
            assertGe(paidIn[id] - paidOut[id], s.balance - s.withdrawn + s.bond, "custody differs from flows");
            if (everClosed[id]) {
                assertEq(uint256(s.state), uint256(Weir.State.Closed), "a closed stream reopened");
                assertEq(s.rate, 0);
                assertEq(s.bond, 0);
                assertEq(weir.refundable(id), 0);
            }
            if (s.state == Weir.State.Disputed || s.state == Weir.State.Ruled) {
                assertEq(s.rate, 0, "accrual during a dispute");
                assertTrue(s.disputer == s.client || s.disputer == s.recipient);
            }
            if (s.state != Weir.State.Disputed && s.state != Weir.State.Ruled) {
                assertEq(s.bond, 0, "bond outside a dispute");
            }
            if (s.token == imd) {
                owedIMD += s.balance - s.withdrawn + s.bond;
                netIMD += paidIn[id] - paidOut[id];
            } else {
                owedToken += s.balance - s.withdrawn + s.bond;
                netToken += paidIn[id] - paidOut[id];
            }
        }
        assertEq(weir.escrowed(address(token)), owedToken, "token escrow");
        assertEq(weir.escrowed(address(imd)), owedIMD, "imd escrow");
        uint256 unclaimedToken = weir.unclaimed(address(token));
        uint256 unclaimedIMD = weir.unclaimed(address(imd));
        assertEq(netToken - claimed[address(token)], owedToken + unclaimedToken, "token flows vs custody");
        assertEq(netIMD - claimed[address(imd)], owedIMD + unclaimedIMD, "imd flows vs custody");
        uint256 claimableToken;
        uint256 claimableIMD;
        for (uint256 i; i < actors.length; ++i) {
            claimableToken += weir.claimable(address(token), actors[i]);
            claimableIMD += weir.claimable(address(imd), actors[i]);
        }
        assertEq(unclaimedToken, claimableToken, "unclaimed differs from the sum of claims");
        assertEq(unclaimedIMD, claimableIMD, "imd unclaimed differs from the sum of claims");
        assertGe(token.balanceOf(address(weir)), owedToken + unclaimedToken, "token insolvent");
        assertEq(token.balanceOf(address(weir)), owedToken + unclaimedToken, "token custody drift");
        assertGe(imd.balanceOf(address(weir)), owedIMD + unclaimedIMD + weir.courtFund(), "imd insolvent");
        assertEq(imd.balanceOf(address(weir)), owedIMD + unclaimedIMD + weir.courtFund(), "imd custody drift");
        assertLe(weir.courtFund(), sponsored, "fund above sponsorship");
        assertEq(imd.balanceOf(address(intake)), disputes * FEE, "every dispute pays the intake exactly once");
        assertEq(imd.allowance(address(weir), address(intake)), 0, "dangling allowance");
    }
}

contract WeirSolvencyInvariantTest is WeirTestBase {
    SolvencyHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new SolvencyHandler(weir, token, imd, gate, intake);
        handler.create(0, 1, 500e18, 1e12, false);
        handler.create(1, 2, 20e18, 1e12, true);
        handler.create(2, 3, 1e6, 1, false);
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.warp.selector;
        selectors[2] = handler.deposit.selector;
        selectors[3] = handler.rateChange.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.refund.selector;
        selectors[6] = handler.sponsor.selector;
        selectors[7] = handler.holdings.selector;
        selectors[8] = handler.dispute.selector;
        selectors[9] = handler.rule.selector;
        selectors[10] = handler.enforce.selector;
        selectors[11] = handler.clear.selector;
        selectors[12] = handler.accept.selector;
        selectors[13] = handler.toggleBlock.selector;
        selectors[14] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_solvencyAndCustodyUnderRandomSequences() public view {
        handler.checkInvariants();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_closedStreamsNeverReopenAndFundOnlyLeavesThroughTheIntake() public view {
        handler.checkInvariants();
        assertEq(imd.balanceOf(address(intake)), handler.disputes() * FEE);
    }

    function test_handlerReachesRulingsAndClosures() public {
        handler.warp(100);
        handler.sponsor(0, 2e18);
        handler.accept(0);
        handler.dispute(0, true, true);
        handler.rule(0, true, true);
        handler.toggleBlock(1, false, true);
        handler.enforce(0);
        assertEq(handler.deferrals(), 1, "the blocked winner's bond is deferred");
        handler.claim(1, false);
        handler.toggleBlock(1, false, false);
        handler.claim(1, false);
        handler.dispute(1, false, false);
        handler.rule(1, false, false);
        handler.enforce(1);
        handler.dispute(2, true, true);
        handler.clear(2, false);
        handler.dispute(2, false, false);
        handler.warp(8 days);
        handler.toggleBlock(3, false, true);
        handler.clear(2, true);
        handler.toggleBlock(3, false, false);
        handler.claim(3, false);
        handler.refund(0, 0, 0);
        handler.withdraw(1, 0, true);
        handler.checkInvariants();
        assertEq(handler.rulings(), 2);
        assertEq(handler.disputes(), 4);
        assertEq(handler.closedCount(), 2);
        assertEq(handler.deferrals(), 2);
        assertEq(weir.unclaimed(address(token)), 0);
    }
}
