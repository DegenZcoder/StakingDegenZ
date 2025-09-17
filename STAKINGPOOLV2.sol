/**
 *Submitted for verification at basescan.org on 2025-09-17
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
  ZStakingPoolV2 - improved single-pool staking contract
  - rewardPerToken accounting (accurate per-user rewards)
  - each user has single balance slot (balance + depositTime)
  - owner funds rewards via addReward(reward, duration)
  - compound supported if rewardToken == stakingToken and autoCompoundEnabled
  - penalty on early withdraw recycled into rewardPool
  - emergencyUnstake (user withdraw principal without rewards)
  - pause, owner controls, and safe ERC20 calls
  - events for frontend
  NOTE: For production, prefer OpenZeppelin imports (Ownable, ReentrancyGuard, SafeERC20).
*/

library SafeERC20 {
    function _callOptionalReturn(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        require(success, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: operation did not succeed");
        }
    }
    function safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(0xa9059cbb, to, value));
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(0x23b872dd, from, to, value));
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor(){ _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "Reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract ZStakingPoolV2 is ReentrancyGuard, Ownable {
    using SafeERC20 for address;

    // Tokens
    address public stakingToken;
    address public rewardToken;

    // staking / reward accounting
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public depositTime; // for lockDuration/penalty

    // reward distribution (Synthetix-like)
    uint256 public rewardPerTokenStored; // scaled by 1e18
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // accrued but not yet claimed

    uint256 public rewardRate; // tokens/second (unscaled)
    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    // params
    uint256 public lockDuration; // seconds
    uint256 public penaltyBps; // basis points (10000 = 100%)
    uint256 public rewardPool; // tokens available (backing)

    bool public initialized;
    bool public paused;
    bool public autoCompoundEnabled;

    // events
    event Initialized(address stakingToken, address rewardToken, uint256 lockDuration, uint256 penaltyBps, bool autoCompound);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 principal, uint256 reward, uint256 penalty);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 duration);
    event AutoCompoundSet(bool enabled);
    event Paused(address by);
    event Unpaused(address by);
    event EmergencyUnstaked(address indexed user, uint256 principal);
    event PenaltyRecycled(uint256 amount);

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor() {
        // lock (if used as implementation for clones)
        initialized = true;
    }

    // initialize for clones or deploy directly with initialize call
    function initialize(
        address _stakingToken,
        address _rewardToken,
        uint256 _lockDuration,
        uint256 _penaltyBps,
        address _owner,
        bool _autoCompoundEnabled
    ) external {
        require(!initialized, "Already initialized");
        require(_stakingToken != address(0) && _rewardToken != address(0), "Zero token");
        require(_owner != address(0), "Zero owner");
        require(_penaltyBps <= 10000, "Penalty >100%");
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        lockDuration = _lockDuration;
        penaltyBps = _penaltyBps;
        owner = _owner;
        autoCompoundEnabled = _autoCompoundEnabled;

        lastUpdateTime = block.timestamp;
        initialized = true;
        paused = false;

        emit Initialized(stakingToken, rewardToken, lockDuration, penaltyBps, autoCompoundEnabled);
    }

    /* ---------------- Reward math ---------------- */
    // lastTimeRewardApplicable = min(now, periodFinish)
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // rewardPerToken = rewardPerTokenStored + (deltaTime * rewardRate * 1e18 / totalStaked)
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        uint256 lastTime = lastTimeRewardApplicable();
        uint256 dt = lastTime - lastUpdateTime;
        if (dt == 0) return rewardPerTokenStored;
        uint256 add = (dt * rewardRate * 1e18) / totalStaked;
        return rewardPerTokenStored + add;
    }

    // earned(user) = balance * (rewardPerToken - userRewardPerTokenPaid) / 1e18 + rewards[user]
    function earned(address account) public view returns (uint256) {
        uint256 rpt = rewardPerToken();
        uint256 paid = userRewardPerTokenPaid[account];
        uint256 bal = balanceOf[account];
        uint256 earned_ = (bal * (rpt - paid)) / 1e18 + rewards[account];
        return earned_;
    }

    // modifier to update reward accounting for an account
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ---------------- Owner functions ---------------- */

    // Owner funds reward pool and sets distribution duration (seconds).
    // Owner must approve rewardToken to this contract before calling.
    function addReward(uint256 reward, uint256 duration) external onlyOwner updateReward(address(0)) {
        require(reward > 0 && duration > 0, "Invalid");
        // transfer in reward tokens
        rewardToken.safeTransferFrom(msg.sender, address(this), reward);
        rewardPool += reward;

        // compute rewardRate considering leftover
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + remaining) / duration;
        }
        periodFinish = block.timestamp + duration;
        emit RewardAdded(reward, duration);
    }

    // owner can set autoCompound flag (if rewardToken==stakingToken)
    function setAutoCompoundEnabled(bool v) external onlyOwner {
        require(!v || rewardToken == stakingToken, "Compound needs same token");
        autoCompoundEnabled = v;
        emit AutoCompoundSet(v);
    }

    function setLockDuration(uint256 d) external onlyOwner { lockDuration = d; }
    function setPenaltyBps(uint256 bps) external onlyOwner { require(bps <= 10000, "Too high"); penaltyBps = bps; }

    function pause() external onlyOwner { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    // withdraw excess reward tokens beyond rewardPool
    function withdrawExcessRewards(uint256 amount, address to) external onlyOwner updateReward(address(0)) {
        require(to != address(0), "Zero");
        uint256 bal = _erc20Balance(rewardToken, address(this));
        require(bal >= rewardPool, "Invariant");
        uint256 excess = bal - rewardPool;
        require(amount <= excess, "Amount>excess");
        if (amount > 0) {
            rewardToken.safeTransfer(to, amount);
        }
    }

    /* ---------------- User functions ---------------- */

    // stake: single-slot model (balanceOf increases)
    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Zero");
        // transfer in
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        // if first deposit or top-up, set depositTime to now (we treat lock per-user)
        depositTime[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    // claim earned rewards
    function claim() public nonReentrant notPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        if (reward > rewardPool) reward = rewardPool; // cap
        rewards[msg.sender] -= reward;
        rewardPool -= reward;
        rewardToken.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    // withdraw principal (with reward paid) - applies penalty if within lockDuration
    function withdraw(uint256 amount) public nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Zero");
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        // compute penalty
        uint256 penalty = 0;
        if (block.timestamp < depositTime[msg.sender] + lockDuration) {
            penalty = (amount * penaltyBps) / 10000;
        }
        uint256 returnAmount = amount - penalty;
        // update balances before transfers
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        // pay reward
        uint256 reward = rewards[msg.sender];
        if (reward > rewardPool) reward = rewardPool;
        if (reward > 0) {
            rewards[msg.sender] -= reward;
            rewardPool -= reward;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }

        // recycle penalty into rewardPool
        if (penalty > 0) {
            rewardPool += penalty;
            emit PenaltyRecycled(penalty);
        }

        // transfer principal back
        if (returnAmount > 0) {
            stakingToken.safeTransfer(msg.sender, returnAmount);
        }
        emit Withdrawn(msg.sender, returnAmount, reward, penalty);
    }

    // exit = claim + withdrawAll
    function exit() external {
        withdraw(balanceOf[msg.sender]);
    }

    // emergencyUnstake: withdraw only principal ignoring rewards (no rewards, bypass lock)
    function emergencyUnstake() external nonReentrant {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "No balance");
        // clear rewards snapshot but keep reward accounting consistent
        // remove user's stake
        balanceOf[msg.sender] = 0;
        totalStaked -= bal;
        // do not pay rewards
        // transfer principal back
        stakingToken.safeTransfer(msg.sender, bal);
        emit EmergencyUnstaked(msg.sender, bal);
    }

    // compound: convert earned reward into stake (only if enabled and same token)
    function compound() external nonReentrant notPaused updateReward(msg.sender) {
        require(autoCompoundEnabled, "AutoCompound disabled");
        require(rewardToken == stakingToken, "rewardToken != stakingToken");
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No reward");
        if (reward > rewardPool) reward = rewardPool;
        // reduce reward balances
        rewards[msg.sender] -= reward;
        rewardPool -= reward;

        // increase stake
        balanceOf[msg.sender] += reward;
        totalStaked += reward;
        depositTime[msg.sender] = block.timestamp; // reset lock for compounded amount
        emit RewardPaid(msg.sender, reward);
        emit Staked(msg.sender, reward);
    }

    /* ---------------- Views / helpers ---------------- */

    function getUserInfo(address user) external view returns (
        uint256 balance,
        uint256 pendingReward,
        uint256 depositAt
    ) {
        balance = balanceOf[user];
        pendingReward = earned(user);
        depositAt = depositTime[user];
    }

    function getPoolInfo() external view returns (
        address _stakingToken,
        address _rewardToken,
        uint256 _totalStaked,
        uint256 _rewardPool,
        uint256 _rewardRate,
        uint256 _periodFinish,
        uint256 _lockDuration,
        uint256 _penaltyBps,
        bool _autoCompound,
        bool _paused
    ) {
        return (
            stakingToken,
            rewardToken,
            totalStaked,
            rewardPool,
            rewardRate,
            periodFinish,
            lockDuration,
            penaltyBps,
            autoCompoundEnabled,
            paused
        );
    }

    /* ---------------- Internals ---------------- */
    function _erc20Balance(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        require(success && data.length >= 32, "bad balanceOf");
        return abi.decode(data, (uint256));
    }
}
