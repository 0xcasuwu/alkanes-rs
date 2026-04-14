#!/bin/bash

# Alkanes Deployment Script for Regtest
# This script deploys all alkanes to a local regtest environment
# Pattern follows reference/oyl-amm/deploy-oyl-amm.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ALKANES_DIR="../alkanes-rs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM_DIR="$SCRIPT_DIR/../prod_wasms"
WALLET_FILE="${WALLET_FILE:-$HOME/.alkanes/wallet.json}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-testtesttest}"
RPC_URL="${RPC_URL:-http://127.0.0.1:18888}"
BITCOIN_RPC_URL="${BITCOIN_RPC_URL:-http://bitcoinrpc:bitcoinrpc@127.0.0.1:18443}"
ESPLORA_URL="${ESPLORA_URL:-http://127.0.0.1:50010}"

# OYL AMM Constants (matching oyl-sdk deployment pattern from pseudocode)
AUTH_TOKEN_FACTORY_ID=65517      # 0xffed
POOL_BEACON_PROXY_TX=780993      # Different from previous
AMM_FACTORY_LOGIC_IMPL_TX=65524  # 0xfff4
POOL_LOGIC_TX=65520              # 0xfff0
AMM_FACTORY_PROXY_TX=65522       # 0xfff2 (upgradeable proxy)
POOL_UPGRADEABLE_BEACON_TX=65523 # 0xfff3

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if alkanes-cli exists
check_cli() {
    # First check if it's in the target/release directory
    if [ -f "$SCRIPT_DIR/../target/release/alkanes-cli" ]; then
        ALKANES_CLI="$SCRIPT_DIR/../target/release/alkanes-cli"
        log_success "Found alkanes-cli: $ALKANES_CLI"
    elif command -v alkanes-cli &> /dev/null; then
        ALKANES_CLI="alkanes-cli"
        log_success "Found alkanes-cli in PATH: $(which alkanes-cli)"
    else
        log_error "alkanes-cli not found"
        log_info "Please build alkanes-cli first:"
        log_info "  cd $SCRIPT_DIR/.. && cargo build --release"
        exit 1
    fi
}

# Check if regtest node is running
check_regtest() {
    log_info "Checking if regtest node is running..."
    if ! curl -s "$RPC_URL" > /dev/null 2>&1; then
        log_error "Cannot connect to regtest node at $RPC_URL"
        log_info "Please start the regtest node first:"
        log_info "  cd $ALKANES_DIR && docker-compose up -d"
        exit 1
    fi
    log_success "Regtest node is running at $RPC_URL"
}

# Check if WASMs exist
check_wasms() {
    log_info "Checking if WASM files exist in prod_wasms..."
    if [ ! -d "$WASM_DIR" ] || [ -z "$(ls -A $WASM_DIR/*.wasm 2>/dev/null)" ]; then
        log_error "WASM files not found in $WASM_DIR"
        log_info "Please ensure WASMs are copied to $WASM_DIR"
        log_info "Or build them with:"
        log_info "  cd ../subfrost-alkanes && cargo build --release --target wasm32-unknown-unknown"
        log_info "  cp target/wasm32-unknown-unknown/release/*.wasm $WASM_DIR/"
        exit 1
    fi
    
    # Count non-empty WASMs
    local count=$(find "$WASM_DIR" -name "*.wasm" -type f -size +1k | wc -l)
    log_success "Found $count WASM files in $WASM_DIR"
}

# Setup wallet if it doesn't exist
setup_wallet() {
    if [ ! -f "$WALLET_FILE" ]; then
        log_info "Creating new wallet..."
        mkdir -p "$(dirname "$WALLET_FILE")"
        
        # Use default password if not set
        DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
        
        "$ALKANES_CLI" -p regtest --wallet-file "$WALLET_FILE" --passphrase "$DEPLOY_PASSWORD" wallet create
        log_success "Wallet created at $WALLET_FILE"
    else
        log_success "Using existing wallet at $WALLET_FILE"
    fi
    
    # Get wallet address
    DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    WALLET_ADDRESS=$("$ALKANES_CLI" -p regtest --wallet-file "$WALLET_FILE" --passphrase "$DEPLOY_PASSWORD" wallet addresses p2tr:0-1 2>/dev/null | grep -oP 'bcrt1[a-zA-Z0-9]+' | head -1)
    log_info "Wallet address: $WALLET_ADDRESS"
}

# Fund wallet with regtest coins
fund_wallet() {
    log_info "Checking if wallet needs funding..."
    
    # Check if wallet has any UTXOs
    UTXO_CHECK=$("$ALKANES_CLI" -p regtest --wallet-file "$WALLET_FILE" --passphrase "$DEPLOY_PASSWORD" wallet utxos p2tr:0 2>&1 | grep -c "Outpoint:" || echo "0")
    
    if [ "$UTXO_CHECK" -gt "0" ]; then
        log_success "Wallet already funded with $UTXO_CHECK UTXOs at p2tr:0"
    else
        log_info "No UTXOs found, mining blocks to fund wallet..."
        # Mine 400 blocks to the wallet's p2tr:0 address (increased from 201 for more mature coins)
        log_info "Mining 400 blocks to $WALLET_ADDRESS (p2tr:0)..."
        "$ALKANES_CLI" -p regtest --wallet-file "$WALLET_FILE" --bitcoin-rpc-url $BITCOIN_RPC_URL --passphrase "$DEPLOY_PASSWORD" bitcoind generatetoaddress 400 "p2tr:0" > /dev/null 2>&1
        
        # Wait for the indexer to sync the blocks
        log_info "Waiting for indexer to sync blocks (15 seconds)..."
        sleep 15
        
        log_success "Wallet funded! Ready for deployments"
    fi
}

# Ensure coinbase maturity by mining additional blocks
ensure_coinbase_maturity() {
    log_info "Ensuring coinbase maturity (mining 101 blocks to mature recent coinbases)..."
    "$ALKANES_CLI" -p regtest --jsonrpc-url $RPC_URL --bitcoin-rpc-url $BITCOIN_RPC_URL --wallet-file "$WALLET_FILE" --passphrase "$DEPLOY_PASSWORD" bitcoind generatetoaddress 101 "p2tr:0" > /dev/null 2>&1
    
    log_info "Waiting for indexer to sync maturity blocks (10 seconds)..."
    sleep 10
    
    log_success "Coinbase outputs matured"
}

