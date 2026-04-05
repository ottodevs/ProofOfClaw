// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SoulVaultSwarm} from "../src/SoulVaultSwarm.sol";
import {ISoulVaultSwarm} from "../src/interfaces/ISoulVaultSwarm.sol";
import {SoulVaultERC8004RegistryAdapter} from "../src/SoulVaultERC8004RegistryAdapter.sol";
import {ProofOfClawVerifier} from "../src/ProofOfClawVerifier.sol";
import {ProofOfClawINFT} from "../src/ProofOfClawINFT.sol";
import {EIP8004Integration} from "../src/EIP8004Integration.sol";
import {IEIP8004IdentityRegistry, IEIP8004ReputationRegistry, IEIP8004ValidationRegistry} from "../src/interfaces/IEIP8004.sol";
import {RiscZeroGroth16Verifier} from "../src/RiscZeroGroth16Verifier.sol";
import {IRiscZeroVerifier} from "../src/interfaces/IRiscZeroVerifier.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockRiscZeroVerifier is IRiscZeroVerifier {
    function verify(bytes calldata, bytes32, bytes32) external pure {}
}

/// @dev Mock verifier that always reverts — used to test rejection path
contract RejectingVerifier is IRiscZeroVerifier {
    function verify(bytes calldata, bytes32, bytes32) external pure {
        revert("Invalid proof");
    }
}

// ===========================================================================
// SoulVaultSwarm Tests
// ===========================================================================

contract SoulVaultSwarmTest is Test {
    SoulVaultSwarm swarm;
    address owner = address(this);
    address member = address(0xBEEF);
    address nonOwner = address(0xCAFE);

    bytes constant PUBKEY = hex"04abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab";

    function setUp() public {
        swarm = new SoulVaultSwarm();
    }

    function _requestJoin(address who) internal returns (bytes32) {
        vm.prank(who);
        return swarm.requestJoin(PUBKEY, "ref://pubkey", "ref://metadata");
    }

    function _approveJoin(bytes32 requestId) internal {
        swarm.approveJoin(requestId);
    }

    // --- Join request & approval -------------------------------------------

    function test_joinRequestAndApproval() public {
        bytes32 requestId = _requestJoin(member);
        _approveJoin(requestId);

        ISoulVaultSwarm.Member memory m = swarm.getMember(member);
        assertTrue(m.active);
        assertEq(m.joinedEpoch, 0);
    }

    // --- Only owner can approve -------------------------------------------

    function test_onlyOwnerCanApprove() public {
        bytes32 requestId = _requestJoin(member);

        vm.prank(nonOwner);
        vm.expectRevert(SoulVaultSwarm.Unauthorized.selector);
        swarm.approveJoin(requestId);
    }

    // --- rotateEpoch version mismatch ------------------------------------

    function test_rotateEpochVersionMismatch() public {
        vm.expectRevert();
        swarm.rotateEpoch(1, "ref://bundle", keccak256("bundle"), 999);
    }

    // --- rotateEpoch success ---------------------------------------------

    function test_rotateEpochSuccess() public {
        uint64 ver = swarm.membershipVersion();
        swarm.rotateEpoch(1, "ref://bundle", keccak256("bundle"), ver);

        assertEq(swarm.currentEpoch(), 1);
    }

    // --- Message sequence must be monotonically increasing ----------------

    function test_messageSequenceMonotonic() public {
        bytes32 requestId = _requestJoin(member);
        _approveJoin(requestId);

        vm.startPrank(member);
        swarm.postMessage(
            address(0),
            keccak256("topic"),
            1,
            0, // epoch
            "ref://payload",
            keccak256("payload"),
            3600
        );

        // Same seq should revert
        vm.expectRevert();
        swarm.postMessage(
            address(0),
            keccak256("topic"),
            1,
            0,
            "ref://payload2",
            keccak256("payload2"),
            3600
        );

        // Lower seq should revert
        vm.expectRevert();
        swarm.postMessage(
            address(0),
            keccak256("topic"),
            0,
            0,
            "ref://payload3",
            keccak256("payload3"),
            3600
        );
        vm.stopPrank();
    }

    // --- Backup only owner ------------------------------------------------

    function test_backupOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(SoulVaultSwarm.Unauthorized.selector);
        swarm.requestBackup(0, "routine", "ref://target", uint64(block.timestamp + 3600));
    }

    // --- Member file mapping access control -------------------------------

    function test_memberFileMappingAccess() public {
        bytes32 requestId = _requestJoin(member);
        _approveJoin(requestId);

        // Member can update own file mapping
        vm.prank(member);
        swarm.updateMemberFileMapping(
            member,
            "0g://abc",
            keccak256("merkle"),
            keccak256("tx"),
            keccak256("manifest"),
            0
        );

        // Owner can update for member
        swarm.updateMemberFileMapping(
            member,
            "0g://def",
            keccak256("merkle2"),
            keccak256("tx2"),
            keccak256("manifest2"),
            0
        );

        // Non-owner cannot update for member
        vm.prank(nonOwner);
        vm.expectRevert(SoulVaultSwarm.Unauthorized.selector);
        swarm.updateMemberFileMapping(
            member,
            "0g://evil",
            keccak256("merkle3"),
            keccak256("tx3"),
            keccak256("manifest3"),
            0
        );
    }
}

