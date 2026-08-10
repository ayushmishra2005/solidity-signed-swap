# SignedSwap

A Solidity EIP-712 intent settlement protocol for non-custodial ERC-20 swaps with cumulative partial fills, nonce cancellation, protocol fees, and Foundry invariant testing.

## Features

- **EIP-712 typed data signing** for human-readable order authorization
- **ECDSA signature verification** with OpenZeppelin
- **Non-custodial settlement** — contract never holds user funds
- **Cumulative partial fills** with mathematically correct rounding
- **Per-maker nonce binding** — each nonce locks to exactly one order hash
- **Individual nonce cancellation** and bulk invalidation via floor
- **Immutable protocol fee** paid by taker on top of maker's amount
- **Reentrancy protection** with checks-effects-interactions and ReentrancyGuard
- **SafeERC20** for compatibility with non-standard tokens
- **Foundry fuzz and invariant tests** proving accounting correctness

## Architecture

Single contract design:

```
src/SignedSwap.sol    — Core protocol (~200 LOC)
```

## Order Model

```solidity
struct Order {
    address maker;      // Seller
    address taker;      // Authorized buyer (address(0) = anyone)
    address sellToken;  // Token maker sells
    address buyToken;   // Token maker receives
    uint256 sellAmount; // Total to sell
    uint256 buyAmount;  // Total to receive
    uint256 nonce;      // Unique per-maker identifier
    uint256 deadline;   // Expiration timestamp
}
```

## Partial Fill Arithmetic

SignedSwap uses **cumulative accounting** to guarantee consistent rounding regardless of fill fragmentation.

For an order with `sellAmount = S` and `buyAmount = B`:

```
sellReleased(filledBuy) = floor(filledBuy × S / B)
```

Each partial fill calculates sell output as:
```
sellFill = sellReleased(filledAfter) − sellReleased(filledBefore)
```

This ensures that multiple small fills produce exactly the same total as a single large fill.

Fees use the same cumulative approach:
```
fee(filledBuy) = floor(filledBuy × feeBps / 10_000)
```

## Security Properties

- **EIP-712 domain separation** prevents cross-chain and cross-contract replay
- **Nonce-order binding** ensures each nonce commits to exactly one order
- **Cumulative accounting** eliminates fragmentation-based rounding exploits
- **Checks-effects-interactions** pattern throughout
- **ReentrancyGuard** on all state-changing external functions
- **SafeERC20** handles non-standard token return values
- **Immutable fee rate** prevents admin manipulation

## Unsupported Token Behaviors

The protocol assumes exact-transfer ERC-20 semantics:

- Fee-on-transfer tokens are **not supported**
- Rebasing tokens are **not supported**
- Native ETH is **not supported** (wrap to WETH)

## Commands

```bash
# Build
forge build

# Run all tests
forge test

# Run fuzz tests
forge test --match-contract SignedSwapFuzzTest

# Run invariant tests
forge test --match-contract SignedSwapInvariantTest

# Check formatting
forge fmt --check

# Deploy (local)
forge script script/DeploySignedSwap.s.sol --broadcast
```

## Environment Variables (Deploy)

| Variable | Description | Default |
|----------|-------------|---------|
| `FEE_BPS` | Fee in basis points (max 100) | 30 |
| `FEE_RECIPIENT` | Address to receive fees | deployer |

## License

MIT
