### Betting.sol README

---

## Betting.sol

**Betting.sol** is a smart contract designed for a decentralized betting platform. Users can create bets, join existing bets, resolve bets, withdraw winnings, and request refunds if a bet is canceled or not matched.

### Features

- **Create Bet**: Users can create a new bet with a specified amount, expiration time, and type (long or short).
- **Join Bet**: Users can join an existing bet by providing the required amount.
- **Resolve Bet**: The contract's designated bot resolves the bet by determining the winner based on asset prices.
- **Withdraw**: The winner of a resolved bet can withdraw their winnings.
- **Refund**: Users can request a refund if a bet is canceled or not matched.

### Prerequisites

- Solidity ^0.8.0
- Chainlink and OpenZeppelin contracts
- Foundry for testing and deployment

### Functions Overview

#### createBet

```solidity
function createBet(uint256 _usdcAmount, uint256 _expireTime, bool _isLong) external onlyRegistered hasSufficientBalance(_usdcAmount) returns (uint256 betID)
```
Creates a new bet with the specified parameters.

#### joinBet

```solidity
function joinBet(uint256 _betID, uint256 _usdcAmount) public payable onlyRegistered hasSufficientBalance(_usdcAmount) validBetID(_betID) returns (uint256)
```
Allows a user to join an existing bet.

#### resolveBet

```solidity
function resolveBet(uint256 _betID) external onlyBot validBetID(_betID)
```
Resolves a bet by determining the winner based on the closing price.

#### withdraw

```solidity
function withdraw(uint256 _betID) external validBetID(_betID)
```
Allows the winner to withdraw the reward from a resolved bet.

#### refundBet

```solidity
function refundBet(uint256 _betID) external validBetID(_betID)
```
Allows users to refund their bets if the bet is canceled or not matched.

### Events

- **BetCreated**: Emitted when a new bet is created.
- **BetActive**: Emitted when a bet becomes active.
- **BetClosed**: Emitted when a bet is resolved.
- **BetWithdrawn**: Emitted when winnings are withdrawn.
- **BetCancelled**: Emitted when a bet is refunded.

---

### Using Foundry for Testing and Deployment

**Foundry** is a blazing fast, portable, and modular toolkit for Ethereum application development written in Rust.

#### Installation

Follow the [Foundry installation guide](https://github.com/foundry-rs/foundry#installation) to install Foundry.

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

#### Initialization

Initialize a new Foundry project:

```bash
forge init betting-platform
cd betting-platform
```

#### Configuration

Ensure `Betting.sol` is in the `src` directory.

Update the `foundry.toml` configuration file as needed.

#### Compilation

Compile the smart contracts:

```bash
forge build
```

#### Testing

Write your tests in the `test` directory.

Run tests using:

```bash
forge test
```

#### Deployment

Create a deployment script in the `script` directory.

Run the deployment script:

```bash
forge script script/DeployBetting.s.sol --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY>
```

Replace `<YOUR_RPC_URL>` with your Ethereum node URL and `<YOUR_PRIVATE_KEY>` with your private key.

#### Example Deployment Script (DeployBetting.s.sol)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {Betting} from "../src/Betting.sol";

contract DeployBetting is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy Betting contract
        Betting betting = new Betting(/* constructor arguments if any */);

        vm.stopBroadcast();
    }
}
```

### Additional Resources

- [Solidity Documentation](https://docs.soliditylang.org/)
- [Chainlink Documentation](https://docs.chain.link/)
- [OpenZeppelin Documentation](https://docs.openzeppelin.com/)

---