// ===========================================================================
// ERC-8004 Registry Adapter Tests
// ===========================================================================

contract ERC8004RegistryAdapterTest is Test {
    SoulVaultERC8004RegistryAdapter registry;
    address wallet = address(0xA1);
    address other = address(0xA2);

    function setUp() public {
        registry = new SoulVaultERC8004RegistryAdapter();
    }

    // --- Register agent ---------------------------------------------------

    function test_registerAgent() public {
        vm.prank(wallet);
        bytes32 agentId = registry.registerAgent(wallet, "data:application/json;base64,abc123");

        assertEq(registry.agentURI(agentId), "data:application/json;base64,abc123");
        assertEq(registry.agentWallet(agentId), wallet);
        assertTrue(registry.isRegistered(agentId));
    }

    // --- Only self can register -------------------------------------------

    function test_onlySelfCanRegister() public {
        vm.prank(other);
        vm.expectRevert(SoulVaultERC8004RegistryAdapter.OnlySelf.selector);
        registry.registerAgent(wallet, "data:application/json;base64,abc123");
    }

    // --- Update URI -------------------------------------------------------

    function test_updateURI() public {
        vm.prank(wallet);
        bytes32 agentId = registry.registerAgent(wallet, "data:old");

        vm.prank(wallet);
        registry.updateAgentURI(agentId, "data:new");

        assertEq(registry.agentURI(agentId), "data:new");
    }

    // --- Set and read metadata --------------------------------------------

    function test_setMetadata() public {
        vm.prank(wallet);
        bytes32 agentId = registry.registerAgent(wallet, "data:uri");

        vm.prank(wallet);
        registry.setMetadata(agentId, "version", "1.0.0");

        assertEq(registry.metadata(agentId, "version"), "1.0.0");
    }

    // --- Reverse wallet lookup --------------------------------------------

    function test_reverseWalletLookup() public {
        vm.startPrank(wallet);

        bytes32 id1 = registry.registerAgent(wallet, "data:one");
        vm.warp(block.timestamp + 1);
        bytes32 id2 = registry.registerAgent(wallet, "data:two");

        vm.stopPrank();

        bytes32[] memory ids = registry.agentIdsForWallet(wallet);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
    }
}

// ===========================================================================
// ProofOfClawVerifier Tests
// ===========================================================================

