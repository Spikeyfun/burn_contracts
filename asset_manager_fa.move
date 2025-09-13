module forgelp::asset_manager {
    use std::option;
    use std::string::{String};
    use std::bcs;
    use supra_framework::fungible_asset::{
        Self,
        MintRef,
        TransferRef,
        BurnRef,
        Metadata,
    };
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::event;
    use supra_framework::timestamp;

    friend forgelp::target_order_sup;
    friend forgelp::target_order_usdc;
    friend forgelp::target_order_eth;
    friend forgelp::config;
    friend forgelp::token_manager;
    
    struct SBT has key {
        fa_generator_extend_ref: ExtendRef,
        token_creation_nonce: u64
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ManagedFungibleAsset has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef
    }

    #[event]
    struct MintEvent has drop, store {
        token_address: address,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct BurnEvent has drop, store {
        token_address: address,
        from: address,
        amount: u64,
        timestamp: u64,
    }

    public(friend) fun initialize_module(sender: &signer) {
        let constructor_ref = object::create_named_object(sender, b"FA Generator");
        let fa_generator_extend_ref = object::generate_extend_ref(&constructor_ref);
        let sbt = SBT { 
            fa_generator_extend_ref: fa_generator_extend_ref,
            token_creation_nonce: 0
        };
        move_to(sender, sbt);
    }

    public(friend) fun create_fa(
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ) : address acquires SBT {
        let sbt = borrow_global_mut<SBT>(@forgelp);
        let current_nonce = sbt.token_creation_nonce;
        sbt.token_creation_nonce = current_nonce + 1;
        let fa_key_seed = bcs::to_bytes(&current_nonce);
        let fa_generator_signer =
            object::generate_signer_for_extending(&sbt.fa_generator_extend_ref);
        let fa_obj_constructor_ref =
            &object::create_named_object(&fa_generator_signer, fa_key_seed);
        let fa_obj_signer = object::generate_signer(fa_obj_constructor_ref);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            option::none(),
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );
        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);
        move_to(
            &fa_obj_signer,
            ManagedFungibleAsset { mint_ref, transfer_ref, burn_ref }
        );
        object::address_from_constructor_ref(fa_obj_constructor_ref)
    }

    public(friend) fun mint(
        token_address: address,
        to: address,
        amount: u64,
    ) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_fungible_asset = authorized_borrow_refs(asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);       
        
        let fa = fungible_asset::mint(&managed_fungible_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(
            &managed_fungible_asset.transfer_ref, to_wallet, fa
        );

        // Freeze the asset in the user's primary store to make it a Soulbound Token (SBT).
        // This prevents the user from transferring the experience tokens.
        primary_fungible_store::set_frozen_flag(&managed_fungible_asset.transfer_ref, to, true);

        event::emit(MintEvent {
            token_address,
            recipient: to,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    public fun burn(
        token_address: address,
        from: address,
        amount: u64,
    ) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let burn_ref = &authorized_borrow_refs(asset).burn_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(burn_ref, from_wallet, amount);

        event::emit(BurnEvent {
            token_address,
            from,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun get_balance(
        token_address: address,
        owner_addr: address
    ): u64 {
        let fa_metadata_obj: Object<Metadata> = object::address_to_object(token_address);
        primary_fungible_store::balance(owner_addr, fa_metadata_obj)
    }

    #[view]
    public fun get_total_supply(token_address: address): u128 {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let total_supply = fungible_asset::supply(asset);
        if (option::is_some(&total_supply)) {
            *option::borrow(&total_supply)
        } else { 0u128 }
    }

    inline fun authorized_borrow_refs(
        asset: Object<Metadata>
    ): &ManagedFungibleAsset acquires ManagedFungibleAsset {
        borrow_global<ManagedFungibleAsset>(object::object_address(&asset))
    }

    public fun is_account_registered(
        token_address: address,
        account: address,
    ): bool {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        primary_fungible_store::primary_store_exists(account, asset)
    }
}