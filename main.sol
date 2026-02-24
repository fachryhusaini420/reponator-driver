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
