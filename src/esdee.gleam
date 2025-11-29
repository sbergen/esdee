import esdee/internal/dns.{type ResourceRecord}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import toss

const mds_port = 5353

/// Describes a service fully discovered via DNS-SD.
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
    /// The IPv4 address, if advertised.
    ipv4: Option(#(Int, Int, Int, Int)),
    /// The IPv6 address, if advertised.
    ipv6: Option(#(Int, Int, Int, Int, Int, Int, Int, Int)),
  )
}

// For future options, e.g. IPv6
pub opaque type Options {
  Options(max_data_size: Int, broadcast_ip: toss.IpAddress)
}

pub opaque type ServiceDiscovery {
  ServiceDiscovery(options: Options, socket: toss.Socket)
}

pub fn new() -> Options {
  Options(max_data_size: 4096, broadcast_ip: toss.Ipv4Address(224, 0, 0, 251))
}

pub type StartError {
  CouldNotOpenSocket
  CouldNotJoinMulticast
}

pub fn start(options: Options) -> Result(ServiceDiscovery, StartError) {
  use socket <- result.try(
    toss.new(mds_port)
    |> toss.use_ipv4()
    |> toss.reuse_address()
    |> toss.using_interface(options.broadcast_ip)
    |> toss.open
    |> result.replace_error(CouldNotOpenSocket),
  )

  let local_addr = toss.Ipv4Address(0, 0, 0, 0)
  use _ <- result.try(
    toss.join_multicast_group(socket, options.broadcast_ip, local_addr)
    |> result.replace_error(CouldNotJoinMulticast),
  )

  Ok(ServiceDiscovery(options, socket))
}

pub fn discover(
  discovery: ServiceDiscovery,
  service: String,
) -> Result(Nil, Nil) {
  let data = dns.encode_question(service)
  toss.send_to(discovery.socket, discovery.options.broadcast_ip, mds_port, data)
  |> result.replace_error(Nil)
}

pub type DiscoveryError {
  ReceiveTimeout
  ReceiveError
  NotAnAnswer
  InvalidDnsData
  InsufficientData
}

pub fn receive_next(
  discovery: ServiceDiscovery,
  timeout_ms: Int,
) -> Result(ServiceDescription, DiscoveryError) {
  use #(_, _, data) <- result.try(
    toss.receive(discovery.socket, discovery.options.max_data_size, timeout_ms)
    |> result.map_error(fn(e) {
      case e {
        toss.Timeout -> ReceiveTimeout
        _ -> ReceiveError
      }
    }),
  )

  use records <- result.try(
    dns.decode_records(data)
    |> result.map_error(fn(e) {
      case e {
        dns.InvalidData -> InvalidDnsData
        dns.NotAnAnswer -> NotAnAnswer
      }
    }),
  )

  description_from_records(records) |> result.replace_error(InsufficientData)
}

fn description_from_records(
  records: List(ResourceRecord),
) -> Result(ServiceDescription, Nil) {
  echo records

  let try_find = fn(with: fn(ResourceRecord) -> Result(a, Nil), apply) {
    result.try(list.find_map(records, with), apply)
  }

  use #(service_type, instance_name) <- try_find(fn(record) {
    case record {
      dns.PtrRecord(service_type:, instance_name:) ->
        Ok(#(service_type, instance_name))
      _ -> Error(Nil)
    }
  })

  use #(priority, weight, port, target_name) <- try_find(fn(record) {
    case record {
      dns.SrvRecord(priority:, weight:, port:, target_name:, ..) ->
        Ok(#(priority, weight, port, target_name))
      _ -> Error(Nil)
    }
  })

  let #(ipv4, ipv6) =
    list.fold(records, #(None, None), fn(ips, record) {
      case record {
        dns.ARecord(ip:, ..) -> #(Some(ip), ips.1)
        dns.AaaaRecord(ip:, ..) -> #(ips.0, Some(ip))
        _ -> ips
      }
    })

  let txt_values =
    list.flat_map(records, fn(record) {
      case record {
        dns.TxtRecord(values:, ..) -> values
        _ -> []
      }
    })

  case option.is_some(ipv4) || option.is_some(ipv6) {
    True ->
      Ok(ServiceDescription(
        service_type:,
        instance_name:,
        target_name:,
        priority:,
        weight:,
        port:,
        txt_values:,
        ipv4:,
        ipv6:,
      ))
    False -> Error(Nil)
  }
}
