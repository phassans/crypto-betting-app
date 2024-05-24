// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Betting is OwnerIsCreator {

    struct BetInfo {
        uint256 id;
        address userA;
        address userB;
        uint256 amount;
        address winner;
        uint256 reward;
        bool isLong; // true: long, false: short
        uint256 createTime;
        uint256 expireTime;
        uint256 closingTime;
        uint256 openingPrice;
        uint256 closingPrice;
        uint256 betStatus; // 0: pending, 1: active, 2: closed, 3: user has withdrawn funds
    }

    // priceFeed & tokens
    AggregatorV3Interface private priceFeedAddress;
    IERC20 private USDCTokenAddress;

    // bot & fee
    address private botAddress;
    uint256 private botFeeBasisPoints;

    // user allowance
    mapping(address => bool) userAllowed;

    // betting Info
    BetInfo[] private s_betInfos;
    mapping(address => uint256[]) private s_betIdsForUser;
    uint256[] private s_pendingBetIDs;
    uint256[] private s_activeBetIDs;
    uint256 public betCount;

    // events
    event BetActived(uint256 betID, address indexed userB, uint256 openingPrice);
    event NewBetCreated(uint256 betID, address indexed userA, uint256 amount, bool isLong, uint256 createTime, uint256 expireTime, uint256 closingTime);
    event BetClosed(uint256 betID, bool isCancel, uint256 closingPrice, uint256 winnerReward, uint256 feeAmount);
    event RewardWithdrawal(uint256 betID, address indexed winner, uint256 amount);
    event BetRefunded(uint256 indexed betId, address userA, uint256 amount);


    constructor(
        address _usdc,
        address _priceFeed,
        address _botAddress,
        uint256 _botFeeBasisPoints
    ) {
        USDCTokenAddress = IERC20(_usdc);
        priceFeedAddress = AggregatorV3Interface(_priceFeed);
        botAddress = _botAddress;
        botFeeBasisPoints = _botFeeBasisPoints;
    }

    receive() external payable {}

    function createBet(bool isLong, uint256 _usdcAmount, uint256 _expireTime, uint256 _closingTime) public payable returns (uint256) {
        require(userAllowed[msg.sender], "Invalid request: You are not registered!");
        require(USDCTokenAddress.balanceOf(msg.sender) >= _usdcAmount, "Invalid request: Insufficient USDC balance for deposit!");
        require(_expireTime > block.timestamp, "Invalid request: Expiration time must be after now!");
        require(_closingTime > _expireTime, "Invalid request: Closing time must be later than expiration time!");

        USDCTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

        BetInfo memory newBet;
        newBet.id = betCount;
        newBet.userA = msg.sender;
        newBet.amount = _usdcAmount;
        newBet.createTime = block.timestamp;
        newBet.isLong = isLong;
        newBet.expireTime = _expireTime;
        newBet.closingTime = _closingTime;
        newBet.betStatus = 0; // pending

        s_betInfos.push(newBet);
        s_betIdsForUser[msg.sender].push(betCount);
        s_pendingBetIDs.push(betCount);

        emit NewBetCreated(betCount, msg.sender, _usdcAmount, isLong, newBet.createTime, _expireTime, _closingTime);
        return betCount++;
    }

    function joinBet(uint256 _betID, uint256 _usdcAmount) public payable returns (uint256) {
        require(userAllowed[msg.sender], "Invalid request: You are not registered!");
        require(_betID < betCount, "Invalid request: Betting ID is invalid!");
        require(s_betInfos[_betID].betStatus == 0 && s_betInfos[_betID].expireTime >= block.timestamp, "Invalid request: The Bet is closed!");
        require(s_betInfos[_betID].amount == _usdcAmount, "Invalid request: You must deposit the same amount of USDC as the creator!");
        require(USDCTokenAddress.balanceOf(msg.sender) >= _usdcAmount, "Invalid request: Insufficient USDC balance for deposit!");

        USDCTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

        s_betInfos[_betID].userB = msg.sender;
        s_betInfos[_betID].openingPrice = getBTCPrice();
        s_betInfos[_betID].betStatus = 1; // active

        s_betIdsForUser[msg.sender].push(_betID);
        s_activeBetIDs.push(_betID);
        for (uint i = 0; i <= s_pendingBetIDs.length; i++) {
            if (s_pendingBetIDs[i] == _betID) {
                s_pendingBetIDs.pop();
                break;
            }
        }

        emit BetActived(_betID, msg.sender, s_betInfos[_betID].openingPrice);
        return s_betInfos[_betID].openingPrice;
    }

    function resolveBet(uint256 _betID) external onlyBot {
        require(msg.sender == botAddress, "Permission Error: You are not allowed to close a betting!");
        require(_betID < betCount, "Invalid request: Betting ID is invalid!");
        require(s_betInfos[_betID].betStatus == 1, "Invalid request: Bet is not active");
        require(s_betInfos[_betID].closingTime <= block.timestamp, "Invalid request: Closing time has not arrived!");

        s_betInfos[_betID].closingPrice = getBTCPrice();

        if (s_betInfos[_betID].isLong) {
            s_betInfos[_betID].winner = (s_betInfos[_betID].openingPrice < s_betInfos[_betID].closingPrice) ? s_betInfos[_betID].userA : s_betInfos[_betID].userB;
        } else {
            s_betInfos[_betID].winner = (s_betInfos[_betID].openingPrice > s_betInfos[_betID].closingPrice) ? s_betInfos[_betID].userA : s_betInfos[_betID].userB;
        }

        uint256 totalAmount = s_betInfos[_betID].amount * 2;
        uint256 botFee = (totalAmount * botFeeBasisPoints) / 10000;
        s_betInfos[_betID].reward = totalAmount - botFee;

        require(USDCTokenAddress.balanceOf(address(this)) >= botFee, "Error: Insufficient USDC balance!");
        USDCTokenAddress.transfer(botAddress, botFee);

        emit BetClosed(_betID, false, s_betInfos[_betID].closingPrice, s_betInfos[_betID].reward, botFee);

        s_betInfos[_betID].betStatus = 2;
    }



    function withdraw(uint256 _betID) external {
        require(_betID < betCount, "Invalid request: Betting ID is invalid!");
        require(msg.sender == s_betInfos[_betID].winner, "Invalid request: Only winner can withdraw!");
        require(s_betInfos[_betID].betStatus != 3, "Invalid request: You already have withdrawn funds!");
        require(s_betInfos[_betID].betStatus == 2, "Invalid request: Bet is not closed!");

        require(USDCTokenAddress.balanceOf(address(this)) >= s_betInfos[_betID].reward, "Error: Insufficient USDC balance!");
        USDCTokenAddress.transfer(msg.sender, s_betInfos[_betID].reward);

        s_betInfos[_betID].betStatus = 3;

        emit RewardWithdrawal(_betID, msg.sender, s_betInfos[_betID].reward);
    }

    function refundBet(uint256 betId) external {
        BetInfo storage bet = s_betInfos[betId];
        require(s_betInfos[betId].betStatus == 0, "Invalid request: Bet is not in pending state");
        require(block.timestamp > bet.expireTime, "Invalid request: Bet expiration time has not yet been reached");
        require(bet.userA == msg.sender, "Invalid request: Only the bet creator can request a refund");

        USDCTokenAddress.transfer(bet.userA, bet.amount);

        delete s_betInfos[betId];

        emit BetRefunded(betId, bet.userA, bet.amount);
    }

    function allowUser(address _userAddress, bool _isAllowed) public {
        require(_userAddress != address(0), "Invalid address!");
        userAllowed[_userAddress] = _isAllowed;
    }

    function getBTCPrice() public view returns (uint256) {
        (, int256 price,,,) = priceFeedAddress.latestRoundData();
        return uint256(price);
    }

    function getBetIdsForUser(address _userAddress) public view returns (uint256[] memory) {
        return s_betIdsForUser[_userAddress];
    }

    function getBetInfo(uint256 _betID) public view returns (BetInfo memory) {
        require(_betID < betCount, "Invalid request: Betting ID is invalid!");
        return s_betInfos[_betID];
    }

    function getPendingBetIDs() public view returns (uint256[] memory) {
        return s_pendingBetIDs;
    }

    function getActiveBetIDs() public view returns (uint256[] memory) {
        return s_activeBetIDs;
    }

    function setPriceFeedAddress(address _feedAddress) external onlyOwner {
        priceFeedAddress = AggregatorV3Interface(_feedAddress);
    }

    function getPriceFeedAddress() external view returns (address) {
        return address(priceFeedAddress);
    }

    function setUSDCAddress(address _usdcAddress) external onlyOwner {
        USDCTokenAddress = IERC20(_usdcAddress);
    }

    function getUSDCAddress() external view returns (address) {
        return address(USDCTokenAddress);
    }

    function setBotAddress(address _botAddress) external onlyOwner {
        botAddress = _botAddress;
    }

    function getBotAddress() external view returns (address) {
        return botAddress;
    }

    function setBotFeeBasisPoints(uint256 _botFeeBasisPoints) external onlyOwner {
        botFeeBasisPoints = _botFeeBasisPoints;
    }

    function getBotFeeBasisPoints() external view returns (uint256) {
        return botFeeBasisPoints;
    }

    modifier onlyBot() {
        require(msg.sender == botAddress, "Caller is not the bot");
        _;
    }
}