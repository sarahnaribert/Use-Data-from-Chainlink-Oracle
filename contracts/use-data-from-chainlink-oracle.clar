(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_PRICE (err u101))
(define-constant ERR_ORACLE_NOT_FOUND (err u102))
(define-constant ERR_STALE_DATA (err u103))
(define-constant ERR_INSUFFICIENT_FUNDS (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_POSITION_NOT_FOUND (err u106))
(define-constant ERR_POSITION_ALREADY_EXISTS (err u107))

(define-map oracle-feeds 
  { feed-id: (string-ascii 32) }
  { 
    price: uint,
    decimals: uint,
    updated-at: uint,
    description: (string-ascii 64),
    is-active: bool
  }
)

(define-map authorized-oracles principal bool)

(define-map user-positions
  { user: principal, asset: (string-ascii 32) }
  {
    amount: uint,
    entry-price: uint,
    timestamp: uint,
    is-long: bool
  }
)

(define-map price-alerts
  { user: principal, feed-id: (string-ascii 32) }
  {
    target-price: uint,
    is-above: bool,
    is-active: bool,
    created-at: uint
  }
)

(define-data-var total-feeds uint u0)
(define-data-var alert-fee uint u1000000)
(define-data-var max-price-age uint u3600)

(define-public (add-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (ok (map-set authorized-oracles oracle true))
  )
)

(define-public (remove-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (ok (map-delete authorized-oracles oracle))
  )
)

(define-public (create-price-feed 
  (feed-id (string-ascii 32))
  (description (string-ascii 64))
  (decimals uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set oracle-feeds 
      { feed-id: feed-id }
      {
        price: u0,
        decimals: decimals,
        updated-at: u0,
        description: description,
        is-active: true
      }
    )
    (var-set total-feeds (+ (var-get total-feeds) u1))
    (ok true)
  )
)

(define-public (update-price 
  (feed-id (string-ascii 32))
  (new-price uint)
)
  (let (
    (oracle-authorized (default-to false (map-get? authorized-oracles tx-sender)))
    (feed-data (map-get? oracle-feeds { feed-id: feed-id }))
  )
    (asserts! oracle-authorized ERR_UNAUTHORIZED)
    (asserts! (is-some feed-data) ERR_ORACLE_NOT_FOUND)
    (asserts! (> new-price u0) ERR_INVALID_PRICE)
    
    (map-set oracle-feeds 
      { feed-id: feed-id }
      (merge (unwrap-panic feed-data) {
        price: new-price,
        updated-at: stacks-block-height
      })
    )
    (ok new-price)
  )
)

(define-public (open-position
  (asset (string-ascii 32))
  (amount uint)
  (is-long bool)
)
  (let (
    (current-price (get-latest-price asset))
    (position-key { user: tx-sender, asset: asset })
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (is-ok current-price) ERR_ORACLE_NOT_FOUND)
    (asserts! (is-none (map-get? user-positions position-key)) ERR_POSITION_ALREADY_EXISTS)
    
    (map-set user-positions
      position-key
      {
        amount: amount,
        entry-price: (unwrap-panic current-price),
        timestamp: stacks-block-height,
        is-long: is-long
      }
    )
    (ok true)
  )
)

(define-public (close-position (asset (string-ascii 32)))
  (let (
    (position-key { user: tx-sender, asset: asset })
    (position (map-get? user-positions position-key))
    (current-price (get-latest-price asset))
  )
    (asserts! (is-some position) ERR_POSITION_NOT_FOUND)
    (asserts! (is-ok current-price) ERR_ORACLE_NOT_FOUND)
    
    (map-delete user-positions position-key)
    (ok (calculate-pnl 
      (unwrap-panic position)
      (unwrap-panic current-price)
    ))
  )
)

(define-public (set-price-alert
  (feed-id (string-ascii 32))
  (target-price uint)
  (is-above bool)
)
  (let (
    (alert-key { user: tx-sender, feed-id: feed-id })
  )
    (asserts! (> target-price u0) ERR_INVALID_PRICE)
    (asserts! (>= (stx-get-balance tx-sender) (var-get alert-fee)) ERR_INSUFFICIENT_FUNDS)
    
    (try! (stx-transfer? (var-get alert-fee) tx-sender CONTRACT_OWNER))
    
    (map-set price-alerts
      alert-key
      {
        target-price: target-price,
        is-above: is-above,
        is-active: true,
        created-at: stacks-block-height
      }
    )
    (ok true)
  )
)

(define-public (trigger-alert
  (user principal)
  (feed-id (string-ascii 32))
)
  (let (
    (alert-key { user: user, feed-id: feed-id })
    (alert (map-get? price-alerts alert-key))
    (current-price (get-latest-price feed-id))
  )
    (asserts! (is-some alert) ERR_ORACLE_NOT_FOUND)
    (asserts! (is-ok current-price) ERR_ORACLE_NOT_FOUND)
    
    (let (
      (alert-data (unwrap-panic alert))
      (price (unwrap-panic current-price))
    )
      (asserts! (get is-active alert-data) ERR_ORACLE_NOT_FOUND)
      (asserts! 
        (if (get is-above alert-data)
          (>= price (get target-price alert-data))
          (<= price (get target-price alert-data))
        )
        ERR_INVALID_PRICE
      )
      
      (map-set price-alerts
        alert-key
        (merge alert-data { is-active: false })
      )
      (ok true)
    )
  )
)

(define-public (set-alert-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set alert-fee new-fee)
    (ok true)
  )
)

