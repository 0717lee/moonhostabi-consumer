///|
pub(all) enum VerificationBaselineInput {
  ValidBaseline(@lockfile.AbiLockfile)
  InvalidBaseline(String)
} derive(Eq, Debug)

///|
pub(all) enum VerificationContractInput {
  ContractNotProvided
  ContractText(String)
  InvalidContractInput(String)
} derive(Eq, Debug)

///|
fn verification_diagnostic(
  code : String,
  path : String,
  message : String,
) -> @model.Diagnostic {
  @model.Diagnostic::{
    code,
    severity: @model.Error,
    path,
    message,
    byte_offset: None,
  }
}

///|
fn baseline_report(input : VerificationBaselineInput) -> BaselineReport {
  match input {
    ValidBaseline(lockfile) =>
      BaselineValid(lockfile.artifact_fingerprint(), lockfile.abi_fingerprint())
    InvalidBaseline(message) =>
      BaselineInvalid(
        verification_diagnostic("MHA_LOCKFILE_INVALID", "baseline", message),
      )
  }
}

///|
pub fn decode_verification_baseline(text : String) -> VerificationBaselineInput {
  ValidBaseline(@lockfile.decode_lockfile(text)) catch {
    error => InvalidBaseline(error.to_string())
  }
}

///|
fn generator_failure(message : String) -> GeneratorReport {
  GeneratorUnrepresentable([
    verification_diagnostic(@model.MHA_ADAPTER_MISMATCH, "contract", message),
  ])
}

///|
fn verify_generator(
  abi : @model.HostAbi,
  contract : @contract.Contract,
) -> GeneratorReport {
  let result : Result[@generator.GenerationResult, String] = Ok(
    @generator.generate_typescript_adapter(abi, contract),
  ) catch {
    error => Err(error.to_string())
  }
  match result {
    Ok(generated) =>
      if generated.diagnostics.is_empty() {
        GeneratorRepresentable
      } else {
        GeneratorUnrepresentable(generated.diagnostics)
      }
    Err(message) => generator_failure(message)
  }
}

///|
fn verify_contract(
  abi : @model.HostAbi,
  input : VerificationContractInput,
) -> (ContractReport, GeneratorReport) {
  match input {
    ContractNotProvided => {
      let draft : Result[@contract.Contract, String] = Ok(
        @contract.create_contract_draft(abi),
      ) catch {
        error => Err(error.to_string())
      }
      match draft {
        Ok(contract) =>
          (ContractNotProvidedReport, verify_generator(abi, contract))
        Err(message) => (ContractNotProvidedReport, generator_failure(message))
      }
    }
    ContractText(text) => {
      let decoded : Result[@contract.Contract, String] = Ok(
        @contract.decode_contract(abi, text),
      ) catch {
        error => Err(error.to_string())
      }
      match decoded {
        Ok(contract) => (ContractValidReport, verify_generator(abi, contract))
        Err(message) =>
          (
            ContractInvalidReport(
              verification_diagnostic(
                "MHA_CONTRACT_INVALID", "contract", message,
              ),
            ),
            GeneratorNotEvaluated,
          )
      }
    }
    InvalidContractInput(message) =>
      (
        ContractInvalidReport(
          verification_diagnostic("MHA_CONTRACT_INVALID", "contract", message),
        ),
        GeneratorNotEvaluated,
      )
  }
}

///|
fn outcome_from_sections(
  baseline : BaselineReport,
  compatibility : @compat.CompatibilityReport?,
  contract : ContractReport,
  generator : GeneratorReport,
) -> VerificationOutcome {
  if baseline is BaselineInvalid(_) {
    return VerificationInvalid
  }
  match compatibility {
    None => return VerificationInvalid
    Some(report) =>
      if report.classification == @compat.Unknown {
        return VerificationUnknown
      }
  }
  if contract is ContractInvalidReport(_) ||
    generator is GeneratorUnrepresentable(_) {
    return VerificationAdapterMismatch
  }
  match compatibility {
    Some(report) =>
      if report.classification == @compat.Breaking {
        VerificationBreaking
      } else {
        VerificationCompatible
      }
    None => VerificationInvalid
  }
}

///|
pub fn verify_artifact(
  artifact : Bytes,
  baseline_input : VerificationBaselineInput,
  contract_input : VerificationContractInput,
) -> VerificationReport {
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let baseline = baseline_report(baseline_input)
  let analysis_result : Result[@projector.ProjectionAnalysis, String] = Ok(
    @projector.analyze_host_abi(
      @wasm_adapter.parse_artifact(artifact),
      @projector.default_js_capability_policy(),
    ),
  ) catch {
    error => Err(error.to_string())
  }
  match analysis_result {
    Err(message) => {
      let contract = match contract_input {
        ContractNotProvided => ContractNotProvidedReport
        ContractText(_) | InvalidContractInput(_) => ContractNotEvaluatedReport
      }
      VerificationReport::{
        outcome: VerificationInvalid,
        artifact_status: ArtifactInvalid,
        artifact_sha256,
        artifact_abi_sha256: None,
        artifact_diagnostics: [
          verification_diagnostic(
            @model.MHA_PARSE_MALFORMED,
            "artifact",
            message,
          ),
        ],
        baseline,
        provenance_artifact_match: None,
        provenance_abi_match: None,
        compatibility: None,
        contract,
        generator: GeneratorNotEvaluated,
      }
    }
    Ok(analysis) => {
      let artifact_abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
      let (provenance_artifact_match, provenance_abi_match, compatibility) = match
        baseline_input {
        ValidBaseline(lockfile) =>
          (
            Some(lockfile.artifact_fingerprint() == artifact_sha256),
            Some(lockfile.abi_fingerprint() == artifact_abi_sha256),
            Some(
              @compat.compare_host_abi_with_diagnostics(
                lockfile.canonical_abi(),
                analysis.abi,
                analysis.diagnostics,
                @compat.semantic_policy(),
              ),
            ),
          )
        InvalidBaseline(_) => (None, None, None)
      }
      let (contract, generator) = verify_contract(analysis.abi, contract_input)
      VerificationReport::{
        outcome: outcome_from_sections(
          baseline, compatibility, contract, generator,
        ),
        artifact_status: if analysis.diagnostics.is_empty() {
          ArtifactValid
        } else {
          ArtifactUnsupported
        },
        artifact_sha256,
        artifact_abi_sha256: Some(artifact_abi_sha256),
        artifact_diagnostics: analysis.diagnostics,
        baseline,
        provenance_artifact_match,
        provenance_abi_match,
        compatibility,
        contract,
        generator,
      }
    }
  }
}
