(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PROPOSAL (err u101))
(define-constant ERR-PROPOSAL-EXPIRED (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-INSUFFICIENT-TOKENS (err u104))

(define-fungible-token governance-token)

(define-data-var proposal-count uint u0)
(define-data-var min-proposal-duration uint u1440) ;; 24 hours in blocks

(define-map proposals 
    uint 
    {
        title: (string-ascii 50),
        description: (string-ascii 500),
        proposer: principal,
        start-block: uint,
        end-block: uint,
        executed: bool,
        yes-votes: uint,
        no-votes: uint
    }
)

(define-map votes 
    { proposal-id: uint, voter: principal } 
    bool
)

(define-data-var contract-owner principal tx-sender)

(define-public (initialize-token (total-supply uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (try! (ft-mint? governance-token total-supply tx-sender))
        (ok true)
    )
)

(define-public (create-proposal (title (string-ascii 50)) (description (string-ascii 500)) (duration uint))
    (let
        (
            (proposal-id (var-get proposal-count))
            (start-block stacks-block-height)
            (end-block (+ stacks-block-height duration))
            (token-balance (ft-get-balance governance-token tx-sender))
        )
        (asserts! (>= duration (var-get min-proposal-duration)) ERR-INVALID-PROPOSAL)
        (asserts! (>= token-balance u100) ERR-INSUFFICIENT-TOKENS)
        
        (map-set proposals proposal-id
            {
                title: title,
                description: description,
                proposer: tx-sender,
                start-block: start-block,
                end-block: end-block,
                executed: false,
                yes-votes: u0,
                no-votes: u0
            }
        )
        (var-set proposal-count (+ proposal-id u1))
        (ok proposal-id)
    )
)
(define-public (vote (proposal-id uint) (vote-bool bool))
    (let
        (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
            (voter-balance (ft-get-balance governance-token tx-sender))
        )
        (asserts! (not (default-to false (map-get? votes {proposal-id: proposal-id, voter: tx-sender}))) ERR-ALREADY-VOTED)
        (asserts! (< stacks-block-height (get end-block proposal)) ERR-PROPOSAL-EXPIRED)
        (asserts! (> voter-balance u0) ERR-INSUFFICIENT-TOKENS)
        
        (map-set votes {proposal-id: proposal-id, voter: tx-sender} vote-bool)
        (map-set proposals proposal-id
            (merge proposal 
                {
                    yes-votes: (if vote-bool (+ (get yes-votes proposal) voter-balance) (get yes-votes proposal)),
                    no-votes: (if vote-bool (get no-votes proposal) (+ (get no-votes proposal) voter-balance))
                }
            )
        )
        (ok true)
    )
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
    (map-get? votes {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-token-balance (account principal))
    (ft-get-balance governance-token account)
)

(define-public (transfer-governance-tokens (amount uint) (recipient principal))
    (ft-transfer? governance-token amount tx-sender recipient)
)
