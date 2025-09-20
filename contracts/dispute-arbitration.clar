;; Dispute Arbitration
;; Fair arbitration process using community-selected mediators

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u201))
(define-constant ERR-DISPUTE-NOT-FOUND (err u202))
(define-constant ERR-DISPUTE-ALREADY-RESOLVED (err u203))
(define-constant ERR-NOT-AUTHORIZED-PARTY (err u204))
(define-constant ERR-MEDIATOR-NOT-QUALIFIED (err u205))
(define-constant ERR-VOTING-CLOSED (err u206))
(define-constant ERR-ALREADY-VOTED (err u207))
(define-constant ERR-INVALID-VOTE (err u208))
(define-constant ERR-INSUFFICIENT-EVIDENCE (err u209))

;; Constants
(define-constant VOTING-PERIOD u1008) ;; ~7 days in blocks
(define-constant MIN-MEDIATORS u3)
(define-constant QUALIFICATION-THRESHOLD u500) ;; Minimum reputation score
(define-constant INITIAL-REPUTATION u500) ;; Initial reputation for new mediators

;; Data variables
(define-data-var dispute-counter uint u0)
(define-data-var mediator-pool (list 50 principal) (list))

;; Data maps
(define-map disputes
    uint
    {
        escrow-id: uint,
        client: principal,
        freelancer: principal,
        initiator: principal,
        reason: (string-ascii 500),
        evidence-client: (optional (string-ascii 1000)),
        evidence-freelancer: (optional (string-ascii 1000)),
        mediators: (list 5 principal),
        votes-client: uint,
        votes-freelancer: uint,
        status: (string-ascii 20),
        created-at: uint,
        voting-ends: uint,
        resolution: (optional (string-ascii 10))
    }
)

(define-map mediator-votes
    { dispute-id: uint, mediator: principal }
    (string-ascii 10)
)

(define-map mediator-qualifications
    principal
    {
        reputation-score: uint,
        cases-resolved: uint,
        success-rate: uint,
        is-active: bool
    }
)

;; Private functions
(define-private (get-next-dispute-id)
    (let ((current-id (var-get dispute-counter)))
        (var-set dispute-counter (+ current-id u1))
        (+ current-id u1)
    )
)

(define-private (select-mediators (exclude-list (list 2 principal)))
    (let 
        (
            (available-mediators 
                (filter is-qualified-mediator (var-get mediator-pool))
            )
        )
        ;; For simplicity, just take the first 5 qualified mediators
        (unwrap-panic (as-max-len? available-mediators u5))
    )
)

(define-private (is-qualified-mediator (mediator principal))
    (match (map-get? mediator-qualifications mediator)
        qualification
            (and 
                (get is-active qualification)
                (>= (get reputation-score qualification) QUALIFICATION-THRESHOLD)
            )
        false
    )
)

(define-private (take-some (lst (list 50 principal)) (count uint))
    (if (is-eq count u0)
        (some (list))
        (if (is-eq (len lst) u0)
            (some (list))
            (some (unwrap-panic (as-max-len? lst u5)))
        )
    )
)

(define-private (is-voting-active (dispute-id uint))
    (match (map-get? disputes dispute-id)
        dispute-data
            (and 
                (is-eq (get status dispute-data) "voting")
                (<= block-height (get voting-ends dispute-data))
            )
        false
    )
)

;; Read-only functions
(define-read-only (get-dispute (dispute-id uint))
    (map-get? disputes dispute-id)
)

(define-read-only (get-mediator-vote (dispute-id uint) (mediator principal))
    (map-get? mediator-votes { dispute-id: dispute-id, mediator: mediator })
)

(define-read-only (get-mediator-qualification (mediator principal))
    (map-get? mediator-qualifications mediator)
)

(define-read-only (get-dispute-count)
    (var-get dispute-counter)
)

(define-read-only (is-mediator-in-case (dispute-id uint) (mediator principal))
    (match (map-get? disputes dispute-id)
        dispute-data
            (is-some (index-of (get mediators dispute-data) mediator))
        false
    )
)

;; Public functions
(define-public (register-as-mediator)
    (let ((initial-reputation INITIAL-REPUTATION))
        ;; In production, this would have more sophisticated qualification checks
        (map-set mediator-qualifications tx-sender
            {
                reputation-score: initial-reputation,
                cases-resolved: u0,
                success-rate: u100, ;; Start with 100%
                is-active: true
            }
        )
        
        ;; Add to mediator pool if qualified
        (if (>= initial-reputation QUALIFICATION-THRESHOLD)
            (var-set mediator-pool 
                (unwrap-panic (as-max-len? 
                    (append (var-get mediator-pool) tx-sender) u50
                ))
            )
            true
        )
        
        (ok true)
    )
)

