// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BladeManager, BladeCnParticipant} from "../src/blade-app/BladeContractNet.sol";
import {
    ManualManager,
    ManualCnParticipant,
    CN_SLOT_NONE,
    CN_PART_NONE
} from "../src/manual/ManualContractNet.sol";
import {ContractNetLib} from "blade/core/ContractNetLib.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";
import {IAgent} from "blade/core/IAgent.sol";

contract ContractNetEquivalenceTest is Test {
    bytes internal constant PAYLOAD = hex"";
    bytes32 internal constant CID = keccak256("f1-cn");

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 10);
    }

    function _partsB(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(new BladeCnParticipant());
        }
    }

    function _partsM(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(new ManualCnParticipant());
        }
    }

    function _empty() internal pure returns (address[] memory a) {}

    function _acceptAll(address[] memory parts) internal pure returns (address[] memory a) {
        a = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            a[i] = parts[i];
        }
    }

    function _ceilHalf(uint256 n) internal pure returns (uint256) {
        return (n + 1) / 2;
    }

    function _cfpMsg(uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = CID;
        m.replyBy = replyBy;
        m.content = PAYLOAD;
    }

    function _acceptMsg(uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.AcceptProposal);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = CID;
        m.replyBy = replyBy;
    }

    function test_scenarioA_N2_allProposeAcceptInform() public {
        uint256 n = 2;
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(n);
        uint64 byB = _deadline();
        bM.cfp(bP, CID, byB, PAYLOAD);
        for (uint256 i = 0; i < n; i++) {
            BladeCnParticipant(bP[i]).propose(_cfpMsg(byB), address(bM), PAYLOAD);
        }
        vm.warp(uint256(byB) + 1);
        bM.evaluate(CID, _acceptAll(bP), _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            BladeCnParticipant(bP[i]).inform(_acceptMsg(0), address(bM), PAYLOAD);
        }
        assertEq(bM.conversation(CID).live, 0);
        assertEq(bM.conversation(CID).invited, 0);
        for (uint256 i = 0; i < n; i++) {
            assertEq(BladeCnParticipant(bP[i]).session(CID).phase, ContractNetLib.PART_NONE);
            assertEq(bM.slotOf(CID, bP[i]), ContractNetLib.SLOT_NONE);
        }

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(n);
        uint64 byM = _deadline();
        mM.cfp(mP, CID, byM, PAYLOAD);
        for (uint256 i = 0; i < n; i++) {
            ManualCnParticipant(mP[i]).propose(CID, PAYLOAD);
        }
        vm.warp(uint256(byM) + 1);
        mM.evaluate(CID, _acceptAll(mP), _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            ManualCnParticipant(mP[i]).inform(CID, PAYLOAD);
        }
        assertEq(mM.conversation(CID).live, 0);
        assertEq(mM.conversation(CID).invited, 0);
        for (uint256 i = 0; i < n; i++) {
            assertEq(ManualCnParticipant(mP[i]).session(CID).phase, CN_PART_NONE);
            assertEq(mM.slotOf(CID, mP[i]), CN_SLOT_NONE);
        }
    }

    function test_scenarioB_N2_mixed() public {
        _runMixed(false);
    }

    /// @dev Confirmation cell only. Semantically identical to B at N=2. Not an RQ2/RQ4 cell.
    function test_scenarioC_confirmation_identicalToB_N2() public {
        _runMixed(true);
    }

    function _runMixed(
        bool /* confirmationLabel */
    )
        internal
    {
        uint256 n = 2;
        uint256 k = _ceilHalf(n);
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(n);
        uint64 byB = _deadline();
        bM.cfp(bP, CID, byB, PAYLOAD);
        for (uint256 i = 0; i < k; i++) {
            BladeCnParticipant(bP[i]).propose(_cfpMsg(byB), address(bM), PAYLOAD);
        }
        for (uint256 i = k; i < n; i++) {
            BladeCnParticipant(bP[i]).refuse(_cfpMsg(byB), address(bM));
        }
        vm.warp(uint256(byB) + 1);
        address[] memory acc = new address[](k);
        for (uint256 i = 0; i < k; i++) {
            acc[i] = bP[i];
        }
        bM.evaluate(CID, acc, _empty(), _empty());
        for (uint256 i = 0; i < k; i++) {
            BladeCnParticipant(bP[i]).inform(_acceptMsg(0), address(bM), PAYLOAD);
        }
        assertEq(bM.conversation(CID).live, 0);
        for (uint256 i = 0; i < n; i++) {
            assertEq(BladeCnParticipant(bP[i]).session(CID).phase, ContractNetLib.PART_NONE);
        }

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(n);
        uint64 byM = _deadline();
        mM.cfp(mP, CID, byM, PAYLOAD);
        for (uint256 i = 0; i < k; i++) {
            ManualCnParticipant(mP[i]).propose(CID, PAYLOAD);
        }
        for (uint256 i = k; i < n; i++) {
            ManualCnParticipant(mP[i]).refuse(CID);
        }
        vm.warp(uint256(byM) + 1);
        address[] memory accM = new address[](k);
        for (uint256 i = 0; i < k; i++) {
            accM[i] = mP[i];
        }
        mM.evaluate(CID, accM, _empty(), _empty());
        for (uint256 i = 0; i < k; i++) {
            ManualCnParticipant(mP[i]).inform(CID, PAYLOAD);
        }
        assertEq(mM.conversation(CID).live, 0);
        for (uint256 i = 0; i < n; i++) {
            assertEq(ManualCnParticipant(mP[i]).session(CID).phase, CN_PART_NONE);
        }
    }

    function test_failureCell_A_N1() public {
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(1);
        uint64 byB = _deadline();
        bM.cfp(bP, CID, byB, PAYLOAD);
        BladeCnParticipant(bP[0]).propose(_cfpMsg(byB), address(bM), PAYLOAD);
        vm.warp(uint256(byB) + 1);
        bM.evaluate(CID, _acceptAll(bP), _empty(), _empty());
        BladeCnParticipant(bP[0]).failure(_acceptMsg(0), address(bM), PAYLOAD);
        assertEq(bM.conversation(CID).live, 0);
        assertEq(BladeCnParticipant(bP[0]).session(CID).phase, ContractNetLib.PART_NONE);

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(1);
        uint64 byM = _deadline();
        mM.cfp(mP, CID, byM, PAYLOAD);
        ManualCnParticipant(mP[0]).propose(CID, PAYLOAD);
        vm.warp(uint256(byM) + 1);
        mM.evaluate(CID, _acceptAll(mP), _empty(), _empty());
        ManualCnParticipant(mP[0]).failure(CID, PAYLOAD);
        assertEq(mM.conversation(CID).live, 0);
        assertEq(ManualCnParticipant(mP[0]).session(CID).phase, CN_PART_NONE);
    }

    function test_invalid_evaluateBeforeDeadline() public {
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(1);
        uint64 by = _deadline();
        bM.cfp(bP, CID, by, PAYLOAD);
        BladeCnParticipant(bP[0]).propose(_cfpMsg(by), address(bM), PAYLOAD);
        vm.expectRevert();
        bM.evaluate(CID, _acceptAll(bP), _empty(), _empty());

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(1);
        mM.cfp(mP, CID, by, PAYLOAD);
        ManualCnParticipant(mP[0]).propose(CID, PAYLOAD);
        vm.expectRevert();
        mM.evaluate(CID, _acceptAll(mP), _empty(), _empty());
    }

    function test_invalid_proposeThenRefuse() public {
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(1);
        uint64 by = _deadline();
        bM.cfp(bP, CID, by, PAYLOAD);
        BladeCnParticipant(bP[0]).propose(_cfpMsg(by), address(bM), PAYLOAD);
        vm.expectRevert();
        BladeCnParticipant(bP[0]).refuse(_cfpMsg(by), address(bM));

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(1);
        mM.cfp(mP, CID, by, PAYLOAD);
        ManualCnParticipant(mP[0]).propose(CID, PAYLOAD);
        vm.expectRevert();
        ManualCnParticipant(mP[0]).refuse(CID);
    }

    function test_invalid_duplicateLiveCfp() public {
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(1);
        uint64 by = _deadline();
        bM.cfp(bP, CID, by, PAYLOAD);
        vm.expectRevert();
        bM.cfp(bP, CID, by, PAYLOAD);

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(1);
        mM.cfp(mP, CID, by, PAYLOAD);
        vm.expectRevert();
        mM.cfp(mP, CID, by, PAYLOAD);
    }

    function test_invalid_unexpectedPeerPropose() public {
        BladeManager bM = new BladeManager();
        address[] memory bP = _partsB(1);
        uint64 by = _deadline();
        bM.cfp(bP, CID, by, PAYLOAD);
        Message memory propose;
        propose.performative = uint8(Performative.Propose);
        propose.protocol = uint8(Protocol.FipaContractNet);
        propose.conversationId = CID;
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        IAgent(address(bM)).handle(propose);

        ManualManager mM = new ManualManager();
        address[] memory mP = _partsM(1);
        mM.cfp(mP, CID, by, PAYLOAD);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        mM.onPropose(CID, PAYLOAD);
    }
}