contract ProofOfClawVerifierTest is Test {
    ProofOfClawVerifier verifierContract;
    MockRiscZeroVerifier mockVerifier;
    bytes32 constant IMAGE_ID = bytes32(uint256(1));
    address agentWallet = address(0xABCD);

    function setUp() public {
        mockVerifier = new MockRiscZeroVerifier();
        verifierContract = new ProofOfClawVerifier(IRiscZeroVerifier(address(mockVerifier)), IMAGE_ID);
    }

    // --- Register agent policy --------------------------------------------

    function test_registerAgentPolicy() public {
        bytes32 agentId = keccak256("agent-1");
        bytes32 policyHash = keccak256("policy-1");
        uint256 maxVal = 1 ether;

        verifierContract.registerAgent(agentId, policyHash, maxVal, agentWallet);

        (
            bytes32 storedPolicy,
            uint256 storedMax,
            address storedOwner,
            address storedWallet,
            bool active
        ) = verifierContract.agents(agentId);

        assertEq(storedPolicy, policyHash);
        assertEq(storedMax, maxVal);
        assertEq(storedOwner, address(this));
        assertEq(storedWallet, agentWallet);
        assertTrue(active);
    }

    // --- Deactivate agent -------------------------------------------------

    function test_deactivateAgent() public {
        bytes32 agentId = keccak256("agent-2");
        bytes32 policyHash = keccak256("policy-2");

        verifierContract.registerAgent(agentId, policyHash, 0, agentWallet);
        verifierContract.deactivateAgent(agentId);

        (, , , , bool active) = verifierContract.agents(agentId);
        assertFalse(active);
    }

    // --- Update verifier (onlyOwner) --------------------------------------

    function test_updateVerifier() public {
        MockRiscZeroVerifier newVerifier = new MockRiscZeroVerifier();

        verifierContract.updateVerifier(address(newVerifier));
        assertEq(address(verifierContract.verifier()), address(newVerifier));
    }

    function test_updateVerifier_rejectsNonOwner() public {
        MockRiscZeroVerifier newVerifier = new MockRiscZeroVerifier();

        vm.prank(address(0xDEAD));
        vm.expectRevert(ProofOfClawVerifier.Unauthorized.selector);
        verifierContract.updateVerifier(address(newVerifier));
    }

    function test_updateVerifier_rejectsZeroAddress() public {
        vm.expectRevert("Zero address");
        verifierContract.updateVerifier(address(0));
    }

    // --- Update image ID (onlyOwner) --------------------------------------

    function test_updateImageId() public {
        bytes32 newImageId = bytes32(uint256(42));

        verifierContract.updateImageId(newImageId);
        assertEq(verifierContract.imageId(), newImageId);
    }

    function test_updateImageId_rejectsNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ProofOfClawVerifier.Unauthorized.selector);
        verifierContract.updateImageId(bytes32(uint256(42)));
    }

    // --- Verifier switch rejects bad proofs --------------------------------

    function test_rejectingVerifier_blocksExecution() public {
        // Register agent
        bytes32 agentId = keccak256("agent-reject");
        bytes32 policyHash = keccak256("policy-reject");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        // Switch to rejecting verifier
        RejectingVerifier rejecter = new RejectingVerifier();
        verifierContract.updateVerifier(address(rejecter));

        // Attempt to verify — should revert
        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-reject",
            policyHash: policyHash,
            outputCommitment: keccak256("output"),
            allChecksPassed: true,
            requiresLedgerApproval: false,
            actionValue: 0
        });

        bytes memory journalData = abi.encode(output);
        bytes memory seal = hex"00";
        bytes memory action = abi.encode(address(0), uint256(0), bytes(""));

        vm.prank(agentWallet);
        vm.expectRevert("Invalid proof");
        verifierContract.verifyAndExecute(seal, journalData, action);
    }

    // --- Full verifyAndExecute with mock (autonomous path) -----------------

    function test_verifyAndExecute_autonomous() public {
        // Deploy a dummy target contract that accepts calls
        DummyTarget target = new DummyTarget();

        // Whitelist the target
        verifierContract.setAllowedTarget(address(target), true);

        bytes32 agentId = keccak256("agent-auto");
        bytes32 policyHash = keccak256("policy-auto");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-auto",
            policyHash: policyHash,
            outputCommitment: keccak256("output"),
            allChecksPassed: true,
            requiresLedgerApproval: false,
            actionValue: 0
        });

        bytes memory journalData = abi.encode(output);
        bytes memory seal = hex"00";
        bytes memory action = abi.encode(
            address(target),
            uint256(0),
            abi.encodeCall(DummyTarget.ping, ())
        );

        vm.prank(agentWallet);
        verifierContract.verifyAndExecute(seal, journalData, action);

        assertTrue(target.pinged());
    }
}

// ===========================================================================
// Groth16 Verifier Tests
// ===========================================================================

