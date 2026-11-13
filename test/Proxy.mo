/// Proxy.mo: forwards a raw candid call, so the tests can call the methods the holder
/// canister accepts from canisters only (reconcile, settlement), and can show the same
/// methods refused as ingress.
import IC "mo:core/InternetComputer";

persistent actor Proxy {
  public func call(target : Principal, method : Text, arg : Blob) : async Blob {
    await IC.call(target, method, arg);
  };
}
