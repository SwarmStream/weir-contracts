// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Weir} from "../src/Weir.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Models the factory constructing the token and application in one transaction.
contract LaunchTokenDeploymentHarness {
    function deploy(IERC20 imd, IIntake intake, address signer) external returns (LaunchToken token, Weir application) {
        token = new LaunchToken();
        application = new Weir(token, imd, intake, signer, 7 days, 10_000e18);
    }
}

contract LaunchTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    LaunchToken private token;
    address private recipient;

    function setUp() public {
        token = new LaunchToken();
        recipient = makeAddr("token recipient");
    }

    function test_launchMetadataAndEntireSupplyBelongToDeployer() public view {
        assertEq(token.name(), "Weir");
        assertEq(token.symbol(), "WEIR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_transferMovesExactAmountAndPreservesSupply() public {
        uint256 amount = 10_000e18;
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), recipient, amount);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowancePermitsOnlyApprovedAmount() public {
        address spender = makeAddr("token spender");
        uint256 amount = 25e18;
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount, amount + 1)
        );
        token.transferFrom(address(this), recipient, amount + 1);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, amount));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRejectsInvalidRecipientAndInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, 0, 1));
        token.transfer(address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_neitherDeployerNorOtherCallerHasPrivilegedEntryPoints() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "setFee(uint256)",
            "setBlacklist(address,bool)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], recipient, uint256(1));
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded, signatures[i]);
            vm.prank(recipient);
            (bool outsiderSucceeded,) = address(token).call(data);
            assertFalse(outsiderSucceeded, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_factoryDeploymentPreservesSupplyAndConfiguresWeir() public {
        LaunchTokenDeploymentHarness factory = new LaunchTokenDeploymentHarness();
        MockToken imd = new MockToken("IMD", 18);
        MockIntake intake = new MockIntake();
        (LaunchToken deployedToken, Weir application) = factory.deploy(imd, intake, makeAddr("oracle signer"));
        assertEq(deployedToken.totalSupply(), SUPPLY);
        assertEq(deployedToken.balanceOf(address(factory)), SUPPLY);
        assertEq(deployedToken.balanceOf(address(application)), 0);
        assertEq(address(application.weir()), address(deployedToken));
        assertEq(application.minHold(), 10_000e18);
        assertEq(application.disputeTimeout(), 7 days);
    }

    function test_realTokenHoldGateAndStreamingIntegration() public {
        MockToken imd = new MockToken("IMD", 18);
        MockIntake intake = new MockIntake();
        Weir application = new Weir(token, imd, intake, makeAddr("oracle signer"), 7 days, 10_000e18);
        address client = makeAddr("token client");
        bytes32 terms = keccak256("Work terms");
        token.transfer(client, 10_000e18 - 1);
        assertFalse(application.canUse(client));
        vm.startPrank(client);
        token.approve(address(application), 100e18);
        vm.expectRevert(Weir.HoldRequired.selector);
        application.createStream(recipient, token, 1e18, 100e18, terms, "ipfs://terms", bytes32(0));
        vm.stopPrank();

        token.transfer(client, 1);
        assertTrue(application.canUse(client));
        assertEq(application.tierBps(client), 500);
        vm.prank(client);
        uint256 id = application.createStream(recipient, token, 1e18, 100e18, terms, "ipfs://terms", bytes32(0));
        assertFalse(application.canUse(client));
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(recipient);
        application.withdrawMax(id);
        assertEq(token.balanceOf(recipient), 5e18);
        assertEq(token.balanceOf(address(application)), 95e18);
        assertEq(application.withdrawable(id) + application.refundable(id), 95e18);
        assertEq(application.escrowed(address(token)), 95e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