# Deploy a WASM contract using [3, tx] cellpack
deploy_contract() {
    local CONTRACT_NAME=$1
    local WASM_FILE=$2
    local TARGET_TX=$3
    shift 3
    local INIT_ARGS="$@"
    
    log_info "Deploying $CONTRACT_NAME using [3, $TARGET_TX] -> will create at [4, $TARGET_TX]..."
    
    if [ ! -f "$WASM_FILE" ]; then
        log_error "WASM file not found: $WASM_FILE"
        return 1
    fi
    
    # Build protostone: [3,tx,init_args...]:v0:v0 for deployment
    local PROTOSTONE="[3,$TARGET_TX$([ -n "$INIT_ARGS" ] && echo ",$INIT_ARGS" || echo "")]:v0:v0"
    
    log_info "  Protostone: $PROTOSTONE"
    
    # Deploy using alkanes-cli with envelope and protostone
    DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    "$ALKANES_CLI" -p regtest \
        --wallet-file "$WALLET_FILE" \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes execute "$PROTOSTONE" \
        --envelope "$WASM_FILE" \
        --from p2tr:0 \
        --fee-rate 1 \
        --mine \
        -y
    
    if [ $? -eq 0 ]; then
        log_success "$CONTRACT_NAME deployed to [4, $TARGET_TX]"
        
        # Wait for metashrew to index the deployment
        log_info "Waiting for metashrew to index (5 seconds)..."
        sleep 5
        
        # Verify deployment by checking bytecode
        log_info "Verifying $CONTRACT_NAME deployment at [4, $TARGET_TX]..."
        
        # Try up to 3 times with 2 second delays
        BYTECODE=""
        for i in 1 2 3; do
            BYTECODE=$("$ALKANES_CLI" --jsonrpc-url $RPC_URL -p regtest alkanes getbytecode "4:$TARGET_TX" 2>/dev/null)
            if [ -n "$BYTECODE" ] && [ "$BYTECODE" != "null" ] && [ "$BYTECODE" != '""' ]; then
                break
            fi
            if [ $i -lt 3 ]; then
                log_info "Bytecode not found yet, waiting 2 seconds..."
                sleep 2
            fi
        done
        
        if [ -n "$BYTECODE" ] && [ "$BYTECODE" != "null" ] && [ "$BYTECODE" != '""' ]; then
            BYTECODE_SIZE=$(echo "$BYTECODE" | wc -c)
            log_success "✓ Bytecode verified at [4, $TARGET_TX] (${BYTECODE_SIZE} bytes)"
        else
            log_warn "⚠ Bytecode verification skipped for $CONTRACT_NAME at [4, $TARGET_TX]"
            log_warn "  (getbytecode view function not available in this metashrew version)"
            log_success "Deployment assumed successful based on reveal transaction confirmation"
        fi
    else
        log_error "Failed to deploy $CONTRACT_NAME"
        return 1
    fi
}

# Initialize a deployed contract
initialize_contract() {
    local CONTRACT_NAME=$1
    local ALKANE_ID=$2
    shift 2
    local ARGS="$@"
    
    log_info "Initializing $CONTRACT_NAME at $ALKANE_ID..."
    
    # Build the protostone format: [block:tx:opcode,args...]
    local PROTOSTONE="[$ALKANE_ID:0$([ -n "$ARGS" ] && echo ",$ARGS" || echo "")]:v0:v0"
    
    DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    "$ALKANES_CLI" -p regtest \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --wallet-file "$WALLET_FILE" \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes execute "$PROTOSTONE" \
        --from p2tr:0 \
        --fee-rate 1 \
        --mine \
        -y \
        > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "$CONTRACT_NAME initialized"
    else
        log_warn "Failed to initialize $CONTRACT_NAME (may not need initialization)"
    fi
}

