module forgelp::token_manager {
    use std::signer;
    use std::string::utf8;
    use std::error;
    use forgelp::asset_manager;

    const ERR_NOT_AUTHORIZED: u64 = 1;
    const ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE: u64 = 2;
    const ERR_TOKEN_INFO_NOT_FOUND: u64 = 3;
    const MODULE_ADMIN_ACCOUNT: address = @forgelp;

    struct ExperienceTokenInfo has key {
        token_address: address
    }

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        assert!(deployer_addr == MODULE_ADMIN_ACCOUNT, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(!exists<ExperienceTokenInfo>(deployer_addr), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));

        asset_manager::initialize_module(deployer);

        let experience_token_address = asset_manager::create_fa(
            utf8(b"Meme Soul Bound"),
            utf8(b"XP"),
            8,
            utf8(b"http://arweave.net/mA-ysvv9drTw7h0fPYv0VR_gNflWZtc-064RTUat2tQ"),
            utf8(b"https://burn.spikey.fun")
        );

        move_to(deployer, ExperienceTokenInfo {
            token_address: experience_token_address
        });
    }

    #[view]
    public fun get_experience_token_address(): address acquires ExperienceTokenInfo {
        assert!(exists<ExperienceTokenInfo>(MODULE_ADMIN_ACCOUNT), error::not_found(ERR_TOKEN_INFO_NOT_FOUND));
        let token_info = borrow_global<ExperienceTokenInfo>(MODULE_ADMIN_ACCOUNT);
        token_info.token_address
    }
}