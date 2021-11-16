/**
 * SPDX-License-Identifier: MIT
 */
pragma solidity 0.8.4;

/**
 * Tokenomics:
 *
 * Protection       3%
 * Liquidity        3%
 * Rewarding        2%
 * Redistribution   1%
 * Burn             1%
 */

import "./imports.sol";

abstract contract Tokenomics {

    using SafeMath for uint256;

    // --------------------- Token Settings ------------------- //

    string internal constant NAME = "NSUR";
    string internal constant SYMBOL = "NSUR";

    uint16 internal constant FEES_DIVISOR = 10**3;
    uint8 internal constant DECIMALS = 6;
    uint256 internal constant ZEROES = 10**DECIMALS;

    uint256 private constant MAX = ~uint256(0);
    uint256 internal constant TOTAL_SUPPLY = 200000000000 * ZEROES;
    uint256 internal _reflectedSupply = (MAX - (MAX % TOTAL_SUPPLY));

    // --------------------- Fees Settings ------------------- //

    address internal constant ProtectedAddress = 0x85FA6B211f4511656d4B8a1C15752aB8433dd534;
    address internal constant liquidityAddress = 0xD8D90330c9Bfe5b683036c96FD2cb80aac3c8639;
    address internal constant RewardingAddress = 0xBE362Aaa1bBaa6276babA2d43b14F6DcD0350f27;
    address internal constant burnAddress = 0x0000000000000000000000000000000000000001;

    uint256 internal numberOfTokensToSwapToLiquidity = 50000 ; // Amount in USD

    enum FeeType { Burn, Liquidity, Rfi, ExternalWithEvent }
    struct Fee {
        FeeType name;
        uint256 value;
        address recipient;
        uint256 total;
    }

    Fee[] internal fees;
    uint256 internal sumOfFees;

    constructor() {
        _addFees();
    }

    function _addFee(FeeType name, uint256 value, address recipient) private {
        fees.push( Fee(name, value, recipient, 0 ) );
        sumOfFees += value;
    }

    function _addFees() private {
        _addFee(FeeType.ExternalWithEvent, 30, ProtectedAddress );
        _addFee(FeeType.Liquidity, 15, address(this) );
        _addFee(FeeType.ExternalWithEvent, 15, liquidityAddress );
        _addFee(FeeType.ExternalWithEvent, 20, RewardingAddress );
        _addFee(FeeType.Burn, 10, burnAddress );
        _addFee(FeeType.Rfi, 10, address(this) );
    }

    function _getFeesCount() internal view returns (uint256){ return fees.length; }

    function _getFeeStruct(uint256 index) private view returns(Fee storage){
        require( index < fees.length, "FeesSettings._getFeeStruct: Fee index out of bounds");
        return fees[index];
    }
    function getFee(uint256 index) external view returns (FeeType, uint256, address, uint256){
        return _getFee(index);
    }
    function _getFee(uint256 index) internal view returns (FeeType, uint256, address, uint256){
        Fee memory fee = _getFeeStruct(index);
        return ( fee.name, fee.value, fee.recipient, fee.total );
    }
    function _addFeeCollectedAmount(uint256 index, uint256 amount) internal {
        Fee storage fee = _getFeeStruct(index);
        fee.total = fee.total.add(amount);
    }
    function getCollectedFeeTotal(uint256 index) external view returns (uint256){
        Fee memory fee = _getFeeStruct(index);
        return fee.total;
    }
}

