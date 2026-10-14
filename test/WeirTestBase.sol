// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Weir} from "../src/Weir.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

abstract contract WeirTestBase is Test {
    uint256 internal constant SIGNING_KEY = 0xfeed1234;
    uint256 internal constant HOLD = 10_000e18;
    uint256 internal constant FEE = 5e17;
    uint128 internal constant AMOUNT = 1_000e6;
    uint128 internal constant RATE = 1e6;
    bytes32 internal constant TERMS = keccak256("Deliver the agreed software and tests");
    string internal constant URI = "ipfs://bafy-weir-terms";

    address internal client;
    address internal recipient;
    address internal stranger;
    MockToken internal gate;
    MockToken internal imd;
    MockToken internal token;
    MockIntake internal intake;
    Weir internal weir;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.roll(500);
        client = makeAddr("client");
        recipient = makeAddr("recipient");
        stranger = makeAddr("stranger");
        gate = new MockToken("WEIR", 18);
        imd = new MockToken("IMD", 18);
        token = new MockToken("USDC-like", 6);
        intake = new MockIntake();
        weir = new Weir(gate, imd, intake, vm.addr(SIGNING_KEY), 7 days, HOLD);
        _fund(client);
        _fund(recipient);
        _fund(stranger);
    }

    function _fund(address user) internal {
        gate.mint(user, HOLD);
        token.mint(user, 1e30);
        imd.mint(user, 1e30);
        vm.startPrank(user);
        token.approve(address(weir), type(uint256).max);
        imd.approve(address(weir), type(uint256).max);
        vm.stopPrank();
    }

    function _create() internal returns (uint256 id) {
        return _createWith(token, RATE, AMOUNT);
    }

    /// @dev Creates an accepted stream, the ordinary case; `_createUnaccepted` leaves the recipient silent.
    function _createWith(IERC20 asset, uint128 rate, uint128 amount) internal returns (uint256 id) {
        id = _createUnaccepted(asset, rate, amount);
        vm.prank(recipient);
        weir.accept(id);
    }

    function _createUnaccepted(IERC20 asset, uint128 rate, uint128 amount) internal returns (uint256 id) {
        vm.prank(client);
        id = weir.createStream(recipient, asset, rate, amount, TERMS, URI, bytes32(0));
    }

    function _dispute(uint256 id, address party) internal returns (bytes32 requestId) {
        vm.prank(party);
        weir.dispute(id, "Work reviewed against the agreed terms.");
        requestId = weir.streams(id).requestId;
    }

    /// @dev Shaped like the live protocol: the signed oracle UUID differs from the Intake receipt id the
    /// callback receives. Use with `intake.deliver(weir.streams(id).requestId, ...)`.
    function _oracleAttestation(uint256 id, bool accepted)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = _attestation(id, accepted);
        a.requestId = _oracleUuid(id);
    }

    /// @dev A sixteen-byte, left-aligned UUID distinct from every Intake receipt id the mock returns.
    function _oracleUuid(uint256 id) internal view returns (bytes32) {
        bytes32 receipt = weir.streams(id).requestId;
        return bytes32(uint256(keccak256(abi.encode("oracle uuid", receipt))) & ~uint256(type(uint128).max));
    }

    /// @dev Synthetic receipt-matched input for submitAttestation's ABI/validation tests only. The live
    /// oracle signs a distinct UUID; settlement scenarios must use _oracleAttestation instead.
    function _attestation(uint256 id, bool accepted) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = weir.streams(id).requestId;
        a.chainId = block.chainid;
        // The canonical oracle document hash is different from keccak256(Q) for the relative window.
        a.questionHash = keccak256("oracle canonical question and resolved window");
        a.answerType = 0;
        a.answer = abi.encode(accepted);
        a.fromBlock = 400;
        a.toBlock = 500;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256(abi.encode("panel", a.requestId));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 7 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, weir.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _rule(uint256 id, bool accepted) internal {
        bytes32 receipt = weir.streams(id).requestId;
        OracleAttestation.Attestation memory a = _oracleAttestation(id, accepted);
        bytes memory signature = _sign(a);
        assertNotEq(a.requestId, receipt);
        (bool called,) = intake.deliver(receipt, a, signature);
        assertTrue(called, "the live-shaped ruling must fit the Intake callback stipend");
    }

    function _conserved(uint256 id) internal view {
        Weir.Stream memory s = weir.streams(id);
        assertLe(weir.streamed(id), s.balance);
        assertGe(weir.streamed(id), s.withdrawn);
        assertEq(weir.withdrawable(id) + weir.refundable(id), s.balance - s.withdrawn);
        assertEq(weir.stake(id), s.balance - s.withdrawn);
    }

    function _solvent(IERC20 asset) internal view {
        uint256 expected;
        for (uint256 id = 1; id <= weir.streamCount(); ++id) {
            Weir.Stream memory s = weir.streams(id);
            if (s.token == asset) expected += s.balance - s.withdrawn + s.bond;
            _conserved(id);
        }
        assertEq(weir.escrowed(address(asset)), expected);
        expected += weir.unclaimed(address(asset));
        if (asset == imd) expected += weir.courtFund();
        assertGe(asset.balanceOf(address(weir)), expected);
    }
}
