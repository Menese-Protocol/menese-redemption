/// MockSale.mo: a test MENES sale canister answering `getStakeInfo` exactly as the live one
/// does. The test loads the stake records and can change one later (to make the two stake
/// reads of the snapshot disagree).
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";

persistent actor MockSale {

  type LockPeriod = { #Months2; #Months4; #Months12; #Months18 };
  public type StakeInfo = {
    id : Nat; owner : Principal; amount : Nat; active : Bool; stakedAt : Int; lockUntil : Int;
    lockPeriod : LockPeriod; pendingRewards : Nat; weightedAmount : Nat;
  };

  let stakes = Map.empty<Nat, StakeInfo>();
  var rejecting : Bool = false;
  public func setRejecting(r : Bool) : async () { rejecting := r };

  public func load(ss : [StakeInfo]) : async Nat {
    for (s in ss.values()) Map.add(stakes, Nat.compare, s.id, s);
    Map.size(stakes);
  };

  public func setActive(id : Nat, active : Bool) : async Bool {
    switch (Map.get(stakes, Nat.compare, id)) {
      case (?s) { Map.add(stakes, Nat.compare, id, { s with active }); true };
      case null false;
    };
  };

  public query func getStakeInfo(id : Nat) : async ?StakeInfo {
    if (rejecting) Runtime.trap("injected reject on getStakeInfo");
    Map.get(stakes, Nat.compare, id);
  };
  public query func size() : async Nat { Map.size(stakes) };
}
