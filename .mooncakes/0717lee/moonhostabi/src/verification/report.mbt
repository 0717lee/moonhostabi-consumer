///|
pub(all) enum VerificationOutcome {
  VerificationCompatible
  VerificationBreaking
  VerificationUnknown
  VerificationInvalid
  VerificationAdapterMismatch
} derive(Eq, Debug)

///|
pub(all) enum ArtifactReportStatus {
  ArtifactValid
  ArtifactUnsupported
  ArtifactInvalid
} derive(Eq, Debug)

///|
pub(all) enum BaselineReport {
  BaselineValid(String, String)
  BaselineInvalid(@model.Diagnostic)
} derive(Eq, Debug)

///|
pub(all) enum ContractReport {
  ContractNotProvidedReport
  ContractValidReport
  ContractInvalidReport(@model.Diagnostic)
  ContractNotEvaluatedReport
} derive(Eq, Debug)

///|
pub(all) enum GeneratorReport {
  GeneratorRepresentable
  GeneratorUnrepresentable(Array[@model.Diagnostic])
  GeneratorNotEvaluated
} derive(Eq, Debug)

///|
pub struct VerificationReport {
  outcome : VerificationOutcome
  artifact_status : ArtifactReportStatus
  artifact_sha256 : String
  artifact_abi_sha256 : String?
  artifact_diagnostics : Array[@model.Diagnostic]
  baseline : BaselineReport
  provenance_artifact_match : Bool?
  provenance_abi_match : Bool?
  compatibility : @compat.CompatibilityReport?
  contract : ContractReport
  generator : GeneratorReport
} derive(Eq, Debug)

///|
fn report_json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn report_bool(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
fn report_optional_bool(value : Bool?) -> String {
  match value {
    Some(value) => report_bool(value)
    None => "null"
  }
}

///|
fn report_optional_string(value : String?) -> String {
  match value {
    Some(value) => report_json_string(value)
    None => "null"
  }
}

///|
fn report_severity(severity : @model.DiagnosticSeverity) -> String {
  match severity {
    @model.Info => "info"
    @model.Warning => "warning"
    @model.Error => "error"
  }
}

///|
fn encode_report_diagnostic(diagnostic : @model.Diagnostic) -> String {
  let byte_offset = match diagnostic.byte_offset {
    Some(value) => value.to_string()
    None => "null"
  }
  "{\"code\":\{report_json_string(diagnostic.code)},\"severity\":\{report_json_string(report_severity(diagnostic.severity))},\"path\":\{report_json_string(diagnostic.path)},\"message\":\{report_json_string(diagnostic.message)},\"byteOffset\":\{byte_offset}}"
}

///|
fn encode_report_diagnostics(diagnostics : Array[@model.Diagnostic]) -> String {
  "[\{diagnostics.map(fn(value) { encode_report_diagnostic(value) }).join(",")}]"
}

///|
fn report_compatibility(value : @compat.Compatibility) -> String {
  match value {
    @compat.Compatible => "compatible"
    @compat.Breaking => "breaking"
    @compat.Unknown => "unknown"
  }
}

///|
fn encode_report_change(change : @compat.AbiChange) -> String {
  "{\"classification\":\{report_json_string(report_compatibility(change.classification))},\"code\":\{report_json_string(change.code)},\"path\":\{report_json_string(change.path)},\"message\":\{report_json_string(change.message)}}"
}

///|
fn report_outcome(outcome : VerificationOutcome) -> String {
  match outcome {
    VerificationCompatible => "compatible"
    VerificationBreaking => "breaking"
    VerificationUnknown => "unknown"
    VerificationInvalid => "invalid"
    VerificationAdapterMismatch => "adapterMismatch"
  }
}

///|
fn report_artifact_status(status : ArtifactReportStatus) -> String {
  match status {
    ArtifactValid => "valid"
    ArtifactUnsupported => "unsupported"
    ArtifactInvalid => "invalid"
  }
}

///|
fn encode_baseline_report(baseline : BaselineReport) -> String {
  match baseline {
    BaselineValid(artifact_sha256, abi_sha256) =>
      "{\"status\":\"valid\",\"artifactSha256\":\{report_json_string(artifact_sha256)},\"abiSha256\":\{report_json_string(abi_sha256)},\"diagnostic\":null}"
    BaselineInvalid(diagnostic) =>
      "{\"status\":\"invalid\",\"artifactSha256\":null,\"abiSha256\":null,\"diagnostic\":\{encode_report_diagnostic(diagnostic)}}"
  }
}

///|
fn encode_compatibility_report(
  compatibility : @compat.CompatibilityReport?,
) -> String {
  match compatibility {
    None =>
      "{\"status\":\"notEvaluated\",\"classification\":null,\"changes\":[]}"
    Some(report) =>
      "{\"status\":\"evaluated\",\"classification\":\{report_json_string(report_compatibility(report.classification))},\"changes\":[" +
      report.changes.map(fn(value) { encode_report_change(value) }).join(",") +
      "]}"
  }
}

///|
fn encode_contract_report(contract : ContractReport) -> String {
  match contract {
    ContractNotProvidedReport =>
      "{\"status\":\"notProvided\",\"diagnostic\":null}"
    ContractValidReport => "{\"status\":\"valid\",\"diagnostic\":null}"
    ContractInvalidReport(diagnostic) =>
      "{\"status\":\"invalid\",\"diagnostic\":\{encode_report_diagnostic(diagnostic)}}"
    ContractNotEvaluatedReport =>
      "{\"status\":\"notEvaluated\",\"diagnostic\":null}"
  }
}

///|
fn encode_generator_report(generator : GeneratorReport) -> String {
  match generator {
    GeneratorRepresentable =>
      "{\"status\":\"representable\",\"diagnostics\":[]}"
    GeneratorUnrepresentable(diagnostics) =>
      "{\"status\":\"unrepresentable\",\"diagnostics\":\{encode_report_diagnostics(diagnostics)}}"
    GeneratorNotEvaluated => "{\"status\":\"notEvaluated\",\"diagnostics\":[]}"
  }
}

///|
pub fn encode_verification_report(report : VerificationReport) -> String {
  "{\"schemaVersion\":1,\"outcome\":\{report_json_string(report_outcome(report.outcome))},\"artifact\":{\"status\":\{report_json_string(report_artifact_status(report.artifact_status))},\"sha256\":\{report_json_string(report.artifact_sha256)},\"abiSha256\":\{report_optional_string(report.artifact_abi_sha256)},\"diagnostics\":\{encode_report_diagnostics(report.artifact_diagnostics)}},\"baseline\":\{encode_baseline_report(report.baseline)},\"provenance\":{\"artifactMatchesBaseline\":\{report_optional_bool(report.provenance_artifact_match)},\"abiMatchesBaseline\":\{report_optional_bool(report.provenance_abi_match)}},\"compatibility\":\{encode_compatibility_report(report.compatibility)},\"contract\":\{encode_contract_report(report.contract)},\"generator\":\{encode_generator_report(report.generator)}}"
}

///|
pub fn VerificationReport::recommended_exit_code(
  self : VerificationReport,
) -> Int {
  match self.outcome {
    VerificationCompatible => 0
    VerificationBreaking => 2
    VerificationUnknown | VerificationInvalid => 3
    VerificationAdapterMismatch => 4
  }
}
