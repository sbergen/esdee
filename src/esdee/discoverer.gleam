//// Provides an actor-based DNS-SD discovery mechanism.

import esdee.{
  type Options, type ServiceDescription, type Sockets, type UdpMessage,
}
import esdee/dispatcher
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import toss

/// A handle to a service discovery actor.
pub opaque type Discoverer {
  Discoverer(subject: Subject(Msg), poll_timeout: Int)
}

pub opaque type Builder {
  Builder(
    options: Options,
    name: Option(process.Name(Msg)),
    start_timeout: Int,
    poll_timeout: Int,
  )
}

/// Sets a timeout for the actor to start.
/// Should be very fast, as no incoming data is waited for.
pub fn start_timeout(builder: Builder, timeout: Int) -> Builder {
  Builder(..builder, start_timeout: timeout)
}

/// Sets a timeout for the actor to respond to poll requests
/// Should be very fast, as no incoming data is waited for.
pub fn poll_timeout(builder: Builder, timeout: Int) -> Builder {
  Builder(..builder, poll_timeout: timeout)
}

/// Starts building a discoverer from the base options.
pub fn build(options: Options) -> Builder {
  Builder(options, None, 1000, 1000)
}

pub fn named(
  builder: Builder,
  name: process.Name(Msg),
) -> #(Builder, Discoverer) {
  let subject = process.named_subject(name)
  let discoverer = Discoverer(subject, builder.poll_timeout)
  let builder = Builder(..builder, name: Some(name))
  #(builder, discoverer)
}

/// Starts a DNS-SD service discovery actor
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Discoverer), actor.StartError) {
  let actor_builder =
    actor.new_with_initialiser(builder.start_timeout, fn(self) {
      use sockets <- result.try(
        esdee.set_up_sockets(builder.options)
        |> result.map_error(esdee.describe_setup_error),
      )

      let selctor =
        process.new_selector()
        |> process.select(self)
        |> esdee.select_processed_udp_messages(UpdUpdate)

      use _ <- result.try(receive_next_datagram_as_message(sockets))

      Ok(
        actor.initialised(State(builder.options, sockets, dispatcher.new()))
        |> actor.selecting(selctor)
        |> actor.returning(Discoverer(self, builder.poll_timeout)),
      )
    })
    |> actor.on_message(handle_message)

  case builder.name {
    Some(name) -> actor.named(actor_builder, name)
    None -> actor_builder
  }
  |> actor.start()
}

/// Returns a child specification for running the actor with supervision.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(Discoverer) {
  supervision.worker(fn() { start(builder) })
}

/// Stops the service discovery actor.
pub fn stop(discoverer: Discoverer) -> Nil {
  process.send(discoverer.subject, Stop)
}

pub opaque type Subscription {
  ServiceTypeSubscription(callback: fn(String) -> Nil)
  ServiceDetailsSubscription(
    service_type: String,
    callback: fn(ServiceDescription) -> Nil,
  )
}

/// Subscribes the given subject to all discovered service types.
/// Note that the same service type might be reported by multiple peers.
/// You will also need to call `poll_service_types` to discover services quickly.
pub fn subscribe_to_service_types(
  discoverer: Discoverer,
  subject: Subject(String),
) -> Subscription {
  subscribe_to_service_types_mapping(discoverer, subject, function.identity)
}

/// Subscribes the given subject to all discovered service types,
/// using the given function to map to another message type.
/// Note that the same service type might be reported by multiple peers.
/// You will also need to call `poll_service_types` to discover services quickly.
pub fn subscribe_to_service_types_mapping(
  discoverer: Discoverer,
  subject: Subject(a),
  mapper: fn(String) -> a,
) -> Subscription {
  let callback = fn(msg) { process.send(subject, mapper(msg)) }
  process.send(discoverer.subject, SubscribeToServiceTypes(callback, True))
  ServiceTypeSubscription(callback)
}

/// Sends a DNS-SD question querying all the available service types in the local network.
/// If there are errors with the socket(s), returns the first error.
pub fn poll_service_types(discoverer: Discoverer) -> Result(Nil, toss.Error) {
  process.call(discoverer.subject, discoverer.poll_timeout, PollServiceTypes)
}

/// Subscribes the given subject to all discovered service details.
/// You will also need to call `poll_service_details` to discover services quickly.
pub fn subscribe_to_service_details(
  discoverer: Discoverer,
  service_type: String,
  subject: Subject(ServiceDescription),
) -> Subscription {
  subscribe_to_service_details_mapping(
    discoverer,
    service_type,
    subject,
    function.identity,
  )
}