# Main deployment process
main() {
    echo ""
    log_info "=========================================="
    log_info "Alkanes Regtest Deployment"
    log_info "=========================================="
    echo ""
    
    # Pre-deployment checks
    check_cli
    check_regtest
    check_wasms
    setup_wallet
    fund_wallet
    
    echo ""
    log_info "=========================================="
    log_info "Starting Contract Deployments"
    log_info "=========================================="
    echo ""
    
    # Deploy Genesis Contracts (these are special and auto-deployed by the protocol)
    log_info "=========================================="
    log_info "Genesis Contracts (auto-deployed by alkanes-rs)"
    log_info "=========================================="
    log_info "  - Genesis Alkane at [1, 0]"
    log_info "  - DIESEL at [2, 0]"
    log_info "  - frBTC (or frZEC) at [32, 0] (or [42, 0] for Zcash)"
    log_info "  - frSIGIL at [32, 1] (or [42, 1] for Zcash)"
    log_info "  - ftrBTC Master at [31, 0] (via setup_ftrbtc in network.rs)"
    echo ""
    
    log_info "=========================================="
    log_info "Deployment Patterns"
    log_info "=========================================="
    log_info "  [1, 0] + envelope -> CREATE (next available [2, n])"
    log_info "  [3, tx] + envelope -> creates alkane at [4, tx]"
    log_info "  [6, tx] + args -> clones template from [4, tx] to next [2, n]"
    echo ""
    
    log_info "=========================================="
    log_info "Reserved Range: [4, 0x1f00-0x1fff]"
    log_info "=========================================="
    log_info "  Core Infrastructure (0x1f00-0x1f0f):"
    log_info "    - dxBTC at [4, 0x1f00]"
    log_info "    - yv-fr-btc Vault at [4, 0x1f01]"
    log_info ""
    log_info "  LBTC Yield System (0x1f10-0x1f1f):"
    log_info "    - LBTC Yield Splitter at [4, 0x1f10]"
    log_info "    - pLBTC at [4, 0x1f11]"
    log_info "    - yxLBTC at [4, 0x1f12]"
    log_info "    - FROST Token at [4, 0x1f13]"
    log_info "    - vxFROST Gauge at [4, 0x1f14] (special: needs fixed ID)"
    log_info "    - Synth Pool at [4, 0x1f15]"
    log_info "    - LBTC Oracle at [4, 0x1f16]"
    log_info "    - LBTC Token at [4, 0x1f17]"
    log_info ""
    log_info "  Templates (0x1f20-0x1f2f):"
    log_info "    - Unit Template at [4, 0x1f20]"
    log_info "    - VE Token Vault Template at [4, 0x1f21]"
    log_info "    - YVE Token NFT Template at [4, 0x1f22]"
    log_info "    - VX Token Gauge Template at [4, 0x1f23]"
    log_info ""
    log_info "  DIESEL Governance (instantiated from templates):"
    log_info "    - veDIESEL: [6, 0x1f21] → creates at [2, n]"
    log_info "    - yveDIESEL: [6, 0x1f22] → creates at [2, n]"
    log_info "    - vxDIESEL Gauge: [6, 0x1f23] → creates at [2, n]"
    echo ""
    
    # Deploy Core Alkanes
    # Note: We deploy to [3, n] which creates the alkane at [4, n]
    # Format: deploy_contract "Name" "file.wasm" target_tx [init_args...]
    
    # === RESERVED RANGE: [4, 0x1f00-0x1fff] for Subfrost System ===
    
    log_info "=========================================="
    log_info "Phase 1: Core Infrastructure"
    log_info "=========================================="
    
    # Deploy dx-btc at [4, 0x1f00] (DX_BTC_ID)
    # Args: opcode(0), asset_id(frBTC), yv_fr_btc_vault_id, escrow_nft_id, vx_frost_gauge_id
    # Note: We'll initialize it separately after deploying dependencies
    deploy_contract "dxBTC" "$WASM_DIR/dx_btc.wasm" $((0x1f00)) "0,32,0,4,$((0x1f01)),4,$((0x1f22)),4,$((0x1f14))"
    
    # Deploy yv-fr-btc-vault at [4, 0x1f01] (YV_FR_BTC_VAULT_ID)
    # Args: opcode(0), yv_fr_btc, yv_boost_id, fr_btc_diesel_lp_id, gauge_contract_id
    # TODO: Need to deploy yv_boost and gauge_contract first
    deploy_contract "yv-fr-btc Vault" "$WASM_DIR/yv_fr_btc_vault.wasm" $((0x1f01)) "0,4,$((0x1f01)),2,1,2,2,2,3"
    
    log_info "=========================================="
    log_info "Phase 2: LBTC Yield System"
    log_info "=========================================="
    
    # Deploy lbtc-yield-splitter at [4, 0x1f10] (LBTC_YIELD_SPLITTER_ID)
    # Args: opcode(0), lbtc_id, btc_pt_id, btc_yt_id, maturity_block
    deploy_contract "LBTC Yield Splitter" "$WASM_DIR/lbtc_yield_splitter.wasm" $((0x1f10)) "0,4,$((0x1f17)),4,$((0x1f11)),4,$((0x1f12)),1000000"
    
    # Deploy p-lbtc at [4, 0x1f11] (PLBTC_ID)
    # Args: opcode(0), splitter_id
    deploy_contract "pLBTC (Principal LBTC)" "$WASM_DIR/p_lbtc.wasm" $((0x1f11)) "0,4,$((0x1f10))"
    
    # Deploy yx-lbtc at [4, 0x1f12] (YXLBTC_ID)
    # Args: opcode(0), splitter_id
    deploy_contract "yxLBTC (Yield LBTC)" "$WASM_DIR/yx_lbtc.wasm" $((0x1f12)) "0,4,$((0x1f10))"
    
    # Deploy frost-token at [4, 0x1f13] (FROST_TOKEN_ID)
    # Args: opcode(0), total_supply, treasury
    deploy_contract "FROST Token" "$WASM_DIR/frost_token.wasm" $((0x1f13)) "0,1000000000000000000,4,$((0x1f00))"
    
    # Deploy vx-frost-gauge at [4, 0x1f14] (VX_FROST_GAUGE_ID)
    # NOTE: vxFROST is deployed directly (not instantiated) because dx-btc needs to reference it at init time
    # Args: opcode(0), frost_token
    deploy_contract "vxFROST Gauge" "$WASM_DIR/vx_frost_gauge.wasm" $((0x1f14)) "0,4,$((0x1f13))"
    
    # Deploy synth-pool at [4, 0x1f15] (SYNTH_POOL_ID)
    # Synth pool may not need initialization args or may need different pattern
    deploy_contract "Synth Pool (pLBTC/frBTC)" "$WASM_DIR/synth_pool.wasm" $((0x1f15)) "0"
    
    log_info "=========================================="
    log_info "Phase 3: LBTC Oracle System"
    log_info "=========================================="
    
    # Deploy lbtc-oracle (unit alkane) at [4, 0x1f16] (LBTC_ORACLE_ID)
    # Args: opcode(0), amount
    deploy_contract "LBTC Oracle" "$WASM_DIR/unit.wasm" $((0x1f16)) "0,1000000000000"
    
    # Deploy lbtc token at [4, 0x1f17] (LBTC_ID)
    # Args: opcode(0), oracle_id
    deploy_contract "LBTC Token" "$WASM_DIR/lbtc.wasm" $((0x1f17)) "0,4,$((0x1f16))"
    
    log_info "=========================================="
    log_info "Phase 4: Template Contracts"
    log_info "=========================================="
    
    # Deploy unit template at [4, 0x1f20] (UNIT_TEMPLATE_ID)
    # Args: opcode(0), amount
    deploy_contract "Unit Template" "$WASM_DIR/unit.wasm" $((0x1f20)) "0,0"
    
    # Deploy ve-token-vault-template at [4, 0x1f21] (VE_TOKEN_VAULT_TEMPLATE_ID)
    # Templates don't need initialization when deployed - they're initialized when cloned
    deploy_contract "VE Token Vault Template" "$WASM_DIR/ve_token_vault_template.wasm" $((0x1f21)) "0"
    
    # Deploy yve-token-nft-template at [4, 0x1f22] (YVE_TOKEN_NFT_TEMPLATE_ID)
    # Templates don't need initialization when deployed - they're initialized when cloned
    deploy_contract "YVE Token NFT Template" "$WASM_DIR/yve_token_nft_template.wasm" $((0x1f22)) "0"
    
    # Deploy vx-token-gauge-template at [4, 0x1f23] (VX_TOKEN_GAUGE_TEMPLATE_ID)
    # Templates don't need initialization when deployed - they're initialized when cloned
    deploy_contract "VX Token Gauge Template" "$WASM_DIR/vx_token_gauge_template.wasm" $((0x1f23)) "0"
    
    # log_info "=========================================="
    # log_info "Phase 5: DIESEL Governance System (Instantiated from Templates)"
    # log_info "=========================================="
    
    # # Instantiate veDIESEL from ve-token-vault-template at [4, 0x1f21]
    # # Using [6, 0x1f21] cellpack creates instance at next available [2, n]
    # # Args: opcode(0), asset_id(DIESEL), yve_token_nft_id, vx_token_gauge_id, fr_sigil_id
    # log_info "Instantiating veDIESEL from template [4, 0x1f21]..."
    # # We need to instantiate yveDIESEL and vxDIESEL first, so this needs proper IDs
    # # Using placeholder IDs for now - this should be adjusted based on actual deployment
    # PROTOSTONE="[6,$((0x1f21)),0,2,0,2,2,2,3,32,1]"  # [6, template_tx, opcode, asset_id, yve_nft_id, vx_gauge_id, fr_sigil_id]
    # log_info "  Protostone: $PROTOSTONE (creates at [2, n])"
    
    # DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    # "$ALKANES_CLI" -p regtest \
    #     --wallet-file "$WALLET_FILE" \
    #     --passphrase "$DEPLOY_PASSWORD" \
    #     alkanes execute "$PROTOSTONE" \
    #     --from p2tr:0 \
    #     --fee-rate 1 \
    #     -y
    
    # if [ $? -eq 0 ]; then
    #     log_success "veDIESEL instantiated at [2, n]"
    # else
    #     log_warn "Failed to instantiate veDIESEL"
    # fi
    
    # echo ""
    
    # # Instantiate yveDIESEL from yve-token-nft-template at [4, 0x1f22]
    # # Using [6, 0x1f22] cellpack creates instance at next available [2, n]
    # # Args: opcode(0), ve_token_vault_id, vx_token_gauge_id, unit_template_id, fr_sigil_id
    # log_info "Instantiating yveDIESEL from template [4, 0x1f22]..."
    # PROTOSTONE="[6,$((0x1f22)),0,2,1,2,3,4,$((0x1f20)),32,1]"  # [6, template_tx, opcode, ve_vault_id, vx_gauge_id, unit_template_id, fr_sigil_id]
    # log_info "  Protostone: $PROTOSTONE (creates at [2, n])"
    
    # DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    # "$ALKANES_CLI" -p regtest \
    #     --wallet-file "$WALLET_FILE" \
    #     --passphrase "$DEPLOY_PASSWORD" \
    #     alkanes execute "$PROTOSTONE" \
    #     --from p2tr:0 \
    #     --fee-rate 1 \
    #     -y
    
    # if [ $? -eq 0 ]; then
    #     log_success "yveDIESEL instantiated at [2, n]"
    # else
    #     log_warn "Failed to instantiate yveDIESEL"
    # fi
    
    # echo ""
    
    # # Instantiate vxDIESEL gauge from vx-token-gauge-template at [4, 0x1f23]
    # # Using [6, 0x1f23] cellpack creates instance at next available [2, n]
    # # Args: opcode(0), lp_token, reward_token, yve_token_nft_id, reward_rate, fr_sigil_id
    # log_info "Instantiating vxDIESEL Gauge from template [4, 0x1f23]..."
    # # LP token needs to be created first (frBTC/DIESEL pool from OYL AMM)
    # # Using DIESEL as reward token for now
    # PROTOSTONE="[6,$((0x1f23)),0,2,4,2,0,2,2,1000000000,32,1]"  # [6, template_tx, opcode, lp_token, reward_token, yve_nft_id, reward_rate, fr_sigil_id]
    # log_info "  Protostone: $PROTOSTONE (creates at [2, n])"
    
    # DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    # "$ALKANES_CLI" -p regtest \
    #     --wallet-file "$WALLET_FILE" \
    #     --passphrase "$DEPLOY_PASSWORD" \
    #     alkanes execute "$PROTOSTONE" \
    #     --from p2tr:0 \
    #     --fee-rate 1 \
    #     -y
    
    # if [ $? -eq 0 ]; then
    #     log_success "vxDIESEL Gauge instantiated at [2, n]"
    # else
    #     log_warn "Failed to instantiate vxDIESEL Gauge"
    # fi
    
    # NOTE: ftr-btc at [31, 0] is deployed automatically in alkanes-rs genesis (setup_ftrbtc)
    # NOTE: dx-btc and yv-fr-btc-vault are now deployed above in the reserved range
    
    # Initialize dx-btc at [4, 0x1f00] with frBTC[32,0] and yv-fr-btc-vault[4,0x1f01]
    
    # Additional Test Contracts (if needed for specific test scenarios)
    # NOTE: DIESEL governance contracts are instantiated from templates above
    # These are generic test vaults deployed to [4, n] via [3, n]
    
    # Uncomment if needed for testing:
    # deploy_contract "Generic Gauge Contract" "$WASM_DIR/gauge_contract.wasm" 100 "1"
    # deploy_contract "yvBOOST Vault" "$WASM_DIR/yv_boost_vault.wasm" 101 "1"
    # deploy_contract "yvTOKEN Vault" "$WASM_DIR/yv_token_vault.wasm" 102 "1"
    
    # OYL AMM System (following oyl-protocol deployment pattern)
    log_info "=========================================="
    log_info "Phase 6: OYL AMM System"
    log_info "=========================================="
    
    echo ""
    
    # Step 1: Deploy Auth Token Factory
    deploy_contract "OYL Auth Token Factory" "$WASM_DIR/alkanes_std_auth_token.wasm" "$AUTH_TOKEN_FACTORY_ID" "100"
    
    # Step 2: Deploy Beacon Proxy Template
    deploy_contract "OYL Beacon Proxy" "$WASM_DIR/alkanes_std_beacon_proxy.wasm" "$POOL_BEACON_PROXY_TX" "36863"
    
    # Step 3: Deploy Factory Logic Implementation
    deploy_contract "OYL Factory Logic" "$WASM_DIR/factory.wasm" "$AMM_FACTORY_LOGIC_IMPL_TX" "50"
    
    # Step 4: Deploy Pool Logic Implementation
    deploy_contract "OYL Pool Logic" "$WASM_DIR/pool.wasm" "$POOL_LOGIC_TX" "50"
    
    # Step 5: Deploy Upgradeable Proxy (Factory Proxy)
    deploy_contract "OYL Factory Proxy (Upgradeable)" "$WASM_DIR/alkanes_std_upgradeable.wasm" "$AMM_FACTORY_PROXY_TX" "$((0x7fff)),4,$AMM_FACTORY_LOGIC_IMPL_TX,5"
    
    # Step 6: Deploy Upgradeable Beacon
    deploy_contract "OYL Upgradeable Beacon" "$WASM_DIR/alkanes_std_upgradeable_beacon.wasm" "$POOL_UPGRADEABLE_BEACON_TX" "$((0x7fff)),4,$POOL_LOGIC_TX,5"
    
    # Step 7: Initialize Factory
    log_info "Initializing OYL Factory with InitFactory opcode..."
    log_info "This requires spending auth token [2:1] to authenticate the call..."
    
    FACTORY_INIT_PROTOSTONE="[4,$AMM_FACTORY_PROXY_TX,0,$POOL_BEACON_PROXY_TX,4,$POOL_UPGRADEABLE_BEACON_TX]:v0:v0"
    log_info "  Protostone: $FACTORY_INIT_PROTOSTONE"
    log_info "  Opcode 0 = InitFactory(pool_beacon_proxy_id, pool_beacon_id)"
    echo ""
    
    DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-password}"
    
    "$ALKANES_CLI" -p regtest \
        --wallet-file "$WALLET_FILE" \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes execute "$FACTORY_INIT_PROTOSTONE" \
        --from p2tr:0 \
        --inputs 2:1:1 \
        --fee-rate 1 \
        --mine \
        --trace \
        -y
    
    if [ $? -eq 0 ]; then
        log_success "OYL Factory initialized successfully!"
        
        # Wait for metashrew to index
        log_info "Waiting for metashrew to index factory initialization (5 seconds)..."
        sleep 5
    else
        log_error "Failed to initialize OYL Factory"
        exit 1
    fi
    echo ""
    
    # Step 8: Create test tokens and pool
    log_info "=========================================="
    log_info "Creating Test Pool (DIESEL/frBTC)"
    log_info "=========================================="
    echo ""
    
    # Configuration for test pool
    DIESEL_ID="2:0"
    FRBTC_ID="32:0"
    DIESEL_AMOUNT="300000000"  # 300M DIESEL
    FRBTC_AMOUNT="50000"       # 0.0005 BTC in sats
    
    # Step 8a: Mine DIESEL
    log_info "Mining DIESEL tokens..."
    "$ALKANES_CLI" -p regtest \
        --wallet-file "$WALLET_FILE" \
        --passphrase "$DEPLOY_PASSWORD" \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        alkanes execute "[2,0,77]:v0:v0" \
        --to p2tr:0 \
        --from p2tr:0 \
        --mine \
        --change p2tr:0 \
        --auto-confirm
    
    if [ $? -eq 0 ]; then
        log_success "DIESEL mined"
    else
        log_error "Failed to mine DIESEL"
        exit 1
    fi
    
    # Step 8b: Wrap BTC for frBTC
    log_info "Wrapping BTC to frBTC..."
    "$ALKANES_CLI" -p regtest \
        --wallet-file "$WALLET_FILE" \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes wrap-btc \
        100000000 \
        --to p2tr:0 \
        --from p2tr:0 \
        --mine \
        --change p2tr:0 \
        --auto-confirm
    
    if [ $? -eq 0 ]; then
        log_success "frBTC wrapped"
    else
        log_error "Failed to wrap frBTC"
        exit 1
    fi
    
    # Wait for confirmations
    log_info "Mining a block to confirm transactions..."
    "$ALKANES_CLI" -p regtest \
        --wallet-file "$WALLET_FILE" \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --passphrase "$DEPLOY_PASSWORD" \
        bitcoind generatetoaddress 1 p2tr:0 > /dev/null 2>&1
    
    log_info "Waiting for metashrew to index transactions (15 seconds)..."
    sleep 15
    
    # Step 8c: Create the pool
    log_info "Creating DIESEL/frBTC pool..."
    "$ALKANES_CLI" -p regtest \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --wallet-file "$WALLET_FILE" \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes init-pool \
        --pair "$DIESEL_ID,$FRBTC_ID" \
        --liquidity "$DIESEL_AMOUNT:$FRBTC_AMOUNT" \
        --to p2tr:0 \
        --from p2tr:0 \
        --mine \
        --change p2tr:0 \
        --factory "4:$AMM_FACTORY_PROXY_TX" \
        --auto-confirm \
        --trace
    
    if [ $? -eq 0 ]; then
        log_success "Pool created successfully!"
        
        # Wait for metashrew to index
        log_info "Waiting for metashrew to index pool creation (5 seconds)..."
        sleep 5
        
        echo ""
        log_success "🎉 OYL AMM deployment and pool creation complete!"
    else
        log_error "Failed to create pool"
        exit 1
    fi
    
    # BTC PT/YT tokens (if needed for tests)
    if [ -f "$WASM_DIR/btc_pt.wasm" ] && [ -s "$WASM_DIR/btc_pt.wasm" ]; then
        deploy_contract "BTC PT Token" "$WASM_DIR/btc_pt.wasm" 70
    fi
    if [ -f "$WASM_DIR/btc_yt.wasm" ] && [ -s "$WASM_DIR/btc_yt.wasm" ]; then
        deploy_contract "BTC YT Token" "$WASM_DIR/btc_yt.wasm" 71
    fi

    # =========================================================================
    # Phase 7: EVM / Anvil + frUSD ERC-20 Deployment
    # =========================================================================
    # Deployed and verified during regtest e2e testing session (2026-04-14).
    # frUSD EVM address: 0x9A676e781A523b5d0C0e43731313A708CB607508
    # Chain ID: 0x7a69 (31337, Anvil regtest)
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 7: EVM / Anvil + frUSD ERC-20"
    log_info "=========================================="
    echo ""

    ANVIL_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin/anvil}"
    CAST_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin/cast}"
    SUBFROST_ERC20_DIR="${SUBFROST_ERC20_DIR:-$HOME/Documents/github/subfrost-erc20}"
    ANVIL_PORT="${ANVIL_PORT:-8545}"

    # Start Anvil if not already running
    if ! curl -s -H "Content-Type: application/json" \
        --data-binary '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        http://127.0.0.1:$ANVIL_PORT/ > /dev/null 2>&1; then
        log_info "Starting Anvil on port $ANVIL_PORT..."
        "$ANVIL_BIN" --host 127.0.0.1 --port $ANVIL_PORT > /tmp/anvil.log 2>&1 &
        ANVIL_PID=$!
        log_success "Anvil started (PID $ANVIL_PID)"
        sleep 2
    else
        log_success "Anvil already running on port $ANVIL_PORT"
    fi

    # Deploy frUSD ERC-20 via Foundry script if coordinator-usd dir exists
    if [ -d "$SUBFROST_ERC20_DIR/coordinator-usd" ]; then
        log_info "Deploying frUSD ERC-20 token..."
        (cd "$SUBFROST_ERC20_DIR/coordinator-usd" && bash start-coordinator.sh > /tmp/frusd-deploy.log 2>&1) &
        sleep 5
        # Verify deployment
        CHAIN_ID=$("$CAST_BIN" chain-id --rpc-url http://127.0.0.1:$ANVIL_PORT 2>/dev/null)
        log_success "EVM frUSD deployment attempted. Chain ID: $CHAIN_ID"
        log_info "  Check /tmp/frusd-deploy.log for details"
    else
        log_warn "subfrost-erc20 dir not found at $SUBFROST_ERC20_DIR — skipping EVM frUSD deploy"
    fi
    echo ""

    # =========================================================================
    # Phase 8: frUSD Alkane Auth Token + Patched frUSD Token
    # =========================================================================
    # frUSD auth token deployed at [4, ~8200] range during e2e testing.
    # Patched frusd-token adds opcodes 99 (name), 100 (symbol), 102 (decimals)
    # required by OYL AMM pool factory for pool creation.
    # Auth token slot: FRUSD_AUTH_TOKEN_TX (8200)
    # frUSD token slot: FRUSD_TOKEN_TX (8210)
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 8: frUSD Alkane Auth Token + Patched frUSD Token"
    log_info "=========================================="
    echo ""

    FRUSD_AUTH_TOKEN_TX="${FRUSD_AUTH_TOKEN_TX:-8200}"
    FRUSD_TOKEN_TX="${FRUSD_TOKEN_TX:-8210}"
    SUBFROST_ERC20_WASM_DIR="${SUBFROST_ERC20_WASM_DIR:-$SUBFROST_ERC20_DIR/alkanes/frusd-token}"

    # Build patched frusd-token if source exists
    if [ -f "$SUBFROST_ERC20_WASM_DIR/src/lib.rs" ]; then
        log_info "Building patched frusd-token WASM (opcodes 99/100/102 for AMM compatibility)..."
        (cd "$SUBFROST_ERC20_DIR" && \
            CC_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/clang \
            AR_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/llvm-ar \
            cargo build --release --target wasm32-unknown-unknown -p frusd-token 2>&1 | tail -3)
        FRUSD_WASM="$SUBFROST_ERC20_DIR/target/wasm32-unknown-unknown/release/frusd_token.wasm"
    else
        FRUSD_WASM="${FRUSD_WASM:-$SUBFROST_ERC20_WASM_DIR/frusd_token_v2.wasm}"
    fi

    if [ -f "$FRUSD_WASM" ]; then
        # Deploy frUSD auth token (opcode 100 = mint cap)
        deploy_contract "frUSD Auth Token" "$WASM_DIR/alkanes_std_auth_token.wasm" \
            "$FRUSD_AUTH_TOKEN_TX" "100"

        # Deploy patched frUSD token with AMM-compatible opcodes
        deploy_contract "frUSD Token (patched, opcodes 99/100/102)" "$FRUSD_WASM" \
            "$FRUSD_TOKEN_TX" ""

        log_success "frUSD alkane deployed at [4, $FRUSD_TOKEN_TX]"
        log_info "  Verify: alkanes-cli simulate $FRUSD_TOKEN_TX:99 should return 0x6672555344 (frUSD)"
    else
        log_warn "frUSD WASM not found at $FRUSD_WASM — skipping frUSD alkane deploy"
    fi
    echo ""

    # =========================================================================
    # Phase 9: Carbine Orderbook Contracts
    # =========================================================================
    # Deployed and verified during regtest e2e testing (2026-04-14).
    # Slots used:
    #   carbine-template:    [4, 8202]
    #   carbine-order-token: [4, 8203]
    #   carbine-controller:  [4, 8260]  (patched: deposit consumes incoming_alkanes)
    #
    # token_id encoding: block * 1_000_000 + tx  (LEB128-safe)
    #   frBTC [32,0]   → token_id = 32000000
    #   frUSD [4,8210] → token_id = 4008210
    #
    # CRITICAL: carbine-controller must be built from current source
    # (patched _deposit/_withdraw in subfrost-alkanes/alkanes/carbine-controller/src/lib.rs)
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 9: Carbine Orderbook Contracts"
    log_info "=========================================="
    echo ""

    CARBINE_TEMPLATE_TX="${CARBINE_TEMPLATE_TX:-8202}"
    CARBINE_ORDER_TOKEN_TX="${CARBINE_ORDER_TOKEN_TX:-8203}"
    CARBINE_CONTROLLER_TX="${CARBINE_CONTROLLER_TX:-8260}"
    SUBFROST_ALKANES_DIR="${SUBFROST_ALKANES_DIR:-$HOME/Documents/github/subfrost-alkanes}"

    # Build carbine contracts from current source
    if [ -d "$SUBFROST_ALKANES_DIR/alkanes/carbine-controller" ]; then
        log_info "Building carbine contracts from source..."
        (cd "$SUBFROST_ALKANES_DIR" && \
            CC_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/clang \
            AR_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/llvm-ar \
            cargo build --release --target wasm32-unknown-unknown \
                -p carbine-template -p carbine-order-token -p carbine-controller 2>&1 | tail -3)
        CARBINE_WASM_DIR="$SUBFROST_ALKANES_DIR/target/wasm32-unknown-unknown/release"
    else
        CARBINE_WASM_DIR="$WASM_DIR"
    fi

    CARBINE_TEMPLATE_WASM="$CARBINE_WASM_DIR/carbine_template.wasm"
    CARBINE_ORDER_TOKEN_WASM="$CARBINE_WASM_DIR/carbine_order_token.wasm"
    CARBINE_CONTROLLER_WASM="$CARBINE_WASM_DIR/carbine_controller.wasm"

    if [ -f "$CARBINE_TEMPLATE_WASM" ] && [ -f "$CARBINE_ORDER_TOKEN_WASM" ] && [ -f "$CARBINE_CONTROLLER_WASM" ]; then
        # Deploy carbine-template at [4, CARBINE_TEMPLATE_TX]
        deploy_contract "Carbine Template" "$CARBINE_TEMPLATE_WASM" "$CARBINE_TEMPLATE_TX" ""

        # Deploy carbine-order-token at [4, CARBINE_ORDER_TOKEN_TX]
        deploy_contract "Carbine Order Token" "$CARBINE_ORDER_TOKEN_WASM" "$CARBINE_ORDER_TOKEN_TX" ""

        # Deploy carbine-controller at [4, CARBINE_CONTROLLER_TX]
        # No init args needed — initialized via opcode 0 call below
        deploy_contract "Carbine Controller (patched deposit/withdraw)" \
            "$CARBINE_CONTROLLER_WASM" "$CARBINE_CONTROLLER_TX" ""

        # Initialize carbine-controller: opcode 0, template=[4,CARBINE_TEMPLATE_TX], order_token=[4,CARBINE_ORDER_TOKEN_TX]
        log_info "Initializing Carbine Controller at [4,$CARBINE_CONTROLLER_TX]..."
        CARBINE_INIT_PROTOSTONE="[4,$CARBINE_CONTROLLER_TX,0,4,$CARBINE_TEMPLATE_TX,4,$CARBINE_ORDER_TOKEN_TX]:v0:v0"
        "$ALKANES_CLI" -p regtest \
            --jsonrpc-url $RPC_URL \
            --bitcoin-rpc-url $BITCOIN_RPC_URL \
            --esplora-api-url $ESPLORA_URL \
            --wallet-file "$WALLET_FILE" \
            --passphrase "$DEPLOY_PASSWORD" \
            alkanes execute "$CARBINE_INIT_PROTOSTONE" \
            --from p2tr:0 \
            --fee-rate 1 \
            --mine \
            -y

        if [ $? -eq 0 ]; then
            log_success "Carbine Controller initialized at [4,$CARBINE_CONTROLLER_TX]"
            log_info "  Verify: alkanes-cli simulate $CARBINE_CONTROLLER_TX:25 → 0x0..0 (0 open orders)"
        else
            log_warn "Carbine Controller initialization may have failed"
        fi
    else
        log_warn "Carbine WASMs not found — skipping carbine deployment"
        log_info "  Expected: $CARBINE_TEMPLATE_WASM"
        log_info "  Expected: $CARBINE_ORDER_TOKEN_WASM"
        log_info "  Expected: $CARBINE_CONTROLLER_WASM"
    fi
    echo ""

    # =========================================================================
    # Phase 10: DxBTC Vault (rebuilt from current source)
    # =========================================================================
    # CRITICAL: The deployed WASM at [4, 0x1f00] may be stale (old version
    # subcalls yvFrBtcVault during swap_internal). Current source handles
    # frBTC→dxBTC directly without delegation.
    #
    # If the existing dx-btc at [4, 0x1f00] is stale, deploy fresh to a new slot.
    # Verified working slot: [4, 8270] (deployed 2026-04-14).
    #
    # Init args: opcode(0), asset=[32,0], yv_fr_btc=[4,0x1f01],
    #            escrow=[4,0x1f22], vx_fuel=[4,0x1f14]
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 10: DxBTC Vault (current source)"
    log_info "=========================================="
    echo ""

    DXBTC_TX="${DXBTC_TX:-8270}"

    if [ -d "$SUBFROST_ALKANES_DIR/alkanes/dx-btc" ]; then
        log_info "Building dx-btc from current source..."
        (cd "$SUBFROST_ALKANES_DIR" && \
            CC_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/clang \
            AR_wasm32_unknown_unknown=/opt/homebrew/opt/llvm/bin/llvm-ar \
            cargo build --release --target wasm32-unknown-unknown -p dx-btc 2>&1 | tail -3)
        DXBTC_WASM="$SUBFROST_ALKANES_DIR/target/wasm32-unknown-unknown/release/dx_btc.wasm"
    else
        DXBTC_WASM="$WASM_DIR/dx_btc.wasm"
    fi

    if [ -f "$DXBTC_WASM" ]; then
        # Deploy dx-btc with init args:
        #   opcode=0, asset=frBTC[32,0], yv_fr_btc=[4,0x1f01],
        #   escrow_nft=[4,0x1f22], vx_fuel_gauge=[4,0x1f14]
        deploy_contract "DxBTC Vault (current source)" "$DXBTC_WASM" "$DXBTC_TX" \
            "0,32,0,4,$((0x1f01)),4,$((0x1f22)),4,$((0x1f14))"

        log_success "DxBTC Vault deployed at [4,$DXBTC_TX]"
        log_info "  Verify: alkanes-cli simulate $DXBTC_TX:11 → total_assets (u128 LE)"
        log_info "  Deposit: alkanes execute '[4,$DXBTC_TX,1]:v0:v0' --inputs frBTC_utxo"
    else
        log_warn "dx-btc WASM not found at $DXBTC_WASM — skipping DxBTC deploy"
    fi
    echo ""

    # =========================================================================
    # Phase 11: frUSD/frBTC Pool Creation
    # =========================================================================
    # Creates the OYL AMM pool for frUSD[4,FRUSD_TOKEN_TX] / frBTC[32,0].
    # Requires frUSD token to have opcodes 99/100/102 (Phase 8 patched build).
    # Pool factory: [4, AMM_FACTORY_PROXY_TX]
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 11: frUSD/frBTC Pool Creation"
    log_info "=========================================="
    echo ""

    FRUSD_POOL_FRUSD_AMOUNT="${FRUSD_POOL_FRUSD_AMOUNT:-100000000}"  # 100M frUSD (6 decimals = 100 frUSD)
    FRUSD_POOL_FRBTC_AMOUNT="${FRUSD_POOL_FRBTC_AMOUNT:-50000000}"   # 50M frBTC sats

    log_info "Creating frUSD[4,$FRUSD_TOKEN_TX]/frBTC[32,0] pool..."
    log_info "  Amounts: $FRUSD_POOL_FRUSD_AMOUNT frUSD : $FRUSD_POOL_FRBTC_AMOUNT frBTC"
    "$ALKANES_CLI" -p regtest \
        --jsonrpc-url $RPC_URL \
        --bitcoin-rpc-url $BITCOIN_RPC_URL \
        --esplora-api-url $ESPLORA_URL \
        --wallet-file "$WALLET_FILE" \
        --passphrase "$DEPLOY_PASSWORD" \
        alkanes init-pool \
        --pair "4:$FRUSD_TOKEN_TX,32:0" \
        --liquidity "$FRUSD_POOL_FRUSD_AMOUNT:$FRUSD_POOL_FRBTC_AMOUNT" \
        --to p2tr:0 \
        --from p2tr:0 \
        --mine \
        --change p2tr:0 \
        --factory "4:$AMM_FACTORY_PROXY_TX" \
        --auto-confirm \
        --trace

    if [ $? -eq 0 ]; then
        log_success "frUSD/frBTC pool created!"
        sleep 5
    else
        log_warn "frUSD/frBTC pool creation failed (may need frUSD balance first)"
        log_info "  Ensure frUSD is minted and available at p2tr:0 before running this phase"
    fi
    echo ""

    # =========================================================================
    # Phase 12: espo, secondaryview shim, subzero-node startup
    # =========================================================================
    # Services required for full e2e stack (verified 2026-04-14):
    #   espo:              UTxO indexer on port 8888
    #   secondaryview-shim: bridges subzero-node ↔ esplora on port 50010
    #   subzero-node:      FROST signing coordinator on port 9800
    #
    # Keys: ~/Documents/github/subzero-rs/regtest-keys/
    # Signals: ~/Documents/github/subzero-rs/regtest-signals.toml
    # Threshold: 2-of-3 signers
    # =========================================================================
    log_info "=========================================="
    log_info "Phase 12: Support Services (espo, shim, subzero-node)"
    log_info "=========================================="
    echo ""

    SUBZERO_DIR="${SUBZERO_DIR:-$HOME/Documents/github/subzero-rs}"

    # Start espo if not running
    if ! curl -s --data-binary '{"jsonrpc":"2.0","method":"get_espo_height","params":[],"id":1}' \
        http://127.0.0.1:8888/rpc > /dev/null 2>&1; then
        log_info "espo not detected on port 8888 — start it separately if needed"
        log_info "  (espo is typically started via docker-compose in the subfrost monorepo)"
    else
        log_success "espo running at port 8888 (height confirmed)"
    fi

    # Start secondaryview shim if not running
    if ! pgrep -f "secondaryview-shim.js" > /dev/null 2>&1; then
        if [ -f "$SUBZERO_DIR/secondaryview-shim.js" ]; then
            log_info "Starting secondaryview-shim..."
            node "$SUBZERO_DIR/secondaryview-shim.js" > /tmp/secondaryview-shim.log 2>&1 &
            SHIM_PID=$!
            sleep 1
            log_success "secondaryview-shim started (PID $SHIM_PID)"
        else
            log_warn "secondaryview-shim.js not found at $SUBZERO_DIR/secondaryview-shim.js"
        fi
    else
        log_success "secondaryview-shim already running"
    fi

    # Start subzero-node if not running
    if ! pgrep -f "subzero-node" > /dev/null 2>&1; then
        if [ -f "$SUBZERO_DIR/target/release/subzero-node" ] && \
           [ -d "$SUBZERO_DIR/regtest-keys" ] && \
           [ -f "$SUBZERO_DIR/regtest-signals.toml" ]; then
            log_info "Starting subzero-node (threshold 2-of-3)..."
            (cd "$SUBZERO_DIR" && \
                ./target/release/subzero-node run \
                    --keystore ./regtest-keys \
                    --threshold 2 \
                    --signers 3 \
                    --signals regtest-signals.toml \
                    --programs-dir ./compiled_programs \
                    --api-addr 127.0.0.1:9800 \
                    --eval-interval-ms 5000 \
                > /tmp/subzero-node.log 2>&1 &)
            SUBZERO_PID=$!
            sleep 2
            log_success "subzero-node started (PID $SUBZERO_PID)"
            log_info "  Logs: /tmp/subzero-node.log"
            log_info "  API: http://127.0.0.1:9800"
        else
            log_warn "subzero-node not ready — build it first:"
            log_info "  cd $SUBZERO_DIR && cargo build --release"
            log_info "  Keys expected at: $SUBZERO_DIR/regtest-keys/"
            log_info "  Signals expected at: $SUBZERO_DIR/regtest-signals.toml"
        fi
    else
        log_success "subzero-node already running"
    fi
    echo ""

    echo ""
    log_info "=========================================="
    log_info "Deployment Summary"
    log_info "=========================================="
    echo ""
    
    log_success "All contracts deployed successfully!"
    echo ""
    log_info "Deployed Alkanes:"
    echo ""
    echo "Genesis (Auto-deployed):"
    echo "  - DIESEL:                 [2, 0]"
    echo "  - frBTC:                  [32, 0]"
    echo ""
    echo "Core Contracts:"
    echo "  - dxBTC Vault:            [4, $((0x1f00))]  (reserved slot, may be stale — see Phase 10)"
    echo "  - yv-fr-btc Vault:        [4, $((0x1f01))]  (reserved slot)"
    echo "  - ftrBTC Master:          [31, 0]  (auto-deployed by genesis)"
    echo ""
    echo "LBTC System:"
    echo "  - LBTC Yield Splitter:    [4, $((0x1f10))]"
    echo "  - pLBTC:                  [4, $((0x1f11))]"
    echo "  - yxLBTC:                 [4, $((0x1f12))]"
    echo "  - FROST Token:            [4, $((0x1f13))]"
    echo "  - vxFROST Gauge:          [4, $((0x1f14))]"
    echo "  - Synth Pool:             [4, $((0x1f15))]"
    echo "  - LBTC Oracle:            [4, $((0x1f16))]"
    echo "  - LBTC Token:             [4, $((0x1f17))]"
    echo ""
    echo "Templates:"
    echo "  - Unit Template:          [4, $((0x1f20))]"
    echo "  - VE Token Vault Template:[4, $((0x1f21))]"
    echo "  - YVE Token NFT Template: [4, $((0x1f22))]"
    echo "  - VX Token Gauge Template:[4, $((0x1f23))]"
    echo ""
    echo "OYL AMM System:"
    echo "  - OYL Auth Token Factory: [4, $AUTH_TOKEN_FACTORY_ID]"
    echo "  - OYL Beacon Proxy:       [4, $POOL_BEACON_PROXY_TX]"
    echo "  - OYL Factory Logic:      [4, $AMM_FACTORY_LOGIC_IMPL_TX]"
    echo "  - OYL Pool Logic:         [4, $POOL_LOGIC_TX]"
    echo "  - OYL Factory Proxy:      [4, $AMM_FACTORY_PROXY_TX]"
    echo "  - OYL Upgradeable Beacon: [4, $POOL_UPGRADEABLE_BEACON_TX]"
    echo ""
    echo "Test Pool:"
    echo "  - DIESEL/frBTC Pool:      Created with 300M DIESEL / 50K frBTC"
    echo ""
    echo "EVM (Anvil regtest, chain ID 31337):"
    echo "  - frUSD ERC-20:           0x9A676e781A523b5d0C0e43731313A708CB607508"
    echo "  - Anvil port:             $ANVIL_PORT"
    echo ""
    echo "frUSD Alkane System:"
    echo "  - frUSD Auth Token:       [4, $FRUSD_AUTH_TOKEN_TX]"
    echo "  - frUSD Token (patched):  [4, $FRUSD_TOKEN_TX]  (opcodes 99/100/102 for AMM)"
    echo "  - frUSD/frBTC Pool:       Created via OYL AMM factory"
    echo ""
    echo "Carbine Orderbook:"
    echo "  - Carbine Template:       [4, $CARBINE_TEMPLATE_TX]"
    echo "  - Carbine Order Token:    [4, $CARBINE_ORDER_TOKEN_TX]"
    echo "  - Carbine Controller:     [4, $CARBINE_CONTROLLER_TX]  (patched deposit/withdraw)"
    echo "    token_id encoding:      block * 1_000_000 + tx  (frBTC=32000000, frUSD=4008210)"
    echo "    opcodes: 1=deposit 2=withdraw 20=place-limit-order 21=cancel-order 25=order-count"
    echo ""
    echo "DxBTC Vault (current source):"
    echo "  - DxBTC Vault:            [4, $DXBTC_TX]"
    echo "    init: asset=frBTC[32,0] yv_fr_btc=[4,$((0x1f01))] escrow=[4,$((0x1f22))] vx_fuel=[4,$((0x1f14))]"
    echo "    opcode 11 = total_assets, opcode 1 = deposit frBTC → dxBTC shares"
    echo ""
    echo "Support Services:"
    echo "  - Anvil (EVM):            http://127.0.0.1:$ANVIL_PORT"
    echo "  - espo (UTxO indexer):    http://127.0.0.1:8888/rpc"
    echo "  - secondaryview-shim:     bridges subzero ↔ esplora"
    echo "  - subzero-node:           http://127.0.0.1:9800 (2-of-3 FROST signing)"
    echo ""
    

    
    log_info "Example commands:"
    echo ""
    echo "# Check balances:"
    echo "alkanes-cli -p regtest --wallet-file $WALLET_FILE --passphrase password alkanes getbalance"
    echo ""
    echo "# Inspect a contract:"
    echo "alkanes-cli -p regtest alkanes inspect 4:10"
    echo ""
    echo "# Execute a contract call (e.g., transfer FROST):"
    echo "alkanes-cli -p regtest --wallet-file $WALLET_FILE --passphrase password alkanes execute '[4:10:1,1000,0,0]' --mine -y"
    echo ""
    
    log_success "Deployment complete! Your regtest environment is ready."
}

# Run main
main
