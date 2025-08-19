;; Calibration Scheduler Contract
;; Manages calibration scheduling, tracking, and history

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-CALIBRATION-NOT-FOUND (err u201))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u202))
(define-constant ERR-INVALID-INPUT (err u203))
(define-constant ERR-CALIBRATION-EXISTS (err u204))
(define-constant ERR-INVALID-DATE (err u205))

;; Priority levels
(define-constant PRIORITY-LOW u1)
(define-constant PRIORITY-NORMAL u2)
(define-constant PRIORITY-HIGH u3)
(define-constant PRIORITY-CRITICAL u4)

;; Calibration results
(define-constant RESULT-PASS "pass")
(define-constant RESULT-FAIL "fail")
(define-constant RESULT-PENDING "pending")

;; Data Variables
(define-data-var next-calibration-id uint u1)

;; Data Maps
(define-map calibration-records
  { calibration-id: uint }
  {
    equipment-id: uint,
    calibrator: principal,
    scheduled-date: uint,
    actual-date: uint,
    due-date: uint,
    priority: uint,
    result: (string-ascii 20),
    accuracy: uint,
    certificate-id: uint,
    notes: (string-ascii 500),
    status: (string-ascii 20),
    created-at: uint,
    updated-at: uint
  }
)

(define-map equipment-calibration-history
  { equipment-id: uint, calibration-id: uint }
  { timestamp: uint }
)

(define-map scheduled-calibrations
  { scheduled-date: uint, equipment-id: uint }
  { calibration-id: uint, priority: uint }
)

(define-map overdue-equipment
  { equipment-id: uint }
  { days-overdue: uint, priority: uint, last-updated: uint }
)

(define-map calibrator-assignments
  { calibrator: principal, calibration-id: uint }
  { assigned-date: uint, status: (string-ascii 20) }
)

;; Public Functions

