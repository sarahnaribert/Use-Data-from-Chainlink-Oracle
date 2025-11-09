(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_PRICE (err u101))
(define-constant ERR_ORACLE_NOT_FOUND (err u102))
(define-constant ERR_STALE_DATA (err u103))
(define-constant ERR_INSUFFICIENT_FUNDS (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_POSITION_NOT_FOUND (err u106))
(define-constant ERR_POSITION_ALREADY_EXISTS (err u107))
(define-constant ERR_INVALID_WEIGHT (err u108))
(define-constant ERR_INSUFFICIENT_SOURCES (err u109))
(define-constant ERR_PRICE_DEVIATION (err u110))
(define-constant ERR_ORACLE_SLASHED (err u111))
(define-constant ERR_REPUTATION_TOO_LOW (err u112))
(define-constant ERR_CIRCUIT_BREAKER_ACTIVE (err u113))
(define-constant ERR_INVALID_THRESHOLD (err u114))
(define-constant ERR_INSUFFICIENT_OBSERVATIONS (err u115))
(define-constant ERR_INVALID_PERIOD (err u116))

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

(define-map aggregation-config
  { asset: (string-ascii 32) }
  {
    feeds: (list 10 (string-ascii 32)),
    weights: (list 10 uint),
    min-sources: uint,
    max-deviation: uint
  }
)

(define-map oracle-reputation
  { oracle: principal }
  {
    total-updates: uint,
    accurate-updates: uint,
    score: uint,
    last-updated: uint,
    is-slashed: bool
  }
)

(define-map price-validations
  { feed-id: (string-ascii 32), block-height: uint }
  {
    predicted-price: uint,
    actual-price: uint,
    oracle: principal,
    validated: bool
  }
)

(define-map circuit-breakers
  { feed-id: (string-ascii 32) }
  {
    is-active: bool,
    threshold-percent: uint,
    cooldown-blocks: uint,
    triggered-at: uint,
    last-price: uint,
    trigger-reason: (string-ascii 64)
  }
)

(define-map price-snapshots
  { feed-id: (string-ascii 32), snapshot-height: uint }
  {
    price: uint,
    timestamp: uint
  }
)

(define-map twap-observations
  { feed-id: (string-ascii 32), observation-index: uint }
  {
    price: uint,
    timestamp: uint,
    cumulative-price: uint
  }
)

(define-map twap-config
  { feed-id: (string-ascii 32) }
  {
    observation-count: uint,
    current-index: uint,
    initialized: bool
  }
)

(define-data-var total-feeds uint u0)
(define-data-var alert-fee uint u1000000)
(define-data-var max-price-age uint u3600)
(define-data-var min-reputation-score uint u5000)
(define-data-var validation-window uint u144)
(define-data-var global-circuit-breaker bool false)
(define-data-var default-threshold-percent uint u2000)
(define-data-var default-cooldown-blocks uint u144)
(define-data-var max-twap-observations uint u100)

(define-public (add-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set oracle-reputation
      { oracle: oracle }
      {
        total-updates: u0,
        accurate-updates: u0,
        score: u10000,
        last-updated: stacks-block-height,
        is-slashed: false
      }
    )
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
    (reputation (default-to { total-updates: u0, accurate-updates: u0, score: u10000, last-updated: u0, is-slashed: false } 
                           (map-get? oracle-reputation { oracle: tx-sender })))
  )
    (asserts! oracle-authorized ERR_UNAUTHORIZED)
    (asserts! (is-some feed-data) ERR_ORACLE_NOT_FOUND)
    (asserts! (> new-price u0) ERR_INVALID_PRICE)
    (asserts! (not (get is-slashed reputation)) ERR_ORACLE_SLASHED)
    (asserts! (>= (get score reputation) (var-get min-reputation-score)) ERR_REPUTATION_TOO_LOW)
    
    (map-set price-validations
      { feed-id: feed-id, block-height: stacks-block-height }
      {
        predicted-price: new-price,
        actual-price: u0,
        oracle: tx-sender,
        validated: false
      }
    )
    
    (map-set oracle-feeds 
      { feed-id: feed-id }
      (merge (unwrap-panic feed-data) {
        price: new-price,
        updated-at: stacks-block-height
      })
    )
    
    (record-twap-observation feed-id new-price)
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
    (asserts! (not (var-get global-circuit-breaker)) ERR_CIRCUIT_BREAKER_ACTIVE)
    (asserts! (not (is-circuit-breaker-active asset)) ERR_CIRCUIT_BREAKER_ACTIVE)
    
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
    (asserts! (not (var-get global-circuit-breaker)) ERR_CIRCUIT_BREAKER_ACTIVE)
    (asserts! (not (is-circuit-breaker-active asset)) ERR_CIRCUIT_BREAKER_ACTIVE)
    
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

(define-public (configure-aggregation
  (asset (string-ascii 32))
  (feeds (list 10 (string-ascii 32)))
  (weights (list 10 uint))
  (min-sources uint)
  (max-deviation uint)
)
  (let (
    (total-weight (fold + weights u0))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-eq (len feeds) (len weights)) ERR_INVALID_WEIGHT)
    (asserts! (and (> min-sources u0) (<= min-sources (len feeds))) ERR_INSUFFICIENT_SOURCES)
    (asserts! (is-eq total-weight u10000) ERR_INVALID_WEIGHT)
    
    (map-set aggregation-config
      { asset: asset }
      {
        feeds: feeds,
        weights: weights,
        min-sources: min-sources,
        max-deviation: max-deviation
      }
    )
    (ok true)
  )
)

