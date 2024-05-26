// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Betting is OwnerIsCreator {

    error InvalidRequest(address user, string reason);
    error InsufficientBalance(address user, uint256 requiredBalance);
    error AmountMismatchError(address user, uint256 providedAmount, uint256 requiredAmount);
    error BetClosedError(address user, uint256 providedBetID, uint256 betStatus, 
        uint256 expireTime, uint256 currentTime);
    error InvalidBetID(address user, uint256 providedBetID, uint256 betCount);

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
        uint256 betStatus; // 0: pending, 1: active, 2: closed, 3: user has withdrawn funds 4: cancelled
    }

    // priceFeed & tokens
    AggregatorV3Interface private priceFeedAddress;
    IERC20 private usdcTokenAddress;

    // bot & fee
    address private botAddress;
    uint256 private botFeeBasisPoints;

    // user allowance
    mapping(address => bool) public userAllowed;

    // betting Info
    BetInfo[] private betInfos;
    mapping(address => uint256[]) private betIdsForUser;
    uint256[] private pendingBetIDs;
    uint256[] private activeBetIDs;
    uint256 public betCount;

    // events
    event BetCreated(uint256 betID, address indexed userA, uint256 amount, bool isLong, uint256 createTime, 
        uint256 expireTime, uint256 closingTime);
    event BetActive(uint256 betID, address indexed userB, uint256 openingPrice);
    event BetClosed(uint256 betID, address indexed winner, uint256 closingPrice, 
        uint256 winnerReward, uint256 feeAmount);
    event BetRewardWithdrawal(uint256 betID, address indexed winner, uint256 amount);
    event BetRefunded(uint256 indexed betId, address userA, uint256 amount);

    constructor(
        address _usdc,
        address _priceFeed,
        address _botAddress,
        uint256 _botFeeBasisPoints
    ) {
        usdcTokenAddress = IERC20(_usdc);
        priceFeedAddress = AggregatorV3Interface(_priceFeed);
        botAddress = _botAddress;
        botFeeBasisPoints = _botFeeBasisPoints;
    }

    receive() external payable {}

    function createBet(bool isLong, uint256 _usdcAmount, uint256 _expireTime, uint256 _closingTime) public payable 
        onlyRegistered hasSufficientBalance(_usdcAmount) returns (uint256)  {
        require(_expireTime > block.timestamp, "Invalid request: Expiration time must be after now!");
        require(_closingTime > _expireTime, "Invalid request: Closing time must be later than expiration time");

        usdcTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

        BetInfo memory newBet;
        newBet.id = betCount;
        newBet.userA = msg.sender;
        newBet.amount = _usdcAmount;
        newBet.createTime = block.timestamp;
        newBet.isLong = isLong;
        newBet.expireTime = _expireTime;
        newBet.closingTime = _closingTime;
        newBet.betStatus = 0; // pending

        betInfos.push(newBet);
        betIdsForUser[msg.sender].push(betCount);
        pendingBetIDs.push(betCount);

        emit BetCreated(betCount, msg.sender, _usdcAmount, isLong, newBet.createTime, _expireTime, _closingTime);
        return betCount++;
    }

    function joinBet(uint256 _betID, uint256 _usdcAmount) public payable 
        onlyRegistered hasSufficientBalance(_usdcAmount) validBetID(_betID) returns (uint256) {
        require(betInfos[_betID].betStatus == 0 && 
            betInfos[_betID].expireTime >= block.timestamp, "Invalid request: The Bet is closed!");
        
        if (betInfos[_betID].amount != _usdcAmount) 
            revert AmountMismatchError(msg.sender, _usdcAmount, betInfos[_betID].amount);

        usdcTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

        betInfos[_betID].userB = msg.sender;
        betInfos[_betID].openingPrice = getBTCPrice();
        betInfos[_betID].betStatus = 1; // active

        betIdsForUser[msg.sender].push(_betID);
        activeBetIDs.push(_betID);
        for (uint i = 0; i <= pendingBetIDs.length; i++) {
            if (pendingBetIDs[i] == _betID) {
                pendingBetIDs.pop();
                break;
            }
        }

        emit BetActive(_betID, msg.sender, betInfos[_betID].openingPrice);
        return betInfos[_betID].openingPrice;
    }

    function resolveBet(uint256 _betID) external onlyBot validBetID(_betID) {
        require(msg.sender == botAddress, "Permission Error: You are not allowed to close a betting!");
        require(betInfos[_betID].betStatus == 1, "Invalid request: Bet is not active");
        require(betInfos[_betID].closingTime <= block.timestamp, "Invalid request: Closing time has not arrived!");

        betInfos[_betID].closingPrice = getBTCPrice();

        if (betInfos[_betID].isLong) {
            betInfos[_betID].winner = (betInfos[_betID].openingPrice < betInfos[_betID].closingPrice) ? 
                betInfos[_betID].userA : betInfos[_betID].userB;
        } else {
            betInfos[_betID].winner = (betInfos[_betID].openingPrice > betInfos[_betID].closingPrice) ? 
                betInfos[_betID].userA : betInfos[_betID].userB;
        }

        uint256 totalAmount = betInfos[_betID].amount * 2;
        uint256 botFee = (totalAmount * botFeeBasisPoints) / 10000;
        betInfos[_betID].reward = totalAmount - botFee;

        require(usdcTokenAddress.balanceOf(address(this)) >= botFee, "Error: Insufficient USDC balance!");

        betInfos[_betID].betStatus = 2;
        usdcTokenAddress.transfer(botAddress, botFee);

        emit BetClosed(_betID, betInfos[_betID].winner, betInfos[_betID].closingPrice, betInfos[_betID].reward, botFee);
    }



    function withdraw(uint256 _betID) external validBetID(_betID) {
        require(msg.sender == betInfos[_betID].winner, "Invalid request: Only winner can withdraw!");
        require(betInfos[_betID].betStatus != 3, "Invalid request: You already have withdrawn funds!");
        require(betInfos[_betID].betStatus == 2, "Invalid request: Bet is not closed!");

        require(usdcTokenAddress.balanceOf(address(this)) >= betInfos[_betID].reward, 
            "Error: Insufficient USDC balance!");

        betInfos[_betID].betStatus = 3;
        usdcTokenAddress.transfer(msg.sender, betInfos[_betID].reward);

        emit BetRewardWithdrawal(_betID, msg.sender, betInfos[_betID].reward);
    }

    function refundBet(uint256 _betID) external validBetID(_betID) {
        BetInfo storage bet = betInfos[_betID];
        require(betInfos[_betID].betStatus == 0, "Invalid request: Bet is not in pending state");
        require(block.timestamp > bet.expireTime, "Invalid request: Bet expiration time has not yet been reached");
        require(bet.userA == msg.sender, "Invalid request: Only the bet creator can request a refund");

        usdcTokenAddress.transfer(bet.userA, bet.amount);

        delete betInfos[_betID];
        emit BetRefunded(_betID, bet.userA, bet.amount);
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
        return betIdsForUser[_userAddress];
    }

    function getBetInfo(uint256 _betID) public view returns (BetInfo memory) {
        require(_betID < betCount, "Invalid request: Betting ID is invalid!");
        return betInfos[_betID];
    }

    function getPendingBetIDs() public view returns (uint256[] memory) {
        return pendingBetIDs;
    }

    function getActiveBetIDs() public view returns (uint256[] memory) {
        return activeBetIDs;
    }

    function setPriceFeedAddress(address _feedAddress) external onlyOwner {
        priceFeedAddress = AggregatorV3Interface(_feedAddress);
    }

    function getPriceFeedAddress() external view returns (address) {
        return address(priceFeedAddress);
    }

    function setUSDCAddress(address _usdcAddress) external onlyOwner {
        usdcTokenAddress = IERC20(_usdcAddress);
    }

    function getUSDCAddress() external view returns (address) {
        return address(usdcTokenAddress);
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

    // check if the user is Bot
    modifier onlyBot() {
        require(msg.sender == botAddress, "Caller is not the bot");
        _;
    }

    // check if the user is registered
    modifier onlyRegistered() {
        if (!userAllowed[msg.sender]) {
            revert InvalidRequest(msg.sender, "You are not registered!");
        }
        _;
    }

    // check if the user has sufficient USDC balance
    modifier hasSufficientBalance(uint256 _usdcAmount) {
        uint256 balance = usdcTokenAddress.balanceOf(msg.sender);
        if (balance < _usdcAmount) {
            revert InsufficientBalance(msg.sender, _usdcAmount);
        }
        _;
    }

    // check if the bet ID is valid
    modifier validBetID(uint256 _betID) {
        if (_betID >= betCount) {
            revert InvalidBetID(msg.sender, _betID, betCount);
        }
        _;
    }
}