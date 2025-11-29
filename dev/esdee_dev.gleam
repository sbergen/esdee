import esdee

pub fn main() {
  let assert Ok(discovery) =
    esdee.new()
    |> esdee.start()

  //let assert Ok(_) = esdee.discover(discovery, "_googlecast._tcp.local")
  let assert Ok(_) = esdee.discover(discovery, "_services._dns-sd._udp.local")
  recieve_forever(discovery)
}

fn recieve_forever(discovery) {
  echo esdee.receive_next(discovery, 10_000)
  recieve_forever(discovery)
}
