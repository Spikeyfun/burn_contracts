module forgelp::target_order_sup {
    use supra_framework::account;
    use supra_framework::coin::{Self};
    use supra_framework::timestamp;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::event;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Metadata};
    use supra_framework::primary_fungible_store;
    use std::signer;
    use std::string::{utf8, String};
    use std::type_info;
    use std::error;
    use spike_amm::amm_router;
    use spike_amm::amm_pair::{Self};
    use spike_amm::coin_wrapper;
    use spike_amm::amm_oracle;
    use forgelp::token_manager;
    use forgelp::asset_manager;
    use razor_libs::sort;

    const ERR_NOT_AUTHORIZED: u64 = 1;
    const ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE: u64 = 2;
    const ERR_SIGNER_CAP_NOT_FOUND: u64 = 3;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const ERR_INSUFFICIENT_RESOURCE_BALANCE: u64 = 5;
    const ERR_DEADLINE_EXPIRED: u64 = 6;
    const ERR_TOKEN_INFO_NOT_FOUND: u64 = 7;
    const ERR_PRICE_MANIPULATION_DETECTED: u64 = 8;
    const ERR_ZERO_PRICE: u64 = 9; // Added for consistency
    const ERR_PRICE_DECIMALS_TOO_LARGE: u64 = 10; // Added for consistency
    const MODULE_ADMIN_ACCOUNT: address = @forgelp;
    const MODULE_RESOURCE_ACCOUNT_SEED: vector<u8> = b"forgelp_resource_account_sup";
    const BURN_ADDRESS: address = @BURN_ADDR;

    const MAX_PRICE_DEVIATION_BPS: u128 = 1370; // 13.7%
    const Q64: u128 = 18446744073709551615;

    struct ModuleSignerStorage has key {
        signer_cap: account::SignerCapability,
    }

    #[event]
    struct LpBurnedEvent has drop, store {
        sender: address,
        coin_type: String,
        amount_supra: u64,
        timestamp: u64,
    }

    #[event]
    struct FALpBurnedEvent has drop, store {
        sender: address,
        fa_address: address,
        amount_supra: u64,
        timestamp: u64,
    }

    #[event]
    struct DepositEvent has drop, store {
        sender: address,
        coin_type: String, // Empty for FA
        fa_address: address, // 0x0 for CoinType
        amount: u64,
        timestamp: u64,
    }

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        assert!(deployer_addr == MODULE_ADMIN_ACCOUNT, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(!exists<ModuleSignerStorage>(deployer_addr), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));

        let (_, signer_cap) = account::create_resource_account(deployer, MODULE_RESOURCE_ACCOUNT_SEED);
        move_to(deployer, ModuleSignerStorage { signer_cap });
    }

    public entry fun deposit_coins<CoinType>(
        sender: &signer,
        amount: u64
    ) acquires ModuleSignerStorage {
        assert!(exists<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT), ERR_SIGNER_CAP_NOT_FOUND);
        let signer_cap = &borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);

        if (!coin::is_account_registered<CoinType>(resource_addr)) {
            coin::register<CoinType>(&resource_signer);
        };

        let coins = coin::withdraw<CoinType>(sender, amount);
        coin::deposit(resource_addr, coins);

        event::emit(DepositEvent {
            sender: signer::address_of(sender),
            coin_type: type_info::type_name<CoinType>(),
            fa_address: @0x0,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun deposit_fa(
        sender: &signer,
        fa_address: address,
        amount: u64
    ) acquires ModuleSignerStorage {
        assert!(exists<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT), ERR_SIGNER_CAP_NOT_FOUND);
        let signer_cap = &borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);

        let fa_object: Object<Metadata> = object::address_to_object(fa_address);

        if (!primary_fungible_store::primary_store_exists(resource_addr, fa_object)) {
            primary_fungible_store::create_primary_store(resource_addr, fa_object);
        };

        primary_fungible_store::transfer(sender, fa_object, resource_addr, amount);

        event::emit(DepositEvent {
            sender: signer::address_of(sender),
            coin_type: utf8(b""),
            fa_address,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun forge_lp_and_burn<CoinType>(
        sender: &signer,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        amount_cointype_min: u64,
        deadline: u64,
    ) acquires ModuleSignerStorage {
        assert!(timestamp::now_seconds() <= deadline, error::invalid_argument(ERR_DEADLINE_EXPIRED));

        assert!(exists<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT), error::not_found(ERR_SIGNER_CAP_NOT_FOUND));
        let signer_cap = &borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);

        if (!coin::is_account_registered<CoinType>(resource_addr)) {
            coin::register<CoinType>(&resource_signer);
        };
        
        if (!coin::is_account_registered<SupraCoin>(resource_addr)) {
            coin::register<SupraCoin>(&resource_signer);
        };

        let cointype_metadata = coin_wrapper::get_wrapper<CoinType>();
        let supra_metadata = coin_wrapper::get_wrapper<SupraCoin>();

        let pair = amm_pair::liquidity_pool(cointype_metadata, supra_metadata);
        let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);

        let (reserve_cointype, reserve_supra) = if (sort::is_sorted_two(cointype_metadata, supra_metadata)) {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        if (reserve_supra == 0 || reserve_cointype == 0) {
            abort(ERR_INSUFFICIENT_LIQUIDITY)
        };
        assert!(reserve_supra >= 10000, error::invalid_argument(ERR_INSUFFICIENT_LIQUIDITY));

        let twap_price_cointype = amm_oracle::get_average_price_v2(cointype_metadata);
        let spot_price_cointype = amm_oracle::get_current_price(cointype_metadata);

        let twap_normalized = twap_price_cointype / Q64;
        let lower_bound = (twap_normalized * (10000 - MAX_PRICE_DEVIATION_BPS)) / 10000;
        let upper_bound = (twap_normalized * (10000 + MAX_PRICE_DEVIATION_BPS)) / 10000;

        assert!(spot_price_cointype >= lower_bound && spot_price_cointype <= upper_bound, error::invalid_argument(ERR_PRICE_MANIPULATION_DETECTED));
        let amount_cointype_needed = ((((amount_supra_desired as u128) * (reserve_cointype as u128)) / (reserve_supra as u128)) as u64);
        assert!((amount_cointype_needed as u128) <= 18446744073709551615u128, error::invalid_argument(ERR_INSUFFICIENT_LIQUIDITY));

        let supra_coins_from_user = coin::withdraw<SupraCoin>(sender, amount_supra_desired);
        coin::deposit(resource_addr, supra_coins_from_user);

        amm_router::add_liquidity_coins_beta<CoinType, SupraCoin>(
            &resource_signer,
            amount_cointype_needed,
            amount_cointype_min,
            amount_supra_desired,
            amount_supra_min,
            BURN_ADDRESS,
            deadline,
        );

        event::emit(LpBurnedEvent {
            sender: signer::address_of(sender),
            coin_type: type_info::type_name<CoinType>(),
            amount_supra: amount_supra_desired,
            timestamp: timestamp::now_seconds(),
        });

        let exp_token_addr = token_manager::get_experience_token_address();
        let reward_amount = amount_supra_desired;
        if (reward_amount > 0) {
            let sender_addr = signer::address_of(sender);
            asset_manager::mint(exp_token_addr, sender_addr, reward_amount);
        }
    }

    public entry fun forge_lp_fa_and_burn(
        sender: &signer,
        fa_address: address,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        amount_fa_min: u64,
        deadline: u64,
    ) acquires ModuleSignerStorage {
        assert!(timestamp::now_seconds() <= deadline, error::invalid_argument(ERR_DEADLINE_EXPIRED));

        assert!(exists<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT), error::not_found(ERR_SIGNER_CAP_NOT_FOUND));
        let signer_cap = &borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);

        let fa_metadata = object::address_to_object<Metadata>(fa_address);
        let supra_metadata = coin_wrapper::get_wrapper<SupraCoin>();

        let pair = amm_pair::liquidity_pool(fa_metadata, supra_metadata);
        let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);

        let (reserve_fa, reserve_supra) = if (sort::is_sorted_two(fa_metadata, supra_metadata)) {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        if (reserve_supra == 0 || reserve_fa == 0) {
            abort(ERR_INSUFFICIENT_LIQUIDITY)
        };
        assert!(reserve_supra >= 10000, error::invalid_argument(ERR_INSUFFICIENT_LIQUIDITY));

        let twap_price_fa = amm_oracle::get_average_price_v2(fa_metadata);
        let spot_price_fa = amm_oracle::get_current_price(fa_metadata);

        let twap_normalized = twap_price_fa / Q64;
        let lower_bound = (twap_normalized * (10000 - MAX_PRICE_DEVIATION_BPS)) / 10000;
        let upper_bound = (twap_normalized * (10000 + MAX_PRICE_DEVIATION_BPS)) / 10000;

        assert!(spot_price_fa >= lower_bound && spot_price_fa <= upper_bound, error::invalid_argument(ERR_PRICE_MANIPULATION_DETECTED));

        let amount_fa_needed = ((((amount_supra_desired as u128) * (reserve_fa as u128)) / (reserve_supra as u128)) as u64);
        assert!((amount_fa_needed as u128) <= 18446744073709551615u128, error::invalid_argument(ERR_INSUFFICIENT_LIQUIDITY));

        let supra_coins_from_user = coin::withdraw<SupraCoin>(sender, amount_supra_desired);
        coin::deposit(resource_addr, supra_coins_from_user);

        amm_router::add_liquidity_coin_beta<SupraCoin>(
            &resource_signer,
            fa_address,
            amount_fa_needed,
            amount_fa_min,
            amount_supra_desired,
            amount_supra_min,
            BURN_ADDRESS,
            deadline,
        );

        event::emit(FALpBurnedEvent {
            sender: signer::address_of(sender),
            fa_address,
            amount_supra: amount_supra_desired,
            timestamp: timestamp::now_seconds(),
        });

        let exp_token_addr = token_manager::get_experience_token_address();
        let reward_amount = amount_supra_desired;
        if (reward_amount > 0) {
            let sender_addr = signer::address_of(sender);
            asset_manager::mint(exp_token_addr, sender_addr, reward_amount);
        }
    }

    #[view]
    public fun get_vault_address(): address acquires ModuleSignerStorage {
        assert!(exists<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT), error::not_found(ERR_SIGNER_CAP_NOT_FOUND));
        let signer_cap = &borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).signer_cap;
        account::get_signer_capability_address(signer_cap)
    }

    #[view]
    public fun calculate_expected_reward(amount_supra_desired: u64): u64 {
        amount_supra_desired
    }
}
