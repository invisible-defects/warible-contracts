// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 <0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@rarible/lazy-mint/contracts/erc-1155/IERC1155LazyMint.sol";
import "@rarible/lazy-mint/contracts/erc-1155/LibERC1155LazyMint.sol";
import "./SafeMath.sol";
import "./Strings.sol";

/**
 * @title Lootbox
 * Lootbox - a randomized and openable lootbox of ERC1155
 */
contract Lootbox is Ownable, Pausable, ReentrancyGuard {
  using SafeMath for uint256;

  // Event for logging lootbox opens
  event LootBoxOpened(uint256 indexed optionId, address indexed buyer, uint256 boxesPurchased, uint256 itemsMinted);
  event Warning(string message, address account);

  // Address of the ERC1155 NFT being used
  address nftAddress;
  // TODO: add meta url
  string constant internal baseMetadataURI = "https://example.com/";

  // Drops rarity classes
  enum Class {
    Common,
    Rare,
    Epic,
    Legendary
  }
  uint256 constant NUM_CLASSES = 4;

  // Lootbox price/loot quiality options
  enum Option {
    Basic,
    Gold,
    Magic
  }
  uint256 constant NUM_OPTIONS = 3;

  struct OptionSettings {
    // Probability in basis points (out of 10,000) of receiving each class (descending)
    uint16[NUM_CLASSES] classProbabilities;
  }

  mapping (uint256 => OptionSettings) optionToSettings;
  mapping (uint256 => uint256[]) classToTokenIds;
  mapping (uint256 => LibERC1155LazyMint.Mint1155Data) tokenIdToMintData;
  mapping (uint256 => bool) classIsPreminted;
  uint256 seed;
  uint256 constant INVERSE_BASIS_POINT = 10000;

  /**
   * @dev Example constructor. Calls setOptionSettings for you with
   *      sample settings
   * @param _nftAddress The address of the non-fungible/semi-fungible item contract
   *                    that you want to mint/transfer with each open
   */
  constructor(
    address _nftAddress
  ) {
    // Example settings and probabilities
    // you can also call these after deploying
    setOptionSettings(Option.Basic, [7300, 2100, 400, 200]);
    setOptionSettings(Option.Gold, [7000, 2300, 400, 300]);
    setOptionSettings(Option.Magic, [6800, 2400, 400, 400]);

    nftAddress = _nftAddress;
  }

  //////
  // INITIALIZATION FUNCTIONS FOR OWNER
  //////

  /**
   * @dev If the tokens for some class are pre-minted and owned by the
   * contract owner, they can be used for a given class by setting them here
   */
  function setClassForTokenId(
    uint256 _tokenId,
    uint256 _classId
  ) public onlyOwner {
    _checkTokenApproval();
    _addTokenIdToClass(Class(_classId), _tokenId);
  }

  /**
   * @dev Alternate way to add token ids to a class
   * Note: resets the full list for the class instead of adding each token id
   */
  function setTokenIdsForClass(
    Class _class,
    uint256[] memory _tokenIds
  ) public onlyOwner {
    uint256 classId = uint256(_class);
    classIsPreminted[classId] = true;
    classToTokenIds[classId] = _tokenIds;
  }

  /**
   * @dev Remove all token ids for a given class, causing it to fall back to
   * creating/minting into the nft address
   */
  function resetClass(
    uint256 _classId
  ) public onlyOwner {
    delete classIsPreminted[_classId];
    delete classToTokenIds[_classId];
  }

  /**
   * @dev Set token IDs for each rarity class. Bulk version of `setTokenIdForClass`
   * @param _tokenIds List of token IDs to set for each class, specified above in order
   */
  function setTokenIdsForClasses(
    uint256[NUM_CLASSES] memory _tokenIds
  ) public onlyOwner {
    _checkTokenApproval();
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      Class class = Class(i);
      _addTokenIdToClass(class, _tokenIds[i]);
    }
  }

  /**
   * @dev Set the settings for a particular lootbox option
   * @param _option The Option to set settings for
   * @param _classProbabilities Array of probabilities (basis points, so integers out of 10,000)
   *                            of receiving each class (the index in the array).
   *                            Should add up to 10k and be descending in value.
   */
  function setOptionSettings(
    Option _option,
    uint16[NUM_CLASSES] memory _classProbabilities
  ) public onlyOwner {
    OptionSettings memory settings = OptionSettings({
        classProbabilities: _classProbabilities
    });

    optionToSettings[uint256(_option)] = settings;
  }

  /**
   * @dev Improve pseudorandom number generator by letting the owner set the seed manually,
   * making attacks more difficult
   * @param _newSeed The new seed to use for the next transaction
   */
  function setSeed(uint256 _newSeed) public onlyOwner {
    seed = _newSeed;
  }

  ///////
  // MAIN FUNCTIONS
  //////

  /**
   * @dev Open a lootbox manually and send what's inside to _toAddress
   * Convenience method for contract owner.
   */
  function open(
    uint256 _optionId,
    address _toAddress,
    uint256 _amount
  ) external onlyOwner {
    _mint(Option(_optionId), _toAddress, _amount, "");
  }

  /**
   * @dev Main minting logic for lootboxes.
   */
  function _mint(
    Option _option,
    address _toAddress,
    uint256 _amount,
    bytes memory /* _data */
  ) internal whenNotPaused nonReentrant {
    // Load settings for this box option
    uint256 optionId = uint256(_option);
    OptionSettings memory settings = optionToSettings[optionId];

    uint256 totalMinted = 0;

    // Iterate over the quantity of boxes specified
    for (uint256 i = 0; i < _amount; i++) {
      uint256 quantitySent = 0;
      
      // Unbox and send a random class token
      while (quantitySent < 1) {
        uint256 quantityOfRandomized = 1;
        Class class = _pickRandomClass(settings.classProbabilities);
        _sendTokenWithClass(class, _toAddress, quantityOfRandomized);
        quantitySent += quantityOfRandomized;
      }

      totalMinted += quantitySent;
    }

    // Event emissions
    emit LootBoxOpened(optionId, _toAddress, _amount, totalMinted);
  }

  function withdraw() public onlyOwner {
    msg.sender.transfer(address(this).balance);
  }

  /////
  // Metadata methods
  /////

  function name() external pure returns (string memory) {
    return "ERC-1155 Lootbox";
  }

  function symbol() external pure returns (string memory) {
    return "LOOTBOX";
  }

  function uri(uint256 _optionId) external pure returns (string memory) {
    return Strings.strConcat(
      baseMetadataURI,
      "box/",
      Strings.uint2str(_optionId)
    );
  }

  /////
  // HELPER FUNCTIONS
  /////

  // Returns the tokenId sent to _toAddress
  function _sendTokenWithClass(
    Class _class,
    address _toAddress,
    uint256 _amount
  ) internal returns (uint256) {
    uint256 classId = uint256(_class);
    IERC1155LazyMint nftContract = IERC1155LazyMint(nftAddress);

    uint256 tokenId = _pickRandomAvailableTokenIdForClass(_class, _amount);
    // TODO: support unminted tokens, pre-created droptables with token meta
    require(
        tokenId != 0,
        "Lootbox#__sendTokenWithClass: UNMINTED_TOKENS_NOT_SUPPORTED"
    );

    if (classIsPreminted[classId]) {
      nftContract.safeTransferFrom(
        owner(),
        _toAddress,
        tokenId,
        _amount,
        ""
      );
    } else {
      nftContract.mintAndTransfer(tokenIdToMintData[tokenId], _toAddress, _amount);
    }
    return tokenId;
  }

  function _pickRandomClass(
    uint16[NUM_CLASSES] memory _classProbabilities
  ) internal returns (Class) {
    uint16 value = uint16(_random().mod(INVERSE_BASIS_POINT));
    // Start at top class (length - 1)
    // skip common (0), we default to it
    for (uint256 i = _classProbabilities.length - 1; i > 0; i--) {
      uint16 probability = _classProbabilities[i];
      if (value < probability) {
        return Class(i);
      } else {
        value = value - probability;
      }
    }
    return Class.Common;
  }

  function _pickRandomAvailableTokenIdForClass(
    Class _class,
    uint256 _minAmount
  ) internal returns (uint256) {
    uint256 classId = uint256(_class);
    uint256[] memory tokenIds = classToTokenIds[classId];
    if (tokenIds.length == 0) {
      // Unminted
      require(
        !classIsPreminted[classId],
        "Lootbox#_pickRandomAvailableTokenIdForClass: NO_TOKEN_ON_PREMINTED_CLASS"
      );
      return 0;
    }

    uint256 randIndex = _random().mod(tokenIds.length);

    if (classIsPreminted[classId]) {
      // Make sure owner() owns enough
      IERC1155LazyMint nftContract = IERC1155LazyMint(nftAddress);
      for (uint256 i = randIndex; i < randIndex + tokenIds.length; i++) {
        uint256 tokenId = tokenIds[i % tokenIds.length];
        if (nftContract.balanceOf(owner(), tokenId) >= _minAmount) {
          return tokenId;
        }
      }
      revert("Lootbox#_pickRandomAvailableTokenIdForClass: NOT_ENOUGH_TOKENS_FOR_CLASS");
    } else {
      return tokenIds[randIndex];
    }
  }

  /**
   * @dev Pseudo-random number generator
   * NOTE: to improve randomness, generate it with an oracle
   */
  function _random() internal returns (uint256) {
    uint256 randomNumber = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender, seed)));
    seed = randomNumber;
    return randomNumber;
  }

  /**
   * @dev emit a Warning if we're not approved to transfer nftAddress
   */
  function _checkTokenApproval() internal {
    IERC1155LazyMint nftContract = IERC1155LazyMint(nftAddress);
    if (!nftContract.isApprovedForAll(owner(), address(this))) {
      emit Warning("Lootbox contract is not approved for trading collectible by:", owner());
    }
  }

  function _addTokenIdToClass(Class _class, uint256 _tokenId) internal {
    uint256 classId = uint256(_class);
    classIsPreminted[classId] = true;
    classToTokenIds[classId].push(_tokenId);
  }
}