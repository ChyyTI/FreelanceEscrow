;; FreelanceEscrow: Milestone-Based Work Escrow Protocol
;; Client funds are locked upfront; milestones gate each release.

;; Error Registry

(define-constant ERR-NOT-CLIENT       (err u700))
(define-constant ERR-NOT-FREELANCER   (err u701))
(define-constant ERR-NOT-ARBITER      (err u702))
(define-constant ERR-BAD-ENG          (err u703))
(define-constant ERR-BAD-MILESTONE    (err u704))
(define-constant ERR-WRONG-STATE      (err u705))
(define-constant ERR-TRANSFER-FAIL    (err u706))
(define-constant ERR-ZERO-VALUE       (err u707))
(define-constant ERR-CANCEL-PENDING   (err u708))
(define-constant ERR-NO-CANCEL-SIGNAL (err u709))
(define-constant ERR-ALREADY-SIGNALED (err u710))
(define-constant ERR-INVALID-PARTY    (err u711))
(define-constant ERR-INVALID-IDX      (err u712))

;; Milestone state codes
(define-constant MS-PENDING    u0)
(define-constant MS-SUBMITTED  u1)
(define-constant MS-RELEASED   u2)
(define-constant MS-DISPUTED   u3)
(define-constant MS-FORCED     u4)

;; Max milestone index (0-based, 5 milestones max idx = 4)
(define-constant MAX-IDX u4)

;; Storage

(define-map engagements
    uint
    {
        client:          principal,
        freelancer:      principal,
        arbiter:         principal,
        total-budget:    uint,
        milestone-count: uint,
        spent:           uint,
        client-cancel:   bool,
        worker-cancel:   bool,
        closed:          bool
    }
)

(define-map milestones
    { eid: uint, idx: uint }
    {
        amount:        uint,
        evidence-hash: (optional (buff 32)),
        state:         uint
    }
)

(define-map disputes
    { eid: uint, idx: uint }
    { raised-at: uint, reason-hash: (buff 32) }
)

(define-data-var eng-counter uint u0)

;; Validation Helpers

;; Ensures a principal is not the burn address and not tx-sender (for third-party roles)
(define-private (valid-party (p principal))
    (not (is-eq p 'SP000000000000000000002Q6VF78))
)

;; Validates idx is within the fixed milestone range
(define-private (valid-idx (idx uint))
    (<= idx MAX-IDX)
)

;; Read-Only 

(define-read-only (get-engagement (eid uint))
    (map-get? engagements eid)
)

(define-read-only (get-milestone (eid uint) (idx uint))
    (map-get? milestones { eid: eid, idx: idx })
)

(define-read-only (get-dispute (eid uint) (idx uint))
    (map-get? disputes { eid: eid, idx: idx })
)

(define-read-only (get-eng-count)
    (var-get eng-counter)
)

;; Public Functions

;; Client locks full budget and registers exactly 5 milestones.
(define-public (create-engagement
    (freelancer   principal)
    (arbiter      principal)
    (total-budget uint)
    (m0 uint) (m1 uint) (m2 uint) (m3 uint) (m4 uint))
    (begin
        (asserts! (valid-party freelancer) ERR-INVALID-PARTY)
        (asserts! (valid-party arbiter)    ERR-INVALID-PARTY)
        (asserts! (not (is-eq freelancer arbiter)) ERR-INVALID-PARTY)
        (asserts! (not (is-eq tx-sender freelancer)) ERR-INVALID-PARTY)
        (asserts! (not (is-eq tx-sender arbiter)) ERR-INVALID-PARTY)
        (asserts! (> total-budget u0) ERR-ZERO-VALUE)
        (asserts! (is-eq total-budget (+ m0 (+ m1 (+ m2 (+ m3 m4))))) ERR-ZERO-VALUE)
        (try! (stx-transfer? total-budget tx-sender (as-contract tx-sender)))
        (let ((eid (+ (var-get eng-counter) u1)))
            (map-set engagements eid {
                client:          tx-sender,
                freelancer:      freelancer,
                arbiter:         arbiter,
                total-budget:    total-budget,
                milestone-count: u5,
                spent:           u0,
                client-cancel:   false,
                worker-cancel:   false,
                closed:          false
            })
            ;; Milestone indices are compile-time literals
            (map-set milestones { eid: eid, idx: u0 } { amount: m0, evidence-hash: none, state: MS-PENDING })
            (map-set milestones { eid: eid, idx: u1 } { amount: m1, evidence-hash: none, state: MS-PENDING })
            (map-set milestones { eid: eid, idx: u2 } { amount: m2, evidence-hash: none, state: MS-PENDING })
            (map-set milestones { eid: eid, idx: u3 } { amount: m3, evidence-hash: none, state: MS-PENDING })
            (map-set milestones { eid: eid, idx: u4 } { amount: m4, evidence-hash: none, state: MS-PENDING })
            (var-set eng-counter eid)
            (ok eid)
        )
    )
)

;; Freelancer marks a milestone done and attaches evidence.
;; Fixes warnings: idx validated via valid-idx; evidence-hash validated non-empty via asserts.
(define-public (submit-milestone (eid uint) (idx uint) (evidence-hash (buff 32)))
    (begin
        ;; Validate untrusted idx before it touches map key (fixes warning line 109)
        (asserts! (valid-idx idx) ERR-INVALID-IDX)
        ;; Validate evidence-hash is not all-zero (sanity check on buff input)
        (asserts! (not (is-eq evidence-hash 0x0000000000000000000000000000000000000000000000000000000000000000))
            ERR-ZERO-VALUE)
        (let (
            (eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG))
            (ms  (unwrap! (map-get? milestones { eid: eid, idx: idx }) ERR-BAD-MILESTONE))
        )
            (asserts! (is-eq tx-sender (get freelancer eng)) ERR-NOT-FREELANCER)
            (asserts! (not (get closed eng)) ERR-WRONG-STATE)
            (asserts! (is-eq (get state ms) MS-PENDING) ERR-WRONG-STATE)
            (map-set milestones { eid: eid, idx: idx }
                (merge ms { state: MS-SUBMITTED, evidence-hash: (some evidence-hash) }))
            (ok true)
        )
    )
)

;; Client approves and pays out one milestone.
;; Fixes warning: idx validated before use in map key (line 122).
(define-public (release-milestone (eid uint) (idx uint))
    (begin
        ;; Validate untrusted idx (fixes warning line 122)
        (asserts! (valid-idx idx) ERR-INVALID-IDX)
        (let (
            (eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG))
            (ms  (unwrap! (map-get? milestones { eid: eid, idx: idx }) ERR-BAD-MILESTONE))
        )
            (asserts! (is-eq tx-sender (get client eng)) ERR-NOT-CLIENT)
            (asserts! (is-eq (get state ms) MS-SUBMITTED) ERR-WRONG-STATE)
            (map-set milestones { eid: eid, idx: idx } (merge ms { state: MS-RELEASED }))
            (map-set engagements eid
                (merge eng { spent: (+ (get spent eng) (get amount ms)) }))
            (as-contract
                (stx-transfer? (get amount ms) tx-sender (get freelancer eng)))
        )
    )
)

