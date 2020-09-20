/**
     * @notice Initiates a new rebase operation, provided the minimum time period has elapsed.
     *
     * @dev The supply adjustment equals (_totalSupply * DeviationFromTargetRate) / rebaseLag
     *      Where DeviationFromTargetRate is (MarketOracleRate - targetRate) / targetRate
     *      and targetRate is 0.006
     */
    function rebase() external onlyOrchestrator {
        require(inRebaseWindow());

        // This comparison also ensures there is no reentrancy.
        require(lastRebaseTimestampSec.add(minRebaseTimeIntervalSec) < now);

        // Snap the rebase time to the start of this window.
        lastRebaseTimestampSec = now.sub(
            now.mod(minRebaseTimeIntervalSec)).add(rebaseWindowOffsetSec);

        epoch = epoch.add(1);

        uint256 yfiRate;
        bool rateValid;
        (yfiRate, rateValid) = yfiOracle.getData();
        require(rateValid);
        
        uint256 tokenRate;
        bool tokenRateValid;
        (tokenRate, tokenRateValid) = tokenOracle.getData();
        require(tokenRateValid);
        
        uint256 newTargetPrice = yfiRate.mul(3 * 10 ** (DECIMALS - 6));

        if (tokenRate > MAX_RATE) {
            tokenRate = MAX_RATE;
        }

        int256 supplyDelta = computeSupplyDelta(tokenRate, newTargetPrice);

        // Apply the Dampening factor.
        supplyDelta = supplyDelta.div(rebaseLag.toInt256Safe());

        if (supplyDelta > 0 && uFrags.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(uFrags.totalSupply())).toInt256Safe();
        }

        uint256 supplyAfterRebase = uFrags.rebase(epoch, supplyDelta);
        assert(supplyAfterRebase <= MAX_SUPPLY);
        emit LogRebase(epoch, yfiRate, tokenRate, supplyDelta, now);
    }

    /**
     * @notice Sets the reference to the YFI oracle.
     * @param yfiOracle_ The address of the YFI oracle contract.
     */
    function setYFIOracle(IOracle yfiOracle_)
        external
        onlyOwner
    {
        yfiOracle = yfiOracle_;
    }

    /**
     * @notice Sets the reference to the market oracle.
     * @param tokenOracle_ The address of the market oracle contract.
     */
    function setTokenOracle(IOracle tokenOracle_)
        external
        onlyOwner
    {
        tokenOracle = tokenOracle_;
    }

    /**
     * @notice Sets the reference to the orchestrator.
     * @param orchestrator_ The address of the orchestrator contract.
     */
    function setOrchestrator(address orchestrator_)
        external
        onlyOwner
    {
        orchestrator = orchestrator_;
    }

    /**
     * @notice Sets the deviation threshold fraction. If the exchange rate given by the market
     *         oracle is within this fractional distance from the targetRate, then no supply
     *         modifications are made. DECIMALS fixed point number.
     * @param deviationThreshold_ The new exchange rate threshold fraction.
     */
    function setDeviationThreshold(uint256 deviationThreshold_)
        external
        onlyOwner
    {
        deviationThreshold = deviationThreshold_;
    }

    /**
     * @notice Sets the rebase lag parameter.
               It is used to dampen the applied supply adjustment by 1 / rebaseLag
               If the rebase lag R, equals 1, the smallest value for R, then the full supply
               correction is applied on each rebase cycle.
               If it is greater than 1, then a correction of 1/R of is applied on each rebase.
     * @param rebaseLag_ The new rebase lag parameter.
     */
    function setRebaseLag(uint256 rebaseLag_)
        external
        onlyOwner
    {
        require(rebaseLag_ > 0);
        rebaseLag = rebaseLag_;
    }

    /**
     * @notice Sets the parameters which control the timing and frequency of
     *         rebase operations.
     *         a) the minimum time period that must elapse between rebase cycles.
     *         b) the rebase window offset parameter.
     *         c) the rebase window length parameter.
     * @param minRebaseTimeIntervalSec_ More than this much time must pass between rebase
     *        operations, in seconds.
     * @param rebaseWindowOffsetSec_ The number of seconds from the beginning of
              the rebase interval, where the rebase window begins.
     * @param rebaseWindowLengthSec_ The length of the rebase window in seconds.
     */
    function setRebaseTimingParameters(
        uint256 minRebaseTimeIntervalSec_,
        uint256 rebaseWindowOffsetSec_,
        uint256 rebaseWindowLengthSec_)
        external
        onlyOwner
    {
        require(minRebaseTimeIntervalSec_ > 0);
        require(rebaseWindowOffsetSec_ < minRebaseTimeIntervalSec_);

        minRebaseTimeIntervalSec = minRebaseTimeIntervalSec_;
        rebaseWindowOffsetSec = rebaseWindowOffsetSec_;
        rebaseWindowLengthSec = rebaseWindowLengthSec_;
    }

    /**
     * @dev ZOS upgradable contract initialization method.
     *      It is called at the time of contract creation to invoke parent class initializers and
     *      initialize the contract's state variables.
     */
    function initialize(address owner_, UFragments uFrags_, uint256 yfiValue)
        public
        initializer
    {
        Ownable.initialize(owner_);

        // deviationThreshold = 0.05e18 = 5e16
        deviationThreshold = 5 * 10 ** (DECIMALS-2);

        rebaseLag = 30;
        minRebaseTimeIntervalSec = 1 days;
        rebaseWindowOffsetSec = 72000;  // 8PM UTC
        rebaseWindowLengthSec = 15 minutes;
        lastRebaseTimestampSec = 0;
        epoch = 0;

        uFrags = uFrags_;
        baseYFIValue = yfiValue;
    }

    /**
     * @return If the latest block timestamp is within the rebase time window it, returns true.
     *         Otherwise, returns false.
     */
    function inRebaseWindow() public view returns (bool) {
        return (
            now.mod(minRebaseTimeIntervalSec) >= rebaseWindowOffsetSec &&
            now.mod(minRebaseTimeIntervalSec) < (rebaseWindowOffsetSec.add(rebaseWindowLengthSec))
        );
    }

    /**
     * @return Computes the total supply adjustment in response to the exchange rate
     *         and the targetRate.
     */
    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        private
        view
        returns (int256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        // supplyDelta = totalSupply * (rate - targetRate) / targetRate
        int256 targetRateSigned = targetRate.toInt256Safe();
        return uFrags.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }

    /**
     * @param rate The current exchange rate, an 18 decimal fixed point number.
     * @param targetRate The target exchange rate, an 18 decimal fixed point number.
     * @return If the rate is within the deviation threshold from the target rate, returns true.
     *         Otherwise, returns false.
     */
    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        private
        view
        returns (bool)
    {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }
}