abstract contract BaseRfiToken is IERC20, IERC20Metadata, Ownable, Tokenomics {

    using SafeMath for uint256;
    using Address for address;

    mapping (address => uint256) internal _protectedBalances;
    mapping (address => uint256) internal _protectedDcas;

    mapping (address => uint256) internal _reflectedBalances;
    mapping (address => uint256) internal _balances;
    mapping (address => mapping (address => uint256)) internal _allowances;

    mapping (address => bool) internal _isExcludedFromFee;
    mapping (address => bool) internal _isExcludedFromRewards;
    address[] private _excluded;

    mapping (uint256 => bool) internal _rewardJobs;

    uint256 holders = 1;

    constructor(){

        _reflectedBalances[owner()] = _reflectedSupply;

        // exclude owner and this contract from fee
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        // exclude the owner and this contract from rewards
        _exclude(owner());

        emit Transfer(address(0), owner(), TOTAL_SUPPLY);

    }

    // --------------------- Events ------------------- //

    event protectedTransferEvent(address indexed recipient, uint256 indexed amount, uint256 indexed protectedPrice);
    event setnumberOfTokensToSwapToLiquidityEvent(uint256 indexed value);
    event excludeFromRewardEvent(address indexed account);
    event includeInRewardEvent(address indexed account);
    event setExcludedFromFeeEvent(address indexed account, bool indexed value);
    event claimRewardEvent(address indexed to, uint256 indexed amount, uint256 indexed rewardId);

    /** Functions required by IERC20Metadat **/
    function name() external pure override returns (string memory) { return NAME; }
    function symbol() external pure override returns (string memory) { return SYMBOL; }
    function decimals() external pure override returns (uint8) { return DECIMALS; }
    /** Functions required by IERC20Metadat - END **/

    /** Functions required by IERC20 **/
    function totalSupply() external pure override returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function balanceOf(address account) public view override returns (uint256){
        if (_isExcludedFromRewards[account]) return _balances[account];
        return tokenFromReflection(_reflectedBalances[account]);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool){
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256){
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool){
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }
    /** Functions required by IERC20 - END **/

    /** Functions required by NSUR **/
    function protectedTransfer(address recipient, uint256 amount, uint256 protectedPrice) external onlyOwner returns (bool){
        _transfer(_msgSender(), recipient, amount);
        uint256 currentPrice = _getCurrentPrice();
        if(protectedPrice > 0){
            currentPrice = protectedPrice;
        }
        if(_protectedBalances[recipient]>0){
            uint256 b1 = _protectedBalances[recipient];
            uint256 t1 = _protectedDcas[recipient];
            uint256 c1 = b1 / t1;
            uint256 b2 = amount * currentPrice / 1_000_000;
            uint256 t2 = currentPrice;
            uint256 c2 = b2 / t2;
            uint256 dca1 = (b1+b2) / (c1+c2);
            _protectedBalances[recipient] = _protectedBalances[recipient].add(b2);
            _protectedDcas[recipient] = dca1;
        }else{
            _protectedBalances[recipient] = amount * currentPrice / 1_000_000;
            _protectedDcas[recipient] = currentPrice;
        }
        emit protectedTransferEvent(recipient, amount, currentPrice);
        return true;
    }
    function setProtected(address recipient,  uint256 protectedDca, uint256 protectedBalance) external onlyOwner {
        _protectedDcas[recipient] = protectedDca;
        _protectedBalances[recipient] = protectedBalance;
    }
    function getCurrentPrice() external view returns (uint256){
        return _getCurrentPrice();
    }
    function getHolders() external view returns (uint256){
        return holders;
    }
    function getnumberOfTokensToSwapToLiquidity() external view returns (uint256){
        return numberOfTokensToSwapToLiquidity;
    }
    function setnumberOfTokensToSwapToLiquidity(uint256 value) external onlyOwner {
        numberOfTokensToSwapToLiquidity = value;
        emit setnumberOfTokensToSwapToLiquidityEvent(value);
    }
    function getProtectedValue(address account) external view returns (uint256){
        return _protectedBalances[account];
    }
    function getProtectedDca(address account) external view returns (uint256){
        return _protectedDcas[account];
    }
    function setFee(uint256 index, FeeType feename, uint256 value, address recipient) external onlyOwner {
        fees[index] = Fee(feename, value, recipient, 0 );
    }
    /** Functions required by NSUR - END **/

    /** Functions for Claiming Rewards **/

    function claimReward(uint256 rewardId, uint256 amount, bytes memory _signature) external returns (bool){
        bytes32 message = keccak256(abi.encodePacked(rewardId, amount));
        (uint8 v, bytes32 r, bytes32 s) = splitSignature(_signature);
        require( owner() == ecrecover(message, v, r, s), "Message not signed by the owner or invalid values");
        require( _rewardJobs[rewardId] != true, "Reward Already Claimed");
        _rewardJobs[rewardId] = true;
        _transfer(owner(), _msgSender(), amount);
        emit claimRewardEvent(_msgSender(), amount, rewardId);
        return true;
    }

    function getReward(uint256 rewardId) external view returns (bool){
        return _rewardJobs[rewardId];
    }

    function splitSignature(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s){
        require(sig.length == 65);
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    /** End Functions for Claiming Rewards **/


    function burn(uint256 amount) external {

        address sender = _msgSender();
        require(sender != address(0), "BaseRfiToken: burn from the zero address");
        require(sender != address(burnAddress), "BaseRfiToken: burn from the burn address");

        uint256 balance = balanceOf(sender);
        require(balance >= amount, "BaseRfiToken: burn amount exceeds balance");

        uint256 reflectedAmount = amount.mul(_getCurrentRate());

        // remove the amount from the sender's balance first
        _reflectedBalances[sender] = _reflectedBalances[sender].sub(reflectedAmount);
        if (_isExcludedFromRewards[sender])
            _balances[sender] = _balances[sender].sub(amount);

        _burnTokens( sender, amount, reflectedAmount );
    }

    function _burnTokens(address sender, uint256 tBurn, uint256 rBurn) internal {

    /**
     * @dev Do not reduce _totalSupply and/or _reflectedSupply. (soft) burning by sending
         * tokens to the burn address (which should be excluded from rewards) is sufficient
         * in RFI
         */
        _reflectedBalances[burnAddress] = _reflectedBalances[burnAddress].add(rBurn);
        if (_isExcludedFromRewards[burnAddress])
            _balances[burnAddress] = _balances[burnAddress].add(tBurn);

        /**
         * @dev Emit the event so that the burn address balance is updated (on bscscan)
         */
        emit Transfer(sender, burnAddress, tBurn);
    }

    function increaseAllowance(address spender, uint256 addedValue) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcludedFromReward(address account) external view returns (bool) {
        return _isExcludedFromRewards[account];
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) external view returns(uint256) {
        require(tAmount <= TOTAL_SUPPLY, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,) = _getValues(tAmount,0);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,) = _getValues(tAmount,_getSumOfFees(_msgSender(), tAmount));
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) internal view returns(uint256) {
        require(rAmount <= _reflectedSupply, "Amount must be less than total reflections");
        uint256 currentRate = _getCurrentRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) external onlyOwner() {
        require(!_isExcludedFromRewards[account], "Account is not included");
        _exclude(account);
        emit excludeFromRewardEvent(account);
    }

    function _exclude(address account) internal {
        if(_reflectedBalances[account] > 0) {
            _balances[account] = tokenFromReflection(_reflectedBalances[account]);
        }
        _isExcludedFromRewards[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner() {
        require(_isExcludedFromRewards[account], "Account is not excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _balances[account] = 0;
                _isExcludedFromRewards[account] = false;
                _excluded.pop();
                break;
            }
        }
        emit includeInRewardEvent(account);
    }

    function setExcludedFromFee(address account, bool value) external onlyOwner {
        _isExcludedFromFee[account] = value;
        emit setExcludedFromFeeEvent(account, value);
    }

    function isExcludedFromFee(address account) external view returns(bool) { return _isExcludedFromFee[account]; }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "BaseRfiToken: approve from the zero address");
        require(spender != address(0), "BaseRfiToken: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "BaseRfiToken: transfer from the zero address");
        require(recipient != address(0), "BaseRfiToken: transfer to the zero address");
        require(sender != address(burnAddress), "BaseRfiToken: transfer from the burn address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // indicates whether or not feee should be deducted from the transfer
        bool takeFee = true;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFee[sender] || _isExcludedFromFee[recipient]){ takeFee = false; }

        _beforeTokenTransfer(sender, recipient, amount, takeFee);
        _transferTokens(sender, recipient, amount, takeFee);

    }

    function _transferTokens(address sender, address recipient, uint256 amount, bool takeFee) private {

        uint256 sumOfFees = _getSumOfFees(sender, amount);
        if ( !takeFee ){ sumOfFees = 0; }

        (uint256 rAmount, uint256 rTransferAmount, uint256 tAmount, uint256 tTransferAmount, uint256 currentRate ) = _getValues(amount, sumOfFees);

        /*
        Add new Holder to the Contract
        */
        if(balanceOf(recipient) == 0 && amount>0) holders++;

        /**
         * Sender's and Recipient's reflected balances must be always updated regardless of
         * whether they are excluded from rewards or not.
         */
        _reflectedBalances[sender] = _reflectedBalances[sender].sub(rAmount);
        _reflectedBalances[recipient] = _reflectedBalances[recipient].add(rTransferAmount);

        /**
         * Update the true/nominal balances for excluded accounts
         */
        if (_isExcludedFromRewards[sender]){ _balances[sender] = _balances[sender].sub(tAmount); }
        if (_isExcludedFromRewards[recipient] ){ _balances[recipient] = _balances[recipient].add(tTransferAmount); }

        /**
         * Reduces the Protected Amount on every transfer out
         */
        if (_protectedBalances[sender] > 0) {
            uint256 currentPrice = _getCurrentPrice();
            if (currentPrice < _protectedDcas[sender]) {
                currentPrice = _protectedDcas[sender];
            }
            if (currentPrice > 0) {
                uint256 protectedToDeduct = amount * currentPrice / 1_000_000;
                if (protectedToDeduct > _protectedBalances[sender]) {
                    _protectedBalances[sender] = 0;
                    _protectedDcas[sender] = 0;
                } else {
                    _protectedBalances[sender] = _protectedBalances[sender].sub(amount * currentPrice / 1_000_000);
                }
            }
        }

        /*
        Remove Holders from the contract
        */
        if(balanceOf(sender) == 0) holders--;

        _takeFees( amount, currentRate, sumOfFees );
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _takeFees(uint256 amount, uint256 currentRate, uint256 sumOfFees ) private {
        if ( sumOfFees > 0 ){
            _takeTransactionFees(amount, currentRate);
        }
    }

    function _getValues(uint256 tAmount, uint256 feesSum) internal view returns (uint256, uint256, uint256, uint256, uint256) {

        uint256 tTotalFees = tAmount.mul(feesSum).div(FEES_DIVISOR);
        uint256 tTransferAmount = tAmount.sub(tTotalFees);
        uint256 currentRate = _getCurrentRate();
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rTotalFees = tTotalFees.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rTotalFees);

        return (rAmount, rTransferAmount, tAmount, tTransferAmount, currentRate);
    }

    function _getCurrentRate() internal view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() internal view returns(uint256, uint256) {
        uint256 rSupply = _reflectedSupply;
        uint256 tSupply = TOTAL_SUPPLY;

        /**
         * The code below removes balances of addresses excluded from rewards from
         * rSupply and tSupply, which effectively increases the % of transaction fees
         * delivered to non-excluded holders
         */
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_reflectedBalances[_excluded[i]] > rSupply || _balances[_excluded[i]] > tSupply) return (_reflectedSupply, TOTAL_SUPPLY);
            rSupply = rSupply.sub(_reflectedBalances[_excluded[i]]);
            tSupply = tSupply.sub(_balances[_excluded[i]]);
        }
        if (tSupply == 0 || rSupply < _reflectedSupply.div(TOTAL_SUPPLY)) return (_reflectedSupply, TOTAL_SUPPLY);
        return (rSupply, tSupply);
    }

    function _beforeTokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) internal virtual;

    function _getSumOfFees(address sender, uint256 amount) internal view virtual returns (uint256);

    function _redistribute(uint256 amount, uint256 currentRate, uint256 fee, uint256 index) internal {
        uint256 tFee = amount.mul(fee).div(FEES_DIVISOR);
        uint256 rFee = tFee.mul(currentRate);

        _reflectedSupply = _reflectedSupply.sub(rFee);
        _addFeeCollectedAmount(index, tFee);
    }

    function _takeTransactionFees(uint256 amount, uint256 currentRate) internal virtual;

    function _getCurrentPrice() internal view virtual returns (uint256);

}

