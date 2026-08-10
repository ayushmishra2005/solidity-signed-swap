// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedSwap} from "../src/SignedSwap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SignedSwapTest is Test {
    SignedSwap public swap;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    uint256 internal makerPk = 0x1234;
    address internal maker;
    address internal taker = address(0xBEEF);
    address internal feeRecipient = address(0xFEE);

    uint256 constant FEE_BPS = 30; // 0.3%

    function setUp() public {
        maker = vm.addr(makerPk);

        swap = new SignedSwap(FEE_BPS, feeRecipient);
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // Setup maker with sellToken and approval
        tokenA.mint(maker, 1000e18);
        vm.prank(maker);
        tokenA.approve(address(swap), type(uint256).max);

        // Setup taker with buyToken and approval
        tokenB.mint(taker, 1000e18);
        vm.prank(taker);
        tokenB.approve(address(swap), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createOrder(uint256 sellAmount, uint256 buyAmount, uint256 nonce, uint256 deadline, address takerAddr)
        internal
        view
        returns (SignedSwap.Order memory)
    {
        return SignedSwap.Order({
            maker: maker,
            taker: takerAddr,
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

    // ============ Hash/Signature Tests ============

    function test_hashOrder_deterministic() public view {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes32 hash1 = swap.hashOrder(order);
        bytes32 hash2 = swap.hashOrder(order);
        assertEq(hash1, hash2);
    }

    function test_fill_validSignature() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig);

        (bytes32 boundHash, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(boundHash, swap.hashOrder(order));
        assertEq(filled, 50e18);
    }

    function test_fill_revert_wrongSigner() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        uint256 wrongPk = 0x5678;
        bytes memory sig = _signOrder(order, wrongPk);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidSignature.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function test_fill_revert_modifiedField() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        // Modify the order after signing
        order.buyAmount = 49e18;

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidSignature.selector);
        swap.fill(order, 49e18, 0, sig);
    }

    function test_fill_revert_signatureFromDifferentDeployment() public {
        SignedSwap swap2 = new SignedSwap(FEE_BPS, feeRecipient);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));

        // Sign with swap2's domain
        bytes32 orderHash = swap2.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, orderHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Try to use on swap1
        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidSignature.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    // ============ Full Fill Tests ============

    function test_fill_full_correctTransfers() public {
        uint256 sellAmount = 100e18;
        uint256 buyAmount = 50e18;
        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 makerSellBefore = tokenA.balanceOf(maker);
        uint256 makerBuyBefore = tokenB.balanceOf(maker);
        uint256 takerSellBefore = tokenA.balanceOf(taker);
        uint256 takerBuyBefore = tokenB.balanceOf(taker);
        uint256 feeBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        // Expected fee: floor(50e18 * 30 / 10_000) = 0.15e18
        uint256 expectedFee = (buyAmount * FEE_BPS) / 10_000;

        assertEq(tokenA.balanceOf(maker), makerSellBefore - sellAmount, "maker sell");
        assertEq(tokenB.balanceOf(maker), makerBuyBefore + buyAmount, "maker buy");
        assertEq(tokenA.balanceOf(taker), takerSellBefore + sellAmount, "taker sell");
        assertEq(tokenB.balanceOf(taker), takerBuyBefore - buyAmount - expectedFee, "taker buy");
        assertEq(tokenB.balanceOf(feeRecipient), feeBefore + expectedFee, "fee");
    }

    function test_fill_full_cumulativeFillTracked() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, 50e18);
    }

    // ============ Partial Fill Tests ============

    function test_fill_partial_singlePartial() public {
        uint256 sellAmount = 100e18;
        uint256 buyAmount = 50e18;
        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 buyFill = 25e18;
        uint256 expectedSellFill = (buyFill * sellAmount) / buyAmount; // 50e18

        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        swap.fill(order, buyFill, 0, sig);

        assertEq(tokenA.balanceOf(taker), takerSellBefore + expectedSellFill);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, buyFill);
    }

    function test_fill_partial_severalFills() public {
        uint256 sellAmount = 100e18;
        uint256 buyAmount = 50e18;
        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 makerBuyBefore = tokenB.balanceOf(maker);
        uint256 takerSellBefore = tokenA.balanceOf(taker);

        // Fill in 3 parts: 10e18, 15e18, 25e18 = 50e18 total
        vm.startPrank(taker);
        swap.fill(order, 10e18, 0, sig);
        swap.fill(order, 15e18, 0, sig);
        swap.fill(order, 25e18, 0, sig);
        vm.stopPrank();

        // Maker should receive full buyAmount
        assertEq(tokenB.balanceOf(maker), makerBuyBefore + buyAmount);
        // Taker should receive full sellAmount
        assertEq(tokenA.balanceOf(taker), takerSellBefore + sellAmount);

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, buyAmount);
    }

    function test_fill_partial_finalFillReleasesAll() public {
        uint256 sellAmount = 100e18;
        uint256 buyAmount = 33e18; // Non-round number for rounding tests
        SignedSwap.Order memory order = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 takerSellBefore = tokenA.balanceOf(taker);

        // Fill in small amounts
        vm.startPrank(taker);
        swap.fill(order, 10e18, 0, sig);
        swap.fill(order, 10e18, 0, sig);
        swap.fill(order, 13e18, 0, sig); // Final fill
        vm.stopPrank();

        // Taker should receive exactly sellAmount
        assertEq(tokenA.balanceOf(taker), takerSellBefore + sellAmount);
    }

    function test_fill_partial_fragmentationSameAsFullFill() public {
        // Test that multiple small fills give same aggregate result as single fill
        uint256 sellAmount = 100e18;
        uint256 buyAmount = 37e18;

        // Setup second swap for comparison
        SignedSwap swap2 = new SignedSwap(FEE_BPS, feeRecipient);
        uint256 maker2Pk = 0x9999;
        address maker2 = vm.addr(maker2Pk);

        tokenA.mint(maker2, sellAmount);
        vm.prank(maker2);
        tokenA.approve(address(swap2), type(uint256).max);

        // Taker needs to approve swap2 as well
        vm.prank(taker);
        tokenB.approve(address(swap2), type(uint256).max);

        // Fragmented fill
        SignedSwap.Order memory order1 = _createOrder(sellAmount, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig1 = _signOrder(order1, makerPk);

        vm.startPrank(taker);
        swap.fill(order1, 7e18, 0, sig1);
        swap.fill(order1, 13e18, 0, sig1);
        swap.fill(order1, 17e18, 0, sig1);
        vm.stopPrank();

        uint256 fragmentedMakerBuy = tokenB.balanceOf(maker);
        uint256 fragmentedTakerSell = tokenA.balanceOf(taker);

        // Single fill on swap2
        SignedSwap.Order memory order2 = SignedSwap.Order({
            maker: maker2,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 hash2 = swap2.hashOrder(order2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(maker2Pk, hash2);
        bytes memory sig2 = abi.encodePacked(r, s, v);

        uint256 maker2BuyBefore = tokenB.balanceOf(maker2);
        uint256 takerSellBefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        swap2.fill(order2, buyAmount, 0, sig2);

        uint256 singleMakerBuy = tokenB.balanceOf(maker2) - maker2BuyBefore;
        uint256 singleTakerSell = tokenA.balanceOf(taker) - takerSellBefore;

        // Both should result in same values
        assertEq(fragmentedMakerBuy, singleMakerBuy, "maker buy mismatch");
        assertEq(fragmentedTakerSell, singleTakerSell, "taker sell mismatch");
    }

    // ============ Order Validation Tests ============

    function test_fill_revert_zeroMaker() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: address(0),
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: 100e18,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidMaker.selector);
        swap.fill(order, 50e18, 0, "");
    }

    function test_fill_revert_zeroSellToken() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(0),
            buyToken: address(tokenB),
            sellAmount: 100e18,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidSellToken.selector);
        swap.fill(order, 50e18, 0, "");
    }

    function test_fill_revert_zeroBuyToken() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidBuyToken.selector);
        swap.fill(order, 50e18, 0, "");
    }

    function test_fill_revert_sameToken() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenA),
            sellAmount: 100e18,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.SameToken.selector);
        swap.fill(order, 50e18, 0, "");
    }

    function test_fill_revert_zeroSellAmount() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: 0,
            buyAmount: 50e18,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidSellAmount.selector);
        swap.fill(order, 50e18, 0, "");
    }

    function test_fill_revert_zeroBuyAmount() public {
        SignedSwap.Order memory order = SignedSwap.Order({
            maker: maker,
            taker: address(0),
            sellToken: address(tokenA),
            buyToken: address(tokenB),
            sellAmount: 100e18,
            buyAmount: 0,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidBuyAmount.selector);
        swap.fill(order, 0, 0, "");
    }

    function test_fill_revert_zeroFillAmount() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.InvalidBuyFillAmount.selector);
        swap.fill(order, 0, 0, sig);
    }

    function test_fill_revert_zeroSellOutput() public {
        // Create order where tiny fill produces zero sell output
        // sellAmount=1, buyAmount=1000 -> fillBuy=1 -> sellFill = floor(1*1/1000) = 0
        SignedSwap.Order memory order = _createOrder(1, 1000, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        tokenA.mint(maker, 1);
        tokenB.mint(taker, 1);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.ZeroSellOutput.selector);
        swap.fill(order, 1, 0, sig);
    }

    function test_fill_revert_expired() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.OrderExpired.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function test_fill_exactDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, deadline, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.warp(deadline);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig); // Should succeed at exact deadline
    }

    function test_fill_revert_invalidTaker() public {
        address specificTaker = address(0xCAFE);
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, specificTaker);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker); // Wrong taker
        vm.expectRevert(SignedSwap.InvalidTaker.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function test_fill_revert_fillExceedsRemaining() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 30e18, 0, sig); // Fill 30e18

        vm.prank(taker);
        vm.expectRevert(SignedSwap.FillExceedsRemaining.selector);
        swap.fill(order, 30e18, 0, sig); // Try to fill 30e18 more (only 20e18 remaining)
    }

    function test_fill_revert_minSellAmountNotMet() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        // buyFill = 10e18 -> sellFill = 20e18, but require 30e18
        vm.prank(taker);
        vm.expectRevert(SignedSwap.MinSellAmountNotMet.selector);
        swap.fill(order, 10e18, 30e18, sig);
    }

    // ============ Nonce Tests ============

    function test_nonce_firstFillBinds() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 25e18, 0, sig);

        (bytes32 boundHash,) = swap.getNonceState(maker, 0);
        assertEq(boundHash, swap.hashOrder(order));
    }

    function test_nonce_subsequentFillSameOrder() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.startPrank(taker);
        swap.fill(order, 25e18, 0, sig);
        swap.fill(order, 25e18, 0, sig); // Should work
        vm.stopPrank();

        (, uint256 filled) = swap.getNonceState(maker, 0);
        assertEq(filled, 50e18);
    }

    function test_nonce_revert_differentOrderSameNonce() public {
        SignedSwap.Order memory order1 = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig1 = _signOrder(order1, makerPk);

        vm.prank(taker);
        swap.fill(order1, 25e18, 0, sig1);

        // Create different order with same nonce
        SignedSwap.Order memory order2 = _createOrder(200e18, 100e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig2 = _signOrder(order2, makerPk);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.OrderHashMismatch.selector);
        swap.fill(order2, 50e18, 0, sig2);
    }

    function test_cancelNonce() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(maker);
        swap.cancelNonce(0);

        assertTrue(swap.nonceCancelled(maker, 0));

        vm.prank(taker);
        vm.expectRevert(SignedSwap.NonceCancelledError.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function test_cancelNonce_afterPartialFill() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 25e18, 0, sig);

        vm.prank(maker);
        swap.cancelNonce(0);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.NonceCancelledError.selector);
        swap.fill(order, 25e18, 0, sig);
    }

    function test_cancelNonce_unauthorizedUser() public {
        address attacker = address(0xDEAD);

        vm.prank(attacker);
        swap.cancelNonce(0); // This cancels attacker's nonce 0, not maker's

        // Maker's nonce should still be valid
        assertFalse(swap.nonceCancelled(maker, 0));

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig); // Should succeed
    }

    function test_invalidateNoncesBelow() public {
        vm.prank(maker);
        swap.invalidateNoncesBelow(10);

        assertEq(swap.minValidNonce(maker), 10);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 5, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        vm.expectRevert(SignedSwap.NonceBelowMinimum.selector);
        swap.fill(order, 50e18, 0, sig);
    }

    function test_invalidateNoncesBelow_revert_cannotDecrease() public {
        vm.startPrank(maker);
        swap.invalidateNoncesBelow(10);

        vm.expectRevert(SignedSwap.InvalidMinNonce.selector);
        swap.invalidateNoncesBelow(5);

        vm.expectRevert(SignedSwap.InvalidMinNonce.selector);
        swap.invalidateNoncesBelow(10); // Same value also rejected
        vm.stopPrank();
    }

    function test_nonce_equalToFloorIsValid() public {
        vm.prank(maker);
        swap.invalidateNoncesBelow(10);

        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 10, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 50e18, 0, sig); // Nonce 10 should be valid
    }

    // ============ Fee Tests ============

    function test_fee_paidOnTopByTaker() public {
        uint256 buyAmount = 100e18;
        SignedSwap.Order memory order = _createOrder(200e18, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 expectedFee = (buyAmount * FEE_BPS) / 10_000;
        uint256 takerBuyBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        // Taker pays buyAmount + fee
        assertEq(tokenB.balanceOf(taker), takerBuyBefore - buyAmount - expectedFee);
    }

    function test_fee_makerReceivesFullBuyAmount() public {
        uint256 buyAmount = 100e18;
        SignedSwap.Order memory order = _createOrder(200e18, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 makerBuyBefore = tokenB.balanceOf(maker);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        assertEq(tokenB.balanceOf(maker), makerBuyBefore + buyAmount);
    }

    function test_fee_recipientReceivesCorrectAmount() public {
        uint256 buyAmount = 100e18;
        SignedSwap.Order memory order = _createOrder(200e18, buyAmount, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        uint256 expectedFee = (buyAmount * FEE_BPS) / 10_000;
        uint256 feeBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(taker);
        swap.fill(order, buyAmount, 0, sig);

        assertEq(tokenB.balanceOf(feeRecipient), feeBefore + expectedFee);
    }

    function test_fee_immutable() public view {
        assertEq(swap.feeBps(), FEE_BPS);
        // feeBps is immutable, no setter exists
    }

    function test_fee_recipientCanBeChanged() public {
        address newRecipient = address(0x1234);

        swap.setFeeRecipient(newRecipient);

        assertEq(swap.feeRecipient(), newRecipient);
    }

    function test_fee_revert_invalidRecipient() public {
        vm.expectRevert(SignedSwap.InvalidFeeRecipient.selector);
        swap.setFeeRecipient(address(0));
    }

    function test_fee_revert_onlyOwnerCanChange() public {
        vm.prank(taker);
        vm.expectRevert();
        swap.setFeeRecipient(address(0x5678));
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(SignedSwap.FeeTooHigh.selector);
        new SignedSwap(101, feeRecipient); // 101 bps > MAX_FEE_BPS (100)
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(SignedSwap.InvalidFeeRecipient.selector);
        new SignedSwap(FEE_BPS, address(0));
    }

    // ============ View Functions ============

    function test_remainingBuyAmount_unboundNonce() public view {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        assertEq(swap.remainingBuyAmount(order), 50e18);
    }

    function test_remainingBuyAmount_partiallyFilled() public {
        SignedSwap.Order memory order = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        swap.fill(order, 20e18, 0, sig);

        assertEq(swap.remainingBuyAmount(order), 30e18);
    }

    function test_remainingBuyAmount_differentOrderBound() public {
        SignedSwap.Order memory order1 = _createOrder(100e18, 50e18, 0, block.timestamp + 1 hours, address(0));
        bytes memory sig1 = _signOrder(order1, makerPk);

        vm.prank(taker);
        swap.fill(order1, 25e18, 0, sig1);

        // Query different order with same nonce
        SignedSwap.Order memory order2 = _createOrder(200e18, 100e18, 0, block.timestamp + 1 hours, address(0));
        assertEq(swap.remainingBuyAmount(order2), 0); // Different order bound
    }
}
