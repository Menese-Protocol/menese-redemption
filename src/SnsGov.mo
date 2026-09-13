/// SnsGov.mo: the subset of the SNS governance interface this canister uses.
///
/// Transcribed from rs/sns/governance/canister/governance.did at dfinity/ic master.
/// Only the four commands the payout path needs, plus get_neuron for idempotency.
/// Field names and variant tags must match the .did exactly or the call decodes to garbage.

module {

  public type NeuronId = { id : Blob };

  public type MemoAndController = {
    controller : ?Principal;   // may name a principal OTHER than the caller; verified at
                               // governance.rs:4235, there is no controller == caller check
    memo : Nat64;
  };

  public type By = {
    #MemoAndController : MemoAndController;
    #NeuronId : {};
  };

  public type ClaimOrRefresh = { by : ?By };

  /// NOTE the field is *additional* seconds, not an absolute delay. A retry therefore
  /// ADDS again, which is why the payout path reads the neuron first and only ever sends
  /// the difference. nat32 caps this at ~136 years, comfortably above any delay issued here.
  public type IncreaseDissolveDelay = { additional_dissolve_delay_seconds : Nat32 };

  public type Operation = {
    #ChangeAutoStakeMaturity : { requested_setting_for_auto_stake_maturity : Bool };
    #StopDissolving : {};
    #StartDissolving : {};
    #IncreaseDissolveDelay : IncreaseDissolveDelay;
    #SetDissolveTimestamp : { dissolve_timestamp_seconds : Nat64 };
  };

  public type Configure = { operation : ?Operation };

  /// Permission ids, from NeuronPermissionType in the SNS governance proto.
  /// The full set is what `neuron_claimer_permissions` and `neuron_grantable_permissions`
  /// are both initialised to (rs/sns/init/src/lib.rs:813-814), so all of these are
  /// grantable to the holder and removable from this canister.
  public type NeuronPermissionList = { permissions : [Int32] };

  public type AddNeuronPermissions = {
    permissions_to_add : ?NeuronPermissionList;
    principal_id : ?Principal;
  };

  public type RemoveNeuronPermissions = {
    permissions_to_remove : ?NeuronPermissionList;
    principal_id : ?Principal;
  };

  public type Command = {
    #ClaimOrRefresh : ClaimOrRefresh;
    #Configure : Configure;
    #AddNeuronPermissions : AddNeuronPermissions;
    #RemoveNeuronPermissions : RemoveNeuronPermissions;
  };

  public type ManageNeuron = { subaccount : Blob; command : ?Command };

  public type GovernanceError = { error_type : Int32; error_message : Text };

  public type ClaimOrRefreshResponse = { refreshed_neuron_id : ?NeuronId };

  public type CommandResponse = {
    #Error : GovernanceError;
    #ClaimOrRefresh : ClaimOrRefreshResponse;
    #Configure : {};
    #AddNeuronPermission : {};
    #RemoveNeuronPermission : {};
  };

  public type ManageNeuronResponse = { command : ?CommandResponse };

  public type DissolveState = {
    #DissolveDelaySeconds : Nat64;
    #WhenDissolvedTimestampSeconds : Nat64;
  };

  /// One principal's permissions on a neuron, exactly as governance stores them.
  public type NeuronPermission = {
    principal : ?Principal;
    permission_type : [Int32];
  };

  public type Neuron = {
    id : ?NeuronId;
    cached_neuron_stake_e8s : Nat64;
    dissolve_state : ?DissolveState;
    /// Read so the strip step can remove exactly what this canister actually holds,
    /// rather than a list it assumed it was given.
    permissions : [NeuronPermission];
  };

  public type GetNeuronResult = { #Error : GovernanceError; #Neuron : Neuron };
  public type GetNeuronResponse = { result : ?GetNeuronResult };

  public type NervousSystemParameters = {
    neuron_minimum_dissolve_delay_to_vote_seconds : ?Nat64;
    neuron_minimum_stake_e8s : ?Nat64;
    transaction_fee_e8s : ?Nat64;
    /// The permissions this SNS will let a claimer hand on. Read live and used verbatim;
    /// see the note on the removal of ALL_PERMISSIONS below.
    neuron_grantable_permissions : ?NeuronPermissionList;
  };

  public type Service = actor {
    manage_neuron : shared ManageNeuron -> async ManageNeuronResponse;
    get_neuron : shared query { neuron_id : ?NeuronId } -> async GetNeuronResponse;
    get_nervous_system_parameters : shared query () -> async NervousSystemParameters;
  };

  // No hardcoded permission list is defined here, by design.
  //
  // A prior revision defined `ALL_PERMISSIONS = [0 ... 11]` as an explicit list, so that a
  // future addition to the enum would require a visible code change. The list was wrong:
  // `NeuronPermissionType` defines eleven values, 0 through 10, and governance rejects any
  // list longer than its own enum --
  //
  //     "AddNeuronPermissions command provided more permissions than exist in the system"
  //
  // -- before the grantable-subset check is reached. Every #Neuron entry consequently
  // funded, claimed and set its dissolve delay correctly, then failed permanently at the
  // grant step, leaving this canister as the neuron's sole controller with no admin path.
  // Recorded as defect F-1 in `docs/FINDING-grantable-permissions.md`.
  //
  // The grant step reads `neuron_grantable_permissions` from the live canister and uses it
  // verbatim; the strip step removes the permissions the neuron records for this canister.
  // Neither can diverge from governance's own definition.
}
