use starknet::ContractAddress;

use openzeppelin::token::erc20::interface::{IERC20Dispatcher};

#[starknet::interface]
pub trait IPausable<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
}

#[starknet::interface]
pub trait IPair<TContractState> {
    fn initialize(ref self: TContractState, token0: ContractAddress, token1: ContractAddress);

    fn MINIMUM_LIQUIDITY(self: @TContractState) -> u256;
    fn factory(self: @TContractState) -> ContractAddress;
    fn token0(self: @TContractState) -> IERC20Dispatcher;
    fn token1(self: @TContractState) -> IERC20Dispatcher;
    fn get_reserves(self: @TContractState) -> (u128, u128, u64);
    fn price0_cumulative_last(self: @TContractState) -> u256;
    fn price1_cumulative_last(self: @TContractState) -> u256;
    fn k_last(self: @TContractState) -> u256;

    fn mint(ref self: TContractState, to: ContractAddress) -> u256;
    fn burn(ref self: TContractState, to: ContractAddress) -> (u256, u256);
    fn swap(ref self: TContractState, amount0_out: u256, amount1_out: u256, to: ContractAddress);
    fn skim(ref self: TContractState, to: ContractAddress);
    fn sync(ref self: TContractState);
}

#[starknet::interface]
pub trait IFactory<T> {
    fn get_fee_to(self: @T) -> ContractAddress;
}
