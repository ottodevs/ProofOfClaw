// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SoulVaultSwarm} from "../src/SoulVaultSwarm.sol";
import {ISoulVaultSwarm} from "../src/interfaces/ISoulVaultSwarm.sol";
import {SoulVaultERC8004RegistryAdapter} from "../src/SoulVaultERC8004RegistryAdapter.sol";
import {ProofOfClawVerifier} from "../src/ProofOfClawVerifier.sol";
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

    // BN256 generator points for testing
    uint256 constant G1_X = 1;
    uint256 constant G1_Y = 2;
    uint256 constant G2_X1 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant G2_X2 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant G2_Y1 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant G2_Y2 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;

    bytes4 constant SELECTOR = bytes4(0x310fe598);

    function setUp() public {
        uint256[2] memory alpha = [G1_X, G1_Y];
        uint256[4] memory beta = [G2_X1, G2_X2, G2_Y1, G2_Y2];
        uint256[4] memory gamma = [G2_X1, G2_X2, G2_Y1, G2_Y2];
        uint256[4] memory delta = [G2_X1, G2_X2, G2_Y1, G2_Y2];
        uint256[6] memory ic = [G1_X, G1_Y, G1_X, G1_Y, G1_X, G1_Y];

        groth16Verifier = new RiscZeroGroth16Verifier(alpha, beta, gamma, delta, ic, SELECTOR);
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
        bytes memory seal = _buildSeal(
            SELECTOR,
            uint256(1), uint256(2),
            G2_X1, G2_X2, G2_Y1, G2_Y2,
            uint256(1), uint256(2)
        );

        vm.expectRevert(RiscZeroGroth16Verifier.PairingFailed.selector);
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
// Helpers
// ===========================================================================

contract DummyTarget {
    bool public pinged;

    function ping() external {
        pinged = true;
    }
}