contract RiscZeroGroth16VerifierTest is Test {
    RiscZeroGroth16Verifier groth16Verifier;

    bytes4 constant SELECTOR = bytes4(0x310fe598);

    function setUp() public {
        groth16Verifier = new RiscZeroGroth16Verifier();
    }

    // --- Seal too short ---------------------------------------------------

    function test_rejectShortSeal() public {
        bytes memory shortSeal = hex"310fe59800";

        vm.expectRevert(RiscZeroGroth16Verifier.InvalidSealLength.selector);
        groth16Verifier.verify(shortSeal, bytes32(0), bytes32(0));
    }

    // --- Wrong selector ---------------------------------------------------

    function test_rejectWrongSelector() public {
        bytes memory seal = new bytes(260);
        seal[0] = 0xDE;
        seal[1] = 0xAD;
        seal[2] = 0xBE;
        seal[3] = 0xEF;

        vm.expectRevert(RiscZeroGroth16Verifier.InvalidProofSelector.selector);
        groth16Verifier.verify(seal, bytes32(0), bytes32(0));
    }

    // --- Invalid proof fails pairing check --------------------------------

    function test_rejectInvalidProof() public {
        // Build a seal with valid-looking but incorrect proof points
        bytes memory seal = _buildSeal(
            SELECTOR,
            uint256(1), uint256(2),  // A (G1 generator)
            uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781),
            uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634),
            uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930),
            uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531),
            uint256(1), uint256(2)   // C (G1 generator)
        );

        vm.expectRevert(); // PairingFailed — proof doesn't match VK
        groth16Verifier.verify(seal, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    // --- Proof selector is stored correctly --------------------------------

    function test_proofSelectorStored() public view {
        assertEq(groth16Verifier.PROOF_SELECTOR(), SELECTOR);
    }

    // --- Helper to build seal bytes ----------------------------------------

    function _buildSeal(
        bytes4 sel,
        uint256 aX, uint256 aY,
        uint256 bX1, uint256 bX2, uint256 bY1, uint256 bY2,
        uint256 cX, uint256 cY
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            sel,
            bytes32(aX), bytes32(aY),
            bytes32(bX1), bytes32(bX2), bytes32(bY1), bytes32(bY2),
            bytes32(cX), bytes32(cY)
        );
    }
}

// ===========================================================================
// ProofOfClawINFT Tests
// ===========================================================================

