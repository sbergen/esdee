import esdee
import esdee/discoverer.{type Discoverer}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/option
import glip

type Discovered {
  ServiceType(String)
  ServiceDetails(esdee.ServiceDescription)
}

pub fn main() {
  // Create new discoverer that listens to both IPv4 and IPv6 DNS-SD messages
  let assert Ok(sd) =
    esdee.new()
    |> esdee.use_ipv6(True)
    |> discoverer.start(name: option.None)
  let sd = sd.data

  // Set up subjects for both service type and details discovery results
  let types = process.new_subject()
  let details = process.new_subject()

  // Subscribe to available service types,
  // and send a query for all available service types.
  discoverer.subscribe_to_service_types(sd, types)
  let assert Ok(_) = discoverer.poll_service_types(sd)

  // Combine both types of updates into one selector for printing
  let selector =
    process.new_selector()
    |> process.select_map(types, ServiceType)
    |> process.select_map(details, ServiceDetails)

  // Start handling updates
  recieve_forever(sd, selector, details)
}

fn recieve_forever(
  discoverer: Discoverer,
  selector: process.Selector(Discovered),
  details: Subject(esdee.ServiceDescription),
) -> Nil {
  let discovered = process.selector_receive_forever(selector)

  case discovered {
    ServiceType(service_type) -> {
      io.println("Discovered service type: " <> service_type)

      // When a service type is discovered,
      // subscribe to the details of and send a query for that type.
      // No duplicate subscriptions will be created,
      // but duplicate detail queries might be sent,
      // as we aren't doing any filtering on the types.
      discoverer.subscribe_to_service_details(discoverer, service_type, details)
      let assert Ok(_) =
        discoverer.poll_service_details(discoverer, service_type)
      Nil
    }

    ServiceDetails(description) -> {
      io.println(
        description.service_type
        <> " -> "
        <> description.target_name
        <> " @ "
        <> glip.ip_to_string(description.ip),
      )
    }
  }

  recieve_forever(discoverer, selector, details)
}
