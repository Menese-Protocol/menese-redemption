//! Redemption canister, verified against deployed SNS modules.
//!
//! The canister's other suites verify it against `test/MockLedger.mo` and
//! `test/MockGov.mo`, which encode a model of the ICRC-1 ledger and SNS Governance. A
//! divergence between that model and the deployed counterparty is outside what those
//! suites can establish. This harness installs `build/redemption.wasm` on PocketIC
//! alongside a launched SNS whose governance and ledger are the byte-identical modules
//! running on mainnet, and drives the payout path against them.
//!
//! No SNS rule is reimplemented here. Every result is read from the deployed canisters.
//!
//! Properties that require the deployed modules, and the checks that establish them:
//!
//!   S1..S3  compiled-in constants against the live nervous system parameters
//!   C1      `get_nervous_system_parameters` arity: the .did declares `(null)`, one
//!           argument, where the Motoko import declares `()`
//!   C5/C6   audit R-3, a rejecting ledger, induced by stopping the ledger canister
//!   C9/C10  `IncreaseDissolveDelay` is additive, as read back from governance
//!   C11..13 the permission model: which principal controls the neuron, and with what
//!   C14     the staking subaccount, against the neuron id governance minted
//!   L1/L2   ICRC-1 deduplication and the transaction window on the deployed ledger,
//!           the properties the canister's retry safety depends on
//!
//! Environment:
//!   MENESE_SNS_INIT_YAML      path to the sns_init.yaml to launch (required)
//!   MENESE_REDEMPTION_WASM    path to build/redemption.wasm (required)
//!   MENESE_REPORT_JSON        where to write the machine-readable report (optional)

use candid::{CandidType, Decode, Deserialize, Encode, Nat, Principal};
use ic_base_types::PrincipalId;
use ic_crypto_sha2::Sha256;
use ic_ledger_core::Tokens;
use ic_nervous_system_agent::{
    helpers::sns as sns_agent_helpers, pocketic_impl::PocketIcAgent,
    sns::governance::GovernanceCanister,
};
use ic_nervous_system_common_test_utils::wasm_helpers::SMALLEST_VALID_WASM_BYTES;
use ic_nervous_system_integration_tests::pocket_ic_helpers::{
    NnsInstaller, add_wasms_to_sns_wasm, nns, sns,
};
use ic_nns_constants::ROOT_CANISTER_ID;
use ic_nns_governance_api::CreateServiceNervousSystem;
use ic_sns_governance_api::pb::v1 as sns_pb;
use ic_sns_swap::pb::v1::Lifecycle;
use icp_ledger::{AccountIdentifier, DEFAULT_TRANSFER_FEE};
use icrc_ledger_types::icrc1::account::Account as IcrcAccount;
use icrc_ledger_types::icrc1::transfer::{TransferArg, TransferError};
use pocket_ic::{PocketIcBuilder, nonblocking::PocketIc};
use std::path::PathBuf;
use std::time::Duration;

const ONE_DAY: u64 = 24 * 60 * 60;
const FIRST_PARTICIPANT_USER_TEST_ID: u64 = 1_000;
const CYCLES_PER_DAPP_CANISTER: u128 = 100_000_000_000_000;
const CYCLES_FOR_REDEMPTION: u128 = 1_000_000_000_000_000;

/// The canister's own compiled-in constants (`src/Logic.mo`). Restated here so a drift
/// between the module and the live SNS is a failing check rather than a silent surprise.
const DISSOLVE_FLOOR_SECONDS: u64 = 15_724_800; // 26 weeks, 182 days
const MIN_NEURON_STAKE_E8S: u64 = 1_000_000_000; // 10 MENES
const FEE_E8S: u64 = 10_000;
const EIGHTEEN_MONTHS_SECONDS: u64 = 47_260_800; // 547 days

// The four entries under test, mirroring `test/e2e.sh` so the two runs are comparable.
const AMT_A: u64 = 500_000_000; // 5 MENES, liquid, payable
const AMT_B: u64 = 5_000; // below the fee, liquid, unpayable
const AMT_C: u64 = 2_000_000_000; // 20 MENES, neuron at the floor
const AMT_D: u64 = 1_000_000_000; // 10 MENES, neuron at 18 months
const AMT_E: u64 = 200_000_000; // 2 MENES, liquid, positioned BEHIND both neuron entries

// ---------------------------------------------------------------------------
// The redemption canister's Candid interface, restated in Rust.
//
// Field and variant names are hashed by Candid, so every name below must match
// `src/Types.mo` exactly. Non-snake-case names are deliberate.
// ---------------------------------------------------------------------------

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct NeuronPayout {
    delaySeconds: u64,
}

#[derive(CandidType, Deserialize, Clone, Debug)]
enum Payout {
    Liquid,
    Neuron(NeuronPayout),
}

#[derive(CandidType, Deserialize, Clone, Debug)]
enum Source {
    Wallet,
    Stake(Nat),
}

#[derive(CandidType, Deserialize, Clone, Debug)]
struct Entry {
    owner: Principal,
    amount: Nat,
    payout: Payout,
    source: Source,
}

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct InitArg {
    ledger: Principal,
    governance: Principal,
    entries: Vec<Entry>,
    initialReserve: Nat,
    fee: Nat,
}

#[derive(CandidType, Deserialize, Clone, Debug, PartialEq)]
enum Status {
    Pending,
    Funded,
    Claimed,
    Delayed,
    Granted,
    Done,
    Failed(String),
}

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct Progress {
    status: Status,
    destination: Option<Principal>,
    neuronId: Option<Vec<u8>>,
    lastError: Option<String>,
    attempts: Nat,
    txTime: Option<u64>,
}

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct Stats {
    entries: Nat,
    done: Nat,
    granted: Nat,
    failed: Nat,
    pending: Nat,
    paidOut: Nat,
    totalObligation: Nat,
    initialReserve: Nat,
    feesPaid: Nat,
}

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct Reconciliation {
    initialReserve: Nat,
    paidOut: Nat,
    feesPaid: Nat,
    reserveBalance: Nat,
    expectedBalance: Nat,
    holds: bool,
}