abstract contract Liquifier is Ownable, Manageable {

    using SafeMath for uint256;

    uint256 private withdrawableBalance;

    enum Env {Testnet, Mainnet}
    Env internal _env;

    // PancakeSwap V2
    address private _mainnetRouterV2Address = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // PancakeSwap Testnet = https://pancake.kiemtienonline360.com/
    address private _testnetRouterAddress = 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;

    //PAIRS BNB BUSD
    address internal _BNBBUSD;
    address internal _mainnetBNBBUSD = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16;
    address internal _testnetBNBBUSD = 0xe0e92035077c39594793e61802a350347c320cf2;

    // --------------------- Events ------------------- //

    event setRouterAddressEvent(address indexed router);
    event withdrawLockedEthEvent(address indexed recipient, uint256 indexed amount);

    IPancakeV2Router internal _router;
    address internal _pair;

    bool private inSwapAndLiquify;
    bool private swapAndLiquifyEnabled = true;

    uint256 private numberOfTokensToSwapToLiquidity;

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    event RouterSet(address indexed router);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event LiquidityAdded(uint256 tokenAmountSent, uint256 ethAmountSent, uint256 liquidity);

    receive() external payable {}

    function initializeLiquiditySwapper(Env env, uint256 liquifyAmount) internal {
        _env = env;
        if (_env == Env.Mainnet){
            _BNBBUSD = _mainnetBNBBUSD;
            _setRouterAddress(_mainnetRouterV2Address);
        }
        if (_env == Env.Testnet){
            _BNBBUSD = _testnetBNBBUSD;
            _setRouterAddress(_testnetRouterAddress);
        }
        numberOfTokensToSwapToLiquidity = liquifyAmount;
    }

    function liquify(uint256 contractTokenBalance, address sender) internal {

        uint256 contractTokenBalanceBUSD = ( contractTokenBalance / 1_000_000 ) * ( _getCurrentPrice() / 1_000_000 );
        bool isOverRequiredTokenBalance = ( contractTokenBalanceBUSD >= numberOfTokensToSwapToLiquidity );

        /**
         * - first check if the contract has collected enough tokens to swap and liquify
         * - then check swap and liquify is enabled
         * - then make sure not to get caught in a circular liquidity event
         * - finally, don't swap & liquify if the sender is the uniswap pair
         */
        if ( isOverRequiredTokenBalance && swapAndLiquifyEnabled && !inSwapAndLiquify && (sender != _pair) ){
            // TODO check if the `(sender != _pair)` is necessary because that basically
            // stops swap and liquify for all "buy" transactions
            _swapAndLiquify(contractTokenBalance);
        }

    }

    function _setRouterAddress(address router) private {
        IPancakeV2Router _newPancakeRouter = IPancakeV2Router(router);
        _pair = IPancakeV2Factory(_newPancakeRouter.factory()).createPair(address(this), _newPancakeRouter.WETH());
        _router = _newPancakeRouter;
        emit RouterSet(router);
    }

    function _swapAndLiquify(uint256 amount) private lockTheSwap {

        // split the contract balance into halves
        uint256 half = amount.div(2);
        uint256 otherHalf = amount.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        _swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        _addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function _swapTokensForEth(uint256 tokenAmount) private {

        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _router.WETH();

        _approveDelegate(address(this), address(_router), tokenAmount);

        // make the swap
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
        // The minimum amount of output tokens that must be received for the transaction not to revert.
        // 0 = accept any amount (slippage is inevitable)
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approveDelegate(address(this), address(_router), tokenAmount);

        // add tahe liquidity
        (uint256 tokenAmountSent, uint256 ethAmountSent, uint256 liquidity) = _router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
        // Bounds the extent to which the WETH/token price can go up before the transaction reverts.
        // Must be <= amountTokenDesired; 0 = accept any amount (slippage is inevitable)
            0,
        // Bounds the extent to which the token/WETH price can go up before the transaction reverts.
        // 0 = accept any amount (slippage is inevitable)
            0,
            address(this),
            block.timestamp
        );

        // fix the forever locked BNBs as per the certik's audit
        /**
         * The swapAndLiquify function converts half of the contractTokenBalance SafeMoon tokens to BNB.
         * For every swapAndLiquify function call, a small amount of BNB remains in the contract.
         * This amount grows over time with the swapAndLiquify function being called throughout the life
         * of the contract. The Safemoon contract does not contain a method to withdraw these funds,
         * and the BNB will be locked in the Safemoon contract forever.
         */
        withdrawableBalance = address(this).balance;
        emit LiquidityAdded(tokenAmountSent, ethAmountSent, liquidity);
    }

    function setRouterAddress(address router) external onlyManager() {
        _setRouterAddress(router);
        emit setRouterAddressEvent(router);
    }

    function setSwapAndLiquifyEnabled(bool enabled) external onlyManager {
        swapAndLiquifyEnabled = enabled;
        emit SwapAndLiquifyEnabledUpdated(swapAndLiquifyEnabled);
    }

    function withdrawLockedEth(address payable recipient) external onlyManager(){
        require(recipient != address(0), "Cannot withdraw the ETH balance to the zero address");
        require(withdrawableBalance > 0, "The ETH balance must be greater than 0");

        // prevent re-entrancy attacks
        uint256 amount = withdrawableBalance;
        withdrawableBalance = 0;
        recipient.transfer(amount);
        emit withdrawLockedEthEvent(recipient, amount);
    }

    function _approveDelegate(address owner, address spender, uint256 amount) internal virtual;

    function _getCurrentPrice() internal view virtual returns (uint256);

}

