;; Agricultural Cooperative Voting DAO Smart Contract

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PROPOSAL (err u101))
(define-constant ERR-PROPOSAL-EXPIRED (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-INSUFFICIENT-TOKENS (err u104))
(define-constant ERR-PROPOSAL-NOT-PASSED (err u105))
(define-constant ERR-PROPOSAL-ALREADY-EXECUTED (err u106))
(define-constant ERR-EXECUTION-FAILED (err u107))
(define-constant ERR-SELF-DELEGATION (err u108))
(define-constant ERR-CIRCULAR-DELEGATION (err u109))
(define-constant ERR-PROPOSAL-CANCELLED (err u110))

;; Governance token
(define-fungible-token governance-token)

;; Data variables
(define-data-var proposal-count uint u0)
(define-data-var min-proposal-duration uint u1440) ;; 24 hours in blocks
(define-data-var treasury-balance uint u0)
(define-data-var quorum-threshold uint u1000)
(define-data-var contract-owner principal tx-sender)

;; Data maps
(define-map proposals 
    uint 
    {
        title: (string-ascii 50),
        description: (string-ascii 500),
        proposer: principal,
        start-block: uint,
        end-block: uint,
        executed: bool,
        cancelled: bool,
        yes-votes: uint,
        no-votes: uint,
        proposal-type: (string-ascii 20),
        execution-data: (optional {recipient: (optional principal), amount: (optional uint), new-value: (optional uint)})
    }
)

(define-map votes 
    { proposal-id: uint, voter: principal } 
    bool
)

(define-map delegations
    principal
    principal
)

(define-map delegation-counts
    principal
    uint
)

(define-map voting-power-snapshots
    { proposal-id: uint, voter: principal }
    uint
)

(define-map proposal-voters
    { proposal-id: uint, voter: principal }
    bool
)

;; Token initialization
(define-public (initialize-token (total-supply uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (try! (ft-mint? governance-token total-supply tx-sender))
        (ok true)
    )
)

;; Treasury management
(define-public (deposit-treasury (amount uint))
    (begin
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set treasury-balance (+ (var-get treasury-balance) amount))
        (ok true)
    )
)

;; Delegation functions
(define-public (delegate-vote (delegate principal))
    (let
        (
            (current-delegate (map-get? delegations tx-sender))
            (delegator-balance (ft-get-balance governance-token tx-sender))
        )
        (asserts! (not (is-eq tx-sender delegate)) ERR-SELF-DELEGATION)
        (asserts! (> delegator-balance u0) ERR-INSUFFICIENT-TOKENS)
        
        (match current-delegate
            old-delegate (map-set delegation-counts old-delegate (- (default-to u0 (map-get? delegation-counts old-delegate)) u1))
            true
        )
        
        (map-set delegations tx-sender delegate)
        (map-set delegation-counts delegate (+ (default-to u0 (map-get? delegation-counts delegate)) u1))
        (ok true)
    )
)

(define-public (revoke-delegation)
    (let
        (
            (current-delegate (map-get? delegations tx-sender))
        )
        (match current-delegate
            delegate (begin
                (map-delete delegations tx-sender)
                (map-set delegation-counts delegate (- (default-to u0 (map-get? delegation-counts delegate)) u1))
                (ok true)
            )
            ERR-NOT-AUTHORIZED
        )
    )
)

(define-private (get-effective-voting-power (voter principal))
    (let
        (
            (base-balance (ft-get-balance governance-token voter))
            (delegated-count (default-to u0 (map-get? delegation-counts voter)))
        )
        (+ base-balance delegated-count)
    )
)

(define-private (create-voting-snapshot (proposal-id uint) (voter principal))
    (let
        (
            (voting-power (get-effective-voting-power voter))
        )
        (if (> voting-power u0)
            (begin
                (map-set voting-power-snapshots {proposal-id: proposal-id, voter: voter} voting-power)
                (map-set proposal-voters {proposal-id: proposal-id, voter: voter} true)
                voting-power
            )
            u0
        )
    )
)

(define-private (get-snapshot-voting-power (proposal-id uint) (voter principal))
    (default-to u0 (map-get? voting-power-snapshots {proposal-id: proposal-id, voter: voter}))
)

;; Proposal creation functions
(define-public (create-proposal (title (string-ascii 50)) (description (string-ascii 500)) (duration uint))
    (let
        (
            (proposal-id (var-get proposal-count))
            (start-block stacks-block-height)
            (end-block (+ stacks-block-height duration))
            (effective-balance (get-effective-voting-power tx-sender))
        )
        (asserts! (>= duration (var-get min-proposal-duration)) ERR-INVALID-PROPOSAL)
        (asserts! (>= effective-balance u100) ERR-INSUFFICIENT-TOKENS)
        
        (map-set proposals proposal-id
            {
                title: title,
                description: description,
                proposer: tx-sender,
                start-block: start-block,
                end-block: end-block,
                executed: false,
                cancelled: false,
                yes-votes: u0,
                no-votes: u0,
                proposal-type: "general",
                execution-data: none
            }
        )
        (create-voting-snapshot proposal-id tx-sender)
        (var-set proposal-count (+ proposal-id u1))
        (ok proposal-id)
    )
)

(define-public (create-treasury-proposal (title (string-ascii 50)) (description (string-ascii 500)) (duration uint) (recipient principal) (amount uint))
    (let
        (
            (proposal-id (var-get proposal-count))
            (start-block stacks-block-height)
            (end-block (+ stacks-block-height duration))
            (effective-balance (get-effective-voting-power tx-sender))
        )
        (asserts! (>= duration (var-get min-proposal-duration)) ERR-INVALID-PROPOSAL)
        (asserts! (>= effective-balance u100) ERR-INSUFFICIENT-TOKENS)
        (asserts! (<= amount (var-get treasury-balance)) ERR-INSUFFICIENT-TOKENS)
        
        (map-set proposals proposal-id
            {
                title: title,
                description: description,
                proposer: tx-sender,
                start-block: start-block,
                end-block: end-block,
                executed: false,
                cancelled: false,
                yes-votes: u0,
                no-votes: u0,
                proposal-type: "treasury",
                execution-data: (some {recipient: (some recipient), amount: (some amount), new-value: none})
            }
        )
        (create-voting-snapshot proposal-id tx-sender)
        (var-set proposal-count (+ proposal-id u1))
        (ok proposal-id)
    )
)

(define-public (create-parameter-proposal (title (string-ascii 50)) (description (string-ascii 500)) (duration uint) (new-quorum uint))
    (let
        (
            (proposal-id (var-get proposal-count))
            (start-block stacks-block-height)
            (end-block (+ stacks-block-height duration))
            (effective-balance (get-effective-voting-power tx-sender))
        )
        (asserts! (>= duration (var-get min-proposal-duration)) ERR-INVALID-PROPOSAL)
        (asserts! (>= effective-balance u100) ERR-INSUFFICIENT-TOKENS)
        
        (map-set proposals proposal-id
            {
                title: title,
                description: description,
                proposer: tx-sender,
                start-block: start-block,
                end-block: end-block,
                executed: false,
                cancelled: false,
                yes-votes: u0,
                no-votes: u0,
                proposal-type: "parameter",
                execution-data: (some {recipient: none, amount: none, new-value: (some new-quorum)})
            }
        )
        (create-voting-snapshot proposal-id tx-sender)
        (var-set proposal-count (+ proposal-id u1))
        (ok proposal-id)
    )
)

;; Proposal cancellation
(define-public (cancel-proposal (proposal-id uint))
    (let
        (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
        )
        (asserts! (is-eq tx-sender (get proposer proposal)) ERR-NOT-AUTHORIZED)
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-ALREADY-EXECUTED)
        (asserts! (not (get cancelled proposal)) ERR-PROPOSAL-CANCELLED)
        (asserts! (< stacks-block-height (get end-block proposal)) ERR-PROPOSAL-EXPIRED)
        
        (map-set proposals proposal-id (merge proposal {cancelled: true}))
        (ok true)
    )
)