contract ProofOfClawINFTTest is Test {
    ProofOfClawINFT inft;
    address admin = address(this);
    address verifierAddr = address(0xV1);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    bytes32 constant AGENT_ID = keccak256("agent-1");
    bytes32 constant POLICY = keccak256("policy-1");
    bytes32 constant IMAGE_ID_INFT = bytes32(uint256(0x1234));
    bytes32 constant META_HASH = keccak256("metadata");
    bytes32 constant SOUL_HASH = keccak256("soul-backup");

    function setUp() public {
        inft = new ProofOfClawINFT(verifierAddr);
    }

    function _mint() internal returns (uint256) {
        vm.prank(alice);
        return inft.mint(AGENT_ID, POLICY, IMAGE_ID_INFT, "0g://encrypted", META_HASH, SOUL_HASH, "0g://soul-backup", "agent.proofofclaw.eth");
    }

    // --- Minting ---

    function test_mint() public {
        uint256 tokenId = _mint();
        assertEq(tokenId, 1);
        assertEq(inft.ownerOf(tokenId), alice);
        assertEq(inft.getTokenByAgent(AGENT_ID), tokenId);
        assertEq(inft.totalSupply(), 1);
    }

    function test_mint_duplicateReverts() public {
        _mint();
        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.AgentAlreadyMinted.selector);
        inft.mint(AGENT_ID, POLICY, IMAGE_ID_INFT, "0g://other", META_HASH, SOUL_HASH, "0g://soul-backup", "bob.proofofclaw.eth");
    }

    // --- Metadata ---

    function test_updateMetadata() public {
        uint256 tokenId = _mint();
        bytes32 newHash = keccak256("new-meta");

        vm.prank(alice);
        inft.updateMetadata(tokenId, "0g://updated", newHash);

        assertEq(inft.tokenURI(tokenId), "0g://updated");
    }

    function test_updateMetadata_nonOwnerReverts() public {
        uint256 tokenId = _mint();
        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.NotOwner.selector);
        inft.updateMetadata(tokenId, "0g://evil", keccak256("evil"));
    }

    // --- Transfers ---

    function test_transferFrom() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.transferFrom(alice, bob, tokenId);

        assertEq(inft.ownerOf(tokenId), bob);
    }

    function test_transferFrom_unauthorizedReverts() public {
        uint256 tokenId = _mint();

        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.NotAuthorized.selector);
        inft.transferFrom(alice, bob, tokenId);
    }

    function test_transferFrom_withApproval() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.approve(bob, tokenId);

        vm.prank(bob);
        inft.transferFrom(alice, bob, tokenId);
        assertEq(inft.ownerOf(tokenId), bob);
    }

    function test_transferFrom_withOperatorApproval() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.setApprovalForAll(bob, true);

        vm.prank(bob);
        inft.transferFrom(alice, bob, tokenId);
        assertEq(inft.ownerOf(tokenId), bob);
    }

    function test_transfer_clearsApproval() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.approve(bob, tokenId);
        assertEq(inft.getApproved(tokenId), bob);

        vm.prank(alice);
        inft.transferFrom(alice, bob, tokenId);
        assertEq(inft.getApproved(tokenId), address(0));
    }

    // --- Usage Authorization (ERC-7857) ---

    function test_authorizeUsage() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.authorizeUsage(tokenId, bob, "inference");

        assertTrue(inft.isAuthorized(tokenId, bob));
    }

    function test_revokeUsage() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.authorizeUsage(tokenId, bob, "inference");

        vm.prank(alice);
        inft.revokeUsage(tokenId, bob);

        assertFalse(inft.isAuthorized(tokenId, bob));
    }

    // --- Proof & Reputation ---

    function test_recordProof() public {
        uint256 tokenId = _mint();

        vm.prank(verifierAddr);
        inft.recordProof(tokenId);

        ProofOfClawINFT.AgentINFT memory agent = inft.getAgent(tokenId);
        assertEq(agent.totalProofs, 1);
    }

    function test_recordProof_nonVerifierReverts() public {
        uint256 tokenId = _mint();

        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.OnlyVerifier.selector);
        inft.recordProof(tokenId);
    }

    function test_updateReputation_byVerifier() public {
        uint256 tokenId = _mint();

        vm.prank(verifierAddr);
        inft.updateReputation(tokenId, 95);

        assertEq(inft.getAgent(tokenId).reputationScore, 95);
    }

    function test_updateReputation_byAdmin() public {
        uint256 tokenId = _mint();

        inft.updateReputation(tokenId, 80); // admin = address(this)

        assertEq(inft.getAgent(tokenId).reputationScore, 80);
    }

    function test_updateReputation_unauthorizedReverts() public {
        uint256 tokenId = _mint();

        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.NotAuthorized.selector);
        inft.updateReputation(tokenId, 50);
    }

    // --- balanceOf ---

    function test_balanceOf() public {
        _mint();
        assertEq(inft.balanceOf(alice), 1);
        assertEq(inft.balanceOf(bob), 0);
    }

    // --- supportsInterface ---

    function test_supportsInterface() public view {
        assertTrue(inft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(inft.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(inft.supportsInterface(0xdeadbeef));
    }

    // --- Deactivate ---

    function test_deactivate() public {
        uint256 tokenId = _mint();

        vm.prank(alice);
        inft.deactivate(tokenId);

        assertFalse(inft.getAgent(tokenId).active);
    }

    // --- Soul Backup ---

    function test_mint_withoutSoulReverts() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfClawINFT.SoulBackupRequired.selector);
        inft.mint(keccak256("soulless-agent"), POLICY, IMAGE_ID_INFT, "0g://enc", META_HASH, bytes32(0), "", "soulless.eth");
    }

    function test_getSoulBackup() public {
        uint256 tokenId = _mint();
        (bytes32 hash, string memory uri) = inft.getSoulBackup(tokenId);
        assertEq(hash, SOUL_HASH);
        assertEq(keccak256(bytes(uri)), keccak256(bytes("0g://soul-backup")));
    }

    function test_updateSoulBackup() public {
        uint256 tokenId = _mint();
        bytes32 newHash = keccak256("evolved-soul");

        vm.prank(alice);
        inft.updateSoulBackup(tokenId, newHash, "0g://evolved-soul");

        (bytes32 hash, string memory uri) = inft.getSoulBackup(tokenId);
        assertEq(hash, newHash);
        assertEq(keccak256(bytes(uri)), keccak256(bytes("0g://evolved-soul")));
    }

    function test_updateSoulBackup_nonOwnerReverts() public {
        uint256 tokenId = _mint();
        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.NotOwner.selector);
        inft.updateSoulBackup(tokenId, keccak256("hijack"), "0g://evil");
    }

    function test_updateSoulBackup_zeroHashReverts() public {
        uint256 tokenId = _mint();
        vm.prank(alice);
        vm.expectRevert(ProofOfClawINFT.SoulBackupRequired.selector);
        inft.updateSoulBackup(tokenId, bytes32(0), "");
    }

    // --- Admin ---

    function test_setVerifier() public {
        inft.setVerifier(address(0x999));
        assertEq(inft.verifier(), address(0x999));
    }

    function test_setVerifier_nonAdminReverts() public {
        vm.prank(bob);
        vm.expectRevert(ProofOfClawINFT.OnlyAdmin.selector);
        inft.setVerifier(address(0x999));
    }
}

// ===========================================================================
// EIP8004Integration Tests (with mock registries)
// ===========================================================================

