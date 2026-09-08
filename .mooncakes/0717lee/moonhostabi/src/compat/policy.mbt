///|
pub(all) enum Compatibility {
  Compatible
  Breaking
  Unknown
} derive(Eq, Debug)

///|
pub(all) enum CompatibilityPolicy {
  Semantic
  Strict
} derive(Eq, Debug)

///|
pub fn semantic_policy() -> CompatibilityPolicy {
  Semantic
}

///|
pub fn strict_policy() -> CompatibilityPolicy {
  Strict
}

///|
pub const MHA_EXPORT_ADDED : String = "MHA_EXPORT_ADDED"

///|
pub const MHA_IMPORT_REMOVED : String = "MHA_IMPORT_REMOVED"

///|
pub const MHA_SCHEMA_UNSUPPORTED : String = "MHA_SCHEMA_UNSUPPORTED"

///|
pub const MHA_FEATURE_UNSUPPORTED : String = "MHA_FEATURE_UNSUPPORTED"

///|
pub(all) struct AbiChange {
  classification : Compatibility
  code : String
  path : String
  message : String
} derive(Eq, Debug)

///|
pub(all) struct CompatibilityReport {
  classification : Compatibility
  changes : Array[AbiChange]
} derive(Eq, Debug)
