// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {IBridgehub, IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice all the ether is held by the weth bridge
    IL1SharedBridge public sharedBridge;

    /// @notice we store registered stateTransitionManagers
    mapping(address _stateTransitionManager => bool) public stateTransitionManagerIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address _token => bool) public tokenIsRegistered;

    /// @notice chainID => StateTransitionManager contract address, storing StateTransitionManager
    mapping(uint256 _chainId => address) public stateTransitionManager;

    /// @dev used to indicate the currently active settlement layer for a given chainId
    mapping(uint256 chainId => uint256 activeSettlementLayerChainId) public settlementLayer;

    /// @notice chainID => baseToken contract address, storing baseToken
    mapping(uint256 _chainId => address) public baseToken;

    /// @dev used to manage non critical updates
    address public admin;

    /// @dev used to accept the admin role
    address private pendingAdmin;

    /// @dev used to indicate that the contract is deployed on synclayer
    bool public syncLayerMode;

    /// @dev the allowed settlement layers
    mapping(uint256 chainId => bool isWhitelistedSyncLayer) public whitelistedSettlementLayers;

    /// @dev the deployed bridgehub on other chains
    mapping(uint256 chainId => address bridgehubCounterPart) public bridgehubCounterParts;

    /// @notice to avoid parity hack
    constructor() reentrancyGuardInitializer {}

    /// @notice used to initialize the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "Bridgehub: not owner or admin");
        _;
    }

    modifier onlyChainSTM(uint256 _chainId) {
        require(msg.sender == stateTransitionManager[_chainId], "Bridgehub: not chain STM");
        _;
    }

    /// @inheritdoc IBridgehub
    /// @dev Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
    /// `acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights.
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IBridgehub
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        require(msg.sender == currentPendingAdmin, "n42"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    ///// Getters

    /// @notice return the state transition chain contract for a chainId
    function getHyperchain(uint256 _chainId) public view returns (address) {
        return IStateTransitionManager(stateTransitionManager[_chainId]).getHyperchain(_chainId);
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    function addStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            !stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition already registered"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = true;
    }

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the STF, old chains are not affected
    function removeStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered yet"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = false;
    }

    /// @notice token can be any contract with the appropriate interface/functionality
    function addToken(address _token) external onlyOwner {
        require(!tokenIsRegistered[_token], "Bridgehub: token already registered");
        tokenIsRegistered[_token] = true;
    }

    /// @notice To set shared bridge, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, Shared bridge, and then we call this
    function setSharedBridge(address _sharedBridge) external onlyOwner {
        sharedBridge = IL1SharedBridge(_sharedBridge);
    }

    /// FIXME: this method should not be present in the production code.
    /// just used in code to register chain successfully until full migration is complete.
    function unsafeRegisterChain(uint256 _chainId, address _stateTransitionManager, address _baseToken) external {
        require(_chainId != 0, "Bridgehub: chainId cannot be 0");
        require(_chainId <= type(uint48).max, "Bridgehub: chainId too large");

        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered"
        );
        require(tokenIsRegistered[_baseToken], "Bridgehub: token not registered");
        require(address(sharedBridge) != address(0), "Bridgehub: weth bridge not set");

        require(stateTransitionManager[_chainId] == address(0), "Bridgehub: chainId already registered");

        stateTransitionManager[_chainId] = _stateTransitionManager;
        baseToken[_chainId] = _baseToken;
    }

    /// @notice register new chain
    /// @notice for Eth the baseToken address is 1
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        // solhint-disable-next-line no-unused-vars
        uint256 _salt,
        address _admin,
        bytes calldata _initData
    ) external onlyOwnerOrAdmin nonReentrant whenNotPaused returns (uint256) {
        require(_chainId != 0, "Bridgehub: chainId cannot be 0");
        require(_chainId <= type(uint48).max, "Bridgehub: chainId too large");

        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered"
        );
        require(tokenIsRegistered[_baseToken], "Bridgehub: token not registered");
        require(address(sharedBridge) != address(0), "Bridgehub: weth bridge not set");

        require(stateTransitionManager[_chainId] == address(0), "Bridgehub: chainId already registered");

        stateTransitionManager[_chainId] = _stateTransitionManager;
        baseToken[_chainId] = _baseToken;

        IStateTransitionManager(_stateTransitionManager).createNewChain({
            _chainId: _chainId,
            _baseToken: _baseToken,
            _sharedBridge: address(sharedBridge),
            _admin: _admin,
            _diamondCut: _initData
        });

        emit NewChain(_chainId, _stateTransitionManager, _admin);
        return _chainId;
    }

    //// Mailbox forwarder

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address hyperchain = getHyperchain(_chainId);
        return IZkSyncHyperchain(hyperchain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address hyperchain = getHyperchain(_chainId);
        return IZkSyncHyperchain(hyperchain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address hyperchain = getHyperchain(_chainId);
        return
            IZkSyncHyperchain(hyperchain).proveL1ToL2TransactionStatus({
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: _status
            });
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address hyperchain = getHyperchain(_chainId);
        return IZkSyncHyperchain(hyperchain).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /// @notice the mailbox is called directly after the sharedBridge received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the sharedBridge.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) public payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        {
            address token = baseToken[_request.chainId];
            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue, "Bridgehub: msg.value mismatch 1");
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
            }

            // slither-disable-next-line arbitrary-send-eth
            sharedBridge.bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                msg.sender,
                token,
                _request.mintValue
            );
        }

        address hyperchain = getHyperchain(_request.chainId);
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);
        canonicalTxHash = IZkSyncHyperchain(hyperchain).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: refundRecipient
            })
        );
    }

    /// @notice After depositing funds to the sharedBridge, the secondBridge is called
    ///  to return the actual L2 message which is sent to the Mailbox.
    ///  This assumes that either ether is the base token or
    ///  the msg.sender has approved the sharedBridge with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        {
            address token = baseToken[_request.chainId];
            uint256 baseTokenMsgValue;
            if (token == ETH_TOKEN_ADDRESS) {
                require(
                    msg.value == _request.mintValue + _request.secondBridgeValue,
                    "Bridgehub: msg.value mismatch 2"
                );
                baseTokenMsgValue = _request.mintValue;
            } else {
                require(msg.value == _request.secondBridgeValue, "Bridgehub: msg.value mismatch 3");
                baseTokenMsgValue = 0;
            }
            // slither-disable-next-line arbitrary-send-eth
            sharedBridge.bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                msg.sender,
                token,
                _request.mintValue
            );
        }

        address hyperchain = getHyperchain(_request.chainId);

        // slither-disable-next-line arbitrary-send-eth
        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1SharedBridge(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.l2Value,
            _request.secondBridgeCalldata
        );

        require(outputRequest.magicValue == TWO_BRIDGES_MAGIC_VALUE, "Bridgehub: magic value mismatch");

        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);

        require(
            _request.secondBridgeAddress > BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS,
            "Bridgehub: second bridge address too low"
        ); // to avoid calls to precompiles
        canonicalTxHash = IZkSyncHyperchain(hyperchain).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: _request.secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: refundRecipient
            })
        );

        IL1SharedBridge(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }

    function forwardTransactionOnSyncLayer(
        uint256 _chainId,
        BridgehubL2TransactionRequest calldata _request
    ) external override {
        require(syncLayerMode, "Bridgehub: not in sync layer mode");
        address hyperchain = getHyperchain(_chainId);
        IZkSyncHyperchain(hyperchain).bridgehubRequestL2Transaction(_request);
    }

    function registerCounterpart(uint256 _chainId, address _counterPart) external onlyOwner {
        require(_counterPart != address(0), "STM: counter part zero");

        bridgehubCounterParts[_chainId] = _counterPart;
    }

    function registerSyncLayer(
        uint256 _newSyncLayerChainId,
        bool _isWhitelisted
    ) external onlyChainSTM(_newSyncLayerChainId) {
        whitelistedSettlementLayers[_newSyncLayerChainId] = _isWhitelisted;

        // TODO: emit event
    }

    /// @dev we can move assets using these
    function startMigrationFromL1(
        L2TransactionRequestDirect memory _request,
        uint256 _migratingChainId,
        address _newSyncLayerAdmin,
        bytes memory _diamondCut
    ) external payable override returns (bytes memory _bridgeMintData) {
        require(!syncLayerMode, "Bh: in sync layer mode");
        uint256 settlementChainId = _request.chainId;
        require(msg.sender == IZkSyncHyperchain(getHyperchain(_migratingChainId)).getAdmin(), "Bh: not chain STM");
        require(whitelistedSettlementLayers[settlementChainId], "Bh: stl not whitelisted");
        require(settlementLayer[_migratingChainId] == block.chainid, "Bh: already migrated");
        require(_newSyncLayerAdmin != address(0), "STM: admin zero");

        IERC20 token = IERC20(baseToken[settlementChainId]);
        token.safeTransferFrom(msg.sender, address(this), _request.mintValue);
        token.safeIncreaseAllowance(address(sharedBridge), _request.mintValue);

        settlementLayer[_migratingChainId] = settlementChainId;

        bytes memory chainData = IZkSyncHyperchain(getHyperchain(_migratingChainId)).startMigration(
            settlementChainId
        );
        bytes memory l2Calldata = abi.encodeCall(this.finalizeMigrationToSL.selector, [_request, _newSyncLayerAdmin, _diamondCut]);

        canonicalTxHash = this.requestL2TransactionDirect(
            L2TransactionRequestDirect({
                chainId: settlementChainId,
                mintValue: _request.mintValue,
                contractL2: bridgehubCounterParts[_settlementChainId],
                l2Value: 0,
                l2Calldata: l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: refundRecipient
            })
        );

    }

    function bridgeMint(uint256 _chainId, bytes32 _assetInfo, bytes calldata _data) external payable override {}

    function bridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override {}

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
