// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BladeRequester, BladeParticipant} from "../src/blade-app/BladeRequest.sol";
import {BladeManager, BladeCnParticipant} from "../src/blade-app/BladeContractNet.sol";
import {ManualInitiator, ManualParticipant} from "../src/manual/ManualRequest.sol";
import {ManualManager, ManualCnParticipant} from "../src/manual/ManualContractNet.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @dev F2 storage probe. Not a gas campaign. Writes JSONL under f2/storage/.
contract StoragePilotTest is Test {
    bytes32 internal constant CID = keccak256("f2-store");

    function _payload(uint256 n) internal pure returns (bytes memory p) {
        p = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            p[i] = bytes1(uint8(0xab));
        }
    }

    function _req(bytes memory payload) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = CID;
        m.content = payload;
    }

    function _merge(address a, bytes32[] storage acc) internal {
        (, bytes32[] memory w) = vm.accesses(a);
        for (uint256 i = 0; i < w.length; i++) {
            bool seen;
            for (uint256 j = 0; j < acc.length; j++) {
                if (acc[j] == w[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                acc.push(w[i]);
            }
        }
    }

    function _nonzero(address a, bytes32[] storage acc) internal view returns (uint256 n) {
        for (uint256 i = 0; i < acc.length; i++) {
            if (vm.load(a, acc[i]) != bytes32(0)) {
                n++;
            }
        }
    }

    function _hasNeedle(address a, bytes32[] storage acc, bytes memory payload)
        internal
        view
        returns (bool)
    {
        if (payload.length < 32) {
            return false;
        }
        bytes32 needle;
        assembly {
            needle := mload(add(payload, 32))
        }
        for (uint256 i = 0; i < acc.length; i++) {
            if (vm.load(a, acc[i]) == needle) {
                return true;
            }
        }
        return false;
    }

    function test_storage_request_R3_payloads() public {
        string memory out = string.concat("[");
        bool first = true;
        uint256[4] memory sizes = [uint256(0), 32, 256, 1024];
        for (uint256 s = 0; s < 4; s++) {
            bytes memory p = _payload(sizes[s]);
            (string memory b, bool okB) = _oneR3(true, p);
            (string memory m, bool okM) = _oneR3(false, p);
            require(okB && okM, "payload stored or identity fail");
            if (!first) {
                out = string.concat(out, ",");
            }
            first = false;
            out = string.concat(out, b, ",", m);
        }
        out = string.concat(out, "]");
        vm.writeFile("outputs/storage/request_r3.json", out);
    }

    struct R3Snap {
        uint256 activeI;
        uint256 activeP;
        uint256 termI;
        uint256 termP;
        bool needle;
        bool ok;
        uint256 payloadBytes;
        bool blade;
    }

    R3Snap internal lastR3;

    function _oneR3(bool blade, bytes memory payload) internal returns (string memory json, bool ok) {
        _runR3(blade, payload);
        json = _fmtR3();
        ok = lastR3.ok;
    }

    function _runR3(bool blade, bytes memory payload) internal {
        address I;
        address P;
        if (blade) {
            I = address(new BladeRequester());
            P = address(new BladeParticipant());
        } else {
            I = address(new ManualInitiator());
            P = address(new ManualParticipant());
        }
        bytes32[] storage wI = _scratch(I);
        bytes32[] storage wP = _scratch(P);
        vm.record();
        if (blade) {
            BladeRequester(I).startRequest(P, CID, payload);
            _merge(I, wI);
            _merge(P, wP);
            BladeParticipant(P).agree(_req(payload), I);
        } else {
            ManualInitiator(I).startRequest(P, CID, payload);
            _merge(I, wI);
            _merge(P, wP);
            ManualParticipant(P).agree(CID);
        }
        _merge(I, wI);
        _merge(P, wP);
        lastR3.activeI = _nonzero(I, wI);
        lastR3.activeP = _nonzero(P, wP);
        require(lastR3.activeI == _nonzero(I, wI), "repeat read");
        if (blade) {
            BladeParticipant(P).inform(_req(payload), I, payload);
        } else {
            ManualParticipant(P).inform(CID, payload);
        }
        _merge(I, wI);
        _merge(P, wP);
        lastR3.termI = _nonzero(I, wI);
        lastR3.termP = _nonzero(P, wP);
        lastR3.needle = _hasNeedle(I, wI, payload) || _hasNeedle(P, wP, payload);
        lastR3.payloadBytes = payload.length;
        lastR3.blade = blade;
        lastR3.ok = !lastR3.needle && lastR3.termI == 0 && lastR3.termP == 0 && lastR3.activeI > 0
            && lastR3.activeP > 0;
    }

    function _fmtR3() internal view returns (string memory) {
        return string.concat(
            "{\"implementation\":\"",
            lastR3.blade ? "blade" : "manual",
            "\",\"path\":\"R3\",\"payload_bytes\":",
            vm.toString(lastR3.payloadBytes),
            ",\"active_I\":",
            vm.toString(lastR3.activeI),
            ",\"terminal_I\":",
            vm.toString(lastR3.termI),
            ",\"active_P\":",
            vm.toString(lastR3.activeP),
            ",\"terminal_P\":",
            vm.toString(lastR3.termP),
            ",\"payload_in_storage\":",
            lastR3.needle ? "true" : "false",
            ",\"ok\":",
            lastR3.ok ? "true" : "false",
            "}"
        );
    }

    mapping(address => bytes32[]) internal _acc;

    function _scratch(address a) internal returns (bytes32[] storage) {
        delete _acc[a];
        return _acc[a];
    }

    function test_storage_cnA_N2() public {
        string memory out = string.concat("[", _oneCn(true), ",", _oneCn(false), "]");
        vm.writeFile("outputs/storage/cn_a_n2.json", out);
    }

    function _oneCn(bool blade) internal returns (string memory json) {
        uint256 n = 2;
        bytes memory payload = _payload(0);
        address M;
        address[] memory parts = new address[](n);
        if (blade) {
            M = address(new BladeManager());
            for (uint256 i = 0; i < n; i++) {
                parts[i] = address(new BladeCnParticipant());
            }
        } else {
            M = address(new ManualManager());
            for (uint256 i = 0; i < n; i++) {
                parts[i] = address(new ManualCnParticipant());
            }
        }
        bytes32[] storage wM = _scratch(M);
        vm.record();
        uint64 by = uint64(block.timestamp + 10);
        if (blade) {
            BladeManager(M).cfp(parts, CID, by, payload);
            for (uint256 i = 0; i < n; i++) {
                Message memory cfp;
                cfp.performative = uint8(Performative.Cfp);
                cfp.protocol = uint8(Protocol.FipaContractNet);
                cfp.conversationId = CID;
                cfp.replyBy = by;
                BladeCnParticipant(parts[i]).propose(cfp, M, payload);
            }
        } else {
            ManualManager(M).cfp(parts, CID, by, payload);
            for (uint256 i = 0; i < n; i++) {
                ManualCnParticipant(parts[i]).propose(CID, payload);
            }
        }
        _merge(M, wM);
        uint256 afterPropose = _nonzero(M, wM);
        vm.warp(uint256(by) + 1);
        address[] memory none = new address[](0);
        if (blade) {
            BladeManager(M).evaluate(CID, parts, none, none);
        } else {
            ManualManager(M).evaluate(CID, parts, none, none);
        }
        _merge(M, wM);
        uint256 afterEval = _nonzero(M, wM);
        if (blade) {
            for (uint256 i = 0; i < n; i++) {
                Message memory acc;
                acc.performative = uint8(Performative.AcceptProposal);
                acc.protocol = uint8(Protocol.FipaContractNet);
                acc.conversationId = CID;
                acc.replyBy = 0;
                BladeCnParticipant(parts[i]).inform(acc, M, payload);
            }
        } else {
            for (uint256 i = 0; i < n; i++) {
                ManualCnParticipant(parts[i]).inform(CID, payload);
            }
        }
        _merge(M, wM);
        uint256 terminal = _nonzero(M, wM);
        json = string.concat(
            "{\"implementation\":\"",
            blade ? "blade" : "manual",
            "\",\"scenario\":\"A\",\"N\":2,\"after_propose_M\":",
            vm.toString(afterPropose),
            ",\"after_eval_M\":",
            vm.toString(afterEval),
            ",\"terminal_M\":",
            vm.toString(terminal),
            "}"
        );
    }

    function test_storage_K_agreed() public {
        uint256[3] memory ks = [uint256(1), 10, 100];
        string memory out = "[";
        for (uint256 t = 0; t < 3; t++) {
            if (t > 0) {
                out = string.concat(out, ",");
            }
            out = string.concat(out, _kRun(true, ks[t]), ",", _kRun(false, ks[t]));
        }
        out = string.concat(out, "]");
        vm.writeFile("outputs/storage/active_k.json", out);
    }

    function _kRun(bool blade, uint256 k) internal returns (string memory json) {
        address I;
        address P;
        if (blade) {
            I = address(new BladeRequester());
            P = address(new BladeParticipant());
        } else {
            I = address(new ManualInitiator());
            P = address(new ManualParticipant());
        }
        bytes32[] storage wI = _scratch(I);
        bytes32[] storage wP = _scratch(P);
        vm.record();
        bytes memory payload = _payload(0);
        for (uint256 i = 0; i < k; i++) {
            bytes32 id = keccak256(abi.encode(i));
            if (blade) {
                BladeRequester(I).startRequest(P, id, payload);
                Message memory req;
                req.performative = uint8(Performative.Request);
                req.protocol = uint8(Protocol.FipaRequest);
                req.conversationId = id;
                BladeParticipant(P).agree(req, I);
            } else {
                ManualInitiator(I).startRequest(P, id, payload);
                ManualParticipant(P).agree(id);
            }
        }
        _merge(I, wI);
        _merge(P, wP);
        uint256 active = _nonzero(I, wI) + _nonzero(P, wP);
        bytes32 keep = keccak256(abi.encode(uint256(1)));
        bytes32 drop = keccak256(abi.encode(uint256(0)));
        if (k >= 2) {
            if (blade) {
                Message memory req;
                req.performative = uint8(Performative.Request);
                req.protocol = uint8(Protocol.FipaRequest);
                req.conversationId = drop;
                BladeParticipant(P).inform(req, I, payload);
            } else {
                ManualParticipant(P).inform(drop, payload);
            }
            _merge(I, wI);
            _merge(P, wP);
            if (blade) {
                require(uint8(BladeRequester(I).requestStatus(keep).phase) == 2, "isolation");
            }
        }
        for (uint256 i = 0; i < k; i++) {
            bytes32 id = keccak256(abi.encode(i));
            if (blade) {
                if (uint8(BladeRequester(I).requestStatus(id).phase) == 0) {
                    continue;
                }
                Message memory req;
                req.performative = uint8(Performative.Request);
                req.protocol = uint8(Protocol.FipaRequest);
                req.conversationId = id;
                BladeParticipant(P).inform(req, I, payload);
            } else {
                if (ManualInitiator(I).status(id).phase == 0) {
                    continue;
                }
                ManualParticipant(P).inform(id, payload);
            }
        }
        _merge(I, wI);
        _merge(P, wP);
        uint256 terminal = _nonzero(I, wI) + _nonzero(P, wP);
        json = string.concat(
            "{\"implementation\":\"",
            blade ? "blade" : "manual",
            "\",\"K\":",
            vm.toString(k),
            ",\"active_slots_IP\":",
            vm.toString(active),
            ",\"terminal_slots_IP\":",
            vm.toString(terminal),
            "}"
        );
    }
}
