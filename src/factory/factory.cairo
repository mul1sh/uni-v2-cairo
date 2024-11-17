use univ2::factory::interface::{IFactory};

#[starknet::contract]
mod Factory {
    use core::num::traits::Zero;
    use starknet::{get_caller_address, ClassHash, ContractAddress};
    use starknet::syscalls::deploy_syscall;
    use core::poseidon::poseidon_hash_span;


    use univ2::pair::interface::{IPairDispatcher, IPairDispatcherTrait};

    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess,
        StorageMapWriteAccess, Map
    };

    #[storage]
    struct Storage {
        _fee_to: ContractAddress,
        _fee_to_setter: ContractAddress,
        _pair_class_hash: ClassHash,
        _all_pairs: Map<u256, ContractAddress>,
        _all_pairs_length: u256,
        _pair_by_tokens: Map<(ContractAddress, ContractAddress), ContractAddress>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PairCreated: PairCreated,
    }

    #[derive(Drop, starknet::Event)]
    struct PairCreated {
        #[key]
        token0: ContractAddress,
        #[key]
        token1: ContractAddress,
        pair: ContractAddress,
        all_pairs_length: u256,
    }

    mod Errors {
        pub const IDENTICAL_ADDRESSES: felt252 = 'Factory: Identical addresses';
        pub const ZERO_ADDRESS: felt252 = 'Factory: Zero address';
        pub const PAIR_EXISTS: felt252 = 'Factory: Pair exists';
        pub const FORBIDDEN: felt252 = 'Factory: Forbidden';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, fee_to_setter: ContractAddress, pair_class_hash: ClassHash
    ) {
        self._fee_to_setter.write(fee_to_setter);
        self._pair_class_hash.write(pair_class_hash);
    }

    #[abi(embed_v0)]
    impl FactoryImpl of super::IFactory<ContractState> {
        fn fee_to(self: @ContractState) -> ContractAddress {
            self._fee_to.read()
        }

        fn fee_to_setter(self: @ContractState) -> ContractAddress {
            self._fee_to_setter.read()
        }

        fn get_pair(
            self: @ContractState, token_a: ContractAddress, token_b: ContractAddress
        ) -> ContractAddress {
            self._pair_by_tokens.read((token_a, token_b))
        }

        fn all_pairs(self: @ContractState, idx: u256) -> ContractAddress {
            self._all_pairs.read(idx)
        }

        fn all_pairs_length(self: @ContractState) -> u256 {
            self._all_pairs_length.read()
        }

        fn create_pair(
            ref self: ContractState, token_a: ContractAddress, token_b: ContractAddress
        ) -> ContractAddress {
            assert(token_a != token_b, Errors::IDENTICAL_ADDRESSES);

            let token_a_felt: felt252 = token_a.into();
            let token_b_felt: felt252 = token_b.into();

            let token_a_uint: u256 = token_a_felt.into();
            let token_b_uint: u256 = token_b_felt.into();

            let (token0, token1) = if token_a_uint < token_b_uint {
                (token_a, token_b)
            } else {
                (token_b, token_a)
            };

            assert(token0.is_zero(), Errors::ZERO_ADDRESS);
            assert(self._pair_by_tokens.read((token0, token1)).is_non_zero(), Errors::PAIR_EXISTS);

            let mut salt_data = ArrayTrait::new();

            salt_data.append(token0.into());
            salt_data.append(token1.into());

            let salt = poseidon_hash_span(salt_data.span());
            let (contract_address, _) = deploy_syscall(
                self._pair_class_hash.read(), salt, ArrayTrait::new().span(), false
            )
                .unwrap();

            let pair = IPairDispatcher { contract_address };
            pair.initialize(token0, token1);

            self._pair_by_tokens.write((token0, token1), contract_address);
            self._pair_by_tokens.write((token1, token0), contract_address);

            let all_pairs_length = self._all_pairs_length.read();
            self._all_pairs_length.write(all_pairs_length + 1);

            self._all_pairs.write(all_pairs_length, contract_address);

            self.emit(PairCreated { token0, token1, pair: contract_address, all_pairs_length });

            contract_address
        }

        fn set_fee_to(ref self: ContractState, fee_to: ContractAddress) {
            assert(get_caller_address() == self._fee_to_setter.read(), Errors::FORBIDDEN);
            self._fee_to.write(fee_to);
        }

        fn set_fee_to_setter(ref self: ContractState, fee_to_setter: ContractAddress) {
            assert(get_caller_address() == self._fee_to_setter.read(), Errors::FORBIDDEN);
            self._fee_to_setter.write(fee_to_setter);
        }
    }
}

