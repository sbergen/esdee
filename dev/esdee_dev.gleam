import esdee
import esdee/discoverer.{type Discoverer}
import gleam/erlang/process.{type Subject}
import gleam/io
import glip

type Discovered {
  ServiceType(String)
  ServiceDetails(esdee.ServiceDescription)
}

pub fn main() {
  let assert Ok(discoverer) =
    esdee.new()
    |> esdee.use_ipv6(True)
    |> discoverer.start()
  let discoverer = discoverer.data

  let types = process.new_subject()
  let details = process.new_subject()

  discoverer.subscribe_to_service_types(discoverer, types)
  let assert Ok(_) = discoverer.poll_service_types(discoverer)

  let selector =
    process.new_selector()
    |> process.select_map(types, ServiceType)
    |> process.select_map(details, ServiceDetails)

  recieve_forever(discoverer, selector, details)
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
