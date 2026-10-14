// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir, OracleAttestation} from "./WeirTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Borrows the holding from its caller, creates and disputes, then repays in one EVM call.
contract ReviewBorrowingClient {
    function createDisputeAndRepay(Weir application, IERC20 asset, address recipient) external returns (uint256 id) {
        IERC20 gate = application.weir();
        uint256 holding = 10_000_000e18;
        require(gate.transferFrom(msg.sender, address(this), holding));
        require(asset.approve(address(application), 1_000e6));
        require(application.imd().approve(address(application), 5e17));
        id = application.createStream(recipient, asset, 1e6, 1_000e6, keccak256("terms"), "ipfs://terms", 0);
        application.dispute(id, "Work not delivered.");
        require(gate.transfer(msg.sender, holding));
    }
}

contract ReviewBlocklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blocklist", "BL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockAddress(address account) external {
        blocked[account] = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "address blocked");
        super._update(from, to, amount);
    }
}

contract WeirReviewTest is WeirTestBase {
    /// @dev A domain-valid signature proves neither the Intake receipt nor the question association.
    function test_unrelatedQuestionCannotSettlePendingDispute() public {
        uint256 id = _create();
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        a.questionHash = keccak256("Unrelated question bought by a stranger for this consumer");
        bytes memory signature = _sign(a);
        assertNotEq(a.requestId, receipt);
        vm.expectRevert(Weir.AttestationRequestMismatch.selector);
        vm.prank(stranger);
        weir.submitAttestation(id, a, signature);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
        assertFalse(weir.consumed(a.requestId));
    }

    function test_liveUUIDCannotBeResubmittedAndMissingCallbackExitsOnlyAfterTimeout() public {
        uint256 id = _create();
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        bytes memory signature = _sign(a);
        assertNotEq(a.requestId, receipt);
        vm.expectRevert(Weir.AttestationRequestMismatch.selector);
        weir.submitAttestation(id, a, signature);
        uint256 bond = weir.streams(id).bond;
        uint256 beforeClient = token.balanceOf(client);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(Weir.DisputeNotExpired.selector);
        weir.expireDispute(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        weir.expireDispute(id);
        assertEq(token.balanceOf(client) - beforeClient, bond);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Active));
        assertEq(weir.streams(id).rate, 0);
        assertEq(weir.streams(id).ruling, 0);
        (uint32 won, uint32 lost,,, uint32 raised) = weir.records(client);
        assertEq(uint256(won) + lost + raised, 0);
        (,, won, lost, raised) = weir.records(recipient);
        assertEq(uint256(won) + lost + raised, 0);
        _solvent(token);
    }

    function test_coldFirstAcceptedRulingByClientFitsIntakeStipend() public {
        _coldFirstRuling(true, client);
    }

    function test_coldFirstAcceptedRulingByRecipientFitsIntakeStipend() public {
        _coldFirstRuling(true, recipient);
    }

    function test_coldFirstRejectedRulingByClientFitsIntakeStipend() public {
        _coldFirstRuling(false, client);
    }

    function test_coldFirstRejectedRulingByRecipientFitsIntakeStipend() public {
        _coldFirstRuling(false, recipient);
    }

    function _coldFirstRuling(bool accepted, address disputer) private {
        uint256 id = _create();
        bytes32 receipt = _dispute(id, disputer);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, accepted);
        bytes memory signature = _sign(a);
        vm.cool(address(weir));
        vm.cool(vm.addr(SIGNING_KEY));
        vm.prank(address(intake));
        uint256 beforeGas = gasleft();
        weir.onOracleResult(receipt, a, signature);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("cold first ruling gas", gasUsed);
        assertLt(gasUsed, 200_000);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
        assertEq(weir.streams(id).ruling, accepted ? 1 : 2);
        assertTrue(weir.consumed(a.requestId));
        _solvent(token);
    }

    function test_acceptedVerdictBlockedRecipientKeepsClientRefundLocked() public {
        ReviewBlocklistToken asset = _blocklistToken();
        uint256 id = _createWith(asset, RATE, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 10);
        bytes32 receipt = _dispute(id, client);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, true);
        (bool ok,) = intake.deliver(receipt, a, _sign(a));
        assertTrue(ok);
        asset.blockAddress(recipient);
        vm.expectRevert("address blocked");
        weir.enforce(id);
        vm.startPrank(client);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.refundMax(id);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.void(id);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert("address blocked");
        weir.enforce(id);
        vm.expectRevert(abi.encodeWithSelector(Weir.WrongState.selector, Weir.State.Ruled));
        weir.expireDispute(id);
        assertEq(weir.refundable(id), AMOUNT - 10 * RATE);
        assertEq(weir.streams(id).bond, AMOUNT / 20);
        _solvent(asset);
    }

    function test_rejectedVerdictBlockedClientStillAllowsRecipientEarnedWithdrawal() public {
        ReviewBlocklistToken asset = _blocklistToken();
        uint256 id = _createWith(asset, RATE, AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 10);
        bytes32 receipt = _dispute(id, recipient);
        OracleAttestation.Attestation memory a = _oracleAttestation(id, false);
        (bool ok,) = intake.deliver(receipt, a, _sign(a));
        assertTrue(ok);
        asset.blockAddress(client);
        vm.expectRevert("address blocked");
        weir.enforce(id);
        uint256 beforeRecipient = asset.balanceOf(recipient);
        vm.prank(recipient);
        weir.withdrawMax(id);
        assertEq(asset.balanceOf(recipient) - beforeRecipient, 10 * RATE);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Ruled));
        _solvent(asset);
    }

    function test_borrowedHoldingPassesGateAndZeroBondTier() public {
        ReviewBorrowingClient borrower = new ReviewBorrowingClient();
        gate.mint(address(this), 10_000_000e18);
        gate.approve(address(borrower), 10_000_000e18);
        token.mint(address(borrower), AMOUNT);
        imd.mint(address(borrower), FEE);
        assertFalse(weir.canUse(address(borrower)));
        uint256 id = borrower.createDisputeAndRepay(weir, token, recipient);
        assertEq(gate.balanceOf(address(this)), 10_000_000e18);
        assertEq(gate.balanceOf(address(borrower)), 0);
        assertFalse(weir.canUse(address(borrower)));
        assertEq(weir.streams(id).client, address(borrower));
        assertEq(weir.streams(id).bond, 0);
        assertEq(uint256(weir.streams(id).state), uint256(Weir.State.Disputed));
        _solvent(token);
    }

    function _blocklistToken() private returns (ReviewBlocklistToken asset) {
        asset = new ReviewBlocklistToken();
        asset.mint(client, 2 * AMOUNT);
        asset.mint(recipient, AMOUNT);
        vm.prank(client);
        asset.approve(address(weir), type(uint256).max);
        vm.prank(recipient);
        asset.approve(address(weir), type(uint256).max);
    }
}
