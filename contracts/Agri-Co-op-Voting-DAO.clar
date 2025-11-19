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
(define-constant ERR-INVALID-REPUTATION-ACTION (err u111))
(define-constant ERR-REPUTATION-OVERFLOW (err u112))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u113))

;; Governance token
(define-fungible-token governance-token)

;; Data variables
(define-data-var proposal-count uint u0)
(define-data-var min-proposal-duration uint u1440) ;; 24 hours in blocks
(define-data-var treasury-balance uint u0)
(define-data-var quorum-threshold uint u1000)
(define-data-var contract-owner principal tx-sender)

;; Reputation System Constants
(define-constant REPUTATION-CREATE-PROPOSAL u50)
(define-constant REPUTATION-VOTE-CAST u10)
(define-constant REPUTATION-PROPOSAL-EXECUTED u100)
(define-constant REPUTATION-DELEGATION u5)
(define-constant REPUTATION-STREAK-BONUS u25)
(define-constant REPUTATION-MAX-SCORE u10000)
(define-constant STREAK-RESET-BLOCKS u4320) ;; ~30 days
(define-constant VETO-COOLDOWN-BLOCKS u144)
(define-constant VETO-REPUTATION-THRESHOLD u5000)
(define-constant ERR-INSUFFICIENT-VETO-REPUTATION (err u114))
(define-constant ERR-VETO-COOLDOWN-ACTIVE (err u115))
(define-constant ERR-PROPOSAL-ALREADY-VETOED (err u116))

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

(define-map proposal-veto
    uint
    { vetoed: bool, by: principal, block: uint }
)

(define-map member-last-veto
    principal
    uint
)

;; Reputation System Maps
(define-map member-reputation
    principal
    {
        score: uint,
        proposals-created: uint,
        votes-cast: uint,
        participation-streak: uint,
        last-activity-block: uint,
        governance-contribution: uint
    }
)

(define-map reputation-actions
    { member: principal, action-type: (string-ascii 20), block-height: uint }
    {
        points-earned: uint,
        description: (string-ascii 100)
    }
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

;; Reputation System Functions
(define-private (initialize-member-reputation (member principal))
    (if (is-none (map-get? member-reputation member))
        (map-set member-reputation member
            {
                score: u0,
                proposals-created: u0,
                votes-cast: u0,
                participation-streak: u0,
                last-activity-block: u0,
                governance-contribution: u0
            }
        )
        true
    )
)

(define-private (update-reputation (member principal) (points uint) (action-type (string-ascii 20)))
    (let
        (
            (current-rep (default-to {score: u0, proposals-created: u0, votes-cast: u0, participation-streak: u0, last-activity-block: u0, governance-contribution: u0} (map-get? member-reputation member)))
            (new-score (+ (get score current-rep) points))
            (capped-score (if (> new-score REPUTATION-MAX-SCORE) REPUTATION-MAX-SCORE new-score))
            (streak-bonus (calculate-streak-bonus member))
        )
        (asserts! (<= new-score REPUTATION-MAX-SCORE) ERR-REPUTATION-OVERFLOW)
        
        ;; Update reputation record
        (map-set member-reputation member
            (merge current-rep 
                {
                    score: capped-score,
                    last-activity-block: stacks-block-height,
                    governance-contribution: (+ (get governance-contribution current-rep) points)
                }
            )
        )
        
        ;; Record the action
        (map-set reputation-actions 
            { member: member, action-type: action-type, block-height: stacks-block-height }
            { points-earned: points, description: action-type }
        )
        
        (ok capped-score)
    )
)

(define-private (calculate-streak-bonus (member principal))
    (let
        (
            (rep-data (default-to {score: u0, proposals-created: u0, votes-cast: u0, participation-streak: u0, last-activity-block: u0, governance-contribution: u0} (map-get? member-reputation member)))
            (last-activity (get last-activity-block rep-data))
            (blocks-since-activity (- stacks-block-height last-activity))
        )
        (if (and (> last-activity u0) (<= blocks-since-activity STREAK-RESET-BLOCKS))
            (+ (get participation-streak rep-data) u1)
            u0
        )
    )
)

(define-public (award-reputation (member principal) (points uint) (action (string-ascii 20)))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (> points u0) ERR-INVALID-REPUTATION-ACTION)
        (initialize-member-reputation member)
        (update-reputation member points action)
    )
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
        
        ;; Award reputation for creating proposal
        (initialize-member-reputation tx-sender)
        (let
            (
                (current-rep (default-to {score: u0, proposals-created: u0, votes-cast: u0, participation-streak: u0, last-activity-block: u0, governance-contribution: u0} (map-get? member-reputation tx-sender)))
            )
            (map-set member-reputation tx-sender
                (merge current-rep 
                    {
                        proposals-created: (+ (get proposals-created current-rep) u1),
                        participation-streak: (+ (calculate-streak-bonus tx-sender) u1)
                    }
                )
            )
            (unwrap-panic (update-reputation tx-sender REPUTATION-CREATE-PROPOSAL "proposal-created"))
        )
        
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

