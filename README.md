# StakingDegenZ
STAKINGSYSTEMV2
# ZStakingPoolV2

An improved single-pool staking contract for ERC20 tokens.  
This contract is designed to be simple, secure, and frontend-friendly while supporting features commonly required in staking systems.

## ✨ Features
- **Accurate Rewards**  
  Uses `rewardPerToken` accounting (Synthetix-inspired) for precise per-user reward calculation.

- **Configurable Lock & Penalty**  
  Owner can set `lockDuration` and early-withdrawal penalty (`penaltyBps`).  
  Penalty amounts are recycled into the reward pool.

- **Funding Rewards**  
  Owner funds reward distribution with `addReward(rewardAmount, duration)`.  
  Rewards are streamed linearly over time.

- **Auto-compound (optional)**  
  If `rewardToken == stakingToken`, users can enable auto-compounding their rewards back into stake.

- **Emergency Unstake**  
  Users can withdraw their principal without claiming rewards, bypassing locks.

- **Admin Controls**  
  - `pause` / `unpause`  
  - `transferOwnership`  
  - `setLockDuration`, `setPenaltyBps`  
  - `withdrawExcessRewards`

- **Events for Frontend Integration**  
  Every critical action (stake, withdraw, claim, reward funded, etc.) emits events.

- **Security Measures**  
  - `ReentrancyGuard`  
  - `Ownable` access control  
  - Minimal inlined `SafeERC20`

## 📖 How It Works
1. **Initialization**  
   Deploy contract and call `initialize(stakingToken, rewardToken, lockDuration, penaltyBps, owner, autoCompoundEnabled)`.

2. **Funding Rewards**  
   Owner transfers reward tokens using `addReward(reward, duration)`.  
   Reward tokens must be approved first.

3. **Staking**  
   - Users call `stake(amount)` after approving the staking token.  
   - Contract tracks balances and reward entitlement.

4. **Claiming Rewards**  
   - Users call `claim()` to receive rewards.  
   - Or `compound()` (if enabled) to re-stake rewards.

5. **Withdraw**  
   - Users call `withdraw(amount)` to withdraw principal and claim rewards.  
   - Early withdrawal applies penalty → recycled into reward pool.

6. **Exit**  
   - Shortcut: `exit()` to withdraw all principal + claim rewards.

7. **Emergency Unstake**  
   - Users can call `emergencyUnstake()` to withdraw principal only, ignoring rewards.

## 🛠️ Deployment Notes
- Contracts must be verified on **Etherscan/Basescan** for transparency.
- Owner should seed reward tokens and configure pool parameters before opening to public.
- Always test on a testnet before mainnet deployment.

## ⚠️ Security Notice
This contract has not undergone a professional audit yet.  
Use at your own risk. For production deployments, an independent security audit is strongly recommended.

## 📜 License
MIT License