contract MockIdentityRegistry is IEIP8004IdentityRegistry {
    uint256 nextId = 1;
    mapping(uint256 => string) public uris;

    function register(string calldata agentURI, MetadataEntry[] calldata) external returns (uint256) {
        uint256 id = nextId++;
        uris[id] = agentURI;
        return id;
    }
    function register(string calldata agentURI) external returns (uint256) {
        uint256 id = nextId++;
        uris[id] = agentURI;
        return id;
    }
    function register() external returns (uint256) { return nextId++; }
    function setAgentURI(uint256, string calldata) external {}
    function getMetadata(uint256, string calldata) external pure returns (bytes memory) { return ""; }
    function setMetadata(uint256, string calldata, bytes calldata) external {}
    function setAgentWallet(uint256, address, uint256, bytes calldata) external {}
    function getAgentWallet(uint256) external pure returns (address) { return address(0); }
    function unsetAgentWallet(uint256) external {}
}

contract MockReputationRegistry is IEIP8004ReputationRegistry {
    uint256 public feedbackCount;

    function initialize(address) external {}
    function getIdentityRegistry() external pure returns (address) { return address(0); }
    function giveFeedback(uint256, int128, uint8, string calldata, string calldata, string calldata, string calldata, bytes32) external {
        feedbackCount++;
    }
    function revokeFeedback(uint256, uint64) external {}
    function appendResponse(uint256, address, uint64, string calldata, bytes32) external {}
    function getSummary(uint256, address[] calldata, string calldata, string calldata) external pure returns (uint64, int128, uint8) {
        return (5, 85, 0);
    }
    function readFeedback(uint256, address, uint64) external pure returns (int128, uint8, string memory, string memory, bool) {
        return (0, 0, "", "", false);
    }
    function getClients(uint256) external pure returns (address[] memory) { return new address[](0); }
    function getLastIndex(uint256, address) external pure returns (uint64) { return 0; }
}

contract MockValidationRegistry is IEIP8004ValidationRegistry {
    uint256 public responseCount;

    function initialize(address) external {}
    function validationRequest(address, uint256, string calldata, bytes32) external {}
    function validationResponse(bytes32, uint8, string calldata, bytes32, string calldata) external {
        responseCount++;
    }
    function getValidationStatus(bytes32) external pure returns (address, uint256, uint8, bytes32, string memory, uint256) {
        return (address(0), 0, 0, bytes32(0), "", 0);
    }
    function getSummary(uint256, address[] calldata, string calldata) external pure returns (uint64, uint8) {
        return (3, 90);
    }
    function getAgentValidations(uint256) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function getValidatorRequests(address) external pure returns (bytes32[] memory) { return new bytes32[](0); }
}