(define-public (veto-proposal (proposal-id uint))
    (let
        (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
            (score (get-reputation-score tx-sender))
            (last-veto (default-to u0 (map-get? member-last-veto tx-sender)))
            (blocks-since (- stacks-block-height last-veto))
        )
        (asserts! (>= score VETO-REPUTATION-THRESHOLD) ERR-INSUFFICIENT-VETO-REPUTATION)
        (asserts! (>= blocks-since VETO-COOLDOWN-BLOCKS) ERR-VETO-COOLDOWN-ACTIVE)
        (asserts! (is-none (map-get? proposal-veto proposal-id)) ERR-PROPOSAL-ALREADY-VETOED)
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-ALREADY-EXECUTED)
        (asserts! (not (get cancelled proposal)) ERR-PROPOSAL-CANCELLED)
        (map-set proposals proposal-id (merge proposal {cancelled: true}))
        (map-set proposal-veto proposal-id { vetoed: true, by: tx-sender, block: stacks-block-height })
        (map-set member-last-veto tx-sender stacks-block-height)
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
        
        ;; Award reputation for voting
        (initialize-member-reputation tx-sender)
        (let
            (
                (current-rep (default-to {score: u0, proposals-created: u0, votes-cast: u0, participation-streak: u0, last-activity-block: u0, governance-contribution: u0} (map-get? member-reputation tx-sender)))
            )
            (map-set member-reputation tx-sender
                (merge current-rep 
                    {
                        votes-cast: (+ (get votes-cast current-rep) u1),
                        participation-streak: (+ (calculate-streak-bonus tx-sender) u1)
                    }
                )
            )
            (unwrap-panic (update-reputation tx-sender REPUTATION-VOTE-CAST "vote-cast"))
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
        (asserts! (not (is-proposal-vetoed proposal-id)) ERR-PROPOSAL-CANCELLED)
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

;; Reputation System Read-Only Functions
(define-read-only (get-member-reputation (member principal))
    (map-get? member-reputation member)
)

(define-read-only (get-reputation-score (member principal))
    (match (map-get? member-reputation member)
        rep-data (get score rep-data)
        u0
    )
)

(define-read-only (get-member-participation-stats (member principal))
    (match (map-get? member-reputation member)
        rep-data {
            proposals-created: (get proposals-created rep-data),
            votes-cast: (get votes-cast rep-data),
            participation-streak: (get participation-streak rep-data),
            governance-contribution: (get governance-contribution rep-data)
        }
        {
            proposals-created: u0,
            votes-cast: u0,
            participation-streak: u0,
            governance-contribution: u0
        }
    )
)

(define-read-only (get-reputation-action (member principal) (action-type (string-ascii 20)) (target-block uint))
    (map-get? reputation-actions { member: member, action-type: action-type, block-height: target-block })
)

(define-read-only (is-active-member (member principal))
    (match (map-get? member-reputation member)
        rep-data (let
            (
                (blocks-since-activity (- stacks-block-height (get last-activity-block rep-data)))
            )
            (<= blocks-since-activity STREAK-RESET-BLOCKS)
        )
        false
    )
)

(define-read-only (get-reputation-tier (member principal))
    (let
        (
            (score (get-reputation-score member))
        )
        (if (>= score u5000)
            "Expert"
            (if (>= score u2000)
                "Advanced"
                (if (>= score u500)
                    "Intermediate"
                    (if (>= score u100)
                        "Beginner"
                        "Newcomer"
                    )
                )
            )
        )
    )
)

(define-read-only (is-proposal-vetoed (proposal-id uint))
    (match (map-get? proposal-veto proposal-id)
        v (get vetoed v)
        false
    )
)

(define-read-only (get-member-last-veto (member principal))
    (default-to u0 (map-get? member-last-veto member))
)

;; Token transfer function
(define-public (transfer-governance-tokens (amount uint) (recipient principal))
    (ft-transfer? governance-token amount tx-sender recipient)
)
