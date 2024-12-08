
#[starknet::component]
pub mod PausableComponent {
    use crate::interface::IPausable;

    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    pub struct Storage {
        pub Pausable_paused: bool,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        Paused: Paused,
        Unpaused: Unpaused,
    }

    /// Emitted when the pause is triggered by `account`.
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Paused {
        pub account: ContractAddress,
    }

    /// Emitted when the pause is lifted by `account`.
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Unpaused {
        pub account: ContractAddress,
    }

    pub mod Errors {
        pub const PAUSED: felt252 = 'Pausable: paused';
        pub const NOT_PAUSED: felt252 = 'Pausable: not paused';
    }

    #[embeddable_as(uni-v2-cairo)]
    impl Pausable<
        TContractState, +HasComponent<TContractState>,
    > of IPausable<ComponentState<TContractState>> {
        /// Returns true if the contract is paused, and false otherwise.
        fn is_paused(self: @ComponentState<TContractState>) -> bool {
            self.Pausable_paused.read()
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        /// Makes a function only callable when the contract is not paused.
        fn assert_not_paused(self: @ComponentState<TContractState>) {
            assert(!self.Pausable_paused.read(), Errors::PAUSED);
        }

        /// Makes a function only callable when the contract is paused.
        fn assert_paused(self: @ComponentState<TContractState>) {
            assert(self.Pausable_paused.read(), Errors::NOT_PAUSED);
        }

     
        fn pause(ref self: ComponentState<TContractState>) {
            self.assert_not_paused();
            self.Pausable_paused.write(true);
            self.emit(Paused { account: get_caller_address() });
        }
        fn unpause(ref self: ComponentState<TContractState>) {
            self.assert_paused();
            self.Pausable_paused.write(false);
            self.emit(Unpaused { account: get_caller_address() });
        }
    }
}