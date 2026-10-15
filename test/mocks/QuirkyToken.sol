// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A stream token that misbehaves on transfer(): it can burn all forwarded gas, or return false
/// (without moving anything) for chosen recipients. transferFrom stays honest so streams can be funded.
contract QuirkyToken is ERC20 {
    bool public burnGas;
    bool public burnBalance;
    bool public garbageReturn;
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

    function setBurnBalance(bool enabled) external {
        burnBalance = enabled;
    }

    function setGarbageReturn(bool enabled) external {
        garbageReturn = enabled;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (burnBalance) {
            assembly {
                for {} 1 {} {}
            }
        }
        return super.balanceOf(account);
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
        if (garbageReturn) {
            // Return the 32-byte word 2 (not a bool) without moving anything.
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (refuseTo[to]) return false;
        return super.transfer(to, amount);
    }
}