;; Voting function
(define-public (vote (proposal-id uint) (vote-bool bool))
    (let
        (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
            (snapshot-power (get-snapshot-voting-power proposal-id tx-sender))
        )
        (asserts! (not (default-to false (map-get? votes {proposal-id: proposal-id, voter: tx-sender}))) ERR-ALREADY-VOTED)
        (asserts! (< stacks-block-height (get end-block proposal)) ERR-PROPOSAL-EXPIRED)
        (asserts! (not (get cancelled proposal)) ERR-PROPOSAL-CANCELLED)
        (asserts! (> snapshot-power u0) ERR-INSUFFICIENT-TOKENS)
        
        (map-set votes {proposal-id: proposal-id, voter: tx-sender} vote-bool)
        (map-set proposals proposal-id
            (merge proposal 
                {
                    yes-votes: (if vote-bool (+ (get yes-votes proposal) snapshot-power) (get yes-votes proposal)),
                    no-votes: (if vote-bool (get no-votes proposal) (+ (get no-votes proposal) snapshot-power))
                }
            )
        )
        (ok true)
    )
)

;; Proposal execution
(define-public (execute-proposal (proposal-id uint))
    (let
        (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
            (total-votes (+ (get yes-votes proposal) (get no-votes proposal)))
            (proposal-passed (and (> (get yes-votes proposal) (get no-votes proposal)) (>= total-votes (var-get quorum-threshold))))
        )
        (asserts! (>= stacks-block-height (get end-block proposal)) ERR-PROPOSAL-EXPIRED)
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-ALREADY-EXECUTED)
        (asserts! (not (get cancelled proposal)) ERR-PROPOSAL-CANCELLED)
        (asserts! proposal-passed ERR-PROPOSAL-NOT-PASSED)
        
        (if (is-eq (get proposal-type proposal) "treasury")
            (execute-treasury-proposal proposal-id proposal)
            (if (is-eq (get proposal-type proposal) "parameter")
                (execute-parameter-proposal proposal-id proposal)
                (execute-general-proposal proposal-id proposal)
            )
        )
    )
)

