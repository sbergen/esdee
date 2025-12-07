import esdee.{type Options}
import esdee/datagrams
import esdee/discoverer.{type Discoverer}
import gleam/erlang/process
import gleam/function
import gleam/result
import glip.{type AddressFamily, type IpAddress, Ipv4, Ipv6}
import toss.{type Socket}

const test_port = 12_345

fn new() -> Discoverer {
  new_with_config(function.identity)
}

fn new_ipv6() -> Discoverer {
  new_with_config(fn(options) {
    options
    |> esdee.use_ipv6(True)
    |> esdee.use_ipv4(False)
  })
}

fn new_with_config(configure: fn(Options) -> Options) -> Discoverer {
  let assert Ok(discoverer) =
    esdee.new()
    |> configure()
    |> esdee.using_port(test_port)
    |> discoverer.start()

  discoverer.data
}

pub fn discover_and_stop_ipv4_test() {
  discover_and_stop(new(), Ipv4)
}

pub fn discover_and_stop_ipv6_test() {
  discover_and_stop(new_ipv6(), Ipv6)
}

fn discover_and_stop(sd: Discoverer, family: AddressFamily) -> Nil {
  let device = start_fake_device(family)

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
      toss.receive(device.socket, 4096, 20)
      |> result.map(fn(tuple) { tuple.2 })
      |> result.replace_error(Nil)
    process.send(result_subject, result)
  })

  process.receive(result_subject, 20)
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
