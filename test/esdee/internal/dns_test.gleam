import esdee/datagrams
import esdee/internal/dns.{ARecord, AaaaRecord, PtrRecord, SrvRecord, TxtRecord}
import glip

pub fn encode_question_test() {
  assert dns.encode_question("_googlecast._tcp.local")
    == datagrams.googlecast_query_bits
}

pub fn decode_records_fail_test() {
  assert dns.decode_records(<<"Not valid":utf8>>) == Error(dns.InvalidData)
}

pub fn decode_records_question_test() {
  assert dns.decode_records(datagrams.googlecast_query_bits)
    == Error(dns.NotAnAnswer)
}

pub fn decode_records_test() {
  let assert Ok(expected_ip) = glip.parse_ip("10.10.2.101")
  let assert Ok(records) =
    dns.decode_records(datagrams.ipv4_service_answer_bits)

  assert records
    == [
      PtrRecord(
        "_googlecast._tcp.local",
        "SHIELD-Android-TV-9693d58e3537dddb118b7b7d17f9c1c2._googlecast._tcp.local",
      ),
      TxtRecord(
        "SHIELD-Android-TV-9693d58e3537dddb118b7b7d17f9c1c2._googlecast._tcp.local",
        [
          "id=9693d58e3537dddb118b7b7d17f9c1c2",
          "cd=45CE3CA42AF5F60529EB61735FFF5076",
          "rm=40543385C9BA2114",
          "ve=05",
          "md=SHIELD Android TV",
          "ic=/setup/icon.png",
          "fn=SHIELDD",
          "ca=463365",
          "st=0",
          "bs=FA8F7F8487F3",
          "nf=1",
          "ct=2AD9C4",
          "rs=",
        ],
      ),
      SrvRecord(
        "SHIELD-Android-TV-9693d58e3537dddb118b7b7d17f9c1c2._googlecast._tcp.local",
        0,
        0,
        8009,
        "9693d58e-3537-dddb-118b-7b7d17f9c1c2.local",
      ),
      ARecord("9693d58e-3537-dddb-118b-7b7d17f9c1c2.local", expected_ip),
    ]
}

pub fn decode_records_aaa_test() {
  let assert Ok(expected_ip) =
    glip.parse_ip("2001:14ba:a194:2402:152e:22c1:d60:d4ce")
  let assert Ok(records) =
    dns.decode_records(datagrams.ipv6_service_answer_bits)

  assert records
    == [
      PtrRecord(
        "_googlezone._tcp.local",
        "9693d58e-3537-dddb-118b-7b7d17f9c1c2._googlezone._tcp.local",
      ),
      TxtRecord("9693d58e-3537-dddb-118b-7b7d17f9c1c2._googlezone._tcp.local", [
        "id=45CE3CA42AF5F60529EB61735FFF5076",
        "CGS",
      ]),
      SrvRecord(
        "9693d58e-3537-dddb-118b-7b7d17f9c1c2._googlezone._tcp.local",
        600,
        0,
        10_001,
        "9693d58e-3537-dddb-118b-7b7d17f9c1c2.local",
      ),
      AaaaRecord("9693d58e-3537-dddb-118b-7b7d17f9c1c2.local", expected_ip),
    ]
}
