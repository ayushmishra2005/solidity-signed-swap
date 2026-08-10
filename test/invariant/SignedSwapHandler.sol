// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedSwap} from "../../src/SignedSwap.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SignedSwapHandler is Test {
    using Math for uint256;

    SignedSwap public swap;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    uint256 public constant FEE_BPS = 30;
    address public feeRecipient;

    // Actors
    uint256[] public makerPks;
    address[] public makers;
    address[] public takers;

    // Order tracking
    struct OrderInfo {
        SignedSwap.Order order;
        bytes signature;
        bool created;
    }

    mapping(address maker => mapping(uint256 nonce => OrderInfo)) public orderInfos;

    // Ghost variables for invariant checking
    uint256 public ghost_totalBuyFilled;
    uint256 public ghost_totalSellReleased;
    uint256 public ghost_totalFees;
    uint256 public ghost_tokenAMinted;
    uint256 public ghost_tokenBMinted;

    // Track cancelled nonces
    mapping(address => mapping(uint256 => bool)) public ghost_cancelled;

    // Track min valid nonces
    mapping(address => uint256) public ghost_minValidNonce;

    constructor(SignedSwap _swap, MockERC20 _tokenA, MockERC20 _tokenB, address _feeRecipient) {
        swap = _swap;
        tokenA = _tokenA;
        tokenB = _tokenB;
        feeRecipient = _feeRecipient;

        // Create actors
        for (uint256 i = 0; i < 3; i++) {
            uint256 pk = uint256(keccak256(abi.encode("maker", i))) % (2 ** 128) + 1;
            makerPks.push(pk);
            makers.push(vm.addr(pk));
        }

        for (uint256 i = 0; i < 3; i++) {
            takers.push(makeAddr(string(abi.encode("taker", i))));
        }
    }

    function createOrder(uint256 makerIdx, uint256 nonce, uint256 sellAmount, uint256 buyAmount, uint256 deadlineOffset)
        external
    {
        makerIdx = bound(makerIdx, 0, makers.length - 1);
        nonce = bound(nonce, swap.minValidNonce(makers[makerIdx]), type(uint64).max);
        sellAmount = bound(sellAmount, 1e12, 1e24);
        buyAmount = bound(buyAmount, 1e12, 1e24);
        deadlineOffset = bound(deadlineOffset, 1, 365 days);

        address maker = makers[makerIdx];

        // Skip if order already exists for this nonce
        if (orderInfos[maker][nonce].created) return;

        // Mint tokens to maker
        tokenA.mint(maker, sellAmount);
        ghost_tokenAMinted += sellAmount;
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            nonce: nonce,
            deadline: block.timestamp + deadlineOffset
        });

        bytes32 orderHash = swap.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPks[makerIdx], orderHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        orderInfos[maker][nonce] = OrderInfo({order: order, signature: sig, created: true});
    }

    function fillOrder(uint256 makerIdx, uint256 nonce, uint256 takerIdx, uint256 buyFillAmount) external {
        makerIdx = bound(makerIdx, 0, makers.length - 1);
        takerIdx = bound(takerIdx, 0, takers.length - 1);

        address maker = makers[makerIdx];
        address taker = takers[takerIdx];

        OrderInfo storage info = orderInfos[maker][nonce];
        if (!info.created) return;
        if (block.timestamp > info.order.deadline) return;
        if (swap.nonceCancelled(maker, nonce)) return;
        if (nonce < swap.minValidNonce(maker)) return;

        (, uint256 filled) = swap.getNonceState(maker, nonce);
        uint256 remaining = info.order.buyAmount - filled;
        if (remaining == 0) return;

        buyFillAmount = bound(buyFillAmount, 1, remaining);

        // Check if sellFill would be 0
        uint256 expectedSellFill = (filled + buyFillAmount).mulDiv(info.order.sellAmount, info.order.buyAmount)
            - filled.mulDiv(info.order.sellAmount, info.order.buyAmount);
        if (expectedSellFill == 0) return;

        // Mint buyToken to taker (with fee)
        uint256 totalTakerPay =
            buyFillAmount + (filled + buyFillAmount).mulDiv(FEE_BPS, 10_000) - filled.mulDiv(FEE_BPS, 10_000);
        tokenB.mint(taker, totalTakerPay);
        ghost_tokenBMinted += totalTakerPay;
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        uint256 takerSellBefore = tokenA.balanceOf(taker);
        uint256 feeBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        try swap.fill(info.order, buyFillAmount, 0, info.signature) {
            ghost_totalBuyFilled += buyFillAmount;
            ghost_totalSellReleased += tokenA.balanceOf(taker) - takerSellBefore;
            ghost_totalFees += tokenB.balanceOf(feeRecipient) - feeBefore;
        } catch {}
    }

    function cancelNonce(uint256 makerIdx, uint256 nonce) external {
        makerIdx = bound(makerIdx, 0, makers.length - 1);
        address maker = makers[makerIdx];

        vm.prank(maker);
        swap.cancelNonce(nonce);
        ghost_cancelled[maker][nonce] = true;
    }

    function invalidateNoncesBelow(uint256 makerIdx, uint256 newMin) external {
        makerIdx = bound(makerIdx, 0, makers.length - 1);
        address maker = makers[makerIdx];

        uint256 currentMin = swap.minValidNonce(maker);
        newMin = bound(newMin, currentMin + 1, currentMin + 1000);

        vm.prank(maker);
        swap.invalidateNoncesBelow(newMin);
        ghost_minValidNonce[maker] = newMin;
    }

    function warpTime(uint256 delta) external {
        delta = bound(delta, 0, 30 days);
        vm.warp(block.timestamp + delta);
    }

    // Getters for invariant tests
    function getMaker(uint256 idx) external view returns (address) {
        return makers[idx % makers.length];
    }

    function getTaker(uint256 idx) external view returns (address) {
        return takers[idx % takers.length];
    }

    function getMakerCount() external view returns (uint256) {
        return makers.length;
    }
}
