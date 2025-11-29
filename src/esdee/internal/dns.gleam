//// Minimal implementation of DNS message encoding/decoding for DNS-SD

/// Encodes a DNS-SD question for the given domain
@external(erlang, "esdee_ffi", "encode_question")
pub fn encode_question(domain: String) -> BitArray

/// The minimal resource record data we require
pub type ResourceRecord {
  PtrRecord(service_type: String, instance_name: String)
  SrvRecord(
    instance_name: String,
    priority: Int,
    weight: Int,
    port: Int,
    target_name: String,
  )
  TxtRecord(instance_name: String, values: List(String))
  ARecord(target_name: String, ip: #(Int, Int, Int, Int))
  AaaaRecord(target_name: String, ip: #(Int, Int, Int, Int, Int, Int, Int, Int))
}

pub type DecodeError {
  InvalidData
  NotAnAnswer
}

/// Decode the resource records out of a binary DNS record.
/// We don't currently care about the header or other entries.
@external(erlang, "esdee_ffi", "decode_records")
pub fn decode_records(
  data: BitArray,
) -> Result(List(ResourceRecord), DecodeError)
