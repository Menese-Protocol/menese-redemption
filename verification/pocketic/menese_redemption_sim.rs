//! The MPV holder canister against the real SNS, on PocketIC.
//!
//! The NNS and SNS modules are the ones live on mainnet. The MENES ledger is the module live
//! at drgmr (DFINITY ic-icrc1-ledger), at drgmr's id, and its history is rebuilt by replaying
//! every block of a walk of the live ledger with the original caller, accounts, amount, fee,
//! created_at_time and time. The MENES sale canister is a mock at d7ebz that returns the
//! stake records as read from the live one. The holder canister is installed at its own id
//! before the SNS exists and is listed in the SNS's sns_init.yaml as a dapp canister with
//! its nine genesis neurons. Then, with no DAO proposal at any point:
//!
//!   G  genesis: the nine neurons exist, controlled by the holder canister, with the stakes
//!      and delays of sns_init.yaml; the canister stays unbound during the swap.
//!   L  the replayed ledger: every block at its original index; supply as the walk says.
//!   S  the swap commits; the canister binds itself to the SNS and takes the snapshot; the
//!      table hash equals the off-chain builder's for the same cut; every row equals it.
//!   D  every basket owner nominates; delivery runs (with upgrades by SNS root between
//!      steps) until every basket is delivered and every genesis neuron is handed over.
//!   N  every neuron read back from SNS governance: rung, owner, stake, delay, permissions;
//!      the holder canister holds none; no holder, destination or dropped holder holds any
//!      liquid MPV on the MPV ledger.
//!   B  the books to the e8s; settlement; and the count of SNS proposals: zero.
//!
//! Two worlds are run when given: the replayed live ledger, and a synthetic table of 2,000
//! holders whose ledger starts with their holdings as initial balances.
//!
//! Environment:
//!   MENESE_SNS_INIT_YAML      sns_init.yaml with the holder canister and its genesis neurons
//!   MENESE_HOLDER_CANISTER    the holder canister's id, as sns_init.yaml lists it
//!   MPV_HOLDER_WASM           build/redemption.wasm
//!   MPV_HOLDER_MOCKS_DIR      build/test (MockSale, Proxy)
//!   MENES_LEDGER_WASM         the MENES ledger module (gzipped)
//!   MENESE_WORLD              lines from verification/real_world.py replay (optional)
//!   MENESE_SYNTHETIC_WORLD    lines from verification/real_world.py synthetic (optional)
//!   MPV_REPORT_JSON           where to write the per-check report (optional)

use candid::types::value::{IDLArgs, IDLValue};
use candid::{CandidType, Deserialize, Encode, Int, Nat, Principal, idl_hash};
use ic_base_types::PrincipalId;
use ic_crypto_sha2::Sha256;
use ic_ledger_core::Tokens;
use ic_nervous_system_agent::{helpers::sns as sns_agent_helpers, pocketic_impl::PocketIcAgent};
use ic_nervous_system_common_test_utils::wasm_helpers::SMALLEST_VALID_WASM_BYTES;
use ic_nervous_system_integration_tests::pocket_ic_helpers::{NnsInstaller, add_wasms_to_sns_wasm, nns, sns};
use ic_nns_constants::ROOT_CANISTER_ID;
use ic_nns_governance_api::CreateServiceNervousSystem;
use ic_sns_governance_api::pb::v1 as sns_pb;
use ic_sns_swap::pb::v1::Lifecycle;
use icp_ledger::{AccountIdentifier, DEFAULT_TRANSFER_FEE};
use pocket_ic::{PocketIcBuilder, Time, nonblocking::PocketIc};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::Duration;

const DAY: u64 = 86_400;
const NEURONS: usize = 9;
const POOL: u128 = 1_500_000_000_000_000;
const MENES_LEDGER: &str = "drgmr-ayaaa-aaaab-aereq-cai";
const MENES_SALE: &str = "d7ebz-3iaaa-aaaab-aerfq-cai";
const MENES_MINTING: &str = "ftmr2-maaaa-aaaab-aersa-cai";
const FIRST_PARTICIPANT: u64 = 1_000;

// ── Candid helpers (generic decoding, so no SNS rule is restated here) ───────────────

