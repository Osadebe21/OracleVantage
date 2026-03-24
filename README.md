# OracleVantage

OracleVantage is an enterprise-grade, decentralized prediction market protocol built on the Stacks blockchain. Utilizing the Clarity smart contract language, the protocol enables a trust-minimized environment where users can speculate on real-world outcomes. The system is architected to prioritize security through the Checks-Effects-Interactions pattern, while incorporating an AI-driven resolution layer supported by a human-in-the-loop dispute mechanism.

---

## Table of Contents

1. Overview
2. Key Features
3. Technical Architecture
4. Data Structures & State
5. Private Functions (Internal Logic)
6. Administrative Functions (Governance)
7. Public Functions (User Interaction)
8. Read-Only Functions (Data Retrieval)
9. Security & Safety Patterns
10. Contribution Guidelines
11. MIT License

---

## Overview

In traditional prediction markets, the "Oracle Problem"—the difficulty of bringing off-chain data onto the blockchain accurately—often leads to centralization or slow resolution times. OracleVantage addresses this by implementing a multi-oracle AI strategy. Authorized AI agents resolve markets based on real-time data ingestion, while a 24-hour dispute window ensures that the community or contract owners can intervene if an AI provides a demonstrably incorrect outcome.

## Key Features

* **Dual-Layer Resolution**: Combines the speed of AI automation with the security of a manual dispute window.
* **Dynamic Fee Scaling**: Includes a configurable platform fee (default 2%) that only impacts the losing pool, ensuring winners maximize their ROI.
* **Fail-Safe Mechanisms**: Comprehensive market cancellation and refund logic to handle scenarios where an oracle fails to provide a resolution.
* **Granular Access Control**: Sophisticated management of "Authorized Oracles" to ensure only verified entities can trigger state changes.
* **Predictable Reward Logic**: Mathematical precision in reward distribution, accounting for proportional stakes and platform overhead.

---

## Technical Architecture

The contract is designed to be state-heavy to ensure data integrity across the Bitcoin-settled Stacks layers. By utilizing Clarity's trait of being non-Turing complete and interpreted, the contract's gas costs and behavior are fully predictable.

### Data Structures & State

The protocol relies on three primary data maps to maintain the lifecycle of a market:

* **Markets Map**: The central registry. It tracks the question, resolution status, block height of resolution (for the dispute window), total liquidity in both YES and NO pools, and flags for disputes or cancellations.
* **Bets Map**: A composite-key map `{ market-id, user }` that tracks individual contributions. This prevents state bloat by only storing data for active participants.
* **Authorized Oracles**: A whitelist of principals. This allows the protocol to scale from a single-admin model to a decentralized network of specialized AI agents.

---

## Private Functions (Internal Logic)

Private functions are the "engine room" of the contract, handling calculations and status checks that are not accessible to external users but are vital for internal consistency.

* **check-not-paused**: A critical guard function that asserts the global `is-paused` variable is false. This is called at the beginning of every state-changing public function to act as a circuit breaker.
* **calculate-fee**: Computes the protocol's cut based on the `platform-fee-percent`. Crucially, this is applied to the *losing pool* rather than the winners' original stakes.
* **calculate-reward**: A complex arithmetic function that determines a winner's payout. It calculates the user's share of the net losing pool (after fees) and adds it to their original stake. It uses the formula:
    $$Reward = UserBet + \frac{UserBet \times (LosingPool - Fee)}{WinningPool}$$

---

## Administrative Functions (Governance)

These functions are restricted to the `contract-owner` and are used to manage the health and parameters of the protocol.

* **set-paused**: Allows the admin to freeze all betting and claiming activity in the event of a detected vulnerability.
* **set-fee**: Updates the `platform-fee-percent`. This function contains an assertion to ensure the fee never exceeds 10%, protecting users from predatory adjustments.
* **set-oracle**: Dynamically adds or removes principals from the authorized oracle list. This allows for the rotation of AI agents or the removal of compromised nodes.
* **cancel-market**: A "God Mode" function for specific markets. If an event becomes unresolvable (e.g., a game is rained out with no makeup date), the admin can flag the market as canceled, enabling the `claim-refund` logic for all participants.
* **resolve-dispute**: The final arbiter function. If a market is flagged as `is-disputed`, the admin uses this to set the definitive outcome and reset the resolution height to allow immediate payouts.

---

## Public Functions (User Interaction)

These functions constitute the primary interface for users and automated AI agents.

* **create-market**: Initializes a new market record. It increments the `next-market-id` and sets all initial pools to zero.
* **place-bet**: The primary entry point for liquidity. It transfers STX from the user to the contract's escrow and updates both the market's total pool and the user's specific bet record.
* **resolve-market**: Called by an authorized AI Oracle. It sets the `outcome` and records the `block-height`, which starts the countdown for the dispute window.
* **dispute-market**: Any user can call this if they believe an oracle has resolved a market incorrectly. It must be called within the `dispute-window-blocks` (default 144 blocks).
* **claim-refund**: If a market is canceled, users use this to retrieve 100% of their staked STX.
* **claim-rewards**: The payout function. It verifies that the market is resolved, the dispute window has closed, and the user was on the winning side. It marks the bet as `claimed` before sending funds to prevent re-entrancy.

---

## Read-Only Functions (Data Retrieval)

Read-only functions are gas-free and essential for front-end integrations to display market data.

* **get-market-details**: Returns the full record of a market, including pools and resolution status.
* **get-bet-details**: Allows a user to check their current stake and whether they have already claimed their rewards.
* **is-oracle-active**: A helper to verify if a specific principal has the authority to resolve markets.
* **get-platform-fee-percent**: Returns the current commission rate.
* **get-dispute-window**: Returns the number of blocks required to pass before rewards can be claimed.

---

## Security & Safety Patterns

OracleVantage implements several layers of security to ensure the safety of user funds:

1.  **Escrow Isolation**: All staked funds are held by the contract principal (`as-contract`). No individual, including the admin, can withdraw these funds except through the defined `claim` or `refund` logic.
2.  **Re-entrancy Protection**: Although Clarity is naturally resistant to many re-entrancy vectors found in the EVM, OracleVantage still follows the best practice of updating the `claimed` status in the map *before* initiating the `stx-transfer?`.
3.  **The Dispute Buffer**: By enforcing a 144-block (approx. 24 hour) delay between resolution and claiming, the protocol creates a "cooling off" period where malicious or incorrect data can be caught.

---

## Contribution Guidelines

I welcome contributions to OracleVantage. Please follow these steps:
* Ensure all new functions include comprehensive error handling.
* Maintain the existing naming convention (`kebab-case`).
* Provide unit tests for any logic changes using the Clarinet framework.
* Update the README if any administrative constants or error codes are modified.

---

## MIT License

Copyright (c) 2026 OracleVantage Protocol

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---
