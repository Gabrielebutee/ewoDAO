# ewoDAO Governance Contract (Clarity)

This contract implements a minimal STX-based governance flow with proposal staking, quadratic-cost voting, delayed execution, and simple admin controls.

## Constants
- VOTING-PERIOD: u1440
- MIN-PROPOSAL-STAKE: u1000000
- EXECUTION-DELAY: u144
- MIN-VOTE-STAKE: u1

## State
- Data vars:
  - contract-owner: principal (initialized to the deployer via `tx-sender`)
  - next-proposal-id: uint (initialized to `u1`)
  - voting-paused: bool (initialized to `false`)
- Maps:
  - proposals: uint -> {
    proposer: principal,
    snapshot-height: uint,
    votes-for: uint,
    votes-against: uint,
    executed: bool,
    creation-height: uint,
    proposal-stake: uint
  }
  - votes: (proposal-id uint, voter principal) -> { weight: uint }

## Workflow (Public Functions)

1) create-proposal(proposal-stake uint) -> (response uint uint)
- Requires proposal-stake >= MIN-PROPOSAL-STAKE.
- Transfers `proposal-stake` STX from caller to the contract.
- Creates a proposal at the current `stacks-block-height`, with zeroed tallies and `executed=false`.
- Returns the new proposal id and increments `next-proposal-id`.

2) cast-vote(id uint, support bool, stake uint) -> (response bool uint)
- Requires:
  - Proposal exists.
  - Current height <= creation-height + VOTING-PERIOD.
  - Caller has not voted on this proposal.
  - stake >= MIN-VOTE-STAKE.
- Quadratic cost: transfers `stake * stake` STX from caller to the contract.
- Records the caller’s vote weight = `stake`.
- Adds `stake` to `votes-for` if `support=true`, otherwise to `votes-against`.

3) execute-proposal(id uint) -> (response bool uint)
- Requires:
  - Proposal exists.
  - Not already executed.
  - Current height > creation-height + VOTING-PERIOD.
  - Current height >= voting-end + EXECUTION-DELAY.
  - votes-for > votes-against.
- Marks the proposal executed and refunds `proposal-stake` from the contract to the proposer.

4) set-contract-owner(new-owner principal) -> (response bool uint)
- Only callable by current `contract-owner`. Updates the owner.

5) toggle-voting-pause() -> (response bool uint)
- Only callable by `contract-owner`. Flips and returns `voting-paused`.

## Read-only Functions
- get-proposal(id): returns proposal or none
- get-vote(proposal-id, voter): returns vote record or none
- has-voted(proposal-id, voter): bool
- is-voting-active(id): bool
  - True if current height <= voting-end AND `voting-paused` is false.
- can-execute(id): bool
  - True if not executed, voting ended, delay elapsed, and votes-for > votes-against.
- get-proposal-status(id): "executed" | "voting" | "pending" | "ready-to-execute" | "failed" | "not-found"
- get-contract-owner(): principal
- get-next-proposal-id(): uint
- is-voting-paused(): bool
- get-governance-params(): {
  voting-period, min-proposal-stake, execution-delay, min-vote-stake
}

## STX Flows
- create-proposal: transfers proposer’s `proposal-stake` to the contract.
- cast-vote: transfers `stake*stake` from voter to the contract.
- execute-proposal: transfers `proposal-stake` from the contract to the proposer.

## Error Codes (explicit in code)
- u1: proposal not found (unwrap in vote/execute).
- u3: double voting attempt.
- u4: proposal-stake below MIN-PROPOSAL-STAKE.
- u5: voting period not active (height > voting-end).
- u6: stake below MIN-VOTE-STAKE.
- u7: already executed.
- u8: voting period not yet ended.
- u9: execution delay not yet elapsed.
- u10: proposal did not pass (no strict majority).
- u11: caller is not contract-owner.
