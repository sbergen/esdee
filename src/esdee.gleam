import esdee/internal/dns.{type ResourceRecord}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import glip.{type IpAddress}
import toss

const mds_port = 5353

const all_services_type = "_services._dns-sd._udp.local"

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
    /// The resolved IP address
    ip: IpAddress,
  )
}

/// For future options, e.g. IPv6
// TODO: Expose some of the existing options, 
// TODO see if the IP Is useful for testing, or if I should use a different port instead
pub opaque type Options {
  Options(start_timeout: Int, max_data_size: Int, broadcast_ip: IpAddress)
}

/// A handle to a service discovery actor.
pub opaque type ServiceDiscovery {
  ServiceDiscovery(subject: Subject(Msg))
}

/// Start configuring a service discovery actor,
/// which can be started with `start`.
pub fn new() -> Options {
  let broadcast_ip = constant_ip("224.0.0.251")
  Options(start_timeout: 2000, max_data_size: 4096, broadcast_ip:)
}

/// Stops the service discovery actor.
pub fn stop(discovery: ServiceDiscovery) -> Nil {
  process.send(discovery.subject, Stop)
}

/// Subscribes the given subject to all discovered service types.
/// Note that the same service type might be reported by multiple peers.
/// You will also need to call `poll_service_types` to discover services quickly.
pub fn subscribe_to_service_types(
  discovery: ServiceDiscovery,
  subject: Subject(String),
) -> Nil {
  process.send(discovery.subject, SubscribeToServiceTypes(subject))
}

/// Sends a DNS-SD question querying all the available service types in the local network.
pub fn poll_service_types(discovery: ServiceDiscovery) -> Result(Nil, Nil) {
  // TODO: configurable timeout?
  process.call(discovery.subject, 1000, PollServiceTypes)
}

/// Subscribes the given subject to all discovered service details.
/// You will also need to call `poll_service_details` to discover services quickly.
pub fn subscribe_to_service_details(
  discovery: ServiceDiscovery,
  service_type: String,
  subject: Subject(ServiceDescription),
) -> Nil {
  process.send(
    discovery.subject,
    SubscribeToServiceDetails(service_type, subject),
  )
}

/// Sends a DNS-SD question querying the given service type in the local network.
pub fn poll_service_details(
  discovery: ServiceDiscovery,
  service_type: String,
) -> Result(Nil, Nil) {
  // TODO: timeout?
  process.call(discovery.subject, 1000, PollServiceDetails(service_type, _))
}

// TODO: Unsubscribe functions

type Msg {
  /// The actor messages
  Stop
  SubscribeToServiceTypes(subject: Subject(String))
  SubscribeToServiceDetails(
    service_type: String,
    subject: Subject(ServiceDescription),
  )
  PollServiceTypes(reply_to: Subject(Result(Nil, Nil)))
  PollServiceDetails(service_type: String, reply_to: Subject(Result(Nil, Nil)))
  UpdDatagram(data: BitArray)
  UdpError(error: String)
}

/// The actor state
type State {
  State(
    options: Options,
    socket: toss.Socket,
    service_type_subjects: Set(Subject(String)),
    service_detail_subjects: Dict(String, Set(Subject(ServiceDescription))),
  )
}

/// Starts the service discovery actor.
pub fn start(
  options: Options,
) -> Result(actor.Started(ServiceDiscovery), actor.StartError) {
  actor.new_with_initialiser(options.start_timeout, fn(self) {
    use socket <- result.try(
      toss.new(mds_port)
      |> toss.use_ipv4()
      |> toss.reuse_address()
      |> toss.using_interface(options.broadcast_ip)
      |> toss.open
      |> result.replace_error("Could not open socket"),
    )

    let local_addr = constant_ip("0.0.0.0")
    use _ <- result.try(
      toss.join_multicast_group(socket, options.broadcast_ip, local_addr)
      |> result.replace_error("Could not join multicast group"),
    )

    let selctor =
      process.new_selector()
      |> process.select(self)
      |> toss.select_udp_messages(fn(udp_msg) {
        case udp_msg {
          toss.Datagram(data:, ..) -> UpdDatagram(data)
          toss.UdpError(_, e) -> UdpError(toss.describe_error(e))
        }
      })

    use _ <- result.try(
      toss.receive_next_datagram_as_message(socket)
      |> result.replace_error("UDP message delivery failed"),
    )

    Ok(
      actor.initialised(State(options, socket, set.new(), dict.new()))
      |> actor.selecting(selctor)
      |> actor.returning(ServiceDiscovery(self)),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    PollServiceDetails(service_type:, reply_to:) ->
      poll(state, service_type, reply_to)
    PollServiceTypes(reply_to:) -> poll(state, all_services_type, reply_to)

    SubscribeToServiceTypes(subject:) -> {
      let service_type_subjects =
        state.service_type_subjects
        |> set.insert(subject)
      actor.continue(State(..state, service_type_subjects:))
    }

    SubscribeToServiceDetails(service_type:, subject:) -> {
      let service_detail_subjects =
        state.service_detail_subjects
        |> dict.upsert(service_type, fn(existing) {
          case existing {
            Some(existing) -> existing
            None -> set.new()
          }
          |> set.insert(subject)
        })
      actor.continue(State(..state, service_detail_subjects:))
    }

    UpdDatagram(data:) -> {
      case toss.receive_next_datagram_as_message(state.socket) {
        // This shouldn't really happen, unless something is really wrong AFAIK.
        Error(_) -> actor.stop_abnormal("UDP message delivery failed")

        Ok(_) -> {
          // Errors from handle_datagram are fine, we're just abusing result.try
          let _ = handle_datagram(state, data)
          actor.continue(state)
        }
      }
    }

    // This shouldn't really happen, unless something is really wrong AFAIK.
    // If I get a practical example of why this could happen, 
    // we should probably do something else.
    UdpError(error:) -> actor.stop_abnormal("UDP socket failed: " <> error)

    Stop -> {
      toss.close(state.socket)
      actor.stop()
    }
  }
}

fn poll(
  state: State,
  service: String,
  respond_to: Subject(Result(Nil, Nil)),
) -> actor.Next(State, Msg) {
  let data = dns.encode_question(service)
  let result =
    toss.send_to(state.socket, state.options.broadcast_ip, mds_port, data)
    |> result.replace_error(Nil)

  process.send(respond_to, result)
  actor.continue(state)
}

fn handle_datagram(state: State, data: BitArray) -> Result(Nil, Nil) {
  // If we get invalid data, we shouldn't care about it
  use records <- result.try(
    dns.decode_records(data) |> result.replace_error(Nil),
  )

  // If we don't find even a PTR record, we do nothing
  use #(ptr_from, ptr_to) <- result.try(find_ptr(records))

  use <- bool.lazy_guard(when: ptr_from == all_services_type, return: fn() {
    set.each(state.service_type_subjects, process.send(_, ptr_to))
    Ok(Nil)
  })

  // If this wasn't an all services discovery, try to find full details
  use description <- result.try(description_from_records(
    records,
    ptr_from,
    ptr_to,
  ))

  // If we find all the required data, send the result!
  use subjects <- result.map(dict.get(
    state.service_detail_subjects,
    description.service_type,
  ))

  set.each(subjects, process.send(_, description))
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

/// Expects an IP to be valid, DON'T use for dynamic strings.
fn constant_ip(ip: String) -> IpAddress {
  let assert Ok(ip) = glip.parse_ip(ip) as "Did the IP standard change?"
  ip
}
