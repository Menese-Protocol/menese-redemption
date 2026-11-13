/// SnsGov.mo: the subset of the SNS governance interface this canister uses.
///
/// Transcribed from the candid:service of the SNS governance module SNS-W deploys
/// (git 3e645182, the Nov-2026 mainnet version). Only the commands the delivery path needs
/// (Split, AddNeuronPermissions, RemoveNeuronPermissions), plus get_neuron, get_mode and the
/// nervous system parameters it checks itself against. Nothing here can move MPV out of a
/// neuron: the canister cannot express a Disburse.
/// Field names and variant tags must match the .did exactly or the call decodes to garbage.

module {

  public type NeuronId = { id : Blob };

  public type NeuronPermissionList = { permissions : [Int32] };

  public type AddNeuronPermissions = {
    permissions_to_add : ?NeuronPermissionList;
    principal_id : ?Principal;
  };

  public type RemoveNeuronPermissions = {
    permissions_to_remove : ?NeuronPermissionList;
    principal_id : ?Principal;
  };

  /// Split `amount_e8s` off the neuron into a new one whose id is the staking subaccount of
  /// (caller, memo). The child holds amount - fee, inherits the dissolve state, age and
  /// permissions; the parent must keep at least the minimum stake (governance.rs
  /// split_neuron). A memo already used by the caller is refused, so a split can never be
  /// made twice under the same memo.
  public type Split = { memo : Nat64; amount_e8s : Nat64 };

  public type Command = {
    #Split : Split;
    #AddNeuronPermissions : AddNeuronPermissions;
    #RemoveNeuronPermissions : RemoveNeuronPermissions;
  };

  public type ManageNeuron = { subaccount : Blob; command : ?Command };

  public type GovernanceError = { error_type : Int32; error_message : Text };

  public type CommandResponse = {
    #Error : GovernanceError;
    #Split : { created_neuron_id : ?NeuronId };
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
    neuron_fees_e8s : Nat64;
    vesting_period_seconds : ?Nat64;
    created_timestamp_seconds : Nat64;
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
    /// Governance clamps a neuron's delay at this value. Read so that no basket delay is
    /// issued that governance would clamp, which would leave the read-then-add step
    /// unable ever to reach its target.
    max_dissolve_delay_seconds : ?Nat64;
    /// The permissions this SNS will let a claimer hand on. Read live and used verbatim;
    /// see the note on the removal of ALL_PERMISSIONS below.
    neuron_grantable_permissions : ?NeuronPermissionList;
  };

  public type Service = actor {
    manage_neuron : shared ManageNeuron -> async ManageNeuronResponse;
    get_neuron : shared query { neuron_id : ?NeuronId } -> async GetNeuronResponse;
    get_nervous_system_parameters : shared query () -> async NervousSystemParameters;
    /// 1 Normal, 2 PreInitializationSwap. Split is refused until Normal
    /// (types.rs, manage_neuron_command_is_allowed_in_pre_initialization_swap_or_err).
    get_mode : shared query {} -> async { mode : ?Int32 };
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
