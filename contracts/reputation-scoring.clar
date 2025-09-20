;; Reputation Scoring
;; Build reputation scores for both freelancers and clients

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u301))
(define-constant ERR-USER-NOT-FOUND (err u302))
(define-constant ERR-INVALID-RATING (err u303))
(define-constant ERR-SELF-RATING (err u304))
(define-constant ERR-ALREADY-RATED (err u305))
(define-constant ERR-INVALID-SCORE (err u306))
(define-constant ERR-NO-INTERACTION (err u307))

;; Constants
(define-constant MAX-RATING u5)
(define-constant MIN-RATING u1)
(define-constant INITIAL-REPUTATION u500)
(define-constant REPUTATION-DECAY-RATE u2) ;; Points lost per period of inactivity

;; Data variables
(define-data-var rating-counter uint u0)

;; Data maps
(define-map user-profiles
    principal
    {
        reputation-score: uint,
        total-projects: uint,
        successful-projects: uint,
        disputed-projects: uint,
        total-ratings: uint,
        average-rating: uint,
        last-activity: uint,
        user-type: (string-ascii 10), ;; "client" or "freelancer" or "both"
        is-verified: bool
    }
)

(define-map project-interactions
    { project-id: uint, client: principal, freelancer: principal }
    {
        status: (string-ascii 20), ;; "completed", "disputed", "cancelled"
        client-rating: (optional uint),
        freelancer-rating: (optional uint),
        completion-time: uint,
        amount: uint
    }
)

(define-map individual-ratings
    { rater: principal, rated: principal, project-id: uint }
    {
        rating: uint,
        comment: (optional (string-ascii 500)),
        created-at: uint
    }
)

(define-map reputation-history
    { user: principal, period: uint }
    {
        score-start: uint,
        score-end: uint,
        projects-completed: uint,
        average-rating: uint
    }
)

;; Private functions
(define-private (get-next-rating-id)
    (let ((current-id (var-get rating-counter)))
        (var-set rating-counter (+ current-id u1))
        (+ current-id u1)
    )
)

(define-private (calculate-reputation-score (user principal))
    (match (map-get? user-profiles user)
        profile
            (let 
                (
                    (base-score (get reputation-score profile))
                    (success-rate (calculate-success-rate profile))
                    (rating-bonus (calculate-rating-bonus (get average-rating profile)))
                    (activity-penalty (calculate-activity-penalty (get last-activity profile)))
                )
                (+ 
                    (- base-score activity-penalty)
                    (+ success-rate rating-bonus)
                )
            )
        INITIAL-REPUTATION
    )
)

(define-private (calculate-success-rate (profile {reputation-score: uint, total-projects: uint, successful-projects: uint, disputed-projects: uint, total-ratings: uint, average-rating: uint, last-activity: uint, user-type: (string-ascii 10), is-verified: bool}))
    (if (> (get total-projects profile) u0)
        (/ (* (get successful-projects profile) u100) (get total-projects profile))
        u100
    )
)

(define-private (calculate-rating-bonus (average-rating uint))
    (if (> average-rating u0)
        (* (- average-rating u3) u50) ;; Bonus for ratings above 3
        u0
    )
)

(define-private (calculate-activity-penalty (last-activity uint))
    (let ((blocks-inactive (- block-height last-activity)))
        (if (> blocks-inactive u14400) ;; ~100 days
            (* REPUTATION-DECAY-RATE (/ blocks-inactive u14400))
            u0
        )
    )
)

(define-private (update-average-rating (user principal) (new-rating uint))
    (match (map-get? user-profiles user)
        profile
            (let 
                (
                    (total-ratings (get total-ratings profile))
                    (current-average (get average-rating profile))
                    (new-total-ratings (+ total-ratings u1))
                    (new-average 
                        (if (is-eq total-ratings u0)
                            new-rating
                            (/ 
                                (+ (* current-average total-ratings) new-rating)
                                new-total-ratings
                            )
                        )
                    )
                )
                (map-set user-profiles user
                    (merge profile {
                        total-ratings: new-total-ratings,
                        average-rating: new-average
                    })
                )
                true
            )
        false
    )
)

;; Read-only functions
(define-read-only (get-user-profile (user principal))
    (map-get? user-profiles user)
)

(define-read-only (get-project-interaction (project-id uint) (client principal) (freelancer principal))
    (map-get? project-interactions { project-id: project-id, client: client, freelancer: freelancer })
)

(define-read-only (get-rating (rater principal) (rated principal) (project-id uint))
    (map-get? individual-ratings { rater: rater, rated: rated, project-id: project-id })
)

(define-read-only (get-reputation-score (user principal))
    (calculate-reputation-score user)
)

(define-read-only (get-success-rate (user principal))
    (match (map-get? user-profiles user)
        profile
            (calculate-success-rate profile)
        u0
    )
)

(define-read-only (is-user-verified (user principal))
    (match (map-get? user-profiles user)
        profile
            (get is-verified profile)
        false
    )
)

