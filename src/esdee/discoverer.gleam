//// Provides an actor-based DNS-SD discovery mechanism.

import esdee.{
  type Options, type ServiceDescription, type Sockets, type UdpMessage,
}
import esdee/dispatcher
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import toss

/// A handle to a service discovery actor.
pub opaque type Discoverer {
  Discoverer(subject: Subject(Msg), poll_timeout: Int)
}

/// Starts a DNS-SD service discovery actor with the default timeouts.
pub fn start(
  options: Options,
) -> Result(actor.Started(Discoverer), actor.StartError) {
  start_with_timeouts(options, 1000, 1000)
}

/// Returns a child specification for running the actor with supervision.
pub fn supervised(
  options: Options,
  start_timeout_milliseconds: Int,
  poll_timeout_milliseconds: Int,
) -> supervision.ChildSpecification(Discoverer) {
  supervision.worker(fn() {
    start_with_timeouts(
      options,
      start_timeout_milliseconds,
      poll_timeout_milliseconds,
    )
  })
}

/// Starts a DNS-SD service discovery actor with custom timeouts.
/// The timeouts apply to the actor startup, 
/// and it responding to poll requests respectively.
/// Both should be very fast, as no incoming data is waited for.
pub fn start_with_timeouts(
  options: Options,
  start_timeout_milliseconds: Int,
  poll_timeout_milliseconds: Int,
) -> Result(actor.Started(Discoverer), actor.StartError) {
  actor.new_with_initialiser(start_timeout_milliseconds, fn(self) {
    use sockets <- result.try(
      esdee.set_up_sockets(options)
      |> result.map_error(esdee.describe_setup_error),
    )

    let selctor =
      process.new_selector()
      |> process.select(self)
      |> esdee.select_processed_udp_messages(UpdUpdate)

    use _ <- result.try(receive_next_datagram_as_message(sockets))

    Ok(
      actor.initialised(State(options, sockets, dispatcher.new()))
      |> actor.selecting(selctor)
      |> actor.returning(Discoverer(self, poll_timeout_milliseconds)),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

/// Stops the service discovery actor.
pub fn stop(discoverer: Discoverer) -> Nil {
  process.send(discoverer.subject, Stop)
}

/// Subscribes the given subject to all discovered service types.
/// Note that the same service type might be reported by multiple peers.
/// You will also need to call `poll_service_types` to discover services quickly.
pub fn subscribe_to_service_types(
  discoverer: Discoverer,
  subject: Subject(String),
) -> Nil {
  process.send(discoverer.subject, SubscribeToServiceTypes(subject, True))
}

/// Unsubscribes the given subject from discovered service types.
pub fn unsubscribe_from_service_types(
  discoverer: Discoverer,
  subject: Subject(String),
) -> Nil {
  process.send(discoverer.subject, SubscribeToServiceTypes(subject, False))
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
) -> Nil {
  process.send(
    discoverer.subject,
    SubscribeToServiceDetails(service_type, subject, True),
  )
}

/// Unsubscribes the given subject from receiving details for the given service type.
pub fn unsubscribe_from_service_details(
  discoverer: Discoverer,
  service_type: String,
  subject: Subject(ServiceDescription),
) -> Nil {
  process.send(
    discoverer.subject,
    SubscribeToServiceDetails(service_type, subject, False),
  )
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

/// The actor state
type State {
  State(options: Options, sockets: Sockets, dispatcher: dispatcher.Dispatcher)
}

/// The actor messages
type Msg {
  Stop
  SubscribeToServiceTypes(subject: Subject(String), subscribe: Bool)
  SubscribeToServiceDetails(
    service_type: String,
    subject: Subject(ServiceDescription),
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

    SubscribeToServiceTypes(subject:, subscribe:) -> {
      let dispatcher = case subscribe {
        True -> dispatcher.subscribe_to_service_types(state.dispatcher, subject)
        False ->
          dispatcher.unsubscribe_from_service_types(state.dispatcher, subject)
      }

      actor.continue(State(..state, dispatcher:))
    }

    SubscribeToServiceDetails(service_type:, subject:, subscribe:) -> {
      let dispatcher = case subscribe {
        True ->
          dispatcher.subscribe_to_service_details(
            state.dispatcher,
            service_type,
            subject,
          )

        False ->
          dispatcher.unsubscribe_from_service_details(
            state.dispatcher,
            service_type,
            subject,
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