abstract contract Token is BaseRfiToken, Liquifier {

    using SafeMath for uint256;

    constructor(Env _env){
        initializeLiquiditySwapper(_env, numberOfTokensToSwapToLiquidity);
        // Redistribution only for holders.
        _exclude(_pair);
        _exclude(burnAddress);
    }

    function _getCurrentPrice() internal view override(BaseRfiToken, Liquifier) returns(uint256) {
        IPancakeV2Pair pairCoinBnb = IPancakeV2Pair(_pair);
        (uint112 reserve0CoinBnb, uint112 reserve1CoinBnb, ) = pairCoinBnb.getReserves();
        if(reserve0CoinBnb == 0 || reserve1CoinBnb == 0){
            return(0);
        }
        address token0CoinBnb = pairCoinBnb.token0();
        uint256 priceinBNB;
        if(token0CoinBnb == _router.WETH()){
            priceinBNB = reserve0CoinBnb/reserve1CoinBnb;
        }else{
            priceinBNB = reserve1CoinBnb/reserve0CoinBnb;
        }

        IPancakeV2Pair pairBnbBusd = IPancakeV2Pair(_BNBBUSD);
        (uint112 reserve0BnbBusd, uint112 reserve1BnbBusd, ) = pairBnbBusd.getReserves();
        uint256 priceinBNBBUSD;
        if(_env == Env.Testnet){
            priceinBNBBUSD = reserve0BnbBusd/reserve1BnbBusd;
        }else{
            priceinBNBBUSD = reserve1BnbBusd/reserve0BnbBusd;
        }

        return(priceinBNB * priceinBNBBUSD / 1_000_000);
    }

    function getPair() external view returns(address,uint256,uint256) {
        IPancakeV2Pair pair = IPancakeV2Pair(_pair);
        (uint112 reserve0,uint112 reserve1,) = pair.getReserves();
        return(_pair,reserve0,reserve1);
    }

    function _getSumOfFees(address, uint256) internal view override returns (uint256){
        return sumOfFees;
    }

    function _beforeTokenTransfer(address sender, address , uint256 , bool ) internal override {
        uint256 contractTokenBalance = balanceOf(address(this));
        liquify( contractTokenBalance, sender );
    }

    function _takeTransactionFees(uint256 amount, uint256 currentRate) internal override {
        uint256 feesCount = _getFeesCount();
        for (uint256 index = 0; index < feesCount; index++ ){
            (FeeType name, uint256 value, address recipient,) = _getFee(index);
            // no need to check value < 0 as the value is uint (i.e. from 0 to 2^256-1)
            if ( value == 0 ) continue;
            if ( name == FeeType.Rfi ){
                _redistribute( amount, currentRate, value, index );
            }
            else if ( name == FeeType.Burn ){
                _burn( amount, currentRate, value, index );
            }
            else if ( name == FeeType.ExternalWithEvent){
                _takeFee( amount, currentRate, value, recipient, index, true );
            }
            else if ( name == FeeType.Liquidity){
                _takeFee( amount, currentRate, value, recipient, index, false );
            }
        }
    }

    function _burn(uint256 amount, uint256 currentRate, uint256 fee, uint256 index) private {
        uint256 tBurn = amount.mul(fee).div(FEES_DIVISOR);
        uint256 rBurn = tBurn.mul(currentRate);

        _burnTokens(address(this), tBurn, rBurn);
        _addFeeCollectedAmount(index, tBurn);
    }

    function _takeFee(uint256 amount, uint256 currentRate, uint256 fee, address recipient, uint256 index, bool emitEvent) private {

        uint256 tAmount = amount.mul(fee).div(FEES_DIVISOR);
        uint256 rAmount = tAmount.mul(currentRate);

        _reflectedBalances[recipient] = _reflectedBalances[recipient].add(rAmount);
        if(_isExcludedFromRewards[recipient])
            _balances[recipient] = _balances[recipient].add(tAmount);

        _addFeeCollectedAmount(index, tAmount);

        /**
         * @dev Emit the event so that the recipient address balance is updated (on bscscan)
         */
        if (emitEvent) {
            emit Transfer(address(this), recipient, tAmount);
        }
    }

    function _approveDelegate(address owner, address spender, uint256 amount) internal override {
        _approve(owner, spender, amount);
    }
}

contract Nsur is Token{
    constructor() Token(Env.Testnet){
        // pre-approve the initial liquidity supply (to safe a bit of time)
        _approve(owner(),address(_router), ~uint256(0));
    }
}
