// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev An ERC-20 that re-enters a target during every transfer in or out of a contract, as an ERC-777-style
/// token or a malicious stream token would. Each armed attack fires once; its outcome is recorded so a test can
/// assert the re-entrant call was refused and why.
contract ReentrantToken is ERC20 {
    struct Attack {
        address target;
        bytes data;
    }

    Attack private _attack;
    bool public armed;
    uint256 public attempts;
    bool public lastSucceeded;
    bytes4 public lastError;

    constructor() ERC20("Reentrant", "RNT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes memory data) external {
        _attack = Attack(target, data);
        armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (armed && from != address(0) && to != address(0)) {
            armed = false;
            ++attempts;
            (bool ok, bytes memory result) = _attack.target.call(_attack.data);
            lastSucceeded = ok;
            lastError = result.length >= 4 ? bytes4(result) : bytes4(0);
        }
        super._update(from, to, amount);
    }
}

/// @dev Charges a flat fee of one minor unit on every transfer between accounts: a fee-on-transfer token.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount > 0) {
            super._update(from, address(0), 1);
            amount -= 1;
        }
        super._update(from, to, amount);
    }
}

/// @dev Holds balances honestly but reports failure from every transfer, as some legacy tokens do.
contract FalseReturningToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return false;
    }
}
