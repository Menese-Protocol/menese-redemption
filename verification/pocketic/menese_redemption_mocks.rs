//! The MPV holder canister against failure-injecting mocks, on PocketIC.
//!
//! The holder canister module is the real build. The MENES ledger and the MENES sale canister
//! are mocks at their mainnet ids (drgmr, d7ebz), because the canister compiles those ids in;
//! one mock at the NNS SNS-W id (qaa6y) plays SNS-W, SNS root, SNS governance, the MPV ledger
//! and the swap, with the canister's nine genesis neurons, and executes Split and the
//! permission commands with governance's own rules (it also answers Disburse, and counts it:
//! the canister must never send one). The MENES world (blocks, stakes) and the
//! table it must produce come from verification/mock_world.py, which computes the table
//! independently of the canister.
//!
//! Groups, each a value comparison:
//!   B  binding after genesis, with no admin; ingress rules (P-2).
//!   H  the happy path: snapshot at the swap's close, table and hash equal to the oracle's,
//!      delivery of every neuron of every basket (nine, or one to eight at rungs 1..n), nothing
//!      to the holders left out, no Disburse, the books to the e8s.
//!   F  fail closed: supply mismatch, a missing block, an unresolvable withdrawal, stakes that
//!      keep changing; an aborted swap does nothing.
//!   R  resume: an error, a reject or a lost reply on every command at every genesis neuron,
//!      ledger and sale rejects during the snapshot, and an upgrade between steps; nothing lost
//!      or paid twice.
//!   Q  books (Q6): a donation is reported as surplus and never spent on purpose; it goes
//!      with its genesis neuron to the last basket there, and a lost Split reply on a neuron
//!      carrying a refreshed donation still splits once.
//!   D  delivery waits for Normal mode and the table's fee and minimum; destination rules;
//!      a holder who never nominates holds up nobody else.
//!   G  split memos are secret: no part has an id before its split; a stranger who claims
//!      neurons for the holder canister at every id the old public rule gave changes nothing;
//!      a neuron already at a part's id when its split arrives is reported, left alone and
//!      never taken as the part, which moves to its next memo; the memos survive an upgrade.
//!
//! Environment: POCKET_IC_BIN, MPV_HOLDER_WASM, MPV_HOLDER_MOCKS_DIR (build/test),
//! MPV_HOLDER_WORLD (mock_world.py output), MPV_REPORT_JSON (optional).

use candid::types::value::{IDLArgs, IDLValue};
use candid::{CandidType, Deserialize, Encode, Int, Nat, Principal, idl_hash};
use ic_crypto_sha2::Sha256;
use pocket_ic::{PocketIcBuilder, Time, nonblocking::PocketIc};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::Duration;

const DAY: u64 = 86_400;
const NEURONS: usize = 9;
const POOL: u128 = 1_500_000_000_000_000;
const SNS_W: &str = "qaa6y-5yaaa-aaaaa-aaafa-cai";
const MENES_LEDGER: &str = "drgmr-ayaaa-aaaab-aereq-cai";
const MENES_SALE: &str = "d7ebz-3iaaa-aaaab-aerfq-cai";
const ALL_PERMISSIONS: [i32; 10] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

// ── Candid helpers ───────────────────────────────────────────────────────────────────

fn encode_text(text: &str) -> Vec<u8> {
    let args = candid_parser::parse_idl_args(text).unwrap_or_else(|err| panic!("bad candid text {text}: {err}"));
    args.to_bytes().unwrap()
}

fn decode(bytes: &[u8]) -> IDLValue {
    IDLArgs::from_bytes(bytes).unwrap().args.into_iter().next().unwrap_or(IDLValue::Null)
}

fn field<'a>(value: &'a IDLValue, name: &str) -> &'a IDLValue {
    let IDLValue::Record(fields) = value else { panic!("not a record (looking for {name}): {value}") };
    let hash = idl_hash(name);
    &fields.iter().find(|f| f.id.get_id() == hash).unwrap_or_else(|| panic!("no field {name} in {value}")).val
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

/// The SNS staking subaccount, and so the neuron id, of (controller, memo).
fn staking_subaccount(controller: Principal, memo: u64) -> Vec<u8> {
    let mut h = Sha256::new();
    h.write(&[12u8]);
    h.write(b"neuron-stake");
    h.write(controller.as_slice());
    h.write(&memo.to_be_bytes());
    h.finish().to_vec()
}

/// The memo the canister's earlier, public rule gave entry i's part at rung k.
fn old_public_memo(i: usize, k: usize) -> u64 {
    ((i as u64) + 1) * 65_536 + k as u64
}

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn blob_text(bytes: &[u8]) -> String {
    format!("blob \"{}\"", bytes.iter().map(|b| format!("\\{b:02x}")).collect::<String>())
}

// ── Typed arguments for the mocks ────────────────────────────────────────────────────

#[derive(CandidType, Deserialize, Clone)]
struct Compact {
    kind: u8,
    from: Principal,
    #[serde(rename = "fromSub")]
    from_sub: Option<Vec<u8>>,
    to: Principal,
    #[serde(rename = "toSub")]
    to_sub: Option<Vec<u8>>,
    amount: Nat,
    fee: Nat,
    ts: u64,
    #[serde(rename = "viaSpender")]
    via_spender: bool,
}

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

#[derive(CandidType, Deserialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Fault {
    #[serde(rename = "error")]
    Error,
    #[serde(rename = "reject")]
    Reject,
    #[serde(rename = "lost")]
    Lost,
}

// ── The world from mock_world.py ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Row {
    owner: Principal,
    held: u128,
    staked: u128,
    gross: u128,
    /// The genesis neuron of the first part: 0 for a basket of nine, 1 otherwise.
    first: usize,
    neurons: Vec<u128>,
}

#[derive(Clone)]
struct WorldSpec {
    close_seconds: u64,
    fee: u128,
    min: u128,
    genesis: Vec<u128>,
    cut: u128,
    supply: u128,
    sale_balance_at_cut: u128,
    active_stake_total: u128,
    hash: String,
    moved: u128,
    withdrawal: (u128, Principal, u128),
    excluded_both: Principal,
    staked_only: (Principal, u128),
    blocks: Vec<Compact>,
    stakes: Vec<StakeInfo>,
    rows: Vec<Row>,
    /// Holders below one minimum neuron: (owner, held, staked).
    dropped: Vec<(Principal, u128, u128)>,
}

fn parse_world(text: &str) -> WorldSpec {
    let mut meta: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let (mut blocks, mut stakes, mut rows, mut dropped) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let p = |s: &str| Principal::from_text(s).unwrap_or_else(|e| panic!("bad principal {s}: {e}"));
    let n = |s: &str| s.parse::<u128>().unwrap_or_else(|e| panic!("bad number {s}: {e}"));
    let sub = |s: &str| if s == "-" { None } else { Some(hex::decode(s).unwrap()) };
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        match f.first().copied() {
            Some("M") => {
                meta.insert(f[1].to_string(), f[2..].iter().map(|x| x.to_string()).collect());
            }
            Some("B") => blocks.push(Compact {
                kind: f[1].parse().unwrap(),
                from: p(f[2]),
                from_sub: sub(f[3]),
                to: p(f[4]),
                to_sub: sub(f[5]),
                amount: Nat::from(n(f[6])),
                fee: Nat::from(n(f[7])),
                ts: f[8].parse().unwrap(),
                via_spender: f[9] == "1",
            }),
            Some("S") => stakes.push(StakeInfo {
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
                pending_rewards: Nat::from(0u64),
                weighted_amount: Nat::from(n(f[3])),
            }),
            Some("R") => rows.push(Row {
                owner: p(f[1]),
                held: n(f[2]),
                staked: n(f[3]),
                gross: n(f[4]),
                first: f[5].parse().unwrap(),
                neurons: f[6].split(',').map(n).collect(),
            }),
            Some("D") => dropped.push((p(f[1]), n(f[2]), n(f[3]))),
            _ => {}
        }
    }
    let m = |k: &str| meta.get(k).unwrap_or_else(|| panic!("world has no {k}")).clone();
    let one = |k: &str| n(&m(k)[0]);
    let w = m("withdrawal");
    let so = m("staked_only");
    WorldSpec {
        close_seconds: one("close_seconds") as u64,
        fee: one("fee"),
        min: one("min"),
        genesis: m("genesis")[0].split(',').map(n).collect(),
        cut: one("cut"),
        supply: one("supply"),
        sale_balance_at_cut: one("sale_balance_at_cut"),
        active_stake_total: one("active_stake_total"),
        hash: m("hash")[0].clone(),
        moved: one("moved"),
        withdrawal: (n(&w[0]), p(&w[1]), n(&w[2])),
        excluded_both: p(&m("excluded_both")[0]),
        staked_only: (p(&so[0]), n(&so[1])),
        blocks,
        stakes,
        rows,
        dropped,
    }
}