;; Public functions
(define-public (create-user-profile (user-type (string-ascii 10)))
    (let ((existing-profile (map-get? user-profiles tx-sender)))
        (if (is-some existing-profile)
            ;; Update existing profile
            (map-set user-profiles tx-sender
                (merge (unwrap-panic existing-profile) {
                    user-type: user-type,
                    last-activity: block-height
                })
            )
            ;; Create new profile
            (map-set user-profiles tx-sender
                {
                    reputation-score: INITIAL-REPUTATION,
                    total-projects: u0,
                    successful-projects: u0,
                    disputed-projects: u0,
                    total-ratings: u0,
                    average-rating: u0,
                    last-activity: block-height,
                    user-type: user-type,
                    is-verified: false
                }
            )
        )
        (ok true)
    )
)

(define-public (record-project-start (project-id uint))
    (let ((amount u1000000)) ;; Default amount
        ;; For simplified implementation, allow any caller
        ;; In production, would check contract-caller
        
        ;; Update user activity and project counts
        (update-user-activity tx-sender)
        
        ;; Record project interaction (simplified)
        (map-set project-interactions 
            { project-id: project-id, client: tx-sender, freelancer: tx-sender }
            {
                status: "active",
                client-rating: none,
                freelancer-rating: none,
                completion-time: block-height,
                amount: amount
            }
        )
        
        (ok true)
    )
)

(define-public (record-project-completion (project-id uint))
    ;; For simplified implementation, allow any caller
    
    ;; Update project status (simplified)
    (match (map-get? project-interactions { project-id: project-id, client: tx-sender, freelancer: tx-sender })
        interaction
            (begin
                (map-set project-interactions 
                    { project-id: project-id, client: tx-sender, freelancer: tx-sender }
                    (merge interaction {
                        status: "completed",
                        completion-time: block-height
                    })
                )
                
                ;; Update user profiles
                (update-project-completion tx-sender)
                
                (ok true)
            )
        ERR-NO-INTERACTION
    )
)

(define-public (record-dispute (project-id uint))
    ;; For simplified implementation, allow any caller
    
    ;; Update project status (simplified)
    (match (map-get? project-interactions { project-id: project-id, client: tx-sender, freelancer: tx-sender })
        interaction
            (begin
                (map-set project-interactions 
                    { project-id: project-id, client: tx-sender, freelancer: tx-sender }
                    (merge interaction { status: "disputed" })
                )
                
                ;; Update dispute counts
                (update-dispute-count tx-sender)
                
                (ok true)
            )
        ERR-NO-INTERACTION
    )
)

(define-public (submit-rating (rated-user principal) (project-id uint) (rating uint) (comment (optional (string-ascii 500))))
    (let 
        (
            (client tx-sender) ;; Simplified - in production would verify project participation
            (freelancer rated-user)
        )
        (asserts! (not (is-eq tx-sender rated-user)) ERR-SELF-RATING)
        (asserts! (and (>= rating MIN-RATING) (<= rating MAX-RATING)) ERR-INVALID-RATING)
        (asserts! (is-none (get-rating tx-sender rated-user project-id)) ERR-ALREADY-RATED)
        
        ;; Verify project interaction exists
        (asserts! (is-some (get-project-interaction project-id client freelancer)) ERR-NO-INTERACTION)
        
        ;; Record individual rating
        (map-set individual-ratings
            { rater: tx-sender, rated: rated-user, project-id: project-id }
            {
                rating: rating,
                comment: comment,
                created-at: block-height
            }
        )
        
        ;; Update average rating for the user
        (update-average-rating rated-user rating)
        
        ;; Update user activity
        (update-user-activity rated-user)
        
        (ok true)
    )
)

(define-public (verify-user (user principal))
    ;; In production, this would have proper verification logic
    ;; For now, anyone can verify (simplified)
    (match (map-get? user-profiles user)
        profile
            (begin
                (map-set user-profiles user
                    (merge profile { is-verified: true })
                )
                (ok true)
            )
        ERR-USER-NOT-FOUND
    )
)

;; Private helper functions
(define-private (update-user-activity (user principal))
    (match (map-get? user-profiles user)
        profile
            (begin
                (map-set user-profiles user
                    (merge profile { last-activity: block-height })
                )
                true
            )
        ;; Create profile if doesn't exist
        (begin
            (map-set user-profiles user
                {
                    reputation-score: INITIAL-REPUTATION,
                    total-projects: u0,
                    successful-projects: u0,
                    disputed-projects: u0,
                    total-ratings: u0,
                    average-rating: u0,
                    last-activity: block-height,
                    user-type: "both",
                    is-verified: false
                }
            )
            true
        )
    )
)

(define-private (update-project-completion (user principal))
    (match (map-get? user-profiles user)
        profile
            (map-set user-profiles user
                (merge profile {
                    total-projects: (+ (get total-projects profile) u1),
                    successful-projects: (+ (get successful-projects profile) u1),
                    last-activity: block-height
                })
            )
        false
    )
)

(define-private (update-dispute-count (user principal))
    (match (map-get? user-profiles user)
        profile
            (map-set user-profiles user
                (merge profile {
                    total-projects: (+ (get total-projects profile) u1),
                    disputed-projects: (+ (get disputed-projects profile) u1),
                    last-activity: block-height
                })
            )
        false
    )
)