contract EIP8004IntegrationTest is Test {
    EIP8004Integration integration;
    MockIdentityRegistry identityReg;
    MockReputationRegistry reputationReg;
    MockValidationRegistry validationReg;
    address verifierAddr = address(0xV1);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    bytes32 constant AGENT_ID = keccak256("agent-eip");

    function setUp() public {
        identityReg = new MockIdentityRegistry();
        reputationReg = new MockReputationRegistry();
        validationReg = new MockValidationRegistry();
        integration = new EIP8004Integration(
            address(identityReg),
            address(reputationReg),
            address(validationReg),
            verifierAddr
        );
    }

    function _registerAgent() internal returns (uint256) {
        vm.prank(alice);
        return integration.registerAgentIdentity(
            AGENT_ID,
            "ipfs://agent-metadata",
            keccak256("policy"),
            bytes32(uint256(0x1234))
        );
    }

    // --- Registration ---

    function test_registerAgentIdentity() public {
        uint256 tokenId = _registerAgent();
        assertEq(tokenId, 1);
        assertEq(integration.agentToTokenId(AGENT_ID), 1);
        assertEq(integration.tokenIdToAgent(1), AGENT_ID);
        assertEq(integration.agentRegistrant(AGENT_ID), alice);
    }

    function test_registerAgentIdentity_duplicateReverts() public {
        _registerAgent();
        vm.prank(bob);
        vm.expectRevert(EIP8004Integration.AgentAlreadyRegistered.selector);
        integration.registerAgentIdentity(AGENT_ID, "ipfs://dup", keccak256("p"), bytes32(0));
    }

    // --- Validation Recording ---

    function test_recordValidation() public {
        _registerAgent();

        vm.prank(verifierAddr);
        integration.recordValidation(AGENT_ID, keccak256("req"), true, "ipfs://proof", keccak256("resp"));

        assertEq(validationReg.responseCount(), 1);
    }

    function test_recordValidation_nonVerifierReverts() public {
        _registerAgent();
        vm.prank(alice);
        vm.expectRevert(EIP8004Integration.OnlyVerifier.selector);
        integration.recordValidation(AGENT_ID, keccak256("req"), true, "", bytes32(0));
    }

    function test_recordValidation_unregisteredReverts() public {
        vm.prank(verifierAddr);
        vm.expectRevert(EIP8004Integration.AgentNotRegistered.selector);
        integration.recordValidation(keccak256("fake"), keccak256("req"), true, "", bytes32(0));
    }

    // --- Reputation ---

    function test_submitReputation() public {
        _registerAgent();

        vm.prank(bob); // not the registrant
        integration.submitReputation(AGENT_ID, 90, 0, "quality", "task", "/verify", "ipfs://feedback", keccak256("fb"));

        assertEq(reputationReg.feedbackCount(), 1);
    }

    function test_submitReputation_selfReviewReverts() public {
        _registerAgent();

        vm.prank(alice); // alice is the registrant
        vm.expectRevert(EIP8004Integration.OnlyAgentOwner.selector);
        integration.submitReputation(AGENT_ID, 90, 0, "quality", "task", "/verify", "ipfs://feedback", keccak256("fb"));
    }

    // --- Validation Request ---

    function test_requestValidation_byVerifier() public {
        _registerAgent();
        vm.prank(verifierAddr);
        integration.requestValidation(AGENT_ID, "0g://trace", keccak256("trace"));
    }

    function test_requestValidation_byRegistrant() public {
        _registerAgent();
        vm.prank(alice);
        integration.requestValidation(AGENT_ID, "0g://trace", keccak256("trace"));
    }

    function test_requestValidation_unauthorizedReverts() public {
        _registerAgent();
        vm.prank(bob);
        vm.expectRevert(EIP8004Integration.OnlyVerifierOrRegistrant.selector);
        integration.requestValidation(AGENT_ID, "0g://trace", keccak256("trace"));
    }

    // --- View functions ---

    function test_getAgentReputation() public {
        _registerAgent();
        address[] memory reviewers = new address[](0);
        (uint64 count, int128 value,) = integration.getAgentReputation(AGENT_ID, reviewers, "", "");
        assertEq(count, 5);
        assertEq(value, 85);
    }

    function test_getAgentValidationSummary() public {
        _registerAgent();
        (uint64 count, uint8 avg) = integration.getAgentValidationSummary(AGENT_ID, "risc-zero-zkvm");
        assertEq(count, 3);
        assertEq(avg, 90);
    }

    function test_getTokenId() public {
        _registerAgent();
        assertEq(integration.getTokenId(AGENT_ID), 1);
    }
}

// ===========================================================================
// Additional ProofOfClawVerifier Tests (new security features)
// ===========================================================================

