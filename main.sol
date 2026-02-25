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
        if (checkpointIndex >= checkpointCountByStage[stageId]) checkpointCountByStage[stageId] = checkpointIndex + 1;
        emit CheckpointConfigured(stageId, checkpointIndex, lapTimeMaxMs, block.number);
    }

    function _tokenQualifiesForStage(uint256 tokenId, uint8 stageId) internal view returns (bool) {
        if (stageId >= RPD_MAX_STAGES || !stageConfigs[stageId].configured) return false;
        StageConfig storage cfg = stageConfigs[stageId];
        uint8 chassis = carChassisType[tokenId];
        uint8 tier = carEngineTier[tokenId];
        if (tier < cfg.requiredMinTier) return false;
        if (cfg.requiredChassisMask != 0 && ((uint32(1) << chassis) & cfg.requiredChassisMask) == 0) return false;
        return true;
    }

    function mintCar(address to, uint8 chassisType, uint8 engineTier) external payable whenNotPausedContract nonReentrant returns (uint256 tokenId) {
        if (to == address(0)) revert RPD_ZeroAddress();
        if (chassisType >= RPD_MAX_CHASSIS_TYPES) revert RPD_InvalidChassisType();
        if (engineTier > RPD_MAX_ENGINE_TIER) revert RPD_InvalidEngineTier();
        if (nextTokenId > RPD_MAX_SUPPLY) revert RPD_MaxSupplyReached();
        uint256 price = mintPriceByChassis[chassisType];
        if (msg.value < price) revert RPD_InsufficientPayment();

        tokenId = nextTokenId++;
        carChassisType[tokenId] = chassisType;
        carEngineTier[tokenId] = engineTier;
        carMintBlock[tokenId] = block.number;
        _safeMint(to, tokenId);
        treasuryBalance += price;
        if (msg.value > price) {
            (bool refund,) = msg.sender.call{value: msg.value - price}("");
            if (!refund) revert RPD_TransferFailed();
        }
        emit CarMinted(tokenId, to, chassisType, engineTier, price, block.number);
        return tokenId;
    }

    function unlockStage(address driver, uint256 tokenId) external onlyRaceDirector whenNotPausedContract {
        if (ownerOf(tokenId) != driver) revert RPD_NotTokenOwner();
        uint8 stageId = 0;
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            stageId = _configuredStageIds[i];
            if (stageUnlockedByDriver[driver][stageId]) continue;
            if (!_tokenQualifiesForStage(tokenId, stageId)) revert RPD_TokenDoesNotQualify();
            stageUnlockedByDriver[driver][stageId] = true;
            emit StageUnlocked(driver, stageId, tokenId, block.number);
            return;
        }
        revert RPD_StageNotUnlocked();
    }

    function unlockStageExplicit(address driver, uint256 tokenId, uint8 stageId) external onlyRaceDirector whenNotPausedContract {
        if (ownerOf(tokenId) != driver) revert RPD_NotTokenOwner();
        if (!_tokenQualifiesForStage(tokenId, stageId)) revert RPD_TokenDoesNotQualify();
        if (stageUnlockedByDriver[driver][stageId]) return;
        stageUnlockedByDriver[driver][stageId] = true;
        emit StageUnlocked(driver, stageId, tokenId, block.number);
    }

    function recordLap(address driver, uint256 tokenId, uint8 stageId, uint256 lapTimeMs) external onlyRaceDirector whenNotPausedContract {
        if (ownerOf(tokenId) != driver) revert RPD_NotTokenOwner();
        if (!stageUnlockedByDriver[driver][stageId]) revert RPD_StageNotUnlocked();
        if (lapTimeMs > RPD_LAP_TIME_SCALE_MS) revert RPD_LapTimeTooHigh();
        uint256 maxMs = checkpointLapTimeMaxMs[stageId][checkpointReachedByDriver[driver][stageId]];
        if (maxMs > 0 && lapTimeMs > maxMs) revert RPD_LapTimeTooHigh();
        emit LapRecorded(driver, tokenId, stageId, lapTimeMs, block.number);
        if (stageBestLapMs[stageId] == 0 || lapTimeMs < stageBestLapMs[stageId]) {
            stageBestLapMs[stageId] = lapTimeMs;
            stageLeader[stageId] = driver;
            emit LeaderboardUpdated(stageId, driver, lapTimeMs, block.number);
        }
    }

    function reachCheckpoint(address driver, uint8 stageId, uint8 checkpointIndex, uint256 lapTimeMs) external onlyRaceDirector whenNotPausedContract {
        if (!stageUnlockedByDriver[driver][stageId]) revert RPD_StageNotUnlocked();
        if (checkpointIndex >= checkpointCountByStage[stageId]) revert RPD_InvalidCheckpointIndex();
        uint256 maxMs = checkpointLapTimeMaxMs[stageId][checkpointIndex];
        if (maxMs > 0 && lapTimeMs > maxMs) revert RPD_LapTimeTooHigh();
        if (checkpointReachedByDriver[driver][stageId] < checkpointIndex + 1)
            checkpointReachedByDriver[driver][stageId] = checkpointIndex + 1;
        emit CheckpointReached(driver, stageId, checkpointIndex, lapTimeMs, block.number);
    }

    function withdrawProceeds(address to, uint256 amountWei) external onlyPitBoss nonReentrant {
        if (to == address(0)) revert RPD_ZeroAddress();
        if (amountWei == 0) revert RPD_WithdrawZero();
        if (amountWei > treasuryBalance) revert RPD_InsufficientPayment();
        treasuryBalance -= amountWei;
        (bool ok,) = to.call{value: amountWei}("");
        if (!ok) revert RPD_TransferFailed();
        emit ProceedsWithdrawn(to, amountWei, block.number);
    }

    function getCar(uint256 tokenId) external view returns (uint8 chassisType, uint8 engineTier, uint256 mintBlock) {
        if (ownerOf(tokenId) == address(0) && tokenId >= nextTokenId) revert RPD_InvalidTokenId();
        return (carChassisType[tokenId], carEngineTier[tokenId], carMintBlock[tokenId]);
    }

    function tokenQualifiesForStage(uint256 tokenId, uint8 stageId) external view returns (bool) {
        return _tokenQualifiesForStage(tokenId, stageId);
    }

    function getDriverProgress(address driver) external view returns (uint8[] memory unlockedStages, uint8[] memory checkpointsReached) {
        uint8[] memory stages = new uint8[](_configuredStageIds.length);
        uint8[] memory cps = new uint8[](_configuredStageIds.length);
        uint256 j = 0;
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            uint8 sid = _configuredStageIds[i];
            if (stageUnlockedByDriver[driver][sid]) {
                stages[j] = sid;
                cps[j] = checkpointReachedByDriver[driver][sid];
                j++;
            }
        }
        unlockedStages = new uint8[](j);
        checkpointsReached = new uint8[](j);
        for (uint256 k = 0; k < j; k++) {
            unlockedStages[k] = stages[k];
            checkpointsReached[k] = cps[k];
        }
        return (unlockedStages, checkpointsReached);
    }

    function getStageLeader(uint8 stageId) external view returns (address driver, uint256 bestLapMs) {
        return (stageLeader[stageId], stageBestLapMs[stageId]);
    }

    function getConfiguredStageIds() external view returns (uint8[] memory) {
        return _configuredStageIds;
    }

    function getStageConfig(uint8 stageId) external view returns (uint8 requiredMinTier, uint32 requiredChassisMask, bool configured) {
        StageConfig storage c = stageConfigs[stageId];
        return (c.requiredMinTier, c.requiredChassisMask, c.configured);
    }

    function paused() public view virtual override returns (bool) {
        return _pausedByRole || super.paused();
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    receive() external payable {
        treasuryBalance += msg.value;
    }

    // -------------------------------------------------------------------------
    // BATCH MINT
    // -------------------------------------------------------------------------

    function mintCarBatch(address to, uint8[] calldata chassisTypes, uint8[] calldata engineTiers) external payable whenNotPausedContract nonReentrant returns (uint256[] memory tokenIds) {
        if (to == address(0)) revert RPD_ZeroAddress();
        uint256 n = chassisTypes.length;
        if (n != engineTiers.length) revert RPD_ArrayLengthMismatch();
        if (n > RPD_BATCH_MINT_CAP) revert RPD_BatchTooLarge();
        if (nextTokenId + n - 1 > RPD_MAX_SUPPLY) revert RPD_MaxSupplyReached();
        uint256 totalPrice = 0;
        for (uint256 i = 0; i < n; i++) {
            if (chassisTypes[i] >= RPD_MAX_CHASSIS_TYPES) revert RPD_InvalidChassisType();
            if (engineTiers[i] > RPD_MAX_ENGINE_TIER) revert RPD_InvalidEngineTier();
            totalPrice += mintPriceByChassis[chassisTypes[i]];
        }
        if (msg.value < totalPrice) revert RPD_InsufficientPayment();
        tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = nextTokenId++;
            carChassisType[tokenId] = chassisTypes[i];
            carEngineTier[tokenId] = engineTiers[i];
            carMintBlock[tokenId] = block.number;
            _safeMint(to, tokenId);
            tokenIds[i] = tokenId;
            emit CarMinted(tokenId, to, chassisTypes[i], engineTiers[i], mintPriceByChassis[chassisTypes[i]], block.number);
        }
        treasuryBalance += totalPrice;
        if (msg.value > totalPrice) {
            (bool refund,) = msg.sender.call{value: msg.value - totalPrice}("");
            if (!refund) revert RPD_TransferFailed();
        }
        emit BatchMinted(to, tokenIds, totalPrice, block.number);
        return tokenIds;
    }

    // -------------------------------------------------------------------------
    // VIEWS: PROGRESSION & LEADERBOARD
    // -------------------------------------------------------------------------

    function isStageUnlocked(address driver, uint8 stageId) external view returns (bool) {
        return stageUnlockedByDriver[driver][stageId];
    }

    function getCheckpointReached(address driver, uint8 stageId) external view returns (uint8) {
        return checkpointReachedByDriver[driver][stageId];
    }

    function getCheckpointMaxTime(uint8 stageId, uint8 checkpointIndex) external view returns (uint256) {
        return checkpointLapTimeMaxMs[stageId][checkpointIndex];
    }

    function getCheckpointCount(uint8 stageId) external view returns (uint8) {
        return checkpointCountByStage[stageId];
    }

    function getTreasuryBalance() external view returns (uint256) {
        return treasuryBalance;
    }

    function getMintPrice(uint8 chassisType) external view returns (uint256) {
        if (chassisType >= RPD_MAX_CHASSIS_TYPES) return 0;
        return mintPriceByChassis[chassisType];
    }

    function getTotalMinted() external view returns (uint256) {
        return nextTokenId - 1;
    }

    function getTrackDomain() external view returns (bytes32) {
        return trackDomain;
    }

    function getImmutableAddresses() external view returns (address pitBoss_, address raceDirector_, address treasury_, address prizeVault_) {
        return (pitBossDeploy, raceDirectorDeploy, treasury, prizeVault);
    }

    function getDeployBlock() external view returns (uint256) {
        return deployBlock;
    }

    function getLeaderboardSlice(uint8 fromStageId, uint8 toStageId) external view returns (
        uint8[] memory stageIds,
        address[] memory leaders,
        uint256[] memory bestLapsMs
    ) {
        if (toStageId > fromStageId + 32) toStageId = uint8(fromStageId + 32);
        if (toStageId >= RPD_MAX_STAGES) toStageId = uint8(RPD_MAX_STAGES - 1);
        uint256 n = toStageId >= fromStageId ? toStageId - fromStageId + 1 : 0;
        stageIds = new uint8[](n);
        leaders = new address[](n);
        bestLapsMs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 sid = uint8(fromStageId + i);
            stageIds[i] = sid;
            leaders[i] = stageLeader[sid];
            bestLapsMs[i] = stageBestLapMs[sid];
        }
        return (stageIds, leaders, bestLapsMs);
    }

    function getCarsByOwner(address owner) external view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(owner);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        return tokenIds;
    }

    function getCarTraits(uint256 tokenId) external view returns (uint8 chassis, uint8 engineTier, uint256 mintBlock) {
        return (carChassisType[tokenId], carEngineTier[tokenId], carMintBlock[tokenId]);
    }

    function getQualifyingTokensForStage(address owner, uint8 stageId) external view returns (uint256[] memory tokenIds) {
        uint256 bal = balanceOf(owner);
        uint256[] memory temp = new uint256[](bal);
        uint256 count = 0;
        for (uint256 i = 0; i < bal; i++) {
            uint256 tid = tokenOfOwnerByIndex(owner, i);
            if (_tokenQualifiesForStage(tid, stageId)) {
                temp[count] = tid;
                count++;
            }
        }
        tokenIds = new uint256[](count);
        for (uint256 j = 0; j < count; j++) tokenIds[j] = temp[j];
        return tokenIds;
    }

    function getFrontendConfig() external view returns (
        address pitBoss_,
        address raceDirector_,
        uint256 totalMinted_,
        uint256 treasuryBalance_,
        bool paused_,
        uint256 deployBlock_
    ) {
        return (pitBoss, raceDirector, nextTokenId - 1, treasuryBalance, paused(), deployBlock);
    }

    // -------------------------------------------------------------------------
    // GAS ESTIMATES
    // -------------------------------------------------------------------------

    uint256 public constant RPD_EST_MINT = 120000;
    uint256 public constant RPD_EST_BATCH_PER = 95000;
    uint256 public constant RPD_EST_UNLOCK_STAGE = 65000;
    uint256 public constant RPD_EST_RECORD_LAP = 55000;
    uint256 public constant RPD_EST_WITHDRAW = 38000;

    function estimateMintGas() external pure returns (uint256) { return RPD_EST_MINT; }
    function estimateBatchMintGas(uint256 count) external pure returns (uint256) {
        if (count > RPD_BATCH_MINT_CAP) count = RPD_BATCH_MINT_CAP;
        return RPD_EST_MINT + (count - 1) * RPD_EST_BATCH_PER;
    }

    // -------------------------------------------------------------------------
    // STAGE BATCH CONFIG
    // -------------------------------------------------------------------------

    function configureStagesBatch(
        uint8[] calldata stageIds,
        uint8[] calldata requiredMinTiers,
        uint32[] calldata requiredChassisMasks
    ) external onlyPitBoss {
        if (stageIds.length != requiredMinTiers.length || stageIds.length != requiredChassisMasks.length) revert RPD_ArrayLengthMismatch();
        if (stageIds.length > 24) revert RPD_BatchTooLarge();
        for (uint256 i = 0; i < stageIds.length; i++) {
            uint8 sid = stageIds[i];
            if (sid >= RPD_MAX_STAGES) continue;
            if (!stageConfigs[sid].configured && stageCount < RPD_MAX_STAGES) {
                _configuredStageIds.push(sid);
                stageCount++;
            }
            stageConfigs[sid] = StageConfig({
                requiredMinTier: requiredMinTiers[i],
                requiredChassisMask: requiredChassisMasks[i],
                configured: true
            });
            emit StageConfigured(sid, requiredMinTiers[i], requiredChassisMasks[i], block.number);
        }
    }

    // -------------------------------------------------------------------------
    // ROLE CHECKS
    // -------------------------------------------------------------------------

    function isPitBoss(address account) external view returns (bool) {
        return account == pitBoss || account == pitBossDeploy;
    }

    function isRaceDirector(address account) external view returns (bool) {
        return account == raceDirector || account == raceDirectorDeploy;
    }

    function isTreasury(address account) external view returns (bool) {
        return account == treasury;
    }

    function isPrizeVault(address account) external view returns (bool) {
        return account == prizeVault;
    }

    // -------------------------------------------------------------------------
    // CONSTANTS EXPORT
    // -------------------------------------------------------------------------

    function getConstants() external pure returns (
        uint256 maxSupply,
        uint256 maxChassisTypes,
        uint256 maxEngineTier,
        uint256 maxStages,
        uint256 maxCheckpointsPerStage,
        uint256 batchMintCap
    ) {
        return (RPD_MAX_SUPPLY, RPD_MAX_CHASSIS_TYPES, RPD_MAX_ENGINE_TIER, RPD_MAX_STAGES, RPD_MAX_CHECKPOINTS_PER_STAGE, RPD_BATCH_MINT_CAP);
    }

    // -------------------------------------------------------------------------
    // PROGRESSION HELPERS
    // -------------------------------------------------------------------------

    function canUnlockNextStage(address driver) external view returns (bool canUnlock, uint8 nextStageId) {
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            uint8 sid = _configuredStageIds[i];
            if (!stageUnlockedByDriver[driver][sid]) {
                return (true, sid);
            }
        }
        return (false, 0);
    }

    function getStagesUnlockedCount(address driver) external view returns (uint256 count) {
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            if (stageUnlockedByDriver[driver][_configuredStageIds[i]]) count++;
        }
        return count;
    }

    function getTotalCheckpointsReached(address driver) external view returns (uint256 total) {
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            total += checkpointReachedByDriver[driver][_configuredStageIds[i]];
        }
        return total;
    }

    // -------------------------------------------------------------------------
    // TOKEN ID RANGE
    // -------------------------------------------------------------------------

    function getTokenIdRange() external view returns (uint256 minId, uint256 maxId, uint256 nextId) {
        return (1, nextTokenId - 1, nextTokenId);
    }

    function carExists(uint256 tokenId) external view returns (bool) {
        return tokenId > 0 && tokenId < nextTokenId;
    }

    // -------------------------------------------------------------------------
    // MINT PRICES BATCH VIEW
    // -------------------------------------------------------------------------

    function getMintPricesBatch(uint8 fromChassis, uint8 toChassis) external view returns (uint8[] memory types, uint256[] memory prices) {
        if (toChassis > fromChassis + 32) toChassis = uint8(fromChassis + 32);
        if (toChassis >= RPD_MAX_CHASSIS_TYPES) toChassis = uint8(RPD_MAX_CHASSIS_TYPES - 1);
        uint256 n = toChassis >= fromChassis ? toChassis - fromChassis + 1 : 0;
        types = new uint8[](n);
        prices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 ct = uint8(fromChassis + i);
            types[i] = ct;
            prices[i] = mintPriceByChassis[ct];
        }
        return (types, prices);
    }

    // -------------------------------------------------------------------------
    // CHECKPOINT CONFIG BATCH VIEW
    // -------------------------------------------------------------------------

    function getCheckpointConfigs(uint8 stageId) external view returns (uint8[] memory indices, uint256[] memory maxTimesMs) {
        uint8 count = checkpointCountByStage[stageId];
        indices = new uint8[](count);
        maxTimesMs = new uint256[](count);
        for (uint8 i = 0; i < count; i++) {
            indices[i] = i;
            maxTimesMs[i] = checkpointLapTimeMaxMs[stageId][i];
        }
        return (indices, maxTimesMs);
    }

    // -------------------------------------------------------------------------
    // UNLOCK STAGE BATCH (race director unlocks for multiple drivers)
    // -------------------------------------------------------------------------

    function unlockStageBatch(address[] calldata drivers, uint256[] calldata tokenIds, uint8[] calldata stageIds) external onlyRaceDirector whenNotPausedContract {
        if (drivers.length != tokenIds.length || drivers.length != stageIds.length) revert RPD_ArrayLengthMismatch();
        if (drivers.length > RPD_BATCH_MINT_CAP) revert RPD_BatchTooLarge();
        for (uint256 i = 0; i < drivers.length; i++) {
            if (ownerOf(tokenIds[i]) != drivers[i]) continue;
            if (!_tokenQualifiesForStage(tokenIds[i], stageIds[i])) continue;
            if (stageUnlockedByDriver[drivers[i]][stageIds[i]]) continue;
            stageUnlockedByDriver[drivers[i]][stageIds[i]] = true;
            emit StageUnlocked(drivers[i], stageIds[i], tokenIds[i], block.number);
        }
    }

    // -------------------------------------------------------------------------
    // RECORD LAP BATCH
    // -------------------------------------------------------------------------

    function recordLapBatch(
        address[] calldata drivers,
        uint256[] calldata tokenIds,
        uint8[] calldata stageIds,
        uint256[] calldata lapTimesMs
    ) external onlyRaceDirector whenNotPausedContract {
        if (drivers.length != tokenIds.length || drivers.length != stageIds.length || drivers.length != lapTimesMs.length) revert RPD_ArrayLengthMismatch();
        if (drivers.length > RPD_BATCH_MINT_CAP) revert RPD_BatchTooLarge();
        for (uint256 i = 0; i < drivers.length; i++) {
            if (ownerOf(tokenIds[i]) != drivers[i]) continue;
            if (!stageUnlockedByDriver[drivers[i]][stageIds[i]]) continue;
            if (lapTimesMs[i] > RPD_LAP_TIME_SCALE_MS) continue;
            uint8 cp = checkpointReachedByDriver[drivers[i]][stageIds[i]];
            uint256 maxMs = checkpointLapTimeMaxMs[stageIds[i]][cp];
            if (maxMs > 0 && lapTimesMs[i] > maxMs) continue;
            emit LapRecorded(drivers[i], tokenIds[i], stageIds[i], lapTimesMs[i], block.number);
            if (stageBestLapMs[stageIds[i]] == 0 || lapTimesMs[i] < stageBestLapMs[stageIds[i]]) {
                stageBestLapMs[stageIds[i]] = lapTimesMs[i];
                stageLeader[stageIds[i]] = drivers[i];
                emit LeaderboardUpdated(stageIds[i], drivers[i], lapTimesMs[i], block.number);
            }
        }
    }

    // -------------------------------------------------------------------------
    // PAGINATION & ENUMERATION
    // -------------------------------------------------------------------------

    function getTokenIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory tokenIds, uint256 total) {
        total = nextTokenId > 1 ? nextTokenId - 1 : 0;
        if (offset >= total) return (new uint256[](0), total);
        uint256 remain = total - offset;
        if (limit > remain) limit = remain;
        if (limit > 64) limit = 64;
        tokenIds = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) tokenIds[i] = offset + i + 1;
        return (tokenIds, total);
    }

    function getCarsPaginated(uint256 offset, uint256 limit) external view returns (
        uint256[] memory tokenIds,
        uint8[] memory chassisTypes,
        uint8[] memory engineTiers,
        uint256 total
    ) {
        total = nextTokenId > 1 ? nextTokenId - 1 : 0;
        if (offset >= total) return (new uint256[](0), new uint8[](0), new uint8[](0), total);
        uint256 remain = total - offset;
        if (limit > remain) limit = remain;
        if (limit > 32) limit = 32;
        tokenIds = new uint256[](limit);
        chassisTypes = new uint8[](limit);
        engineTiers = new uint8[](limit);
        for (uint256 i = 0; i < limit; i++) {
            uint256 tid = offset + i + 1;
            tokenIds[i] = tid;
            chassisTypes[i] = carChassisType[tid];
            engineTiers[i] = carEngineTier[tid];
        }
        return (tokenIds, chassisTypes, engineTiers, total);
    }

    // -------------------------------------------------------------------------
    // STAGE STATS
    // -------------------------------------------------------------------------

    function getStageStats(uint8 stageId) external view returns (
        address leader,
        uint256 bestLapMs,
        bool configured,
        uint8 checkpointCount
    ) {
        StageConfig storage c = stageConfigs[stageId];
        return (stageLeader[stageId], stageBestLapMs[stageId], c.configured, checkpointCountByStage[stageId]);
    }

    function getAllStageLeaders() external view returns (uint8[] memory stageIds, address[] memory leaders, uint256[] memory bestLapsMs) {
        uint256 n = _configuredStageIds.length;
        stageIds = new uint8[](n);
        leaders = new address[](n);
        bestLapsMs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint8 sid = _configuredStageIds[i];
            stageIds[i] = sid;
            leaders[i] = stageLeader[sid];
            bestLapsMs[i] = stageBestLapMs[sid];
        }
        return (stageIds, leaders, bestLapsMs);
    }

    // -------------------------------------------------------------------------
    // DRIVER STATS
    // -------------------------------------------------------------------------

    function getDriverStageProgress(address driver, uint8 stageId) external view returns (
        bool unlocked,
        uint8 checkpointsReached,
        uint8 checkpointCount
    ) {
        return (
            stageUnlockedByDriver[driver][stageId],
            checkpointReachedByDriver[driver][stageId],
            checkpointCountByStage[stageId]
        );
    }

    function getDriverFullProgress(address driver) external view returns (
        uint8[] memory unlockedStageIds,
        uint8[] memory checkpointsPerStage,
        uint256 carCount
    ) {
        carCount = balanceOf(driver);
        uint256 n = 0;
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            if (stageUnlockedByDriver[driver][_configuredStageIds[i]]) n++;
        }
        unlockedStageIds = new uint8[](n);
        checkpointsPerStage = new uint8[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            uint8 sid = _configuredStageIds[i];
            if (stageUnlockedByDriver[driver][sid]) {
                unlockedStageIds[j] = sid;
                checkpointsPerStage[j] = checkpointReachedByDriver[driver][sid];
                j++;
            }
        }
        return (unlockedStageIds, checkpointsPerStage, carCount);
    }

    // -------------------------------------------------------------------------
    // MULTI-GET CARS
    // -------------------------------------------------------------------------

    function getCarsTraits(uint256[] calldata tokenIds) external view returns (
        uint8[] memory chassisTypes,
        uint8[] memory engineTiers,
        uint256[] memory mintBlocks
    ) {
        uint256 n = tokenIds.length;
        if (n > 64) n = 64;
        chassisTypes = new uint8[](n);
        engineTiers = new uint8[](n);
        mintBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            chassisTypes[i] = carChassisType[tokenIds[i]];
            engineTiers[i] = carEngineTier[tokenIds[i]];
            mintBlocks[i] = carMintBlock[tokenIds[i]];
        }
        return (chassisTypes, engineTiers, mintBlocks);
    }

    // -------------------------------------------------------------------------
    // BASE URI & METADATA
    // -------------------------------------------------------------------------

    function getBaseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    // -------------------------------------------------------------------------
    // TREASURY & FEE
    // -------------------------------------------------------------------------

    function getTreasuryAddress() external view returns (address) {
        return treasury;
    }

    function getPrizeVaultAddress() external view returns (address) {
        return prizeVault;
    }

    // -------------------------------------------------------------------------
    // OPERATIONAL
    // -------------------------------------------------------------------------

    function isOperational() external view returns (bool) {
        return !paused();
    }

    function getPitBoss() external view returns (address) {
        return pitBoss;
    }

    function getRaceDirector() external view returns (address) {
        return raceDirector;
    }

    // -------------------------------------------------------------------------
    // DOMAIN & DEPLOY
    // -------------------------------------------------------------------------

    function getTrackDomainSalt() external pure returns (bytes32) {
        return RPD_TRACK_SALT;
    }

    function getDeployMetadata() external view returns (uint256 blockNum, bytes32 domain) {
        return (deployBlock, trackDomain);
    }

    // -------------------------------------------------------------------------
    // QUALIFY CHECK BATCH
    // -------------------------------------------------------------------------

    function getQualifyStatusForStages(uint256 tokenId, uint8[] calldata stageIds) external view returns (bool[] memory qualifies) {
        uint256 n = stageIds.length;
        if (n > 32) n = 32;
        qualifies = new bool[](n);
        for (uint256 i = 0; i < n; i++) qualifies[i] = _tokenQualifiesForStage(tokenId, stageIds[i]);
        return qualifies;
    }

    // -------------------------------------------------------------------------
    // NEXT STAGE FOR DRIVER (first locked stage id)
    // -------------------------------------------------------------------------

    function getNextLockedStageId(address driver) external view returns (uint8 stageId, bool found) {
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            uint8 sid = _configuredStageIds[i];
            if (!stageUnlockedByDriver[driver][sid]) return (sid, true);
        }
        return (0, false);
    }

    // -------------------------------------------------------------------------
    // CHASSIS / TIER COUNTS (for analytics)
    // -------------------------------------------------------------------------

    function getMintedCountByChassis(uint8 chassisType) external view returns (uint256 count) {
        if (chassisType >= RPD_MAX_CHASSIS_TYPES) return 0;
        for (uint256 tid = 1; tid < nextTokenId; tid++) {
            if (carChassisType[tid] == chassisType) count++;
        }
        return count;
    }

    function getMintedCountByTier(uint8 engineTier) external view returns (uint256 count) {
        if (engineTier > RPD_MAX_ENGINE_TIER) return 0;
        for (uint256 tid = 1; tid < nextTokenId; tid++) {
            if (carEngineTier[tid] == engineTier) count++;
        }
        return count;
    }

    // -------------------------------------------------------------------------
    // SUPPLY REMAINING
    // -------------------------------------------------------------------------

    function getSupplyRemaining() external view returns (uint256) {
        if (nextTokenId > RPD_MAX_SUPPLY) return 0;
        return RPD_MAX_SUPPLY - (nextTokenId - 1);
    }

    function isMaxSupplyReached() external view returns (bool) {
        return nextTokenId > RPD_MAX_SUPPLY;
    }

    // -------------------------------------------------------------------------
    // PAUSE STATE
    // -------------------------------------------------------------------------

    function isPausedByRole() external view returns (bool) {
        return _pausedByRole;
    }

    // -------------------------------------------------------------------------
    // BATCH UNLOCK (convenience for race director)
    // -------------------------------------------------------------------------

    function unlockStageForDriverWithToken(address driver, uint256 tokenId) external onlyRaceDirector whenNotPausedContract {
        if (ownerOf(tokenId) != driver) revert RPD_NotTokenOwner();
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            uint8 sid = _configuredStageIds[i];
            if (stageUnlockedByDriver[driver][sid]) continue;
            if (!_tokenQualifiesForStage(tokenId, sid)) continue;
            stageUnlockedByDriver[driver][sid] = true;
            emit StageUnlocked(driver, sid, tokenId, block.number);
            return;
        }
    }

    // -------------------------------------------------------------------------
    // REACH CHECKPOINT BATCH
    // -------------------------------------------------------------------------

    function reachCheckpointBatch(
        address[] calldata drivers,
        uint8[] calldata stageIds,
        uint8[] calldata checkpointIndices,
        uint256[] calldata lapTimesMs
    ) external onlyRaceDirector whenNotPausedContract {
        if (drivers.length != stageIds.length || drivers.length != checkpointIndices.length || drivers.length != lapTimesMs.length) revert RPD_ArrayLengthMismatch();
        if (drivers.length > RPD_BATCH_MINT_CAP) revert RPD_BatchTooLarge();
        for (uint256 i = 0; i < drivers.length; i++) {
            if (!stageUnlockedByDriver[drivers[i]][stageIds[i]]) continue;
            if (checkpointIndices[i] >= checkpointCountByStage[stageIds[i]]) continue;
            uint256 maxMs = checkpointLapTimeMaxMs[stageIds[i]][checkpointIndices[i]];
            if (maxMs > 0 && lapTimesMs[i] > maxMs) continue;
            if (checkpointReachedByDriver[drivers[i]][stageIds[i]] < checkpointIndices[i] + 1)
                checkpointReachedByDriver[drivers[i]][stageIds[i]] = checkpointIndices[i] + 1;
            emit CheckpointReached(drivers[i], stageIds[i], checkpointIndices[i], lapTimesMs[i], block.number);
        }
    }

    // -------------------------------------------------------------------------
    // STAGE CONFIG BATCH VIEW
    // -------------------------------------------------------------------------

    function getStageConfigsBatch(uint8[] calldata stageIds) external view returns (
        uint8[] memory requiredMinTiers,
        uint32[] memory requiredChassisMasks,
        bool[] memory configured
    ) {
        uint256 n = stageIds.length;
        if (n > 32) n = 32;
        requiredMinTiers = new uint8[](n);
        requiredChassisMasks = new uint32[](n);
        configured = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            StageConfig storage c = stageConfigs[stageIds[i]];
            requiredMinTiers[i] = c.requiredMinTier;
            requiredChassisMasks[i] = c.requiredChassisMask;
            configured[i] = c.configured;
        }
        return (requiredMinTiers, requiredChassisMasks, configured);
    }

    // -------------------------------------------------------------------------
    // OWNER OF TOKEN (convenience)
    // -------------------------------------------------------------------------

    function getOwnerOfCar(uint256 tokenId) external view returns (address) {
        return ownerOf(tokenId);
    }

    // -------------------------------------------------------------------------
    // ESTIMATE MINT COST
    // -------------------------------------------------------------------------

    function estimateMintCost(uint8 chassisType) external view returns (uint256 weiAmount) {
        return mintPriceByChassis[chassisType];
    }

    function estimateBatchMintCost(uint8[] calldata chassisTypes, uint8[] calldata engineTiers) external view returns (uint256 totalWei) {
        if (chassisTypes.length != engineTiers.length) return 0;
        for (uint256 i = 0; i < chassisTypes.length; i++) {
            if (chassisTypes[i] >= RPD_MAX_CHASSIS_TYPES || engineTiers[i] > RPD_MAX_ENGINE_TIER) continue;
            totalWei += mintPriceByChassis[chassisTypes[i]];
        }
        return totalWei;
    }

    // -------------------------------------------------------------------------
    // STAGE COUNT VIEW
    // -------------------------------------------------------------------------

    function getStageCount() external view returns (uint8) {
        return stageCount;
    }

    // -------------------------------------------------------------------------
    // CHECKPOINT MAX TIMES FOR STAGE (full array)
    // -------------------------------------------------------------------------

    function getCheckpointMaxTimes(uint8 stageId) external view returns (uint256[] memory maxTimesMs) {
        uint8 count = checkpointCountByStage[stageId];
        maxTimesMs = new uint256[](count);
        for (uint8 i = 0; i < count; i++) maxTimesMs[i] = checkpointLapTimeMaxMs[stageId][i];
        return maxTimesMs;
    }

    // -------------------------------------------------------------------------
    // DRIVER QUALIFYING TOKEN COUNT FOR STAGE
    // -------------------------------------------------------------------------

    function getQualifyingTokenCount(address owner, uint8 stageId) external view returns (uint256 count) {
        uint256 bal = balanceOf(owner);
        for (uint256 i = 0; i < bal; i++) {
            if (_tokenQualifiesForStage(tokenOfOwnerByIndex(owner, i), stageId)) count++;
        }
        return count;
    }

    // -------------------------------------------------------------------------
    // HAS DRIVER UNLOCKED ANY STAGE
    // -------------------------------------------------------------------------

    function hasDriverUnlockedAnyStage(address driver) external view returns (bool) {
        for (uint256 i = 0; i < _configuredStageIds.length; i++) {
            if (stageUnlockedByDriver[driver][_configuredStageIds[i]]) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // LAST MINTED TOKEN ID
    // -------------------------------------------------------------------------

    function getLastMintedTokenId() external view returns (uint256) {
        if (nextTokenId <= 1) return 0;
        return nextTokenId - 1;
    }

    /// @notice Returns whether a token ID is in the minted range (1 to nextTokenId-1).
    function isValidToken(uint256 tokenId) external view returns (bool) {
        return tokenId >= 1 && tokenId < nextTokenId;
    }

    /// @notice Returns the chassis type name index (0-31) for a token.
    function getChassisType(uint256 tokenId) external view returns (uint8) {
        return carChassisType[tokenId];
    }

    /// @notice Returns the engine tier (0-7) for a token.
    function getEngineTier(uint256 tokenId) external view returns (uint8) {
        return carEngineTier[tokenId];
    }

    /// @notice Returns the block number when the car was minted.
    function getMintBlock(uint256 tokenId) external view returns (uint256) {
        return carMintBlock[tokenId];
    }

    /// @notice Returns the number of stages currently configured.
    function getConfiguredStagesCount() external view returns (uint256) {
        return _configuredStageIds.length;
    }

    /// @notice Returns RPD_TRACK_SALT for verification.
    function getTrackSalt() external pure returns (bytes32) {
        return RPD_TRACK_SALT;
    }

    /// @notice Returns max supply constant.
    function getMaxSupply() external pure returns (uint256) {
        return RPD_MAX_SUPPLY;
    }

    /// @notice Returns batch mint cap.
    function getBatchMintCap() external pure returns (uint256) {
        return RPD_BATCH_MINT_CAP;
    }

    /// @notice Returns lap time scale (max allowed lap time in ms).
    function getLapTimeScaleMs() external pure returns (uint256) {
        return RPD_LAP_TIME_SCALE_MS;
    }

    /// @notice Returns whether the collection is paused (role or OZ Pausable).
    function getPaused() external view returns (bool) {
        return paused();
    }

    /// @notice Returns pit boss deploy address (immutable).
    function getPitBossDeploy() external view returns (address) {
        return pitBossDeploy;
    }

    /// @notice Returns race director deploy address (immutable).
    function getRaceDirectorDeploy() external view returns (address) {
        return raceDirectorDeploy;
    }
}

