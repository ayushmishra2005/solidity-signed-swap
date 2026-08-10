// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SignedSwap} from "../../src/SignedSwap.sol";

/// @dev ERC20 that attempts reentrancy on transfer
contract ReentrantERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    SignedSwap public targetSwap;
    SignedSwap.Order public reentrantOrder;
    bytes public reentrantSignature;
    bool public shouldReenter;
    bool public reentered;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setReentrantParams(SignedSwap _swap, SignedSwap.Order calldata _order, bytes calldata _sig) external {
        targetSwap = _swap;
        reentrantOrder = _order;
        reentrantSignature = _sig;
        shouldReenter = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        _attemptReentry();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) return false;
        if (allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        _attemptReentry();
        return true;
    }

    function _attemptReentry() internal {
        if (shouldReenter && !reentered) {
            reentered = true;
            shouldReenter = false;
            // Attempt to reenter fill
            try targetSwap.fill(reentrantOrder, 1e18, 0, reentrantSignature) {} catch {}
        }
    }
}
