use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
struct FeeConfig {
    fee_recipient: ContractAddress
}

#[starknet::component]
mod fee_model_component {
    use alexandria_math::i257::{i257, i257_new};
    use starknet::{ContractAddress, get_contract_address, contract_address_const};
    use vesu::{
        singleton_v2::{
            ISingletonV2Dispatcher, ISingletonV2DispatcherTrait, ModifyPositionParams, UpdatePositionResponse
        },
        data_model::{Amount, AmountDenomination, AmountType},
        extension::{components::fee_model::FeeConfig, default_extension_po_v2::IDefaultExtensionCallback},
        vendor::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait},
    };

    #[storage]
    struct Storage {
        // fee configuration
        fee_config: FeeConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct SetFeeConfig {
        #[key]
        fee_config: FeeConfig
    }

    #[derive(Drop, starknet::Event)]
    struct ClaimFees {
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SetFeeConfig: SetFeeConfig,
        ClaimFees: ClaimFees
    }

    #[generate_trait]
    impl FeeModelTrait<
        TContractState, +HasComponent<TContractState>, +IDefaultExtensionCallback<TContractState>,
    > of Trait<TContractState> {
        /// Sets the fee configuration
        /// # Arguments
        /// * `fee_config` - The fee configuration
        fn set_fee_config(ref self: ComponentState<TContractState>, fee_config: FeeConfig) {
            self.fee_config.write(fee_config);
            self.emit(SetFeeConfig { fee_config });
        }

        /// Claims the fees accrued in the extension for a given asset and sends them to the fee recipient
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        fn claim_fees(ref self: ComponentState<TContractState>, collateral_asset: ContractAddress) {
            let singleton = self.get_contract().singleton();

            let (position, _, _) = ISingletonV2Dispatcher { contract_address: singleton }
                .position(collateral_asset, Zeroable::zero(), get_contract_address());

            let amount = position.collateral_shares;

            let UpdatePositionResponse { collateral_delta, .. } = ISingletonV2Dispatcher { contract_address: singleton }
                .modify_position(
                    ModifyPositionParams {
                        collateral_asset,
                        debt_asset: Zeroable::zero(),
                        user: get_contract_address(),
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Native,
                            value: i257_new(amount, true),
                        },
                        debt: Default::default(),
                        data: ArrayTrait::new().span()
                    }
                );

            let fee_config = self.fee_config.read();
            let amount = collateral_delta.abs;

            IERC20Dispatcher { contract_address: collateral_asset }.transfer(fee_config.fee_recipient, amount);

            self
                .emit(
                    ClaimFees {
                        collateral_asset, debt_asset: Zeroable::zero(), recipient: fee_config.fee_recipient, amount
                    }
                );
        }
    }
}