#[allow(non_snake_case)]
#[derive(CandidType, Deserialize, Clone, Debug)]
struct Settlement {
    settled: bool,
    writtenOff: Nat,
    reason: String,
}

/// Motoko's `Result.Result<T, E>`: `variant { ok : T; err : E }`.
#[derive(CandidType, Deserialize, Clone, Debug)]
enum MoResult<T, E> {
    #[serde(rename = "ok")]
    Ok(T),
    #[serde(rename = "err")]
    Err(E),
}

impl<T, E: std::fmt::Debug> MoResult<T, E> {
    fn is_ok(&self) -> bool {
        matches!(self, MoResult::Ok(_))
    }
    fn describe(&self) -> String
    where
        T: std::fmt::Debug,
    {
        match self {
            MoResult::Ok(v) => format!("ok({v:?})"),
            MoResult::Err(e) => format!("err({e:?})"),
        }
    }
}

// ---------------------------------------------------------------------------
// A check ledger, so one run reports every outcome rather than stopping at the first
// failure. The run still fails if any check failed.
// ---------------------------------------------------------------------------

struct Checks {
    rows: Vec<(String, bool, String)>,
}

impl Checks {
    fn new() -> Self {
        Self { rows: Vec::new() }
    }

    fn check(&mut self, id: &str, name: &str, passed: bool, detail: impl Into<String>) {
        let detail = detail.into();
        let mark = if passed { "ok  " } else { "FAIL" };
        eprintln!("  {mark} {id:<4} {name:<58} {detail}");
        self.rows.push((format!("{id} {name}"), passed, detail));
    }

    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, id: &str, name: &str, got: T, want: T) {
        let passed = got == want;
        let detail = if passed {
            format!("{got:?}")
        } else {
            format!("got={got:?} want={want:?}")
        };
        self.check(id, name, passed, detail);
    }

    fn failures(&self) -> Vec<&(String, bool, String)> {
        self.rows.iter().filter(|(_, passed, _)| !passed).collect()
    }
}

// ---------------------------------------------------------------------------
// Independent reimplementation of the IC's neuron staking subaccount, from
// `rs/nervous_system/common/src/ledger.rs`:
//
//   sha256( 0x0c || "neuron-stake" || controller_bytes || nonce_be_u64 )
//
// Derived from the IC source rather than from `src/Logic.mo`, so the canister is checked
// against the formula rather than against its own copy of it.
// ---------------------------------------------------------------------------
fn staking_subaccount(controller: Principal, nonce: u64) -> Vec<u8> {
    let domain = b"neuron-stake";
    let mut hasher = Sha256::new();
    hasher.write(&[domain.len() as u8]);
    hasher.write(domain);
    hasher.write(controller.as_slice());
    hasher.write(&nonce.to_be_bytes());
    hasher.finish().to_vec()
}

/// Minimal JSON string escaping, so the report needs no extra dependency.
fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

async fn now_seconds(pocket_ic: &PocketIc) -> u64 {
    pocket_ic.get_time().await.as_nanos_since_unix_epoch() / 1_000_000_000
}

async fn list_all_neurons(
    pocket_ic: &PocketIc,
    governance_canister_id: PrincipalId,
) -> Vec<sns_pb::Neuron> {
    const PAGE_SIZE: u32 = 100;
    let governance_canister = GovernanceCanister::new(governance_canister_id);
    let mut all_neurons: Vec<sns_pb::Neuron> = Vec::new();
    let mut start_page_at: Option<sns_pb::NeuronId> = None;

    loop {
        let page = governance_canister
            .list_neurons(
                pocket_ic,
                sns_pb::ListNeurons {
                    limit: PAGE_SIZE,
                    start_page_at: start_page_at.clone(),
                    of_principal: None,
                },
            )
            .await
            .unwrap()
            .neurons;

        let page_len = page.len();
        if let Some(last) = page.last() {
            start_page_at = last.id.clone();
        }
        all_neurons.extend(page);

        if page_len < PAGE_SIZE as usize {
            return all_neurons;
        }
    }
}

fn dissolve_delay_of(neuron: &sns_pb::Neuron) -> u64 {
    match neuron.dissolve_state {
        Some(sns_pb::neuron::DissolveState::DissolveDelaySeconds(seconds)) => seconds,
        _ => 0,
    }
}

fn permissions_of(neuron: &sns_pb::Neuron, principal: PrincipalId) -> Option<Vec<i32>> {
    neuron
        .permissions
        .iter()
        .find(|permission| permission.principal == Some(principal))
        .map(|permission| {
            let mut types = permission.permission_type.clone();
            types.sort_unstable();
            types
        })
}

/// Every `NeuronPermissionType` this SNS Governance build defines, read from the live
/// nervous system parameters rather than assumed. This is the set a claimer is permitted to
/// grant.
fn all_permissions_live(parameters: &sns_pb::NervousSystemParameters) -> Vec<i32> {
    let mut types = parameters
        .neuron_grantable_permissions
        .as_ref()
        .expect("governance did not report neuron_grantable_permissions")
        .permissions
        .clone();
    types.sort_unstable();
    types
}

// ---------------------------------------------------------------------------
// Calling the redemption canister.
// ---------------------------------------------------------------------------

async fn call_update<A: CandidType, R: CandidType + for<'a> Deserialize<'a>>(
    pocket_ic: &PocketIc,
    canister: Principal,
    sender: Principal,
    method: &str,
    arg: &A,
) -> Result<R, String> {
    match pocket_ic
        .update_call(canister, sender, method, Encode!(arg).unwrap())
        .await
    {
        Ok(bytes) => Ok(Decode!(&bytes, R).unwrap_or_else(|err| {
            panic!("could not decode the reply from `{method}`: {err}");
        })),
        Err(reject) => Err(format!("{reject:?}")),
    }
}

