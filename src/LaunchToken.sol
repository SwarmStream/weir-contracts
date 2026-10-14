// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Weir launch token
/// @notice Fixed-supply WEIR token used for Weir's holding gate and dispute bond tiers.
/// @dev The launch factory receives the entire supply and handles its distribution.
contract LaunchToken is ERC20 {
    constructor() ERC20("Weir", "WEIR") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}
