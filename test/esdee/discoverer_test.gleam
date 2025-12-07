import esdee
import esdee/datagrams
import esdee/discoverer.{type Discoverer}
import gleam/erlang/process
import gleam/result
import glip.{type AddressFamily, type IpAddress, Ipv4, Ipv6}
import toss.{type Socket}

const test_port = 12_345

fn new(family: AddressFamily) -> #(Discoverer, FakeDevice) {
  let assert Ok(sd) =
    esdee.new()
    |> esdee.using_port(test_port)
    |> esdee.use_address_families([family])
    |> discoverer.start()

  let device = start_fake_device(family)

  #(sd.data, device)
}

pub fn discover_and_stop_ipv4_test() {
  discover_and_stop(Ipv4)
}

pub fn discover_and_stop_ipv6_test() {
  discover_and_stop(Ipv6)
}

fn discover_and_stop(family: AddressFamily) -> Nil {
  let #(sd, device) = new(family)

  assert discoverer.poll_service_types(sd) == Ok(Nil)
  assert expect_receive(device) == Ok(datagrams.service_type_discovery_bits)

  discoverer.stop(sd)
}

type FakeDevice {
  FakeDevice(socket: Socket, broadcast_ip: IpAddress)
}

fn expect_receive(device: FakeDevice) -> Result(BitArray, Nil) {
  let result_subject = process.new_subject()
  process.spawn(fn() {
    let result =
      toss.receive(device.socket, 4096, 10)
      |> result.map(fn(tuple) { tuple.2 })
      |> result.replace_error(Nil)
    process.send(result_subject, result)
  })

  process.receive(result_subject, 10)
  |> result.flatten()
}

fn start_fake_device(family: AddressFamily) -> FakeDevice {
  case family {
    Ipv4 -> {
      let broadcast_ip = constant_ip("224.0.0.251")
      let assert Ok(socket) =
        toss.new(test_port)
        |> toss.use_ipv4()
        |> toss.reuse_address()
        |> toss.using_interface(broadcast_ip)
        |> toss.open
        as "Failed to open IPv4 socket"

      let local_addr = constant_ip("0.0.0.0")
      assert toss.join_multicast_group(socket, broadcast_ip, local_addr)
        == Ok(Nil)

      FakeDevice(socket, broadcast_ip)
    }

    Ipv6 -> {
      let broadcast_ip = constant_ip("ff02::fb")
      let assert Ok(socket) =
        toss.new(test_port)
        |> toss.use_ipv6()
        |> toss.reuse_address()
        |> toss.open
        as "Failed to open IPv6 socket"

      FakeDevice(socket, broadcast_ip)
    }
  }
}

/// Expects an IP to be valid, DON'T use for dynamic strings.
fn constant_ip(ip: String) -> IpAddress {
  let assert Ok(ip) = glip.parse_ip(ip) as "Did the IP standard change?"
  ip
}
