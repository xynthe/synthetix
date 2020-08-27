pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

// Libraries
import "./SafeDecimalMath.sol";

// Internal references
import "./interfaces/ISystemStatus.sol";
import "./interfaces/ISystemSettings.sol";
import "./interfaces/IDelegateApprovals.sol";
import "./interfaces/IExchangeRates.sol";


contract GasTank is Owned, MixinResolver, ReentrancyGuard, MixinSystemSettings {
    /* ========== LIBRARIES ========== */

    using SafeMath for uint;
    using SafeDecimalMath for uint;
    /* ========== STATE VARIABLES ========== */

    /* This value matches the required gas to execute the SpendGas function. It is added to the total gas spent
		so keepers are fully refunded.
     */
    // TODO calculate this value with the tests
    uint public constant PAYGAS_COST = 0;
    mapping(address => bool) public allowance;

    bytes32 public constant CONTRACT_NAME = "GasTank";
    bytes32 public constant DEPOSIT = "DEPOSIT";
    bytes32 public constant MAX_GAS_PRICE = "MAX_GAS_PRICE";

    /* ---------- Address Resolver Configuration ---------- */

    bytes32 internal constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 internal constant CONTRACT_SYSTEMSETTINGS = "SystemSettings";
    bytes32 internal constant CONTRACT_DELEGATEAPPROVALS = "DelegateApprovals";
    bytes32 internal constant CONTRACT_EXCHANGERATES = "ExchangeRates";

    bytes32[24] internal addressesToCache = [
        CONTRACT_SYSTEMSTATUS,
        CONTRACT_SYSTEMSETTINGS,
        CONTRACT_DELEGATEAPPROVALS,
        CONTRACT_EXCHANGERATES
    ];

    /* ========== CONSTRUCTOR ========== */

    constructor(address _owner, address _resolver)
        public
        Owned(_owner)
        MixinResolver(_resolver, addressesToCache)
        MixinSystemSettings()
    {}

    /* ========== VIEWS ========== */

    /* ---------- Related Contracts ---------- */

    function _systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS, "Missing SystemStatus address"));
    }

    function _systemSettings() internal view returns (ISystemSettings) {
        return ISystemSettings(requireAndGetAddress(CONTRACT_SYSTEMSETTINGS, "Missing SystemSettings address"));
    }

    function _delegateApprovals() internal view returns (IDelegateApprovals) {
        return IDelegateApprovals(requireAndGetAddress(CONTRACT_DELEGATEAPPROVALS, "Missing DelegateApprovals address"));
    }

    function _exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXCHANGERATES, "Missing ExchangeRates address"));
    }

    /* ---------- GasTank Information ---------- */

    function _balanceOf(address _account) internal view returns (uint balance) {
        return flexibleStorage().getUIntValue(CONTRACT_NAME, keccak256(abi.encodePacked(DEPOSIT, _account)));
    }

    function balanceOf(address _account) external view returns (uint balance) {
        return _balanceOf(_account);
    }

    function _maxGasPriceOf(address _account) internal view returns (uint maxGasPriceWei) {
        return flexibleStorage().getUIntValue(CONTRACT_NAME, keccak256(abi.encodePacked(MAX_GAS_PRICE, _account)));
    }

    function maxGasPriceOf(address _account) external view returns (uint maxGasPriceWei) {
        return _maxGasPriceOf(_account);
    }

    function isApprovedContract(address _address) internal view returns (bool isApproved) {
        return allowance[_address] == true;
    }

    function currentGasPrice() external view returns (uint currentGasPriceWei) {
        return _currentGasPrice();
    }

    function _currentGasPrice() internal view returns (uint currentGasPriceWei) {
        return _exchangeRates().rateForCurrency("fastGasPrice");
    }

    function currentEtherPrice() external view returns (uint currentEtherPriceWei) {
        return _currentEtherPrice();
    }

    function _currentEtherPrice() internal view returns (uint currentGasPriceWei) {
        return _exchangeRates().rateForCurrency("ETH");
    }

    function executionCost(uint _gas) internal view returns (uint etherCost) {
        return (_gas + PAYGAS_COST) * _currentGasPrice() + _systemSettings().keeperFee() / _currentEtherPrice();
    }

    function _toPayable(address _address) internal pure returns (address payable) {
        return address(uint160(_address));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function _setDepositBalance(address _account, uint _amount) internal {
        flexibleStorage().setUIntValue(CONTRACT_NAME, keccak256(abi.encodePacked(DEPOSIT, _account)), _amount);
    }

    function _depositEther(address _account, uint _amount) internal {
        require(_amount > 0, "Deposit must be greater than 0");
        _setDepositBalance(_account, _amount);
        emit EtherDeposited(msg.sender, _account, _amount);
    }

    function _withdrawEther(address _account, uint _amount) internal {
        require(_amount > 0, "Withdrawal amount must be greater than 0");
        address payable recipient = _toPayable(_account);
        uint accountBalance = _balanceOf(_account);
        require(accountBalance >= _amount, "Balance must be greater or equal to amount");
        _setDepositBalance(_account, accountBalance.sub(_amount));
        recipient.transfer(_amount);
        emit EtherWithdrawn(msg.sender, recipient, _amount);
    }

    function _setMaxGasPrice(address _account, uint _gasPrice) internal {
        require(_gasPrice > 0, "Gas Price must be greater than 0");
        flexibleStorage().setUIntValue(CONTRACT_NAME, keccak256(abi.encodePacked(MAX_GAS_PRICE, _account)), _gasPrice);
        emit MaxGasPriceSet(_account, _gasPrice);
    }

    function approveContract(bytes32 _contractName, bool _approve) external onlyOwner {
        address contractAddress = requireAndGetAddress(_contractName, "Missing contract address");
        allowance[contractAddress] = _approve;
        emit ContractApproved(_contractName, _approve);
    }

    function depositEtherOnBehalf(address _account) external payable {
        require(_delegateApprovals().canManageGasTankFor(_account, msg.sender), "Not approved to act on behalf");
        _depositEther(_account, msg.value);
    }

    function depositEther() external payable {
        _depositEther(msg.sender, msg.value);
    }

    function withdrawEtherOnBehalf(address _recipient, uint _amount) external payable {
        require(_delegateApprovals().canManageGasTankFor(_recipient, msg.sender), "Not approved to act on behalf");
        _withdrawEther(_recipient, _amount);
    }

    function withdrawEther(address payable _recipient, uint _amount) external payable {
        _withdrawEther(_recipient, _amount);
    }

    function setMaxGasPriceOnBehalf(address _account, uint _maxGasPriceWei) external {
        require(_delegateApprovals().canManageGasTankFor(_account, msg.sender), "Not approved to act on behalf");
        _setMaxGasPrice(_account, _maxGasPriceWei);
    }

    function setMaxGasPrice(uint _maxGasPriceWei) external {
        _setMaxGasPrice(msg.sender, _maxGasPriceWei);
    }

    function payGas(
        address _spender,
        address payable _recipient,
        uint _gas
    ) external nonReentrant returns (uint) {
        require(isApprovedContract(msg.sender), "Contract is not approved");
        uint depositBalance = _balanceOf(_spender);
        uint etherSpent = executionCost(_gas);
        require(depositBalance >= etherSpent, "Spender balance is too low");
        require(tx.gasprice >= _currentGasPrice(), "Gas price is too low");
        require(tx.gasprice <= _maxGasPriceOf(_spender), "Spender gas price limit is reached");
        _setDepositBalance(_spender, depositBalance.sub(etherSpent));
        _recipient.transfer(etherSpent);
        emit EtherSpent(_spender, _recipient, etherSpent, tx.gasprice);
        return etherSpent;
    }

    /* ========== EVENTS ========== */

    event ContractApproved(bytes32 contractName, bool approved);
    event EtherDeposited(address indexed spender, address indexed recipient, uint value);
    event EtherWithdrawn(address indexed spender, address payable indexed recipient, uint value);
    event EtherSpent(address indexed spender, address payable indexed recipient, uint value, uint gasPrice);
    event MaxGasPriceSet(address indexed account, uint maxGasPriceWei);
}