fn encode_text(text: &str) -> Vec<u8> {
    candid_parser::parse_idl_args(text).unwrap_or_else(|err| panic!("bad candid text {}: {err}", &text[..text.len().min(300)])).to_bytes().unwrap()
}
fn decode(bytes: &[u8]) -> IDLValue {
    IDLArgs::from_bytes(bytes).unwrap().args.into_iter().next().unwrap_or(IDLValue::Null)
}
fn field<'a>(value: &'a IDLValue, name: &str) -> &'a IDLValue {
    let IDLValue::Record(fields) = value else { panic!("not a record (looking for {name}): {value}") };
    let hash = idl_hash(name);
    &fields.iter().find(|f| f.id.get_id() == hash).unwrap_or_else(|| panic!("no field {name} in {value}")).val
}
fn has_field(value: &IDLValue, name: &str) -> bool {
    matches!(value, IDLValue::Record(fields) if fields.iter().any(|f| f.id.get_id() == idl_hash(name)))
}
fn variant_name(value: &IDLValue, names: &[&str]) -> String {
    let IDLValue::Variant(v) = value else { panic!("not a variant: {value}") };
    names.iter().find(|n| idl_hash(n) == v.0.id.get_id()).map(|n| n.to_string()).unwrap_or_else(|| format!("{value}"))
}
fn variant_payload(value: &IDLValue) -> &IDLValue {
    let IDLValue::Variant(v) = value else { panic!("not a variant: {value}") };
    &v.0.val
}
fn to_u128(value: &IDLValue) -> u128 {
    match value {
        IDLValue::Nat(n) => n.0.to_string().parse::<u128>().unwrap(),
        IDLValue::Int(i) => i.0.to_string().parse::<u128>().unwrap(),
        IDLValue::Nat64(n) => *n as u128,
        IDLValue::Nat32(n) => *n as u128,
        IDLValue::Nat8(n) => *n as u128,
        IDLValue::Int32(n) => *n as u128,
        IDLValue::Number(s) => s.parse::<u128>().unwrap(),
        other => panic!("not a number: {other}"),
    }
}
fn to_opt(value: &IDLValue) -> Option<&IDLValue> {
    match value {
        IDLValue::Opt(inner) => Some(inner),
        IDLValue::None | IDLValue::Null => None,
        other => Some(other),
    }
}
fn to_vec(value: &IDLValue) -> Vec<IDLValue> {
    match value {
        IDLValue::Vec(items) => items.clone(),
        IDLValue::Blob(b) => b.iter().map(|x| IDLValue::Nat8(*x)).collect(),
        other => panic!("not a vec: {other}"),
    }
}
fn to_bytes(value: &IDLValue) -> Vec<u8> {
    match value {
        IDLValue::Blob(b) => b.clone(),
        IDLValue::Vec(items) => items.iter().map(|x| to_u128(x) as u8).collect(),
        other => panic!("not a blob: {other}"),
    }
}
fn to_text(value: &IDLValue) -> String {
    match value {
        IDLValue::Text(t) => t.clone(),
        other => format!("{other}"),
    }
}
fn to_principal(value: &IDLValue) -> Principal {
    match value {
        IDLValue::Principal(p) => *p,
        other => panic!("not a principal: {other}"),
    }
}
fn account_text(owner: Principal) -> String {
    format!("record {{ owner = principal \"{owner}\"; subaccount = null }}")
}
fn opt_nat(v: &Option<u128>, ty: &str) -> String {
    match v {
        Some(x) => format!("opt ({x} : {ty})"),
        None => "null".into(),
    }
}

/// sha256(0x0c || "neuron-stake" || controller || nonce, big-endian): SNS governance's
/// neuron id, derived here from the IC source rather than from the canister's copy.
fn staking_subaccount(controller: Principal, nonce: u64) -> Vec<u8> {
    let mut h = Sha256::new();
    h.write(&[12u8]);
    h.write(b"neuron-stake");
    h.write(controller.as_slice());
    h.write(&nonce.to_be_bytes());
    h.finish().to_vec()
}

// ── The world ────────────────────────────────────────────────────────────────────────

#[derive(CandidType, Deserialize, Clone)]
enum LockPeriod {
    Months2,
    Months4,
    Months12,
    Months18,
}
#[derive(CandidType, Deserialize, Clone)]
struct StakeInfo {
    id: Nat,
    owner: Principal,
    amount: Nat,
    active: bool,
    #[serde(rename = "stakedAt")]
    staked_at: Int,
    #[serde(rename = "lockUntil")]
    lock_until: Int,
    #[serde(rename = "lockPeriod")]
    lock_period: LockPeriod,
    #[serde(rename = "pendingRewards")]
    pending_rewards: Nat,
    #[serde(rename = "weightedAmount")]
    weighted_amount: Nat,
}

#[derive(Clone)]
struct Block {
    kind: String,
    from: Principal,
    to: Principal,
    spender: Option<Principal>,
    amount: u128,
    fee: Option<u128>,
    created_at_time: Option<u128>,
    ts: u64,
}

#[derive(Clone)]
struct Row {
    owner: Principal,
    held: u128,
    staked: u128,
    gross: u128,
    /// The genesis neuron of the first part: 0 for a basket of nine, 1 otherwise.
    first: usize,
    neurons: Vec<u128>,
}

struct World {
    name: String,
    hash: String,
    initial: Vec<(Principal, u128, u64)>,
    blocks: Vec<Block>,
    stakes: Vec<StakeInfo>,
    rows: Vec<Row>,
    /// Holders below one minimum neuron, as the builder published them: (owner, held, staked).
    dropped: Vec<(Principal, u128, u128)>,
}

fn parse_world(name: &str, text: &str) -> World {
    let p = |s: &str| Principal::from_text(s).unwrap_or_else(|e| panic!("bad principal {s}: {e}"));
    let n = |s: &str| s.parse::<u128>().unwrap_or_else(|e| panic!("bad number {s}: {e}"));
    let o = |s: &str| if s == "-" { None } else { Some(s.parse::<u128>().unwrap()) };
    let mut w = World { name: name.into(), hash: String::new(), initial: vec![], blocks: vec![], stakes: vec![], rows: vec![], dropped: vec![] };
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        match f.first().copied() {
            Some("M") if f[1] == "hash" => w.hash = f[2].to_string(),
            Some("I") => w.initial.push((p(f[1]), n(f[2]), f[3].parse().unwrap())),
            Some("L") => w.blocks.push(Block {
                kind: f[1].to_string(),
                from: p(f[2]),
                to: p(f[3]),
                spender: if f[4] == "-" { None } else { Some(p(f[4])) },
                amount: n(f[5]),
                fee: o(f[6]),
                created_at_time: o(f[7]),
                ts: f[8].parse().unwrap(),
            }),
            Some("S") => w.stakes.push(StakeInfo {
                id: Nat::from(n(f[1])),
                owner: p(f[2]),
                amount: Nat::from(n(f[3])),
                active: f[4] == "1",
                staked_at: Int::from(f[5].parse::<i128>().unwrap()),
                lock_until: Int::from(f[6].parse::<i128>().unwrap()),
                lock_period: match f[7] {
                    "Months2" => LockPeriod::Months2,
                    "Months4" => LockPeriod::Months4,
                    "Months12" => LockPeriod::Months12,
                    _ => LockPeriod::Months18,
                },
                pending_rewards: Nat::from(n(f[8])),
                weighted_amount: Nat::from(n(f[9])),
            }),
            Some("R") => w.rows.push(Row {
                owner: p(f[1]),
                held: n(f[2]),
                staked: n(f[3]),
                gross: n(f[4]),
                first: f[5].parse().unwrap(),
                neurons: f[6].split(',').map(n).collect(),
            }),
            Some("D") => w.dropped.push((p(f[1]), n(f[2]), n(f[3]))),
            _ => {}
        }
    }
    assert!(!w.hash.is_empty(), "the world gives no expected table hash");
    w
}

