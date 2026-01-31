// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @custom:security-contact security@roar.io
/// @notice RoarToken - ERC20 token with voting, permit, and admin features
/// @dev Designed to work with ERC-1167 minimal proxy pattern for gas-efficient deployment
contract RoarToken is ERC20, ERC20Permit, ERC20Votes, ERC20Burnable {
    error NotAdmin();
    error NotCreator();
    error AlreadyVerified();

    /// @notice Tracks if this contract instance has been initialized
    bool private _initialized;

    /// @notice The original admin/creator who deployed this token
    address private _creator;

    /// @notice Current admin address (can be transferred)
    address private _admin;

    /// @notice Token metadata (stored for clones)
    string private _nameStorage;
    string private _symbolStorage;
    string private _metadata;
    string private _context;
    string private _image;

    /// @notice Verification status
    bool private _verified;

    event Initialized(address indexed admin, string name, string symbol);
    event Verified(address indexed admin, address indexed token);
    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Constructor for implementation contract only
    /// @dev This constructor is only called once for the master implementation
    constructor() ERC20("", "") ERC20Permit("") {}

    /// @notice Initializes a new token clone instance
    /// @dev This function replaces constructor logic for minimal proxy clones
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param maxSupply_ Maximum token supply to mint on initial chain
    /// @param admin_ Initial admin address (also becomes creator)
    /// @param image_ Token image URL
    /// @param metadata_ Token metadata
    /// @param context_ Token context
    /// @param initialSupplyChainId_ Chain ID where initial supply is minted
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin_,
        string memory image_,
        string memory metadata_,
        string memory context_,
        uint256 initialSupplyChainId_
    ) external {
        require(!_initialized, "Already initialized");
        _initialized = true;

        // Store name and symbol in storage (for clones)
        _nameStorage = name_;
        _symbolStorage = symbol_;

        // Set admin and creator
        _admin = admin_;
        _creator = admin_;

        // Set metadata
        _image = image_;
        _metadata = metadata_;
        _context = context_;

        emit Initialized(admin_, name_, symbol_);

        // Only mint initial supply on a single chain
        if (block.chainid == initialSupplyChainId_) {
            _mint(admin_, maxSupply_);
        }
    }

    /// @notice Get the token name - override to support clones
    /// @dev Returns stored name for clones, empty for implementation
    function name() public view override returns (string memory) {
        return _nameStorage;
    }

    /// @notice Get the token symbol - override to support clones
    /// @dev Returns stored symbol for clones, empty for implementation
    function symbol() public view override returns (string memory) {
        return _symbolStorage;
    }

    function updateAdmin(address admin_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        address oldAdmin = _admin;
        _admin = admin_;
        emit UpdateAdmin(oldAdmin, admin_);
    }

    function updateImage(string memory image_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _image = image_;
        emit UpdateImage(image_);
    }

    function updateMetadata(string memory metadata_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function verify() external {
        if (msg.sender != _creator) {
            revert NotCreator();
        }
        if (_verified) {
            revert AlreadyVerified();
        }
        _verified = true;
        emit Verified(msg.sender, address(this));
    }

    function isVerified() external view returns (bool) {
        return _verified;
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function admin() external view returns (address) {
        return _admin;
    }

    function originalAdmin() external view returns (address) {
        return _creator;
    }

    function imageUrl() external view returns (string memory) {
        return _image;
    }

    function metadata() external view returns (string memory) {
        return _metadata;
    }

    function context() external view returns (string memory) {
        return _context;
    }

    /// @notice Get all token data in one call
    function allData()
        external
        view
        returns (
            address originalAdminValue,
            address adminValue,
            string memory image,
            string memory metadataValue,
            string memory contextValue
        )
    {
        return (_creator, _admin, _image, _metadata, _context);
    }

    function supportsInterface(bytes4 _interfaceId) public pure returns (bool) {
        return _interfaceId == type(IERC20).interfaceId || _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC5805).interfaceId;
    }
}