(define-public (set-max-price-age (new-age uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set max-price-age new-age)
    (ok true)
  )
)

(define-read-only (get-latest-price (feed-id (string-ascii 32)))
  (match (map-get? oracle-feeds { feed-id: feed-id })
    feed-data 
      (if (and 
            (get is-active feed-data)
            (< (- stacks-block-height (get updated-at feed-data)) (var-get max-price-age))
          )
        (ok (get price feed-data))
        ERR_STALE_DATA
      )
    ERR_ORACLE_NOT_FOUND
  )
)

(define-read-only (get-feed-info (feed-id (string-ascii 32)))
  (map-get? oracle-feeds { feed-id: feed-id })
)

(define-read-only (get-user-position (user principal) (asset (string-ascii 32)))
  (map-get? user-positions { user: user, asset: asset })
)

(define-read-only (get-price-alert (user principal) (feed-id (string-ascii 32)))
  (map-get? price-alerts { user: user, feed-id: feed-id })
)

(define-read-only (is-oracle-authorized (oracle principal))
  (default-to false (map-get? authorized-oracles oracle))
)

(define-read-only (get-position-pnl (user principal) (asset (string-ascii 32)))
  (match (map-get? user-positions { user: user, asset: asset })
    position
      (match (get-latest-price asset)
        current-price (ok (calculate-pnl position current-price))
        error-code (err error-code)
      )
    ERR_POSITION_NOT_FOUND
  )
)

(define-private (calculate-pnl (position {amount: uint, entry-price: uint, timestamp: uint, is-long: bool}) (current-price uint))
  (let (
    (price-diff (if (get is-long position)
                   (if (> current-price (get entry-price position))
                     (- current-price (get entry-price position))
                     (- (get entry-price position) current-price))
                   (if (> (get entry-price position) current-price)
                     (- (get entry-price position) current-price)
                     (- current-price (get entry-price position)))))
    (is-profit (if (get is-long position)
                 (> current-price (get entry-price position))
                 (> (get entry-price position) current-price)))
  )
    {
      pnl: (* (get amount position) price-diff),
      is-profit: is-profit,
      percentage: (/ (* price-diff u10000) (get entry-price position))
    }
  )
)

(define-read-only (get-contract-stats)
  {
    total-feeds: (var-get total-feeds),
    alert-fee: (var-get alert-fee),
    max-price-age: (var-get max-price-age),
    contract-owner: CONTRACT_OWNER
  }
)