// ── Checks ───────────────────────────────────────────────────────────────────────────

struct Checks {
    results: Vec<(String, bool, String)>,
}

impl Checks {
    fn check(&mut self, id: &str, name: &str, passed: bool, detail: impl Into<String>) {
        let detail = detail.into();
        eprintln!("  {} {id:<5} {name}  {detail}", if passed { "ok  " } else { "FAIL" });
        self.results.push((format!("{id} {name}"), passed, detail));
        if let Ok(path) = std::env::var("MPV_REPORT_JSON") {
            let rows = self
                .results
                .iter()
                .map(|(n, p, d)| format!("{{\"check\":{n:?},\"passed\":{p},\"detail\":{d:?}}}"))
                .collect::<Vec<String>>()
                .join(",\n");
            std::fs::write(path, format!("[\n{rows}\n]\n")).unwrap();
        }
    }
    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, id: &str, name: &str, got: T, want: T) {
        let passed = got == want;
        self.check(id, name, passed, format!("got {got:?}, want {want:?}"));
    }
}

// ── The environment ──────────────────────────────────────────────────────────────────

struct Env {
    pic: PocketIc,
    admin: Principal,
    holder: Principal,
    sns: Principal,
    menes: Principal,
    sale: Principal,
    proxy: Principal,
    holder_wasm: Vec<u8>,
    w: WorldSpec,
}

fn read(path: &PathBuf) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|err| panic!("could not read {}: {err}", path.display()))
}

fn destination_of(owner: Principal) -> Principal {
    let mut raw = owner.as_slice().to_vec();
    raw.reverse();
    raw.truncate(28);
    raw.push(0x02);
    Principal::from_slice(&raw)
}

const PHASES: [&str; 6] = ["Unbound", "AwaitClose", "Snapshot", "Delivering", "Aborted", "Halted"];

impl Env {
    async fn new(w: &WorldSpec) -> Env {
        let holder_wasm = read(&PathBuf::from(std::env::var("MPV_HOLDER_WASM").expect("MPV_HOLDER_WASM")));
        let mocks = PathBuf::from(std::env::var("MPV_HOLDER_MOCKS_DIR").expect("MPV_HOLDER_MOCKS_DIR"));
        let wasm = |name: &str| read(&mocks.join(format!("{name}.wasm")));
        let pic = PocketIcBuilder::new().with_nns_subnet().with_application_subnet().build_async().await;
        pic.set_time(Time::from_nanos_since_unix_epoch((w.close_seconds - 3_600) * 1_000_000_000)).await;
        let admin = Principal::from_slice(&[0x10, 0x01, 0x01]);
        // The holder canister is created and installed by an outside party, as it is before it
        // is handed to NNS root: no SNS exists yet.
        let holder = pic.create_canister_with_settings(Some(admin), None).await;
        pic.add_cycles(holder, 100_000_000_000_000_000).await;
        pic.install_canister(holder, holder_wasm.clone(), Encode!().unwrap(), Some(admin)).await;
        let at = |id: &str| Principal::from_text(id).unwrap();
        let sns = pic.create_canister_with_id(Some(admin), None, at(SNS_W)).await.unwrap();
        pic.add_cycles(sns, 100_000_000_000_000_000).await;
        let init = format!(
            "(record {{ holder = principal \"{holder}\"; stakes = vec {{ {} }}; fee = {} : nat; minStake = {} : nat }})",
            w.genesis.iter().map(|s| format!("{s} : nat")).collect::<Vec<_>>().join("; "),
            w.fee,
            w.min
        );
        pic.install_canister(sns, wasm("MockSns"), encode_text(&init), Some(admin)).await;
        let menes = pic.create_canister_with_id(Some(admin), None, at(MENES_LEDGER)).await.unwrap();
        pic.add_cycles(menes, 100_000_000_000_000_000).await;
        pic.install_canister(menes, wasm("MockMenesLedger"), Encode!().unwrap(), Some(admin)).await;
        let sale = pic.create_canister_with_id(Some(admin), None, at(MENES_SALE)).await.unwrap();
        pic.add_cycles(sale, 100_000_000_000_000_000).await;
        pic.install_canister(sale, wasm("MockSale"), Encode!().unwrap(), Some(admin)).await;
        let proxy = pic.create_canister_with_settings(Some(admin), None).await;
        pic.add_cycles(proxy, 100_000_000_000_000_000).await;
        pic.install_canister(proxy, wasm("Proxy"), Encode!().unwrap(), Some(admin)).await;
        for chunk in w.blocks.chunks(200) {
            pic.update_call(menes, admin, "load", Encode!(&chunk.to_vec()).unwrap()).await.unwrap();
        }
        // Part of the history sits behind the archive callback, as on the live ledger.
        pic.update_call(menes, admin, "setArchived", Encode!(&Nat::from((w.blocks.len() / 3) as u64)).unwrap()).await.unwrap();
        pic.update_call(sale, admin, "load", Encode!(&w.stakes).unwrap()).await.unwrap();
        Env { pic, admin, holder, sns, menes, sale, proxy, holder_wasm, w: w.clone() }
    }

    /// Delete the PocketIC instance (the async API keeps it on the server until told).
    async fn finish(self) {
        self.pic.drop().await;
    }

    async fn update(&self, canister: Principal, method: &str, args: Vec<u8>) -> IDLValue {
        let bytes = self.pic.update_call(canister, self.admin, method, args).await.unwrap_or_else(|e| panic!("{method}: {e:?}"));
        decode(&bytes)
    }

    async fn query(&self, canister: Principal, method: &str, args: Vec<u8>) -> IDLValue {
        let bytes = self.pic.query_call(canister, Principal::anonymous(), method, args).await.unwrap_or_else(|e| panic!("{method}: {e:?}"));
        decode(&bytes)
    }

    /// A call from a canister (the proxy), for methods refused as ingress.
    async fn via_proxy(&self, method: &str, args: Vec<u8>) -> Result<IDLValue, String> {
        let arg = Encode!(&self.holder, &method.to_string(), &args).unwrap();
        match self.pic.update_call(self.proxy, self.admin, "call", arg).await {
            Ok(bytes) => Ok(decode(&to_bytes(&decode(&bytes)))),
            Err(e) => Err(format!("{e:?}")),
        }
    }

    async fn status(&self) -> (String, String, Vec<String>) {
        let s = self.query(self.holder, "status", Encode!().unwrap()).await;
        let phase = field(&s, "phase");
        let mut name = variant_name(phase, &PHASES);
        if name == "Halted" {
            name = format!("Halted: {}", to_text(variant_payload(phase)));
        }
        let checks = to_vec(field(&s, "snapshotChecks")).iter().map(to_text).collect();
        (name, to_text(field(&s, "note")), checks)
    }

    /// Let the 15-second timer run `rounds` times.
    async fn run(&self, rounds: usize) {
        for _ in 0..rounds {
            self.pic.advance_time(Duration::from_secs(16)).await;
            for _ in 0..4 {
                self.pic.tick().await;
            }
        }
    }

    async fn run_until_phase(&self, want: &str, max_rounds: usize) -> String {
        for _ in 0..max_rounds {
            let (p, _, _) = self.status().await;
            if p.starts_with(want) || p.starts_with("Halted") || p == "Aborted" {
                return p;
            }
            self.run(1).await;
        }
        self.status().await.0
    }

    async fn bind(&self) {
        self.pic.set_controllers(self.holder, Some(self.admin), vec![self.sns]).await.unwrap();
    }

    async fn commit_swap(&self) {
        let arg = encode_text(&format!("(3 : int32, opt ({} : nat64))", self.w.close_seconds));
        self.update(self.sns, "setLifecycle", arg).await;
    }

    async fn set_mode(&self, mode: i32) {
        self.update(self.sns, "setMode", Encode!(&mode).unwrap()).await;
    }