async fn call_query<R: CandidType + for<'a> Deserialize<'a>>(
    pocket_ic: &PocketIc,
    canister: Principal,
    method: &str,
) -> R {
    let bytes = pocket_ic
        .query_call(canister, Principal::anonymous(), method, Encode!(&()).unwrap())
        .await
        .unwrap_or_else(|reject| panic!("`{method}` was rejected: {reject:?}"));
    Decode!(&bytes, R).unwrap_or_else(|err| panic!("could not decode `{method}`: {err}"))
}

async fn get_progress(pocket_ic: &PocketIc, redemption: Principal) -> Vec<Progress> {
    call_query::<Vec<Progress>>(pocket_ic, redemption, "getProgress").await
}

/// One `process(i)` call. Returns the canister's own Result, or the reject if the call
/// itself was refused (which is a different, and worse, outcome).
async fn process(
    pocket_ic: &PocketIc,
    redemption: Principal,
    index: u64,
) -> Result<MoResult<String, String>, String> {
    call_update(
        pocket_ic,
        redemption,
        Principal::anonymous(),
        "process",
        &Nat::from(index),
    )
    .await
}

/// Drive one entry to a terminal status, one step per call, with a bound so a wedged entry
/// fails the run instead of hanging it.
async fn drive_to_terminal(
    pocket_ic: &PocketIc,
    redemption: Principal,
    index: u64,
    max_steps: usize,
) -> (Status, Vec<String>) {
    let mut log = Vec::new();
    for _ in 0..max_steps {
        let status = get_progress(pocket_ic, redemption).await[index as usize]
            .status
            .clone();
        if matches!(status, Status::Done | Status::Failed(_)) {
            return (status, log);
        }
        let outcome = process(pocket_ic, redemption, index).await;
        log.push(match &outcome {
            Ok(result) => result.describe(),
            Err(reject) => format!("REJECTED: {reject}"),
        });
    }
    let status = get_progress(pocket_ic, redemption).await[index as usize]
        .status
        .clone();
    (status, log)
}

async fn sns_balance(pocket_ic: &PocketIc, ledger: Principal, account: IcrcAccount) -> u64 {
    let bytes = pocket_ic
        .query_call(
            ledger,
            Principal::anonymous(),
            "icrc1_balance_of",
            Encode!(&account).unwrap(),
        )
        .await
        .unwrap();
    let balance = Decode!(&bytes, Nat).unwrap();
    u64::try_from(balance.0).unwrap_or(u64::MAX)
}

async fn sns_transfer(
    pocket_ic: &PocketIc,
    ledger: Principal,
    sender: Principal,
    arg: &TransferArg,
) -> Result<Result<Nat, TransferError>, String> {
    match pocket_ic
        .update_call(ledger, sender, "icrc1_transfer", Encode!(arg).unwrap())
        .await
    {
        Ok(bytes) => Ok(Decode!(&bytes, Result<Nat, TransferError>).unwrap()),
        Err(reject) => Err(format!("{reject:?}")),
    }
}

async fn manage_neuron(
    pocket_ic: &PocketIc,
    governance: Principal,
    sender: Principal,
    request: sns_pb::ManageNeuron,
) -> Result<sns_pb::ManageNeuronResponse, String> {
    match pocket_ic
        .update_call(
            governance,
            sender,
            "manage_neuron",
            Encode!(&request).unwrap(),
        )
        .await
    {
        Ok(bytes) => Ok(Decode!(&bytes, sns_pb::ManageNeuronResponse).unwrap()),
        Err(reject) => Err(format!("{reject:?}")),
    }
}

