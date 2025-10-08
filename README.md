# 🔗 Chainlink Oracle Integration Contract

A Clarity smart contract that demonstrates oracle integration by consuming off-chain price data, managing trading positions, and providing price alerts on the Stacks blockchain.

## 🚀 Features

- 📊 **Price Feed Management**: Create and manage multiple oracle price feeds
- 🔐 **Oracle Authorization**: Secure oracle management with authorized updaters
- 💹 **Trading Positions**: Open long/short positions based on oracle prices
- 🚨 **Price Alerts**: Set custom price alerts with automatic triggering
- ⏰ **Data Freshness**: Built-in stale data protection
- 📈 **P&L Calculation**: Real-time profit/loss tracking

## 🛠️ Contract Functions

### 👑 Owner Functions

#### `add-oracle`
Authorize an oracle to update price feeds
```clarity
(contract-call? .use-data-from-chainlink-oracle add-oracle 'SP1234...)
```

#### `create-price-feed`
Create a new price feed
```clarity
(contract-call? .use-data-from-chainlink-oracle create-price-feed "BTC-USD" "Bitcoin to USD" u8)
```

### 🔄 Oracle Functions

#### `update-price`
Update price data (authorized oracles only)
```clarity
(contract-call? .use-data-from-chainlink-oracle update-price "BTC-USD" u4500000000000)
```

### 💰 Trading Functions

#### `open-position`
Open a trading position
```clarity
(contract-call? .use-data-from-chainlink-oracle open-position "BTC-USD" u1000000 true)
```

#### `close-position`
Close an existing position
```clarity
(contract-call? .use-data-from-chainlink-oracle close-position "BTC-USD")
```

### 🔔 Alert Functions

#### `set-price-alert`
Set a price alert (requires fee payment)
```clarity
(contract-call? .use-data-from-chainlink-oracle set-price-alert "BTC-USD" u5000000000000 true)
```

#### `trigger-alert`
Trigger a price alert when conditions are met
```clarity
(contract-call? .use-data-from-chainlink-oracle trigger-alert 'SP1234... "BTC-USD")
```

## 📖 Read-Only Functions

### `get-latest-price`
Get the latest price for a feed
```clarity
(contract-call? .use-data-from-chainlink-oracle get-latest-price "BTC-USD")
```

### `get-user-position`
Get user's position details
```clarity
(contract-call? .use-data-from-chainlink-oracle get-user-position 'SP1234... "BTC-USD")
```

### `get-position-pnl`
Calculate current P&L for a position
```clarity
(contract-call? .use-data-from-chainlink-oracle get-position-pnl 'SP1234... "BTC-USD")
```

## 🎯 Usage Examples

### Setting up a BTC Price Feed

1. **Create the feed** (owner only):
```bash
clarinet console
```
```clarity
(contract-call? .use-data-from-chainlink-oracle create-price-feed "BTC-USD" "Bitcoin to USD Price Feed" u8)
```

2. **Authorize an oracle**:
```clarity
(contract-call? .use-data-from-chainlink-oracle add-oracle 'SP2J6ZY48GV1EZ5V2V5RB9MP66SW86PYKKNRV9EJ7)
```

3. **Update price data**:
```clarity
(contract-call? .use-data-from-chainlink-oracle update-price "BTC-USD" u4500000000000)
```

### Opening a Trading Position

```clarity
(contract-call? .use-data-from-chainlink-oracle open-position "BTC-USD" u1000000 true)
```

### Setting Price Alerts

```clarity
(contract-call? .use-data-from-chainlink-oracle set-price-alert "BTC-USD" u5000000000000 true)
```

## ⚙️ Configuration

- **Alert Fee**: 1 STX (adjustable by owner)
- **Max Price Age**: 3600 blocks (adjustable by owner)
- **Price Decimals**: Configurable per feed

## 🔒 Security Features

- Owner-only administrative functions
- Oracle authorization system
- Stale data protection
- Input validation and error handling
- Position existence checks

## 🧪 Testing