    /// Upgrade the holder canister as SNS root does: stop, upgrade keeping memory, start.
    async fn upgrade(&self) -> Result<(), String> {
        self.pic.stop_canister(self.holder, Some(self.sns)).await.map_err(|e| format!("stop: {e:?}"))?;
        let r = self.pic.upgrade_eop_canister(self.holder, self.holder_wasm.clone(), Encode!().unwrap(), Some(self.sns)).await;
        self.pic.start_canister(self.holder, Some(self.sns)).await.map_err(|e| format!("start: {e:?}"))?;
        r.map_err(|e| format!("upgrade: {e:?}"))
    }

    async fn table(&self) -> Vec<IDLValue> {
        to_vec(&self.query(self.holder, "getTable", Encode!().unwrap()).await)
    }

    async fn nominate_all(&self, skip: &BTreeSet<Principal>) -> usize {
        let mut n = 0;
        for r in self.w.rows.iter().filter(|r| !skip.contains(&r.owner)) {
            let reply = self.pic.update_call(self.holder, r.owner, "setNeuronDestination", Encode!(&destination_of(r.owner)).unwrap()).await;
            if let Ok(bytes) = reply {
                if variant_name(&decode(&bytes), &["ok", "err"]) == "ok" {
                    n += 1;
                }
            }
        }
        n
    }

    async fn stats(&self) -> IDLValue {
        self.query(self.holder, "stats", Encode!().unwrap()).await
    }

    async fn settlement(&self) -> (bool, String) {
        let s = self.via_proxy("settlement", Encode!().unwrap()).await.unwrap();
        (matches!(field(&s, "settled"), IDLValue::Bool(true)), to_text(field(&s, "reason")))
    }

    async fn reconcile(&self) -> (bool, u128, bool) {
        let r = self.via_proxy("reconcile", Encode!().unwrap()).await.unwrap();
        (matches!(field(&r, "holds"), IDLValue::Bool(true)), to_u128(field(&r, "surplus")), matches!(field(&r, "poolAccounted"), IDLValue::Bool(true)))
    }

    /// Drive delivery by the timer and by processNext from a canister, until every entry is
    /// terminal and every genesis neuron is handed over, or `max` rounds.
    async fn deliver_all(&self, max: usize, mut between: impl FnMut(usize) -> Option<Action>) -> usize {
        for round in 0..max {
            if let Some(action) = between(round) {
                self.act(action).await;
            }
            let pn = self.via_proxy("processNext", Encode!().unwrap()).await;
            self.run(1).await;
            if std::env::var("MPV_DEBUG").is_ok() && round <= 12 {
                eprintln!("    r{round} processNext: {:?}", pn.as_ref().map(|v| to_text(v)));
            }
            if std::env::var("MPV_DEBUG").is_ok() && round % 10 == 0 {
                let (p, note, _) = self.status().await;
                eprintln!("    round {round}: {p}; note: {note}; processNext: {:?}", pn.map(|v| to_text(&v)));
                if round == 10 || round == 390 {
                    let st = self.query(self.holder, "stats", Encode!().unwrap()).await;
                    eprintln!("      takenFrom {:?}", to_vec(field(&st, "takenFrom")).iter().map(to_u128).collect::<Vec<_>>());
                    match self.pic.fetch_canister_logs(self.holder, self.sns).await {
                        Ok(logs) => for l in logs.iter() { eprintln!("      log: {}", String::from_utf8_lossy(&l.content).chars().take(300).collect::<String>()); },
                        Err(e) => eprintln!("      logs: {e:?}"),
                    }
                    let pr = to_vec(&self.query(self.holder, "getProgress", Encode!(&Nat::from(0u64), &Nat::from(100u64)).unwrap()).await);
                    for (i, x) in pr.iter().enumerate() {
                        let st = variant_name(field(x, "status"), &["Pending", "Split", "Granted", "Done"]);
                        if st != "Done" {
                            eprintln!("      entry {i}: {st} dest {} neuron {} attempts {} failures {} err {:?}", to_opt(field(x, "destination")).is_some(), to_u128(field(x, "neuron")), to_u128(field(x, "attempts")), to_u128(field(x, "failures")), to_opt(field(x, "lastError")).map(to_text));
                        }
                    }
                }
            }
            let s = self.stats().await;
            let terminal = to_u128(field(&s, "done")) == to_u128(field(&s, "entries"));
            if terminal && to_u128(field(&s, "parentsHandedOver")) == NEURONS as u128 {
                return round + 1;
            }
        }
        max
    }

    async fn act(&self, action: Action) {
        match action {
            Action::Fault(cmd, f) => {
                self.update(self.sns, "setFaults", Encode!(&cmd.to_string(), &vec![f]).unwrap()).await;
            }
            Action::Upgrade => {
                self.upgrade().await.unwrap();
            }
        }
    }

    async fn neurons(&self) -> BTreeMap<Vec<u8>, IDLValue> {
        to_vec(&self.query(self.sns, "allNeurons", Encode!().unwrap()).await)
            .into_iter()
            .map(|n| (to_bytes(field(to_opt(field(&n, "id")).unwrap(), "id")), n))
            .collect()
    }

    async fn parent_id(&self, k: usize) -> Vec<u8> {
        to_bytes(&self.update(self.sns, "neuronIdOf", Encode!(&self.holder, &(k as u64)).unwrap()).await)
    }

    async fn payout(&self, owner: Principal) -> u128 {
        to_u128(&self.query(self.sns, "payoutOf", Encode!(&owner).unwrap()).await)
    }
}

