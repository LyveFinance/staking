// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../Interfaces/IRewardDistributor.sol";
import "../Interfaces/IRewardTracker.sol";


import "./Governable.sol";

contract RewardTracker is IERC20, ReentrancyGuard, IRewardTracker, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;

    uint8 public constant decimals = 18;

    bool public isInitialized;

    string public name;
    string public symbol;

    address public distributor;
    mapping (address => bool) public isDepositToken;
    mapping (address => mapping (address => uint256)) public override depositBalances;

    uint256 public override totalSupply;
    mapping (address => uint256) public balances;
    mapping (address => mapping (address => uint256)) public allowances;

    mapping (uint256 => uint256) public cumulativeRewardPerToken;
    mapping (address => uint256) public override stakedAmounts;

    mapping (address => mapping(uint256 => uint256)) public claimableRewards;
    mapping (address => mapping(uint256 => uint256)) public previousCumulatedRewardPerToken;
    mapping (address => mapping(uint256 => uint256)) public cumulativeRewards;
    mapping (address => mapping(uint256 => uint256)) public averageStakedAmounts;

    mapping(address => uint256) public lastStakeTime;

    address public treasury;

    uint256 public feeRate1;
    uint256 public feeRate2;
    uint256 public feeRate3;
    uint256 public timeThreshold1;
    uint256 public timeThreshold2;
    uint256 public timeThreshold3;


    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping (address => bool) public isHandler;

    event Claim(address receiver,address _token, uint256 amount);

    constructor(string memory _name, string memory _symbol)  {
        name = _name;
        symbol = _symbol;
    }

    function initialize(
        address[] memory _depositTokens,
        address _distributor
    ) external onlyGov {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;

        for (uint256 i = 0; i < _depositTokens.length; i++) {
            address depositToken = _depositTokens[i];
            isDepositToken[depositToken] = true;
        }

        distributor = _distributor;
    }

    function setDepositToken(address _depositToken, bool _isDepositToken) external onlyGov {
        isDepositToken[_depositToken] = _isDepositToken;
    }
    function setTreasury(address _treasury) external onlyGov {
        treasury = _treasury;
    }

    function setInPrivateTransferMode(bool _inPrivateTransferMode) external onlyGov {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setInPrivateStakingMode(bool _inPrivateStakingMode) external onlyGov {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(bool _inPrivateClaimingMode) external onlyGov {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }
    function setFeeRatesAndThresholds(uint256 _feeRate1, uint256 _feeRate2, uint256 _feeRate3, uint256 _timeThreshold1, uint256 _timeThreshold2, uint256 _timeThreshold3) external onlyGov {
        feeRate1 = _feeRate1;
        feeRate2 = _feeRate2;
        feeRate3 = _feeRate3;
        timeThreshold1 = _timeThreshold1;
        timeThreshold2 = _timeThreshold2;
        timeThreshold3 = _timeThreshold3;
    }
    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        require(!isDepositToken[_token], "RewardTracker: _token cannot be a depositToken");
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function balanceOf(address _account) external view override returns (uint256) {
        return balances[_account];
    }

    function stake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) { revert("RewardTracker: action not enabled"); }
        _stake(msg.sender, msg.sender, _depositToken, _amount);
    }

    function stakeForAccount(address _fundingAccount, address _account, address _depositToken, uint256 _amount) external override nonReentrant {
        _validateHandler();
        _stake(_fundingAccount, _account, _depositToken, _amount);
    }

    function unstake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) { revert("RewardTracker: action not enabled"); }
        _unstake(msg.sender, _depositToken, _amount, msg.sender);
    }

    function unstakeForAccount(address _account, address _depositToken, uint256 _amount, address _receiver) external override nonReentrant {
        _validateHandler();
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function transfer(address _recipient, uint256 _amount) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender].sub(_amount, "RewardTracker: transfer amount exceeds allowance");
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function updateRewards() external override nonReentrant {
        _updateRewards(address(0));
    }

    function claim(address _receiver) external override nonReentrant returns (uint256[] memory) {
        if (inPrivateClaimingMode) { revert("RewardTracker: action not enabled"); }
        return _claim(msg.sender, _receiver);
    }

    function claimForAccount(address _account, address _receiver) external override nonReentrant returns (uint256[] memory) {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    function claimable(address _account) public override view returns (uint256[] memory) {
        uint256 stakedAmount = stakedAmounts[_account];
        IRewardDistributor.RewardInfo[] memory rewards = IRewardDistributor(distributor).viewRewards();
        uint256 supply = totalSupply;
        uint256[] memory pendingRewardsArray = IRewardDistributor(distributor).pendingRewards();
        uint256[] memory claimableRewardsArray = new uint256[](rewards.length);
        address userAccount = _account;
        for (uint256 i = 0; i < rewards.length; i++) {
            if(stakedAmount == 0 ){
                claimableRewardsArray[i] = claimableRewards[userAccount][i];
                continue;
            }
            uint256 pendingRewards = pendingRewardsArray[i].mul(PRECISION);
            uint256 nextCumulativeRewardPerToken = cumulativeRewardPerToken[i].add(pendingRewards.div(supply));
            claimableRewardsArray[i] = claimableRewards[userAccount][i].add(
                stakedAmount.mul(nextCumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[userAccount][i])).div(PRECISION)
            );
        }
        return claimableRewardsArray;
    }

    function rewardToken() public view returns (IRewardDistributor.RewardInfo[] memory) {
        return IRewardDistributor(distributor).viewRewards();
    }

    function _claim(address _account, address _receiver) private returns (uint256[] memory) {
        _updateRewards(_account);

        IRewardDistributor.RewardInfo[] memory rewards = IRewardDistributor(distributor).viewRewards();
        uint256[] memory tokenAmounts = new uint256[](rewards.length);
        for (uint256 i = 0; i < rewards.length; i++) {
            uint256 tokenAmount = claimableRewards[_account][i];
            claimableRewards[_account][i] = 0;

            if (tokenAmount > 0) {
                rewards[i].token.safeTransfer(_receiver, tokenAmount);
                tokenAmounts[i] = tokenAmount;
                emit Claim(_account, address(rewards[i].token), tokenAmount);
            }
        }

        return tokenAmounts;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: mint to the zero address");

        totalSupply = totalSupply.add(_amount);
        balances[_account] = balances[_account].add(_amount);

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: burn from the zero address");

        balances[_account] = balances[_account].sub(_amount, "RewardTracker: burn amount exceeds balance");
        totalSupply = totalSupply.sub(_amount);

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(_sender != address(0), "RewardTracker: transfer from the zero address");
        require(_recipient != address(0), "RewardTracker: transfer to the zero address");

        if (inPrivateTransferMode) { _validateHandler(); }

        balances[_sender] = balances[_sender].sub(_amount, "RewardTracker: transfer amount exceeds balance");
        balances[_recipient] = balances[_recipient].add(_amount);

        emit Transfer(_sender, _recipient,_amount);
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        require(_owner != address(0), "RewardTracker: approve from the zero address");
        require(_spender != address(0), "RewardTracker: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "RewardTracker: forbidden");
    }

    function _stake(address _fundingAccount, address _account, address _depositToken, uint256 _amount) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");

        IERC20(_depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        _updateRewards(_account);
    
        stakedAmounts[_account] = stakedAmounts[_account].add(_amount);
        depositBalances[_account][_depositToken] = depositBalances[_account][_depositToken].add(_amount);
        lastStakeTime[_account] = block.timestamp;
        _mint(_account, _amount);
    }
    
    function _unstake(address _account, address _depositToken, uint256 _amount, address _receiver) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");

        _updateRewards(_account);

        uint256 stakedAmount = stakedAmounts[_account];
        require(stakedAmounts[_account] >= _amount, "RewardTracker: _amount exceeds stakedAmount");

        stakedAmounts[_account] = stakedAmount.sub(_amount);

        uint256 depositBalance = depositBalances[_account][_depositToken];
        require(depositBalance >= _amount, "RewardTracker: _amount exceeds depositBalance");
        depositBalances[_account][_depositToken] = depositBalance.sub(_amount);

        uint256 fee = _fee(_account,_amount);
        uint256 amountAfterFee = _amount.sub(fee);

        _burn(_account, _amount);

        if (fee > 0) {
            IERC20(_depositToken).safeTransfer(treasury, fee);
        }
        IERC20(_depositToken).safeTransfer(_receiver, amountAfterFee);
    }

    function _fee(address _account,uint256 _amount) private view returns(uint256){
        uint256 fee = 0;
        uint256 timeStaked = block.timestamp.sub(lastStakeTime[_account]);
        if (timeStaked <= timeThreshold1) {
            fee = _amount.mul(feeRate1).div(10000);
        } else if (timeStaked <= timeThreshold2) {
            fee = _amount.mul(feeRate2).div(10000);
        } else if (timeStaked <= timeThreshold3) {
            fee = _amount.mul(feeRate3).div(10000);
        }
        return fee;
    }

    function _updateRewards(address _account) private {
  
        uint256[] memory blockRewards = IRewardDistributor(distributor).distribute();
         address userAccount = _account;
        for (uint256 i = 0; i < blockRewards.length; i++) {
            uint256 blockReward = blockRewards[i];
         
            uint256 _cumulativeRewardPerToken = cumulativeRewardPerToken[i];
            
            uint256 supply = totalSupply; 

            if (supply > 0 && blockReward > 0) {
                _cumulativeRewardPerToken = _cumulativeRewardPerToken.add(blockReward.mul(PRECISION).div(supply));
                cumulativeRewardPerToken[i] = _cumulativeRewardPerToken;
            }
            // cumulativeRewardPerToken can only increase
            // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
            if (_cumulativeRewardPerToken == 0) {
                continue;
            }
            if (_account != address(0)) {
                uint256 stakedAmount = stakedAmounts[userAccount];

                uint256 accountReward = stakedAmount.mul(_cumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[userAccount][i])).div(PRECISION);

                uint256 _claimableReward = claimableRewards[userAccount][i].add(accountReward);
                claimableRewards[userAccount][i] = _claimableReward;
                previousCumulatedRewardPerToken[userAccount][i] = _cumulativeRewardPerToken;

            if (_claimableReward > 0 && stakedAmounts[userAccount] > 0) {
                    uint256 nextCumulativeReward = cumulativeRewards[userAccount][i].add(accountReward);
                    uint256 _averageStakedAmountsI = averageStakedAmounts[userAccount][i];
                    uint256 _cumulativeRewardsI = cumulativeRewards[userAccount][i];
                    averageStakedAmounts[userAccount][i] = _averageStakedAmountsI.mul(_cumulativeRewardsI).div(nextCumulativeReward)
                        .add(stakedAmount.mul(accountReward).div(nextCumulativeReward));
                    cumulativeRewards[userAccount][i] = nextCumulativeReward;
                }
            }
        }
    }
}
