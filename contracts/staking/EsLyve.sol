// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


interface IRouter {

    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
}
interface IVotingEscrow {
    function create_lock_for(uint _value, uint _lock_duration, address _to) external returns (uint);
}
interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
    function balanceOf(address) external returns (uint256);

}

contract EsLyve is ERC20,ReentrancyGuard,Ownable{
    using SafeMath for uint256;

    IERC20 public immutable LYVE;

    address public  router;

    IVotingEscrow public  ve;

    IWETH public  WETH;
    
    address public  treasury;

    address public stakingValut;

    uint internal constant MAXTIME =  2 * 365 * 86400;

    uint internal constant MAX_DURATION =  6 * 30 days;

    uint internal constant MIN_EXIT_RATIO =  60 ; //60%
    uint internal constant MAX_EXIT_RATIO =  100 ; //60%

    uint256 public exitRatio = 70; // 70%

    uint256 public toTreasury = 50; // 50%

    uint256 public vestingDuration = 30 days; 


    event Deposited(address indexed beneficiary, uint256 amount);
    event StartedVesting(address indexed account, uint256 amount);
    event ClaimedVested(address indexed account, uint256 amount);
    event ImmediateConversion(address indexed account, uint256 amount);


    struct Vesting {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 lockedAmount;
        uint256 startTime;
    }

   // mapping(address => Vesting) public vestings;
    mapping(address =>  Vesting) public vestings;

    constructor(address _lyve,address _weth,address _treasury) ERC20("esLYVE","esLYVE") {
        LYVE = IERC20(_lyve);
        WETH = IWETH(_weth);
        treasury = _treasury;
    }

    function setStakingValut(address _stakingValut) external onlyOwner {
        stakingValut = _stakingValut;
    }
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
    
    function deposit(uint256 amount, address account)  external nonReentrant{
        require(LYVE.transferFrom(msg.sender, address(this), amount), "Transfer failed");
         _mint(account, amount); 
        emit Deposited(account, amount);
    }

    function setRouter( address _router)  external onlyOwner{
        router = _router;
    }
    
    function setVe( address _ve)  external onlyOwner{
        ve = IVotingEscrow(_ve);
    }
    function setDuration( uint256 _vestingDuration)  external onlyOwner{
        require(_vestingDuration <= MAX_DURATION, "duration exceeds maximum limit");
        vestingDuration = _vestingDuration;
    }

    function setExitRatio( uint256 _exitRatio)  external onlyOwner{
        require(_exitRatio >= MIN_EXIT_RATIO, "exitRatio ERROR");
        require(_exitRatio <= MAX_EXIT_RATIO, "exitRatio ERROR");
        exitRatio = _exitRatio;
    }
     function setTreasuryRatio( uint256 _treasuryRatio)  external onlyOwner{
        toTreasury = _treasuryRatio;
    }    
    
    function calculateClaimable(address account) external view returns (uint256) {
        Vesting memory v = vestings[account];
        if(v.startTime == 0){
            return 0;
        }
        return _calculateClaimable(v);
    }
    function _calculateClaimable(Vesting memory v) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp.sub(v.startTime);
        uint256 claimable;
        if (timeElapsed >= vestingDuration) {
            claimable = v.totalAmount.sub(v.claimedAmount);
        } else {
            claimable = v.totalAmount.mul(timeElapsed).div(vestingDuration).sub(v.claimedAmount);
        }
    
        return claimable; 
    }

    function startVesting(uint256 amount) external nonReentrant {
        require(amount > 0,"error amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient esLyve balance");
        require(LYVE.balanceOf(msg.sender) >= amount, "Insufficient LYVE balance"); 
        LYVE.transferFrom(msg.sender, address(this), amount);

        _burn(msg.sender, amount);

        Vesting storage v = vestings[msg.sender];
         v.totalAmount = v.totalAmount.add(amount).add(amount);
         v.lockedAmount = v.lockedAmount.add(amount).add(amount);
         v.startTime = block.timestamp;
        emit StartedVesting(msg.sender, amount);    
    }

    function claimVested() external nonReentrant {
        Vesting storage v = vestings[msg.sender];
        require(block.timestamp > v.startTime, "Vesting not started");
        uint256 claimable = _calculateClaimable(v);
        require(claimable > 0,"nothing to claim");
        v.claimedAmount = v.claimedAmount.add(claimable);
        
        require(LYVE.transfer(msg.sender, claimable), "Transfer failed");

        emit ClaimedVested(msg.sender, claimable);
    }

    
    function immediateConversion(uint256 amount,uint splige) public nonReentrant payable {
        require(balanceOf(msg.sender) >= amount, "Insufficient esLyve balance");
        require(balanceOf(address(this)) >= amount,"Insufficient lyve balance");

        uint wethAmount = quotePayment(amount);

        require(wethAmount > 0,"error ETH");

        require(msg.value >= wethAmount,"Insufficient ETH");
        uint rate = (msg.value - wethAmount ) *10000/ wethAmount;
        require(rate <= splige,"splige error");

        _burn(msg.sender,amount);

        WETH.deposit{value: wethAmount}();

        uint treasuryWeth = toTreasury * wethAmount/100;

        if(stakingValut == address(0)){
             treasuryWeth = wethAmount;
        }
        if(treasuryWeth > 0){
            assert(WETH.transfer(treasury, treasuryWeth));
        }
        uint stakingVaultWeth = wethAmount - treasuryWeth;

        if(stakingVaultWeth > 0 ){
            assert(WETH.transfer(stakingValut, stakingVaultWeth));
        }

        require(LYVE.transfer(msg.sender, amount), "Transfer failed");

        emit ImmediateConversion(msg.sender,amount);
    }

    function quotePayment(uint256 amount) public view returns(uint) {
      uint256 lyveAmount = amount * (100 - exitRatio) / 100;
     (uint amountout, ) = IRouter(router).getAmountOut(lyveAmount, address(LYVE),  address(WETH)) ;
     return amountout;
    }

    function lockedVe(uint _value, address _to) external nonReentrant returns (uint) {
        require(balanceOf(msg.sender) >= _value, "Insufficient xCOFFEE balance");
        _burn(msg.sender,_value) ;
        LYVE.approve(address(ve), _value);
        return ve.create_lock_for(_value, MAXTIME, _to);
    }
    function withdrawETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(address(this).balance >= amount, "Insufficient balance");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }
    function withdrawWETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(WETH.balanceOf(address(this)) >= amount, "Insufficient WETH balance");
        WETH.withdraw(amount);
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }


}