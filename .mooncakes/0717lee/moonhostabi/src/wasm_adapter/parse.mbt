///|
pub fn parse_artifact(
  bytes : Bytes,
) -> @wasm_types.Module raise @wasm_parser.ParserError {
  @wasm_parser.parse_module(bytes)
}
