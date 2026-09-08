///|
#external
pub type HostToken

///|
fn host_echo(token : HostToken) -> HostToken = "host" "echo"

///|
#export_name("roundtrip")
pub fn roundtrip(token : HostToken) -> HostToken {
  host_echo(token)
}

///|
#export_name("add")
pub fn add(left : Int, right : Int) -> Int {
  left + right
}
