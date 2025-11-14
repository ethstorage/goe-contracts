// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFlatDirectoryFactory} from "./interfaces/IFlatDirectoryFactory.sol";
import {GoeRepo} from "./GoeRepo.sol";

contract GoeHub is Ownable, ReentrancyGuard {
    event RepoCreated(address indexed repo, address indexed creator, bytes repoName);
    event ImplementationUpdated(address indexed oldImp, address indexed newImp);
    event FDFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    address public fdFactory;
    address public repoImpl;

    struct RepoInfo {
        address repoAddress;
        uint256 creationTime;
        bytes repoName;
    }

    mapping(address => RepoInfo[]) public reposOf; //  creator => repos

    constructor(address _fdFactory) Ownable(msg.sender) {
        require(_fdFactory != address(0), "EthfsHub: invalid db factory");
        fdFactory = _fdFactory;
        repoImpl = address(new GoeRepo());
    }

    function setRepoImplementation(address _newImp) external onlyOwner {
        require(_newImp != address(0), "EthfsHub: invalid implementation");
        emit ImplementationUpdated(repoImpl, _newImp);
        repoImpl = _newImp;
    }

    function setFdFactory(address _newFactory) external onlyOwner {
        require(_newFactory != address(0), "EthfsHub: invalid db factory");
        emit FDFactoryUpdated(fdFactory, _newFactory);
        fdFactory = _newFactory;
    }

    function createRepo(bytes memory repoName) external nonReentrant returns (address) {
        address repoInstance = Clones.clone(repoImpl);
        GoeRepo(payable(repoInstance)).initialize(msg.sender, repoName, IFlatDirectoryFactory(fdFactory));

        RepoInfo memory info = RepoInfo({repoAddress: repoInstance, creationTime: block.timestamp, repoName: repoName});
        reposOf[msg.sender].push(info);

        emit RepoCreated(repoInstance, msg.sender, repoName);

        return repoInstance;
    }

    // ---------------------- query ----------------------
    function getUserRepoCount(address user) external view returns (uint256) {
        return reposOf[user].length;
    }

    function getUserReposPaginated(address user, uint256 start, uint256 limit)
        external
        view
        returns (RepoInfo[] memory)
    {
        RepoInfo[] storage userRepos = reposOf[user];

        uint256 end = start + limit;
        if (end > userRepos.length) end = userRepos.length;
        uint256 count = end > start ? end - start : 0;

        RepoInfo[] memory result = new RepoInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = userRepos[start + i];
        }
        return result;
    }
}
