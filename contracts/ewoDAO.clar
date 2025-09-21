;; Constants for governance parameters
(define-constant VOTING-PERIOD u1440) ;; ~10 days in blocks (assuming 10min blocks)
(define-constant MIN-PROPOSAL-STAKE u1000000) ;; 1 STX minimum to create proposal
(define-constant EXECUTION-DELAY u144) ;; ~1 day delay before execution
(define-constant MIN-VOTE-STAKE u1) ;; Minimum stake to vote

;; Contract owner for admin functions
(define-data-var contract-owner principal tx-sender)
(define-data-var next-proposal-id uint u1)

;; Enhanced proposal structure with security fields
(define-map proposals uint { 
  proposer: principal, 
  snapshot-height: uint, 
  votes-for: uint, 
  votes-against: uint, 
  executed: bool,
  creation-height: uint,
  proposal-stake: uint
})

(define-map votes (tuple (proposal-id uint) (voter principal)) { weight: uint })

;; Enhanced proposal creation with anti-spam protection
(define-public (create-proposal (proposal-stake uint))
  (let ((proposal-id (var-get next-proposal-id)))
    (begin
      ;; Require minimum stake to prevent spam
      (asserts! (>= proposal-stake MIN-PROPOSAL-STAKE) (err u4))
      
      ;; Lock proposal stake
      (try! (stx-transfer? proposal-stake tx-sender (as-contract tx-sender)))
      
      ;; Create proposal with enhanced data
      (map-set proposals proposal-id { 
        proposer: tx-sender, 
        snapshot-height: stacks-block-height, 
        votes-for: u0, 
        votes-against: u0, 
        executed: false,
        creation-height: stacks-block-height,
        proposal-stake: proposal-stake
      })
      
      ;; Increment proposal counter
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id))))

;; Enhanced voting with time-based security
(define-public (cast-vote (id uint) (support bool) (stake uint))
  (let (
    (cost (* stake stake))
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (existing-vote (map-get? votes (tuple (proposal-id id) (voter tx-sender))))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
  )
    (begin
      ;; Check voting period is active
      (asserts! (<= stacks-block-height voting-end) (err u5))
      
      ;; Prevent double voting
      (asserts! (is-none existing-vote) (err u3))
      
      ;; Minimum stake requirement
      (asserts! (>= stake MIN-VOTE-STAKE) (err u6))
      
      ;; Transfer quadratic cost
      (try! (stx-transfer? cost tx-sender (as-contract tx-sender)))
      
      ;; Record individual vote
      (map-set votes (tuple (proposal-id id) (voter tx-sender)) { weight: stake })
      
      ;; Update proposal vote counts
      (if support
        (map-set proposals id (merge proposal-data { 
          votes-for: (+ (get votes-for proposal-data) stake) 
        }))
        (map-set proposals id (merge proposal-data { 
          votes-against: (+ (get votes-against proposal-data) stake) 
        })))
      
      (ok true))))

;; Secure proposal execution with delays and validation
(define-public (execute-proposal (id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
    (execution-time (+ voting-end EXECUTION-DELAY))
  )
    (begin
      ;; Check proposal hasn't been executed
      (asserts! (not (get executed proposal-data)) (err u7))
      
      ;; Check voting period has ended
      (asserts! (> stacks-block-height voting-end) (err u8))
      
      ;; Check execution delay has passed
      (asserts! (>= stacks-block-height execution-time) (err u9))
      
      ;; Check proposal passed (simple majority)
      (asserts! (> (get votes-for proposal-data) (get votes-against proposal-data)) (err u10))
      
      ;; Mark as executed
      (map-set proposals id (merge proposal-data { executed: true }))
      
      ;; Return proposal stake to proposer
      (try! (as-contract (stx-transfer? (get proposal-stake proposal-data) tx-sender (get proposer proposal-data))))
      
      (ok true))))

;; Admin function to update contract owner
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u11))
    (var-set contract-owner new-owner)
    (ok true)))

;; Emergency function to pause voting (admin only)
(define-data-var voting-paused bool false)

(define-public (toggle-voting-pause)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u11))
    (var-set voting-paused (not (var-get voting-paused)))
    (ok (var-get voting-paused))))

;; Enhanced read-only functions for governance state
(define-read-only (get-proposal (id uint))
  (map-get? proposals id))

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes (tuple (proposal-id proposal-id) (voter voter))))

(define-read-only (has-voted (proposal-id uint) (voter principal))
  (is-some (map-get? votes (tuple (proposal-id proposal-id) (voter voter)))))

(define-read-only (is-voting-active (id uint))
  (match (map-get? proposals id)
    proposal-data 
      (let ((voting-end (+ (get creation-height proposal-data) VOTING-PERIOD)))
        (and (<= stacks-block-height voting-end) (not (var-get voting-paused))))
    false))

(define-read-only (can-execute (id uint))
  (match (map-get? proposals id)
    proposal-data
      (let (
        (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
        (execution-time (+ voting-end EXECUTION-DELAY))
      )
        (and 
          (not (get executed proposal-data))
          (> stacks-block-height voting-end)
          (>= stacks-block-height execution-time)
          (> (get votes-for proposal-data) (get votes-against proposal-data))))
    false))

(define-read-only (get-proposal-status (id uint))
  (match (map-get? proposals id)
    proposal-data
      (let (
        (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
        (execution-time (+ voting-end EXECUTION-DELAY))
        (current-height stacks-block-height)
      )
        (if (get executed proposal-data)
          "executed"
          (if (<= current-height voting-end)
            "voting"
            (if (< current-height execution-time)
              "pending"
              (if (> (get votes-for proposal-data) (get votes-against proposal-data))
                "ready-to-execute"
                "failed")))))
    "not-found"))

(define-read-only (get-contract-owner)
  (var-get contract-owner))

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id))

(define-read-only (is-voting-paused)
  (var-get voting-paused))

;; Get governance parameters
(define-read-only (get-governance-params)
  {
    voting-period: VOTING-PERIOD,
    min-proposal-stake: MIN-PROPOSAL-STAKE,
    execution-delay: EXECUTION-DELAY,
    min-vote-stake: MIN-VOTE-STAKE
  })