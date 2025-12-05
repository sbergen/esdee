import esdee
import gleam/erlang/process.{type Subject}
import gleam/io
import glip

type Discovered {
  ServiceType(String)
  ServiceDetails(esdee.ServiceDescription)
}

pub fn main() {
  let assert Ok(discovery) =
    esdee.new()
    |> esdee.start()
  let discovery = discovery.data

  let types = process.new_subject()
  let details = process.new_subject()

  esdee.subscribe_to_service_types(discovery, types)
  let assert Ok(_) = esdee.poll_service_types(discovery)

  let selector =
    process.new_selector()
    |> process.select_map(types, ServiceType)
    |> process.select_map(details, ServiceDetails)

  recieve_forever(discovery, selector, details)
}

fn recieve_forever(
  discovery: esdee.ServiceDiscovery,
  selector: process.Selector(Discovered),
  details: Subject(esdee.ServiceDescription),
) -> Nil {
  let discovered = process.selector_receive_forever(selector)

  case discovered {
    ServiceType(service_type) -> {
      io.println("Discovered service type: " <> service_type)
      esdee.subscribe_to_service_details(discovery, service_type, details)
      let assert Ok(_) = esdee.poll_service_details(discovery, service_type)
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

  recieve_forever(discovery, selector, details)
}
