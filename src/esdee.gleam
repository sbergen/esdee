///// A utility for dispatching service types and descriptions
///// and managing related subscriptions.

import esdee/internal/dns.{type ResourceRecord}
import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/set.{type Set}
import glip.{type AddressFamily, type IpAddress, Ipv4, Ipv6}
import toss

/// The meta-service type for polling for all services
pub const all_services_type = "_services._dns-sd._udp.local"

/// Describes a service fully discovered via DNS-SD.
/// Note that the same service might be discovered through both IPv4 and IPv6.
pub type ServiceDescription {
  ServiceDescription(
    /// The service type string, e.g. _googlecast._tcp.local
    service_type: String,
    /// The unique instance name for a peer providing the service, e.g.
    /// SHIELD-Android-TV-9693d58e3537dddb118b7b7d17f9c1c2._googlecast._tcp.local
    instance_name: String,
    /// The target host name, which can be used to actually connect to the service, e.g.
    /// 9693d58e-3537-dddb-118b-7b7d17f9c1c2.local
    target_name: String,
    /// The priority of the target host, lower value means more preferred.
    /// Originates from the SRV record.
    priority: Int,
    /// A relative weight for records with the same priority,
    /// higher value means higher chance of getting picked.
    /// Originates from the SRV record.
    weight: Int,
    /// The port the service is served on.
    port: Int,
    /// Any TXT records that the service advertises (can be empty).
    txt_values: List(String),
    /// The resolved IP address
    ip: IpAddress,
  )
}

/// For future options, e.g. IPv6
pub opaque type Options {
  Options(max_data_size: Int, address_families: Set(AddressFamily), port: Int)
}

/// Create default options for DNS-SD discovery.
/// Can be used either with a full-fledged actor implementation
/// which can be found in the `discoverer` module,
/// or used with the `set_up_sockets` function.
pub fn new() -> Options {
  let address_families = set.new() |> set.insert(Ipv4)
  Options(max_data_size: 8192, address_families:, port: 5353)
}

/// Sets a non-standard port, intended for testing
@internal
pub fn using_port(options: Options, port: Int) -> Options {
  Options(..options, port:)
}

/// Configures the maximum data size when receiving UDP datagrams.
/// Affects UDP performance, 8 KiB by default.
pub fn with_max_data_size(options: Options, max_data_size: Int) {
  Options(..options, max_data_size:)
}

/// Sets whether IPv4 will be used. True by default.
pub fn use_ipv4(options: Options, enabled: Bool) -> Options {
  set_address_family(options, Ipv4, enabled)
}

/// Sets whether IPv6 will be used. False by default.
pub fn use_ipv6(options: Options, enabled: Bool) -> Options {
  set_address_family(options, Ipv6, enabled)
}

fn set_address_family(
  options: Options,
  family: AddressFamily,
  enabled: Bool,
) -> Options {
  let address_families =
    options.address_families
    |> case enabled {
      False -> set.delete(_, family)
      True -> set.insert(_, family)
    }

  Options(..options, address_families:)
}

/// The result of successfully parsing a UDP datagram into an DNS-SD update.
pub type ServiceDiscveryUpdate {
  ServiceTypeDiscovered(String)
  ServiceDiscovered(ServiceDescription)
}

/// A pre-processed UDP message
pub type UdpMessage {
  /// A processed datagram that was DNS-SD related
  DnsSdMessage(ServiceDiscveryUpdate)
  /// A UDP message that was not detected to be DNS-SD-related.
  OtherUdpMessage(toss.UdpMessage)
}

/// Configure a selector to receive messages from UDP sockets,
/// pre-processing them to filter separate DNS-SD messages from other messages.
/// You will also need to call
/// [`receive_next_datagram_as_message`](#receive_next_datagram_as_message)
/// to use the selector successfully - once initially,
/// and again after receiving each message.
///
/// Note that this will receive messages from all UDP sockets that the process controls,
/// rather than any specific one.
/// If you wish to only handle messages from one socket then use one process per socket.
pub fn select_processed_udp_messages(
  selector: process.Selector(a),
  mapper: fn(UdpMessage) -> a,
) -> process.Selector(a) {
  use message <- toss.select_udp_messages(selector)
  mapper(classify_message(message))
}

/// Classifies an UDP message
pub fn classify_message(message: toss.UdpMessage) -> UdpMessage {
  case message {
    toss.Datagram(data:, ..) as datagram ->
      case parse_sd_update(data) {
        Error(_) -> OtherUdpMessage(datagram)
        Ok(update) -> DnsSdMessage(update)
      }

    other -> OtherUdpMessage(other)
  }
}

/// Parses the contents of an UDP datagram into a DNS-SD update,
/// Returns an error, if the data was not a DNS-SD update or had incomplete data.
pub fn parse_sd_update(data: BitArray) -> Result(ServiceDiscveryUpdate, Nil) {
  // If we get invalid data, we shouldn't care about it
  use records <- result.try(
    dns.decode_records(data) |> result.replace_error(Nil),
  )

  // If we don't find even a PTR record, we do nothing
  use #(ptr_from, ptr_to) <- result.try(find_ptr(records))

  use <- bool.lazy_guard(when: ptr_from == all_services_type, return: fn() {
    Ok(ServiceTypeDiscovered(ptr_to))
  })

  // If this wasn't an all services discovery, try to find full details
  use description <- result.try(description_from_records(
    records,
    ptr_from,
    ptr_to,
  ))

  Ok(ServiceDiscovered(description))
}