(define-read-only (get-aggregated-price (asset (string-ascii 32)))
  (match (map-get? aggregation-config { asset: asset })
    config
      (let (
        (prices (map get-feed-price (get feeds config)))
        (valid-prices (filter is-valid-price prices))
        (valid-count (len valid-prices))
      )
        (if (>= valid-count (get min-sources config))
          (let (
            (weighted-prices (map multiply-by-weight valid-prices (get weights config)))
            (weighted-sum (fold + weighted-prices u0))
            (weight-sum (fold + (get weights config) u0))
            (avg-price (/ weighted-sum weight-sum))
          )
            (if (is-within-deviation valid-prices avg-price (get max-deviation config))
              (ok avg-price)
              ERR_PRICE_DEVIATION
            )
          )
          ERR_INSUFFICIENT_SOURCES
        )
      )
    ERR_ORACLE_NOT_FOUND
  )
)

(define-read-only (get-aggregation-config (asset (string-ascii 32)))
  (map-get? aggregation-config { asset: asset })
)

(define-private (get-feed-price (feed-id (string-ascii 32)))
  (match (get-latest-price feed-id)
    ok-price ok-price
    err-code u0
  )
)

(define-private (is-valid-price (price uint))
  (> price u0)
)

(define-private (multiply-by-weight (price uint) (weight uint))
  (/ (* price weight) u10000)
)

(define-private (is-within-deviation (prices (list 10 uint)) (avg-price uint) (max-deviation uint))
  (let (
    (max-diff (fold max-price-diff prices u0))
    (deviation (/ (* max-diff u10000) avg-price))
  )
    (<= deviation max-deviation)
  )
)

(define-private (max-price-diff (price uint) (current-max uint))
  (let (
    (diff (if (> price current-max) (- price current-max) (- current-max price)))
  )
    (if (> diff current-max) diff current-max)
  )
)

(define-public (validate-price
  (feed-id (string-ascii 32))
  (height uint)
  (actual-price uint)
)
  (let (
    (validation-key { feed-id: feed-id, block-height: height })
    (validation (map-get? price-validations validation-key))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-some validation) ERR_ORACLE_NOT_FOUND)
    (asserts! (>= stacks-block-height (+ height (var-get validation-window))) ERR_STALE_DATA)
    
    (let (
      (validation-data (unwrap-panic validation))
      (oracle (get oracle validation-data))
      (predicted-price (get predicted-price validation-data))
      (is-accurate (is-price-accurate predicted-price actual-price))
    )
      (map-set price-validations
        validation-key
        (merge validation-data {
          actual-price: actual-price,
          validated: true
        })
      )
      
      (begin
        (unwrap-panic (update-oracle-reputation oracle is-accurate))
        (ok is-accurate)
      )
    )
  )
)

(define-public (slash-oracle (oracle principal))
  (let (
    (reputation (map-get? oracle-reputation { oracle: oracle }))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-some reputation) ERR_ORACLE_NOT_FOUND)
    
    (map-set oracle-reputation
      { oracle: oracle }
      (merge (unwrap-panic reputation) { is-slashed: true })
    )
    (map-delete authorized-oracles oracle)
    (ok true)
  )
)

