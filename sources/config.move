module forgelp::config {
    use std::signer;
    use std::error;
    use supra_framework::event;
    use supra_framework::timestamp;

    friend forgelp::token_manager;

    const ERR_NOT_AUTHORIZED: u64 = 1;
    const ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE: u64 = 2;
    const ERR_INVALID_PERCENTAGES: u64 = 4;
    const ERR_NOT_READY: u64 = 6;
    const ERR_ADMIN_ALREADY_PROPOSED: u64 = 7;
    const MIN_PERCENTAGE: u64 = 500; // 5% min per vault

    struct AdminConfig has key {
        admin: address,
    }

    struct PendingAdmin has key {
        new_admin: address,
        apply_timestamp: u64,
    }

    struct DistributionConfig has key {
        usdc_percentage: u64,
        sup_percentage: u64,
        eth_percentage: u64,
    }

    struct PendingDistributionConfig has key {
        usdc_percentage: u64,
        sup_percentage: u64,
        eth_percentage: u64,
        apply_timestamp: u64,
    }

    #[event]
    struct DistributionPercentagesUpdatedEvent has drop, store {
        usdc_percentage: u64,
        sup_percentage: u64,
        eth_percentage: u64,
        timestamp: u64,
    }

    #[event]
    struct AdminChangedEvent has drop, store {
        old_admin: address,
        new_admin: address,
        timestamp: u64,
    }

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        assert!(!exists<AdminConfig>(deployer_addr), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));
        assert!(!exists<DistributionConfig>(deployer_addr), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));

        move_to(deployer, AdminConfig {
            admin: deployer_addr,
        });

        move_to(deployer, DistributionConfig {
            usdc_percentage: 1500, 
            sup_percentage: 7000,
            eth_percentage: 1500,
        });
    }

    public entry fun propose_distribution_percentages(
        admin: &signer,
        usdc_percentage: u64,
        sup_percentage: u64,
        eth_percentage: u64,
        delay_secs: u64
    ) acquires AdminConfig {
        let admin_addr = signer::address_of(admin);
        let admin_config = borrow_global<AdminConfig>(@forgelp);
        assert!(admin_addr == admin_config.admin, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(usdc_percentage + sup_percentage + eth_percentage == 10000, error::invalid_argument(ERR_INVALID_PERCENTAGES));
        assert!(usdc_percentage >= MIN_PERCENTAGE, error::invalid_argument(ERR_INVALID_PERCENTAGES));
        assert!(sup_percentage >= MIN_PERCENTAGE, error::invalid_argument(ERR_INVALID_PERCENTAGES));
        assert!(eth_percentage >= MIN_PERCENTAGE, error::invalid_argument(ERR_INVALID_PERCENTAGES));
        assert!(!exists<PendingDistributionConfig>(@forgelp), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));

        move_to(admin, PendingDistributionConfig {
            usdc_percentage,
            sup_percentage,
            eth_percentage,
            apply_timestamp: timestamp::now_seconds() + delay_secs,
        });
    }

    public entry fun apply_distribution_percentages(admin: &signer) acquires AdminConfig, DistributionConfig, PendingDistributionConfig {
        let admin_addr = signer::address_of(admin);
        let admin_config = borrow_global<AdminConfig>(@forgelp);
        assert!(admin_addr == admin_config.admin, error::permission_denied(ERR_NOT_AUTHORIZED));
        let pending = borrow_global<PendingDistributionConfig>(@forgelp);
        assert!(timestamp::now_seconds() >= pending.apply_timestamp, error::invalid_state(ERR_NOT_READY));
        let config = borrow_global_mut<DistributionConfig>(@forgelp);
        config.usdc_percentage = pending.usdc_percentage;
        config.sup_percentage = pending.sup_percentage;
        config.eth_percentage = pending.eth_percentage;

        let PendingDistributionConfig { usdc_percentage: _, sup_percentage: _, eth_percentage: _, apply_timestamp: _ } = 
            move_from<PendingDistributionConfig>(@forgelp);

        event::emit(DistributionPercentagesUpdatedEvent {
            usdc_percentage: config.usdc_percentage,
            sup_percentage: config.sup_percentage,
            eth_percentage: config.eth_percentage,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun propose_new_admin(
        admin: &signer,
        new_admin: address,
        delay_secs: u64
    ) acquires AdminConfig {
        let admin_addr = signer::address_of(admin);
        let admin_config = borrow_global<AdminConfig>(@forgelp);
        assert!(admin_addr == admin_config.admin, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(!exists<PendingAdmin>(@forgelp), error::already_exists(ERR_ADMIN_ALREADY_PROPOSED));

        move_to(admin, PendingAdmin {
            new_admin,
            apply_timestamp: timestamp::now_seconds() + delay_secs,
        });
    }

    public entry fun apply_new_admin(admin: &signer) acquires AdminConfig, PendingAdmin {
        let admin_addr = signer::address_of(admin);
        let admin_config = borrow_global<AdminConfig>(@forgelp);
        assert!(admin_addr == admin_config.admin, error::permission_denied(ERR_NOT_AUTHORIZED));
        let pending = borrow_global<PendingAdmin>(@forgelp);
        assert!(timestamp::now_seconds() >= pending.apply_timestamp, error::invalid_state(ERR_NOT_READY));
        let config = borrow_global_mut<AdminConfig>(@forgelp);
        let old_admin = config.admin;
        config.admin = pending.new_admin;

        // Clean up PendingAdmin
        let PendingAdmin { new_admin: _, apply_timestamp: _ } = move_from<PendingAdmin>(@forgelp);

        event::emit(AdminChangedEvent {
            old_admin,
            new_admin: config.admin,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun get_distribution_percentages(): (u64, u64, u64) acquires DistributionConfig {
        let config = borrow_global<DistributionConfig>(@forgelp);
        (config.usdc_percentage, config.sup_percentage, config.eth_percentage)
    }

    #[view]
    public fun get_admin(): address acquires AdminConfig {
        let config = borrow_global<AdminConfig>(@forgelp);
        config.admin
    }
}
