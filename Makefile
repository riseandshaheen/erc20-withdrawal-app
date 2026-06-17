all: erc20-withdrawal-dapp

# =============================================================================
# Clean
# =============================================================================

clean: clean-dependencies

clean-dependencies: ## Clean the test dependencies
	@echo "Cleaning dependencies"
	@rm -rf $(DOWNLOADS_DIR)

# =============================================================================
# Dependencies
# =============================================================================

DOWNLOADS_DIR = .downloads
CARTESI_TEST_MACHINE_IMAGES = $(DOWNLOADS_DIR)/linux.bin
$(CARTESI_TEST_MACHINE_IMAGES):
	@mkdir -p $(DOWNLOADS_DIR)
	@wget -nc -i dependencies -P $(DOWNLOADS_DIR)
	@shasum -ca 256 dependencies.sha256
	@cd $(DOWNLOADS_DIR) && ln -s rootfs-tools.ext2 rootfs.ext2
	@cd $(DOWNLOADS_DIR) && ln -s linux-6.5.13-ctsi-1-v0.20.0.bin linux.bin

download-dependencies: | $(CARTESI_TEST_MACHINE_IMAGES)

dependencies.sha256:
	@shasum -a 256 $(DOWNLOADS_DIR)/rootfs-tools* $(DOWNLOADS_DIR)/linux-*.bin > $@

# =============================================================================
# App
# =============================================================================

erc20-withdrawal-dapp: .cartesi/image ## ERC-20 withdrawal test dapp

.cartesi/image: download-dependencies install.sh ## Create ERC-20 withdrawal test application
	echo "Creating ERC-20 withdrawal test application"
	mkdir -p .cartesi
	rm -rf .cartesi/image
	PORTAL=$${CARTESI_DEVNET_ERC20_PORTAL_ADDRESS:-0x22E57511C30CcE6CDaa742E13CE3b774fDC663b1}; \
	TOKEN=$${CARTESI_DEVNET_TEST_ERC20_ADDRESS:-0x88A2120B7068E78692C8fd12E751d610B6377E4d}; \
	cartesi-machine --ram-length=128Mi \
		--ram-image=$(DOWNLOADS_DIR)/linux.bin \
		--flash-drive=label:root,filename:$(DOWNLOADS_DIR)/rootfs.ext2 \
		--flash-drive=label:accounts,length:4Mi,mount:false,user:dapp \
		--env=TRUSTED_ERC20_PORTAL=$$PORTAL \
		--env=TRUSTED_ERC20_TOKEN=$$TOKEN \
		--append-init-file=install.sh \
		--store=.cartesi/image --final-hash -- /usr/local/bin/erc20-withdrawal-dapp

deploy-erc20-withdrawal-dapp: .cartesi/image ## Deploy ERC-20 withdrawal test application
	@set -e; \
	APP=$${APP:-erc20-withdrawal-dapp}; \
	GUARDIAN=$${GUARDIAN:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}; \
	BUILDER=$${CARTESI_DEVNET_WITHDRAWAL_OUTPUT_BUILDER_ADDRESS:-0x0745787835A019cd4dae8EDB541Fbc0647793d63}; \
	DRIVE_START_INDEX=$$(jq -r '.config.flash_drive[] | select(.length == 4194304) | (.start / 4194304 | floor)' \
		.cartesi/image/config.json); \
	WITHDRAWAL_CONFIG=$$(jq -cn \
		--arg guardian "$$GUARDIAN" \
		--arg builder "$$BUILDER" \
		--argjson drive "$$DRIVE_START_INDEX" \
		'{guardian:$$guardian,log2_leaves_per_account:0,log2_max_num_of_accounts:17,accounts_drive_start_index:$$drive,withdrawal_output_builder:$$builder}'); \
	echo "Deploying $$APP with accounts-drive start index $$DRIVE_START_INDEX"; \
	./cartesi-rollups-cli deploy application "$$APP" .cartesi/image \
		--salt "$$(openssl rand -hex 32)" \
		--withdrawal-config "$$WITHDRAWAL_CONFIG" \
		--enable=false; \
	./cartesi-rollups-cli app execution-parameters set "$$APP" snapshot_policy EVERY_EPOCH; \
	./cartesi-rollups-cli app status "$$APP" enabled --yes