(define-public (initiate-dispute (escrow-id uint) (reason (string-ascii 500)))
    (let 
        (
            (dispute-id (get-next-dispute-id))
            (current-block block-height)
            (voting-end (+ current-block VOTING-PERIOD))
            (selected-mediators (select-mediators (list)))
        )
        ;; Get escrow details by calling contract-escrow
        ;; For this implementation, we'll assume the caller provides necessary info
        
        (asserts! (> (len reason) u10) ERR-INSUFFICIENT-EVIDENCE)
        
        ;; Create dispute record
        (map-set disputes dispute-id
            {
                escrow-id: escrow-id,
                client: tx-sender, ;; Simplified - would get from escrow
                freelancer: tx-sender, ;; Simplified - would get from escrow
                initiator: tx-sender,
                reason: reason,
                evidence-client: none,
                evidence-freelancer: none,
                mediators: selected-mediators,
                votes-client: u0,
                votes-freelancer: u0,
                status: "evidence",
                created-at: current-block,
                voting-ends: voting-end,
                resolution: none
            }
        )
        
        ;; Notify escrow contract
        (try! (contract-call? .contract-escrow escalate-to-dispute escrow-id dispute-id))
        
        (ok dispute-id)
    )
)

(define-public (submit-evidence (dispute-id uint) (evidence (string-ascii 1000)))
    (let 
        (
            (dispute-data (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND))
        )
        (asserts! (is-eq (get status dispute-data) "evidence") ERR-DISPUTE-ALREADY-RESOLVED)
        (asserts! (> (len evidence) u20) ERR-INSUFFICIENT-EVIDENCE)
        
        (if (is-eq tx-sender (get client dispute-data))
            ;; Client evidence
            (map-set disputes dispute-id
                (merge dispute-data { evidence-client: (some evidence) })
            )
            ;; Freelancer evidence
            (if (is-eq tx-sender (get freelancer dispute-data))
                (map-set disputes dispute-id
                    (merge dispute-data { evidence-freelancer: (some evidence) })
                )
                (asserts! false ERR-NOT-AUTHORIZED-PARTY)
            )
        )
        
        ;; Check if both parties have submitted evidence, start voting
        (let ((updated-dispute (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND)))
            (if (and 
                    (is-some (get evidence-client updated-dispute))
                    (is-some (get evidence-freelancer updated-dispute))
                )
                (map-set disputes dispute-id
                    (merge updated-dispute { status: "voting" })
                )
                true
            )
        )
        
        (ok true)
    )
)

(define-public (cast-vote (dispute-id uint) (vote (string-ascii 10)))
    (let 
        (
            (dispute-data (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND))
        )
        (asserts! (is-voting-active dispute-id) ERR-VOTING-CLOSED)
        (asserts! (is-mediator-in-case dispute-id tx-sender) ERR-MEDIATOR-NOT-QUALIFIED)
        (asserts! (is-none (get-mediator-vote dispute-id tx-sender)) ERR-ALREADY-VOTED)
        (asserts! (or (is-eq vote "client") (is-eq vote "freelancer")) ERR-INVALID-VOTE)
        
        ;; Record vote
        (map-set mediator-votes 
            { dispute-id: dispute-id, mediator: tx-sender }
            vote
        )
        
        ;; Update vote counts
        (let 
            (
                (new-client-votes 
                    (if (is-eq vote "client")
                        (+ (get votes-client dispute-data) u1)
                        (get votes-client dispute-data)
                    )
                )
                (new-freelancer-votes
                    (if (is-eq vote "freelancer")
                        (+ (get votes-freelancer dispute-data) u1)
                        (get votes-freelancer dispute-data)
                    )
                )
            )
            (map-set disputes dispute-id
                (merge dispute-data {
                    votes-client: new-client-votes,
                    votes-freelancer: new-freelancer-votes
                })
            )
        )
        
        (ok true)
    )
)

(define-public (finalize-dispute (dispute-id uint))
    (let 
        (
            (dispute-data (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND))
        )
        (asserts! (is-eq (get status dispute-data) "voting") ERR-DISPUTE-ALREADY-RESOLVED)
        (asserts! (> block-height (get voting-ends dispute-data)) ERR-VOTING-CLOSED)
        
        (let 
            (
                (client-votes (get votes-client dispute-data))
                (freelancer-votes (get votes-freelancer dispute-data))
                (winner 
                    (if (> client-votes freelancer-votes)
                        "client"
                        "freelancer"
                    )
                )
            )
            
            ;; Update dispute status
            (map-set disputes dispute-id
                (merge dispute-data {
                    status: "resolved",
                    resolution: (some winner)
                })
            )
            
            ;; Resolve escrow
            (try! (contract-call? .contract-escrow resolve-dispute 
                (get escrow-id dispute-data) winner
            ))
            
            ;; Update mediator stats (simplified)
            (update-mediator-stats (get mediators dispute-data))
            
            (ok winner)
        )
    )
)

(define-private (update-mediator-stats (mediators (list 5 principal)))
    ;; Simplified mediator stats update
    ;; In production, would track individual performance
    (fold update-single-mediator mediators true)
)

(define-private (update-single-mediator (mediator principal) (acc bool))
    (match (map-get? mediator-qualifications mediator)
        qualification
            (begin
                (map-set mediator-qualifications mediator
                    (merge qualification {
                        cases-resolved: (+ (get cases-resolved qualification) u1)
                    })
                )
                true
            )
        acc
    )
)


;; title: dispute-arbitration
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

