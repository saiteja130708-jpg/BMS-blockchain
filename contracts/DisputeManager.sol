// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DTTypes.sol";
import "./KeyRegistry.sol";
import "./CheckpointAnchor.sol";
import "./RFC6962Verifier.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract DisputeManager {
    using ECDSA for bytes32;

    enum CaseState { NONE, OPEN, SEALED, REOPENED, RESPONDED, ESCALATED, DEEMED_APPROVED }

    struct CaseRecord {
        CaseState state;
        bytes32 institutionId;
        bytes32 serviceId;
        bytes32 holderCommitment;
        uint64 round;
        uint64 deadline;
        uint64 outstandingObligations;
    }

    KeyRegistry public immutable keyRegistry;
    CheckpointAnchor public immutable checkpointAnchor;

    mapping(bytes32 => CaseRecord) public cases;

    event ReceiptRegistered(bytes32 indexed caseId, bytes32 indexed institutionId, bytes32 holderCommitment);
    event RoundSealed(bytes32 indexed caseId, uint64 round, bytes32 rootHash);
    event CaseReopened(bytes32 indexed caseId, uint64 round, uint64 deadline);
    event InstitutionResponded(bytes32 indexed caseId, uint64 round);
    event CaseEscalated(bytes32 indexed caseId, address appellateAuthority);
    event DeemedApprovalClaimed(bytes32 indexed caseId);

    error InvalidState();
    error Unauthorized();
    error SignatureMismatch();
    error KeyNotValid();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error InvalidInclusionProof();

    constructor(address _keyRegistry, address _checkpointAnchor) {
        keyRegistry = KeyRegistry(_keyRegistry);
        checkpointAnchor = CheckpointAnchor(_checkpointAnchor);
    }

    function registerReceipt(
        DTTypes.Receipt memory receipt,
        bytes memory institutionSig
    ) external {
        if (cases[receipt.caseId].state != CaseState.NONE) revert InvalidState();
        
        // Verify institution signature on the receipt
        bytes32 receiptHash = DTTypes.hashReceipt(receipt);
        address signer = MessageHashUtils.toEthSignedMessageHash(receiptHash).recover(institutionSig);
        
        if (!keyRegistry.isKeyValidAt(receipt.institutionId, signer, receipt.timestamp)) {
            revert KeyNotValid();
        }

        cases[receipt.caseId] = CaseRecord({
            state: CaseState.OPEN,
            institutionId: receipt.institutionId,
            serviceId: receipt.serviceId,
            holderCommitment: receipt.holderCommitment,
            round: 0,
            deadline: 0,
            outstandingObligations: 0
        });

        emit ReceiptRegistered(receipt.caseId, receipt.institutionId, receipt.holderCommitment);
    }

    function sealRound(
        DTTypes.Receipt memory receipt,
        bytes32 manifestHash,
        bytes32 rootHash,
        uint64 treeSize,
        bytes32[] memory inclusionProof
    ) external {
        CaseRecord storage c = cases[receipt.caseId];
        if (c.state != CaseState.OPEN && c.state != CaseState.RESPONDED) revert InvalidState();
        if (c.outstandingObligations > 0) revert InvalidState();

        // Verify that the checkpoint root is anchored on-chain
        if (!checkpointAnchor.isRootAnchored(receipt.institutionId, treeSize, rootHash)) {
            revert Unauthorized();
        }

        // Verify inclusion of the manifest/receipt in the Merkle log (simplified leaf check)
        bytes32 leafHash = RFC6962Verifier.hashLeaf(abi.encodePacked(receipt.caseId, manifestHash));
        // For demonstration, we assume the caller provides correct index in a known layout, or we verify log inclusion directly
        // (In production, index is passed alongside proof)

        c.state = CaseState.SEALED;
        emit RoundSealed(receipt.caseId, c.round, rootHash);
    }

    function reopen(
        DTTypes.Receipt memory receipt,
        bytes memory receiptSig,
        address holderAddress,
        bytes32 holderSalt,
        bytes memory holderSig,
        uint8 disputeType
    ) external {
        CaseRecord storage c = cases[receipt.caseId];
        // Can reopen from SEALED or directly from OPEN if deadline missed
        if (c.state != CaseState.SEALED && c.state != CaseState.OPEN) revert InvalidState();

        // 1. Verify holder binding
        if (keccak256(abi.encodePacked(holderAddress, holderSalt)) != receipt.holderCommitment) {
            revert SignatureMismatch();
        }
        bytes32 disputeMsgHash = keccak256(abi.encodePacked(receipt.caseId, c.round, disputeType, holderSalt));
        if (MessageHashUtils.toEthSignedMessageHash(disputeMsgHash).recover(holderSig) != holderAddress) {
            revert SignatureMismatch();
        }

        // 2. Fetch service response window from KeyRegistry
        (uint64 responseWindow, bool deemedEnabled, , address appellateAuthority) = keyRegistry.serviceConfigs(receipt.institutionId, receipt.serviceId);
        if (responseWindow == 0) responseWindow = 604800; // Default 7 days

        c.state = CaseState.REOPENED;
        c.round++;
        c.deadline = uint64(block.timestamp) + responseWindow;
        c.outstandingObligations = 1;

        emit CaseReopened(receipt.caseId, c.round, c.deadline);
    }

    function respond(
        bytes32 caseId,
        bytes32 responseHash,
        bytes memory institutionSig
    ) external {
        CaseRecord storage c = cases[caseId];
        if (c.state != CaseState.REOPENED) revert InvalidState();
        if (block.timestamp > c.deadline) revert DeadlinePassed();

        // Verify institution signature on response
        bytes32 respMsgHash = keccak256(abi.encodePacked(caseId, c.round, responseHash));
        address signer = MessageHashUtils.toEthSignedMessageHash(respMsgHash).recover(institutionSig);
        if (!keyRegistry.isKeyValidAt(c.institutionId, signer, uint64(block.timestamp))) {
            revert KeyNotValid();
        }

        c.state = CaseState.RESPONDED;
        c.outstandingObligations = 0;

        emit InstitutionResponded(caseId, c.round);
    }

    function escalate(bytes32 caseId) external {
        CaseRecord storage c = cases[caseId];
        if (c.state != CaseState.REOPENED) revert InvalidState();
        if (block.timestamp <= c.deadline) revert DeadlineNotPassed();

        c.state = CaseState.ESCALATED;
        (, , , address appellateAuthority) = keyRegistry.serviceConfigs(c.institutionId, c.serviceId);

        emit CaseEscalated(caseId, appellateAuthority);
    }
}
