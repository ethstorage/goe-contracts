// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IFlatDirectoryFactory} from "./interfaces/IFlatDirectoryFactory.sol";
import {IFlatDirectory} from "./interfaces/IFlatDirectory.sol";

contract GoeRepo is Initializable, AccessControlUpgradeable, ReentrancyGuard {
    // Role definitions - Minimum permission set
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");
    bytes32 public constant PUSHER_ROLE = keccak256("PUSHER_ROLE");

    // Event definitions - Record key information only
    event RefUpdated(bytes32 indexed refKey, bytes20 oldOid, bytes20 newOid);
    event ForceRefUpdated(bytes32 indexed refKey, bytes20 oldOid, bytes20 newOid);
    event BranchDeleted(bytes32 indexed refKey);
    event DefaultBranchChanged(bytes oldBranch, bytes newBranch);

    // Lightweight Commit Information - Minimal data storage
    struct PushRecord {
        bytes20 newOid; // Final commit oid of the current push
        bytes20 parentOid; // Parent commit oid, used to build history chain
        bytes packfileKey; // Key for storing the packfile
        uint256 size; // Packfile size
        uint256 timestamp; // Timestamp
        address pusher; // Pusher address
    }

    // Branch Metadata (Core: activeLength maintains the logical number of valid records)
    struct Branch {
        bytes20 headOid; // Latest commit oid of the branch
        uint256 activeLength; // Logical count of valid records (core field, replaces array length)
        bool exists; // Whether the branch exists
        address creator; // branch creator
    }

    // Branch list query return structure
    struct RefData {
        bytes name; // Branch name
        bytes20 hash; // Latest commit oid of the branch
    }

    // ======================== Core Storage ========================
    // Repository metadata
    bytes public repoName;
    bytes public defaultBranchName;
    address public flatDirectory; // Address of the file storing packfiles

    // Branch mapping: refKey (hash of branch name) → Branch info
    mapping(bytes32 => Branch) private _branches; // refKey => Branch information
    // Push Record mapping: refKey → Physical Array (data is never deleted, filtered by activeLength)
    mapping(bytes32 => PushRecord[]) private _branchRecords;

    bytes[] private _branchNames; // All branch names (for enumeration)
    // Branch Name Index mapping: Quick lookup of branch name's position in _branchNames (used for deletion)
    mapping(bytes32 => uint256) private _branchNameIndex;

    // Initialization function
    function initialize(address _owner, bytes memory _repoName, IFlatDirectoryFactory _flatDirectoryFactory)
        external
        initializer
    {
        __AccessControl_init();

        require(_owner != address(0), "EthfsRepo: Invalid owner");
        require(_repoName.length > 0 && _repoName.length <= 100, "EthfsRepo: Invalid repo name length");
        for (uint256 i; i < _repoName.length; i++) {
            bytes1 char = _repoName[i];
            require(
                (char >= 0x61 && char <= 0x7A) // a-z
                    || (char >= 0x41 && char <= 0x5A) // A-Z
                    || (char >= 0x30 && char <= 0x39) // 0-9
                    || (char == 0x2D || char == 0x2E || char == 0x5F), // -._
                "EthfsRepo: Repo name must be alphanumeric or -._"
            );
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(MAINTAINER_ROLE, _owner);
        _grantRole(PUSHER_ROLE, _owner);

        repoName = _repoName;
        flatDirectory = _flatDirectoryFactory.create();
    }

    // ======================== Permission ========================
    modifier onlyPusher() {
        _onlyPusher();
        _;
    }

    function _onlyPusher() internal view {
        require(
            hasRole(PUSHER_ROLE, msg.sender) || hasRole(MAINTAINER_ROLE, msg.sender)
                || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "EthfsRepo: No push permission"
        );
    }

    modifier onlyMaintainer() {
        _onlyMaintainer();
        _;
    }

    function _onlyMaintainer() internal view {
        require(
            hasRole(MAINTAINER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "EthfsRepo: No maintainer permission"
        );
    }

    function canPush(address account) external view returns (bool) {
        return
            hasRole(PUSHER_ROLE, account) || hasRole(MAINTAINER_ROLE, account) || hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function canForcePush(address account, bytes calldata refName) external view returns (bool) {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        return account == branch.creator || hasRole(MAINTAINER_ROLE, account) || hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function canMaintain(address account) external view returns (bool) {
        return hasRole(MAINTAINER_ROLE, account) || hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function addPusher(address account) external onlyMaintainer {
        grantRole(PUSHER_ROLE, account);
    }

    function removePusher(address account) external onlyMaintainer {
        revokeRole(PUSHER_ROLE, account);
    }

    function addMaintainer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(MAINTAINER_ROLE, account);
    }

    // ======================== Core Business Functions ========================
    /**
     * @dev Normal push (fast-forward)
     * Core: Uses indexed assignment instead of push, marks valid records via activeLength.
     */
    function push(
        bytes calldata refName,
        bytes20 parentOid,
        bytes20 newOid,
        bytes calldata packfileKey,
        uint256 packfileSize
    ) external onlyPusher nonReentrant {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey]; // Reference to the physical array

        uint256 realSize = IFlatDirectory(flatDirectory).size(packfileKey);
        require(realSize == packfileSize, "File not uploaded or size mismatch");

        // 1. First push to this branch
        if (!branch.exists) {
            require(parentOid == bytes20(0), "EthfsRepo: First push must have no parent");
            branch.headOid = newOid;
            branch.exists = true;
            branch.creator = msg.sender;
            branch.activeLength = 0; // Initial active length is 0 (no valid records yet)

            // Record branch name and index
            _branchNameIndex[refKey] = _branchNames.length;
            _branchNames.push(refName);

            // If default branch is not set, set it to the current branch
            if (defaultBranchName.length == 0) {
                defaultBranchName = refName;
            }
        }
        // 2. Subsequent push (must be fast-forward: Parent OID must match current branch head)
        else {
            require(branch.headOid == parentOid, "EthfsRepo: Non fast-forward push not allowed");
            branch.headOid = newOid;
        }

        // 3. Core: Use indexed assignment instead of push, do not modify physical array length explicitly
        // Assign to the index corresponding to the "current active length" (physical array auto-expands if needed)
        PushRecord memory newRecord = PushRecord({
            newOid: newOid,
            parentOid: parentOid,
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });
        _writeRecord(records, branch.activeLength, newRecord);
        // Increment logical active length (marks this record as valid)
        branch.activeLength++;

        // Emit event
        emit RefUpdated(refKey, parentOid, newOid);
    }

    /**
     * @dev Force push (supports three scenarios)
     * 1. Delete Branch: newOid=0 → activeLength=0 + marks exists=false
     * 2. Full History Replacement: parentOid=0 → activeLength reset to 0, then add 1 new record
     * 3. Partial History Replacement: parentOid≠0 → activeLength truncated to parentIndex+1, then add 1 new record
     */
    function forcePush(
        bytes calldata refName,
        bytes20 newOid,
        bytes calldata packfileKey,
        uint256 packfileSize,
        bytes20 parentOid,
        uint256 parentIndex
    ) external nonReentrant {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey];
        require(branch.exists, "EthfsRepo: Branch does not exist");
        require(
            msg.sender == branch.creator || hasRole(MAINTAINER_ROLE, msg.sender)
                || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "EthfsRepo: No permission to push or delete branch"
        );

        bytes20 oldOid = branch.headOid; // Record old head for event traceability

        // Scenario 1: Delete Branch (newOid=0)
        if (newOid == bytes20(0)) {
            _handleBranchDeletion(refKey, branch);
            return;
        }

        // check packfile
        uint256 realSize = IFlatDirectory(flatDirectory).size(packfileKey);
        require(realSize == packfileSize, "File not uploaded or size mismatch");

        // Scenario 2: Full History Replacement (parentOid=0)
        if (parentOid == bytes20(0)) {
            _handleFullHistoryReplacement(refKey, branch, records, oldOid, newOid, packfileKey, packfileSize);
            return;
        }

        // Scenario 3: Partial History Replacement (parentOid≠0)
        _handlePartialHistoryReplacement(
            refKey, branch, records, oldOid, newOid, packfileKey, packfileSize, parentOid, parentIndex
        );
    }

    function _handleBranchDeletion(bytes32 refKey, Branch storage branch) private {
        bytes32 defaultRefKey = _keccak256(defaultBranchName);
        require(refKey != defaultRefKey, "EthfsRepo: Cannot delete default branch");

        // 1. Remove branch name from _branchNames (O(1) swap-and-pop)
        uint256 branchIdx = _branchNameIndex[refKey];
        require(branchIdx < _branchNames.length, "EthfsRepo: Branch not in name list");

        if (branchIdx < _branchNames.length - 1) {
            bytes memory lastBranchName = _branchNames[_branchNames.length - 1];
            bytes32 lastRefKey = _keccak256(lastBranchName);
            _branchNameIndex[lastRefKey] = branchIdx;
            _branchNames[branchIdx] = lastBranchName;
        }
        _branchNames.pop();
        delete _branchNameIndex[refKey];

        // 2. Logical clear
        branch.activeLength = 0;
        branch.headOid = bytes20(0);
        branch.creator = address(0);
        branch.exists = false;

        emit BranchDeleted(refKey);
    }

    function _handleFullHistoryReplacement(
        bytes32 refKey,
        Branch storage branch,
        PushRecord[] storage records,
        bytes20 oldOid,
        bytes20 newOid,
        bytes calldata packfileKey,
        uint256 packfileSize
    ) private {
        // 1. Logical clear of old records
        branch.activeLength = 0;

        // 2. Add new record (index=0)
        PushRecord memory newRecord = PushRecord({
            newOid: newOid,
            parentOid: bytes20(0),
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });
        _writeRecord(records, 0, newRecord);
        branch.activeLength = 1;

        // 3. Update branch head
        branch.headOid = newOid;

        emit ForceRefUpdated(refKey, oldOid, newOid);
    }

    function _handlePartialHistoryReplacement(
        bytes32 refKey,
        Branch storage branch,
        PushRecord[] storage records,
        bytes20 oldOid,
        bytes20 newOid,
        bytes calldata packfileKey,
        uint256 packfileSize,
        bytes20 parentOid,
        uint256 parentIndex
    ) private {
        require(parentIndex < branch.activeLength, "EthfsRepo: Parent index out of valid range");
        require(records[parentIndex].newOid == parentOid, "EthfsRepo: Parent OID not match");

        // 1. Logical truncation: Active length set to parentIndex + 1
        uint256 nextIndex = parentIndex + 1;
        branch.activeLength = nextIndex;

        // 2. Add new record (index=nextIndex)
        PushRecord memory newRecord = PushRecord({
            newOid: newOid,
            parentOid: parentOid,
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });
        _writeRecord(records, nextIndex, newRecord);
        branch.activeLength++; // Active length + 1

        // 3. Update branch head
        branch.headOid = newOid;

        emit ForceRefUpdated(refKey, oldOid, newOid);
    }

    // Set default branch
    function setDefaultBranch(bytes calldata branchName) external onlyMaintainer {
        bytes32 refKey = _keccak256(branchName);
        require(_branches[refKey].exists, "EthfsRepo: Branch not exists");

        bytes memory oldBranch = defaultBranchName;
        defaultBranchName = branchName;

        emit DefaultBranchChanged(oldBranch, branchName);
    }

    // ======================== Query ========================
    /**
     * @dev Paginates and retrieves the list of branches (only returns active branches).
     */
    function listBranches(uint256 start, uint256 limit) external view returns (RefData[] memory list) {
        uint256 end = start + limit;
        if (end > _branchNames.length) {
            end = _branchNames.length;
        }

        uint256 count = end > start ? end - start : 0;
        list = new RefData[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes memory branchName = _branchNames[start + i];
            bytes32 refKey = _keccak256(branchName);
            list[i] = RefData({name: branchName, hash: _branches[refKey].headOid});
        }
    }

    /**
     * @dev Gets the total count of active branches.
     */
    function getBranchCount() external view returns (uint256) {
        return _branchNames.length;
    }

    /**
     * @dev Gets the default branch information.
     */
    function getDefaultBranch() external view returns (bytes memory name, bytes20 headOid) {
        bytes32 refKey = _keccak256(defaultBranchName);
        return (defaultBranchName, _branches[refKey].headOid);
    }

    /**
     * @dev Gets the latest head information for a branch.
     */
    function getBranchHead(bytes calldata refName) external view returns (bytes20 headOid, bool exists) {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        return (branch.headOid, branch.exists);
    }

    /**
     * @dev Paginates and retrieves push records (only returns logically valid records).
     */
    function getPushRecords(bytes calldata refName, uint256 startIndex, uint256 count)
        external
        view
        returns (PushRecord[] memory)
    {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey];
        require(branch.exists, "EthfsRepo: Branch not exists");

        // Boundary 1: If startIndex is out of the active range, return an empty array
        if (startIndex >= branch.activeLength) {
            return new PushRecord[](0);
        }
        // Boundary 2: endIndex must not exceed the logical active length
        uint256 endIndex = startIndex + count;
        if (endIndex > branch.activeLength) {
            endIndex = branch.activeLength;
        }

        // Assemble the valid records
        uint256 resultCount = endIndex - startIndex;
        PushRecord[] memory results = new PushRecord[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            results[i] = records[startIndex + i]; // Only retrieve records within the active range
        }
        return results;
    }

    function getPushRecordCount(bytes calldata refName) external view returns (uint256 count) {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        count = branch.activeLength;
    }

    // ---------------------- Database fallback ----------------------

    // Database interaction proxy (forward necessary calls only)
    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes4 selector;
        assembly {
            // Correctly load the 4-byte selector from the high-order bytes of calldata(0)
            // by right-shifting the 32-byte word by 224 bits.
            selector := shr(224, calldataload(0))
        }

        // Write check: Restrict access to flatDirectory write functions to authorized roles
        if (
            selector == 0xc1d71b17 // writeChunksByBlobs
                || selector == 0x6c0a0207 // remove
                || selector == 0x4d705e59 // truncate
        ) {
            require(
                hasRole(PUSHER_ROLE, msg.sender) || hasRole(MAINTAINER_ROLE, msg.sender)
                    || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
                "EthfsRepo: No write permission"
            );
        }

        (bool success, bytes memory result) = flatDirectory.call{value: msg.value}(data);
        if (!success) {
            // Revert with the returned data from the call (standard pattern)
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }

    receive() external payable {}

    // ---------------------- Internal Helpers ----------------------

    /**
     * @dev Gas-optimized keccak256 hash using inline assembly.
     * @param data The bytes array to hash.
     * @return result The 32-byte hash.
     */
    function _keccak256(bytes memory data) internal pure returns (bytes32 result) {
        // The KECCAK256 opcode is used directly via assembly, which is more
        // gas-efficient than the Solidity builtin function for dynamic data.
        assembly {
            // data is at p; data length is mload(data)
            // Actual content starts 32 bytes after the pointer (skipping the length)
            result := keccak256(add(data, 32), mload(data))
        }
    }

    /**
     * @dev Safely writes a PushRecord to the array based on the current activeLength.
     * Performs an in-place overwrite if records.length > activeLength,
     * or calls push() if records.length == activeLength to expand the physical array.
     * @param records The physical PushRecord[] storage array.
     * @param activeLength The current logical length (the index where the new record should go).
     * @param newRecord The record data to write.
     */
    function _writeRecord(PushRecord[] storage records, uint256 activeLength, PushRecord memory newRecord) internal {
        // 1. Case: Physical array is large enough (records.length > activeLength)
        // This occurs after a forcePush has logically truncated the array. We safely overwrite the old, invalid data.
        if (records.length > activeLength) {
            records[activeLength] = newRecord;
        }
        // 2. Case: Physical array is exactly at the logical limit (records.length == activeLength)
        // This is the normal appending case. We must use push() to physically expand the array by one.
        else if (records.length == activeLength) {
            records.push(newRecord);
        }
        // 3. Case: Integrity check (records.length < activeLength)
        // This should never happen and indicates a storage corruption.
        else {
            revert("EthfsRepo: Storage corruption (Active length exceeds physical length)");
        }
    }
}