(define-public (set-min-reputation-score (new-score uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-score u10000) ERR_INVALID_AMOUNT)
    (var-set min-reputation-score new-score)
    (ok true)
  )
)

(define-public (set-validation-window (new-window uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set validation-window new-window)
    (ok true)
  )
)

(define-read-only (get-oracle-reputation (oracle principal))
  (map-get? oracle-reputation { oracle: oracle })
)

(define-read-only (get-price-validation (feed-id (string-ascii 32)) (height uint))
  (map-get? price-validations { feed-id: feed-id, block-height: height })
)

(define-read-only (get-oracle-score (oracle principal))
  (match (map-get? oracle-reputation { oracle: oracle })
    reputation (ok (get score reputation))
    ERR_ORACLE_NOT_FOUND
  )
)

(define-private (update-oracle-reputation (oracle principal) (is-accurate bool))
  (let (
    (current-rep (default-to { total-updates: u0, accurate-updates: u0, score: u10000, last-updated: u0, is-slashed: false }
                             (map-get? oracle-reputation { oracle: oracle })))
    (new-total (+ (get total-updates current-rep) u1))
    (new-accurate (if is-accurate (+ (get accurate-updates current-rep) u1) (get accurate-updates current-rep)))
    (new-score (calculate-reputation-score new-accurate new-total))
  )
    (map-set oracle-reputation
      { oracle: oracle }
      {
        total-updates: new-total,
        accurate-updates: new-accurate,
        score: new-score,
        last-updated: stacks-block-height,
        is-slashed: (get is-slashed current-rep)
      }
    )
    (ok true)
  )
)

(define-private (is-price-accurate (predicted uint) (actual uint))
  (let (
    (tolerance (/ actual u20))
    (diff (if (> predicted actual) (- predicted actual) (- actual predicted)))
  )
    (<= diff tolerance)
  )
)

(define-private (calculate-reputation-score (accurate uint) (total uint))
  (if (is-eq total u0)
    u10000
    (/ (* accurate u10000) total)
  )
)

(define-public (configure-circuit-breaker
  (feed-id (string-ascii 32))
  (threshold-percent uint)
  (cooldown-blocks uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (and (> threshold-percent u0) (<= threshold-percent u10000)) ERR_INVALID_THRESHOLD)
    
    (map-set circuit-breakers
      { feed-id: feed-id }
      {
        is-active: false,
        threshold-percent: threshold-percent,
        cooldown-blocks: cooldown-blocks,
        triggered-at: u0,
        last-price: u0,
        trigger-reason: ""
      }
    )
    (ok true)
  )
)

(define-public (trigger-circuit-breaker
  (feed-id (string-ascii 32))
  (reason (string-ascii 64))
)
  (let (
    (current-price-result (get-latest-price feed-id))
    (breaker-config (map-get? circuit-breakers { feed-id: feed-id }))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-some breaker-config) ERR_ORACLE_NOT_FOUND)
    (asserts! (is-ok current-price-result) ERR_ORACLE_NOT_FOUND)
    
    (let (
      (current-price (unwrap-panic current-price-result))
      (config (unwrap-panic breaker-config))
    )
      (map-set circuit-breakers
        { feed-id: feed-id }
        (merge config {
          is-active: true,
          triggered-at: stacks-block-height,
          last-price: current-price,
          trigger-reason: reason
        })
      )
      (create-price-snapshot feed-id current-price)
      (ok true)
    )
  )
)

(define-public (auto-check-circuit-breaker (feed-id (string-ascii 32)))
  (let (
    (current-price-result (get-latest-price feed-id))
    (breaker-config (map-get? circuit-breakers { feed-id: feed-id }))
    (last-snapshot (get-recent-price-snapshot feed-id))
  )
    (asserts! (is-ok current-price-result) ERR_ORACLE_NOT_FOUND)
    (asserts! (is-some breaker-config) ERR_ORACLE_NOT_FOUND)
    (asserts! (is-some last-snapshot) (ok false))
    
    (let (
      (current-price (unwrap-panic current-price-result))
      (config (unwrap-panic breaker-config))
      (snapshot (unwrap-panic last-snapshot))
      (price-change-percent (calculate-price-change-percent 
                            (get price snapshot) 
                            current-price))
    )
      (if (> price-change-percent (get threshold-percent config))
        (begin
          (map-set circuit-breakers
            { feed-id: feed-id }
            (merge config {
              is-active: true,
              triggered-at: stacks-block-height,
              last-price: current-price,
              trigger-reason: "automatic-threshold-breach"
            })
          )
          (ok true)
        )
        (begin
          (create-price-snapshot feed-id current-price)
          (ok false)
        )
      )
    )
  )
)

