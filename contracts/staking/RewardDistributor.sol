// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../Interfaces/IRewardDistributor.sol";
import "../Interfaces/IRewardTracker.sol";
import "./Governable.sol";

contract RewardDistributor is IRewardDistributor, ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    RewardInfo[] public rewards;

    mapping(address => uint256) public rewardTokensIndex;

    mapping(address => bool) public isTokenAdded;

    address public rewardTracker;

    address public admin;

    event Distribute(address _token,uint256 amount);
    event TokensPerIntervalChange(address _token,uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "RewardDistributor: forbidden");
        _;
    }

    constructor( address _rewardTracker) {
        rewardTracker = _rewardTracker;
        admin = msg.sender;
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
    }
    function setRewardTracker(address _rewardTracker) external onlyGov {
        rewardTracker = _rewardTracker;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function addRewardToken(IERC20 _token) external onlyAdmin{
    require(!isTokenAdded[address(_token)], "RewardDistributor: token already added");
        rewards.push(RewardInfo({
            token: _token,
            lastDistributionTime: block.timestamp
        }));
        rewardTokensIndex[address(_token)] = rewards.length - 1;
        isTokenAdded[address(_token)] = true;
    }

    // 
    function updateLastDistributionTime(address _token) external onlyAdmin {
        require(isTokenAdded[_token], "RewardDistributor: token not added");
        uint256 index = rewardTokensIndex[_token];
        require(index < rewards.length, "Token not found");
        rewards[index].lastDistributionTime = block.timestamp;
    }
    

    function pendingRewards() public view override returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](rewards.length);
        for (uint256 i = 0; i < rewards.length; i++) {
            amounts[i] = rewards[i].token.balanceOf(address(this));
        }
        return amounts;
    }

    function distribute() external override returns (uint256[] memory) {
        require(msg.sender == rewardTracker, "RewardDistributor: invalid msg.sender");
        uint256[] memory amounts = pendingRewards();
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] > 0) {
                rewards[i].lastDistributionTime = block.timestamp;

                uint256 balance = rewards[i].token.balanceOf(address(this));
                if (amounts[i] > balance) {
                    amounts[i] = balance;
                }

                if (amounts[i] > 0) {
                    rewards[i].token.safeTransfer(msg.sender, amounts[i]);
                    emit Distribute(address(rewards[i].token), amounts[i]);
                }
            }
        }
        return amounts;
    }
     function viewRewards() public view override returns (RewardInfo[] memory) {
        return rewards;
    }

}
