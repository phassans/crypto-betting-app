// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import necessary interfaces from Chainlink and OpenZeppelin
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Betting is OwnerIsCreator {

    // Define custom errors
    error InvalidRequest(address user, string reason);
    error InsufficientBalance(address user, uint256 requiredBalance);
    error AmountMismatchError(address user, uint256 providedAmount, uint256 requiredAmount);
    error BetClosedError(address user, uint256 providedBetID, uint256 betStatus, 
        uint256 expireTime, uint256 currentTime);
    error InvalidBetID(address user, uint256 providedBetID, uint256 betCount);

    // Structure to store bet information
    struct BetInfo {
        uint256 id;                 // Unique identifier for the bet
        address userA;              // Address of the user who created the bet
        address userB;              // Address of the user who joined the bet
        uint256 amount;             // Amount of USDC wagered
        address winner;             // Address of the winner
        uint256 reward;             // Reward amount for the winner
        bool isLong;                // True if the bet is long, false if short
        uint256 createTime;         // Timestamp when the bet was created
        uint256 expireTime;         // Timestamp when the bet expires
        uint256 closingTime;        // Timestamp when the bet closes
        uint256 openingPrice;       // Opening price of the asset at the start of the bet
        uint256 closingPrice;       // Closing price of the asset at the end of the bet
        uint256 betStatus;          // Status of the bet: 0 - pending, 1 - active, 2 - closed, 3 - withdrawn, 4 - cancelled
    }

    // State variables
    AggregatorV3Interface private priceFeedAddress;    // Address of the Chainlink price feed
    IERC20 private usdcTokenAddress;                    // Address of the USDC token contract
    address private botAddress;                         // Address of the bot managing bets
    uint256 private botFeeBasisPoints;                  // Fee basis points for the bot

    // Mappings and arrays to manage user allowances and bets
    mapping(address => bool) public userAllowed;        // Mapping to check if a user is allowed to bet
    BetInfo[] private betInfos;                         // Array to store all bet information
    mapping(address => uint256[]) private betIdsForUser;// Mapping of user addresses to their bet IDs
    uint256[] private pendingBetIDs;                    // Array of pending bet IDs
    uint256[] private activeBetIDs;                     // Array of active bet IDs
    uint256 public betCount;                            // Total count of bets

    // Events to log important actions
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

    /**
        * @dev Creates a new bet with the specified amount, expiration time, and type (long/short).
        * @param isLong True if the bet is long, false if it is short.
        * @param _usdcAmount The amount of USDC to bet.
        * @param _expireTime The expiration time for the bet (in Unix timestamp).
        * @param _closingTime The closing time for the bet (in Unix timestamp).
        * @return betID The ID of the newly created bet.
    */
    function createBet(bool isLong, uint256 _usdcAmount, uint256 _expireTime, uint256 _closingTime) public payable 
        onlyRegistered hasSufficientBalance(_usdcAmount) returns (uint256)  {
        require(_expireTime > block.timestamp, "Invalid request: Expiration time must be after now!");
        require(_closingTime > _expireTime, "Invalid request: Closing time must be later than expiration time");

        usdcTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

        // Create a new BetInfo struct with the provided details and default values for others
        BetInfo memory newBet;
        newBet.id = betCount;
        newBet.userA = msg.sender;
        newBet.amount = _usdcAmount;
        newBet.createTime = block.timestamp;
        newBet.isLong = isLong;
        newBet.expireTime = _expireTime;
        newBet.closingTime = _closingTime;
        newBet.betStatus = 0; // pending

        // Add the new bet to the array of all bets
        betInfos.push(newBet);

        // Map the new bet ID to the user's address
        betIdsForUser[msg.sender].push(betCount);

        // Add the new bet ID to the array of pending bets
        pendingBetIDs.push(betCount);

        // Emit an event to log the creation of the new bet
        emit BetCreated(betCount, msg.sender, _usdcAmount, isLong, newBet.createTime, _expireTime, _closingTime);
        return betCount++;
    }

    /**
        * @dev Allows a user to join an existing bet with the specified bet ID and amount.
        * @param _betID The ID of the bet to join.
        * @param _usdcAmount The amount of USDC to bet.
        * @return The opening price of the asset at the time the bet is joined.
    */
    function joinBet(uint256 _betID, uint256 _usdcAmount) public payable 
        onlyRegistered hasSufficientBalance(_usdcAmount) validBetID(_betID) returns (uint256) {
        
        // Ensure the bet is still open and has not expired
        require(betInfos[_betID].betStatus == 0 && 
            betInfos[_betID].expireTime >= block.timestamp, "Invalid request: The Bet is closed!");
        
        // Ensure the amount matches the bet's required amount
        if (betInfos[_betID].amount != _usdcAmount) 
            revert AmountMismatchError(msg.sender, _usdcAmount, betInfos[_betID].amount);

        // Transfer USDC from the user to the contract
        usdcTokenAddress.transferFrom(msg.sender, address(this), _usdcAmount);

         // Update bet information with the joining user's details
        betInfos[_betID].userB = msg.sender;
        betInfos[_betID].openingPrice = getBTCPrice();
        betInfos[_betID].betStatus = 1; // active

        // Add the bet ID to the user's list of bets and the active bets array
        betIdsForUser[msg.sender].push(_betID);
        activeBetIDs.push(_betID);

        // Remove the bet ID from the pending bets array
        for (uint i = 0; i <= pendingBetIDs.length; i++) {
            if (pendingBetIDs[i] == _betID) {
                pendingBetIDs.pop();
                break;
            }
        }

        // Emit an event to log the activation of the bet
        emit BetActive(_betID, msg.sender, betInfos[_betID].openingPrice);
        return betInfos[_betID].openingPrice;
    }

    /**
        * @dev Resolves a bet by determining the winner based on the closing price.
        * @param _betID The ID of the bet to resolve.
    */
    function resolveBet(uint256 _betID) external onlyBot validBetID(_betID) {
        require(msg.sender == botAddress, "Permission Error: You are not allowed to close a betting!");
        require(betInfos[_betID].betStatus == 1, "Invalid request: Bet is not active");
        require(betInfos[_betID].closingTime <= block.timestamp, "Invalid request: Closing time has not arrived!");

        // Fetch the closing price of the asset
        betInfos[_betID].closingPrice = getBTCPrice();

        // Determine the winner based on the bet type (long/short) and price movement
        if (betInfos[_betID].isLong) {
            betInfos[_betID].winner = (betInfos[_betID].openingPrice < betInfos[_betID].closingPrice) ? 
                betInfos[_betID].userA : betInfos[_betID].userB;
        } else {
            betInfos[_betID].winner = (betInfos[_betID].openingPrice > betInfos[_betID].closingPrice) ? 
                betInfos[_betID].userA : betInfos[_betID].userB;
        }

        // Calculate the reward amount for the winner and botfee
        uint256 totalAmount = betInfos[_betID].amount * 2;
        uint256 botFee = (totalAmount * botFeeBasisPoints) / 10000;
        betInfos[_betID].reward = totalAmount - botFee;

        require(usdcTokenAddress.balanceOf(address(this)) >= botFee, "Error: Insufficient USDC balance!");

        // Update the bet status to closed
        betInfos[_betID].betStatus = 2;

        // Transfer USDC from the contract to the botFeeAddress
        usdcTokenAddress.transfer(botAddress, botFee);

        // Emit an event to log the resolution of the bet
        emit BetClosed(_betID, betInfos[_betID].winner, betInfos[_betID].closingPrice, betInfos[_betID].reward, botFee);
    }

    /**
        * @dev Allows the winner to withdraw the reward from a resolved bet.
        * @param _betID The ID of the bet from which to withdraw the reward.
    */
    function withdraw(uint256 _betID) external validBetID(_betID) {
        require(msg.sender == betInfos[_betID].winner, "Invalid request: Only winner can withdraw!");
        require(betInfos[_betID].betStatus != 3, "Invalid request: You already have withdrawn funds!");
        require(betInfos[_betID].betStatus == 2, "Invalid request: Bet is not closed!");

        require(usdcTokenAddress.balanceOf(address(this)) >= betInfos[_betID].reward, 
            "Error: Insufficient USDC balance!");

        // Update the bet status to indicate the funds have been withdrawn
        betInfos[_betID].betStatus = 3;

        // Transfer the reward amount to the winner
        usdcTokenAddress.transfer(msg.sender, betInfos[_betID].reward);

        // Emit an event to log the withdrawal
        emit BetRewardWithdrawal(_betID, msg.sender, betInfos[_betID].reward);
    }

    /**
        * @dev Allows users to refund their bets if the bet is canceled or not matched.
        * @param _betID The ID of the bet to refund.
    */
    function refundBet(uint256 _betID) external validBetID(_betID) {
        BetInfo storage bet = betInfos[_betID];
        require(betInfos[_betID].betStatus == 0, "Invalid request: Bet is not in pending state");
        require(block.timestamp > bet.expireTime, "Invalid request: Bet expiration time has not yet been reached");
        require(bet.userA == msg.sender, "Invalid request: Only the bet creator can request a refund");

        // Update the bet status to canceled if it was pending
        if (betInfos[_betID].betStatus == 0) {
            betInfos[_betID].betStatus = 4; // canceled
        }

        // Transfer the bet amount back to the caller
        usdcTokenAddress.transfer(bet.userA, bet.amount);

        // Emit an event to log the refund
        emit BetRefunded(_betID, bet.userA, bet.amount);
    }

    function allowUser(address _userAddress, bool _isAllowed) public {
        require(_userAddress != address(0), "Invalid address!");
        userAllowed[_userAddress] = _isAllowed;
    }

    // Function to get the current price of BTC (stubbed)
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

    // Function to retrieve all pending bet IDs
    function getPendingBetIDs() public view returns (uint256[] memory) {
        return pendingBetIDs;
    }

    // Function to retrieve all active bet IDs
    function getActiveBetIDs() public view returns (uint256[] memory) {
        return activeBetIDs;
    }

    // Function to set the address of the Chainlink price feed
    function setPriceFeedAddress(address _feedAddress) external onlyOwner {
        priceFeedAddress = AggregatorV3Interface(_feedAddress);
    }

    // Function to get the address of the Chainlink price feed
    function getPriceFeedAddress() external view returns (address) {
        return address(priceFeedAddress);
    }

    // Function to set the address of the USDC token contract
    function setUSDCAddress(address _usdcAddress) external onlyOwner {
        usdcTokenAddress = IERC20(_usdcAddress);
    }

    // Function to get the address of the USDC token contract
    function getUSDCAddress() external view returns (address) {
        return address(usdcTokenAddress);
    }

    // Function to set the address of the bot
    function setBotAddress(address _botAddress) external onlyOwner {
        botAddress = _botAddress;
    }

    // Function to get the address of the bot
    function getBotAddress() external view returns (address) {
        return botAddress;
    }

    // Function to set the bot fee basis points
    function setBotFeeBasisPoints(uint256 _botFeeBasisPoints) external onlyOwner {
        botFeeBasisPoints = _botFeeBasisPoints;
    }

    // Function to get the bot fee basis points
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