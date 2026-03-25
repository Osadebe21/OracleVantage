;; contract title: AI-Powered Decentralized Prediction Markets
;; This contract allows users to create prediction markets, place bets (YES/NO) on future events,
;; and resolve markets using authorized AI oracles.
;; 
;; Features added in v2:
;; - Multiple AI Oracles support.
;; - Dispute Mechanism: Users can dispute an AI's resolution within a time window.
;; - Market Cancellation & Refunds: Safe fallback if an oracle fails to resolve.
;; - Platform Fees: Protocol takes a small fee from winning pools.
;; - Circuit Breaker: Admin can pause the contract in emergencies.
;; - Event Logging: Emits print statements for all major state changes.

;; =========================================================================
;; constants
;; =========================================================================

(define-constant contract-owner tx-sender)

;; Error codes
(define-constant err-unauthorized (err u100))
(define-constant err-market-exists (err u101))
(define-constant err-market-not-found (err u102))
(define-constant err-market-resolved (err u103))
(define-constant err-market-unresolved (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-invalid-outcome (err u106))
(define-constant err-already-claimed (err u107))
(define-constant err-no-bets (err u108))
(define-constant err-paused (err u109))
(define-constant err-market-canceled (err u110))
(define-constant err-not-canceled (err u111))
(define-constant err-dispute-window-passed (err u112))
(define-constant err-already-disputed (err u113))
(define-constant err-dispute-active (err u114))

;; =========================================================================
;; data maps and vars
;; =========================================================================

;; Map to store prediction market details
(define-map markets
    { market-id: uint }
    {
        creator: principal,
        question: (string-ascii 128),
        resolved: bool,
        resolution-height: uint,
        outcome: (optional bool), ;; true = YES, false = NO
        total-yes-pool: uint,
        total-no-pool: uint,
        is-canceled: bool,
        is-disputed: bool
    }
)

;; Map to store individual bets for a specific market
(define-map bets
    { market-id: uint, user: principal }
    { yes-amount: uint, no-amount: uint, claimed: bool }
)

;; Map to store authorized AI oracles
(define-map authorized-oracles { oracle: principal } { active: bool })

;; Contract states
(define-data-var next-market-id uint u1)
(define-data-var is-paused bool false)

;; Platform settings
(define-data-var platform-fee-percent uint u2) ;; 2% default fee
(define-data-var dispute-window-blocks uint u144) ;; ~24 hours in Bitcoin blocks

;; Initialize contract owner as the first oracle
(map-set authorized-oracles { oracle: contract-owner } { active: true })

;; =========================================================================
;; private functions
;; =========================================================================

;; Helper to ensure the contract is not paused
(define-private (check-not-paused)
    (begin
        (asserts! (not (var-get is-paused)) err-paused)
        (ok true)
    )
)

;; Calculate the platform fee
(define-private (calculate-fee (amount uint))
    (/ (* amount (var-get platform-fee-percent)) u100)
)

;; Calculate proportional reward based on user's winning bet and the total pools
(define-private (calculate-reward (user-bet uint) (winning-pool uint) (losing-pool uint))
    (let
        (
            (total-pool (+ winning-pool losing-pool))
            (fee (calculate-fee losing-pool))
            (net-losing-pool (- losing-pool fee))
        )
        ;; user-bet + (user-bet / winning-pool) * net-losing-pool
        (+ user-bet (/ (* user-bet net-losing-pool) winning-pool))
    )
)

;; =========================================================================
;; admin functions
;; =========================================================================

;; Pause or unpause the contract
(define-public (set-paused (paused bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set is-paused paused)
        (print { event: "set-paused", paused: paused })
        (ok true)
    )
)

;; Update platform fee (max 10%)
(define-public (set-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= new-fee u10) err-invalid-amount)
        (var-set platform-fee-percent new-fee)
        (print { event: "set-fee", new-fee: new-fee })
        (ok true)
    )
)

;; Add or remove authorized AI Oracles
(define-public (set-oracle (oracle principal) (active bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (map-set authorized-oracles { oracle: oracle } { active: active })
        (print { event: "set-oracle", oracle: oracle, active: active })
        (ok true)
    )
)

;; Cancel a market (if oracle fails to resolve or is broken)
(define-public (cancel-market (market-id uint))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (not (get resolved market)) err-market-resolved)
        
        (map-set markets
            { market-id: market-id }
            (merge market { is-canceled: true, resolved: true })
        )
        (print { event: "cancel-market", market-id: market-id })
        (ok true)
    )
)