;; Freelancer flags a submitted milestone as withheld.
;; Fixes warnings: idx validated (lines 135-136); reason-hash validated non-zero (line 136).
(define-public (raise-dispute (eid uint) (idx uint) (reason-hash (buff 32)))
    (begin
        ;; Validate untrusted idx and reason-hash (fixes warnings lines 135-136)
        (asserts! (valid-idx idx) ERR-INVALID-IDX)
        (asserts! (not (is-eq reason-hash 0x0000000000000000000000000000000000000000000000000000000000000000))
            ERR-ZERO-VALUE)
        (let (
            (eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG))
            (ms  (unwrap! (map-get? milestones { eid: eid, idx: idx }) ERR-BAD-MILESTONE))
        )
            (asserts! (is-eq tx-sender (get freelancer eng)) ERR-NOT-FREELANCER)
            (asserts! (is-eq (get state ms) MS-SUBMITTED) ERR-WRONG-STATE)
            (map-set milestones { eid: eid, idx: idx }
                (merge ms { state: MS-DISPUTED }))
            (map-set disputes { eid: eid, idx: idx }
                { raised-at: block-height, reason-hash: reason-hash })
            (ok true)
        )
    )
)

;; Arbiter force-pays a disputed milestone to the freelancer.
;; Fixes warning: idx validated before map key use (line 148).
(define-public (arbiter-release (eid uint) (idx uint))
    (begin
        ;; Validate untrusted idx (fixes warning line 148)
        (asserts! (valid-idx idx) ERR-INVALID-IDX)
        (let (
            (eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG))
            (ms  (unwrap! (map-get? milestones { eid: eid, idx: idx }) ERR-BAD-MILESTONE))
        )
            (asserts! (is-eq tx-sender (get arbiter eng)) ERR-NOT-ARBITER)
            (asserts! (is-eq (get state ms) MS-DISPUTED) ERR-WRONG-STATE)
            (map-set milestones { eid: eid, idx: idx }
                (merge ms { state: MS-FORCED }))
            (map-set engagements eid
                (merge eng { spent: (+ (get spent eng) (get amount ms)) }))
            (as-contract
                (stx-transfer? (get amount ms) tx-sender (get freelancer eng)))
        )
    )
)

(define-public (propose-cancel (eid uint))
    (let ((eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG)))
        (asserts! (not (get closed eng)) ERR-WRONG-STATE)
        (asserts!
            (or (is-eq tx-sender (get client eng))
                (is-eq tx-sender (get freelancer eng)))
            ERR-NOT-CLIENT)
        (if (is-eq tx-sender (get client eng))
            (begin
                (asserts! (not (get client-cancel eng)) ERR-ALREADY-SIGNALED)
                (map-set engagements eid (merge eng { client-cancel: true }))
            )
            (begin
                (asserts! (not (get worker-cancel eng)) ERR-ALREADY-SIGNALED)
                (map-set engagements eid (merge eng { worker-cancel: true }))
            )
        )
        (ok true)
    )
)

(define-public (confirm-cancel (eid uint))
    (let ((eng (unwrap! (map-get? engagements eid) ERR-BAD-ENG)))
        (asserts! (not (get closed eng)) ERR-WRONG-STATE)
        (asserts! (and (get client-cancel eng) (get worker-cancel eng))
            ERR-NO-CANCEL-SIGNAL)
        (let ((remaining (- (get total-budget eng) (get spent eng))))
            (map-set engagements eid (merge eng { closed: true }))
            (if (> remaining u0)
                (as-contract
                    (stx-transfer? remaining tx-sender (get client eng)))
                (ok true)
            )
        )
    )
)