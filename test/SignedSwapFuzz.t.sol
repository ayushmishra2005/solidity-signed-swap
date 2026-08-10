// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedSwap} from "../src/SignedSwap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {NoReturnERC20} from "./mocks/NoReturnERC20.sol";
import {FalseReturnERC20} from "./mocks/FalseReturnERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SignedSwapFuzzTest is Test {
    using Math for uint256;

    SignedSwap public swap;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    uint256 internal makerPk = 0x1234;
    address internal maker;
    address internal taker = address(0xBEEF);
    address internal feeRecipient = address(0xFEE);

    uint256 constant FEE_BPS = 30;
    uint256 constant MAX_AMOUNT = 1e30;
    uint256 constant MIN_AMOUNT = 1;

    function setUp() public {
        maker = vm.addr(makerPk);
        swap = new SignedSwap(FEE_BPS, feeRecipient);
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
    }

    function _createOrder(uint256 sellAmount, uint256 buyAmount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (SignedSwap.Order memory)
    {
        return SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            nonce: nonce,
            deadline: deadline
        });
    }

    function _signOrder(SignedSwap.Order memory order, uint256 pk) internal view returns (bytes memory) {
        bytes32 orderHash = swap.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _setupFill(uint256 sellAmount, uint256 buyAmount) internal {
        tokenA.mint(maker, sellAmount);
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, buyAmount + (buyAmount * FEE_BPS) / 10_000 + 1);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);
    }

    // ============ Token Behavior Tests ============

    function test_token_noReturnERC20Works() public {
        NoReturnERC20 noReturnA = new NoReturnERC20("NoReturn A", "NRA", 18);
        NoReturnERC20 noReturnB = new NoReturnERC20("NoReturn B", "NRB", 18);

        noReturnA.mint(maker, 100e18);
        vm.prank(maker);
        noReturnA.approve(address(swap), type(uint256).max);

        noReturnB.mint(taker, 100e18);
        vm.prank(taker);
        noReturnB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(noReturnA),
            buyToken: address(noReturnB),
            sellAmount: 50e18,
            buyAmount: 25e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 25e18, 0, sig);

        assertEq(noReturnA.balanceOf(taker), 50e18);
        assertEq(noReturnB.balanceOf(maker), 25e18);
    }

    function test_token_falseReturnERC20Reverts() public {
        FalseReturnERC20 falseReturnB = new FalseReturnERC20("False B", "FRB", 18);

        tokenA.mint(maker, 100e18);
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        falseReturnB.mint(taker, 100e18);
        vm.prank(taker);
        falseReturnB.approve(address(swap), type(uint256).max);

        falseReturnB.setShouldFail(true);

        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(falseReturnB),
            sellAmount: 50e18,
            buyAmount: 25e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 25e18, 0, sig);
    }

    function test_token_insufficientMakerBalance() public {
        tokenA.mint(maker, 10e18); // Less than sellAmount
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, 100e18);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = _createOrder(50e18, 25e18, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 25e18, 0, sig);
    }

    function test_token_insufficientMakerAllowance() public {
        tokenA.mint(maker, 100e18);
        vm.prank(maker);
        tokenA.approve(address(swap), 10e18); // Less than sellAmount

        tokenB.mint(taker, 100e18);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = _createOrder(50e18, 25e18, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 25e18, 0, sig);
    }

    function test_token_insufficientTakerBalance() public {
        tokenA.mint(maker, 100e18);
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, 10e18); // Less than buyAmount + fee
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = _createOrder(50e18, 25e18, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 25e18, 0, sig);
    }

    function test_token_insufficientTakerAllowance() public {
        tokenA.mint(maker, 100e18);
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, 100e18);
        vm.prank(taker);
        tokenB.approve(address(swap), 10e18); // Less than needed

        SignedSwap.Order memory order = _createOrder(50e18, 25e18, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 25e18, 0, sig);
    }

    function test_token_transferFailureRollsBackState() public {
        FalseReturnERC20 falseReturnA = new FalseReturnERC20("False A", "FRA", 18);

        falseReturnA.mint(maker, 100e18);
        vm.prank(maker);
        falseReturnA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, 100e18);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(falseReturnA),
            buyToken: address(tokenB),
            sellAmount: 50e18,
            buyAmount: 25e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signOrder(order, makerPk);

        // First fill succeeds
        vm.prank(taker);
        swap.fill(order, 10e18, 0, sig);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, 10e18);

        // Make sellToken fail
        falseReturnA.setShouldFail(true);

        // Second fill should fail and not update state
        vm.prank(taker);
        vm.expectRevert();
        swap.fill(order, 10e18, 0, sig);

        // State should be unchanged
        (, uint256 filledAfter) = swap.getNonceState(maker, 0);
        assertEq(filledAfter, 10e18);
    }

    function test_token_reentrancyProtected() public {
        ReentrantERC20 reentrantA = new ReentrantERC20("Reentrant", "REE", 18);

        reentrantA.mint(maker, 200e18);
        vm.prank(maker);
        reentrantA.approve(address(swap), type(uint256).max);

        tokenB.mint(taker, 200e18);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);

        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(reentrantA),
            buyToken: address(tokenB),
            sellAmount: 100e18,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signOrder(order, makerPk);

        // Set up reentrancy attempt
        reentrantA.setReentrantParams(swap, order, sig);

        // Fill should succeed but reentrancy should be blocked
        vm.prank(taker);
        swap.fill(order, 25e18, 0, sig);

        // Should have only filled once
        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, 25e18);
    }

    // ============ Partial Fill Arithmetic Fuzz Tests ============

    function testFuzz_partialFill_fillNeverExceedsBuyAmount(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 buyFillAmount
    ) public {
        sellAmount = bound(sellAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyAmount = bound(buyAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyFillAmount = bound(buyFillAmount, 1, buyAmount);

        // Ensure sellFill > 0
        uint256 expectedSellFill = buyFillAmount.mulDiv(sellAmount, buyAmount);
        vm.assume(expectedSellFill > 0);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, buyFillAmount, 0, sig);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertLe(filled, buyAmount);
    }

    function testFuzz_partialFill_sellReleasedNeverExceedsSellAmount(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 buyFillAmount
    ) public {
        sellAmount = bound(sellAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyAmount = bound(buyAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyFillAmount = bound(buyFillAmount, 1, buyAmount);

        uint256 expectedSellFill = buyFillAmount.mulDiv(sellAmount, buyAmount);
        vm.assume(expectedSellFill > 0);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        swap.fill(order, buyFillAmount, 0, sig);

        uint256 sellReceived = tokenA.balanceOf(taker) - takerSellBefore;
        assertLe(sellReceived, sellAmount);
    }

    function testFuzz_partialFill_cumulativeSellEqualsFloor(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 buyFillAmount
    ) public {
        sellAmount = bound(sellAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyAmount = bound(buyAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyFillAmount = bound(buyFillAmount, 1, buyAmount);

        uint256 expectedSellFill = buyFillAmount.mulDiv(sellAmount, buyAmount);
        vm.assume(expectedSellFill > 0);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        swap.fill(order, buyFillAmount, 0, sig);

        uint256 sellReceived = tokenA.balanceOf(taker) - takerSellBefore;
        uint256 expectedCumulativeSell = buyFillAmount.mulDiv(sellAmount, buyAmount);

        assertEq(sellReceived, expectedCumulativeSell);
    }

    function testFuzz_partialFill_sequenceIndependence(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 fill1,
        uint256 fill2
    ) public {
        sellAmount = bound(sellAmount, 1e12, MAX_AMOUNT);
        buyAmount = bound(buyAmount, 1e12, MAX_AMOUNT);
        uint256 totalFill = buyAmount;
        fill1 = bound(fill1, 1, totalFill - 1);
        fill2 = totalFill - fill1;

        // Ensure each fill produces non-zero sell output
        vm.assume(fill1.mulDiv(sellAmount, buyAmount) > 0);
        vm.assume(fill2.mulDiv(sellAmount, buyAmount) > 0);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.startPrank(taker);
        swap.fill(order, fill1, 0, sig);
        swap.fill(order, fill2, 0, sig);
        vm.stopPrank();

        uint256 totalSellReceived = tokenA.balanceOf(taker) - takerSellBefore;

        // Total sell should equal floor(buyAmount * sellAmount / buyAmount) = sellAmount
        assertEq(totalSellReceived, sellAmount);
    }

    function testFuzz_fullFill_exactAmounts(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyAmount = bound(buyAmount, MIN_AMOUNT, MAX_AMOUNT);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        uint256 makerBuyBefore = tokenB.balanceOf(maker);
        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        assertEq(tokenB.balanceOf(maker) - makerBuyBefore, buyAmount);
        assertEq(tokenA.balanceOf(taker) - takerSellBefore, sellAmount);
    }

    // ============ Fee Fragmentation Tests ============

    function testFuzz_fee_fragmentationEquals(uint256 sellAmount, uint256 buyAmount, uint256 numFills) public {
        sellAmount = bound(sellAmount, 1e12, MAX_AMOUNT);
        buyAmount = bound(buyAmount, 1e12, MAX_AMOUNT);
        numFills = bound(numFills, 2, 10);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        uint256 feeBefore = tokenB.balanceOf(feeRecipient);
        uint256 fillPerRound = buyAmount / numFills;

        vm.assume(fillPerRound.mulDiv(sellAmount, buyAmount) > 0);

        vm.startPrank(taker);
        for (uint256 i = 0; i < numFills - 1; i++) {
            swap.fill(order, fillPerRound, 0, sig);
        }

        // Fill remainder
        (, uint256 filled) = swap.getNonceState(maker, 0);
        uint256 remaining = buyAmount - filled;
        if (remaining > 0 && remaining.mulDiv(sellAmount, buyAmount) > 0) {
            swap.fill(order, remaining, 0, sig);
        }
        vm.stopPrank();

        (, uint256 finalFilled) = swap.getNonceState(maker, 0);
        uint256 expectedTotalFee = finalFilled.mulDiv(FEE_BPS, 10_000);
        uint256 actualTotalFee = tokenB.balanceOf(feeRecipient) - feeBefore;

        assertEq(actualTotalFee, expectedTotalFee);
    }

    // ============ Extreme Values Tests ============

    function testFuzz_extremeValues_noOverflow(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1, type(uint128).max);
        buyAmount = bound(buyAmount, 1, type(uint128).max);

        _setupFill(sellAmount, buyAmount);

        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, buyAmount);
    }

    // ============ Nonce Fuzz Tests ============

    function testFuzz_nonce_uniqueHashes(uint256 nonce1, uint256 nonce2, uint256 sellAmount, uint256 buyAmount)
        public
        view
    {
        vm.assume(nonce1 != nonce2);
        sellAmount = bound(sellAmount, MIN_AMOUNT, MAX_AMOUNT);
        buyAmount = bound(buyAmount, MIN_AMOUNT, MAX_AMOUNT);

        SignedSwap.Order memory order1 = _createOrder(sellAmount, buyAmount, nonce1, block.timestamp + 1 hours);
        SignedSwap.Order memory order2 = _createOrder(sellAmount, buyAmount, nonce2, block.timestamp + 1 hours);

        bytes32 hash1 = swap.hashOrder(order1);
        bytes32 hash2 = swap.hashOrder(order2);

        assertTrue(hash1 != hash2);
    }

    function testFuzz_nonce_minNonceBoundary(uint256 minNonce, uint256 orderNonce) public {
        minNonce = bound(minNonce, 1, type(uint128).max);
        orderNonce = bound(orderNonce, 0, minNonce - 1);

        vm.prank(maker);
        swap.invalidateNoncesBelow(minNonce);

        _setupFill(100e18, 50e18);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, orderNonce, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.NonceBelowMinimum.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function testFuzz_nonce_equalToMinIsValid(uint256 minNonce) public {
        minNonce = bound(minNonce, 1, type(uint128).max);

        vm.prank(maker);
        swap.invalidateNoncesBelow(minNonce);

        _setupFill(100e18, 50e18);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, minNonce, block.timestamp + 1 hours);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig);

        (, uint256 filled) = swap.getNonceState(maker, minNonce);
        assertEq(filled, 50e18);
    }

    // ============ Deadline Fuzz Tests ============

    function testFuzz_deadline_validUntil(uint256 deadline, uint256 fillTime) public {
        deadline = bound(deadline, block.timestamp + 1, block.timestamp + 365 days);
        fillTime = bound(fillTime, block.timestamp, deadline);

        vm.warp(fillTime);

        _setupFill(100e18, 50e18);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, deadline);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig);
    }

    function testFuzz_deadline_invalidAfter(uint256 deadline, uint256 fillTime) public {
        deadline = bound(deadline, block.timestamp, block.timestamp + 365 days);
        fillTime = bound(fillTime, deadline + 1, deadline + 365 days);

        _setupFill(100e18, 50e18);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, deadline);
        bytes memory sig = _signOrder(order, makerPk);

        vm.warp(fillTime);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.OrderExpired.selector);
        swap.fill(order, 50e18, 0, sig);
    }
}
