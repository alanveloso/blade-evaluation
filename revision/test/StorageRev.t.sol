// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RevisionBase} from "./RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {ManualInitiator, ManualParticipant} from "app/manual/ManualRequest.sol";

/// @dev Revision of the Request storage probe (comparison/test/StoragePilot.t.sol stays unchanged).
/// Non-zero written slots are split into session slots (must return to zero at the end of the
/// conversation) and the persistent nonce slot (slot 1: `RequestAgent._requestNonce` on E2, `_nonce`
/// in the correlated purpose-built variant), which is never cleared by design.
contract StorageRevTest is RevisionBase {
    bytes32 internal constant CID = keccak256("f2-store");
    bytes32 internal constant NONCE_SLOT = bytes32(uint256(1));

    mapping(address => bytes32[]) internal _acc;

    struct Count {
        uint256 session;
        uint256 persistent;
    }

    function _scratch(address a) internal returns (bytes32[] storage) {
        delete _acc[a];
        return _acc[a];
    }

    function _merge(address a) internal {
        (, bytes32[] memory w) = vm.accesses(a);
        bytes32[] storage acc = _acc[a];
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

    function _count(address a) internal view returns (Count memory c) {
        bytes32[] storage acc = _acc[a];
        for (uint256 i = 0; i < acc.length; i++) {
            if (vm.load(a, acc[i]) == bytes32(0)) {
                continue;
            }
            if (acc[i] == NONCE_SLOT) {
                c.persistent++;
            } else {
                c.session++;
            }
        }
    }

    function _payloadInStorage(address a, bytes memory payload) internal view returns (bool) {
        if (payload.length < 32) {
            return false;
        }
        bytes32 needle;
        assembly {
            needle := mload(add(payload, 32))
        }
        bytes32[] storage acc = _acc[a];
        for (uint256 i = 0; i < acc.length; i++) {
            if (vm.load(a, acc[i]) == needle) {
                return true;
            }
        }
        return false;
    }

    function _deploy(bool blade) internal returns (address I, address P) {
        if (blade) {
            I = address(new BladeRequester());
            P = address(new BladeParticipant());
        } else {
            I = address(new ManualInitiator());
            P = address(new ManualParticipant());
        }
        _scratch(I);
        _scratch(P);
    }

    function _start(bool blade, address I, address P, bytes32 id, bytes memory payload) internal {
        if (blade) {
            BladeRequester(I).startRequest(P, id, payload);
        } else {
            ManualInitiator(I).startRequest(P, id, payload);
        }
    }

    function _agree(bool blade, address I, address P, bytes32 id) internal {
        if (blade) {
            BladeParticipant(P).agree(_reqInbound(id, _token(P, id), ""), I);
        } else {
            ManualParticipant(P).agree(id);
        }
    }

    function _inform(bool blade, address I, address P, bytes32 id, bytes memory payload) internal {
        if (blade) {
            BladeParticipant(P).inform(_reqInbound(id, _token(P, id), ""), I, payload);
        } else {
            ManualParticipant(P).inform(id, payload);
        }
    }

    function _fmt(Count memory c) internal pure returns (string memory) {
        return string.concat(
            "{\"session\":", vm.toString(c.session), ",\"persistent\":", vm.toString(c.persistent), "}"
        );
    }

    function _r3(bool blade, uint256 n) internal returns (string memory json) {
        bytes memory payload = _payload(n, 0xab);
        (address I, address P) = _deploy(blade);
        vm.record();
        _start(blade, I, P, CID, payload);
        _merge(I);
        _merge(P);
        Count memory reqI = _count(I);
        Count memory reqP = _count(P);
        _agree(blade, I, P, CID);
        _merge(I);
        _merge(P);
        Count memory agI = _count(I);
        Count memory agP = _count(P);
        _inform(blade, I, P, CID, payload);
        _merge(I);
        _merge(P);
        Count memory tI = _count(I);
        Count memory tP = _count(P);
        bool needle = _payloadInStorage(I, payload) || _payloadInStorage(P, payload);
        require(tI.session == 0 && tP.session == 0, "session storage not cleared");
        require(!needle, "payload stored");
        json = string.concat(
            "{\"implementation\":\"", blade ? "blade" : "manual", "\",\"path\":\"R3\",\"payload_bytes\":",
            vm.toString(n),
            ",\"requested_I\":", _fmt(reqI), ",\"requested_P\":", _fmt(reqP),
            ",\"agreed_I\":", _fmt(agI), ",\"agreed_P\":", _fmt(agP),
            ",\"terminal_I\":", _fmt(tI), ",\"terminal_P\":", _fmt(tP),
            ",\"payload_in_storage\":false}"
        );
    }

    function test_storage_request_R3() public {
        uint256[4] memory sizes = [uint256(0), 32, 256, 1024];
        string memory out = "[";
        for (uint256 s = 0; s < 4; s++) {
            out = string.concat(out, s == 0 ? "" : ",", _r3(true, sizes[s]), ",", _r3(false, sizes[s]));
        }
        vm.writeFile("outputs/storage/revision_request_r3.json", string.concat(out, "]"));
    }

    function _k(bool blade, uint256 k) internal returns (string memory json) {
        (address I, address P) = _deploy(blade);
        vm.record();
        for (uint256 i = 0; i < k; i++) {
            bytes32 id = keccak256(abi.encode(i));
            _start(blade, I, P, id, "");
            _agree(blade, I, P, id);
        }
        _merge(I);
        _merge(P);
        Count memory aI = _count(I);
        Count memory aP = _count(P);
        for (uint256 i = 0; i < k; i++) {
            _inform(blade, I, P, keccak256(abi.encode(i)), "");
        }
        _merge(I);
        _merge(P);
        Count memory tI = _count(I);
        Count memory tP = _count(P);
        require(tI.session == 0 && tP.session == 0, "session storage not cleared");
        json = string.concat(
            "{\"implementation\":\"", blade ? "blade" : "manual", "\",\"K\":", vm.toString(k),
            ",\"active_I\":", _fmt(aI), ",\"active_P\":", _fmt(aP),
            ",\"terminal_I\":", _fmt(tI), ",\"terminal_P\":", _fmt(tP), "}"
        );
    }

    function test_storage_K_agreed() public {
        uint256[3] memory ks = [uint256(1), 10, 100];
        string memory out = "[";
        for (uint256 t = 0; t < 3; t++) {
            out = string.concat(out, t == 0 ? "" : ",", _k(true, ks[t]), ",", _k(false, ks[t]));
        }
        vm.writeFile("outputs/storage/revision_active_k.json", string.concat(out, "]"));
    }
}
