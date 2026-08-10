// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SignedSwap
/// @notice EIP-712 intent settlement for non-custodial ERC-20 swaps with cumulative partial fills
contract SignedSwap is EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Order {
        address maker;
        address taker;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 nonce;
        uint256 deadline;
    }

    struct NonceState {
        bytes32 orderHash;
        uint256 filledBuyAmount;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address sellToken,address buyToken,uint256 sellAmount,uint256 buyAmount,uint256 nonce,uint256 deadline)"
    );

    uint256 public constant MAX_FEE_BPS = 100; // 1%

    uint256 public immutable feeBps;
    address public feeRecipient;

    mapping(address maker => mapping(uint256 nonce => NonceState)) private _nonceStates;
    mapping(address maker => mapping(uint256 nonce => bool)) public nonceCancelled;
    mapping(address maker => uint256) public minValidNonce;

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 fee,
        uint256 cumulativeBuyFilled
    );

    event NonceCancelled(address indexed maker, uint256 indexed nonce);
    event NoncesInvalidatedBelow(address indexed maker, uint256 newMinNonce);
    event FeeRecipientUpdated(address indexed newFeeRecipient);

    error InvalidMaker();
    error InvalidSellToken();
    error InvalidBuyToken();
    error SameToken();
    error InvalidSellAmount();
    error InvalidBuyAmount();
    error InvalidBuyFillAmount();
    error OrderExpired();
    error InvalidTaker();
    error NonceBelowMinimum();
    error NonceCancelledError();
    error OrderHashMismatch();
    error InvalidSignature();
    error FillExceedsRemaining();
    error ZeroSellOutput();
    error MinSellAmountNotMet();
    error InvalidFeeRecipient();
    error FeeTooHigh();
    error InvalidMinNonce();
    error NotContract();

    constructor(uint256 _feeBps, address _feeRecipient) EIP712("SignedSwap", "1") Ownable(msg.sender) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();

        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    /// @notice Fills part or all of a signed order
    /// @param order The order to fill
    /// @param buyFillAmount Amount of buyToken the taker will pay toward maker's buyAmount
    /// @param minSellAmount Minimum sellToken output required for taker protection
    /// @param signature Maker's EIP-712 signature
    function fill(Order calldata order, uint256 buyFillAmount, uint256 minSellAmount, bytes calldata signature)
        external
        nonReentrant
    {
        _validateOrder(order);
        if (buyFillAmount == 0) revert InvalidBuyFillAmount();

        bytes32 orderHash = hashOrder(order);
        NonceState storage state = _nonceStates[order.maker][order.nonce];

        // First fill binds nonce to order hash; subsequent fills must match
        if (state.orderHash == bytes32(0)) {
            _verifySignature(orderHash, order.maker, signature);
            state.orderHash = orderHash;
        } else {
            if (state.orderHash != orderHash) revert OrderHashMismatch();
        }

        uint256 filledBefore = state.filledBuyAmount;
        uint256 remaining = order.buyAmount - filledBefore;
        if (buyFillAmount > remaining) revert FillExceedsRemaining();

        uint256 filledAfter = filledBefore + buyFillAmount;

        // Cumulative sell calculation: floor(filled * S / B)
        uint256 sellReleasedBefore = filledBefore.mulDiv(order.sellAmount, order.buyAmount);
        uint256 sellReleasedAfter = filledAfter.mulDiv(order.sellAmount, order.buyAmount);
        uint256 sellFill = sellReleasedAfter - sellReleasedBefore;

        if (sellFill == 0) revert ZeroSellOutput();
        if (sellFill < minSellAmount) revert MinSellAmountNotMet();

        // Cumulative fee calculation: floor(filled * feeBps / 10_000)
        uint256 feeBefore = filledBefore.mulDiv(feeBps, 10_000);
        uint256 feeAfter = filledAfter.mulDiv(feeBps, 10_000);
        uint256 incrementalFee = feeAfter - feeBefore;

        // Update state before transfers
        state.filledBuyAmount = filledAfter;

        // Transfers: taker pays buyFillAmount + fee, maker receives buyFillAmount
        IERC20(order.buyToken).safeTransferFrom(msg.sender, order.maker, buyFillAmount);

        if (incrementalFee > 0) {
            IERC20(order.buyToken).safeTransferFrom(msg.sender, feeRecipient, incrementalFee);
        }

        IERC20(order.sellToken).safeTransferFrom(order.maker, msg.sender, sellFill);

        emit OrderFilled(orderHash, order.maker, msg.sender, buyFillAmount, sellFill, incrementalFee, filledAfter);
    }

    /// @notice Cancel a single nonce for the caller
    function cancelNonce(uint256 nonce) external {
        nonceCancelled[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @notice Invalidate all nonces below the new minimum for the caller
    function invalidateNoncesBelow(uint256 newMinNonce) external {
        if (newMinNonce <= minValidNonce[msg.sender]) revert InvalidMinNonce();
        minValidNonce[msg.sender] = newMinNonce;
        emit NoncesInvalidatedBelow(msg.sender, newMinNonce);
    }

    /// @notice Update the fee recipient (owner only)
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /// @notice Compute the EIP-712 hash of an order
    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.maker,
                    order.taker,
                    order.sellToken,
                    order.buyToken,
                    order.sellAmount,
                    order.buyAmount,
                    order.nonce,
                    order.deadline
                )
            )
        );
    }

    /// @notice Get the nonce state for a maker
    function getNonceState(address maker, uint256 nonce)
        external
        view
        returns (bytes32 orderHash, uint256 filledBuyAmount)
    {
        NonceState storage state = _nonceStates[maker][nonce];
        return (state.orderHash, state.filledBuyAmount);
    }

    /// @notice Get remaining buyAmount for an order
    function remainingBuyAmount(Order calldata order) external view returns (uint256) {
        bytes32 orderHash = hashOrder(order);
        NonceState storage state = _nonceStates[order.maker][order.nonce];

        if (state.orderHash == bytes32(0)) {
            return order.buyAmount;
        }
        if (state.orderHash != orderHash) {
            return 0; // Different order bound to this nonce
        }
        return order.buyAmount - state.filledBuyAmount;
    }

    function _validateOrder(Order calldata order) internal view {
        if (order.maker == address(0)) revert InvalidMaker();
        if (order.sellToken == address(0)) revert InvalidSellToken();
        if (order.buyToken == address(0)) revert InvalidBuyToken();
        if (order.sellToken == order.buyToken) revert SameToken();
        if (order.sellAmount == 0) revert InvalidSellAmount();
        if (order.buyAmount == 0) revert InvalidBuyAmount();
        if (block.timestamp > order.deadline) revert OrderExpired();
        if (order.taker != address(0) && order.taker != msg.sender) revert InvalidTaker();
        if (order.nonce < minValidNonce[order.maker]) revert NonceBelowMinimum();
        if (nonceCancelled[order.maker][order.nonce]) revert NonceCancelledError();
        if (!_isContract(order.sellToken)) revert NotContract();
        if (!_isContract(order.buyToken)) revert NotContract();
    }

    function _verifySignature(bytes32 orderHash, address expectedSigner, bytes calldata signature) internal pure {
        address recovered = ECDSA.recover(orderHash, signature);
        if (recovered != expectedSigner) revert InvalidSignature();
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
