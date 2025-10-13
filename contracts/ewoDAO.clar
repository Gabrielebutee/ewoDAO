;; Constants for governance parameters
(define-constant VOTING-PERIOD u1440) ;; ~10 days in blocks (assuming 10min blocks)
(define-constant MIN-PROPOSAL-STAKE u1000000) ;; 1 STX minimum to create proposal
(define-constant EXECUTION-DELAY u144) ;; ~1 day delay before execution
(define-constant MIN-VOTE-STAKE u1) ;; Minimum stake to vote

;; Additional constants for cancellation system
(define-constant CANCELLATION-THRESHOLD u75) ;; 75% of votes needed to cancel
(define-constant EMERGENCY-CANCELLATION-PERIOD u72) ;; ~12 hours for emergency cancellation

;; Contract owner for admin functions
(define-data-var contract-owner principal tx-sender)
(define-data-var next-proposal-id uint u1)

;; Enhanced proposal structure with cancellation fields
(define-map proposals uint { 
  proposer: principal, 
  snapshot-height: uint, 
  votes-for: uint, 
  votes-against: uint, 
  executed: bool,
  creation-height: uint,
  proposal-stake: uint,
  cancelled: bool,
  cancellation-votes: uint,
  stake-slashed: bool
})

(define-map votes (tuple (proposal-id uint) (voter principal)) { weight: uint })

;; Track cancellation votes separately
(define-map cancellation-votes (tuple (proposal-id uint) (voter principal)) { weight: uint })

;; Enhanced proposal creation with anti-spam protection
(define-public (create-proposal (proposal-stake uint))
  (let ((proposal-id (var-get next-proposal-id)))
    (begin
      ;; Require minimum stake to prevent spam
      (asserts! (>= proposal-stake MIN-PROPOSAL-STAKE) (err u4))
      
      ;; Lock proposal stake
      (try! (stx-transfer? proposal-stake tx-sender (as-contract tx-sender)))
      
      ;; Create proposal with enhanced data including cancellation fields
      (map-set proposals proposal-id { 
        proposer: tx-sender, 
        snapshot-height: stacks-block-height, 
        votes-for: u0, 
        votes-against: u0, 
        executed: false,
        creation-height: stacks-block-height,
        proposal-stake: proposal-stake,
        cancelled: false,
        cancellation-votes: u0,
        stake-slashed: false
      })
      
      ;; Increment proposal counter
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id))))

