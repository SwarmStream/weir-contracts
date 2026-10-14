// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Bounded UTF-8 validation and JSON string escaping for the fixed dispute question.
library OracleText {
    error InvalidUTF8();
    error TextTooLong(uint256 length, uint256 maximum);

    bytes16 private constant HEX = "0123456789abcdef";

    /// @dev Rejects overlong encodings, isolated continuation bytes, surrogates and codepoints > U+10FFFF.
    function validate(string memory text, uint256 maximum) internal pure {
        bytes memory data = bytes(text);
        if (data.length > maximum) revert TextTooLong(data.length, maximum);
        for (uint256 i; i < data.length;) {
            uint8 first = uint8(data[i]);
            if (first < 0x80) {
                ++i;
                continue;
            }
            uint256 size;
            uint32 point;
            uint32 minimum;
            if (first >= 0xc2 && first <= 0xdf) {
                size = 2;
                point = first & 0x1f;
                minimum = 0x80;
            } else if (first >= 0xe0 && first <= 0xef) {
                size = 3;
                point = first & 0x0f;
                minimum = 0x800;
            } else if (first >= 0xf0 && first <= 0xf4) {
                size = 4;
                point = first & 0x07;
                minimum = 0x10000;
            } else {
                revert InvalidUTF8();
            }
            if (i + size > data.length) revert InvalidUTF8();
            for (uint256 j = 1; j < size; ++j) {
                uint8 next = uint8(data[i + j]);
                if (next < 0x80 || next > 0xbf) revert InvalidUTF8();
                point = (point << 6) | uint32(next & 0x3f);
            }
            if (point < minimum || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) {
                revert InvalidUTF8();
            }
            i += size;
        }
    }

    /// @dev Escapes every JSON control byte, plus quotes and backslashes. Preserves validated UTF-8.
    function escape(string memory text) internal pure returns (string memory) {
        bytes memory data = bytes(text);
        bytes memory encoded = new bytes(data.length * 6);
        uint256 length;
        for (uint256 i; i < data.length; ++i) {
            bytes1 c = data[i];
            if (c == '"' || c == "\\") {
                encoded[length++] = "\\";
                encoded[length++] = c;
            } else if (uint8(c) < 0x20) {
                encoded[length++] = "\\";
                encoded[length++] = "u";
                encoded[length++] = "0";
                encoded[length++] = "0";
                encoded[length++] = HEX[uint8(c) >> 4];
                encoded[length++] = HEX[uint8(c) & 0xf];
            } else {
                encoded[length++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(encoded, length)
        }
        return string(encoded);
    }
}