/// Subscribes the given subject to all discovered service details,
/// using the given function to map to another message type.
/// You will also need to call `poll_service_details` to discover services quickly.
pub fn subscribe_to_service_details_mapping(
  discoverer: Discoverer,
  service_type: String,
  subject: Subject(a),
  mapper: fn(ServiceDescription) -> a,
) -> Subscription {
  let callback = fn(msg) { process.send(subject, mapper(msg)) }
  process.send(
    discoverer.subject,
    SubscribeToServiceDetails(service_type, callback, True),
  )
  ServiceDetailsSubscription(service_type, callback)
}

/// Sends a DNS-SD question querying the given service type in the local network.
/// If there are errors with the socket(s), returns the first error.
pub fn poll_service_details(
  discoverer: Discoverer,
  service_type: String,
) -> Result(Nil, toss.Error) {
  process.call(discoverer.subject, discoverer.poll_timeout, PollServiceDetails(
    service_type,
    _,
  ))
}

/// Terminates the given subscription.
pub fn unsubscribe(discoverer: Discoverer, subscription: Subscription) -> Nil {
  case subscription {
    ServiceTypeSubscription(callback:) ->
      process.send(discoverer.subject, SubscribeToServiceTypes(callback, False))

    ServiceDetailsSubscription(service_type, callback:) ->
      process.send(
        discoverer.subject,
        SubscribeToServiceDetails(service_type, callback, False),
      )
  }
}

/// The actor state
type State {
  State(options: Options, sockets: Sockets, dispatcher: dispatcher.Dispatcher)
}

/// The internal actor message type
pub opaque type Msg {
  Stop
  SubscribeToServiceTypes(callback: fn(String) -> Nil, subscribe: Bool)
  SubscribeToServiceDetails(
    service_type: String,
    callback: fn(ServiceDescription) -> Nil,
    subscribe: Bool,
  )
  PollServiceTypes(reply_to: Subject(Result(Nil, toss.Error)))
  PollServiceDetails(
    service_type: String,
    reply_to: Subject(Result(Nil, toss.Error)),
  )
  UpdUpdate(UdpMessage)
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    PollServiceDetails(service_type:, reply_to:) ->
      poll(state, service_type, reply_to)

    PollServiceTypes(reply_to:) ->
      poll(state, esdee.all_services_type, reply_to)

    SubscribeToServiceTypes(callback:, subscribe:) -> {
      let dispatcher = case subscribe {
        True ->
          dispatcher.subscribe_to_service_types(state.dispatcher, callback)
        False ->
          dispatcher.unsubscribe_from_service_types(state.dispatcher, callback)
      }

      actor.continue(State(..state, dispatcher:))
    }

    SubscribeToServiceDetails(service_type:, callback:, subscribe:) -> {
      let dispatcher = case subscribe {
        True ->
          dispatcher.subscribe_to_service_details(
            state.dispatcher,
            service_type,
            callback,
          )

        False ->
          dispatcher.unsubscribe_from_service_details(
            state.dispatcher,
            service_type,
            callback,
          )
      }
      actor.continue(State(..state, dispatcher:))
    }

    UpdUpdate(update) -> {
      case handle_udp_update(state.dispatcher, state.sockets, update) {
        Ok(_) -> actor.continue(state)
        Error(e) -> actor.stop_abnormal(e)
      }
    }

    Stop -> {
      esdee.close_sockets(state.sockets)
      actor.stop()
    }
  }
}

fn poll(
  state: State,
  service_type: String,
  respond_to: Subject(Result(Nil, toss.Error)),
) -> actor.Next(State, Msg) {
  let result = esdee.broadcast_service_question(state.sockets, service_type)
  process.send(respond_to, result)
  actor.continue(state)
}

fn handle_udp_update(
  dispatcher: dispatcher.Dispatcher,
  sockets: Sockets,
  update: UdpMessage,
) -> Result(Nil, String) {
  use _ <- result.try(case update {
    esdee.DnsSdMessage(update) -> {
      dispatcher.dispatch(dispatcher, update)
      Ok(Nil)
    }
    esdee.OtherUdpMessage(message) -> {
      case message {
        // Discard other UDP messages
        toss.Datagram(..) -> Ok(Nil)
        toss.UdpError(_, error) -> Error(describe_toss_error(error))
      }
    }
  })

  receive_next_datagram_as_message(sockets)
}

fn receive_next_datagram_as_message(sockets: Sockets) -> Result(Nil, String) {
  esdee.receive_next_datagram_as_message(sockets)
  |> result.map_error(describe_toss_error)
}

fn describe_toss_error(error: toss.Error) -> String {
  "UDP socket failed: " <> toss.describe_error(error)
}
