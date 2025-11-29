import gleam/option

pub type ServiceDescription {
  ServiceDescription(
    service_type: String,
    instance_name: String,
    target_name: String,
    priority: Int,
    weight: Int,
    port: Int,
    txt_values: List(String),
    ipv4: option.Option(#(Int, Int, Int, Int)),
    ipv6: option.Option(#(Int, Int, Int, Int, Int, Int, Int, Int)),
  )
}
