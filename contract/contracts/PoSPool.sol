//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@confluxfans/contracts/InternalContracts/ParamsControl.sol";
import "./PoolContext.sol";
import "./utils/VotePowerQueue.sol";
import "./utils/PoolAPY.sol";
import "./interfaces/IVotingEscrow.sol";

///
///  @title PoSPool
///  @dev This is Conflux PoS pool contract
///  @notice Users can use this contract to participate Conflux PoS without running a PoS node.
///
contract PoSPool is PoolContext, Ownable, Initializable {
  using SafeMath for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;
  using VotePowerQueue for VotePowerQueue.InOutQueue;
  using PoolAPY for PoolAPY.ApyQueue;

  uint256 private RATIO_BASE = 10000;
  uint256 private CFX_COUNT_OF_ONE_VOTE = 1000;
  uint256 private CFX_VALUE_OF_ONE_VOTE = 1000 ether;
  uint256 private ONE_DAY_BLOCK_COUNT = 2 * 3600 * 24;
  uint256 private ONE_YEAR_BLOCK_COUNT = ONE_DAY_BLOCK_COUNT * 365;
  
  // ======================== Pool config =========================

  string public poolName;
  // wheter this poolContract registed in PoS
  bool public _poolRegisted;
  // ratio shared by user: 1-10000
  uint256 public poolUserShareRatio = 9000; 
  // lock period: 13 days + half hour
  uint256 public _poolLockPeriod = ONE_DAY_BLOCK_COUNT * 13 + 3600; 

  // ======================== Struct definitions =========================

  struct PoolSummary {
    uint256 available;
    uint256 interest; // PoS pool interest share
    uint256 totalInterest; // total interest of whole pools
  }

  /// @title UserSummary
  /// @custom:field votes User's total votes
  /// @custom:field available User's avaliable votes
  /// @custom:field locked
  /// @custom:field unlocked
  /// @custom:field claimedInterest
  /// @custom:field currentInterest
  struct UserSummary {
    uint256 votes;  // Total votes in PoS system, including locking, locked, unlocking, unlocked
    uint256 available; // locking + locked
    uint256 locked;
    uint256 unlocked;
    uint256 claimedInterest;
    uint256 currentInterest;
  }

  struct PoolShot {
    uint256 available;
    uint256 balance;
    uint256 blockNumber;
  } 

  struct UserShot {
    uint256 available;
    uint256 accRewardPerCfx;
    uint256 blockNumber;
  }

  // ======================== Contract states =========================

  // global pool accumulative reward for each cfx
  uint256 public accRewardPerCfx;  // start from 0

  PoolSummary private _poolSummary;
  mapping(address => UserSummary) private userSummaries;
  mapping(address => VotePowerQueue.InOutQueue) private userInqueues;
  mapping(address => VotePowerQueue.InOutQueue) private userOutqueues;

  PoolShot internal lastPoolShot;
  mapping(address => UserShot) internal lastUserShots;
  
  EnumerableSet.AddressSet private stakers;
  // used to calculate latest seven days APY
  PoolAPY.ApyQueue private apyNodes;

  // Free fee whitelist
  EnumerableSet.AddressSet private feeFreeWhiteList;

  // unlock period: 1 days + half hour
  uint256 public _poolUnlockPeriod = ONE_DAY_BLOCK_COUNT + 3600; 

  string public constant VERSION = "1.6.0";

  ParamsControl public paramsControl = ParamsControl(0x0888000000000000000000000000000000000007);

  address public votingEscrow;

  address public manager; // added in version 1.6.0

  // ======================== Modifiers =========================
  modifier onlyRegisted() {
    require(_poolRegisted, "Pool is not registed");
    _;
  }

  modifier onlyVotingEscrow() {
    require(msg.sender == votingEscrow && votingEscrow != address(0), "Only votingEscrow can call this function");
    _;
  }

  modifier onlyManager() {
    require(msg.sender == manager, "Only manager can call this function");
    _;
  }

  // ======================== Helpers =========================

  function _userShareRatio(address _user) public view returns (uint256) {
    if (feeFreeWhiteList.contains(_user)) return RATIO_BASE;
    return poolUserShareRatio;
  }

  function _calUserShare(uint256 reward, address _stakerAddress) private view returns (uint256) {
    return reward.mul(_userShareRatio(_stakerAddress)).div(RATIO_BASE);
  }

  // used to update lastPoolShot after _poolSummary.available changed 
  function _updatePoolShot() private {
    lastPoolShot.available = _poolSummary.available;
    lastPoolShot.balance = _selfBalance();
    lastPoolShot.blockNumber = _blockNumber();
  }

  // used to update lastUserShot after userSummary.available and accRewardPerCfx changed
  function _updateUserShot(address _user) private {
    lastUserShots[_user].available = userSummaries[_user].available;
    lastUserShots[_user].accRewardPerCfx = accRewardPerCfx;
    lastUserShots[_user].blockNumber = _blockNumber();
  }

  // used to update accRewardPerCfx after _poolSummary.available changed or user claimed interest
  // depend on: lastPoolShot.available and lastPoolShot.balance
  function _updateAccRewardPerCfx() private {
    uint256 reward = _selfBalance() - lastPoolShot.balance;
    if (reward == 0 || lastPoolShot.available == 0) return;

    // update global accRewardPerCfx
    uint256 cfxCount = lastPoolShot.available.mul(CFX_COUNT_OF_ONE_VOTE);
    accRewardPerCfx = accRewardPerCfx.add(reward.div(cfxCount));

    // update pool interest info
    _poolSummary.totalInterest = _poolSummary.totalInterest.add(reward);
  }

  // depend on: accRewardPerCfx and lastUserShot
  function _updateUserInterest(address _user) private {
    UserShot memory uShot = lastUserShots[_user];
    if (uShot.available == 0) return;
    uint256 latestInterest = accRewardPerCfx.sub(uShot.accRewardPerCfx).mul(uShot.available.mul(CFX_COUNT_OF_ONE_VOTE));
    uint256 _userInterest = _calUserShare(latestInterest, _user);
    userSummaries[_user].currentInterest = userSummaries[_user].currentInterest.add(_userInterest);
    _poolSummary.interest = _poolSummary.interest.add(latestInterest.sub(_userInterest));
  }

  // depend on: lastPoolShot
  function _updateAPY() private {
    if (_blockNumber() == lastPoolShot.blockNumber)  return;
    uint256 reward = _selfBalance() - lastPoolShot.balance;
    PoolAPY.ApyNode memory node = PoolAPY.ApyNode({
      startBlock: lastPoolShot.blockNumber,
      endBlock: _blockNumber(),
      reward: reward,
      available: lastPoolShot.available
    });

    uint256 outdatedBlock = 0;
    if (_blockNumber() > ONE_DAY_BLOCK_COUNT.mul(7)) {
      outdatedBlock = _blockNumber().sub(ONE_DAY_BLOCK_COUNT.mul(7));
    }
    apyNodes.enqueueAndClearOutdated(node, outdatedBlock);
  }

  // ======================== Events =========================

  event IncreasePoSStake(address indexed user, uint256 votePower);

  event DecreasePoSStake(address indexed user, uint256 votePower);

  event WithdrawStake(address indexed user, uint256 votePower);

  event ClaimInterest(address indexed user, uint256 amount);

  event RatioChanged(uint256 ratio);

  // error UnnormalReward(uint256 previous, uint256 current, uint256 blockNumber);

  // ======================== Init methods =========================

  // call this method when depoly the 1967 proxy contract
  function initialize() public initializer {
    RATIO_BASE = 10000;
    CFX_COUNT_OF_ONE_VOTE = 1000;
    CFX_VALUE_OF_ONE_VOTE = 1000 ether;
    ONE_DAY_BLOCK_COUNT = 2 * 3600 * 24;
    ONE_YEAR_BLOCK_COUNT = ONE_DAY_BLOCK_COUNT * 365;
    poolUserShareRatio = 9000;
    _poolLockPeriod = ONE_DAY_BLOCK_COUNT * 13 + 3600;
    _poolUnlockPeriod = ONE_DAY_BLOCK_COUNT * 1 + 3600;
    manager = msg.sender;
  }
  
  ///
  /// @notice Regist the pool contract in PoS internal contract 
  /// @dev Only admin can do this
  /// @param indentifier The identifier of PoS node
  /// @param votePower The vote power when register
  /// @param blsPubKey The bls public key of PoS node
  /// @param vrfPubKey The vrf public key of PoS node
  /// @param blsPubKeyProof The bls public key proof of PoS node
  ///
  function register(
    bytes32 indentifier,
    uint64 votePower,
    bytes calldata blsPubKey,
    bytes calldata vrfPubKey,
    bytes[2] calldata blsPubKeyProof
  ) public virtual payable onlyOwner {
    require(!_poolRegisted, "Pool is already registed");
    require(votePower == 1, "votePower should be 1");
    require(msg.value == votePower * CFX_VALUE_OF_ONE_VOTE, "msg.value should be 1000 CFX");
    _stakingDeposit(msg.value);
    _posRegisterRegister(indentifier, votePower, blsPubKey, vrfPubKey, blsPubKeyProof);
    _poolRegisted = true;

    // update user info
    userSummaries[msg.sender].votes += votePower;
    userSummaries[msg.sender].available += votePower;
    userSummaries[msg.sender].locked += votePower;  // directly add to admin's locked votes
    _updateUserShot(msg.sender);
    //
    stakers.add(msg.sender);

    // update pool info
    _poolSummary.available += votePower;
    _updatePoolShot();
  }

  // ======================== Contract methods =========================

  ///
  /// @notice Increase PoS vote power
  /// @param votePower The number of vote power to increase
  ///
  function increaseStake(uint64 votePower) public virtual payable onlyRegisted {
    require(votePower > 0, "Minimal votePower is 1");
    require(msg.value == votePower * CFX_VALUE_OF_ONE_VOTE, "msg.value should be votePower * 1000 ether");
    
    _stakingDeposit(msg.value);
    _posRegisterIncreaseStake(votePower);
    emit IncreasePoSStake(msg.sender, votePower);

    _updateAccRewardPerCfx();
    _updateAPY();
    
    // update user interest
    _updateUserInterest(msg.sender);
    // put stake info in queue
    userInqueues[msg.sender].enqueue(VotePowerQueue.QueueNode(votePower, _blockNumber() + _poolLockPeriod));
    userSummaries[msg.sender].locked += userInqueues[msg.sender].collectEndedVotes();
    userSummaries[msg.sender].votes += votePower;
    userSummaries[msg.sender].available += votePower;
    _updateUserShot(msg.sender);

    stakers.add(msg.sender);

    //
    _poolSummary.available += votePower;
    _updatePoolShot();
  }

  ///
  /// @notice Decrease PoS vote power
  /// @param votePower The number of vote power to decrease
  ///
  function decreaseStake(uint64 votePower) public virtual onlyRegisted {
    userSummaries[msg.sender].locked += userInqueues[msg.sender].collectEndedVotes();
    require(userSummaries[msg.sender].locked >= votePower, "Locked is not enough");
    
    // if user has locked cfx for vote power, the rest amount should bigger than that
    if (votingEscrow != address(0)) {
      IVotingEscrow.LockInfo memory lockInfo = IVotingEscrow(votingEscrow).userLockInfo(msg.sender);
      require((userSummaries[msg.sender].available - votePower) * CFX_VALUE_OF_ONE_VOTE >= lockInfo.amount, "Locked is not enough");
    }

    _posRegisterRetire(votePower);
    emit DecreasePoSStake(msg.sender, votePower);

    _updateAccRewardPerCfx();
    _updateAPY();

    // update user interest
    _updateUserInterest(msg.sender);
    //
    userOutqueues[msg.sender].enqueue(VotePowerQueue.QueueNode(votePower, _blockNumber() + _poolUnlockPeriod));
    userSummaries[msg.sender].unlocked += userOutqueues[msg.sender].collectEndedVotes();
    userSummaries[msg.sender].available -= votePower;
    userSummaries[msg.sender].locked -= votePower;
    _updateUserShot(msg.sender);

    //
    _poolSummary.available -= votePower;
    _updatePoolShot();
  }

  ///
  /// @notice Withdraw PoS vote power
  /// @param votePower The number of vote power to withdraw
  ///
  function withdrawStake(uint64 votePower) public onlyRegisted {
    userSummaries[msg.sender].unlocked += userOutqueues[msg.sender].collectEndedVotes();
    require(userSummaries[msg.sender].unlocked >= votePower, "Unlocked is not enough");
    _stakingWithdraw(votePower * CFX_VALUE_OF_ONE_VOTE);
    //    
    userSummaries[msg.sender].unlocked -= votePower;
    userSummaries[msg.sender].votes -= votePower;
    
    address payable receiver = payable(msg.sender);
    receiver.transfer(votePower * CFX_VALUE_OF_ONE_VOTE);
    emit WithdrawStake(msg.sender, votePower);

    if (userSummaries[msg.sender].votes == 0) {
      stakers.remove(msg.sender);
    }
  }

  ///
  /// @notice User's interest from participate PoS
  /// @param _address The address of user to query
  /// @return CFX interest in Drip
  ///
  function userInterest(address _address) public view returns (uint256) {
    uint256 _interest = userSummaries[_address].currentInterest;

    uint256 _latestAccRewardPerCfx = accRewardPerCfx;
    // add latest profit
    uint256 _latestReward = _selfBalance() - lastPoolShot.balance;
    UserShot memory uShot = lastUserShots[_address];
    if (_latestReward > 0) {
      uint256 _deltaAcc = _latestReward.div(lastPoolShot.available.mul(CFX_COUNT_OF_ONE_VOTE));
      _latestAccRewardPerCfx = _latestAccRewardPerCfx.add(_deltaAcc);
    }

    if (uShot.available > 0) {
      uint256 _latestInterest = _latestAccRewardPerCfx.sub(uShot.accRewardPerCfx).mul(uShot.available.mul(CFX_COUNT_OF_ONE_VOTE));
      _interest = _interest.add(_calUserShare(_latestInterest, _address));
    }

    return _interest;
  }

  ///
  /// @notice Claim specific amount user interest
  /// @param amount The amount of interest to claim
  ///
  function claimInterest(uint amount) public onlyRegisted {
    uint claimableInterest = userInterest(msg.sender);
    require(claimableInterest >= amount, "Interest not enough");

    _updateAccRewardPerCfx();
    _updateAPY();

    _updateUserInterest(msg.sender);
    //
    userSummaries[msg.sender].claimedInterest = userSummaries[msg.sender].claimedInterest.add(amount);
    userSummaries[msg.sender].currentInterest = userSummaries[msg.sender].currentInterest.sub(amount);
    // update userShot's accRewardPerCfx
    _updateUserShot(msg.sender);

    // send interest to user
    address payable receiver = payable(msg.sender);
    receiver.transfer(amount);
    emit ClaimInterest(msg.sender, amount);

    // update blockNumber and balance
    _updatePoolShot();
  }

  ///
  /// @notice Claim one user's all interest
  ///
  function claimAllInterest() public onlyRegisted {
    uint claimableInterest = userInterest(msg.sender);
    require(claimableInterest > 0, "No claimable interest");
    claimInterest(claimableInterest);
  }

  /// 
  /// @notice Get user's pool summary
  /// @param _user The address of user to query
  /// @return User's summary
  ///
  function userSummary(address _user) public view returns (UserSummary memory) {
    UserSummary memory summary = userSummaries[_user];
    summary.locked += userInqueues[_user].sumEndedVotes();
    summary.unlocked += userOutqueues[_user].sumEndedVotes();
    return summary;
  }

  function poolSummary() public view returns (PoolSummary memory) {
    PoolSummary memory summary = _poolSummary;
    uint256 _latestReward = _selfBalance().sub(lastPoolShot.balance);
    summary.totalInterest = summary.totalInterest.add(_latestReward);
    return summary;
  }

  function poolAPY() public view returns (uint256) {
    if(apyNodes.start == apyNodes.end) return 0;
    
    uint256 totalReward = 0;
    uint256 totalWorkload = 0;
    for(uint256 i = apyNodes.start; i < apyNodes.end; i++) {
      PoolAPY.ApyNode memory node = apyNodes.items[i];
      totalReward = totalReward.add(node.reward);
      totalWorkload = totalWorkload.add(node.available.mul(CFX_VALUE_OF_ONE_VOTE).mul(node.endBlock - node.startBlock));
    }

    if (_blockNumber() > lastPoolShot.blockNumber) {
      uint256 _latestReward = _selfBalance().sub(lastPoolShot.balance);
      totalReward = totalReward.add(_latestReward);
      totalWorkload = totalWorkload.add(lastPoolShot.available.mul(CFX_VALUE_OF_ONE_VOTE).mul(_blockNumber() - lastPoolShot.blockNumber));
    }

    return totalReward.mul(RATIO_BASE).mul(ONE_YEAR_BLOCK_COUNT).div(totalWorkload);
  }

  /// 
  /// @notice Query pools contract address
  /// @return Pool's PoS address
  ///
  function posAddress() public view onlyRegisted returns (bytes32) {
    return _posAddressToIdentifier(address(this));
  }

  function userInQueue(address account) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userInqueues[account].queueItems();
  }

  function userOutQueue(address account) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userOutqueues[account].queueItems();
  }

  function userInQueue(address account, uint64 offset, uint64 limit) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userInqueues[account].queueItems(offset, limit);
  }

  function userOutQueue(address account, uint64 offset, uint64 limit) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userOutqueues[account].queueItems(offset, limit);
  }

  function stakerNumber() public view returns (uint) {
    return stakers.length();
  }

  function stakerAddress(uint256 i) public view returns (address) {
    return stakers.at(i);
  }

  function userShareRatio() public view returns (uint256) {
    return _userShareRatio(msg.sender);
  }

  function poolShot() public view returns (PoolShot memory) {
    return lastPoolShot;
  }

  function userShot(address _user) public view returns (UserShot memory) {
    return lastUserShots[_user];
  }

  function lockForVotePower(uint256 amount, uint256 unlockBlockNumber) public onlyVotingEscrow {
    _stakingVoteLock(amount, unlockBlockNumber);
  }

  function castVote(uint64 vote_round, ParamsControl.Vote[] calldata vote_data) public onlyVotingEscrow {
    paramsControl.castVote(vote_round, vote_data);
  }

  function userLockInfo(address user) public view returns (IVotingEscrow.LockInfo memory) {
    if (votingEscrow == address(0)) return IVotingEscrow.LockInfo(0, 0);
    return IVotingEscrow(votingEscrow).userLockInfo(user);
  }

  function userVotePower(address user) external view returns (uint256) {
    if (votingEscrow == address(0)) return 0;
    return IVotingEscrow(votingEscrow).userVotePower(user);
  }

  // ======================== admin methods =====================

  ///
  /// @notice Enable admin to set the user share ratio
  /// @dev The ratio base is 10000, only admin can do this
  /// @param ratio The interest user share ratio (1-10000), default is 9000
  ///
  function setPoolUserShareRatio(uint64 ratio) public onlyManager {
    require(ratio > 0 && ratio <= RATIO_BASE, "ratio should be 1-10000");
    poolUserShareRatio = ratio;
    emit RatioChanged(ratio);
  }

  /// 
  /// @notice Enable admin to set the lock and unlock period
  /// @dev Only admin can do this
  /// @param period The lock period in block number, default is seven day's block count
  ///
  function setLockPeriod(uint64 period) public onlyManager {
    _poolLockPeriod = period;
  }

  function setUnlockPeriod(uint64 period) public onlyManager {
    _poolUnlockPeriod = period;
  }

  function addToFeeFreeWhiteList(address _freeAddress) public onlyManager returns (bool) {
    return feeFreeWhiteList.add(_freeAddress);
  }

  function removeFromFeeFreeWhiteList(address _freeAddress) public onlyManager returns (bool) {
    return feeFreeWhiteList.remove(_freeAddress);
  }

  /// 
  /// @notice Enable admin to set the pool name
  ///
  function setPoolName(string memory name) public onlyManager {
    poolName = name;
  }

  /// @param count Vote cfx count, unit is cfx
  function setCfxCountOfOneVote(uint256 count) public onlyOwner {
    CFX_COUNT_OF_ONE_VOTE = count;
    CFX_VALUE_OF_ONE_VOTE = count * 1 ether;
  }

  function setVotingEscrow(address _votingEscrow) public onlyOwner {
    votingEscrow = _votingEscrow;
  }

  function setManager(address _manager) public onlyOwner {
    manager = _manager;
  }

  function setParamsControl() public onlyOwner {
    paramsControl = ParamsControl(0x0888000000000000000000000000000000000007);
  }

  function _withdrawPoolProfit(uint256 amount) public onlyOwner {
    require(_poolSummary.interest > amount, "Not enough interest");
    require(_selfBalance() > amount, "Balance not enough");
    _poolSummary.interest = _poolSummary.interest.sub(amount);
    address payable receiver = payable(msg.sender);
    receiver.transfer(amount);
    _updatePoolShot();
  }

  function _restakePosVote(uint64 votes) public onlyManager {
    _posRegisterIncreaseStake(votes);
  }

}