// ── Checks ───────────────────────────────────────────────────────────────────────────

struct Checks {
    results: Vec<(String, bool, String)>,
}
impl Checks {
    fn check(&mut self, id: &str, name: &str, passed: bool, detail: impl Into<String>) {
        let detail = detail.into();
        eprintln!("  {} {id:<6} {name}  {detail}", if passed { "ok  " } else { "FAIL" });
        self.results.push((format!("{id} {name}"), passed, detail));
        if let Ok(path) = std::env::var("MPV_REPORT_JSON") {
            let rows = self.results.iter().map(|(n, p, d)| format!("{{\"check\":{n:?},\"passed\":{p},\"detail\":{d:?}}}")).collect::<Vec<_>>().join(",\n");
            std::fs::write(path, format!("[\n{rows}\n]\n")).unwrap();
        }
    }
    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, id: &str, name: &str, got: T, want: T) {
        let passed = got == want;
        self.check(id, name, passed, format!("got {got:?}, want {want:?}"));
    }
}

fn read(path: &str) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|e| panic!("could not read {path}: {e}"))
}
fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

fn destination_of(owner: Principal) -> Principal {
    let mut raw = owner.as_slice().to_vec();
    raw.reverse();
    raw.truncate(28);
    raw.push(0x02);
    Principal::from_slice(&raw)
}

struct Sim {
    pic: PocketIc,
    holder: Principal,
    governance: Principal,
    mpv_ledger: Principal,
    root: Principal,
    proxy: Principal,
    holder_wasm: Vec<u8>,
}

impl Sim {
    async fn finish(self) {
        self.pic.drop().await;
    }
    async fn query(&self, canister: Principal, method: &str, arg: Vec<u8>) -> IDLValue {
        decode(&self.pic.query_call(canister, Principal::anonymous(), method, arg).await.unwrap_or_else(|e| panic!("{method}: {e:?}")))
    }
    async fn via_proxy(&self, method: &str, arg: Vec<u8>) -> Result<IDLValue, String> {
        let a = Encode!(&self.holder, &method.to_string(), &arg).unwrap();
        match self.pic.update_call(self.proxy, Principal::anonymous(), "call", a).await {
            Ok(b) => Ok(decode(&to_bytes(&decode(&b)))),
            Err(e) => Err(format!("{e:?}")),
        }
    }
    async fn status(&self) -> (String, String, Vec<String>) {
        let s = self.query(self.holder, "status", Encode!().unwrap()).await;
        let phase = field(&s, "phase");
        let mut name = variant_name(phase, &["Unbound", "AwaitClose", "Snapshot", "Delivering", "Aborted", "Halted"]);
        if name == "Halted" {
            name = format!("Halted: {}", to_text(variant_payload(phase)));
        }
        (name, to_text(field(&s, "note")), to_vec(field(&s, "snapshotChecks")).iter().map(to_text).collect())
    }
    async fn run(&self, rounds: usize) {
        for _ in 0..rounds {
            self.pic.advance_time(Duration::from_secs(16)).await;
            for _ in 0..6 {
                self.pic.tick().await;
            }
        }
    }
    async fn stats(&self) -> IDLValue {
        self.query(self.holder, "stats", Encode!().unwrap()).await
    }
    async fn upgrade(&self) -> Result<(), String> {
        self.pic.stop_canister(self.holder, Some(self.root)).await.map_err(|e| format!("stop: {e:?}"))?;
        let r = self.pic.upgrade_eop_canister(self.holder, self.holder_wasm.clone(), Encode!().unwrap(), Some(self.root)).await;
        self.pic.start_canister(self.holder, Some(self.root)).await.map_err(|e| format!("start: {e:?}"))?;
        r.map_err(|e| format!("upgrade: {e:?}"))
    }
    async fn mpv_balance(&self, owner: Principal) -> u128 {
        to_u128(&self.query(self.mpv_ledger, "icrc1_balance_of", encode_text(&format!("({})", account_text(owner)))).await)
    }
    async fn all_neurons(&self) -> BTreeMap<Vec<u8>, IDLValue> {
        let mut out = BTreeMap::new();
        let mut start: Option<sns_pb::NeuronId> = None;
        loop {
            let arg = Encode!(&sns_pb::ListNeurons { limit: 100, start_page_at: start.clone(), of_principal: None }).unwrap();
            let page = to_vec(field(&self.query(self.governance, "list_neurons", arg).await, "neurons"));
            let len = page.len();
            for n in page {
                let id = to_bytes(field(to_opt(field(&n, "id")).unwrap(), "id"));
                start = Some(sns_pb::NeuronId { id: id.clone() });
                out.insert(id, n);
            }
            if len < 100 {
                return out;
            }
        }
    }
    async fn proposals(&self) -> usize {
        let arg = Encode!(&sns_pb::ListProposals { limit: 100, ..Default::default() }).unwrap();
        to_vec(field(&self.query(self.governance, "list_proposals", arg).await, "proposals")).len()
    }
}