fn find_ptr(records: List(ResourceRecord)) -> Result(#(String, String), Nil) {
  list.find_map(records, fn(record) {
    case record {
      dns.PtrRecord(service_type:, instance_name:) ->
        Ok(#(service_type, instance_name))
      _ -> Error(Nil)
    }
  })
}

fn description_from_records(
  records: List(ResourceRecord),
  service_type: String,
  instance_name: String,
) -> Result(ServiceDescription, Nil) {
  let try_find = fn(with: fn(ResourceRecord) -> Result(a, Nil), apply) {
    result.try(list.find_map(records, with), apply)
  }

  use #(priority, weight, port, target_name) <- try_find(fn(record) {
    case record {
      dns.SrvRecord(priority:, weight:, port:, target_name:, ..) ->
        Ok(#(priority, weight, port, target_name))
      _ -> Error(Nil)
    }
  })

  use ip <- try_find(fn(record) {
    case record {
      dns.ARecord(ip:, ..) | dns.AaaaRecord(ip:, ..) -> Ok(ip)
      _ -> Error(Nil)
    }
  })

  let txt_values =
    list.flat_map(records, fn(record) {
      case record {
        dns.TxtRecord(values:, ..) -> values
        _ -> []
      }
    })

  Ok(ServiceDescription(
    service_type:,
    instance_name:,
    target_name:,
    priority:,
    weight:,
    port:,
    txt_values:,
    ip:,
  ))
}

/// Socket configuration, for IPv4 or IPv6
type SocketConfiguration {
  SocketConfiguration(socket: toss.Socket, broadcast_ip: IpAddress)
}

/// The collection of sockets used for service discovery (one for each address family used)
pub opaque type Sockets {
  Sockets(sockets: List(SocketConfiguration), port: Int)
}

/// An error that can happen while setting up the UDP sockets.
pub type SocketSetupError {
  /// The options had no address family selected
  NoAddressFamilyEnabled
  /// Opening the socket failed
  FailedToOpenSocket(AddressFamily)
  /// Joining the multicast group failed (only relevant for IPv4)
  FailedToJoinMulticastGroup
  /// Setting the socket(s) to active mode failed
  SetActiveModeFailed
}

pub fn describe_setup_error(error: SocketSetupError) -> String {
  case error {
    FailedToJoinMulticastGroup -> "Failed to join (IPv4) multicast group"
    NoAddressFamilyEnabled -> "No address family enabled in options"
    SetActiveModeFailed -> "Setting socket(s) to active mode failed"

    FailedToOpenSocket(family) ->
      "Failed to open IPv"
      <> case family {
        Ipv4 -> "4"
        Ipv6 -> "6"
      }
      <> " socket"
  }
}

/// Opens and sets ups the service discovery UDP socket(s).
pub fn set_up_sockets(options: Options) -> Result(Sockets, SocketSetupError) {
  use _ <- result.try(case set.is_empty(options.address_families) {
    False -> Ok(Nil)
    True -> Error(NoAddressFamilyEnabled)
  })

  use sockets <- result.try(
    options.address_families
    |> set.to_list()
    |> list.map(open_socket(_, options.port))
    |> result.all(),
  )

  Ok(Sockets(sockets, options.port))
}

fn open_socket(
  family: AddressFamily,
  port: Int,
) -> Result(SocketConfiguration, SocketSetupError) {
  use #(socket, broadcast_ip) <- result.try(case family {
    Ipv4 -> {
      let broadcast_ip = constant_ip("224.0.0.251")
      use socket <- result.try(
        toss.new(port)
        |> toss.use_ipv4()
        |> toss.reuse_address()
        |> toss.using_interface(broadcast_ip)
        |> toss.open
        |> result.replace_error(FailedToOpenSocket(family)),
      )

      let local_addr = constant_ip("0.0.0.0")
      use _ <- result.try(
        toss.join_multicast_group(socket, broadcast_ip, local_addr)
        |> result.replace_error(FailedToJoinMulticastGroup),
      )

      Ok(#(socket, broadcast_ip))
    }

    Ipv6 -> {
      let broadcast_ip = constant_ip("ff02::fb")
      use socket <- result.try(
        toss.new(port)
        |> toss.use_ipv6()
        |> toss.reuse_address()
        |> toss.open
        |> result.replace_error(FailedToOpenSocket(family)),
      )

      Ok(#(socket, broadcast_ip))
    }
  })

  use _ <- result.try(
    toss.receive_next_datagram_as_message(socket)
    |> result.replace_error(SetActiveModeFailed),
  )

  Ok(SocketConfiguration(socket, broadcast_ip))
}

pub fn receive_next_datagram_as_message(
  sockets: Sockets,
) -> Result(Nil, toss.Error) {
  use config <- for_each_socket(sockets)
  toss.receive_next_datagram_as_message(config.socket)
}

pub fn close_sockets(sockets: Sockets) -> Nil {
  use socket <- list.each(sockets.sockets)
  toss.close(socket.socket)
}

/// Broadcasts the DNS-SD question for the given service type.
pub fn broadcast_service_question(
  sockets: Sockets,
  service_type: String,
) -> Result(Nil, toss.Error) {
  let data = dns.encode_question(service_type)
  use config <- for_each_socket(sockets)
  toss.send_to(config.socket, config.broadcast_ip, sockets.port, data)
}

fn for_each_socket(
  sockets: Sockets,
  do: fn(SocketConfiguration) -> Result(Nil, e),
) -> Result(Nil, e) {
  sockets.sockets
  |> list.map(do)
  |> result.all()
  |> result.replace(Nil)
}

/// Expects an IP to be valid, DON'T use for dynamic strings.
fn constant_ip(ip: String) -> IpAddress {
  let assert Ok(ip) = glip.parse_ip(ip) as "Did the IP standard change?"
  ip
}
