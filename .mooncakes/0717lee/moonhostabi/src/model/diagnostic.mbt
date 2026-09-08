///|
pub(all) enum DiagnosticSeverity {
  Info
  Warning
  Error
} derive(Eq, Debug)

///|
pub(all) struct Diagnostic {
  code : String
  severity : DiagnosticSeverity
  path : String
  message : String
  byte_offset : Int?
} derive(Eq, Debug)

///|
pub const MHA_PARSE_MALFORMED : String = "MHA_PARSE_MALFORMED"

///|
pub const MHA_PARSE_UNSUPPORTED : String = "MHA_PARSE_UNSUPPORTED"

///|
pub const MHA_PROJECT_UNREPRESENTABLE : String = "MHA_PROJECT_UNREPRESENTABLE"

///|
pub const MHA_PROJECT_UNSUPPORTED_ITEM : String = "MHA_PROJECT_UNSUPPORTED_ITEM"

///|
pub const MHA_IMPORT_ADDED : String = "MHA_IMPORT_ADDED"

///|
pub const MHA_EXPORT_REMOVED : String = "MHA_EXPORT_REMOVED"

///|
pub const MHA_SIGNATURE_CHANGED : String = "MHA_SIGNATURE_CHANGED"

///|
pub const MHA_GC_TYPE_CHANGED : String = "MHA_GC_TYPE_CHANGED"

///|
pub const MHA_ADAPTER_MISMATCH : String = "MHA_ADAPTER_MISMATCH"

///|
pub const MHA_RUNTIME_FAILURE : String = "MHA_RUNTIME_FAILURE"
