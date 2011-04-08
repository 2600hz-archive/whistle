%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_basic).
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([publish/1, message/3, message/4, properties/1, delivery/5]).
-export([publish/4, publish/7]).
-export([build_content/2, from_content/1]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(properties_input() ::
        (rabbit_framing:amqp_property_record() | [{atom(), any()}])).
-type(publish_result() ::
        ({ok, rabbit_router:routing_result(), [pid()]}
         | rabbit_types:error('not_found'))).

-spec(publish/1 ::
        (rabbit_types:delivery()) -> publish_result()).
-spec(delivery/5 ::
        (boolean(), boolean(), rabbit_types:maybe(rabbit_types:txn()),
         rabbit_types:message(), undefined | integer()) ->
                         rabbit_types:delivery()).
-spec(message/4 ::
        (rabbit_exchange:name(), rabbit_router:routing_key(),
         properties_input(), binary()) -> rabbit_types:message()).
-spec(message/3 ::
        (rabbit_exchange:name(), rabbit_router:routing_key(),
         rabbit_types:decoded_content()) ->
                        rabbit_types:ok_or_error2(rabbit_types:message(), any())).
-spec(properties/1 ::
        (properties_input()) -> rabbit_framing:amqp_property_record()).
-spec(publish/4 ::
        (rabbit_exchange:name(), rabbit_router:routing_key(),
         properties_input(), binary()) -> publish_result()).
-spec(publish/7 ::
        (rabbit_exchange:name(), rabbit_router:routing_key(),
         boolean(), boolean(), rabbit_types:maybe(rabbit_types:txn()),
         properties_input(), binary()) -> publish_result()).
-spec(build_content/2 :: (rabbit_framing:amqp_property_record(), binary()) ->
                              rabbit_types:content()).
-spec(from_content/1 :: (rabbit_types:content()) ->
                             {rabbit_framing:amqp_property_record(), binary()}).

-endif.

%%----------------------------------------------------------------------------

publish(Delivery = #delivery{
          message = #basic_message{exchange_name = ExchangeName}}) ->
    case rabbit_exchange:lookup(ExchangeName) of
        {ok, X} ->
            {RoutingRes, DeliveredQPids} = rabbit_exchange:publish(X, Delivery),
            {ok, RoutingRes, DeliveredQPids};
        Other ->
            Other
    end.

delivery(Mandatory, Immediate, Txn, Message, MsgSeqNo) ->
    #delivery{mandatory = Mandatory, immediate = Immediate, txn = Txn,
              sender = self(), message = Message, msg_seq_no = MsgSeqNo}.

build_content(Properties, BodyBin) ->
    %% basic.publish hasn't changed so we can just hard-code amqp_0_9_1
    {ClassId, _MethodId} =
        rabbit_framing_amqp_0_9_1:method_id('basic.publish'),
    #content{class_id = ClassId,
             properties = Properties,
             properties_bin = none,
             protocol = none,
             payload_fragments_rev = [BodyBin]}.

from_content(Content) ->
    #content{class_id = ClassId,
             properties = Props,
             payload_fragments_rev = FragmentsRev} =
        rabbit_binary_parser:ensure_content_decoded(Content),
    %% basic.publish hasn't changed so we can just hard-code amqp_0_9_1
    {ClassId, _MethodId} =
        rabbit_framing_amqp_0_9_1:method_id('basic.publish'),
    {Props, list_to_binary(lists:reverse(FragmentsRev))}.

%% This breaks the spec rule forbidding message modification
strip_header(#content{properties = #'P_basic'{headers = undefined}}
             = DecodedContent, _Key) ->
    DecodedContent;
strip_header(#content{properties = Props = #'P_basic'{headers = Headers}}
             = DecodedContent, Key) ->
    case lists:keysearch(Key, 1, Headers) of
        false          -> DecodedContent;
        {value, Found} -> Headers0 = lists:delete(Found, Headers),
                          rabbit_binary_generator:clear_encoded_content(
                            DecodedContent#content{
                              properties = Props#'P_basic'{
                                             headers = Headers0}})
    end.

message(ExchangeName, RoutingKey,
        #content{properties = Props} = DecodedContent) ->
    try
        {ok, #basic_message{
           exchange_name = ExchangeName,
           content       = strip_header(DecodedContent, ?DELETED_HEADER),
           id            = rabbit_guid:guid(),
           is_persistent = is_message_persistent(DecodedContent),
           routing_keys  = [RoutingKey |
                            header_routes(Props#'P_basic'.headers)]}}
    catch
        {error, _Reason} = Error -> Error
    end.

message(ExchangeName, RoutingKey, RawProperties, BodyBin) ->
    Properties = properties(RawProperties),
    Content = build_content(Properties, BodyBin),
    {ok, Msg} = message(ExchangeName, RoutingKey, Content),
    Msg.

properties(P = #'P_basic'{}) ->
    P;
properties(P) when is_list(P) ->
    %% Yes, this is O(length(P) * record_info(size, 'P_basic') / 2),
    %% i.e. slow. Use the definition of 'P_basic' directly if
    %% possible!
    lists:foldl(fun ({Key, Value}, Acc) ->
                        case indexof(record_info(fields, 'P_basic'), Key) of
                            0 -> throw({unknown_basic_property, Key});
                            N -> setelement(N + 1, Acc, Value)
                        end
                end, #'P_basic'{}, P).

indexof(L, Element) -> indexof(L, Element, 1).

indexof([], _Element, _N)              -> 0;
indexof([Element | _Rest], Element, N) -> N;
indexof([_ | Rest], Element, N)        -> indexof(Rest, Element, N + 1).

%% Convenience function, for avoiding round-trips in calls across the
%% erlang distributed network.
publish(ExchangeName, RoutingKeyBin, Properties, BodyBin) ->
    publish(ExchangeName, RoutingKeyBin, false, false, none, Properties,
            BodyBin).

%% Convenience function, for avoiding round-trips in calls across the
%% erlang distributed network.
publish(ExchangeName, RoutingKeyBin, Mandatory, Immediate, Txn, Properties,
        BodyBin) ->
    publish(delivery(Mandatory, Immediate, Txn,
                     message(ExchangeName, RoutingKeyBin,
                             properties(Properties), BodyBin),
                     undefined)).

is_message_persistent(#content{properties = #'P_basic'{
                                 delivery_mode = Mode}}) ->
    case Mode of
        1         -> false;
        2         -> true;
        undefined -> false;
        Other     -> throw({error, {delivery_mode_unknown, Other}})
    end.

%% Extract CC routes from headers
header_routes(undefined) ->
    [];
header_routes(HeadersTable) ->
    lists:append(
      [case rabbit_misc:table_lookup(HeadersTable, HeaderKey) of
           {array, Routes} -> [Route || {longstr, Route} <- Routes];
           undefined       -> [];
           {Type, _Val}    -> throw({error, {unacceptable_type_in_header,
                                             Type,
                                             binary_to_list(HeaderKey)}})
       end || HeaderKey <- ?ROUTING_HEADERS]).
