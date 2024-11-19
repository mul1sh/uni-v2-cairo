trait PairInternalTrait<TContractState> {
    fn _update(
        ref self: TContractState, balance0: u128, balance1: u128, reserve0: u128, reserve1: u128
    );
    fn _mint_fee(ref self: TContractState, reserve0: u128, reserve1: u128) -> bool;
}

#[starknet::contract]
mod Pair {
    use univ2::pair::interface::{IPair, IPausable, IFactoryDispatcher, IFactoryDispatcherTrait};
    use starknet::{
        ContractAddress, get_caller_address, get_contract_address, get_block_timestamp,
        contract_address_const
    };
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess,};
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20Mixin
    };
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::pausable::PausableComponent;

    use core::cmp::min;
    #[feature("corelib-internal-use")]
    use core::integer::u256_sqrt;


    //init the components

    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);


    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20Internal = ERC20Component::InternalImpl<ContractState>;
    impl ReentrancyGuardInternal = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl OwnableInternal = OwnableComponent::InternalImpl<ContractState>;
    impl PausableInternal = PausableComponent::InternalImpl<ContractState>;


    const MINIMUM_LIQUIDITY: u256 = 10_000;


    #[storage]
    struct Storage {
        _factory: ContractAddress,
        _token0: IERC20Dispatcher,
        _token1: IERC20Dispatcher,
        _reserve0: u128,
        _reserve1: u128,
        _block_timestamp_last: u64,
        _price0_cumulative_last: u256,
        _price1_cumulative_last: u256,
        _k_last: u256,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Swap: Swap,
        Sync: Sync,
        Mint: Mint,
        Burn: Burn,
        ERC20Event: ERC20Component::Event,
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        OwnableEvent: OwnableComponent::Event,
        PausableEvent: PausableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct Swap {
        #[key]
        sender: ContractAddress,
        amount0_in: u256,
        amount1_in: u256,
        amount0_out: u256,
        amount1_out: u256,
        #[key]
        to: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Sync {
        reserve0: u128,
        reserve1: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct Mint {
        #[key]
        sender: ContractAddress,
        amount0: u256,
        amount1: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Burn {
        #[key]
        sender: ContractAddress,
        amount0: u256,
        amount1: u256,
        #[key]
        to: ContractAddress,
    }

    pub mod Errors {
        pub const NOT_FACTORY: felt252 = 'Pair: Caller is not factory';
        pub const INSUFFICIENT_LIQUIDITY: felt252 = 'Pair: Insuficient liquidity';
        pub const INSUFFICIENT_OUTPUT: felt252 = 'Pair: Insuficient output';
        pub const INVALID_TO: felt252 = 'Pair: Invalid to';
        pub const INSUFFICIENT_INPUT: felt252 = 'Pair: Insufficient input';
        pub const K: felt252 = 'Pair: K';
    }


    impl PausableImpl of IPausable<ContractState> {
        fn pause(ref self: ContractState) {
            // Only owner can pause
            self.ownable.assert_only_owner();
            self.pausable.assert_not_paused();
            self.pausable._pause();
        }

        fn unpause(ref self: ContractState) {
            // Only owner can unpause
            self.ownable.assert_only_owner();
            self.pausable.assert_paused();
            self.pausable._unpause();
        }
    }


    #[constructor]
    fn constructor(ref self: ContractState) {
        let factory = get_caller_address();

        self._factory.write(factory);
        self.ownable._transfer_ownership(factory);
    }

    fn _uq_encode(y: u128) -> u256 {
        y.into() * 0x100000000000000000000000000000000_u256
    }

    fn _uq_div(x: u256, y: u128) -> u256 {
        x / y.into()
    }

    impl PairInternalImpl of super::PairInternalTrait<ContractState> {
        fn _update(
            ref self: ContractState, balance0: u128, balance1: u128, reserve0: u128, reserve1: u128
        ) {
            let timestamp = get_block_timestamp();
            let time_elapsed = timestamp - self._block_timestamp_last.read();

            if time_elapsed > 0 && reserve0 != 0 && reserve1 != 0 {
                self
                    ._price0_cumulative_last
                    .write(
                        self._price0_cumulative_last.read()
                            + _uq_div(_uq_encode(reserve1), reserve0).into() * time_elapsed.into()
                    );
                self
                    ._price1_cumulative_last
                    .write(
                        self._price1_cumulative_last.read()
                            + _uq_div(_uq_encode(reserve0), reserve1).into() * time_elapsed.into()
                    );
            }

            self._reserve0.write(balance0);
            self._reserve1.write(balance1);
            self._block_timestamp_last.write(timestamp);

            self.emit(Sync { reserve0, reserve1 });
        }

        fn _mint_fee(ref self: ContractState, reserve0: u128, reserve1: u128) -> bool {
            let factory = self._factory.read();
            let factoryDispatcher = IFactoryDispatcher { contract_address: factory };
            let fee_to = factoryDispatcher.get_fee_to();
            let fee_on = (fee_to != contract_address_const::<0>());

            let klast = self._k_last.read();

            if (fee_on) {
                if (klast != 0.into()) {
                    let rootk = u256 { low: u256_sqrt(reserve0.into() * reserve1.into()), high: 0 };
                    let rootklast = u256 { low: u256_sqrt(klast), high: 0 };
                    if (rootk > rootklast) {
                        let numerator = self.erc20.total_supply() * (rootk - rootklast);
                        let denominator = (rootk * 5.into()) + rootklast;
                        let liquidity = numerator / denominator;
                        if (liquidity > 0.into()) {
                            self.erc20.mint(fee_to, liquidity);
                        }
                    }
                }
            } else {
                if (klast != 0.into()) {
                    self._k_last.write(0.into());
                }
            }
            fee_on
        }
    }

    #[abi(embed_v0)]
    impl PairImpl of IPair<ContractState> {
        fn initialize(ref self: ContractState, token0: ContractAddress, token1: ContractAddress) {
            let caller = get_caller_address();

            assert(caller == self._factory.read(), Errors::NOT_FACTORY);

            self._token0.write(IERC20Dispatcher { contract_address: token0 });
            self._token1.write(IERC20Dispatcher { contract_address: token1 });
        }

        fn MINIMUM_LIQUIDITY(self: @ContractState) -> u256 {
            MINIMUM_LIQUIDITY
        }

        fn factory(self: @ContractState) -> ContractAddress {
            self._factory.read()
        }

        fn token0(self: @ContractState) -> IERC20Dispatcher {
            self._token0.read()
        }

        fn token1(self: @ContractState) -> IERC20Dispatcher {
            self._token1.read()
        }

        fn get_reserves(self: @ContractState) -> (u128, u128, u64) {
            (self._reserve0.read(), self._reserve1.read(), self._block_timestamp_last.read())
        }

        fn price0_cumulative_last(self: @ContractState) -> u256 {
            self._price0_cumulative_last.read()
        }

        fn price1_cumulative_last(self: @ContractState) -> u256 {
            self._price1_cumulative_last.read()
        }

        fn k_last(self: @ContractState) -> u256 {
            self._k_last.read()
        }

        fn mint(ref self: ContractState, to: ContractAddress) -> u256 {
            ReentrancyGuardInternal::start(ref self.reentrancy_guard);

            let this = get_contract_address();

            let reserve0 = self._reserve0.read();
            let reserve1 = self._reserve1.read();

            let balance0 = self._token0.read().balance_of(this);
            let balance1 = self._token1.read().balance_of(this);

            let amount0 = balance0 - reserve0.into();
            let amount1 = balance1 - reserve1.into();

            let fee_on = self._mint_fee(reserve0, reserve1);
            let total_supply = self.erc20.total_supply();

            let liquidity = if total_supply == 0 {
                let val = u256_sqrt(amount0 * amount1).into() - MINIMUM_LIQUIDITY;
                self.erc20.mint(contract_address_const::<1>(), MINIMUM_LIQUIDITY);
                val
            } else {
                min(
                    (amount0 * total_supply) / reserve0.into(),
                    (amount1 * total_supply) / reserve1.into()
                )
            };

            assert(liquidity > 0, Errors::INSUFFICIENT_LIQUIDITY);

            self.erc20.mint(to, liquidity);
            self
                ._update(
                    balance0.try_into().unwrap(), balance1.try_into().unwrap(), reserve0, reserve1
                );

            if fee_on {
                let reserve0 = self._reserve0.read();
                let reserve1 = self._reserve1.read();

                self._k_last.write((reserve0 * reserve1).into());
            }

            self.emit(Mint { sender: get_caller_address(), amount0, amount1 });

            ReentrancyGuardInternal::end(ref self.reentrancy_guard);

            liquidity
        }

        fn burn(ref self: ContractState, to: ContractAddress) -> (u256, u256) {
            ReentrancyGuardInternal::start(ref self.reentrancy_guard);

            let this = get_contract_address();

            let reserve0 = self._reserve0.read();
            let reserve1 = self._reserve1.read();

            let token0 = self._token0.read();
            let token1 = self._token1.read();

            let balance0 = self._token0.read().balance_of(this);
            let balance1 = self._token1.read().balance_of(this);

            let liquidity = self.erc20.balance_of(this);

            let fee_on = self._mint_fee(reserve0, reserve1);
            let total_supply = self.erc20.total_supply();

            let amount0 = (liquidity * balance0) / total_supply;
            let amount1 = (liquidity * balance1) / total_supply;

            assert(amount0 > 0 && amount1 > 0, Errors::INSUFFICIENT_LIQUIDITY);

            self.erc20.burn(this, liquidity);

            token0.transfer(to, amount0);
            token1.transfer(to, amount1);

            let balance0 = self._token0.read().balance_of(this);
            let balance1 = self._token1.read().balance_of(this);

            self
                ._update(
                    balance0.try_into().unwrap(), balance1.try_into().unwrap(), reserve0, reserve1
                );

            if fee_on {
                let reserve0 = self._reserve0.read();
                let reserve1 = self._reserve1.read();

                self._k_last.write((reserve0 * reserve1).into());
            }

            self.emit(Burn { sender: get_caller_address(), amount0, amount1, to });

            ReentrancyGuardInternal::end(ref self.reentrancy_guard);

            (amount0, amount1)
        }

        fn swap(
            ref self: ContractState, amount0_out: u256, amount1_out: u256, to: ContractAddress
        ) {
            // lock the swap to prevent another call to swap as the swap is being executed
            ReentrancyGuardInternal::start(ref self.reentrancy_guard);

            // Check if contract is paused
            self.pausable.assert_not_paused();

            let this = get_contract_address();

            let reserve0 = self._reserve0.read();
            let reserve1 = self._reserve1.read();

            assert(amount0_out > 0 || amount1_out > 0, Errors::INSUFFICIENT_OUTPUT);
            assert(
                amount0_out < reserve0.into() && amount1_out < reserve1.into(),
                Errors::INSUFFICIENT_LIQUIDITY
            );

            let token0 = self._token0.read();
            let token1 = self._token1.read();

            assert(
                to != token0.contract_address && to != token1.contract_address, Errors::INVALID_TO
            );

            if amount0_out > 0 {
                // optimistic transfer of token0 to user
                token0.transfer(to, amount0_out);
            }

            if amount1_out > 0 {
                // optimistic transfer of token1 to user
                token1.transfer(to, amount1_out);
            }

            let balance0 = self._token0.read().balance_of(this);
            let balance1 = self._token1.read().balance_of(this);

            let amount0_in = if balance0 > reserve0.into() - amount0_out {
                balance0 - (reserve0.into() - amount0_out)
            } else {
                0
            };

            let amount1_in = if balance1 > reserve1.into() - amount1_out {
                balance1 - (reserve1.into() - amount1_out)
            } else {
                0
            };

            assert(amount0_in > 0 || amount1_in > 0, Errors::INSUFFICIENT_INPUT);

            let balance0_adjusted = balance0 * 1000 - amount0_in * 3;
            let balance1_adjusted = balance1 * 1000 - amount1_in * 3;

            assert(
                balance0_adjusted
                    * balance1_adjusted >= reserve0.into()
                    * reserve1.into()
                    * 1000000,
                Errors::K
            );

            self
                ._update(
                    balance0.try_into().unwrap(), balance1.try_into().unwrap(), reserve0, reserve1
                );
            self
                .emit(
                    Swap {
                        sender: get_caller_address(),
                        amount0_in,
                        amount1_in,
                        amount0_out,
                        amount1_out,
                        to
                    }
                );

            ReentrancyGuardInternal::end(ref self.reentrancy_guard);
            self.reentrancy_guard.end();
        }

        fn skim(ref self: ContractState, to: ContractAddress) {
            ReentrancyGuardInternal::start(ref self.reentrancy_guard);

            let this = get_caller_address();

            let token0 = self._token0.read();
            let token1 = self._token1.read();

            let reserve0 = self._reserve0.read();
            let reserve1 = self._reserve1.read();

            token0.transfer(to, token0.balance_of(this) - reserve0.into());
            token0.transfer(to, token1.balance_of(this) - reserve1.into());

            ReentrancyGuardInternal::end(ref self.reentrancy_guard);
        }

        fn sync(ref self: ContractState) {
            ReentrancyGuardInternal::start(ref self.reentrancy_guard);

            let this = get_caller_address();

            let reserve0 = self._reserve0.read();
            let reserve1 = self._reserve1.read();

            let balance0 = self._token0.read().balance_of(this);
            let balance1 = self._token1.read().balance_of(this);

            self
                ._update(
                    balance0.try_into().unwrap(), balance1.try_into().unwrap(), reserve0, reserve1
                );

            ReentrancyGuardInternal::end(ref self.reentrancy_guard);
        }
    }
}
