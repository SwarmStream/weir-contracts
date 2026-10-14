// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockIntake is IIntake {
    using SafeERC20 for IERC20;

    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;
    bytes4 public lastFailure;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public approvedAmount;
    bytes32 public lastRequestId;
    bytes32 public forcedId;
    uint256 public sequence;
    bool public shouldRevert;
    bool public underPull;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;
    uint256 public price = 5e17;

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function setForcedId(bytes32 id) external {
        forcedId = id;
    }

    function setRevert(bool flag) external {
        shouldRevert = flag;
    }

    function setUnderPull(bool flag) external {
        underPull = flag;
    }

    function setHook(address target, bytes memory data) external {
        hook = target;
        hookData = data;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        require(!shouldRevert, "intake unavailable");
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        lastFailure = onFailure;
        lastAsset = asset;
        lastAmount = amount;
        approvedAmount = IERC20(asset).allowance(msg.sender, address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), underPull ? amount - 1 : amount);
        if (hook != address(0)) (hookSucceeded,) = hook.call(hookData);
        requestId = forcedId == bytes32(0) ? keccak256(abi.encode(address(this), ++sequence)) : forcedId;
        lastRequestId = requestId;
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory signature)
        external
        returns (bool success, bytes memory result)
    {
        return lastCallback.target.call{gas: 200_000}(
            abi.encodeWithSelector(lastCallback.selector, requestId, a, signature)
        );
    }

    function failRequest(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)
        external
        returns (bool success, bytes memory result)
    {
        return lastCallback.target.call{gas: 200_000}(
            abi.encodeWithSelector(lastFailure, requestId, status, reason, agreed, answered, bytes(""))
        );
    }
}
