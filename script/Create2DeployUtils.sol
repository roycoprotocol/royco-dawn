// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

contract Create2DeployUtils is Script {
    error Create2DeployerNotDeployed();
    error DeploymentFailed(bytes data);
    error AlreadyDeployed(address deployedAddress);
    error NotDeployedToExpectedAddress(address expectedAddress, address deployedAddress);
    error AddressDoesNotContainBytecode(address deployedAddress);

    function deployWithSanityChecks(
        bytes32 _salt,
        bytes memory _creationCode,
        bool _revertIfAlreadyDeployed
    )
        internal
        returns (address, bool isAlreadyDeployed)
    {
        bool debug = vm.envOr("DEBUG", false);

        if (CREATE2_FACTORY_ADDRESS.code.length == 0) {
            revert Create2DeployerNotDeployed();
        }

        address expectedAddress = generateDeterminsticAddress(_salt, _creationCode);

        if (address(expectedAddress).code.length != 0) {
            if (debug) console2.log("Contract already deployed at: ", expectedAddress);

            require(!_revertIfAlreadyDeployed, AlreadyDeployed(expectedAddress));

            return (expectedAddress, true);
        }

        address addr = _deploy(_salt, _creationCode);

        require(addr == expectedAddress, NotDeployedToExpectedAddress(expectedAddress, addr));
        require(address(addr).code.length != 0, AddressDoesNotContainBytecode(addr));

        if (debug) console2.log("Contract deployed at: ", addr);

        return (addr, false);
    }

    function generateDeterminsticAddress(bytes32 _salt, bytes memory _creationCode) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDRESS, _salt, keccak256(_creationCode)));
        return address(uint160(uint256(hash)));
    }

    function getERC1967ProxyCreationCode(address _implementation, bytes memory _initData) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, _initData));
    }

    function _deploy(bytes32 _salt, bytes memory _creationCode) private returns (address deployedAddress) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = CREATE2_FACTORY_ADDRESS.call(abi.encodePacked(_salt, _creationCode));

        require(success, DeploymentFailed(data));

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            deployedAddress := shr(0x60, mload(add(data, 0x20)))
        }
    }
}