(define-public (reset-circuit-breaker (feed-id (string-ascii 32)))
  (let (
    (breaker-config (map-get? circuit-breakers { feed-id: feed-id }))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-some breaker-config) ERR_ORACLE_NOT_FOUND)
    
    (let (
      (config (unwrap-panic breaker-config))
    )
      (asserts! (>= stacks-block-height (+ (get triggered-at config) (get cooldown-blocks config))) ERR_STALE_DATA)
      
      (map-set circuit-breakers
        { feed-id: feed-id }
        (merge config {
          is-active: false,
          triggered-at: u0,
          trigger-reason: ""
        })
      )
      (ok true)
    )
  )
)

(define-public (set-global-circuit-breaker (active bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set global-circuit-breaker active)
    (ok true)
  )
)

(define-public (set-default-threshold (threshold-percent uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (and (> threshold-percent u0) (<= threshold-percent u10000)) ERR_INVALID_THRESHOLD)
    (var-set default-threshold-percent threshold-percent)
    (ok true)
  )
)

(define-read-only (get-circuit-breaker-status (feed-id (string-ascii 32)))
  (map-get? circuit-breakers { feed-id: feed-id })
)

(define-read-only (is-circuit-breaker-active (feed-id (string-ascii 32)))
  (match (map-get? circuit-breakers { feed-id: feed-id })
    breaker (get is-active breaker)
    false
  )
)

(define-read-only (get-price-snapshot (feed-id (string-ascii 32)) (height uint))
  (map-get? price-snapshots { feed-id: feed-id, snapshot-height: height })
)

(define-private (create-price-snapshot (feed-id (string-ascii 32)) (price uint))
  (map-set price-snapshots
    { feed-id: feed-id, snapshot-height: stacks-block-height }
    {
      price: price,
      timestamp: stacks-block-height
    }
  )
)

(define-private (get-recent-price-snapshot (feed-id (string-ascii 32)))
  (map-get? price-snapshots { feed-id: feed-id, snapshot-height: (- stacks-block-height u1) })
)

(define-private (calculate-price-change-percent (old-price uint) (new-price uint))
  (let (
    (price-diff (if (> new-price old-price) 
                   (- new-price old-price) 
                   (- old-price new-price)))
    (change-percent (/ (* price-diff u10000) old-price))
  )
    change-percent
  )
)

(define-public (initialize-twap (feed-id (string-ascii 32)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set twap-config
      { feed-id: feed-id }
      {
        observation-count: u0,
        current-index: u0,
        initialized: true
      }
    )
    (ok true)
  )
)

(define-read-only (get-twap (feed-id (string-ascii 32)) (period-blocks uint))
  (let (
    (config (map-get? twap-config { feed-id: feed-id }))
  )
    (asserts! (is-some config) ERR_ORACLE_NOT_FOUND)
    (asserts! (> period-blocks u0) ERR_INVALID_PERIOD)
    
    (let (
      (config-data (unwrap-panic config))
      (obs-count (get observation-count config-data))
      (current-idx (get current-index config-data))
    )
      (asserts! (>= obs-count u2) ERR_INSUFFICIENT_OBSERVATIONS)
      
      (ok (calculate-twap feed-id period-blocks obs-count current-idx))
    )
  )
)

(define-read-only (get-twap-1h (feed-id (string-ascii 32)))
  (get-twap feed-id u60)
)

(define-read-only (get-twap-24h (feed-id (string-ascii 32)))
  (get-twap feed-id u1440)
)

(define-read-only (get-twap-7d (feed-id (string-ascii 32)))
  (get-twap feed-id u10080)
)

(define-read-only (get-twap-config (feed-id (string-ascii 32)))
  (map-get? twap-config { feed-id: feed-id })
)

(define-read-only (get-twap-observation (feed-id (string-ascii 32)) (index uint))
  (map-get? twap-observations { feed-id: feed-id, observation-index: index })
)

