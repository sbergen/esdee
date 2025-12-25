import esdee.{
  type ServiceDescription, ServiceDescription, ServiceDiscovered,
  ServiceTypeDiscovered,
}
import esdee/dispatcher
import gleam/erlang/process
import glip

const receive_timeout = 10

pub fn dispatch_empty_test() {
  // Smoke test that nothing happens with an empty dispatcher
  dispatcher.new()
  |> dispatcher.dispatch(ServiceTypeDiscovered("my-service"))
}

pub fn dispatch_basic_test() {
  let type_subject = process.new_subject()
  let details_subject = process.new_subject()
  let other_details_subject = process.new_subject()

  let dispatcher =
    dispatcher.new()
    |> dispatcher.subscribe_to_service_types(process.send(type_subject, _))
    |> dispatcher.subscribe_to_service_details("my-service", process.send(
      details_subject,
      _,
    ))
    |> dispatcher.subscribe_to_service_details("my-other_service", process.send(
      other_details_subject,
      _,
    ))

  let service_type = "my-service"
  let service = fake_service_description("my-service")
  dispatcher.dispatch(dispatcher, ServiceTypeDiscovered(service_type))
  dispatcher.dispatch(dispatcher, ServiceDiscovered(service))

  assert process.receive(type_subject, receive_timeout) == Ok(service_type)
  assert process.receive(details_subject, receive_timeout) == Ok(service)
  assert process.receive(other_details_subject, receive_timeout) == Error(Nil)
}

pub fn subscribe_twice_test() {
  let type_subject = process.new_subject()
  let type_callback = process.send(type_subject, _)

  let details_subject = process.new_subject()
  let details_callback = process.send(details_subject, _)

  let dispatcher =
    dispatcher.new()
    |> dispatcher.subscribe_to_service_types(type_callback)
    |> dispatcher.subscribe_to_service_types(type_callback)
    |> dispatcher.subscribe_to_service_details("my-service", details_callback)
    |> dispatcher.subscribe_to_service_details("my-service", details_callback)

  let service_type = "my-service"
  let service = fake_service_description("my-service")
  dispatcher.dispatch(dispatcher, ServiceTypeDiscovered(service_type))
  dispatcher.dispatch(dispatcher, ServiceDiscovered(service))

  assert process.receive(type_subject, receive_timeout) == Ok(service_type)
  assert process.receive(details_subject, receive_timeout) == Ok(service)

  // Should not be received twice
  assert process.receive(type_subject, receive_timeout) == Error(Nil)
  assert process.receive(details_subject, receive_timeout) == Error(Nil)
}

pub fn unsubscribe_types_test() {
  let type_subject = process.new_subject()
  let type_callback = process.send(type_subject, _)

  let dispatcher =
    dispatcher.new()
    |> dispatcher.subscribe_to_service_types(type_callback)
    // Even if subscribed twice
    |> dispatcher.subscribe_to_service_types(type_callback)
    |> dispatcher.unsubscribe_from_service_types(type_callback)

  let service_type = ServiceTypeDiscovered("my-service")
  dispatcher.dispatch(dispatcher, service_type)

  assert process.receive(type_subject, receive_timeout) == Error(Nil)
}

pub fn unsubscribe_details_test() {
  let subject_1 = process.new_subject()
  let callback_1 = process.send(subject_1, _)

  let subject_2 = process.new_subject()
  let callback_2 = process.send(subject_2, _)

  let both_subject = process.new_subject()
  let both_callback = process.send(both_subject, _)

  let my_service = fake_service_description("my-service")
  let other_service = fake_service_description("other-service")

  let dispatcher =
    dispatcher.new()
    |> dispatcher.subscribe_to_service_details("my-service", callback_1)
    |> dispatcher.subscribe_to_service_details("my-service", callback_2)
    |> dispatcher.subscribe_to_service_details("my-service", both_callback)
    |> dispatcher.subscribe_to_service_details("other-service", both_callback)

  // Unsubscribe first subscriber, others should still receive
  let dispatcher =
    dispatcher.unsubscribe_from_service_details(
      dispatcher,
      "my-service",
      callback_1,
    )
  dispatcher.dispatch(dispatcher, ServiceDiscovered(my_service))
  assert process.receive(subject_1, receive_timeout) == Error(Nil)
  assert process.receive(subject_2, receive_timeout) == Ok(my_service)
  assert process.receive(both_subject, receive_timeout) == Ok(my_service)

  // Unsubscribe from my-service, other-service should still work
  let dispatcher =
    dispatcher.unsubscribe_from_service_details(
      dispatcher,
      "my-service",
      both_callback,
    )
  dispatcher.dispatch(dispatcher, ServiceDiscovered(other_service))
  assert process.receive(both_subject, receive_timeout) == Ok(other_service)

  // Unsubscribe last subscriber, nothing should be received
  let dispatcher =
    dispatcher.unsubscribe_from_service_details(
      dispatcher,
      "my-service",
      callback_2,
    )
  dispatcher.dispatch(dispatcher, ServiceDiscovered(my_service))

  assert process.new_selector()
    |> process.select(subject_1)
    |> process.select(subject_2)
    |> process.select(both_subject)
    |> process.selector_receive(receive_timeout)
    == Error(Nil)
}

fn fake_service_description(service_type: String) -> ServiceDescription {
  let assert Ok(ip) = glip.parse_ip("10.0.0.1")
  ServiceDescription(
    service_type:,
    instance_name: "my-instance",
    target_name: "my-target",
    priority: 42,
    weight: 10,
    port: 8080,
    txt_values: ["my-txt"],
    ip:,
  )
}
