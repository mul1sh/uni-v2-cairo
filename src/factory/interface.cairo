use starknet::ContractAddress;

#[starknet::interface]
trait IFactory<TContractState> {
    fn fee_to(self: @TContractState) -> ContractAddress;
    fn fee_to_setter(self: @TContractState) -> ContractAddress;
    fn get_pair(
        self: @TContractState, token_a: ContractAddress, token_b: ContractAddress
    ) -> ContractAddress;
    fn all_pairs(self: @TContractState, idx: u256) -> ContractAddress;
    fn all_pairs_length(self: @TContractState) -> u256;
    fn create_pair(
        ref self: TContractState, token_a: ContractAddress, token_b: ContractAddress
    ) -> ContractAddress;
    fn set_fee_to(ref self: TContractState, fee_to: ContractAddress);
    fn set_fee_to_setter(ref self: TContractState, fee_to_setter: ContractAddress);
}
