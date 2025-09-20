;; Contract Escrow
;; Manages secure escrow for freelance project payments

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u101))
(define-constant ERR-ESCROW-NOT-FOUND (err u102))
(define-constant ERR-ESCROW-ALREADY-RELEASED (err u103))
(define-constant ERR-ESCROW-NOT-EXPIRED (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-INVALID-AMOUNT (err u106))
(define-constant ERR-ESCROW-DISPUTED (err u107))
(define-constant ERR-INVALID-DEADLINE (err u108))

;; Data variables
(define-data-var escrow-counter uint u0)

;; Data maps
(define-map escrows
    uint
    {
        client: principal,
        freelancer: principal,
        amount: uint,
        deadline: uint,
        status: (string-ascii 20),
        dispute-id: (optional uint),
        created-at: uint
    }
)

(define-map escrow-balances
    uint
    uint
)

;; Private functions
(define-private (get-next-escrow-id)
    (let ((current-id (var-get escrow-counter)))
        (var-set escrow-counter (+ current-id u1))
        (+ current-id u1)
    )
)

(define-private (is-escrow-expired (escrow-id uint))
    (match (map-get? escrows escrow-id)
        escrow-data
            (>= block-height (get deadline escrow-data))
        false
    )
)

;; Read-only functions
(define-read-only (get-escrow (escrow-id uint))
    (map-get? escrows escrow-id)
)

(define-read-only (get-escrow-balance (escrow-id uint))
    (map-get? escrow-balances escrow-id)
)

(define-read-only (get-escrow-count)
    (var-get escrow-counter)
)

(define-read-only (is-authorized-party (escrow-id uint))
    (match (map-get? escrows escrow-id)
        escrow-data
            (or 
                (is-eq tx-sender (get client escrow-data))
                (is-eq tx-sender (get freelancer escrow-data))
            )
        false
    )
)

;; Public functions
(define-public (create-escrow (client principal) (freelancer principal) (amount uint) (deadline uint))
    (let 
        (
            (escrow-id (get-next-escrow-id))
            (current-block block-height)
        )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> deadline current-block) ERR-INVALID-DEADLINE)
        (asserts! (is-eq tx-sender client) ERR-UNAUTHORIZED)
        
        ;; Transfer funds to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Create escrow record
        (map-set escrows escrow-id
            {
                client: client,
                freelancer: freelancer,
                amount: amount,
                deadline: deadline,
                status: "active",
                dispute-id: none,
                created-at: current-block
            }
        )
        
        ;; Set escrow balance
        (map-set escrow-balances escrow-id amount)
        
        (ok escrow-id)
    )
)

(define-public (release-payment (escrow-id uint))
    (let 
        (
            (escrow-data (unwrap! (map-get? escrows escrow-id) ERR-ESCROW-NOT-FOUND))
            (escrow-balance (unwrap! (map-get? escrow-balances escrow-id) ERR-ESCROW-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender (get client escrow-data)) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status escrow-data) "active") ERR-ESCROW-ALREADY-RELEASED)
        (asserts! (is-none (get dispute-id escrow-data)) ERR-ESCROW-DISPUTED)
        
        ;; Transfer funds to freelancer
        (try! (as-contract (stx-transfer? escrow-balance tx-sender (get freelancer escrow-data))))
        
        ;; Update escrow status
        (map-set escrows escrow-id
            (merge escrow-data { status: "released" })
        )
        
        ;; Clear balance
        (map-delete escrow-balances escrow-id)
        
        (ok true)
    )
)

(define-public (request-refund (escrow-id uint))
    (let 
        (
            (escrow-data (unwrap! (map-get? escrows escrow-id) ERR-ESCROW-NOT-FOUND))
            (escrow-balance (unwrap! (map-get? escrow-balances escrow-id) ERR-ESCROW-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender (get client escrow-data)) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status escrow-data) "active") ERR-ESCROW-ALREADY-RELEASED)
        (asserts! (is-none (get dispute-id escrow-data)) ERR-ESCROW-DISPUTED)
        (asserts! (is-escrow-expired escrow-id) ERR-ESCROW-NOT-EXPIRED)
        
        ;; Transfer funds back to client
        (try! (as-contract (stx-transfer? escrow-balance tx-sender (get client escrow-data))))
        
        ;; Update escrow status
        (map-set escrows escrow-id
            (merge escrow-data { status: "refunded" })
        )
        
        ;; Clear balance
        (map-delete escrow-balances escrow-id)
        
        (ok true)
    )
)

(define-public (escalate-to-dispute (escrow-id uint) (dispute-id uint))
    (let 
        (
            (escrow-data (unwrap! (map-get? escrows escrow-id) ERR-ESCROW-NOT-FOUND))
        )
        ;; For simplified implementation, allow any caller
        ;; In production, would check contract-caller
        (asserts! (is-authorized-party escrow-id) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status escrow-data) "active") ERR-ESCROW-ALREADY-RELEASED)
        (asserts! (is-none (get dispute-id escrow-data)) ERR-ESCROW-DISPUTED)
        
        ;; Update escrow with dispute reference
        (map-set escrows escrow-id
            (merge escrow-data { 
                status: "disputed",
                dispute-id: (some dispute-id)
            })
        )
        
        (ok true)
    )
)

(define-public (resolve-dispute (escrow-id uint) (winner (string-ascii 10)))
    (let 
        (
            (escrow-data (unwrap! (map-get? escrows escrow-id) ERR-ESCROW-NOT-FOUND))
            (escrow-balance (unwrap! (map-get? escrow-balances escrow-id) ERR-ESCROW-NOT-FOUND))
        )
        ;; For simplified implementation, allow any caller
        ;; In production, would check contract-caller
        (asserts! (is-authorized-party escrow-id) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status escrow-data) "disputed") ERR-ESCROW-ALREADY-RELEASED)
        
        (if (is-eq winner "freelancer")
            ;; Award to freelancer
            (begin
                (try! (as-contract (stx-transfer? escrow-balance tx-sender (get freelancer escrow-data))))
                (map-set escrows escrow-id (merge escrow-data { status: "resolved-freelancer" }))
            )
            ;; Award to client (refund)
            (begin
                (try! (as-contract (stx-transfer? escrow-balance tx-sender (get client escrow-data))))
                (map-set escrows escrow-id (merge escrow-data { status: "resolved-client" }))
            )
        )
        
        ;; Clear balance
        (map-delete escrow-balances escrow-id)
        
        (ok true)
    )
)


;; title: contract-escrow
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

