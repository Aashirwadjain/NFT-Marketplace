// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface NFTInterface {

    function balanceOf(address account, uint id) external view returns (uint);

    function mint(address _to, uint _amount, string memory _uri, uint _royaltyFee, uint _royaltyFeeDecimalPlaces) external;

    function burn(address _from, uint _tokenId, uint _amount) external;

    function remint(address _to, uint _tokenId, uint _amount) external;

    function transfer(address from, address to, uint tokenId, uint amount) external;

    function getNFTInfo(uint _tokenId) external view returns (uint tokenId, uint amount, uint royaltyFee, uint royaltyFeeDecimalPlaces, address author, string memory uri);
    
    function isApprovedForAll(address account, address operator) external view returns (bool);

}

/**
 * @title NFT Marketplace Smart Contract
 *
 * @author Aashirwad Jain
 *
 * @dev This contracts provides functionality to Auction NFTs, Create Bids on Auctions,
 * create Sale for NFTs, Make Offer for Sale, Purchase NFTs
 */
contract NFTMarketPlace is ERC1155Holder {

    event AuctionCreated(uint indexed auctionId, uint indexed tokenId, uint startTime, uint endTime, uint price, uint tokensOnAuction, address auctionedBy, uint timestamp);

    event AuctionExecuted(uint indexed auctionId, uint indexed tokenId, address indexed bidder, uint price, uint tokensOnAuction, uint timestamp);

    event AuctionCancelled(uint indexed auctionId, uint indexed tokenId, address indexed auctionedBy, uint timestamp);

    event BidCreated(uint indexed auctionId, address indexed offerer, uint indexed bidPrice, uint timestamp);

    event SaleCreated(uint indexed saleId, uint indexed tokenId, uint price, uint tokensOnSale, address saleBy, uint timestamp);

    event SaleExecuted(uint indexed saleId, uint indexed tokenId, address indexed offerer, uint price, uint tokensOnSale, uint timestamp);

    event SaleCancelled(uint indexed saleId, uint indexed tokenId, address indexed saleBy, uint timestamp);

    event OfferCreated(uint indexed saleId, address indexed offerer, uint indexed offerPrice, uint timestamp);

    address private nftContractAddress;

    address private admin;

    uint private auctionCount;
    uint private saleCount;

    uint private minDurationToAuction = 5 minutes;

    uint private marketPlaceFee = 1;
    uint private marketPlaceFeeDecimalPlaces;

    uint private mintFee = 0.00001 ether;

    uint private remintFee = 0.00001 ether;

    enum Status {Initial, Executed, Cancelled}

    struct Auction {
        uint auctionId;
        uint tokenId;
        uint startTS;
        uint endTS;
        uint tokensOnAuction;
        uint bidCount;
        uint maxBid;
        address maxBidder;
        address auctionedBy;
        Status status;
    }

    /// auctionId => bidder => amount;
    mapping(uint => mapping(address => uint)) private holdingAuction;

    mapping(uint => Auction) private auctionInfo;

    struct Sale {
        uint saleId;
        uint tokenId;
        uint salePrice;
        uint tokensOnSale;
        uint offerCount;
        uint maxOffer;
        address maxOfferer;
        address saleBy;
        Status status;
    }

    /// saleId => offerer => amount;
    mapping(uint => mapping(address => uint)) private holdingSale;

    mapping(uint => Sale) private saleInfo;

    mapping(uint => uint) private burntTokens;

    constructor(address _nftContractAddress) {
        admin = msg.sender;
        nftContractAddress = _nftContractAddress;
    }

    modifier onlyValidAuction(uint _auctionId) {
        require(auctionInfo[_auctionId].auctionId == _auctionId && auctionInfo[_auctionId].auctionedBy != address(0), "Invalid Auction");
        _;
    }

    modifier canBid(uint _auctionId) {
        require(block.timestamp >= auctionInfo[_auctionId].startTS && 
                block.timestamp <= auctionInfo[_auctionId].endTS && 
                auctionInfo[_auctionId].status == Status.Initial, "Invalid Bid");
        _;
    }

    /**
     * @dev Creates an Auction
     *
     * Emits an {AuctionCreated} event indicating that the auction is created
     *
     * Requirements:
     * 
     * - `_tokenId` must be a valid token id.
     * - `_startTS` must not be in past.
     * - `_endTS` must be greater than `_startTS`.
     * - `_price` must be greater than zero.
     * - the contract must have allowance for caller's tokens
     * - duration between `_endTS` and `_startTS` should be atleast `minDurationToAuction`.
     */
    function createAuction(uint _tokenId, uint _startTS, uint _endTS, uint _price, uint _tokensOnAuction) external {

        (uint tokenId, , , , address author,) = NFTInterface(nftContractAddress).getNFTInfo(_tokenId);
        require(tokenId == _tokenId && author != address(0), "Invalid Token");

        require(NFTInterface(nftContractAddress).balanceOf(msg.sender, _tokenId) >= _tokensOnAuction, "You don't have enough Tokens to Auction");

        require(_startTS >= block.timestamp, "Start time should not be in past");
        require(_endTS > _startTS, "End time must be greater than start time");
        require(_endTS - _startTS >= minDurationToAuction, "Please Increase Duration");

        require(_price > 0, "Price cannot be 0");
        require(NFTInterface(nftContractAddress).isApprovedForAll(msg.sender, address(this)), "Insufficient Allowance");

        NFTInterface(nftContractAddress).transfer(msg.sender, address(this), _tokenId, _tokensOnAuction);
        
        auctionInfo[auctionCount] = Auction({
            auctionId : auctionCount,
            tokenId : _tokenId,
            startTS : _startTS,
            endTS : _endTS,
            tokensOnAuction : _tokensOnAuction,
            bidCount : 0,
            maxBid : _price,
            maxBidder : address(0),
            auctionedBy : msg.sender,
            status : Status.Initial
        });

        emit AuctionCreated(auctionInfo[auctionCount].auctionId, auctionInfo[auctionCount].tokenId, 
                            auctionInfo[auctionCount].startTS, auctionInfo[auctionCount].endTS, 
                            _price, auctionInfo[auctionCount].tokensOnAuction,
                            auctionInfo[auctionCount].auctionedBy, block.timestamp);

        ++auctionCount;

    }

    /**
     * @dev Creates bids for an auction
     *
     * Emits a {BidCreated} event indicating a bid is created
     *
     * Requirements:
     * 
     * - `_auctionId` must be valid
     * - caller must not bid in their own auction
     * - bid must always be greater than previous bid
     *
     */
    function bidAuction(uint _auctionId) payable external onlyValidAuction(_auctionId) canBid(_auctionId) {

        require(msg.sender != auctionInfo[_auctionId].auctionedBy, "You cannot bid in your own auction");
       
        require(holdingAuction[_auctionId][msg.sender] + msg.value > auctionInfo[_auctionId].maxBid, "Bid Price must be greater than Max Bid");
        
        holdingAuction[_auctionId][msg.sender] += msg.value;

        auctionInfo[_auctionId].maxBid = holdingAuction[_auctionId][msg.sender];
        auctionInfo[_auctionId].maxBidder = msg.sender;

        auctionInfo[_auctionId].bidCount++;

        emit BidCreated(_auctionId, msg.sender, holdingAuction[_auctionId][msg.sender], block.timestamp);

    }

    /**
     * @dev Executes an Auction
     *
     * An Auction can only be executed iff its duration is over.
     *
     * An Auction can only be executed iff the caller is auction's owner or max bidder.
     *
     * Tokens will be transferred to the max bidder if there is any.
     * 
     * The Amount received from max bidder is transferred to the auction's owner after deducting
     * marketplace fee & token's author reward.
     *
     * Updates auction's status to EXECUTED.
     *
     * Emits a {AuctionExecuted} event indicating auction is executed.
     */
    function executeAuction(uint _auctionId) external onlyValidAuction(_auctionId) {

        require(block.timestamp > auctionInfo[_auctionId].startTS && 
                block.timestamp > auctionInfo[_auctionId].endTS && 
                auctionInfo[_auctionId].status == Status.Initial, "Cannot Execute Auction");

        uint maxBid = auctionInfo[_auctionId].maxBid;
        address maxBidder = auctionInfo[_auctionId].maxBidder;

        require(maxBidder != address(0), "No Bid Found");
        require(msg.sender == auctionInfo[_auctionId].auctionedBy || msg.sender == maxBidder, "Insufficient Access");

        NFTInterface(nftContractAddress).transfer(address(this), maxBidder, auctionInfo[_auctionId].tokenId, auctionInfo[_auctionId].tokensOnAuction);

        uint fee = (maxBid * marketPlaceFee) / (10 ** (marketPlaceFeeDecimalPlaces + 2));
        uint amount = maxBid - fee;

        (, , uint authorReward, uint authorRewardDecimalPlaces, address author, ) = NFTInterface(nftContractAddress).getNFTInfo(auctionInfo[_auctionId].tokenId);

        if(author != auctionInfo[_auctionId].auctionedBy) {
            uint feeToAuthor = (maxBid * authorReward) / (10 ** (authorRewardDecimalPlaces + 2));
            payable(author).transfer(feeToAuthor);
            amount -= feeToAuthor;
        }

        payable(auctionInfo[_auctionId].auctionedBy).transfer(amount);
        holdingAuction[_auctionId][maxBidder] = 0;

        auctionInfo[_auctionId].status = Status.Executed;

        emit AuctionExecuted(_auctionId, auctionInfo[_auctionId].tokenId, maxBidder, maxBid, auctionInfo[_auctionId].tokensOnAuction, block.timestamp);

    }

    /**
     * @dev Claims Refund for unexecuted bids for an auction.
     *
     * Refund can only be claimed after the auction is over.
     * 
     * Transfers bid amount to the bidder if participated in the auction.
     */
    function claimRefundForAuction(uint _auctionId) public onlyValidAuction(_auctionId) {

        if(auctionInfo[_auctionId].status != Status.Cancelled) {
            require(block.timestamp > auctionInfo[_auctionId].startTS && block.timestamp > auctionInfo[_auctionId].endTS, "Cannot Claim at the moment");
            require(auctionInfo[_auctionId].maxBidder != msg.sender, "Cannot Claim Refund for Highest Bidder");
        }
        
        require(holdingAuction[_auctionId][msg.sender] > 0, "No Refund to Claim for this Auction");

        payable(msg.sender).transfer(holdingAuction[_auctionId][msg.sender]);

        holdingAuction[_auctionId][msg.sender] = 0;
    }

    /**
     * @dev Cancels an Auction
     *
     * Emits {AuctionCancelled} event indicating auction is cancelled.
     *
     * Requirements:
     *
     * - caller must be auction's owner.
     * - there must not be any bids present in order to cancel the auction.
     */
    function cancelAuction(uint _auctionId) public onlyValidAuction(_auctionId) {

        require(msg.sender == auctionInfo[_auctionId].auctionedBy, "Insufficient Access");
        require(auctionInfo[_auctionId].status == Status.Initial, "Auction is Inactive");

        require(auctionInfo[_auctionId].maxBidder == address(0), "Bids Exist! Cannot Cancel Auction");

        auctionInfo[_auctionId].status = Status.Cancelled;

        emit AuctionCancelled(_auctionId, auctionInfo[_auctionId].tokenId, auctionInfo[_auctionId].auctionedBy, block.timestamp);
    }

    /**
     * @dev Creates Sale
     *
     * Emits {SaleCreated} event indicating sale is created.
     *
     * Requirements:
     * - caller must have enough tokens to sale.
     */
    function createSale(uint _tokenId, uint _salePrice, uint _tokensOnSale) external {

        (uint tokenId, , , ,address author,) = NFTInterface(nftContractAddress).getNFTInfo(_tokenId);
        require(tokenId == _tokenId && author != address(0), "Invalid Token");

        require(NFTInterface(nftContractAddress).balanceOf(msg.sender, _tokenId) >= _tokensOnSale, "You don't have enough Tokens to Sale");
        require(_salePrice > 0, "Price cannot be 0");

        require(NFTInterface(nftContractAddress).isApprovedForAll(msg.sender, address(this)), "Insufficient Allowance");

        NFTInterface(nftContractAddress).transfer(msg.sender, address(this), _tokenId, _tokensOnSale);

        saleInfo[saleCount] = Sale ({
            saleId : saleCount,
            tokenId : _tokenId,
            salePrice : _salePrice,
            tokensOnSale : _tokensOnSale,
            offerCount : 0,
            maxOffer : 0,
            maxOfferer : address(0),
            saleBy : msg.sender,
            status : Status.Initial
        });

        emit SaleCreated(saleInfo[saleCount].saleId, saleInfo[saleCount].tokenId,
                         saleInfo[saleCount].salePrice, saleInfo[saleCount].tokensOnSale, 
                         saleInfo[saleCount].saleBy, block.timestamp);
        
        ++saleCount;

    }

    /**
     * @dev Makes Purchase
     *
     * The Amount received from buyer is transferred to the sale's owner after deducting
     * marketplace fee & token's author reward.
     *
     * Emits {SaleExecuted} event indicating sale is executed.
     *
     * Requirements:
     * - caller must not be owner of Sale.
     */
    function purchase(uint _saleId) external payable {

        require(saleInfo[_saleId].saleId == _saleId && saleInfo[_saleId].saleBy != address(0), "Invalid sale");
        require(msg.sender != saleInfo[_saleId].saleBy, "You cannot Purchase in your own Sale");
        require(msg.value >= saleInfo[_saleId].salePrice, "Insufficient Amount Provided");

        NFTInterface(nftContractAddress).transfer(address(this), msg.sender, saleInfo[_saleId].tokenId, saleInfo[_saleId].tokensOnSale);

        if(msg.value > saleInfo[_saleId].salePrice) {
            payable(msg.sender).transfer(msg.value - saleInfo[_saleId].salePrice);
        }

        uint amount = saleInfo[_saleId].salePrice;

        uint fee = (amount * marketPlaceFee) / (10 ** (marketPlaceFeeDecimalPlaces + 2));
        amount -= fee;

        (, , uint authorReward, uint authorRewardDecimalPlaces, address author, ) = NFTInterface(nftContractAddress).getNFTInfo(saleInfo[_saleId].tokenId);

        if(author != saleInfo[_saleId].saleBy) {
            uint feeToAuthor = (saleInfo[_saleId].salePrice * authorReward) / (10 ** (authorRewardDecimalPlaces + 2));
            payable(author).transfer(feeToAuthor);
            amount -= feeToAuthor;
        }

        payable(saleInfo[_saleId].saleBy).transfer(amount);

        saleInfo[_saleId].status = Status.Executed;

        emit SaleExecuted(_saleId, saleInfo[_saleId].tokenId, msg.sender, saleInfo[_saleId].salePrice, saleInfo[_saleId].tokensOnSale, block.timestamp);
             
    }

    /**
     * @dev Makes Offer for Sale
     *
     * Emits {OfferCreated} event indicating an offer is made.
     *
     * Requirements:
     * - Offer Price must be greater than zero.
     * - Offer Price must be lesser than Sale Price.
     * - Offer must be made for a price more than Max Offer.
     */
    function makeOffer(uint _saleId) payable external {

        require(saleInfo[_saleId].saleId == _saleId && saleInfo[_saleId].saleBy != address(0), "Invalid sale");
        require(msg.sender != saleInfo[_saleId].saleBy, "You cannot Make Offers in your own Sale");
        require(msg.value > 0, "Price cannot be 0");
        require(holdingSale[_saleId][msg.sender] + msg.value > saleInfo[_saleId].maxOffer, "Price must be more than max offer price");
        require(holdingSale[_saleId][msg.sender] + msg.value < saleInfo[_saleId].salePrice, "Cannot make offer for price more than sale price");

        holdingSale[_saleId][msg.sender] += msg.value;

        saleInfo[_saleId].maxOffer = holdingSale[_saleId][msg.sender];
        saleInfo[_saleId].maxOfferer = msg.sender;
 
        emit OfferCreated(_saleId, msg.sender, holdingSale[_saleId][msg.sender], block.timestamp);
        
    }

    /**
     * @dev Executes a Sale
     *
     * The Amount received from max offerer is transferred to the sale's owner after deducting
     * marketplace fee & token's author reward.
     *
     * Emits {SaleExecuted} event indicating Sale is executed.
     *
     * Requirements:
     * - Sale must be active [Neither Cancelled nor Executed] 
     */
    function executeSale(uint _saleId) external {

        require(saleInfo[_saleId].saleId == _saleId && saleInfo[_saleId].saleBy != address(0), "Invalid sale");

        uint maxOffer = saleInfo[_saleId].maxOffer;
        address offerer = saleInfo[_saleId].maxOfferer;

        require(msg.sender == saleInfo[_saleId].saleBy, "Insufficient Access");

        require(saleInfo[_saleId].status == Status.Initial, "Sale is Inactive");

        require(maxOffer != 0 && offerer != address(0), "No Offer Found");

        uint amount = maxOffer;
        
        NFTInterface(nftContractAddress).transfer(address(this), offerer, saleInfo[_saleId].tokenId, saleInfo[_saleId].tokensOnSale);

        uint fee = (maxOffer * marketPlaceFee) / (10 ** (marketPlaceFeeDecimalPlaces + 2));
        amount -= fee;

        (, , uint authorReward, uint authorRewardDecimalPlaces, address author, ) = NFTInterface(nftContractAddress).getNFTInfo(saleInfo[_saleId].tokenId);
        
        if(author != address(0) && author != saleInfo[_saleId].saleBy) {
            uint feeToAuthor = (maxOffer * authorReward) / (10 ** (authorRewardDecimalPlaces + 2));
            payable(author).transfer(feeToAuthor);
            amount -= feeToAuthor;
        }
        
        payable(saleInfo[_saleId].saleBy).transfer(amount);
        holdingSale[_saleId][offerer] = 0;

        saleInfo[_saleId].status = Status.Executed;

        emit SaleExecuted(_saleId, saleInfo[_saleId].tokenId, offerer, maxOffer, saleInfo[_saleId].tokensOnSale, block.timestamp);

    }

    /**
     * @dev Cancels a Sale
     *
     * Emits {SaleCancelled} event indicating Sale is cancelled.
     *
     * Requirements:
     * - sale must be active [Neither Cancelled nor Executed] 
     * - caller must be sale's owner
     */
    function cancelSale(uint _saleId) external {

        require(saleInfo[_saleId].saleId == _saleId && saleInfo[_saleId].saleBy != address(0), "Invalid sale");
        require(msg.sender == saleInfo[_saleId].saleBy, "Insufficient Access");

        require(saleInfo[_saleId].status == Status.Initial, "Sale is Inactive");
        
        saleInfo[_saleId].status = Status.Cancelled;

        emit SaleCancelled(_saleId, saleInfo[_saleId].tokenId, saleInfo[_saleId].saleBy, block.timestamp);
    }

    /**
     * @dev Claims Refund for unexecuted offers for a sale.
     *
     * Transfers offered amount to the offerer if participated in the sale.
     */
    function claimRefundForSale(uint _saleId) external {

        require(saleInfo[_saleId].saleId == _saleId && saleInfo[_saleId].saleBy != address(0), "Invalid sale");

        if(saleInfo[_saleId].status != Status.Cancelled) {
            require(saleInfo[_saleId].maxOfferer != msg.sender, "Cannot Claim");
        }

        require(holdingSale[_saleId][msg.sender] > 0, "No Refund to Claim for this Auction");

        payable(msg.sender).transfer(holdingSale[_saleId][msg.sender]);

        holdingSale[_saleId][msg.sender] = 0;
    }

    function mintNFT(uint _amount, string memory _uri, uint _royaltyFee, uint _royaltyFeeDecimalPlaces) external payable {

        require(_amount > 0, "Amount cannot be 0");
        require(msg.value >= (mintFee * _amount), "Insufficient Fund Provided");
        
        NFTInterface(nftContractAddress).mint(msg.sender, _amount, _uri, _royaltyFee, _royaltyFeeDecimalPlaces);
        
    }

    function burnNFT(uint _tokenId, uint _amount) external {
        
        require(_amount > 0, "Amount cannot be 0");
        require(NFTInterface(nftContractAddress).balanceOf(msg.sender, _tokenId) >= _amount, "Insufficient Tokens to Burn");

        NFTInterface(nftContractAddress).burn(msg.sender, _tokenId, _amount);

        burntTokens[_tokenId] += _amount;
    }

    function remintNFT(uint _tokenId, uint _amount) external payable {
        (, , , , address author, ) = NFTInterface(nftContractAddress).getNFTInfo(_tokenId);

        require(author == msg.sender, "Only Author can mint NFT");
        require(_amount > 0, "Amount cannot be 0");
        require(msg.value >= (remintFee * _amount), "Insufficient Fund Provided");
        require(burntTokens[_tokenId] >= _amount, "Insufficient NFTs to Remint");

        burntTokens[_tokenId] -= _amount;

        NFTInterface(nftContractAddress).remint(msg.sender, _tokenId, _amount);
    }

    /**
     * @dev Returns Holding for Auction
     */
    function getHoldingAuction(uint _tokenId, address _bidder) external view returns (uint _amount) {
        return holdingAuction[_tokenId][_bidder];
    }

    /**
     * @dev Returns Holding for Sale
     */
    function getHoldingSale(uint _tokenId, address _offerer) external view returns (uint _amount) {
        return holdingSale[_tokenId][_offerer];
    }

    /**
     * @dev Returns Auction Information
     */
    function getAuction(uint auctionId_) external view returns (uint _auctionId, uint _tokenId, uint _startTS, 
                                                                uint _endTS, uint _tokensOnAuction, uint _bidCount,
                                                                uint _maxBid, address _maxBidder, address _auctionedBy,
                                                                Status _status) {

        _auctionId = auctionInfo[auctionId_].auctionId;
        _tokenId = auctionInfo[auctionId_].tokenId;
        _startTS = auctionInfo[auctionId_].startTS;
        _endTS = auctionInfo[auctionId_].endTS;
        _tokensOnAuction = auctionInfo[auctionId_].tokensOnAuction;
        _bidCount = auctionInfo[auctionId_].bidCount;
        _maxBid = auctionInfo[auctionId_].maxBid;
        _maxBidder =  auctionInfo[auctionId_].maxBidder;
        _auctionedBy = auctionInfo[auctionId_].auctionedBy;
        _status = auctionInfo[auctionId_].status;

        return (_auctionId, _tokenId, _startTS, _endTS, _tokensOnAuction, 
                _bidCount, _maxBid, _maxBidder, _auctionedBy, _status);

    }

    /**
     * @dev Returns Sale Information
     */
    function getSale(uint saleId_) external view returns (uint _saleId, uint _tokenId, uint _salePrice,
                                                          uint _tokensOnSale, uint _offerCount, uint _maxOffer,
                                                          address _maxOfferer, address _saleBy, Status _status) {
        
        _saleId = saleInfo[saleId_].saleId;
        _tokenId = saleInfo[saleId_].tokenId;
        _salePrice = saleInfo[saleId_].salePrice;
        _tokensOnSale = saleInfo[saleId_].tokensOnSale;
        _offerCount = saleInfo[saleId_].offerCount;
        _maxOffer = saleInfo[saleId_].maxOffer;
        _maxOfferer =  saleInfo[saleId_].maxOfferer;
        _saleBy = saleInfo[saleId_].saleBy;
        _status = saleInfo[saleId_].status;

        return (_saleId, _tokenId, _salePrice, _tokensOnSale, _offerCount, 
                _maxOffer, _maxOfferer, _saleBy, _status);

    }

    /**
     * @dev Returns Marketplace Fee
     */
    function getMarketPlaceFee() external view returns (uint _marketPlaceFee, uint _marketPlaceFeeDecimalPlaces) {
        return (marketPlaceFee, marketPlaceFeeDecimalPlaces);
    }

    function setMarketPlaceFee(uint _marketPlaceFee, uint _marketPlaceFeeDecimalPlaces) external {
        require(msg.sender == admin, "Insufficient Access");
        marketPlaceFee = _marketPlaceFee;
        marketPlaceFeeDecimalPlaces = _marketPlaceFeeDecimalPlaces;
    }

    /**
     * @dev Returns total amount of tokens burnt for a `_tokenId`
     */
    function getBurntTokens(uint _tokenId) external view returns (uint) {
        return burntTokens[_tokenId];
    }

    /**
     * @dev Returns Mint Fee
     */
    function getMintFee() external view returns (uint) {
        return mintFee;
    }

    function setMintFee(uint _mintFee) external {
        require(msg.sender == admin, "Insufficient Access");
        mintFee = _mintFee;
    }

    /**
     * @dev Returns Remint Fee
     */
    function getRemintFee() external view returns (uint) {
        return remintFee;
    }

    function setRemintFee(uint _remintFee) external {
        require(msg.sender == admin, "Insufficient Access");
        remintFee = _remintFee;
    }

    /**
     * @dev Returns admin address
     */
    function getAdmin() external view returns (address) {
        return admin;
    }

    function setAdmin(address _admin) external {
        require(msg.sender == admin, "Insufficient Access");
        require(_admin != address(0), "Admin address must not be zero address");
        admin = _admin;
    }

    /**
     * @dev Returns Minimum Duration required to Auction
     */
    function getMinDurationToAuction() external view returns (uint) {
        return minDurationToAuction;
    }

    function setMinDurationToAuction(uint _minDurationToAuction) external {
        require(msg.sender == admin, "Insufficient Access");
        require(_minDurationToAuction > 0, "Minimum Duration required to Auction should be greater than 0");
        minDurationToAuction = _minDurationToAuction;
    }

}
