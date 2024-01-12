// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";
import {L2Message} from "../../../../../../cache/solpp-generated-contracts/common/Messaging.sol";
import {IMailbox} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-interfaces/IMailbox.sol";

/* solhint-enable max-line-length */

contract ProveL2MessageInclusionTest is BridgehubMailboxTest {
    uint256 internal blockNumber;
    uint256 internal index;
    L2Message internal message;
    bytes32[] internal proof;

    function setUp() public {
        blockNumber = 3456789;
        index = 234567890;
        proof = new bytes32[](1);

        uint16 txNumberInBlock = 12345;
        address sender = makeAddr("sender");
        bytes memory data = "data";
        message = L2Message(txNumberInBlock, sender, data);
    }

    function test_WhenChainContractReturnsTrue() public {
        vm.mockCall(
            bridgehub.getChainContract(chainId),
            abi.encodeWithSelector(IMailbox.proveL2MessageInclusion.selector, blockNumber, index, message, proof),
            abi.encode(true)
        );

        vm.expectCall(
            bridgehub.getChainContract(chainId),
            abi.encodeWithSelector(IMailbox.proveL2MessageInclusion.selector, blockNumber, index, message, proof)
        );

        bool res = bridgehub.proveL2MessageInclusion(chainId, blockNumber, index, message, proof);
        assertEq(res, true, "L2 message should be included");
    }

    function test_WhenChainContractReturnsFalse() public {
        vm.mockCall(
            bridgehub.getChainContract(chainId),
            abi.encodeWithSelector(IMailbox.proveL2MessageInclusion.selector, blockNumber, index, message, proof),
            abi.encode(false)
        );

        vm.expectCall(
            bridgehub.getChainContract(chainId),
            abi.encodeWithSelector(IMailbox.proveL2MessageInclusion.selector, blockNumber, index, message, proof)
        );

        bool res = bridgehub.proveL2MessageInclusion(chainId, blockNumber, index, message, proof);
        assertEq(res, false, "L2 message should not be included");
    }
}