// File: contracts/Orchestrator.sol

pragma solidity 0.4.24;

/**
 * @title Orchestrator
 * @notice The orchestrator is the main entry point for rebase operations. It coordinates the policy
 * actions with external consumers.
 */
contract Orchestrator is Ownable {

    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }

    event TransactionFailed(address indexed destination, uint index, bytes data);

    // Stable ordering is not guaranteed.
    Transaction[] public transactions;

    UFragmentsPolicy public policy;

    /**
     * @param policy_ Address of the UFragments policy.
     */
    constructor(address policy_) public {
        Ownable.initialize(msg.sender);
        policy = UFragmentsPolicy(policy_);
    }

    /**
     * @notice Main entry point to initiate a rebase operation.
     *         The Orchestrator calls rebase on the policy and notifies downstream applications.
     *         Contracts are guarded from calling, to avoid flash loan attacks on liquidity
     *         providers.
     *         If a transaction in the transaction list reverts, it is swallowed and the remaining
     *         transactions are executed.
     */
    function rebase()
        external
    {
        require(msg.sender == tx.origin);  // solhint-disable-line avoid-tx-origin

        policy.rebase();

        for (uint i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                bool result =
                    externalCall(t.destination, t.data);
                if (!result) {
                    emit TransactionFailed(t.destination, i, t.data);
                    revert("Transaction Failed");
                }
            }
        }
    }

    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     */
    function addTransaction(address destination, bytes data)
        external
        onlyOwner
    {
        transactions.push(Transaction({
            enabled: true,
            destination: destination,
            data: data
        }));
    }

    /**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */
    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.length--;
    }

    /**
     * @param index Index of transaction. Transaction ordering may have changed since adding.
     * @param enabled True for enabled, false for disabled.
     */
    function setTransactionEnabled(uint index, bool enabled)
        external
        onlyOwner
    {
        require(index < transactions.length, "index must be in range of stored tx list");
        transactions[index].enabled = enabled;
    }

    /**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */
    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }

    /**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */
    function externalCall(address destination, bytes data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                // 34710 is the value that solidity is currently emitting
                // It includes callGas (700) + callVeryLow (3, to pay for SUB)
                // + callValueTransferGas (9000) + callNewAccountGas
                // (25000, in case the destination address does not exist and needs creating)
                sub(gas, 34710),


                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }
}
