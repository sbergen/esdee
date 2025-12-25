//// A utility for dispatching service types and descriptions
//// and managing related subscriptions.

import esdee.{
  type ServiceDescription, type ServiceDiscveryUpdate, ServiceDiscovered,
  ServiceTypeDiscovered,
}
import gleam/dict.{type Dict}
import gleam/option.{None, Some}
import gleam/set.{type Set}

pub opaque type Dispatcher {
  Dispatcher(
    service_type_callbacks: Set(fn(String) -> Nil),
    service_detail_callbacks: Dict(String, Set(fn(ServiceDescription) -> Nil)),
  )
}

pub fn new() -> Dispatcher {
  Dispatcher(set.new(), dict.new())
}

/// Subscribes the given callback to discovered service types.
/// Calling this multiple times with the same callback
/// does not produce multiple subscriptions.
pub fn subscribe_to_service_types(
  dispatcher: Dispatcher,
  callback: fn(String) -> Nil,
) -> Dispatcher {
  let service_type_callbacks =
    dispatcher.service_type_callbacks
    |> set.insert(callback)
  Dispatcher(..dispatcher, service_type_callbacks:)
}

/// Unsubscribes the given callback from discovered service types.
/// Note that this needs to be the exact same callback instance as used with `subscribe...`.
pub fn unsubscribe_from_service_types(
  dispatcher: Dispatcher,
  callback: fn(String) -> Nil,
) -> Dispatcher {
  let service_type_callbacks =
    dispatcher.service_type_callbacks |> set.delete(callback)
  Dispatcher(..dispatcher, service_type_callbacks:)
}

/// Subscribes the given subject to discovered service details of the given type.
/// Calling this multiple times with the same subject
/// does not produce multiple subscriptions.
pub fn subscribe_to_service_details(
  dispatcher: Dispatcher,
  service_type: String,
  callback: fn(ServiceDescription) -> Nil,
) -> Dispatcher {
  let service_detail_callbacks =
    dispatcher.service_detail_callbacks
    |> dict.upsert(service_type, fn(existing) {
      case existing {
        Some(existing) -> existing
        None -> set.new()
      }
      |> set.insert(callback)
    })
  Dispatcher(..dispatcher, service_detail_callbacks:)
}

/// Unsubscribes the given subject from receiving details for the given service type.
pub fn unsubscribe_from_service_details(
  dispatcher: Dispatcher,
  service_type: String,
  callback: fn(ServiceDescription) -> Nil,
) -> Dispatcher {
  let callbacks_dict = dispatcher.service_detail_callbacks
  let service_detail_callbacks = case dict.get(callbacks_dict, service_type) {
    Error(_) -> callbacks_dict
    Ok(callbacks) -> {
      let callbacks = set.delete(callbacks, callback)
      callbacks_dict
      |> case set.is_empty(callbacks) {
        True -> dict.delete(_, service_type)
        False -> dict.insert(_, service_type, callbacks)
      }
    }
  }
  Dispatcher(..dispatcher, service_detail_callbacks:)
}

/// Dispatches the service discovery update to all relevant subscribers.
pub fn dispatch(dispatcher: Dispatcher, update: ServiceDiscveryUpdate) -> Nil {
  case update {
    ServiceTypeDiscovered(service_type) ->
      set.each(dispatcher.service_type_callbacks, fn(callback) {
        callback(service_type)
      })

    ServiceDiscovered(description) -> {
      case
        dict.get(dispatcher.service_detail_callbacks, description.service_type)
      {
        Ok(callbacks) ->
          set.each(callbacks, fn(callback) { callback(description) })
        Error(_) -> Nil
      }
    }
  }
}
