import esdee
import esdee/datagrams
import esdee/discoverer.{type Discoverer}
import gleam/erlang/process
import gleam/result
import glip.{type AddressFamily, type IpAddress, Ipv4, Ipv6}
import toss.{type Socket}

const test_port = 12_345

const googlecast_type = "_googlecast._tcp.local"

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

fn discover_and_stop(family: AddressFamily) {
  let #(sd, device) = new(family)

  // Check that discovery packet is sent
  assert discoverer.poll_service_types(sd) == Ok(Nil)
  assert expect_device_receive(device)
    == Ok(datagrams.service_type_discovery_bits)

  // Check that details packet is sent
  assert discoverer.poll_service_details(sd, googlecast_type) == Ok(Nil)
  assert expect_device_receive(device) == Ok(datagrams.googlecast_query_bits)

  // Check that service types are discovered
  let types = process.new_subject()
  discoverer.subscribe_to_service_types(sd, types)
  device_send(device, datagrams.googlecast_type_answer_bits)
  assert process.receive(types, 10) == Ok(googlecast_type)

  // Check that services are discovered
  let services = process.new_subject()
  discoverer.subscribe_to_service_details(sd, googlecast_type, services)
  device_send(device, datagrams.ipv4_service_answer_bits)
  let assert Ok(_) = process.receive(services, 10)
}

pub fn unsubscribe_test() {
  let #(sd, device) = new(Ipv4)

  // Subscribe and unsubscribe
  let types = process.new_subject()
  let services = process.new_subject()

  discoverer.subscribe_to_service_types(sd, types)
  discoverer.subscribe_to_service_details(sd, googlecast_type, services)

  discoverer.unsubscribe_from_service_types(sd, types)
  discoverer.unsubscribe_from_service_details(sd, googlecast_type, services)

  // Send datagrams
  device_send(device, datagrams.googlecast_type_answer_bits)
  device_send(device, datagrams.ipv4_service_answer_bits)

  // Check that nothing is received after unsubscribe
  assert process.receive(types, 10) == Error(Nil)
  assert process.receive(services, 10) == Error(Nil)
}

type FakeDevice {
  FakeDevice(socket: Socket, broadcast_ip: IpAddress)
}

fn expect_device_receive(device: FakeDevice) -> Result(BitArray, toss.Error) {
  toss.receive(device.socket, 4096, 10)
  |> result.map(fn(tuple) { tuple.2 })
}

fn device_send(device: FakeDevice, data: BitArray) {
  assert toss.send_to(device.socket, device.broadcast_ip, test_port, data)
    == Ok(Nil)
    as "Device send failed"
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