;; =========================================================================
;; public functions (core logic)
;; =========================================================================

;; Create a new prediction market
(define-public (create-market (question (string-ascii 128)))
    (let
        (
            (market-id (var-get next-market-id))
        )
        (try! (check-not-paused))
        
        (map-insert markets
            { market-id: market-id }
            {
                creator: tx-sender,
                question: question,
                resolved: false,
                resolution-height: u0,
                outcome: none,
                total-yes-pool: u0,
                total-no-pool: u0,
                is-canceled: false,
                is-disputed: false
            }
        )
        (var-set next-market-id (+ market-id u1))
        (print { event: "create-market", market-id: market-id, creator: tx-sender })
        (ok market-id)
    )
)

;; Place a bet on a specific market (is-yes: true for YES, false for NO)
(define-public (place-bet (market-id uint) (amount uint) (is-yes bool))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
            (current-bet (default-to { yes-amount: u0, no-amount: u0, claimed: false } (map-get? bets { market-id: market-id, user: tx-sender })))
        )
        (try! (check-not-paused))
        
        ;; Security checks
        (asserts! (not (get resolved market)) err-market-resolved)
        (asserts! (not (get is-canceled market)) err-market-canceled)
        (asserts! (> amount u0) err-invalid-amount)
        
        ;; Transfer funds from user to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update market pools
        (map-set markets
            { market-id: market-id }
            (merge market 
                {
                    total-yes-pool: (if is-yes (+ (get total-yes-pool market) amount) (get total-yes-pool market)),
                    total-no-pool: (if is-yes (get total-no-pool market) (+ (get total-no-pool market) amount))
                }
            )
        )
        
        ;; Update user bets
        (map-set bets
            { market-id: market-id, user: tx-sender }
            (merge current-bet
                {
                    yes-amount: (if is-yes (+ (get yes-amount current-bet) amount) (get yes-amount current-bet)),
                    no-amount: (if is-yes (get no-amount current-bet) (+ (get no-amount current-bet) amount))
                }
            )
        )
        (print { event: "place-bet", market-id: market-id, user: tx-sender, amount: amount, is-yes: is-yes })
        (ok true)
    )
)

;; Resolve a market (Only authorized AI Oracles can call this)
(define-public (resolve-market (market-id uint) (winning-outcome bool))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
            (oracle-status (default-to { active: false } (map-get? authorized-oracles { oracle: tx-sender })))
        )
        (try! (check-not-paused))
        
        ;; Security checks
        (asserts! (get active oracle-status) err-unauthorized)
        (asserts! (not (get resolved market)) err-market-resolved)
        (asserts! (not (get is-canceled market)) err-market-canceled)
        
        ;; Update market state and start dispute window
        (map-set markets
            { market-id: market-id }
            (merge market 
                { 
                    resolved: true, 
                    resolution-height: block-height,
                    outcome: (some winning-outcome) 
                }
            )
        )
        (print { event: "resolve-market", market-id: market-id, outcome: winning-outcome, oracle: tx-sender })
        (ok true)
    )
)

;; Dispute an AI Oracle's resolution
;; Users can flag a resolution as incorrect within the dispute window.
;; Admin will step in to finalize.
(define-public (dispute-market (market-id uint))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
            (blocks-passed (- block-height (get resolution-height market)))
        )
        (try! (check-not-paused))
        
        ;; Security checks
        (asserts! (get resolved market) err-market-unresolved)
        (asserts! (not (get is-canceled market)) err-market-canceled)
        (asserts! (not (get is-disputed market)) err-already-disputed)
        (asserts! (<= blocks-passed (var-get dispute-window-blocks)) err-dispute-window-passed)
        
        ;; Update market to disputed state
        (map-set markets
            { market-id: market-id }
            (merge market { is-disputed: true })
        )
        (print { event: "dispute-market", market-id: market-id, user: tx-sender })
        (ok true)
    )
)

;; Admin overriding a disputed market
(define-public (resolve-dispute (market-id uint) (final-outcome bool))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (get is-disputed market) err-market-not-found) ;; Must be disputed
        
        ;; Update market state and remove dispute lock
        (map-set markets
            { market-id: market-id }
            (merge market 
                { 
                    outcome: (some final-outcome),
                    is-disputed: false,
                    resolution-height: u0 ;; Reset to allow immediate claiming
                }
            )
        )
        (print { event: "resolve-dispute", market-id: market-id, final-outcome: final-outcome })
        (ok true)
    )
)

