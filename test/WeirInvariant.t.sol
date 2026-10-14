// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WeirTestBase, Weir, OracleAttestation, IERC20} from "./WeirTestBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev An independent cash-flow model: earned and unearned buckets, with no snapshot-debt formula.
contract WeirHandler is Test {
    struct Model {
        address client;
        address recipient;
        IERC20 token;
        uint256 earned;
        uint256 unearned;
        uint128 rate;
        uint128 savedRate;
        Weir.State state;
        address disputer;
        uint256 bond;
        uint256 deadline;
        bool accepted;
    }

    Weir public immutable weir;
    MockToken public immutable token;
    MockToken public immutable imd;
    MockToken public immutable gate;
    MockIntake public immutable intake;
    uint256 public count;
    uint256 public fund;
    mapping(uint256 => Model) private model;
    mapping(address => Weir.Record) private record;
    address[3] public actors;
    uint256 public transitions;
    uint256 public rulings;
    uint256 public enforcements;

    constructor(Weir weir_, MockToken token_, MockToken imd_, MockToken gate_, MockIntake intake_) {
        weir = weir_;
        token = token_;
        imd = imd_;
        gate = gate_;
        intake = intake_;
        for (uint256 i; i < 3; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("invariant actor", i)))));
            actors[i] = actor;
            token_.mint(actor, 1e40);
            imd_.mint(actor, 1e40);
            gate_.mint(actor, 100_000e18);
            vm.startPrank(actor);
            token_.approve(address(weir_), type(uint256).max);
            imd_.approve(address(weir_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(uint8 actorSeed, uint128 amountSeed, uint128 rateSeed, bool useIMD) public {
        if (count >= 8) return;
        address client = actors[actorSeed % 3];
        if (!weir.canUse(client)) return;
        address recipient = actors[(uint256(actorSeed) + 1) % 3];
        uint128 amount = uint128(bound(amountSeed, 1, 1e22));
        uint128 rate = uint128(bound(rateSeed, 1, 1e18));
        IERC20 asset = useIMD ? imd : token;
        vm.prank(client);
        uint256 id = weir.createStream(recipient, asset, rate, amount, keccak256("terms"), "ipfs://model-terms", 0);
        assertEq(id, ++count);
        Model storage m = model[id];
        m.client = client;
        m.recipient = recipient;
        m.token = asset;
        m.unearned = amount;
        m.rate = rate;
        m.state = Weir.State.Active;
        ++transitions;
    }

    function advance(uint32 secondsSeed) public {
        uint256 elapsed = bound(secondsSeed, 0, 8 days);
        for (uint256 id = 1; id <= count; ++id) {
            Model storage m = model[id];
            uint256 newlyEarned = uint256(m.rate) * elapsed;
            if (newlyEarned > m.unearned) newlyEarned = m.unearned;
            m.earned += newlyEarned;
            m.unearned -= newlyEarned;
        }
        vm.warp(vm.getBlockTimestamp() + elapsed);
    }

    function deposit(uint256 seed, uint128 amountSeed) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Active && m.state != Weir.State.Disputed) return;
        uint256 amount = bound(amountSeed, 1, 1e22);
        vm.prank(m.client);
        weir.deposit(id, amount);
        m.unearned += amount;
        ++transitions;
    }

    function rateAction(uint256 seed, uint128 rateSeed, bool pauseIt) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Active) return;
        uint128 rate = uint128(bound(rateSeed, 1, 1e18));
        vm.startPrank(m.client);
        if (m.rate == 0) {
            weir.restart(id, rate);
            m.rate = rate;
            m.savedRate = 0;
        } else if (pauseIt) {
            weir.pause(id);
            m.savedRate = m.rate;
            m.rate = 0;
        } else {
            weir.adjust(id, rate);
            m.rate = rate;
        }
        vm.stopPrank();
        ++transitions;
    }

    function withdraw(uint256 seed, uint256 amountSeed, bool all) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        uint256 amount = all ? m.earned : bound(amountSeed, 0, m.earned);
        vm.startPrank(m.recipient);
        if (all) weir.withdrawMax(id);
        else weir.withdraw(id, amount);
        vm.stopPrank();
        m.earned -= amount;
        ++transitions;
    }

    function refund(uint256 seed, uint256 amountSeed, bool close) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Active) return;
        vm.startPrank(m.client);
        if (close) {
            weir.void(id);
            m.unearned = 0;
            m.rate = 0;
            m.savedRate = 0;
            m.state = Weir.State.Closed;
        } else {
            uint256 amount = bound(amountSeed, 0, m.unearned);
            weir.refund(id, amount);
            m.unearned -= amount;
        }
        vm.stopPrank();
        ++transitions;
    }

    function sponsor(uint128 amountSeed, uint8 actorSeed) public {
        uint256 amount = bound(amountSeed, 1, 2e18);
        vm.prank(actors[actorSeed % 3]);
        weir.sponsor(amount);
        fund += amount;
        ++transitions;
    }

    function changeHoldings(uint8 actorSeed, uint8 tierSeed) public {
        address actor = actors[actorSeed % 3];
        uint256[5] memory amounts = [uint256(0), 10_000e18, 100_000e18, 1_000_000e18, 10_000_000e18];
        uint256 desired = amounts[tierSeed % 5];
        uint256 current = gate.balanceOf(actor);
        if (desired > current) gate.mint(actor, desired - current);
        else gate.burn(actor, current - desired);
    }

    function dispute(uint256 seed, bool byClient) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Active || m.earned + m.unearned == 0) return;
        address actor = byClient ? m.client : m.recipient;
        if (!weir.canUse(actor)) return;
        uint256 holding = gate.balanceOf(actor);
        uint256 bps = holding >= 10_000_000e18 ? 0 : holding >= 1_000_000e18 ? 100 : holding >= 100_000e18 ? 250 : 500;
        m.bond = (m.earned + m.unearned) * bps / 10_000;
        // Some streams are never accepted by their recipient; those rulings must leave records untouched.
        if (weir.acceptedAt(id) == 0 && seed % 3 != 0) {
            vm.prank(m.recipient);
            weir.accept(id);
        }
        vm.prank(actor);
        weir.dispute(id, "Evaluate the agreed work", m.bond);
        if (m.rate != 0) m.savedRate = m.rate;
        m.rate = 0;
        m.state = Weir.State.Disputed;
        m.disputer = actor;
        m.deadline = vm.getBlockTimestamp() + 7 days;
        if (fund >= 5e17) fund -= 5e17;
        ++transitions;
    }

    function rule(uint256 seed, bool accepted) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Disputed) return;
        OracleAttestation.Attestation memory a;
        bytes32 receipt = weir.streams(id).requestId;
        a.requestId = bytes32(bytes16(keccak256(abi.encode("oracle uuid", receipt))));
        a.chainId = block.chainid;
        a.questionHash = keccak256("resolved document");
        a.answer = abi.encode(accepted);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 7 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xfeed1234, weir.attestationDigest(a));
        assertNotEq(a.requestId, receipt);
        (bool delivered,) = intake.deliver(receipt, a, abi.encodePacked(r, s, v));
        assertTrue(delivered, "a pending model dispute must receive its signed ruling within the stipend");
        assertTrue(weir.consumed(a.requestId));
        assertFalse(weir.consumed(receipt));
        m.state = Weir.State.Ruled;
        m.accepted = accepted;
        if (weir.acceptedAt(id) != 0) {
            if (accepted) {
                ++record[m.client].clientLost;
                ++record[m.recipient].recipientWon;
            } else {
                ++record[m.client].clientWon;
                ++record[m.recipient].recipientLost;
            }
            ++record[m.disputer].raised;
        }
        ++rulings;
        ++transitions;
    }

    function enforce(uint256 seed) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Ruled) return;
        address winner = m.accepted ? m.recipient : m.client;
        uint256 before = m.token.balanceOf(winner);
        weir.enforce(id);
        assertEq(m.token.balanceOf(winner) - before, m.bond + (m.accepted ? 0 : m.unearned));
        m.bond = 0;
        if (m.accepted) {
            m.rate = m.savedRate;
            m.state = Weir.State.Active;
        } else {
            m.unearned = 0;
            m.state = Weir.State.Closed;
        }
        m.savedRate = 0;
        ++enforcements;
        ++transitions;
    }

    function clearDispute(uint256 seed, bool expire) public {
        if (count == 0) return;
        uint256 id = seed % count + 1;
        Model storage m = model[id];
        if (m.state != Weir.State.Disputed) return;
        uint256 before = m.token.balanceOf(m.disputer);
        if (expire) {
            if (vm.getBlockTimestamp() <= m.deadline) return;
            weir.expireDispute(id);
        } else {
            bytes32 requestId = weir.streams(id).requestId;
            vm.prank(address(intake));
            weir.onFailure(requestId, 2, "disagreed", 3, 5, "");
        }
        assertEq(m.token.balanceOf(m.disputer) - before, m.bond);
        m.bond = 0;
        m.state = Weir.State.Active;
        ++transitions;
    }

    function assertModel() external view {
        uint256 owedToken;
        uint256 owedIMD;
        for (uint256 id = 1; id <= count; ++id) {
            Model storage m = model[id];
            Weir.Stream memory s = weir.streams(id);
            assertEq(weir.withdrawable(id), m.earned, "earned bucket differs");
            assertEq(weir.refundable(id), m.unearned, "unearned bucket differs");
            assertEq(weir.stake(id), m.earned + m.unearned);
            assertEq(s.balance - s.withdrawn, m.earned + m.unearned);
            assertEq(s.rate, m.rate);
            assertEq(s.pausedRate, m.savedRate);
            assertEq(s.bond, m.bond);
            assertEq(uint256(s.state), uint256(m.state));
            assertLe(weir.streamed(id), s.balance);
            if (m.token == imd) owedIMD += m.earned + m.unearned + m.bond;
            else owedToken += m.earned + m.unearned + m.bond;
        }
        assertEq(weir.escrowed(address(token)), owedToken);
        assertEq(weir.escrowed(address(imd)), owedIMD);
        assertEq(token.balanceOf(address(weir)), owedToken);
        assertEq(imd.balanceOf(address(weir)), owedIMD + fund);
        assertEq(weir.courtFund(), fund);
        assertEq(imd.allowance(address(weir), address(intake)), 0);
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            (uint32 cw, uint32 cl, uint32 rw, uint32 rl, uint32 raised) = weir.records(actor);
            assertEq(cw, record[actor].clientWon);
            assertEq(cl, record[actor].clientLost);
            assertEq(rw, record[actor].recipientWon);
            assertEq(rl, record[actor].recipientLost);
            assertEq(raised, record[actor].raised);
        }
    }
}