fn permissions_of(neuron: &IDLValue, who: Principal) -> BTreeSet<i32> {
    let mut out = BTreeSet::new();
    for p in to_vec(field(neuron, "permissions")) {
        if let Some(pr) = to_opt(field(&p, "principal")) {
            if to_principal(pr) == who {
                for x in to_vec(field(&p, "permission_type")) {
                    out.insert(to_u128(&x) as i32);
                }
            }
        }
    }
    out
}
fn delay_of(neuron: &IDLValue) -> u64 {
    match to_opt(field(neuron, "dissolve_state")) {
        Some(v) => to_u128(variant_payload(v)) as u64,
        None => u64::MAX,
    }
}

// ── One world, end to end ────────────────────────────────────────────────────────────

async fn run_world(w: &World, checks: &mut Checks) {
    let tag = |id: &str| format!("{}{id}", &w.name[..1].to_uppercase());
    eprintln!("=== world {}: {} initial balances, {} blocks, {} stakes, {} holders; expected hash {}", w.name, w.initial.len(), w.blocks.len(), w.stakes.len(), w.rows.len(), w.hash);
    let yaml = PathBuf::from(env("MENESE_SNS_INIT_YAML"));
    let holder_id = Principal::from_text(env("MENESE_HOLDER_CANISTER")).unwrap();
    let holder_wasm = read(&env("MPV_HOLDER_WASM"));
    let mocks = PathBuf::from(env("MPV_HOLDER_MOCKS_DIR"));
    let start = w.initial.iter().map(|x| x.2).filter(|t| *t > 0).min();
    let mut builder = PocketIcBuilder::new().with_nns_subnet().with_sns_subnet().with_application_subnet();
    if let Some(t) = start {
        builder = builder.with_initial_time(Time::from_nanos_since_unix_epoch(t));
    }
    let pic = builder.build_async().await;
    let admin = Principal::from_slice(&[0x10, 0x77, 0x01]);

    // ── L: the MENES ledger at its own id, its history replayed ───────────────────────
    let menes = pic.create_canister_with_id(Some(admin), None, Principal::from_text(MENES_LEDGER).unwrap()).await.unwrap();
    pic.add_cycles(menes, 1_000_000_000_000_000).await;
    let balances = w.initial.iter().map(|(o, a, _)| format!("record {{ {}; {a} : nat }}", account_text(*o))).collect::<Vec<_>>().join("; ");
    let init = format!(
        "(variant {{ Init = record {{ token_symbol = \"MENES\"; token_name = \"MENES\"; \
         minting_account = {}; transfer_fee = 10_000 : nat; metadata = vec {{}}; \
         initial_balances = vec {{ {balances} }}; \
         archive_options = record {{ num_blocks_to_archive = 1_000 : nat64; trigger_threshold = 2_000 : nat64; \
           controller_id = principal \"{admin}\"; cycles_for_archive_creation = opt (10_000_000_000_000 : nat64) }}; \
         feature_flags = opt record {{ icrc2 = true }} }} }})",
        account_text(Principal::from_text(MENES_MINTING).unwrap())
    );
    pic.install_canister(menes, read(&env("MENES_LEDGER_WASM")), encode_text(&init), Some(admin)).await;
    let mut index = w.initial.len() as u128;
    let (mut mismatched, mut clamped) = (Vec::new(), 0usize);
    for b in &w.blocks {
        let now = pic.get_time().await.as_nanos_since_unix_epoch();
        if b.ts >= now {
            pic.set_time(Time::from_nanos_since_unix_epoch(b.ts)).await;
        } else {
            clamped += 1;
        }
        let fee = opt_nat(&b.fee, "nat");
        let cat = opt_nat(&b.created_at_time, "nat64");
        let (caller, method, arg) = match b.kind.as_str() {
            "transfer" => (b.from, "icrc1_transfer", format!("(record {{ to = {}; amount = {} : nat; fee = {fee}; memo = null; from_subaccount = null; created_at_time = {cat} }})", account_text(b.to), b.amount)),
            "approve" => (b.from, "icrc2_approve", format!("(record {{ spender = {}; amount = {} : nat; fee = {fee}; memo = null; from_subaccount = null; created_at_time = {cat}; expected_allowance = null; expires_at = null }})", account_text(b.to), b.amount)),
            _ => (b.spender.unwrap(), "icrc2_transfer_from", format!("(record {{ spender_subaccount = null; from = {}; to = {}; amount = {} : nat; fee = {fee}; memo = null; created_at_time = {cat} }})", account_text(b.from), account_text(b.to), b.amount)),
        };
        let reply = pic.update_call(menes, caller, method, encode_text(&arg)).await.map(|b| decode(&b));
        let got = match &reply {
            Ok(v) if variant_name(v, &["Ok", "Err"]) == "Ok" => Some(to_u128(variant_payload(v))),
            _ => None,
        };
        if got != Some(index) && mismatched.len() < 5 {
            mismatched.push(format!("block {index}: {:?}", reply.map(|v| format!("{v}"))));
        }
        index += 1;
    }
    let length = to_u128(field(&decode(&pic.query_call(menes, admin, "get_transactions", encode_text("(record { start = 0 : nat; length = 0 : nat })")).await.unwrap()), "log_length"));
    checks.check(&tag("L1"), "every block of the walk replayed at its original index on the real ledger module", mismatched.is_empty() && length == index,
        format!("{length} blocks; {} replayed at a later time than the original (same-time blocks); first mismatches {mismatched:?}", clamped));
    let supply = to_u128(&decode(&pic.query_call(menes, admin, "icrc1_total_supply", Encode!().unwrap()).await.unwrap()));
    let want_supply: u128 = w.initial.iter().map(|x| x.1).sum::<u128>() - w.blocks.iter().map(|b| b.fee.unwrap_or(10_000)).sum::<u128>();
    checks.eq(&tag("L2"), "supply after the replay = initial balances less every fee", supply, want_supply);

    // The sale canister: its stake records as read from the live one.
    let sale = pic.create_canister_with_id(Some(admin), None, Principal::from_text(MENES_SALE).unwrap()).await.unwrap();
    pic.add_cycles(sale, 100_000_000_000_000).await;
    pic.install_canister(sale, read(mocks.join("MockSale.wasm").to_str().unwrap()), Encode!().unwrap(), Some(admin)).await;
    for chunk in w.stakes.chunks(500) {
        pic.update_call(sale, admin, "load", Encode!(&chunk.to_vec()).unwrap()).await.unwrap();
    }

    // ── The NNS and the SNS, from sns_init.yaml ──────────────────────────────────────
    let mut csns: CreateServiceNervousSystem = ic_sns_cli::read_create_service_nervous_system_from_init_yaml(&yaml).expect("sns_init.yaml");
    let swap = csns.swap_parameters.clone().unwrap();
    let min_participants = swap.minimum_participants.unwrap();
    let min_each = swap.minimum_participant_icp.unwrap().e8s.unwrap();
    let max_each = swap.maximum_participant_icp.unwrap().e8s.unwrap();
    let raise = swap.minimum_direct_participation_icp.unwrap().e8s.unwrap().max(min_participants * min_each);
    let count = min_participants.max(raise.div_ceil(max_each));
    let participants: Vec<(PrincipalId, u64)> = (0..count).map(|i| (PrincipalId::new_user_test_id(FIRST_PARTICIPANT + i), raise / count + if i == 0 { raise % count } else { 0 })).collect();
    let mut nns_installer = NnsInstaller::default();
    nns_installer.with_mainnet_nns_canister_versions();
    nns_installer.with_cycles_minting_canister();
    nns_installer.with_ledger_balances(participants.iter().map(|(p, a)| (AccountIdentifier::new(*p, None), Tokens::from_e8s(a + DEFAULT_TRANSFER_FEE.get_e8s()))).collect());
    nns_installer.install(&pic).await;
    add_wasms_to_sns_wasm(&pic, true).await.unwrap();
    let settings = ic_management_canister_types::CanisterSettings { controllers: Some(vec![ROOT_CANISTER_ID.get().0]), ..Default::default() };
    let app = pic.topology().await.get_app_subnets()[0];
    let mut dapps = Vec::new();
    let mut holder = None;
    for c in csns.dapp_canisters.clone() {
        let want = Principal::from(c.id.unwrap());
        let id = match pic.create_canister_with_id(Some(ROOT_CANISTER_ID.get().0), Some(settings.clone()), want).await {
            Ok(id) => id,
            Err(_) => pic.create_canister_on_subnet(Some(ROOT_CANISTER_ID.get().0), Some(settings.clone()), app).await,
        };
        pic.add_cycles(id, 1_000_000_000_000_000).await;
        if want == holder_id {
            // The holder canister runs its final module before the SNS exists.
            pic.install_canister(id, holder_wasm.clone(), Encode!().unwrap(), Some(ROOT_CANISTER_ID.get().0)).await;
            holder = Some(id);
        } else {
            pic.install_canister(id, SMALLEST_VALID_WASM_BYTES.to_vec(), vec![], Some(ROOT_CANISTER_ID.get().0)).await;
        }
        dapps.push(PrincipalId::from(id));
    }
    let holder = holder.expect("sns_init.yaml does not list MENESE_HOLDER_CANISTER");
    checks.eq(&tag("G0"), "the holder canister sits at its own id", holder, holder_id);
    csns.dapp_canisters = dapps.iter().map(|id| ic_nervous_system_proto::pb::v1::Canister { id: Some(*id) }).collect();
    let (sns, _) = nns::governance::propose_to_deploy_sns_and_wait(&pic, csns.clone(), "mpv").await;
    let governance = Principal::from(sns.governance.canister_id);
    let root = Principal::from(sns.root.canister_id);
    let mpv_ledger = Principal::from(sns.ledger.canister_id);
    let proxy = pic.create_canister_on_subnet(Some(admin), None, app).await;
    pic.add_cycles(proxy, 100_000_000_000_000).await;
    pic.install_canister(proxy, read(mocks.join("Proxy.wasm").to_str().unwrap()), Encode!().unwrap(), Some(admin)).await;
    let sim = Sim { pic, holder, governance, mpv_ledger, root, proxy, holder_wasm: holder_wasm.clone() };

    // ── G: genesis ───────────────────────────────────────────────────────────────────
    let neurons = sim.all_neurons().await;
    let mut genesis = Vec::new();
    for k in 0..NEURONS {
        let n = neurons.get(&staking_subaccount(holder, k as u64));
        genesis.push(n.map(|n| (to_u128(field(n, "cached_neuron_stake_e8s")), delay_of(n) / DAY, permissions_of(n, holder).len())));
    }
    let want: Vec<Option<(u128, u64, usize)>> = (0..NEURONS).map(|k| Some((if k == 8 { 166_667_200_000_000 } else { 166_666_600_000_000 }, 182 * k as u64, 0))).collect();
    let genesis_ok = genesis.iter().zip(want.iter()).all(|(g, w)| matches!((g, w), (Some((s, d, p)), Some((ws, wd, _))) if s == ws && d == wd && *p > 0));
    checks.check(&tag("G1"), "nine genesis neurons controlled by the holder canister: stakes and delays as in sns_init.yaml", genesis_ok, format!("{genesis:?}"));
    sim.run(5).await;
    checks.eq(&tag("G2"), "unbound while the swap runs (NNS root still a controller)", sim.status().await.0, "Unbound".to_string());

    // ── S: the swap commits; the canister binds and takes the snapshot ─────────────────
    sns::swap::await_swap_lifecycle(&sim.pic, sns.swap.canister_id, Lifecycle::Open).await.unwrap();
    for (p, a) in &participants {
        let agent = PocketIcAgent::new(&sim.pic, *p);
        sns_agent_helpers::participate_in_swap(&agent, ic_nervous_system_agent::sns::swap::SwapCanister::new(sns.swap.canister_id), Tokens::from_e8s(*a), swap.confirmation_text.clone()).await.unwrap();
    }
    let due = sns::swap::get_init(&sim.pic, sns.swap.canister_id).await.init.unwrap().swap_due_timestamp_seconds.unwrap();
    let now = sim.pic.get_time().await.as_nanos_since_unix_epoch() / 1_000_000_000;
    sim.pic.advance_time(Duration::from_secs((due + DAY).saturating_sub(now))).await;
    for _ in 0..40 {
        sim.pic.tick().await;
    }
    sns::swap::await_swap_finalization_status(&sim.pic, sns.swap.canister_id, sns::swap::SwapFinalizationStatus::Committed).await.unwrap();
    let mut phase = String::new();
    for _ in 0..400 {
        sim.run(1).await;
        phase = sim.status().await.0;
        if phase == "Delivering" || phase.starts_with("Halted") {
            break;
        }
    }
    let b = sim.query(holder, "getBinding", Encode!().unwrap()).await;
    let bound = to_opt(field(&b, "binding")).map(|x| (to_principal(field(x, "root")), to_principal(field(x, "governance")), to_principal(field(x, "ledger"))));
    checks.eq(&tag("S1"), "bound after the swap to this SNS's root, governance and ledger, with no admin", bound, Some((root, governance, mpv_ledger)));
    let (_, _, lines) = sim.status().await;
    checks.check(&tag("S2"), "the snapshot completes", phase == "Delivering", format!("{phase}\n{}", lines.join("\n")));
    let snap = sim.query(holder, "getSnapshot", Encode!().unwrap()).await;
    let hash = to_opt(&snap).map(|r| to_bytes(field(r, "tableHash")).iter().map(|b| format!("{b:02x}")).collect::<String>());
    checks.eq(&tag("S3"), "the on-chain table hash equals the off-chain builder's for the same cut", hash, Some(w.hash.clone()));
    let table = to_vec(&sim.query(holder, "getTable", Encode!().unwrap()).await);
    let mut diffs = 0;
    for (i, e) in table.iter().enumerate() {
        let r = &w.rows[i.min(w.rows.len() - 1)];
        let first = to_u128(field(e, "firstRung")) as usize;
        let ns: Vec<u128> = to_vec(field(e, "neurons")).iter().map(to_u128).collect();
        if (to_principal(field(e, "owner")), to_u128(field(e, "held")), to_u128(field(e, "staked")), to_u128(field(e, "gross")), first, ns) != (r.owner, r.held, r.staked, r.gross, r.first, r.neurons.clone()) {
            diffs += 1;
        }
    }
    checks.check(&tag("S4"), "every row equals the builder's", diffs == 0 && table.len() == w.rows.len(), format!("{} rows, {diffs} differ", table.len()));
    let dropped: Vec<(Principal, u128, u128)> = to_vec(&sim.query(holder, "getDropped", Encode!().unwrap()).await)
        .iter()
        .map(|d| (to_principal(field(d, "owner")), to_u128(field(d, "held")), to_u128(field(d, "staked"))))
        .collect();
    let reported = to_opt(&snap).map(|r| (to_u128(field(r, "dropped")), to_u128(field(r, "fullBaskets")), to_u128(field(r, "smallBaskets")), to_u128(field(r, "neurons"))));
    let full = w.rows.iter().filter(|r| r.first == 0).count() as u128;
    let total_neurons: usize = w.rows.iter().map(|r| r.neurons.len()).sum();
    checks.check(&tag("S5"), "the dropped list equals the builder's; the report counts baskets of nine, smaller baskets, neurons and dropped holders as the builder does",
        dropped == w.dropped && reported == Some((w.dropped.len() as u128, full, w.rows.len() as u128 - full, total_neurons as u128)),
        format!("{} dropped vs {}; report {reported:?}", dropped.len(), w.dropped.len()));
    if phase != "Delivering" {
        sim.finish().await;
        return;
    }

    // ── P: a stranger claims neurons in the holder canister's name ─────────────────────
    // A swap participant disburses its neuron with no dissolve delay, then, on real
    // governance, claims a neuron for the holder canister at every id the canister's earlier
    // public memo rule ((entry + 1) x 65,536 + k) gave the first parts. Anyone can do this:
    // ClaimOrRefresh by MemoAndController takes any controller. The canister's split memos
    // are secret now, so these ids are never a basket's.
    let stranger = participants[0].0;
    let stranger_p = Principal::from(stranger);
    let arg = Encode!(&sns_pb::ListNeurons { limit: 100, start_page_at: None, of_principal: Some(stranger) }).unwrap();
    let mine = to_vec(field(&sim.query(governance, "list_neurons", arg).await, "neurons"));
    let liquid_neuron = mine.iter().find(|n| delay_of(n) == 0).map(|n| to_bytes(field(to_opt(field(n, "id")).unwrap(), "id")));
    let mut disbursed = false;
    if let Some(sub) = liquid_neuron {
        let cmd = sns_pb::ManageNeuron { subaccount: sub, command: Some(sns_pb::manage_neuron::Command::Disburse(sns_pb::manage_neuron::Disburse { amount: None, to_account: None })) };
        if let Ok(b) = sim.pic.update_call(governance, stranger_p, "manage_neuron", Encode!(&cmd).unwrap()).await {
            disbursed = to_opt(field(&decode(&b), "command")).is_some_and(|c| variant_name(c, &["Disburse", "Error"]) == "Disburse");
        }
    }
    let min_stake = sns::governance::get_nervous_system_parameters(&sim.pic, sns.governance.canister_id).await.neuron_minimum_stake_e8s.unwrap() as u128;
    let mut planted: BTreeMap<Vec<u8>, u64> = BTreeMap::new();
    for (i, r) in w.rows.iter().enumerate().take(3) {
        for j in 0..r.neurons.len() {
            let memo = (i as u64 + 1) * 65_536 + (r.first + j) as u64;
            let sub = staking_subaccount(holder, memo);
            let blob = sub.iter().map(|b| format!("\\{b:02x}")).collect::<String>();
            let t = format!("(record {{ to = record {{ owner = principal \"{governance}\"; subaccount = opt blob \"{blob}\" }}; amount = {min_stake} : nat; fee = null; memo = null; from_subaccount = null; created_at_time = null }})");
            let sent = sim.pic.update_call(mpv_ledger, stranger_p, "icrc1_transfer", encode_text(&t)).await.map(|b| variant_name(&decode(&b), &["Ok", "Err"]) == "Ok");
            if sent != Ok(true) {
                continue;
            }
            let by = sns_pb::manage_neuron::claim_or_refresh::By::MemoAndController(sns_pb::manage_neuron::claim_or_refresh::MemoAndController { memo, controller: Some(PrincipalId::from(holder)) });
            let cmd = sns_pb::ManageNeuron { subaccount: sub.clone(), command: Some(sns_pb::manage_neuron::Command::ClaimOrRefresh(sns_pb::manage_neuron::ClaimOrRefresh { by: Some(by) })) };
            if let Ok(b) = sim.pic.update_call(governance, stranger_p, "manage_neuron", Encode!(&cmd).unwrap()).await {
                if to_opt(field(&decode(&b), "command")).is_some_and(|c| variant_name(c, &["ClaimOrRefresh", "Error"]) == "ClaimOrRefresh") {
                    planted.insert(sub, memo);
                }
            }
        }
    }
    let parts_first3: usize = w.rows.iter().take(3).map(|r| r.neurons.len()).sum();
    let neurons_now = sim.all_neurons().await;
    let claimed_for_holder = planted.keys().filter(|id| neurons_now.get(*id).is_some_and(|n| !permissions_of(n, holder).is_empty() && delay_of(n) == 0)).count();
    checks.check(&tag("P1"), "on real governance a stranger claims a neuron for the holder canister at each id the old public memo rule gave the first three baskets",
        disbursed && planted.len() == parts_first3 && claimed_for_holder == parts_first3,
        format!("disbursed {disbursed}; claimed {} of {parts_first3}; holder-controlled with no delay {claimed_for_holder}", planted.len()));

    // ── D: delivery ───────────────────────────────────────────────────────────────────
    let mut nominated = 0;
    for r in w.rows.iter() {
        if let Ok(b) = sim.pic.update_call(holder, r.owner, "setNeuronDestination", Encode!(&destination_of(r.owner)).unwrap()).await {
            if variant_name(&decode(&b), &["ok", "err"]) == "ok" {
                nominated += 1;
            }
        }
    }
    checks.eq(&tag("D1"), "every basket owner nominates a destination (canister owners by their own call)", nominated, w.rows.len());
    let driver = w.rows[0].owner;
    let (mut rounds, mut upgrades) = (0usize, 0usize);
    let limit = 400 + 2 * (total_neurons * 3) / 12;
    loop {
        rounds += 1;
        let _ = sim.pic.update_call(holder, driver, "processNext", Encode!().unwrap()).await;
        sim.run(1).await;
        if rounds % 50 == 25 {
            sim.upgrade().await.unwrap();
            upgrades += 1;
        }
        let s = sim.stats().await;
        let terminal = to_u128(field(&s, "done")) == to_u128(field(&s, "entries"));
        if (terminal && to_u128(field(&s, "parentsHandedOver")) == NEURONS as u128) || rounds >= limit {
            break;
        }
    }
    checks.check(&tag("D2"), "every share delivered and every genesis neuron handed over, through upgrades by SNS root", rounds < limit, format!("{rounds} rounds, {upgrades} upgrades"));

    // ── N: every neuron and payment read back ────────────────────────────────────────
    let params = sns::governance::get_nervous_system_parameters(&sim.pic, sns.governance.canister_id).await;
    let grantable: BTreeSet<i32> = params.neuron_grantable_permissions.unwrap().permissions.into_iter().collect();
    let fee = params.transaction_fee_e8s.unwrap() as u128;
    let neurons = sim.all_neurons().await;
    let mut problems = Vec::new();
    let (mut stake_total, mut checked) = (0u128, 0usize);
    for (i, r) in w.rows.iter().enumerate() {
        let dest = destination_of(r.owner);
        let basket = to_vec(&sim.query(holder, "basketOf", Encode!(&Nat::from(i as u64)).unwrap()).await);
        if basket.len() != r.neurons.len() {
            problems.push(format!("{i}: {} neurons, want {}", basket.len(), r.neurons.len()));
        }
        for (j, bn) in basket.iter().enumerate() {
            let k = to_u128(field(bn, "rung")) as usize;
            if k != r.first + j {
                problems.push(format!("{i}/{j}: rung {k}, want {}", r.first + j));
            }
            let (Some(id), Some(memo)) = (to_opt(field(bn, "neuronId")).map(to_bytes), to_opt(field(bn, "memo")).map(|m| to_u128(m) as u64)) else {
                problems.push(format!("{i}/{k}: delivered without an id or a memo"));
                continue;
            };
            let whole = matches!(field(bn, "genesisNeuron"), IDLValue::Bool(true));
            if id != staking_subaccount(holder, memo) {
                problems.push(format!("{i}/{k}: id is not the staking subaccount of (holder, memo)"));
            }
            if (whole && memo != k as u64) || (!whole && (memo < 1 << 63 || memo == (i as u64 + 1) * 65_536 + k as u64)) {
                problems.push(format!("{i}/{k}: memo {memo} is neither genesis memo k nor a secret memo"));
            }
            if planted.contains_key(&id) {
                problems.push(format!("{i}/{k}: delivered the stranger's neuron"));
            }
            let Some(n) = neurons.get(&id) else {
                problems.push(format!("{i}/{k}: no such neuron"));
                continue;
            };
            checked += 1;
            let stake = to_u128(field(n, "cached_neuron_stake_e8s"));
            let want = if whole { r.neurons[j] } else { r.neurons[j] - fee };
            if stake != want {
                problems.push(format!("{i}/{k}: stake {stake} want {want}"));
            }
            stake_total += stake;
            if delay_of(n) != 182 * DAY * k as u64 {
                problems.push(format!("{i}/{k}: delay {}", delay_of(n)));
            }
            if permissions_of(n, dest) != grantable {
                problems.push(format!("{i}/{k}: destination holds {:?}", permissions_of(n, dest)));
            }
            if !permissions_of(n, holder).is_empty() {
                problems.push(format!("{i}/{k}: the holder canister still holds {:?}", permissions_of(n, holder)));
            }
        }
    }
    checks.check(&tag("N1"), "every neuron of every basket: right rung; the nominated owner holds the live grantable permissions, the holder canister none; stake and delay exact",
        problems.is_empty() && checked == total_neurons, format!("{checked} neurons of {total_neurons}; {} problems {:?}", problems.len(), problems.iter().take(5).collect::<Vec<_>>()));
    let mut liquid = Vec::new();
    for who in w.rows.iter().flat_map(|r| [r.owner, destination_of(r.owner)]).chain(w.dropped.iter().flat_map(|d| [d.0, destination_of(d.0)])) {
        let b = sim.mpv_balance(who).await;
        if b != 0 {
            liquid.push(format!("{who}: {b}"));
        }
    }
    checks.check(&tag("N2"), "no holder, destination or dropped holder holds liquid MPV: nothing was paid out liquid", liquid.is_empty(),
        format!("{} accounts read; {} hold MPV {:?}", 2 * (w.rows.len() + w.dropped.len()), liquid.len(), liquid.iter().take(3).collect::<Vec<_>>()));
    let splits = total_neurons - NEURONS;
    let fees = splits as u128 * fee;
    checks.eq(&tag("B1"), "delivered stake + split fees = 15,000,000 MPV", stake_total + fees, POOL);
    let s = sim.stats().await;
    checks.eq(&tag("B2"), "the canister's own count of splits", to_u128(field(&s, "splits")), splits as u128);
    let settlement = sim.via_proxy("settlement", Encode!().unwrap()).await.unwrap();
    checks.check(&tag("B3"), "settlement: settled", matches!(field(&settlement, "settled"), IDLValue::Bool(true)), to_text(field(&settlement, "reason")));
    let held_by_holder = neurons.iter().filter(|(id, n)| !planted.contains_key(*id) && !permissions_of(n, holder).is_empty()).count();
    checks.eq(&tag("B4"), "the holder canister controls no neuron at the end but the stranger's, which it never touched", held_by_holder, 0);
    let untouched = planted.keys().filter(|id| {
        neurons.get(*id).is_some_and(|n| to_u128(field(n, "cached_neuron_stake_e8s")) == min_stake && delay_of(n) == 0 && to_vec(field(n, "permissions")).len() == 1 && !permissions_of(n, holder).is_empty())
    }).count();
    let foreign = to_vec(&sim.query(holder, "getForeign", Encode!().unwrap()).await).len();
    checks.check(&tag("P2"), "every neuron the stranger claimed is untouched (stake, no delay, only the holder canister as claimer), none is a basket's, and the canister met none at a part's id",
        untouched == planted.len() && foreign == 0 && to_u128(field(&s, "foreignNeurons")) == 0,
        format!("{untouched} of {} untouched; foreign reported {foreign}", planted.len()));
    checks.eq(&tag("B5"), "SNS proposals made from genesis to the last delivery", sim.proposals().await, 0);
    let _ = has_field;
    sim.finish().await;
}

#[tokio::test]
async fn menese_redemption_simulation() {
    let mut checks = Checks { results: Vec::new() };
    for (var, name) in [("MENESE_WORLD", "real"), ("MENESE_SYNTHETIC_WORLD", "synthetic")] {
        if let Ok(path) = std::env::var(var) {
            let w = parse_world(name, &std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}")));
            run_world(&w, &mut checks).await;
        }
    }
    let failed: Vec<_> = checks.results.iter().filter(|r| !r.1).map(|r| r.0.clone()).collect();
    eprintln!("{} checks, {} failed {:?}", checks.results.len(), failed.len(), failed);
    assert!(!checks.results.is_empty() && failed.is_empty(), "failed: {failed:?}");
}