contract ProofOfClawVerifierSecurityTest is Test {
    ProofOfClawVerifier verifierContract;
    MockRiscZeroVerifier mockVerifier;
    bytes32 constant IMG_ID = bytes32(uint256(1));
    address agentWallet = address(0xABCD);
    address owner;

    function setUp() public {
        owner = address(this);
        mockVerifier = new MockRiscZeroVerifier();
        verifierContract = new ProofOfClawVerifier(IRiscZeroVerifier(address(mockVerifier)), IMG_ID);
    }

    function test_setAllowedTarget() public {
        verifierContract.setAllowedTarget(address(0x123), true);
        assertTrue(verifierContract.allowedTargets(address(0x123)));

        verifierContract.setAllowedTarget(address(0x123), false);
        assertFalse(verifierContract.allowedTargets(address(0x123)));
    }

    function test_setAllowedTarget_nonOwnerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ProofOfClawVerifier.Unauthorized.selector);
        verifierContract.setAllowedTarget(address(0x123), true);
    }

    function test_executeAction_rejectsUnwhitelistedTarget() public {
        DummyTarget target = new DummyTarget();
        // Do NOT whitelist the target

        bytes32 agentId = keccak256("agent-nowhite");
        bytes32 policyHash = keccak256("policy-nowhite");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-nowhite",
            policyHash: policyHash,
            outputCommitment: keccak256("output"),
            allChecksPassed: true,
            requiresLedgerApproval: false,
            actionValue: 0
        });

        bytes memory journalData = abi.encode(output);
        bytes memory seal = hex"00";
        bytes memory action = abi.encode(address(target), uint256(0), abi.encodeCall(DummyTarget.ping, ()));

        vm.prank(agentWallet);
        vm.expectRevert(ProofOfClawVerifier.TargetNotAllowed.selector);
        verifierContract.verifyAndExecute(seal, journalData, action);
    }

    function test_approveAction_flow() public {
        DummyTarget target = new DummyTarget();
        verifierContract.setAllowedTarget(address(target), true);

        bytes32 agentId = keccak256("agent-approve");
        bytes32 policyHash = keccak256("policy-approve");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-approve",
            policyHash: policyHash,
            outputCommitment: keccak256("output-approve"),
            allChecksPassed: true,
            requiresLedgerApproval: true,
            actionValue: 1 ether
        });

        bytes memory journalData = abi.encode(output);
        bytes memory seal = hex"00";

        // Submit for approval (anyone can call when ledger approval required)
        verifierContract.verifyAndExecute(seal, journalData, hex"");

        // Owner approves
        bytes memory action = abi.encode(address(target), uint256(0), abi.encodeCall(DummyTarget.ping, ()));
        verifierContract.approveAction(agentId, keccak256("output-approve"), action);

        assertTrue(target.pinged());
    }

    function test_approveAction_rejectsAlreadyExecuted() public {
        DummyTarget target = new DummyTarget();
        verifierContract.setAllowedTarget(address(target), true);

        bytes32 agentId = keccak256("agent-replay");
        bytes32 policyHash = keccak256("policy-replay");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-replay",
            policyHash: policyHash,
            outputCommitment: keccak256("output-replay"),
            allChecksPassed: true,
            requiresLedgerApproval: true,
            actionValue: 1 ether
        });

        bytes memory journalData = abi.encode(output);
        verifierContract.verifyAndExecute(hex"00", journalData, hex"");

        bytes memory action = abi.encode(address(target), uint256(0), abi.encodeCall(DummyTarget.ping, ()));
        verifierContract.approveAction(agentId, keccak256("output-replay"), action);

        // Try to approve again — should revert
        vm.expectRevert(ProofOfClawVerifier.ActionNotPending.selector);
        verifierContract.approveAction(agentId, keccak256("output-replay"), action);
    }

    function test_replayPrevention_rejectsDuplicateActionId() public {
        bytes32 agentId = keccak256("agent-dup");
        bytes32 policyHash = keccak256("policy-dup");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-dup",
            policyHash: policyHash,
            outputCommitment: keccak256("output-dup"),
            allChecksPassed: true,
            requiresLedgerApproval: true,
            actionValue: 1 ether
        });

        bytes memory journalData = abi.encode(output);
        verifierContract.verifyAndExecute(hex"00", journalData, hex"");

        // Same proof again — should revert with ActionAlreadySubmitted
        vm.expectRevert(ProofOfClawVerifier.ActionAlreadySubmitted.selector);
        verifierContract.verifyAndExecute(hex"00", journalData, hex"");
    }

    function test_approveAction_nonOwnerReverts() public {
        bytes32 agentId = keccak256("agent-auth");
        bytes32 policyHash = keccak256("policy-auth");
        verifierContract.registerAgent(agentId, policyHash, 1 ether, agentWallet);

        ProofOfClawVerifier.VerifiedOutput memory output = ProofOfClawVerifier.VerifiedOutput({
            agentId: "agent-auth",
            policyHash: policyHash,
            outputCommitment: keccak256("output-auth"),
            allChecksPassed: true,
            requiresLedgerApproval: true,
            actionValue: 0
        });

        verifierContract.verifyAndExecute(hex"00", abi.encode(output), hex"");

        vm.prank(address(0xDEAD));
        vm.expectRevert(ProofOfClawVerifier.Unauthorized.selector);
        verifierContract.approveAction(agentId, keccak256("output-auth"), hex"");
    }

    function test_updateAgentPolicy() public {
        bytes32 agentId = keccak256("agent-policy");
        verifierContract.registerAgent(agentId, keccak256("old"), 1 ether, agentWallet);

        verifierContract.updateAgentPolicy(agentId, keccak256("new"), 2 ether);

        (bytes32 storedPolicy, uint256 storedMax,,,) = verifierContract.agents(agentId);
        assertEq(storedPolicy, keccak256("new"));
        assertEq(storedMax, 2 ether);
    }
}

// ===========================================================================
// Helpers
// ===========================================================================

contract DummyTarget {
    bool public pinged;

    function ping() external {
        pinged = true;
    }
}