contract WeirInvariantTest is WeirTestBase {
    WeirHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new WeirHandler(weir, token, imd, gate, intake);
        handler.create(0, 100e18, 1e12, false);
        handler.create(1, 200e18, 1e12, true);
        handler.create(2, 300e18, 1e12, false);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.deposit.selector;
        selectors[3] = handler.rateAction.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.refund.selector;
        selectors[6] = handler.sponsor.selector;
        selectors[7] = handler.changeHoldings.selector;
        selectors[8] = handler.dispute.selector;
        selectors[9] = handler.rule.selector;
        selectors[10] = handler.enforce.selector;
        selectors[11] = handler.clearDispute.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_cashFlowAndRecordsMatchIndependentModel() public view {
        handler.assertModel();
    }

    function test_handlerExercisesEveryDisputeExitAndAllStates() public {
        handler.advance(17);
        handler.deposit(0, 10e18);
        handler.withdraw(0, 1, false);
        handler.rateAction(0, 1e12, true);
        handler.sponsor(2e18, 0);
        handler.dispute(0, true);
        handler.rule(0, true);
        handler.enforce(0);
        handler.dispute(1, false);
        handler.rule(1, false);
        handler.enforce(1);
        handler.dispute(2, true);
        handler.clearDispute(2, false);
        handler.dispute(2, false);
        handler.advance(7 days + 1);
        handler.clearDispute(2, true);
        handler.refund(2, 1, true);
        handler.assertModel();
        assertEq(handler.rulings(), 2);
        assertEq(handler.enforcements(), 2);
        assertGt(handler.transitions(), 15);
    }
}
