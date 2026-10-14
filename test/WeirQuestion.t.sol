// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WeirTestBase, Weir} from "./WeirTestBase.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OracleText} from "../src/libraries/OracleText.sol";

contract TextHarness {
    function validate(string memory value, uint256 maximum) external pure {
        OracleText.validate(value, maximum);
    }

    function escape(string memory value) external pure returns (string memory) {
        return OracleText.escape(value);
    }
}

contract WeirQuestionTest is WeirTestBase {
    using Strings for uint256;
    using Strings for address;

    function test_exactFixedQuestionAndBodyAndStoredHash() public {
        uint256 id = _create();
        string memory question = string.concat(
            "Weir stream 1 at ",
            address(weir).toHexString(),
            " on chain 4663. Client ",
            client.toHexString(),
            " streams ",
            address(token).toHexString(),
            " to recipient ",
            recipient.toHexString()
        );
        question = string.concat(
            question,
            " under the terms at ipfs://bafy-weir-terms (keccak256 ",
            uint256(TERMS).toHexString(32),
            "). Dispute raised by the client with note: Missing tests. As of block 500, has the recipient delivered the work those terms describe to the standard a reasonable client would accept? Answer true if yes, false if no."
        );
        string memory expected = string.concat(
            '{"v":1,"question":"',
            question,
            '","chainId":4663,"window":{"hours":24},"answerType":"bool","panelSize":5,"quorum":4,"validForSeconds":604800,"evidence":"panel","consumer":{"chainId":4663,"verifyingContract":"',
            address(weir).toHexString(),
            '"}}'
        );
        assertEq(weir.questionFor(id, client, "Missing tests"), question);
        bytes memory body = weir.expectedBody(id, client, "Missing tests");
        assertEq(body, bytes(expected));
        vm.prank(client);
        assertEq(weir.expectedBody(id, "Missing tests"), body);
        vm.prank(client);
        weir.dispute(id, "Missing tests");
        assertEq(intake.lastBody(), body);
        assertEq(weir.questionOf(id), keccak256(bytes(question)));
    }

    function test_optionalJobAndRecipientRole() public {
        bytes32 job = keccak256("job");
        vm.prank(client);
        uint256 id = weir.createStream(recipient, token, RATE, AMOUNT, TERMS, URI, job);
        bytes memory body = weir.expectedBody(id, recipient, "Complete");
        string memory q = vm.parseJsonString(string(body), ".question");
        assertTrue(_contains(q, string.concat(", IMD job ", uint256(job).toHexString(32))));
        assertTrue(_contains(q, ". Dispute raised by the recipient with note: Complete."));
        assertEq(vm.parseJsonString(string(body), ".consumer.verifyingContract"), address(weir).toHexString());
        assertEq(vm.parseJsonUint(string(body), ".consumer.chainId"), 4663);
        assertEq(vm.parseJsonUint(string(body), ".panelSize"), 5);
        assertEq(vm.parseJsonUint(string(body), ".quorum"), 4);
        assertEq(vm.parseJsonUint(string(body), ".validForSeconds"), 604800);
        assertEq(vm.parseJsonString(string(body), ".evidence"), "panel");
        assertEq(vm.parseJsonUint(string(body), ".window.hours"), 24);
    }

    function test_jsonInjectionControlsAndUnicodeRoundTrip() public {
        string memory uri = 'ipfs://terms/"\\\n';
        string memory note =
            string.concat(unicode'"},"quorum":1,"note":"café 🦦 ', string(hex"00010208090a0b0c0d1f"));
        vm.prank(client);
        uint256 id = weir.createStream(recipient, token, RATE, AMOUNT, TERMS, uri, 0);
        bytes memory body = weir.expectedBody(id, recipient, note);
        string memory q = vm.parseJsonString(string(body), ".question");
        assertEq(q, weir.questionFor(id, recipient, note));
        assertEq(vm.parseJsonUint(string(body), ".quorum"), 4);
        assertEq(vm.parseJsonString(string(body), ".answerType"), "bool");
        assertTrue(_contains(q, uri));
        assertTrue(_contains(q, note));
        vm.prank(recipient);
        weir.dispute(id, note);
        assertEq(intake.lastBody(), body);
    }

    function test_noteLengthAndURIAtLimitsStayWithinOracleBounds() public {
        string memory uri = _repeat(512, "a");
        string memory note = _repeat(280, "b");
        vm.prank(client);
        uint256 id = weir.createStream(recipient, token, RATE, AMOUNT, TERMS, uri, keccak256("job"));
        assertLe(bytes(weir.questionFor(id, client, note)).length, 2000);
        assertLe(weir.expectedBody(id, client, note).length, 16 * 1024);
        vm.prank(client);
        weir.dispute(id, note);
        uint256 other = _create();
        vm.expectRevert(abi.encodeWithSelector(OracleText.TextTooLong.selector, 281, 280));
        vm.prank(client);
        weir.dispute(other, _repeat(281, "b"));
        vm.expectRevert(abi.encodeWithSelector(OracleText.TextTooLong.selector, 513, 512));
        vm.prank(client);
        weir.createStream(recipient, token, RATE, AMOUNT, TERMS, _repeat(513, "a"), 0);
    }

    function test_invalidUTF8RejectedBeforeFundingOrOraclePayment() public {
        TextHarness text = new TextHarness();
        bytes[9] memory invalid = [
            bytes(hex"80"),
            hex"c080",
            hex"e08080",
            hex"eda080",
            hex"f0808080",
            hex"f4908080",
            hex"f5808080",
            hex"f09f",
            hex"c261"
        ];
        uint256 id = _create();
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(OracleText.InvalidUTF8.selector);
            text.validate(string(invalid[i]), 280);
            vm.expectRevert(OracleText.InvalidUTF8.selector);
            vm.prank(client);
            weir.dispute(id, string(invalid[i]));
        }
        assertEq(intake.sequence(), 0);
        assertEq(weir.streams(id).rate, RATE);
        vm.expectRevert(OracleText.InvalidUTF8.selector);
        vm.prank(client);
        weir.createStream(recipient, token, RATE, AMOUNT, TERMS, string(bytes(hex"ff")), 0);
        // Lowest/highest code points of each multibyte range.
        text.validate(string(hex"c280dfbfe0a080ed9fbfefbfbff0908080f48fbfbf"), 280);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_escapeAllASCIIKeepsJSONShape(bytes memory input) public {
        if (input.length > 280) input = bytes(_repeat(280, "x"));
        for (uint256 i; i < input.length; ++i) {
            input[i] = bytes1(uint8(input[i]) & 0x7f);
        }
        uint256 id = _create();
        string memory body = string(weir.expectedBody(id, client, string(input)));
        assertEq(vm.parseJsonString(body, ".question"), weir.questionFor(id, client, string(input)));
        assertEq(vm.parseJsonUint(body, ".quorum"), 4);
        assertEq(vm.parseJsonString(body, ".consumer.verifyingContract"), address(weir).toHexString());
    }

    function _repeat(uint256 n, bytes1 c) private pure returns (string memory) {
        bytes memory value = new bytes(n);
        for (uint256 i; i < n; ++i) {
            value[i] = c;
        }
        return string(value);
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool matches = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