(define-private (execute-treasury-proposal (proposal-id uint) (proposal {title: (string-ascii 50), description: (string-ascii 500), proposer: principal, start-block: uint, end-block: uint, executed: bool, cancelled: bool, yes-votes: uint, no-votes: uint, proposal-type: (string-ascii 20), execution-data: (optional {recipient: (optional principal), amount: (optional uint), new-value: (optional uint)})}))
    (let
        (
            (exec-data (unwrap! (get execution-data proposal) ERR-EXECUTION-FAILED))
            (recipient (unwrap! (get recipient exec-data) ERR-EXECUTION-FAILED))
            (amount (unwrap! (get amount exec-data) ERR-EXECUTION-FAILED))
        )
        (try! (as-contract (stx-transfer? amount tx-sender recipient)))
        (var-set treasury-balance (- (var-get treasury-balance) amount))
        (map-set proposals proposal-id (merge proposal {executed: true}))
        (ok true)
    )
)

(define-private (execute-parameter-proposal (proposal-id uint) (proposal {title: (string-ascii 50), description: (string-ascii 500), proposer: principal, start-block: uint, end-block: uint, executed: bool, cancelled: bool, yes-votes: uint, no-votes: uint, proposal-type: (string-ascii 20), execution-data: (optional {recipient: (optional principal), amount: (optional uint), new-value: (optional uint)})}))
    (let
        (
            (exec-data (unwrap! (get execution-data proposal) ERR-EXECUTION-FAILED))
            (new-value (unwrap! (get new-value exec-data) ERR-EXECUTION-FAILED))
        )
        (var-set quorum-threshold new-value)
        (map-set proposals proposal-id (merge proposal {executed: true}))
        (ok true)
    )
)

(define-private (execute-general-proposal (proposal-id uint) (proposal {title: (string-ascii 50), description: (string-ascii 500), proposer: principal, start-block: uint, end-block: uint, executed: bool, cancelled: bool, yes-votes: uint, no-votes: uint, proposal-type: (string-ascii 20), execution-data: (optional {recipient: (optional principal), amount: (optional uint), new-value: (optional uint)})}))
    (begin
        (map-set proposals proposal-id (merge proposal {executed: true}))
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
    (map-get? votes {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-token-balance (account principal))
    (ft-get-balance governance-token account)
)

(define-read-only (get-treasury-balance)
    (var-get treasury-balance)
)

(define-read-only (get-quorum-threshold)
    (var-get quorum-threshold)
)

(define-read-only (get-delegation (delegator principal))
    (map-get? delegations delegator)
)

(define-read-only (get-delegation-count (delegate principal))
    (default-to u0 (map-get? delegation-counts delegate))
)

(define-read-only (get-effective-voting-power-read (voter principal))
    (get-effective-voting-power voter)
)

(define-read-only (is-proposal-cancelled (proposal-id uint))
    (match (map-get? proposals proposal-id)
        proposal (get cancelled proposal)
        false
    )
)

(define-read-only (get-voting-power-snapshot (proposal-id uint) (voter principal))
    (get-snapshot-voting-power proposal-id voter)
)

(define-read-only (has-voter-snapshot (proposal-id uint) (voter principal))
    (is-some (map-get? voting-power-snapshots {proposal-id: proposal-id, voter: voter}))
)

;; Token transfer function
(define-public (transfer-governance-tokens (amount uint) (recipient principal))
    (ft-transfer? governance-token amount tx-sender recipient)
)