;; Enhanced voting with time-based security and CRITICAL BUG FIX
(define-public (cast-vote (id uint) (support bool) (stake uint))
  (let (
    (cost (* stake stake))
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (existing-vote (map-get? votes (tuple (proposal-id id) (voter tx-sender))))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
  )
    (begin
      ;; CRITICAL FIX: Check if voting is paused
      (asserts! (not (var-get voting-paused)) (err u12))
      
      ;; Check voting period is active
      (asserts! (<= stacks-block-height voting-end) (err u5))
      
      ;; Cannot vote on cancelled proposals
      (asserts! (not (get cancelled proposal-data)) (err u14))
      
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

;; Admin emergency cancellation (within first 12 hours)
(define-public (emergency-cancel-proposal (id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (emergency-window (+ (get creation-height proposal-data) EMERGENCY-CANCELLATION-PERIOD))
  )
    (begin
      ;; Only contract owner can emergency cancel
      (asserts! (is-eq tx-sender (var-get contract-owner)) (err u11))
      
      ;; Must be within emergency window
      (asserts! (<= stacks-block-height emergency-window) (err u13))
      
      ;; Cannot cancel already executed or cancelled proposals
      (asserts! (not (get executed proposal-data)) (err u7))
      (asserts! (not (get cancelled proposal-data)) (err u14))
      
      ;; Mark as cancelled and slash stake (keep 50% as penalty)
      (map-set proposals id (merge proposal-data { 
        cancelled: true,
        stake-slashed: true
      }))
      
      ;; Return only 50% of stake to proposer (rest stays in contract as penalty)
      (let ((partial-refund (/ (get proposal-stake proposal-data) u2)))
        (try! (as-contract (stx-transfer? partial-refund tx-sender (get proposer proposal-data)))))
      
      (ok true))))

;; Community-driven proposal cancellation
(define-public (vote-to-cancel (id uint) (stake uint))
  (let (
    (cost (* stake stake))
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (existing-cancel-vote (map-get? cancellation-votes (tuple (proposal-id id) (voter tx-sender))))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
  )
    (begin
      ;; Check voting is not paused
      (asserts! (not (var-get voting-paused)) (err u12))
      
      ;; Can only cancel during voting period
      (asserts! (<= stacks-block-height voting-end) (err u5))
      
      ;; Cannot cancel already executed or cancelled proposals
      (asserts! (not (get executed proposal-data)) (err u7))
      (asserts! (not (get cancelled proposal-data)) (err u14))
      
      ;; Prevent double voting for cancellation
      (asserts! (is-none existing-cancel-vote) (err u15))
      
      ;; Minimum stake requirement
      (asserts! (>= stake MIN-VOTE-STAKE) (err u6))
      
      ;; Transfer quadratic cost
      (try! (stx-transfer? cost tx-sender (as-contract tx-sender)))
      
      ;; Record cancellation vote
      (map-set cancellation-votes (tuple (proposal-id id) (voter tx-sender)) { weight: stake })
      
      ;; Update proposal cancellation vote count
      (let ((new-cancellation-votes (+ (get cancellation-votes proposal-data) stake)))
        (map-set proposals id (merge proposal-data { 
          cancellation-votes: new-cancellation-votes
        }))
        
        ;; Check if cancellation threshold reached
        (let ((total-votes (+ (get votes-for proposal-data) (get votes-against proposal-data))))
          (if (and (> total-votes u0) 
                   (>= (* new-cancellation-votes u100) (* total-votes CANCELLATION-THRESHOLD)))
            ;; Cancel proposal and slash stake
            (begin
              (map-set proposals id (merge proposal-data { 
                cancelled: true,
                stake-slashed: true,
                cancellation-votes: new-cancellation-votes
              }))
              ;; No refund for community-cancelled proposals
              (ok true))
            (ok true)))))
      ))

;; Allow proposer to withdraw stake from failed proposals after execution period
(define-public (withdraw-failed-proposal-stake (id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
    (execution-time (+ voting-end EXECUTION-DELAY))
  )
    (begin
      ;; Only proposer can withdraw
      (asserts! (is-eq tx-sender (get proposer proposal-data)) (err u16))
      
      ;; Cannot withdraw from executed, cancelled, or slashed proposals
      (asserts! (not (get executed proposal-data)) (err u7))
      (asserts! (not (get cancelled proposal-data)) (err u14))
      (asserts! (not (get stake-slashed proposal-data)) (err u17))
      
      ;; Must be past execution time
      (asserts! (>= stacks-block-height execution-time) (err u9))
      
      ;; Proposal must have failed (more against than for)
      (asserts! (<= (get votes-for proposal-data) (get votes-against proposal-data)) (err u18))
      
      ;; Mark stake as withdrawn and return it
      (map-set proposals id (merge proposal-data { stake-slashed: true }))
      (try! (as-contract (stx-transfer? (get proposal-stake proposal-data) tx-sender (get proposer proposal-data))))
      
      (ok true))))

;; Secure proposal execution with delays and validation
(define-public (execute-proposal (id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals id) (err u1)))
    (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
    (execution-time (+ voting-end EXECUTION-DELAY))
  )
    (begin
      ;; Check proposal hasn't been executed or cancelled
      (asserts! (not (get executed proposal-data)) (err u7))
      (asserts! (not (get cancelled proposal-data)) (err u14))
      
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

(define-read-only (get-cancellation-vote (proposal-id uint) (voter principal))
  (map-get? cancellation-votes (tuple (proposal-id proposal-id) (voter voter))))

(define-read-only (has-voted (proposal-id uint) (voter principal))
  (is-some (map-get? votes (tuple (proposal-id proposal-id) (voter voter)))))

(define-read-only (has-voted-to-cancel (proposal-id uint) (voter principal))
  (is-some (map-get? cancellation-votes (tuple (proposal-id proposal-id) (voter voter)))))

(define-read-only (is-voting-active (id uint))
  (match (map-get? proposals id)
    proposal-data 
      (let ((voting-end (+ (get creation-height proposal-data) VOTING-PERIOD)))
        (and 
          (<= stacks-block-height voting-end) 
          (not (var-get voting-paused))
          (not (get cancelled proposal-data))))
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
          (not (get cancelled proposal-data))
          (> stacks-block-height voting-end)
          (>= stacks-block-height execution-time)
          (> (get votes-for proposal-data) (get votes-against proposal-data))))
    false))

(define-read-only (can-emergency-cancel (id uint))
  (match (map-get? proposals id)
    proposal-data
      (let ((emergency-window (+ (get creation-height proposal-data) EMERGENCY-CANCELLATION-PERIOD)))
        (and 
          (<= stacks-block-height emergency-window)
          (not (get executed proposal-data))
          (not (get cancelled proposal-data))))
    false))

(define-read-only (get-proposal-status (id uint))
  (match (map-get? proposals id)
    proposal-data
      (let (
        (voting-end (+ (get creation-height proposal-data) VOTING-PERIOD))
        (execution-time (+ voting-end EXECUTION-DELAY))
        (current-height stacks-block-height)
      )
        (if (get cancelled proposal-data)
          "cancelled"
          (if (get executed proposal-data)
            "executed"
            (if (<= current-height voting-end)
              "voting"
              (if (< current-height execution-time)
                "pending"
                (if (> (get votes-for proposal-data) (get votes-against proposal-data))
                  "ready-to-execute"
                  "failed"))))))
    "not-found"))

(define-read-only (get-contract-owner)
  (var-get contract-owner))

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id))

(define-read-only (is-voting-paused)
  (var-get voting-paused))

;; Get governance parameters including new cancellation parameters
(define-read-only (get-governance-params)
  {
    voting-period: VOTING-PERIOD,
    min-proposal-stake: MIN-PROPOSAL-STAKE,
    execution-delay: EXECUTION-DELAY,
    min-vote-stake: MIN-VOTE-STAKE,
    cancellation-threshold: CANCELLATION-THRESHOLD,
    emergency-cancellation-period: EMERGENCY-CANCELLATION-PERIOD
  })
