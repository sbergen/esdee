-module(esdee_ffi).

-export([encode_question/1, decode_records/1]).

-include_lib("kernel/src/inet_dns.hrl").

encode_question(Domain) ->
  Header = #dns_header{},
  Question =
    #dns_query{domain = unicode:characters_to_list(Domain),
               type = ?T_ANY,
               class = ?C_IN},
  Record = #dns_rec{header = Header, qdlist = [Question]},
  inet_dns:encode(Record, true).

decode_records(Bits) ->
  case inet_dns:decode(Bits) of
    {ok, Record} ->
      Header = Record#dns_rec.header,
      case Header#dns_header.qr of
        true ->
          Answers = lists:filtermap(fun map_answer/1, Record#dns_rec.anlist),
          Resources = lists:filtermap(fun map_resource/1, Record#dns_rec.arlist),
          {ok, Answers ++ Resources};
        _ ->
          {error, not_an_answer}
      end;
    _ ->
      {error, invalid_data}
  end.

map_answer(Answer) ->
  case Answer#dns_rr.type of
    ?S_PTR ->
      {true, map_ptr(Answer)};
    _ ->
      false
  end.

map_resource(Resource) ->
  case Resource#dns_rr.type of
    ?S_TXT ->
      {true, map_txt(Resource)};
    ?S_SRV ->
      {true, map_srv(Resource)};
    ?S_A ->
      {true, map_a(Resource)};
    ?S_AAAA ->
      {true, map_aaaa(Resource)};
    _ ->
      false
  end.

map_ptr(Record) ->
  ServiceType = unicode:characters_to_binary(Record#dns_rr.domain),
  InstanceName = unicode:characters_to_binary(Record#dns_rr.data),
  {ptr_record, ServiceType, InstanceName}.

map_txt(Record) ->
  InstanceName = unicode:characters_to_binary(Record#dns_rr.domain),
  Values = lists:map(fun unicode:characters_to_binary/1, Record#dns_rr.data),
  {txt_record, InstanceName, Values}.

map_srv(Record) ->
  InstanceName = unicode:characters_to_binary(Record#dns_rr.domain),
  {Priority, Weight, Port, TargetName} = Record#dns_rr.data,
  {srv_record,
   InstanceName,
   Priority,
   Weight,
   Port,
   unicode:characters_to_binary(TargetName)}.

map_a(Record) ->
  TargetName = unicode:characters_to_binary(Record#dns_rr.domain),
  Ip = Record#dns_rr.data,
  {a_record, TargetName, Ip}.

map_aaaa(Record) ->
  TargetName = unicode:characters_to_binary(Record#dns_rr.domain),
  Ip = Record#dns_rr.data,
  {aaaa_record, TargetName, Ip}.
