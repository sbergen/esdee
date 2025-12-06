//// Utility for dispatching service types and descriptions.

import esdee.{
  type ServiceDescription, type ServiceDiscveryUpdate, ServiceDiscovered,
  ServiceTypeDiscoverd,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/set.{type Set}

pub opaque type Dispatcher {
  Dispatcher(
    service_type_subjects: Set(Subject(String)),
    service_detail_subjects: Dict(String, Set(Subject(ServiceDescription))),
  )
}

pub fn new() -> Dispatcher {
  Dispatcher(set.new(), dict.new())
}

pub fn subscribe_to_service_types(
  dispatcher: Dispatcher,
  subject: Subject(String),
) -> Dispatcher {
  let service_type_subjects =
    dispatcher.service_type_subjects
    |> set.insert(subject)
  Dispatcher(..dispatcher, service_type_subjects:)
}

pub fn subscribe_to_service_details(
  dispatcher: Dispatcher,
  service_type: String,
  subject: Subject(ServiceDescription),
) -> Dispatcher {
  let service_detail_subjects =
    dispatcher.service_detail_subjects
    |> dict.upsert(service_type, fn(existing) {
      case existing {
        Some(existing) -> existing
        None -> set.new()
      }
      |> set.insert(subject)
    })
  Dispatcher(..dispatcher, service_detail_subjects:)
}

pub fn dispatch(dispatcher: Dispatcher, update: ServiceDiscveryUpdate) -> Nil {
  case update {
    ServiceTypeDiscoverd(service_type) ->
      set.each(dispatcher.service_type_subjects, process.send(_, service_type))

    ServiceDiscovered(description) -> {
      case
        dict.get(dispatcher.service_detail_subjects, description.service_type)
      {
        Ok(subjects) -> set.each(subjects, process.send(_, description))
        Error(_) -> Nil
      }
    }
  }
}
