// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFlatDirectoryFactory} from "./interfaces/IFlatDirectoryFactory.sol";
import {GoeRepo} from "./GoeRepo.sol";

contract GoeHub is Ownable, ReentrancyGuard {
    event RepoCreated(address indexed repo, address indexed owner, bytes repoName);
    event ImplementationUpdated(address indexed oldImp, address indexed newImp);
    event FDFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    struct RepoInfo {
        address repoAddress;
        uint256 creationTime;
        bytes repoName;
    }

    address public fdFactory;
    address public repoImpl;
    mapping(address => RepoInfo[]) public reposOf; //  owner => repos
    mapping(address => mapping(bytes32 => address)) private _repoByName; // owner => nameHash => repo

    constructor(address fdFactory_) Ownable(msg.sender) {
        require(fdFactory_ != address(0), "GoeHub: invalid db factory");
        fdFactory = fdFactory_;
        repoImpl = address(new GoeRepo());
    }

    function setRepoImplementation(address newImp) external onlyOwner {
        require(newImp != address(0), "GoeHub: invalid implementation");
        emit ImplementationUpdated(repoImpl, newImp);
        repoImpl = newImp;
    }

    function setFdFactory(address newFactory) external onlyOwner {
        require(newFactory != address(0), "GoeHub: invalid db factory");
        emit FDFactoryUpdated(fdFactory, newFactory);
        fdFactory = newFactory;
    }

    function createRepo(bytes memory repoName) external nonReentrant returns (address) {
        require(repoName.length > 0, "GoeHub: empty repo name");
        bytes32 nameHash = keccak256(repoName);
        require(_repoByName[msg.sender][nameHash] == address(0), "GoeHub: repo name already exists for owner");

        address repoInstance = Clones.clone(repoImpl);
        GoeRepo(payable(repoInstance)).initialize(msg.sender, repoName, IFlatDirectoryFactory(fdFactory));

        _repoByName[msg.sender][nameHash] = repoInstance;
        RepoInfo memory info = RepoInfo({repoAddress: repoInstance, creationTime: block.timestamp, repoName: repoName});
        reposOf[msg.sender].push(info);

        emit RepoCreated(repoInstance, msg.sender, repoName);

        return repoInstance;
    }

    // ---------------------- query ----------------------
    function getRepoCount(address owner) external view returns (uint256) {
        return reposOf[owner].length;
    }

    function getReposPaginated(address owner, uint256 start, uint256 limit) external view returns (RepoInfo[] memory) {
        RepoInfo[] storage userRepos = reposOf[owner];

        uint256 end = start + limit;
        if (end > userRepos.length) end = userRepos.length;
        uint256 count = end > start ? end - start : 0;

        RepoInfo[] memory result = new RepoInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = userRepos[start + i];
        }
        return result;
    }

    function getRepoByName(address owner, bytes calldata repoName) external view returns (address) {
        return _repoByName[owner][keccak256(repoName)];
    }
}
