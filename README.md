# 🌾 Agri Co-op Voting DAO

A decentralized governance platform for agricultural cooperatives built on Stacks blockchain.

## 🎯 Features

- 🏢 Create and manage proposals for co-op decisions
- 🗳️ Vote on proposals with governance tokens
- 💰 Token-weighted voting system
- ⏱️ Time-bound proposal periods
- 🔄 Transparent voting process

## 📚 Contract Functions

### Governance Token Operations
- `initialize-token`: Mint initial governance tokens
- `transfer-governance-tokens`: Transfer tokens between members

### Proposal Management
- `create-proposal`: Submit new proposals
- `vote`: Cast votes on active proposals
- `get-proposal`: View proposal details
- `get-vote`: Check member's vote
- `get-token-balance`: Check member's voting power

## 🚀 Getting Started

1. Deploy the contract using Clarinet:
```bash
clarinet deploy
```

2. Initialize governance tokens:
```bash
clarinet console
```

3. Create a proposal:
```bash
(contract-call? .agri-co-op-voting-dao create-proposal "Equipment Purchase" "Buy new tractor" u1440)
```

4. Cast your vote:
```bash
(contract-call? .agri-co-op-voting-dao vote u0 true)
```

## 🔒 Security

- Proposals require minimum token holdings
- One vote per member per proposal
- Time-locked voting periods
- Token-weighted voting power

## 🤝 Contributing

Feel free to submit issues and enhancement requests!

## 📜 License

MIT
```