(define-private (record-twap-observation (feed-id (string-ascii 32)) (price uint))
  (let (
    (config (map-get? twap-config { feed-id: feed-id }))
  )
    (if (is-none config)
      false
      (let (
        (config-data (unwrap-panic config))
        (current-idx (get current-index config-data))
        (obs-count (get observation-count config-data))
        (previous-obs (map-get? twap-observations { feed-id: feed-id, observation-index: current-idx }))
        (previous-cumulative (if (is-some previous-obs) 
                                (get cumulative-price (unwrap-panic previous-obs)) 
                                u0))
        (new-cumulative (+ previous-cumulative price))
        (next-idx (mod (+ current-idx u1) (var-get max-twap-observations)))
      )
        (map-set twap-observations
          { feed-id: feed-id, observation-index: next-idx }
          {
            price: price,
            timestamp: stacks-block-height,
            cumulative-price: new-cumulative
          }
        )
        
        (map-set twap-config
          { feed-id: feed-id }
          {
            observation-count: (if (< obs-count (var-get max-twap-observations)) 
                                  (+ obs-count u1) 
                                  obs-count),
            current-index: next-idx,
            initialized: true
          }
        )
        true
      )
    )
  )
)

(define-private (calculate-twap 
  (feed-id (string-ascii 32)) 
  (period-blocks uint) 
  (obs-count uint) 
  (current-idx uint)
)
  (let (
    (observations-to-use (if (< period-blocks obs-count) period-blocks obs-count))
    (start-idx (if (>= current-idx observations-to-use)
                  (- current-idx observations-to-use)
                  (+ (var-get max-twap-observations) (- current-idx observations-to-use))))
    (start-obs (map-get? twap-observations { feed-id: feed-id, observation-index: start-idx }))
    (end-obs (map-get? twap-observations { feed-id: feed-id, observation-index: current-idx }))
  )
    (if (and (is-some start-obs) (is-some end-obs))
      (let (
        (start-data (unwrap-panic start-obs))
        (end-data (unwrap-panic end-obs))
        (cumulative-diff (- (get cumulative-price end-data) (get cumulative-price start-data)))
        (time-diff (- (get timestamp end-data) (get timestamp start-data)))
      )
        (if (> time-diff u0)
          (/ cumulative-diff time-diff)
          (get price end-data)
        )
      )
      u0
    )
  )
)

(define-read-only (get-contract-stats)
  {
    total-feeds: (var-get total-feeds),
    alert-fee: (var-get alert-fee),
    max-price-age: (var-get max-price-age),
    min-reputation-score: (var-get min-reputation-score),
    validation-window: (var-get validation-window),
    global-circuit-breaker: (var-get global-circuit-breaker),
    default-threshold-percent: (var-get default-threshold-percent),
    default-cooldown-blocks: (var-get default-cooldown-blocks),
    max-twap-observations: (var-get max-twap-observations),
    contract-owner: CONTRACT_OWNER
  }
)

(define-private (pow10 (n uint))
  (if (is-eq n u0) u1
    (if (is-eq n u1) u10
      (if (is-eq n u2) u100
        (if (is-eq n u3) u1000
          (if (is-eq n u4) u10000
            (if (is-eq n u5) u100000
              (if (is-eq n u6) u1000000
                (if (is-eq n u7) u10000000
                  (if (is-eq n u8) u100000000
                    (if (is-eq n u9) u1000000000
                      (if (is-eq n u10) u10000000000
                        (if (is-eq n u11) u100000000000
                          (if (is-eq n u12) u1000000000000
                            (if (is-eq n u13) u10000000000000
                              (if (is-eq n u14) u100000000000000
                                (if (is-eq n u15) u1000000000000000
                                  (if (is-eq n u16) u10000000000000000
                                    (if (is-eq n u17) u100000000000000000
                                      (if (is-eq n u18) u1000000000000000000
                                        u1
                                      )
                                    )
                                  )
                                )
                              )
                            )
                          )
                        )
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    )
  )
)

(define-read-only (get-normalized-price (feed-id (string-ascii 32)) (target-decimals uint))
  (let (
    (feed (map-get? oracle-feeds { feed-id: feed-id }))
  )
    (match feed
      some-feed
        (let (
          (price (get price some-feed))
          (decimals (get decimals some-feed))
        )
          (if (is-eq decimals target-decimals)
            (ok price)
            (let (
              (diff (if (> target-decimals decimals)
                        (- target-decimals decimals)
                        (- decimals target-decimals)))
              (scale (pow10 diff))
            )
              (if (> target-decimals decimals)
                (ok (* price scale))
                (ok (/ price scale))
              )
            )
          )
        )
      ERR_ORACLE_NOT_FOUND
    )
  )
)