;; Claim Refunds for a canceled market
(define-public (claim-refund (market-id uint))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
            (user-bet (unwrap! (map-get? bets { market-id: market-id, user: tx-sender }) err-no-bets))
            (has-claimed (get claimed user-bet))
            (total-staked (+ (get yes-amount user-bet) (get no-amount user-bet)))
        )
        (try! (check-not-paused))
        
        ;; Security checks
        (asserts! (get is-canceled market) err-not-canceled)
        (asserts! (not has-claimed) err-already-claimed)
        (asserts! (> total-staked u0) err-invalid-amount)
        
        ;; Effect
        (map-set bets
            { market-id: market-id, user: tx-sender }
            (merge user-bet { claimed: true })
        )
        
        ;; Interaction
        (print { event: "claim-refund", market-id: market-id, user: tx-sender, amount: total-staked })
        (as-contract (stx-transfer? total-staked tx-sender tx-sender))
    )
)

;; =========================================================================
;; read-only functions
;; =========================================================================

(define-read-only (get-market-details (market-id uint))
    (map-get? markets { market-id: market-id })
)

(define-read-only (get-bet-details (market-id uint) (user principal))
    (map-get? bets { market-id: market-id, user: user })
)

(define-read-only (is-oracle-active (oracle principal))
    (get active (default-to { active: false } (map-get? authorized-oracles { oracle: oracle })))
)

(define-read-only (get-platform-fee-percent)
    (var-get platform-fee-percent)
)

(define-read-only (get-dispute-window)
    (var-get dispute-window-blocks)
)

;; =========================================================================
;; The final code snippet: Claim Rewards for a resolved market (40+ lines)
;; =========================================================================
;; This function allows users to claim their winnings after a market is resolved.
;; It performs several crucial security checks:
;; 1. Ensures the market exists, is resolved, and NOT canceled.
;; 2. Ensures the dispute window has passed and no active disputes exist.
;; 3. Ensures the user hasn't already claimed their reward (preventing double-spend).
;; 4. Calculates the proportional reward based on the winning pool size minus fees.
;; 5. Updates the user's claimed status BEFORE transferring funds (Checks-Effects-Interactions pattern).
(define-public (claim-rewards (market-id uint))
    (let
        (
            (market (unwrap! (map-get? markets { market-id: market-id }) err-market-not-found))
            (user-bet (unwrap! (map-get? bets { market-id: market-id, user: tx-sender }) err-no-bets))
            (is-resolved (get resolved market))
            (is-canceled (get is-canceled market))
            (is-disputed (get is-disputed market))
            (winning-outcome (unwrap! (get outcome market) err-market-unresolved))
            (has-claimed (get claimed user-bet))
            (yes-pool (get total-yes-pool market))
            (no-pool (get total-no-pool market))
            (blocks-passed (- block-height (get resolution-height market)))
        )
        (try! (check-not-paused))
        
        ;; Security: Market must be resolved and not canceled
        (asserts! is-resolved err-market-unresolved)
        (asserts! (not is-canceled) err-market-canceled)
        
        ;; Security: Dispute window must have passed, and no active disputes
        (asserts! (not is-disputed) err-dispute-active)
        (asserts! (>= blocks-passed (var-get dispute-window-blocks)) err-dispute-active)
        
        ;; Security: Prevent double claiming
        (asserts! (not has-claimed) err-already-claimed)
        
        (let
            (
                (reward-amount
                    (if winning-outcome
                        ;; YES won
                        (if (> (get yes-amount user-bet) u0)
                            (calculate-reward (get yes-amount user-bet) yes-pool no-pool)
                            u0)
                        ;; NO won
                        (if (> (get no-amount user-bet) u0)
                            (calculate-reward (get no-amount user-bet) no-pool yes-pool)
                            u0)
                    )
                )
            )
            ;; Security: Only process if there is a reward to claim
            (asserts! (> reward-amount u0) err-invalid-amount)
            
            ;; Effect: Mark as claimed BEFORE transferring to prevent re-entrancy
            (map-set bets
                { market-id: market-id, user: tx-sender }
                (merge user-bet { claimed: true })
            )
            
            ;; Interaction: Transfer the calculated reward from contract to user
            (print { event: "claim-rewards", market-id: market-id, user: tx-sender, reward: reward-amount })
            (as-contract (stx-transfer? reward-amount tx-sender tx-sender))
        )
    )
)


