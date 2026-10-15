// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A stream token that misbehaves on transfer(): it can burn all forwarded gas, or return false
/// (without moving anything) for chosen recipients. transferFrom stays honest so streams can be funded.
contract QuirkyToken is ERC20 {
    bool public burnGas;
    mapping(address => bool) public refuseTo;

    constructor() ERC20("Quirky", "QRK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurn(bool enabled) external {
        burnGas = enabled;
    }

    function setRefuse(address account, bool enabled) external {
        refuseTo[account] = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (burnGas) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (refuseTo[to]) return false;
        return super.transfer(to, amount);
    }
}
