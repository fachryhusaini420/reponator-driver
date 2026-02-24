// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ReponatorDriver
 * @notice Racing car NFT collection with NFT-gated progression: mint cars by chassis and engine tier, unlock stages and checkpoints by holding qualifying tokens. Lap times and leaderboard on-chain.
 * @dev Pit boss mints and configures stages; race director records laps and advances progression. Treasury and prize vault are immutable.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC721/ERC721.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";

contract ReponatorDriver is ERC721, ERC721Enumerable, ERC721URIStorage, ReentrancyGuard, Pausable {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event CarMinted(uint256 indexed tokenId, address indexed to, uint8 chassisType, uint8 engineTier, uint256 paidWei, uint256 atBlock);
    event StageConfigured(uint8 indexed stageId, uint8 requiredMinTier, uint32 requiredChassisMask, uint256 atBlock);
    event CheckpointConfigured(uint8 indexed stageId, uint8 indexed checkpointIndex, uint256 lapTimeMaxMs, uint256 atBlock);
    event StageUnlocked(address indexed driver, uint8 stageId, uint256 indexed tokenIdUsed, uint256 atBlock);
    event CheckpointReached(address indexed driver, uint8 stageId, uint8 checkpointIndex, uint256 lapTimeMs, uint256 atBlock);
    event LapRecorded(address indexed driver, uint256 indexed tokenId, uint8 stageId, uint256 lapTimeMs, uint256 atBlock);
    event PitBossUpdated(address indexed previous, address indexed current);
    event RaceDirectorUpdated(address indexed previous, address indexed current);
    event MintPriceSet(uint8 chassisType, uint256 previousWei, uint256 newWei, uint256 atBlock);
    event BaseURISet(string previousURI, string newURI, uint256 atBlock);
    event ProceedsWithdrawn(address indexed to, uint256 amountWei, uint256 atBlock);
    event CollectionPaused(address indexed by, uint256 atBlock);
    event CollectionUnpaused(address indexed by, uint256 atBlock);
    event BatchMinted(address indexed to, uint256[] tokenIds, uint256 totalPaidWei, uint256 atBlock);
    event LeaderboardUpdated(uint8 stageId, address indexed driver, uint256 lapTimeMs, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error RPD_ZeroAddress();
    error RPD_ZeroAmount();
    error RPD_CollectionPaused();
    error RPD_MaxSupplyReached();
    error RPD_InsufficientPayment();
    error RPD_TransferFailed();
    error RPD_NotPitBoss();
    error RPD_NotRaceDirector();
    error RPD_InvalidChassisType();
    error RPD_InvalidEngineTier();
    error RPD_InvalidStageId();
    error RPD_InvalidCheckpointIndex();
    error RPD_StageNotUnlocked();
    error RPD_CheckpointNotReached();
    error RPD_NotTokenOwner();
    error RPD_TokenDoesNotQualify();
    error RPD_LapTimeTooHigh();
    error RPD_ArrayLengthMismatch();
    error RPD_BatchTooLarge();
    error RPD_WithdrawZero();
    error RPD_StageAlreadyConfigured();
    error RPD_InvalidTokenId();
    error RPD_MaxStagesReached();
    error RPD_MaxCheckpointsReached();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant RPD_MAX_SUPPLY = 9999;
    uint256 public constant RPD_MAX_CHASSIS_TYPES = 32;
    uint256 public constant RPD_MAX_ENGINE_TIER = 7;
    uint256 public constant RPD_MAX_STAGES = 24;
    uint256 public constant RPD_MAX_CHECKPOINTS_PER_STAGE = 16;
    uint256 public constant RPD_BATCH_MINT_CAP = 12;
    uint256 public constant RPD_LAP_TIME_SCALE_MS = 999999;
    bytes32 public constant RPD_TRACK_SALT = bytes32(uint256(0x2f4a6c8e0b2d5f7a9c1e4f6a8b0d2e5f7a9c1e4f6a8b0d2e5f7a9c1e4f6a8b0d2));

    // -------------------------------------------------------------------------
    // IMMUTABLE
    // -------------------------------------------------------------------------

    address public immutable pitBossDeploy;
    address public immutable raceDirectorDeploy;
    address public immutable treasury;
    address public immutable prizeVault;
    uint256 public immutable deployBlock;
    bytes32 public immutable trackDomain;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    address public pitBoss;
    address public raceDirector;
    uint256 public nextTokenId;
    string private _baseTokenURI;
    bool private _pausedByRole;
    mapping(uint256 => uint8) public carChassisType;
    mapping(uint256 => uint8) public carEngineTier;
    mapping(uint256 => uint256) public carMintBlock;

    struct StageConfig {
        uint8 requiredMinTier;
        uint32 requiredChassisMask;
        bool configured;
    }
    mapping(uint8 => StageConfig) public stageConfigs;
    mapping(uint8 => mapping(uint8 => uint256)) public checkpointLapTimeMaxMs;
    mapping(uint8 => uint8) public checkpointCountByStage;
    mapping(address => mapping(uint8 => bool)) public stageUnlockedByDriver;
    mapping(address => mapping(uint8 => uint8)) public checkpointReachedByDriver;
    mapping(uint8 => address) public stageLeader;
    mapping(uint8 => uint256) public stageBestLapMs;
    mapping(uint8 => uint256) public mintPriceByChassis;
    uint256 public treasuryBalance;
    uint8 public stageCount;
    uint8[] private _configuredStageIds;

    modifier whenNotPausedContract() {
        if (paused() || _pausedByRole) revert RPD_CollectionPaused();
        _;
    }

    modifier onlyPitBoss() {
        if (msg.sender != pitBoss && msg.sender != pitBossDeploy) revert RPD_NotPitBoss();
        _;
    }

    modifier onlyRaceDirector() {
        if (msg.sender != raceDirector && msg.sender != raceDirectorDeploy) revert RPD_NotRaceDirector();
        _;
    }

    constructor() ERC721("Reponator Driver", "RPD") {
        pitBossDeploy = address(0x4B2c6E8f0A3d5F7b9C1e4F6a8B0d2E5f7A9c1D4e6);
        raceDirectorDeploy = address(0x5C3d7F9a1B4e6D8f0A2c5E7b9D1f3A6c8E0b2D5f7);
        treasury = address(0x6D4e8F0a2B5c7E9d1F3a6C8e0B2d5F7a9C1e4D6f8);
        prizeVault = address(0x7E5f9A1b3C6d8F0a2B5e7D9f1A4c6E8b0D2f5A7c9);
        deployBlock = block.number;
        trackDomain = keccak256(abi.encodePacked(RPD_TRACK_SALT, block.chainid, block.timestamp, address(this)));
        pitBoss = pitBossDeploy;
        raceDirector = raceDirectorDeploy;
        nextTokenId = 1;
        mintPriceByChassis[0] = 0.02 ether;
        mintPriceByChassis[1] = 0.03 ether;
        mintPriceByChassis[2] = 0.05 ether;
    }

    function pauseCollection() external onlyPitBoss {
        _pausedByRole = true;
        emit CollectionPaused(msg.sender, block.number);
    }

    function unpauseCollection() external onlyPitBoss {
        _pausedByRole = false;
        emit CollectionUnpaused(msg.sender, block.number);
    }

    function setPitBoss(address newPitBoss) external onlyPitBoss {
        if (newPitBoss == address(0)) revert RPD_ZeroAddress();
        address prev = pitBoss;
        pitBoss = newPitBoss;
        emit PitBossUpdated(prev, newPitBoss);
    }

    function setRaceDirector(address newRaceDirector) external onlyPitBoss {
        if (newRaceDirector == address(0)) revert RPD_ZeroAddress();
        address prev = raceDirector;
        raceDirector = newRaceDirector;
        emit RaceDirectorUpdated(prev, newRaceDirector);
    }

    function setMintPrice(uint8 chassisType, uint256 priceWei) external onlyPitBoss {
        if (chassisType >= RPD_MAX_CHASSIS_TYPES) revert RPD_InvalidChassisType();
        uint256 prev = mintPriceByChassis[chassisType];
        mintPriceByChassis[chassisType] = priceWei;
        emit MintPriceSet(chassisType, prev, priceWei, block.number);
    }

    function setBaseURI(string calldata baseURI_) external onlyPitBoss {
        string memory prev = _baseTokenURI;
        _baseTokenURI = baseURI_;
        emit BaseURISet(prev, baseURI_, block.number);
    }

    function configureStage(uint8 stageId, uint8 requiredMinTier, uint32 requiredChassisMask) external onlyPitBoss {
        if (stageId >= RPD_MAX_STAGES) revert RPD_InvalidStageId();
        if (stageCount < RPD_MAX_STAGES && !stageConfigs[stageId].configured) {
            _configuredStageIds.push(stageId);
            stageCount++;
        }
        stageConfigs[stageId] = StageConfig({ requiredMinTier: requiredMinTier, requiredChassisMask: requiredChassisMask, configured: true });
        emit StageConfigured(stageId, requiredMinTier, requiredChassisMask, block.number);
    }

    function configureCheckpoint(uint8 stageId, uint8 checkpointIndex, uint256 lapTimeMaxMs) external onlyPitBoss {
        if (stageId >= RPD_MAX_STAGES) revert RPD_InvalidStageId();
        if (checkpointIndex >= RPD_MAX_CHECKPOINTS_PER_STAGE) revert RPD_MaxCheckpointsReached();
        checkpointLapTimeMaxMs[stageId][checkpointIndex] = lapTimeMaxMs;