#[tokio::test]
async fn menese_redemption_simulation() {
    let yaml_path = PathBuf::from(
        std::env::var("MENESE_SNS_INIT_YAML")
            .expect("MENESE_SNS_INIT_YAML must point at the sns_init.yaml to launch"),
    );
    let redemption_wasm_path = PathBuf::from(
        std::env::var("MENESE_REDEMPTION_WASM")
            .expect("MENESE_REDEMPTION_WASM must point at build/redemption.wasm"),
    );
    let redemption_wasm = std::fs::read(&redemption_wasm_path)
        .unwrap_or_else(|err| panic!("could not read {}: {err}", redemption_wasm_path.display()));

    eprintln!("=== Menese redemption simulation ===");
    eprintln!("init file : {}", yaml_path.display());
    eprintln!(
        "module    : {} ({} bytes)",
        redemption_wasm_path.display(),
        redemption_wasm.len()
    );

    let mut checks = Checks::new();

    // -----------------------------------------------------------------------
    // Step 1. Launch a real SNS. This is the same path `menese_genesis_sim`
    // takes: a CreateServiceNervousSystem proposal to mainnet NNS Governance,
    // a real swap, real finalization. It exists here only to produce a
    // genuinely-configured SNS Governance and its ledger.
    // -----------------------------------------------------------------------

    let mut create_service_nervous_system: CreateServiceNervousSystem =
        ic_sns_cli::read_create_service_nervous_system_from_init_yaml(&yaml_path)
            .expect("sns_init.yaml did not convert into a CreateServiceNervousSystem proposal");

    let swap_parameters = create_service_nervous_system.swap_parameters.clone().unwrap();
    let minimum_participant_count = swap_parameters.minimum_participants.unwrap();
    let raise_icp_e8s = swap_parameters
        .minimum_direct_participation_icp
        .unwrap()
        .e8s
        .unwrap();

    let pocket_ic = PocketIcBuilder::new()
        .with_nns_subnet()
        .with_sns_subnet()
        .with_application_subnet()
        .build_async()
        .await;

    let per_participant_e8s = raise_icp_e8s / minimum_participant_count;
    let remainder_e8s = raise_icp_e8s % minimum_participant_count;
    let participations: Vec<(PrincipalId, u64)> = (0..minimum_participant_count)
        .map(|index| {
            let principal = PrincipalId::new_user_test_id(FIRST_PARTICIPANT_USER_TEST_ID + index);
            let amount_e8s = per_participant_e8s + if index == 0 { remainder_e8s } else { 0 };
            (principal, amount_e8s)
        })
        .collect();

    let initial_balances: Vec<(AccountIdentifier, Tokens)> = participations
        .iter()
        .map(|(principal, amount_e8s)| {
            (
                AccountIdentifier::new(*principal, None),
                Tokens::from_e8s(amount_e8s + DEFAULT_TRANSFER_FEE.get_e8s()),
            )
        })
        .collect();

    eprintln!("Installing the mainnet NNS canisters ...");
    {
        let mut nns_installer = NnsInstaller::default();
        nns_installer.with_mainnet_nns_canister_versions();
        nns_installer.with_ledger_balances(initial_balances);
        nns_installer.install(&pocket_ic).await;
    }

    eprintln!("Publishing the mainnet SNS WASMs to SNS-W ...");
    {
        let with_mainnet_sns_canisters = true;
        add_wasms_to_sns_wasm(&pocket_ic, with_mainnet_sns_canisters)
            .await
            .unwrap();
    }

    // The dapp canisters the DAO takes over. Immaterial here, but the proposal will not
    // validate without them existing and being controlled by NNS Root.
    let genesis_controllers: Vec<PrincipalId> = vec![ROOT_CANISTER_ID.get()];
    let dapp_canister_settings = ic_management_canister_types::CanisterSettings {
        controllers: Some(genesis_controllers.iter().map(|p| p.0).collect()),
        ..Default::default()
    };
    let application_subnet_id = pocket_ic.topology().await.get_app_subnets()[0];
    let mut installed_dapp_canister_ids: Vec<PrincipalId> = Vec::new();
    let mut substituted = 0;
    for canister in create_service_nervous_system.dapp_canisters.clone() {
        let requested = Principal::from(canister.id.unwrap());
        let created = pocket_ic
            .create_canister_with_id(
                Some(ROOT_CANISTER_ID.get().0),
                Some(dapp_canister_settings.clone()),
                requested,
            )
            .await;
        let canister_id = match created {
            Ok(canister_id) => canister_id,
            Err(_) => {
                substituted += 1;
                pocket_ic
                    .create_canister_on_subnet(
                        Some(ROOT_CANISTER_ID.get().0),
                        Some(dapp_canister_settings.clone()),
                        application_subnet_id,
                    )
                    .await
            }
        };
        pocket_ic
            .add_cycles(canister_id, CYCLES_PER_DAPP_CANISTER)
            .await;
        pocket_ic
            .install_canister(
                canister_id,
                SMALLEST_VALID_WASM_BYTES.to_vec(),
                vec![],
                Some(ROOT_CANISTER_ID.get().0),
            )
            .await;
        installed_dapp_canister_ids.push(PrincipalId::from(canister_id));
    }
    if substituted > 0 {
        create_service_nervous_system.dapp_canisters = installed_dapp_canister_ids
            .iter()
            .map(|id| ic_nervous_system_proto::pb::v1::Canister { id: Some(*id) })
            .collect();
    }

    eprintln!("Submitting the CreateServiceNervousSystem proposal ...");
    let (sns, _nns_proposal_id) = nns::governance::propose_to_deploy_sns_and_wait(
        &pocket_ic,
        create_service_nervous_system.clone(),
        "menese-redemption",
    )
    .await;
    eprintln!("  governance {}", sns.governance.canister_id);
    eprintln!("  ledger     {}", sns.ledger.canister_id);
    eprintln!("  root       {}", sns.root.canister_id);

    sns::swap::await_swap_lifecycle(&pocket_ic, sns.swap.canister_id, Lifecycle::Open)
        .await
        .unwrap();

    let confirmation_text = swap_parameters.confirmation_text.clone();
    for (principal, amount_e8s) in &participations {
        let agent = PocketIcAgent::new(&pocket_ic, *principal);
        sns_agent_helpers::participate_in_swap(
            &agent,
            ic_nervous_system_agent::sns::swap::SwapCanister::new(sns.swap.canister_id),
            Tokens::from_e8s(*amount_e8s),
            confirmation_text.clone(),
        )
        .await
        .unwrap();
    }

    let swap_init = sns::swap::get_init(&pocket_ic, sns.swap.canister_id)
        .await
        .init
        .unwrap();
    let swap_due = swap_init.swap_due_timestamp_seconds.unwrap();
    pocket_ic
        .advance_time(Duration::from_secs(
            (swap_due + ONE_DAY).saturating_sub(now_seconds(&pocket_ic).await),
        ))
        .await;
    for _ in 0..40 {
        pocket_ic.tick().await;
    }
    sns::swap::await_swap_finalization_status(
        &pocket_ic,
        sns.swap.canister_id,
        sns::swap::SwapFinalizationStatus::Committed,
    )
    .await
    .unwrap();
    eprintln!("Swap committed; the SNS is live.");

    let governance = Principal::from(sns.governance.canister_id);
    let ledger = Principal::from(sns.ledger.canister_id);
    let sns_root = Principal::from(sns.root.canister_id);

    // -----------------------------------------------------------------------
    // Step 2. Our compiled-in constants against the live parameters.
    // -----------------------------------------------------------------------

    eprintln!("\n-- setup: compiled-in constants against the live SNS --");
    let parameters =
        sns::governance::get_nervous_system_parameters(&pocket_ic, sns.governance.canister_id)
            .await;
    let live_floor = parameters
        .neuron_minimum_dissolve_delay_to_vote_seconds
        .unwrap();
    let live_min_stake = parameters.neuron_minimum_stake_e8s.unwrap();
    let live_fee = parameters.transaction_fee_e8s.unwrap();
    let live_permissions = all_permissions_live(&parameters);

    checks.eq(
        "S1",
        "live voting floor equals compiled-in DISSOLVE_FLOOR_SECONDS",
        live_floor,
        DISSOLVE_FLOOR_SECONDS,
    );
    checks.eq(
        "S2",
        "live minimum neuron stake equals compiled-in MIN_NEURON_STAKE_E8S",
        live_min_stake,
        MIN_NEURON_STAKE_E8S,
    );
    checks.eq("S3", "live transfer fee equals compiled-in FEE_E8S", live_fee, FEE_E8S);
    eprintln!(
        "       live neuron_grantable_permissions = {live_permissions:?} ({} of them)",
        live_permissions.len()
    );

    // -----------------------------------------------------------------------
    // Step 3. Get real SNS tokens, by disbursing a swap participant's neuron.
    // Every token the redemption canister pays out below is a token this SNS
    // actually minted.
    // -----------------------------------------------------------------------

    let funder = PrincipalId::new_user_test_id(9_001);
    let reserve_e8s = AMT_A + AMT_B + AMT_C + AMT_D + AMT_E + 5 * FEE_E8S;

    let participant0 = participations[0].0;
    let neurons = list_all_neurons(&pocket_ic, sns.governance.canister_id).await;
    let mut participant_neurons: Vec<&sns_pb::Neuron> = neurons
        .iter()
        .filter(|neuron| permissions_of(neuron, participant0).is_some())
        .collect();
    participant_neurons.sort_by_key(|neuron| dissolve_delay_of(neuron));
    assert!(
        !participant_neurons.is_empty(),
        "the swap produced no neurons for participant 0, so there is nothing to disburse"
    );

    let source_neuron = participant_neurons[0];
    let source_delay = dissolve_delay_of(source_neuron);
    let source_subaccount = source_neuron.id.as_ref().unwrap().id.clone();
    eprintln!(
        "\nFunding: disbursing participant-0 neuron with dissolve delay {source_delay}s, \
         stake {} e8s",
        source_neuron.cached_neuron_stake_e8s
    );
    if source_delay > 0 {
        let _ = manage_neuron(
            &pocket_ic,
            governance,
            Principal::from(participant0),
            sns_pb::ManageNeuron {
                subaccount: source_subaccount.clone(),
                command: Some(sns_pb::manage_neuron::Command::Configure(
                    sns_pb::manage_neuron::Configure {
                        operation: Some(
                            sns_pb::manage_neuron::configure::Operation::StartDissolving(
                                sns_pb::manage_neuron::StartDissolving {},
                            ),
                        ),
                    },
                )),
            },
        )
        .await;
        pocket_ic
            .advance_time(Duration::from_secs(source_delay + ONE_DAY))
            .await;
        for _ in 0..10 {
            pocket_ic.tick().await;
        }
    }

    let disburse = manage_neuron(
        &pocket_ic,
        governance,
        Principal::from(participant0),
        sns_pb::ManageNeuron {
            subaccount: source_subaccount.clone(),
            command: Some(sns_pb::manage_neuron::Command::Disburse(
                sns_pb::manage_neuron::Disburse {
                    amount: None, // the whole cached stake
                    to_account: Some(sns_pb::Account {
                        owner: Some(funder),
                        subaccount: None,
                    }),
                },
            )),
        },
    )
    .await
    .expect("the disburse call was rejected");
    eprintln!("  disburse -> {:?}", disburse.command);

    let funder_balance = sns_balance(
        &pocket_ic,
        ledger,
        IcrcAccount {
            owner: Principal::from(funder),
            subaccount: None,
        },
    )
    .await;
    eprintln!("  funder holds {funder_balance} e8s; the reserve needs {reserve_e8s}");
    assert!(
        funder_balance >= reserve_e8s + FEE_E8S,
        "disbursing one basket neuron did not cover the reserve"
    );

    // -----------------------------------------------------------------------
    // Step 4. Install the redemption canister and fund its reserve.
    // -----------------------------------------------------------------------

    let holder_a = PrincipalId::new_user_test_id(9_100); // liquid, payable
    let holder_b = PrincipalId::new_user_test_id(9_101); // liquid, dust
    let holder_c = PrincipalId::new_user_test_id(9_102); // neuron at the floor
    let holder_d = PrincipalId::new_user_test_id(9_103); // neuron at 18 months
    // Where the neurons must actually land. A DIFFERENT principal from the snapshot owner,
    // standing in for the holder's NNS-dapp identity -- which is the whole reason
    // `setNeuronDestination` exists.
    let holder_e = PrincipalId::new_user_test_id(9_104); // liquid, behind the neuron entries
    let dest_c = PrincipalId::new_user_test_id(9_202);
    let dest_d = PrincipalId::new_user_test_id(9_203);

    let redemption = pocket_ic
        .create_canister_on_subnet(None, None, application_subnet_id)
        .await;
    pocket_ic
        .add_cycles(redemption, CYCLES_FOR_REDEMPTION)
        .await;

    let entries = vec![
        Entry {
            owner: Principal::from(holder_a),
            amount: Nat::from(AMT_A),
            payout: Payout::Liquid,
            source: Source::Wallet,
        },
        Entry {
            owner: Principal::from(holder_b),
            amount: Nat::from(AMT_B),
            payout: Payout::Liquid,
            source: Source::Wallet,
        },
        Entry {
            owner: Principal::from(holder_c),
            amount: Nat::from(AMT_C),
            payout: Payout::Neuron(NeuronPayout {
                delaySeconds: DISSOLVE_FLOOR_SECONDS,
            }),
            source: Source::Stake(Nat::from(1u64)),
        },
        Entry {
            owner: Principal::from(holder_d),
            amount: Nat::from(AMT_D),
            payout: Payout::Neuron(NeuronPayout {
                delaySeconds: EIGHTEEN_MONTHS_SECONDS,
            }),
            source: Source::Stake(Nat::from(2u64)),
        },
        // Index 4, deliberately behind both neuron entries: if a stalled entry can hold up
        // the ones behind it, this is the entry that never gets paid.
        Entry {
            owner: Principal::from(holder_e),
            amount: Nat::from(AMT_E),
            payout: Payout::Liquid,
            source: Source::Wallet,
        },
    ];

    let init = InitArg {
        ledger,
        governance,
        entries,
        initialReserve: Nat::from(reserve_e8s),
        fee: Nat::from(FEE_E8S),
    };

    pocket_ic
        .install_canister(
            redemption,
            redemption_wasm.clone(),
            Encode!(&init).unwrap(),
            None,
        )
        .await;
    eprintln!("\nRedemption canister installed at {redemption}");

    let funding = sns_transfer(
        &pocket_ic,
        ledger,
        Principal::from(funder),
        &TransferArg {
            from_subaccount: None,
            to: IcrcAccount {
                owner: redemption,
                subaccount: None,
            },
            amount: Nat::from(reserve_e8s),
            fee: Some(Nat::from(FEE_E8S)),
            memo: None,
            created_at_time: None,
        },
    )
    .await
    .expect("funding transfer was rejected");
    assert!(funding.is_ok(), "funding transfer failed: {funding:?}");

    // -----------------------------------------------------------------------
    // Step 5. The checks.
    // -----------------------------------------------------------------------

    eprintln!("\n-- C1: verifyParameters against real governance --");
    // Run with the ledger stopped, so C5 observes a rejecting ledger from the first payout
    // attempt and the timer cannot settle entry 0 beforehand.
    pocket_ic
        .stop_canister(ledger, Some(sns_root))
        .await
        .expect("could not stop the SNS ledger");

    let verify: Result<MoResult<String, String>, String> = call_update(
        &pocket_ic,
        redemption,
        Principal::anonymous(),
        "verifyParameters",
        &(),
    )
    .await;
    match &verify {
        Ok(result) => checks.check(
            "C1",
            "verifyParameters() succeeds against real governance",
            result.is_ok(),
            result.describe(),
        ),
        Err(reject) => checks.check(
            "C1",
            "verifyParameters() succeeds against real governance",
            false,
            format!("the call was REJECTED: {reject}"),
        ),
    }

    eprintln!("\n-- C5: a REJECTING ledger must not destroy an entry (audit R-3) --");
    let rejected = process(&pocket_ic, redemption, 0).await;
    let rejected_detail = match &rejected {
        Ok(result) => result.describe(),
        Err(reject) => format!("REJECTED: {reject}"),
    };
    let progress_while_down = get_progress(&pocket_ic, redemption).await;
    checks.check(
        "C5a",
        "process(0) reports failure while the ledger is stopped",
        matches!(&rejected, Ok(MoResult::Err(_))),
        rejected_detail,
    );
    checks.eq(
        "C5b",
        "entry 0 is NOT marked Done by the rejection",
        progress_while_down[0].status.clone(),
        Status::Pending,
    );
    checks.check(
        "C5c",
        "entry 0 recorded the error rather than losing it",
        progress_while_down[0].lastError.is_some(),
        format!("{:?}", progress_while_down[0].lastError),
    );
    checks.check(
        "C5d",
        "the deterministic created_at_time was fixed on the first attempt",
        progress_while_down[0].txTime.is_some(),
        format!("{:?}", progress_while_down[0].txTime),
    );

    pocket_ic
        .start_canister(ledger, Some(sns_root))
        .await
        .expect("could not restart the SNS ledger");

    eprintln!("\n-- C6: after recovery the holder is paid exactly once --");
    let (status_a, log_a) = drive_to_terminal(&pocket_ic, redemption, 0, 6).await;
    eprintln!("       entry 0 log: {log_a:?}");
    checks.eq("C6a", "entry 0 reaches Done", status_a, Status::Done);
    let balance_a = sns_balance(
        &pocket_ic,
        ledger,
        IcrcAccount {
            owner: Principal::from(holder_a),
            subaccount: None,
        },
    )
    .await;
    checks.eq(
        "C6b",
        "holder A was credited exactly the entry amount, once",
        balance_a,
        AMT_A,
    );

    eprintln!("\n-- C7: dust below the fee is written off visibly --");
    let (status_b, _) = drive_to_terminal(&pocket_ic, redemption, 1, 4).await;
    checks.check(
        "C7",
        "entry 1 (dust) is Failed, not silently skipped",
        matches!(status_b, Status::Failed(_)),
        format!("{status_b:?}"),
    );

    eprintln!("\n-- C2/C3/C4: the destination nomination --");
    let awaiting = process(&pocket_ic, redemption, 2).await;
    let awaiting_detail = match &awaiting {
        Ok(result) => result.describe(),
        Err(reject) => format!("REJECTED: {reject}"),
    };
    checks.check(
        "C2",
        "a neuron entry does nothing before its owner nominates",
        awaiting_detail.contains("awaiting"),
        awaiting_detail,
    );

    let intruder: Result<MoResult<Nat, String>, String> = call_update(
        &pocket_ic,
        redemption,
        Principal::from(holder_a), // owns entry 0, not entry 2
        "setNeuronDestination",
        &Principal::from(dest_c),
    )
    .await;
    let intruder_ok = match &intruder {
        Ok(MoResult::Err(_)) => true,
        Ok(MoResult::Ok(n)) => {
            // A caller with no neuron entry must not be able to nominate anything.
            eprintln!("       WARNING: a non-owner nominated {n:?} entries");
            false
        }
        Err(_) => true,
    };
    checks.check(
        "C3",
        "a principal with no neuron entry cannot nominate",
        intruder_ok,
        match &intruder {
            Ok(result) => result.describe(),
            Err(reject) => format!("REJECTED: {reject}"),
        },
    );

    for (owner, destination) in [(holder_c, dest_c), (holder_d, dest_d)] {
        let nominated: Result<MoResult<Nat, String>, String> = call_update(
            &pocket_ic,
            redemption,
            Principal::from(owner),
            "setNeuronDestination",
            &Principal::from(destination),
        )
        .await;
        let ok = matches!(&nominated, Ok(MoResult::Ok(_)));
        checks.check(
            "C4",
            &format!("owner {owner} nominates {destination}"),
            ok,
            match &nominated {
                Ok(result) => result.describe(),
                Err(reject) => format!("REJECTED: {reject}"),
            },
        );
    }

    // -----------------------------------------------------------------------
    // C17: a stalled entry must not hold up the entries behind it.
    //
    // SNS Governance is stopped, so both neuron entries fail at the claim step on every
    // attempt. Entry 4 is a liquid entry sitting behind them and needs only the ledger.
    // Under a driver that rescans from index 0 it would never be attempted at all.
    // -----------------------------------------------------------------------
    eprintln!("\n-- C17: a stalled entry does not starve the entries behind it --");
    pocket_ic
        .stop_canister(governance, Some(sns_root))
        .await
        .expect("could not stop SNS governance");

    for _ in 0..24 {
        let _ = call_update::<(), MoResult<String, String>>(
            &pocket_ic,
            redemption,
            Principal::anonymous(),
            "processNext",
            &(),
        )
        .await;
    }

    let stalled = get_progress(&pocket_ic, redemption).await;
    checks.check(
        "C17a",
        "the neuron entries are stalled while governance is down",
        !matches!(stalled[2].status, Status::Done) && !matches!(stalled[3].status, Status::Done),
        format!("{:?} / {:?}", stalled[2].status, stalled[3].status),
    );
    checks.eq(
        "C17b",
        "entry 4, behind both stalled entries, still reaches Done",
        stalled[4].status.clone(),
        Status::Done,
    );
    let balance_e = sns_balance(
        &pocket_ic,
        ledger,
        IcrcAccount {
            owner: Principal::from(holder_e),
            subaccount: None,
        },
    )
    .await;
    checks.eq(
        "C17c",
        "entry 4 was credited its full amount",
        balance_e,
        AMT_E,
    );

    let settlement_stalled: Settlement = call_update(
        &pocket_ic,
        redemption,
        Principal::anonymous(),
        "settlement",
        &(),
    )
    .await
    .expect("settlement() was rejected");
    checks.check(
        "C17d",
        "settlement names the stalled entry rather than reporting silence",
        settlement_stalled.reason.contains("has failed")
            && settlement_stalled.reason.contains("consecutive"),
        settlement_stalled.reason.clone(),
    );

    pocket_ic
        .start_canister(governance, Some(sns_root))
        .await
        .expect("could not restart SNS governance");

    eprintln!("\n-- C8..C14: the neuron path, against real governance --");
    let (status_c, log_c) = drive_to_terminal(&pocket_ic, redemption, 2, 12).await;
    eprintln!("       entry 2 log: {log_c:?}");
    checks.eq("C8", "entry 2 reaches Done", status_c.clone(), Status::Done);

    // Entry 3 is left to the canister's own 15-second timer, so the push mechanism is
    // exercised rather than assumed.
    // Entry 3 accumulated failures while governance was stopped for C17, so the per-entry
    // backoff holds it for up to its capped interval of 240 ticks. The budget here covers
    // that interval, so this also exercises recovery from backoff: the first success resets
    // the count and the remaining steps run on consecutive ticks.
    eprintln!("       leaving entry 3 to the canister's own timer ...");
    for _ in 0..400 {
        pocket_ic.advance_time(Duration::from_secs(20)).await;
        pocket_ic.tick().await;
        let status = get_progress(&pocket_ic, redemption).await[3].status.clone();
        if matches!(status, Status::Done | Status::Failed(_)) {
            break;
        }
    }
    let progress = get_progress(&pocket_ic, redemption).await;
    checks.eq(
        "C8b",
        "entry 3 reaches Done driven only by the canister's timer",
        progress[3].status.clone(),
        Status::Done,
    );

    let neurons = list_all_neurons(&pocket_ic, sns.governance.canister_id).await;
    let redemption_principal = PrincipalId::from(redemption);

    for (index, owner, destination, want_delay, id) in [
        (2usize, holder_c, dest_c, DISSOLVE_FLOOR_SECONDS, "C9"),
        (3usize, holder_d, dest_d, EIGHTEEN_MONTHS_SECONDS, "C10"),
    ] {
        let recorded = match progress[index].neuronId.clone() {
            Some(recorded) => recorded,
            None => {
                // Recorded rather than raised: a wedged entry must still leave a readable
                // report for the remaining checks.
                checks.check(
                    &format!("{id}x"),
                    &format!("entry {index} recorded a neuron id"),
                    false,
                    format!("status is {:?}", progress[index].status),
                );
                continue;
            }
        };

        // C14: the subaccount the canister derived is the one the IC's formula gives.
        let derived = staking_subaccount(redemption, index as u64);
        checks.check(
            &format!("{id}d"),
            &format!("entry {index} neuron id equals the IC staking-subaccount formula"),
            derived == recorded,
            format!("{}", hex::encode(&recorded[..8])),
        );

        let neuron = match neurons
            .iter()
            .find(|neuron| neuron.id.as_ref().map(|n| n.id.clone()) == Some(recorded.clone()))
        {
            Some(neuron) => neuron,
            None => {
                checks.check(
                    &format!("{id}y"),
                    &format!("real governance holds a neuron for entry {index}"),
                    false,
                    "no such neuron".to_string(),
                );
                continue;
            }
        };

        checks.eq(
            id,
            &format!("entry {index} dissolve delay, read off real governance"),
            dissolve_delay_of(neuron),
            want_delay,
        );
        checks.eq(
            &format!("{id}a"),
            &format!("entry {index} stake, read off real governance"),
            neuron.cached_neuron_stake_e8s,
            if index == 2 { AMT_C } else { AMT_D },
        );

        // C11: the neuron is controlled by the NOMINATED principal, not the snapshot owner.
        let destination_permissions = permissions_of(neuron, destination);
        checks.check(
            &format!("{id}b"),
            &format!("entry {index} neuron is controlled by the nominated destination"),
            destination_permissions.as_ref() == Some(&live_permissions),
            format!("{destination_permissions:?}"),
        );
        checks.check(
            &format!("{id}c"),
            &format!("entry {index} snapshot owner has NO permissions"),
            permissions_of(neuron, owner).is_none(),
            format!("{:?}", permissions_of(neuron, owner)),
        );

        // C12: the canister stripped itself.
        checks.check(
            &format!("{id}e"),
            &format!("entry {index}: the redemption canister holds no permissions"),
            permissions_of(neuron, redemption_principal).is_none(),
            format!("{:?}", permissions_of(neuron, redemption_principal)),
        );
    }

    eprintln!("\n-- C15/C16: the books, against the real ledger --");
    let reconciliation: Reconciliation = call_update(
        &pocket_ic,
        redemption,
        Principal::anonymous(),
        "reconcile",
        &(),
    )
    .await
    .expect("reconcile() was rejected");
    let live_reserve = sns_balance(
        &pocket_ic,
        ledger,
        IcrcAccount {
            owner: redemption,
            subaccount: None,
        },
    )
    .await;
    eprintln!("       {reconciliation:?}");
    checks.check(
        "C15a",
        "reconcile() holds",
        reconciliation.holds,
        format!(
            "reserve={} expected={}",
            reconciliation.reserveBalance, reconciliation.expectedBalance
        ),
    );
    checks.eq(
        "C15b",
        "reconcile()'s reserve balance is the ledger's own number",
        u64::try_from(reconciliation.reserveBalance.0.clone()).unwrap(),
        live_reserve,
    );

    let settlement: Settlement = call_update(
        &pocket_ic,
        redemption,
        Principal::anonymous(),
        "settlement",
        &(),
    )
    .await
    .expect("settlement() was rejected");
    eprintln!("       {settlement:?}");
    checks.check("C16a", "settlement() reports settled", settlement.settled, settlement.reason.clone());
    checks.eq(
        "C16b",
        "settlement() writes off exactly the one dust entry",
        u64::try_from(settlement.writtenOff.0.clone()).unwrap(),
        1u64,
    );

    let stats: Stats = call_query(&pocket_ic, redemption, "stats").await;
    eprintln!("       {stats:?}");

    // -----------------------------------------------------------------------
    // Step 6. The ledger properties the canister's retry safety rests on,
    // exercised directly on the real Rust ICRC-1 ledger.
    //
    // These are ledger-level property checks, not canister-level ones: PocketIC
    // cannot drop a reply, so the case of a transfer that lands with its reply
    // lost cannot be induced end-to-end. What it does establish is that the
    // deployed ledger behaves as the canister assumes when it fixes
    // `created_at_time` on the first attempt and reuses it on every retry.
    // -----------------------------------------------------------------------

    eprintln!("\n-- L1/L2: ICRC-1 deduplication on the real ledger --");
    let replay_target = PrincipalId::new_user_test_id(9_300);
    let now_nanos = pocket_ic.get_time().await.as_nanos_since_unix_epoch();
    let replay = TransferArg {
        from_subaccount: None,
        to: IcrcAccount {
            owner: Principal::from(replay_target),
            subaccount: None,
        },
        amount: Nat::from(1_000_000u64),
        fee: Some(Nat::from(FEE_E8S)),
        memo: Some(vec![7, 0, 0, 0, 0, 0, 0, 0].into()),
        created_at_time: Some(now_nanos),
    };

    let first = sns_transfer(&pocket_ic, ledger, Principal::from(funder), &replay)
        .await
        .expect("first replay transfer was rejected");
    let second = sns_transfer(&pocket_ic, ledger, Principal::from(funder), &replay)
        .await
        .expect("second replay transfer was rejected");
    checks.check(
        "L1a",
        "the first transfer is accepted",
        first.is_ok(),
        format!("{first:?}"),
    );
    checks.check(
        "L1b",
        "a byte-identical replay returns Duplicate, not a second payment",
        matches!(&second, Err(TransferError::Duplicate { .. })),
        format!("{second:?}"),
    );
    let replay_balance = sns_balance(
        &pocket_ic,
        ledger,
        IcrcAccount {
            owner: Principal::from(replay_target),
            subaccount: None,
        },
    )
    .await;
    checks.eq(
        "L1c",
        "the replay target was credited exactly once",
        replay_balance,
        1_000_000u64,
    );

    // Push past the ledger's transaction window and confirm the canister's #TooOld arm is
    // reachable rather than theoretical.
    pocket_ic.advance_time(Duration::from_secs(2 * ONE_DAY)).await;
    for _ in 0..5 {
        pocket_ic.tick().await;
    }
    let stale = TransferArg {
        amount: Nat::from(2_000_000u64),
        memo: Some(vec![8, 0, 0, 0, 0, 0, 0, 0].into()),
        ..replay.clone()
    };
    let stale_result = sns_transfer(&pocket_ic, ledger, Principal::from(funder), &stale)
        .await
        .expect("stale transfer was rejected");
    checks.check(
        "L2",
        "a created_at_time outside the window returns TooOld",
        matches!(&stale_result, Err(TransferError::TooOld)),
        format!("{stale_result:?}"),
    );

    // -----------------------------------------------------------------------
    // Verdict.
    // -----------------------------------------------------------------------

    let failures = checks.failures();
    eprintln!(
        "\n=== {} checks, {} failures ===",
        checks.rows.len(),
        failures.len()
    );

    if let Ok(report_path) = std::env::var("MENESE_REPORT_JSON") {
        let rows: Vec<String> = checks
            .rows
            .iter()
            .map(|(name, passed, detail)| {
                format!(
                    "    {{ \"check\": {}, \"passed\": {}, \"detail\": {} }}",
                    json_string(name),
                    passed,
                    json_string(detail)
                )
            })
            .collect();
        let report = format!(
            "{{\n  \"module\": {},\n  \"governance\": \"{}\",\n  \"ledger\": \"{}\",\n  \
             \"redemption\": \"{}\",\n  \"checks\": [\n{}\n  ]\n}}\n",
            json_string(&redemption_wasm_path.display().to_string()),
            governance,
            ledger,
            redemption,
            rows.join(",\n")
        );
        std::fs::write(&report_path, report).unwrap();
        eprintln!("report written to {report_path}");
    }

    assert!(
        failures.is_empty(),
        "{} check(s) failed against the real SNS:\n{}",
        failures.len(),
        failures
            .iter()
            .map(|(name, _, detail)| format!("  {name}: {detail}"))
            .collect::<Vec<_>>()
            .join("\n")
    );
}