#[derive(Clone, Copy)]
enum Action {
    Fault(&'static str, Fault),
    Upgrade,
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

/// Every neuron of every basket against the expected table, and nothing paid to anyone;
/// returns the stake the holders hold.
async fn verify_delivery(env: &Env, checks: &mut Checks, id: &str) -> u128 {
    let neurons = env.neurons().await;
    let table = env.table().await;
    let fee = env.w.fee;
    let mut problems: Vec<String> = Vec::new();
    let (mut stake_total, mut neurons_checked) = (0u128, 0usize);
    let mut seen_ids: BTreeSet<Vec<u8>> = BTreeSet::new();
    for (i, e) in table.iter().enumerate() {
        let owner = to_principal(field(e, "owner"));
        let row = &env.w.rows[i];
        let dest = destination_of(owner);
        let basket = to_vec(&env.query(env.holder, "basketOf", Encode!(&Nat::from(i as u64)).unwrap()).await);
        if basket.len() != row.neurons.len() {
            problems.push(format!("entry {i}: {} neurons, want {}", basket.len(), row.neurons.len()));
        }
        for (j, bn) in basket.iter().enumerate() {
            let k = to_u128(field(bn, "rung")) as usize;
            if k != row.first + j {
                problems.push(format!("entry {i} part {j}: rung {k}, want {}", row.first + j));
            }
            let Some(nid) = to_opt(field(bn, "neuronId")).map(to_bytes) else {
                problems.push(format!("entry {i} rung {k}: no id"));
                continue;
            };
            let whole = matches!(field(bn, "genesisNeuron"), IDLValue::Bool(true));
            match to_opt(field(bn, "memo")).map(|m| to_u128(m) as u64) {
                None => problems.push(format!("entry {i} rung {k}: delivered without a memo")),
                Some(m) => {
                    if staking_subaccount(env.holder, m) != nid {
                        problems.push(format!("entry {i} rung {k}: id is not the staking subaccount of (holder, memo)"));
                    }
                    if whole && m != k as u64 {
                        problems.push(format!("entry {i} rung {k}: genesis neuron with memo {m}"));
                    }
                    if !whole && (m < 1 << 63 || m == old_public_memo(i, k)) {
                        problems.push(format!("entry {i} rung {k}: split memo {m} is not a secret memo"));
                    }
                }
            }
            if !seen_ids.insert(nid.clone()) {
                problems.push(format!("entry {i} rung {k}: id used twice"));
            }
            let Some(n) = neurons.get(&nid) else {
                problems.push(format!("entry {i} rung {k}: missing in governance"));
                continue;
            };
            neurons_checked += 1;
            let stake = to_u128(field(n, "cached_neuron_stake_e8s"));
            let want = if whole { row.neurons[j] } else { row.neurons[j] - fee };
            // A handed-over genesis neuron may also carry a donation (group Q).
            if stake < want || (!whole && stake != want) {
                problems.push(format!("entry {i} rung {k}: stake {stake}, want {want}"));
            }
            stake_total += stake;
            if delay_of(n) != 182 * DAY * k as u64 {
                problems.push(format!("entry {i} rung {k}: delay {}", delay_of(n)));
            }
            let theirs = permissions_of(n, dest);
            if theirs != ALL_PERMISSIONS.iter().copied().collect::<BTreeSet<i32>>() {
                problems.push(format!("entry {i} rung {k}: destination holds {theirs:?}"));
            }
            if !permissions_of(n, env.holder).is_empty() {
                problems.push(format!("entry {i} rung {k}: the holder canister still holds permissions"));
            }
            if permissions_of(n, owner).len() > 0 && owner != dest {
                problems.push(format!("entry {i} rung {k}: the snapshot owner holds permissions"));
            }
        }
        if env.payout(owner).await != 0 {
            problems.push(format!("entry {i}: paid liquid"));
        }
    }
    for (owner, _, _) in &env.w.dropped {
        if env.payout(*owner).await != 0 || env.payout(destination_of(*owner)).await != 0 {
            problems.push(format!("dropped holder {owner} was paid"));
        }
        if neurons.values().any(|n| !permissions_of(n, *owner).is_empty() || !permissions_of(n, destination_of(*owner)).is_empty()) {
            problems.push(format!("dropped holder {owner} holds a neuron permission"));
        }
    }
    let total: usize = env.w.rows.iter().map(|r| r.neurons.len()).sum();
    checks.check(id, "every neuron of every basket: right rung, owner, delay and stake; holder canister removed; nothing paid liquid; nothing to a dropped holder",
        problems.is_empty() && neurons_checked == total,
        format!("{neurons_checked} neurons checked of {total}; {} problems {:?}", problems.len(), problems.iter().take(5).collect::<Vec<_>>()));
    stake_total
}

/// `foreign`: neurons in governance that the canister did not make (group G).
async fn books_after(env: &Env, checks: &mut Checks, id: &str, donated: u128, foreign: u128) {
    let stake_total = verify_delivery(env, checks, &format!("{id}a")).await;
    let s = env.stats().await;
    let fees = to_u128(field(&s, "feesPaid"));
    let splits = to_u128(field(&s, "splits"));
    let total: u128 = env.w.rows.iter().map(|r| r.neurons.len() as u128).sum();
    let disburse = to_u128(&env.query(env.sns, "callsOf", Encode!(&"disburse".to_string()).unwrap()).await);
    checks.eq(&format!("{id}b"), "splits = every neuron less the 9 handed-over genesis neurons; no Disburse ever sent", (splits, disburse), (total - 9, 0));
    checks.eq(&format!("{id}c"), "delivered stake + fees = 15,000,000 MPV (+ any donation)", stake_total + fees, POOL + donated);
    let total_neurons = env.neurons().await.len() as u128;
    checks.eq(&format!("{id}d"), "governance holds exactly the 9 genesis neurons, one per split and the strangers' own, none twice", total_neurons, 9 + splits + foreign);
    let (settled, reason) = env.settlement().await;
    checks.check(&format!("{id}e"), "settlement: settled", settled, reason);
}

async fn snapshot_ok(env: &Env, checks: &mut Checks, id: &str) {
    let snap = env.query(env.holder, "getSnapshot", Encode!().unwrap()).await;
    let Some(r) = to_opt(&snap) else {
        checks.check(id, "a snapshot report is published", false, format!("{:?}", env.status().await));
        return;
    };
    let hash = hex_of(&to_bytes(field(r, "tableHash")));
    checks.eq(&format!("{id}a"), "the on-chain table hash equals the independent oracle's", hash, env.w.hash.clone());
    checks.eq(&format!("{id}b"), "blocks at or before the close; supply rebuilt = reported",
        (to_u128(field(r, "cut")), to_u128(field(r, "supplyRebuilt")), to_u128(field(r, "supplyReported"))),
        (env.w.cut, env.w.supply, env.w.supply));
    checks.eq(&format!("{id}c"), "the sale canister's balance at the cut and the active stakes at the close",
        (to_u128(field(r, "saleBalanceAtCut")), to_u128(field(r, "activeStakeTotal"))),
        (env.w.sale_balance_at_cut, env.w.active_stake_total));
    let table = env.table().await;
    let mut diffs = Vec::new();
    for (i, e) in table.iter().enumerate() {
        let r = env.w.rows.get(i);
        let got = (
            to_principal(field(e, "owner")),
            to_u128(field(e, "held")),
            to_u128(field(e, "staked")),
            to_u128(field(e, "gross")),
            to_u128(field(e, "firstRung")) as usize,
            to_vec(field(e, "neurons")).iter().map(to_u128).collect::<Vec<u128>>(),
        );
        let want = r.map(|r| (r.owner, r.held, r.staked, r.gross, r.first, r.neurons.clone()));
        if Some(got.clone()) != want {
            diffs.push(format!("row {i}: got {got:?} want {want:?}"));
        }
    }
    checks.check(&format!("{id}d"), "every row equals the oracle's (owner, held, staked, gross, first rung, parts)", diffs.is_empty() && table.len() == env.w.rows.len(),
        format!("{} rows, {} differ {:?}", table.len(), diffs.len(), diffs.iter().take(3).collect::<Vec<_>>()));
    let dropped: Vec<(Principal, u128, u128)> = to_vec(&env.query(env.holder, "getDropped", Encode!().unwrap()).await)
        .iter()
        .map(|d| (to_principal(field(d, "owner")), to_u128(field(d, "held")), to_u128(field(d, "staked"))))
        .collect();
    let full = env.w.rows.iter().filter(|r| r.first == 0).count() as u128;
    let got_counts = (to_u128(field(r, "dropped")), to_u128(field(r, "fullBaskets")), to_u128(field(r, "smallBaskets")), to_u128(field(r, "movedToEight")));
    let want_counts = (env.w.dropped.len() as u128, full, env.w.rows.len() as u128 - full, env.w.moved);
    checks.check(&format!("{id}f"), "the dropped list equals the oracle's, and the report's counts (dropped, nine, smaller, moved to rungs 1..8)",
        dropped == env.w.dropped && got_counts == want_counts,
        format!("{} dropped vs {}; counts {got_counts:?} vs {want_counts:?}", dropped.len(), env.w.dropped.len()));
    let owners: BTreeSet<Principal> = table.iter().map(|e| to_principal(field(e, "owner"))).collect();
    let so = table.iter().find(|e| to_principal(field(e, "owner")) == env.w.staked_only.0);
    checks.check(&format!("{id}e"), "exclusions: the excluded principal is absent; the staked-only exclusion keeps its held MENES only",
        !owners.contains(&env.w.excluded_both) && so.map(|e| (to_u128(field(e, "held")), to_u128(field(e, "staked")))) == Some((env.w.staked_only.1, 0)),
        format!("excluded present: {}; staked-only row {:?}", owners.contains(&env.w.excluded_both), so.map(|e| (to_u128(field(e, "held")), to_u128(field(e, "staked"))))));
}

async fn to_delivering(env: &Env, checks: &mut Checks, id: &str) {
    env.bind().await;
    env.run(3).await;
    env.commit_swap().await;
    let p = env.run_until_phase("Delivering", 200).await;
    checks.eq(id, "the snapshot completes after the swap commits", p, "Delivering".to_string());
}

fn world() -> WorldSpec {
    let path = std::env::var("MPV_HOLDER_WORLD").expect("MPV_HOLDER_WORLD");
    parse_world(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}")))
}

// ── B: binding and ingress ───────────────────────────────────────────────────────────

async fn group_b(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── B: binding after genesis, no admin; ingress rules");
    let env = Env::new(w).await;
    env.run(3).await;
    checks.eq("B1", "unbound while an outside party controls it", env.status().await.0, "Unbound".to_string());
    env.pic.set_controllers(env.holder, Some(env.admin), vec![env.admin, env.sns]).await.unwrap();
    env.run(3).await;
    checks.eq("B2", "unbound while SNS root is a co-controller", env.status().await.0, "Unbound".to_string());
    env.update(env.sns, "setListed", Encode!(&true, &false).unwrap()).await;
    env.bind().await;
    env.run(3).await;
    let (p, note, _) = env.status().await;
    checks.check("B3", "unbound to a sole controller that does not answer as an SNS root", p == "Unbound", note);
    env.update(env.sns, "setListed", Encode!(&false, &true).unwrap()).await;
    env.run(3).await;
    let (p, note, _) = env.status().await;
    checks.check("B4", "unbound to a root that NNS SNS-W does not list", p == "Unbound" && note.contains("SNS-W"), note);
    env.update(env.sns, "setListed", Encode!(&true, &true).unwrap()).await;
    env.run(3).await;
    let b = env.query(env.holder, "getBinding", Encode!().unwrap()).await;
    let bound = to_opt(field(&b, "binding")).map(|x| [field(x, "root"), field(x, "governance"), field(x, "ledger"), field(x, "swap")].iter().all(|v| to_principal(v) == env.sns));
    checks.check("B5", "bound to that SNS's root, governance, ledger and swap", bound == Some(true) && env.status().await.0 == "AwaitClose", format!("{b}"));
    env.update(env.sns, "setListed", Encode!(&false, &false).unwrap()).await;
    env.run(3).await;
    checks.eq("B6", "bound permanently: no later answer changes it", env.status().await.0, "AwaitClose".to_string());
    env.update(env.sns, "setListed", Encode!(&true, &true).unwrap()).await;
    checks.eq("B7", "waits while the swap is open", env.status().await.0, "AwaitClose".to_string());
    // Ingress (P-2).
    let stranger = Principal::from_slice(&[0x33; 29]);
    let refused = |r: Result<Vec<u8>, pocket_ic::RejectResponse>| r.is_err();
    let a = refused(env.pic.update_call(env.holder, Principal::anonymous(), "processNext", Encode!().unwrap()).await);
    let s = refused(env.pic.update_call(env.holder, stranger, "processNext", Encode!().unwrap()).await);
    let rc = refused(env.pic.update_call(env.holder, stranger, "reconcile", Encode!().unwrap()).await);
    let st = refused(env.pic.update_call(env.holder, stranger, "settlement", Encode!().unwrap()).await);
    let sd = refused(env.pic.update_call(env.holder, Principal::anonymous(), "setNeuronDestination", Encode!(&stranger).unwrap()).await);
    checks.check("B8", "ingress refused: processNext and setNeuronDestination from anonymous or outside the table, reconcile and settlement from anyone", a && s && rc && st && sd, format!("{a} {s} {rc} {st} {sd}"));
    let pr = env.via_proxy("reconcile", Encode!().unwrap()).await.is_ok() && env.via_proxy("processNext", Encode!().unwrap()).await.is_ok();
    checks.check("B9", "the same methods answer a canister", pr, "");
    let q = env.pic.query_call(env.holder, Principal::anonymous(), "status", Encode!().unwrap()).await.is_ok();
    checks.check("B10", "queries stay open to anyone", q, "");
    env.finish().await;
}

// ── H: happy path ────────────────────────────────────────────────────────────────────

async fn group_h(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── H: snapshot at the close, delivery of every share");
    let env = Env::new(w).await;
    to_delivering(&env, checks, "H1").await;
    snapshot_ok(&env, checks, "H2").await;
    // Mode PreInitializationSwap: Split would be refused, so nothing is tried.
    env.nominate_all(&BTreeSet::new()).await;
    env.run(3).await;
    let s = env.stats().await;
    let (_, note, _) = env.status().await;
    let tried = to_u128(&env.query(env.sns, "callsOf", Encode!(&"split".to_string()).unwrap()).await);
    checks.check("H3", "delivery waits for governance to leave PreInitializationSwap", to_u128(field(&s, "done")) == 0 && tried == 0 && note.contains("Normal"), note);
    env.set_mode(1).await;
    let s = env.stats().await;
    checks.eq("H4", "every row is a basket of one to nine neurons; the counts match the oracle's",
        (to_u128(field(&s, "fullBaskets")), to_u128(field(&s, "smallBaskets")), to_u128(field(&s, "neuronsTotal")), to_u128(field(&s, "dropped"))),
        (w.rows.iter().filter(|r| r.first == 0).count() as u128, w.rows.iter().filter(|r| r.first == 1).count() as u128,
         w.rows.iter().map(|r| r.neurons.len() as u128).sum::<u128>(), w.dropped.len() as u128));
    let n = env.nominate_all(&BTreeSet::new()).await;
    checks.eq("H5", "every basket owner can still nominate before its basket starts", n, w.rows.len());
    let rounds = env.deliver_all(400, |_| None).await;
    checks.check("H6", "every entry delivered and every genesis neuron handed over", rounds < 400, format!("{rounds} rounds"));
    books_after(&env, checks, "H7", 0, 0).await;
    let calls = ["split", "add", "remove"].iter().map(|c| c.to_string()).collect::<Vec<_>>();
    let mut total = 0;
    for c in &calls {
        total += to_u128(&env.query(env.sns, "callsOf", Encode!(c).unwrap()).await);
    }
    checks.check("H8", "delivery is made of the canister's own Split and permission commands only (the real-SNS run counts proposals)", total > 0, format!("{total} neuron commands"));
    let stranger = w.dropped[0].0;
    let r = env.pic.update_call(env.holder, stranger, "setNeuronDestination", Encode!(&destination_of(stranger)).unwrap()).await;
    checks.check("H9", "a holder left out cannot nominate (refused at ingress: not in the table)", r.is_err(), format!("{r:?}"));
    env.finish().await;
}

// ── F: fail closed ───────────────────────────────────────────────────────────────────

async fn halted(env: &Env, want: &str) -> (bool, String) {
    let p = env.run_until_phase("Delivering", 200).await;
    let table = env.table().await.len();
    let commands = to_u128(&env.query(env.sns, "callsOf", Encode!(&"split".to_string()).unwrap()).await)
        + to_u128(&env.query(env.sns, "callsOf", Encode!(&"disburse".to_string()).unwrap()).await);
    (p.starts_with("Halted") && p.contains(want) && table == 0 && commands == 0, format!("{p}; table {table}; commands {commands}"))
}

async fn group_f(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── F: fail closed");
    {
        let env = Env::new(w).await;
        env.update(env.menes, "setSupplyDelta", Encode!(&Int::from(1)).unwrap()).await;
        env.bind().await;
        env.run(2).await;
        env.commit_swap().await;
        let (ok, d) = halted(&env, "supply").await;
        checks.check("F1", "a ledger whose reported supply differs from its blocks by 1 e8s: halted, nothing built or paid", ok, d);
        env.finish().await;
    }
    {
        let env = Env::new(w).await;
        env.update(env.menes, "setMissing", Encode!(&Some(Nat::from(5u64))).unwrap()).await;
        env.bind().await;
        env.run(2).await;
        env.commit_swap().await;
        let (ok, d) = halted(&env, "missing block").await;
        checks.check("F2", "an archive that does not return block 5: halted", ok, d);
        env.finish().await;
    }
    {
        let env = Env::new(w).await;
        let (id, owner, amount) = w.withdrawal;
        env.update(env.sale, "setActive", Encode!(&Nat::from(id), &false).unwrap()).await;
        let pay = Compact {
            kind: 1,
            from: Principal::from_text(MENES_SALE).unwrap(),
            from_sub: None,
            to: owner,
            to_sub: None,
            amount: Nat::from(amount),
            fee: Nat::from(10_000u64),
            ts: (w.close_seconds + 60) * 1_000_000_000,
            via_spender: false,
        };
        env.update(env.menes, "load", Encode!(&vec![pay]).unwrap()).await;
        env.bind().await;
        env.run(2).await;
        env.commit_swap().await;
        let (ok, d) = halted(&env, "withdrawn").await;
        checks.check("F3", "a stake inactive at the read with a payout of its amount after the cut: halted", ok, d);
        env.finish().await;
    }
    {
        let env = Env::new(w).await;
        env.bind().await;
        env.run(2).await;
        env.update(env.sns, "setLifecycle", encode_text(&format!("(4 : int32, opt ({} : nat64))", w.close_seconds))).await;
        env.run(5).await;
        let p = env.status().await.0;
        let commands: u128 = {
            let mut t = 0;
            for c in ["split", "disburse", "add", "remove"] {
                t += to_u128(&env.query(env.sns, "callsOf", Encode!(&c.to_string()).unwrap()).await);
            }
            t
        };
        checks.check("F4", "an aborted swap: nothing is read, built or delivered", p == "Aborted" && env.table().await.is_empty() && commands == 0, format!("{p}; {commands} commands"));
        env.finish().await;
    }
    {
        // Stakes that change between the two reads of one round are read again; a stake
        // made after the close changes nothing in the table.
        let env = Env::new(w).await;
        let late = w.stakes.iter().find(|s| s.staked_at > Int::from((w.close_seconds as i128) * 1_000_000_000)).expect("a stake after the close").id.clone();
        env.bind().await;
        env.run(2).await;
        env.commit_swap().await;
        let mut flipped = 0;
        let mut was_waiting = false;
        for _ in 0..200 {
            let (p, note, _) = env.status().await;
            if p != "Snapshot" && p != "AwaitClose" {
                break;
            }
            let waiting = note.contains("settle");
            if waiting && !was_waiting && flipped < 1 {
                env.update(env.sale, "setActive", Encode!(&late, &false).unwrap()).await;
                flipped += 1;
            }
            was_waiting = waiting;
            env.run(1).await;
        }
        let (p, _, c) = env.status().await;
        checks.check("F5", "a stake record that changes during the snapshot is read again, and the table still equals the oracle's", p == "Delivering" && c.iter().any(|l| l.contains("changed")), format!("{p}; flipped {flipped}"));
        snapshot_ok(&env, checks, "F5").await;
        env.finish().await;
    }
    {
        let env = Env::new(w).await;
        let late = w.stakes.iter().find(|s| s.staked_at > Int::from((w.close_seconds as i128) * 1_000_000_000)).unwrap().id.clone();
        env.bind().await;
        env.run(2).await;
        env.commit_swap().await;
        // Flip the stake each time the canister finishes a read of the stake records, so the
        // two reads of every round disagree.
        let mut active = true;
        let mut reads_seen = 0;
        for _ in 0..800 {
            let (p, _, c) = env.status().await;
            if p != "Snapshot" && p != "AwaitClose" {
                break;
            }
            let reads = c.iter().filter(|l| l.contains("stake records (round") || l.contains("changed; reading")).count();
            if reads > reads_seen {
                reads_seen = reads;
                active = !active;
                env.update(env.sale, "setActive", Encode!(&late, &active).unwrap()).await;
            }
            env.run(1).await;
        }
        let p = env.status().await.0;
        checks.check("F6", "stake records that keep changing: halted after five rounds", p.contains("kept changing") && env.table().await.is_empty(), p);
        env.finish().await;
    }
}

// ── R: resume after faults and upgrades ──────────────────────────────────────────────

async fn group_r(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── R: faults on every command, rejects, upgrades between steps");
    let env = Env::new(w).await;
    env.bind().await;
    env.run(2).await;
    env.commit_swap().await;
    // The snapshot under ledger and sale rejects, with an upgrade every other tick.
    let mut upgrades = 0;
    for round in 0..400 {
        let (p, _, _) = env.status().await;
        if p != "Snapshot" && p != "AwaitClose" {
            break;
        }
        let rejecting = round % 5 == 1;
        env.update(env.menes, "setRejecting", Encode!(&rejecting).unwrap()).await;
        env.update(env.sale, "setRejecting", Encode!(&(round % 7 == 3)).unwrap()).await;
        if round % 2 == 0 {
            env.upgrade().await.unwrap();
            upgrades += 1;
        }
        env.run(1).await;
    }
    env.update(env.menes, "setRejecting", Encode!(&false).unwrap()).await;
    env.update(env.sale, "setRejecting", Encode!(&false).unwrap()).await;
    let p = env.run_until_phase("Delivering", 100).await;
    checks.check("R1", "the snapshot completes through ledger and sale rejects and an upgrade every other tick", p == "Delivering", format!("{p}; {upgrades} upgrades"));
    snapshot_ok(&env, checks, "R1").await;
    env.set_mode(1).await;
    env.nominate_all(&BTreeSet::new()).await;
    // Every command, every fault kind, at every genesis neuron: an error, a reject and a lost
    // reply queued on Split of each genesis neuron, on the grant and the strip of the first
    // split-off neuron at each rung k (its id is secret until split, so the mock keys these
    // by rung), and of each genesis neuron, for the basket that receives it whole; more
    // faults at random; an upgrade every 5th round.
    let kinds = vec![Fault::Error, Fault::Reject, Fault::Lost];
    for k in 0..NEURONS {
        let pid = env.parent_id(k).await;
        env.update(env.sns, "setFaultsAt", Encode!(&"split".to_string(), &pid, &kinds).unwrap()).await;
        for cmd in ["add", "remove"] {
            env.update(env.sns, "setFaultsAtRung", Encode!(&cmd.to_string(), &Nat::from(k as u64), &kinds).unwrap()).await;
            env.update(env.sns, "setFaultsAt", Encode!(&cmd.to_string(), &pid, &kinds).unwrap()).await;
        }
    }
    let plan: Vec<(&'static str, Fault)> = ["split", "add", "remove"]
        .iter()
        .flat_map(|c| [Fault::Error, Fault::Reject, Fault::Lost].into_iter().map(move |f| (*c, f)))
        .collect();
    let mut i = 0usize;
    let rounds = env
        .deliver_all(900, |round| {
            if round % 5 == 4 {
                return Some(Action::Upgrade);
            }
            i += 1;
            Some(Action::Fault(plan[i % plan.len()].0, plan[i % plan.len()].1))
        })
        .await;
    checks.check("R2", "delivery completes under faults and upgrades", rounds < 900, format!("{rounds} rounds"));
    // Which neuron each injected fault hit.
    let mut k_of: BTreeMap<Vec<u8>, usize> = BTreeMap::new();
    for k in 0..NEURONS {
        k_of.insert(env.parent_id(k).await, k);
    }
    for i in 0..w.rows.len() {
        for bn in to_vec(&env.query(env.holder, "basketOf", Encode!(&Nat::from(i as u64)).unwrap()).await) {
            if let Some(id) = to_opt(field(&bn, "neuronId")) {
                k_of.insert(to_bytes(id), to_u128(field(&bn, "rung")) as usize);
            }
        }
    }
    let log = to_vec(&env.query(env.sns, "getFaultLog", Encode!().unwrap()).await);
    let mut hit: BTreeSet<(String, usize, String)> = BTreeSet::new();
    for e in &log {
        let IDLValue::Record(f) = e else { continue };
        let cmd = to_text(&f[0].val);
        let k = k_of.get(&to_bytes(&f[1].val)).copied().unwrap_or(99);
        let fault = variant_name(&f[2].val, &["error", "reject", "lost"]);
        hit.insert((cmd, k, fault));
    }
    let mut missing = Vec::new();
    for c in ["split", "add", "remove"] {
        for k in 0..NEURONS {
            for f in ["error", "reject", "lost"] {
                if !hit.contains(&(c.to_string(), k, f.to_string())) {
                    missing.push(format!("{c}@{k}/{f}"));
                }
            }
        }
    }
    checks.check("R3", "an error, a reject and a lost reply hit Split, the grant and the strip at every genesis neuron k = 0..8", missing.is_empty(),
        format!("{} faults injected, {} (command, k, fault) cells hit of 81; missing {:?}", log.len(), hit.len(), missing));
    books_after(&env, checks, "R4", 0, 0).await;
    let (holds, surplus, accounted) = env.reconcile().await;
    checks.check("R5", "books after: hold, no surplus, pool accounted", holds && surplus == 0 && accounted, format!("{holds} {surplus} {accounted}"));
    env.finish().await;
}

// ── Q: books with donations ──────────────────────────────────────────────────────────

async fn group_q(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── Q: donations");
    let env = Env::new(w).await;
    to_delivering(&env, checks, "Q0").await;
    let donated = 123_457u128;
    let p3 = env.parent_id(3).await;
    env.update(env.sns, "donate", Encode!(&p3, &Nat::from(donated)).unwrap()).await;
    let (holds, surplus, accounted) = env.reconcile().await;
    checks.check("Q1", "a donation to a genesis neuron's subaccount is reported as surplus; the books hold", holds && surplus == donated && accounted, format!("{holds} {surplus} {accounted}"));
    // A donation to genesis neuron 0, refreshed into its stake, and a lost reply on a Split
    // of neuron 0: the canister confirms the split from the child neuron, which the donation
    // does not touch, so nothing is split twice and no part changes.
    let p0 = env.parent_id(0).await;
    let big = 5 * (w.min + w.fee);
    env.update(env.sns, "donate", Encode!(&p0, &Nat::from(big)).unwrap()).await;
    env.update(env.sns, "refresh", Encode!(&p0).unwrap()).await;
    let (holds, surplus, accounted) = env.reconcile().await;
    checks.check("Q2", "a refreshed donation on neuron 0: reported as surplus too", holds && surplus == donated + big && accounted, format!("{holds} {surplus} {accounted}"));
    env.update(env.sns, "setFaultsAt", Encode!(&"split".to_string(), &p0, &vec![Fault::Lost, Fault::Lost]).unwrap()).await;
    env.set_mode(1).await;
    env.nominate_all(&BTreeSet::new()).await;
    // The first lost reply leaves one entry holding genesis neuron 0 (its split unconfirmed);
    // every other share on neuron 0 waits for it. The very next call must attempt that entry,
    // wherever the rotating cursor stands: left to the scan, it waits for the cursor to come
    // round, and in a large table every share on neuron 0 waits with it.
    let names = ["Pending", "Split", "Granted", "Done"];
    let all = Encode!(&Nat::from(0u64), &Nat::from(w.rows.len() as u64)).unwrap();
    env.via_proxy("processNext", Encode!().unwrap()).await.unwrap();
    let before = to_vec(&env.query(env.holder, "getProgress", all.clone()).await);
    let held: Vec<usize> = before
        .iter()
        .enumerate()
        .filter(|(_, x)| variant_name(field(x, "status"), &names) == "Split" && to_u128(field(x, "neuron")) == 0 && to_opt(field(x, "lastError")).is_some())
        .map(|(i, _)| i)
        .collect();
    let attempted_first: Vec<usize> = before.iter().enumerate().filter(|(_, x)| to_u128(field(x, "attempts")) > 0).map(|(i, _)| i).collect();
    env.via_proxy("processNext", Encode!().unwrap()).await.unwrap();
    let after = to_vec(&env.query(env.holder, "getProgress", all.clone()).await);
    let moved_on = held.len() == 1 && variant_name(field(&after[held[0]], "status"), &names) != "Split";
    checks.check("Q8", "the entry holding genesis neuron 0 after a lost reply is attempted first by the next call, not when the rotating cursor reaches it",
        moved_on, format!("holding: {held:?}; entries moved by the first call: {}; its status after the next call: {:?}", attempted_first.len(),
            held.first().map(|&j| variant_name(field(&after[j], "status"), &names))));
    let rounds = env.deliver_all(400, |_| None).await;
    checks.check("Q3", "delivery completes", rounds < 400, format!("{rounds} rounds"));
    let left = to_u128(&env.query(env.sns, "faultsLeft", Encode!(&"split".to_string()).unwrap()).await);
    let s = env.stats().await;
    let total: u128 = w.rows.iter().map(|r| r.neurons.len() as u128).sum();
    checks.check("Q4", "both lost Split replies on neuron 0 consumed; every split made exactly once", left == 0 && to_u128(field(&s, "splits")) == total - 9 && env.neurons().await.len() as u128 == total,
        format!("faults left {left}; splits {}; governance neurons {}", to_u128(field(&s, "splits")), env.neurons().await.len()));
    let neurons = env.neurons().await;
    let stake_of = |id: &Vec<u8>| neurons.get(id).map(|n| to_u128(field(n, "cached_neuron_stake_e8s"))).unwrap_or(0);
    let (last0, last3) = (last_part(&env, w, 0).await, last_part(&env, w, 3).await);
    let bal3 = to_u128(&env.update(env.sns, "icrc1_balance_of", encode_text(&format!("(record {{ owner = principal \"{}\"; subaccount = opt {} }})", env.sns, blob_text(&p3)))).await);
    checks.check("Q5", "the unrefreshed donation on neuron 3 goes with neuron 3 to the last basket at k = 3 (stake = its part, balance = part + donation)", stake_of(&p3) == last3 && bal3 == last3 + donated, format!("stake {} part {last3} balance {bal3}", stake_of(&p3)));
    checks.check("Q6", "neuron 0 reaches its last basket holding exactly that basket's part plus the refreshed donation", stake_of(&p0) == last0 + big, format!("stake {} part {last0} donation {big}", stake_of(&p0)));
    // The refreshed donation is stake of the neuron handed over; the unrefreshed one is not.
    books_after(&env, checks, "Q7", big, 0).await;
    env.finish().await;
}

/// The part of the basket that received genesis neuron k itself.
async fn last_part(env: &Env, w: &WorldSpec, k: usize) -> u128 {
    let pid = env.parent_id(k).await;
    let mut v = 0;
    for (i, r) in w.rows.iter().enumerate() {
        for bn in to_vec(&env.query(env.holder, "basketOf", Encode!(&Nat::from(i as u64)).unwrap()).await) {
            if to_opt(field(&bn, "neuronId")).map(to_bytes) == Some(pid.clone()) {
                v = r.neurons[to_u128(field(&bn, "rung")) as usize - r.first];
            }
        }
    }
    v
}

// ── D: delivery conditions and destinations ──────────────────────────────────────────

async fn group_d(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── D: delivery conditions, destinations, a holder who never nominates");
    let env = Env::new(w).await;
    to_delivering(&env, checks, "D0").await;
    env.set_mode(1).await;
    let basket_owner = w.rows.iter().find(|r| r.first == 0).unwrap().owner;
    let dropped_owner = w.dropped[0].0;
    let try_dest = |who: Principal, dest: Principal| {
        let env = &env;
        async move {
            match env.pic.update_call(env.holder, who, "setNeuronDestination", Encode!(&dest).unwrap()).await {
                Ok(b) => {
                    let v = decode(&b);
                    format!("{}: {}", variant_name(&v, &["ok", "err"]), to_text(variant_payload(&v)))
                }
                Err(e) => format!("rejected {e:?}"),
            }
        }
    };
    let r1 = try_dest(basket_owner, env.holder).await;
    let r2 = try_dest(basket_owner, env.sns).await;
    let r3 = try_dest(basket_owner, Principal::anonymous()).await;
    let r4 = try_dest(dropped_owner, destination_of(dropped_owner)).await;
    checks.check("D1", "destinations refused: the canister itself, governance / the ledger, anonymous; a holder left out of the table", [&r1, &r2, &r3, &r4].iter().all(|r| !r.starts_with("ok")), format!("{r1} | {r2} | {r3} | {r4}"));
    // Everyone but one basket-of-nine owner nominates.
    let skip: BTreeSet<Principal> = [basket_owner].into_iter().collect();
    env.nominate_all(&skip).await;
    // The fee changes after the table: delivery waits; restored: it goes on.
    env.update(env.sns, "setParams", encode_text(&format!("({} : nat, {} : nat, vec {{ 1 : int32; 2 : int32; 3 : int32; 4 : int32; 5 : int32; 6 : int32; 7 : int32; 8 : int32; 9 : int32; 10 : int32 }})", w.fee + 1, w.min))).await;
    env.deliver_all(5, |_| None).await;
    let (_, note, _) = env.status().await;
    let d = to_u128(&env.query(env.sns, "callsOf", Encode!(&"split".to_string()).unwrap()).await);
    checks.check("D2", "a fee other than the table's: delivery waits", d == 0 && note.contains("fee"), note);
    env.update(env.sns, "setParams", encode_text(&format!("({} : nat, {} : nat, vec {{ 1 : int32; 2 : int32; 3 : int32; 4 : int32; 5 : int32; 6 : int32; 7 : int32; 8 : int32; 9 : int32; 10 : int32 }})", w.fee, w.min))).await;
    let rounds = env.deliver_all(400, |_| None).await;
    let s = env.stats().await;
    let total: u128 = w.rows.iter().map(|r| r.neurons.len() as u128).sum();
    let (settled, reason) = env.settlement().await;
    checks.check("D3", "a holder who never nominates holds up nobody else; the genesis neurons wait for that holder's share",
        rounds == 400 && to_u128(field(&s, "neuronsDelivered")) == total - 9 && to_u128(field(&s, "parentsHandedOver")) == 0 && !settled,
        format!("delivered {} of {total}; handed over {}; {reason}", to_u128(field(&s, "neuronsDelivered")), to_u128(field(&s, "parentsHandedOver"))));
    let r5 = try_dest(basket_owner, destination_of(basket_owner)).await;
    let rounds = env.deliver_all(200, |_| None).await;
    checks.check("D4", "the late nomination completes delivery", r5.starts_with("ok") && rounds < 200, format!("{r5}; {rounds} rounds"));
    let other = w.rows.iter().find(|r| r.first == 1).unwrap().owner;
    let r6 = try_dest(other, Principal::from_slice(&[0x44; 29])).await;
    checks.check("D5", "a destination cannot be changed once its basket has started (a basket at rungs 1..n)", r6.starts_with("err"), r6);
    books_after(&env, checks, "D6", 0, 0).await;
    env.finish().await;
}

// ── G: secret split memos (G-5) ──────────────────────────────────────────────────────

async fn baskets(env: &Env, w: &WorldSpec) -> Vec<Vec<IDLValue>> {
    let mut out = Vec::new();
    for i in 0..w.rows.len() {
        out.push(to_vec(&env.query(env.holder, "basketOf", Encode!(&Nat::from(i as u64)).unwrap()).await));
    }
    out
}

async fn group_g(checks: &mut Checks, w: &WorldSpec) {
    eprintln!("── G: secret split memos; a stranger's neuron at a part's id");
    let env = Env::new(w).await;
    to_delivering(&env, checks, "G0").await;
    let fee = w.fee;
    let shown: usize = baskets(&env, w).await.iter().flatten()
        .filter(|bn| to_opt(field(bn, "neuronId")).is_some() || to_opt(field(bn, "memo")).is_some()).count();
    let parts: usize = w.rows.iter().map(|r| r.neurons.len()).sum();
    checks.check("G1", "before any split, no part of any basket has an id or a memo", shown == 0, format!("{shown} of {parts} parts show one"));
    // A stranger claims, for the holder canister as controller, a neuron at every id the old
    // public rule gave, each holding exactly that part's stake less the fee.
    let mut planted: BTreeMap<Vec<u8>, u128> = BTreeMap::new();
    for (i, r) in w.rows.iter().enumerate() {
        for (j, part) in r.neurons.iter().enumerate() {
            let k = r.first + j;
            let got = env.update(env.sns, "claim", Encode!(&env.holder, &old_public_memo(i, k), &Nat::from(part - fee)).unwrap()).await;
            if let Some(id) = to_opt(&got) {
                planted.insert(to_bytes(id), part - fee);
            }
        }
    }
    checks.eq("G2", "a stranger claimed a neuron for the holder canister at every id the old public rule gave", planted.len(), parts);
    env.set_mode(1).await;
    env.nominate_all(&BTreeSet::new()).await;
    env.via_proxy("processNext", Encode!().unwrap()).await.unwrap();
    // A part whose split is sent shows its id, and no memo until it is delivered; parts not
    // yet reached show neither.
    let names = ["Pending", "Split", "Granted", "Done"];
    let all = Encode!(&Nat::from(0u64), &Nat::from(w.rows.len() as u64)).unwrap();
    let progress = to_vec(&env.query(env.holder, "getProgress", all).await);
    let bs = baskets(&env, w).await;
    let (mut in_flight, mut wrong) = (0usize, Vec::new());
    for (i, p) in progress.iter().enumerate() {
        let st = variant_name(field(p, "status"), &names);
        let at = to_u128(field(p, "neuron")) as usize;
        let takes = matches!(field(p, "takesParent"), IDLValue::Bool(true));
        for bn in &bs[i] {
            let k = to_u128(field(bn, "rung")) as usize;
            let id = to_opt(field(bn, "neuronId")).map(to_bytes);
            let memo = to_opt(field(bn, "memo")).is_some();
            let delivered = matches!(field(bn, "delivered"), IDLValue::Bool(true));
            if k == at && (st == "Split" || st == "Granted") && !takes {
                in_flight += 1;
                if id.is_none() || id != to_opt(field(p, "neuronId")).map(to_bytes) || memo {
                    wrong.push(format!("entry {i} rung {k}: in flight shows id {} memo {memo}", id.is_some()));
                }
            } else if !delivered && !matches!(field(bn, "genesisNeuron"), IDLValue::Bool(true)) && (id.is_some() || memo) {
                wrong.push(format!("entry {i} rung {k}: not yet split, shows an id or memo"));
            }
        }
    }
    checks.check("G3", "after the first splits: a part in flight shows its id (as in its progress) and no memo; parts not yet split show neither",
        in_flight > 0 && wrong.is_empty(), format!("{in_flight} in flight; {:?}", wrong.iter().take(4).collect::<Vec<_>>()));
    // The next three Splits find a stranger's neuron already at their target id, with the
    // holder canister as controller and exactly the part's stake.
    env.update(env.sns, "setOccupyNext", Encode!(&Nat::from(3u64)).unwrap()).await;
    let rounds = env.deliver_all(500, |_| None).await;
    checks.check("G4", "delivery completes", rounds < 500, format!("{rounds} rounds"));
    let occupied: BTreeSet<Vec<u8>> = to_vec(&env.query(env.sns, "occupiedIds", Encode!().unwrap()).await).iter().map(to_bytes).collect();
    let foreign = to_vec(&env.query(env.holder, "getForeign", Encode!().unwrap()).await);
    let reported: BTreeSet<Vec<u8>> = foreign.iter().map(|f| to_bytes(field(f, "neuronId"))).collect();
    let s = env.stats().await;
    checks.check("G5", "each of the 3 occupied ids is reported once as foreign, and nothing else is (none of the stranger's claims at the old ids)",
        occupied.len() == 3 && reported == occupied && foreign.len() == 3 && to_u128(field(&s, "foreignNeurons")) == 3,
        format!("occupied {}, reported {} ({} records), stats {}", occupied.len(), reported.len(), foreign.len(), to_u128(field(&s, "foreignNeurons"))));
    books_after(&env, checks, "G6", 0, (planted.len() + occupied.len()) as u128).await;
    // Every stranger's neuron is untouched: same stake, no delay, only its claimer, and none
    // is any basket's neuron.
    let neurons = env.neurons().await;
    let bs = baskets(&env, w).await;
    let delivered: BTreeSet<Vec<u8>> = bs.iter().flatten().filter_map(|bn| to_opt(field(bn, "neuronId")).map(to_bytes)).collect();
    let mut bad = Vec::new();
    for (id, stake) in planted.iter().map(|(id, s)| (id.clone(), Some(*s))).chain(occupied.iter().map(|id| (id.clone(), None))) {
        let Some(n) = neurons.get(&id) else { bad.push("missing".to_string()); continue };
        let only_claimer = permissions_of(n, env.holder) == ALL_PERMISSIONS.iter().copied().collect::<BTreeSet<i32>>()
            && to_vec(field(n, "permissions")).len() == 1;
        if stake.is_some_and(|s| to_u128(field(n, "cached_neuron_stake_e8s")) != s) || delay_of(n) != 0 || !only_claimer || delivered.contains(&id) {
            bad.push(format!("{} stake {} delay {} claimer-only {only_claimer} delivered {}", hex_of(&id[..4]), to_u128(field(n, "cached_neuron_stake_e8s")), delay_of(n), delivered.contains(&id)));
        }
    }
    checks.check("G7", "every stranger's neuron is untouched (stake, no delay, only its claimer) and none is a basket's neuron",
        bad.is_empty(), format!("{} stranger neurons; {:?}", planted.len() + occupied.len(), bad.iter().take(4).collect::<Vec<_>>()));
    let moved = foreign.iter().all(|f| {
        let (i, k) = (to_u128(field(f, "entry")) as usize, to_u128(field(f, "rung")) as usize);
        let j = k - w.rows[i].first;
        to_opt(field(&bs[i][j], "neuronId")).map(to_bytes) != Some(to_bytes(field(f, "neuronId")))
    });
    checks.check("G8", "each occupied part was delivered at its next memo, not at the occupied id", moved && foreign.len() == 3, format!("{} records", foreign.len()));
    env.upgrade().await.unwrap();
    let after = baskets(&env, w).await;
    checks.check("G9", "an upgrade keeps every basket's ids and memos (the seed and the steps survive)", after == bs, "");
    env.finish().await;
}

#[tokio::test]
async fn menese_redemption_mocks() {
    let w = world();
    eprintln!("world: {} blocks, {} stakes, {} rows, expected hash {}", w.blocks.len(), w.stakes.len(), w.rows.len(), w.hash);
    assert!(w.moved >= 1 && w.dropped.len() >= 2 && w.rows.iter().any(|r| r.first == 1));
    let mut checks = Checks { results: Vec::new() };
    let only = std::env::var("MPV_GROUPS").unwrap_or_else(|_| "BHFRQDG".into());
    if only.contains('B') {
        group_b(&mut checks, &w).await;
    }
    if only.contains('H') {
        group_h(&mut checks, &w).await;
    }
    if only.contains('F') {
        group_f(&mut checks, &w).await;
    }
    if only.contains('R') {
        group_r(&mut checks, &w).await;
    }
    if only.contains('Q') {
        group_q(&mut checks, &w).await;
    }
    if only.contains('D') {
        group_d(&mut checks, &w).await;
    }
    if only.contains('G') {
        group_g(&mut checks, &w).await;
    }
    let failed: Vec<_> = checks.results.iter().filter(|r| !r.1).map(|r| r.0.clone()).collect();
    eprintln!("{} checks, {} failed {:?}", checks.results.len(), failed.len(), failed);
    assert!(failed.is_empty(), "failed checks: {failed:?}");
}