;; Schedule a new calibration
(define-public (schedule-calibration
  (equipment-id uint)
  (scheduled-date uint)
  (priority uint)
  (calibrator principal)
  (notes (string-ascii 500)))
  (let
    (
      (calibration-id (var-get next-calibration-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (due-date (+ scheduled-date (* u86400 u30))) ;; 30 days from scheduled date
    )
    ;; Validate inputs
    (asserts! (> equipment-id u0) ERR-INVALID-INPUT)
    (asserts! (> scheduled-date current-time) ERR-INVALID-DATE)
    (asserts! (and (>= priority PRIORITY-LOW) (<= priority PRIORITY-CRITICAL)) ERR-INVALID-INPUT)

    ;; Check if equipment exists (would need to call equipment registry)
    ;; For now, assume equipment exists

    ;; Create calibration record
    (map-set calibration-records
      { calibration-id: calibration-id }
      {
        equipment-id: equipment-id,
        calibrator: calibrator,
        scheduled-date: scheduled-date,
        actual-date: u0,
        due-date: due-date,
        priority: priority,
        result: RESULT-PENDING,
        accuracy: u0,
        certificate-id: u0,
        notes: notes,
        status: "scheduled",
        created-at: current-time,
        updated-at: current-time
      }
    )

    ;; Add to scheduled calibrations
    (map-set scheduled-calibrations
      { scheduled-date: scheduled-date, equipment-id: equipment-id }
      { calibration-id: calibration-id, priority: priority }
    )

    ;; Assign calibrator
    (map-set calibrator-assignments
      { calibrator: calibrator, calibration-id: calibration-id }
      { assigned-date: current-time, status: "assigned" }
    )

    ;; Add to equipment calibration history
    (map-set equipment-calibration-history
      { equipment-id: equipment-id, calibration-id: calibration-id }
      { timestamp: current-time }
    )

    ;; Increment next calibration ID
    (var-set next-calibration-id (+ calibration-id u1))

    (ok calibration-id)
  )
)

;; Complete a calibration
(define-public (complete-calibration
  (calibration-id uint)
  (result (string-ascii 20))
  (accuracy uint)
  (certificate-id uint)
  (notes (string-ascii 500)))
  (let
    (
      (calibration (unwrap! (map-get? calibration-records { calibration-id: calibration-id }) ERR-CALIBRATION-NOT-FOUND))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    ;; Check authorization (calibrator or contract owner)
    (asserts! (or
      (is-eq tx-sender (get calibrator calibration))
      (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Validate inputs
    (asserts! (or
      (is-eq result RESULT-PASS)
      (is-eq result RESULT-FAIL)) ERR-INVALID-INPUT)
    (asserts! (<= accuracy u100) ERR-INVALID-INPUT)

    ;; Update calibration record
    (map-set calibration-records
      { calibration-id: calibration-id }
      (merge calibration {
        actual-date: current-time,
        result: result,
        accuracy: accuracy,
        certificate-id: certificate-id,
        notes: notes,
        status: "completed",
        updated-at: current-time
      })
    )

    ;; Update calibrator assignment status
    (map-set calibrator-assignments
      { calibrator: (get calibrator calibration), calibration-id: calibration-id }
      { assigned-date: (unwrap-panic (get assigned-date (map-get? calibrator-assignments { calibrator: (get calibrator calibration), calibration-id: calibration-id }))), status: "completed" }
    )

    ;; Remove from overdue if it was overdue
    (map-delete overdue-equipment { equipment-id: (get equipment-id calibration) })

    (ok true)
  )
)

;; Reschedule a calibration
(define-public (reschedule-calibration
  (calibration-id uint)
  (new-scheduled-date uint)
  (new-priority uint)
  (reason (string-ascii 500)))
  (let
    (
      (calibration (unwrap! (map-get? calibration-records { calibration-id: calibration-id }) ERR-CALIBRATION-NOT-FOUND))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (new-due-date (+ new-scheduled-date (* u86400 u30)))
    )
    ;; Check authorization (calibrator or contract owner)
    (asserts! (or
      (is-eq tx-sender (get calibrator calibration))
      (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Validate inputs
    (asserts! (> new-scheduled-date current-time) ERR-INVALID-DATE)
    (asserts! (and (>= new-priority PRIORITY-LOW) (<= new-priority PRIORITY-CRITICAL)) ERR-INVALID-INPUT)
    (asserts! (is-eq (get status calibration) "scheduled") ERR-INVALID-INPUT)

    ;; Remove old scheduled entry
    (map-delete scheduled-calibrations
      { scheduled-date: (get scheduled-date calibration), equipment-id: (get equipment-id calibration) }
    )

    ;; Update calibration record
    (map-set calibration-records
      { calibration-id: calibration-id }
      (merge calibration {
        scheduled-date: new-scheduled-date,
        due-date: new-due-date,
        priority: new-priority,
        notes: reason,
        updated-at: current-time
      })
    )

    ;; Add new scheduled entry
    (map-set scheduled-calibrations
      { scheduled-date: new-scheduled-date, equipment-id: (get equipment-id calibration) }
      { calibration-id: calibration-id, priority: new-priority }
    )

    (ok true)
  )
)

;; Mark equipment as overdue
(define-public (mark-overdue
  (equipment-id uint)
  (days-overdue uint)
  (priority uint))
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    ;; Only contract owner can mark as overdue
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    ;; Validate inputs
    (asserts! (> equipment-id u0) ERR-INVALID-INPUT)
    (asserts! (> days-overdue u0) ERR-INVALID-INPUT)
    (asserts! (and (>= priority PRIORITY-LOW) (<= priority PRIORITY-CRITICAL)) ERR-INVALID-INPUT)

    ;; Mark as overdue
    (map-set overdue-equipment
      { equipment-id: equipment-id }
      { days-overdue: days-overdue, priority: priority, last-updated: current-time }
    )

    (ok true)
  )
)

;; Cancel a scheduled calibration
(define-public (cancel-calibration
  (calibration-id uint)
  (reason (string-ascii 500)))
  (let
    (
      (calibration (unwrap! (map-get? calibration-records { calibration-id: calibration-id }) ERR-CALIBRATION-NOT-FOUND))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    ;; Check authorization (calibrator or contract owner)
    (asserts! (or
      (is-eq tx-sender (get calibrator calibration))
      (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Can only cancel scheduled calibrations
    (asserts! (is-eq (get status calibration) "scheduled") ERR-INVALID-INPUT)

    ;; Update calibration record
    (map-set calibration-records
      { calibration-id: calibration-id }
      (merge calibration {
        status: "cancelled",
        notes: reason,
        updated-at: current-time
      })
    )

    ;; Remove from scheduled calibrations
    (map-delete scheduled-calibrations
      { scheduled-date: (get scheduled-date calibration), equipment-id: (get equipment-id calibration) }
    )

    ;; Update calibrator assignment status
    (map-set calibrator-assignments
      { calibrator: (get calibrator calibration), calibration-id: calibration-id }
      { assigned-date: (unwrap-panic (get assigned-date (map-get? calibrator-assignments { calibrator: (get calibrator calibration), calibration-id: calibration-id }))), status: "cancelled" }
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get calibration record
(define-read-only (get-calibration (calibration-id uint))
  (map-get? calibration-records { calibration-id: calibration-id })
)

;; Check if calibration exists
(define-read-only (calibration-exists (calibration-id uint))
  (is-some (map-get? calibration-records { calibration-id: calibration-id }))
)

;; Get scheduled calibration for date and equipment
(define-read-only (get-scheduled-calibration (scheduled-date uint) (equipment-id uint))
  (map-get? scheduled-calibrations { scheduled-date: scheduled-date, equipment-id: equipment-id })
)

;; Check if equipment is overdue
(define-read-only (is-equipment-overdue (equipment-id uint))
  (is-some (map-get? overdue-equipment { equipment-id: equipment-id }))
)

;; Get overdue information
(define-read-only (get-overdue-info (equipment-id uint))
  (map-get? overdue-equipment { equipment-id: equipment-id })
)

;; Get calibrator assignment
(define-read-only (get-calibrator-assignment (calibrator principal) (calibration-id uint))
  (map-get? calibrator-assignments { calibrator: calibrator, calibration-id: calibration-id })
)

;; Get next calibration ID
(define-read-only (get-next-calibration-id)
  (var-get next-calibration-id)
)

;; Check if user is authorized for calibration
(define-read-only (is-calibration-authorized (calibration-id uint) (user principal))
  (match (map-get? calibration-records { calibration-id: calibration-id })
    calibration (or
      (is-eq user (get calibrator calibration))
      (is-eq user CONTRACT-OWNER))
    false
  )
)

;; Get calibration status
(define-read-only (get-calibration-status (calibration-id uint))
  (match (map-get? calibration-records { calibration-id: calibration-id })
    calibration (some (get status calibration))
    none
  )
)

;; Check if calibration is pending
(define-read-only (is-calibration-pending (calibration-id uint))
  (match (map-get? calibration-records { calibration-id: calibration-id })
    calibration (is-eq (get status calibration) "scheduled")
    false
  )
)

;; Get calibration result
(define-read-only (get-calibration-result (calibration-id uint))
  (match (map-get? calibration-records { calibration-id: calibration-id })
    calibration (some (get result calibration))
    none
  )
)

;; Check if calibration passed
(define-read-only (calibration-passed (calibration-id uint))
  (match (map-get? calibration-records { calibration-id: calibration-id })
    calibration (is-eq (get result calibration) RESULT-PASS)
    false
  )
)

;; Get equipment calibration history entry
(define-read-only (get-equipment-calibration-entry (equipment-id uint) (calibration-id uint))
  (map-get? equipment-calibration-history { equipment-id: equipment-id, calibration-id: calibration-id })
)

;; Calculate priority score for scheduling
(define-read-only (calculate-priority-score (priority uint) (days-overdue uint))
  (+ (* priority u10) days-overdue)
)
