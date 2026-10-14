// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token with switches for rejected transfer behavior and reentrancy probes.
contract MockToken is ERC20 {
    uint8 private immutable _decimals;
    bool public tax;
    bool public fail;
    mapping(address => bool) public blocked;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;
    bytes4 public hookError;

    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setTax(bool enabled) external {
        tax = enabled;
    }

    function setFail(bool enabled) external {
        fail = enabled;
    }

    function setBlocked(address account, bool enabled) external {
        blocked[account] = enabled;
    }

    function setHook(address target, bytes memory data) external {
        hook = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!fail && !blocked[from] && !blocked[to], "token blocked");
            if (hook != address(0)) {
                address target = hook;
                hook = address(0);
                bytes memory result;
                (hookSucceeded, result) = target.call(hookData);
                if (result.length >= 4) hookError = bytes4(result);
            }
            if (tax && amount > 0) {
                super._update(from, address(0), 1);
                --amount;
            }
        }
        super._update(from, to, amount);
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FalseReturnToken {
    function balanceOf(address) external pure returns (uint256) {
        return 1_000_000;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}
