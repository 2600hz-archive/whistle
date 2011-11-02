%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Handle registration queries
%%% @end
%%% Created : 19 Aug 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(reg_query).

-export([init/0, handle_req/2]).

-include("reg.hrl").

init() ->
    ok.

-spec handle_req/2 :: (JObj, Props) -> no_return() when
      JObj :: json_object(),
      Props :: proplist().
handle_req(ApiJObj, Props) ->
    Queue = props:get_value(queue, Props),
    CallId = wh_json:get_value(<<"Call-ID">>, ApiJObj, <<"000000000000">>),
    put(callid, CallId),

    ?LOG_START("received registration query"),
    true = wh_api:reg_query_v(ApiJObj),

    Realm = wh_json:get_value(<<"Realm">>, ApiJObj),
    Username = wh_json:get_value(<<"Username">>, ApiJObj),

    %% only send data if a registration is found
    case reg_util:lookup_registration(Realm, Username) of
        {ok, RegJObj} ->
            ?LOG("found contact for ~s@~s in cache", [Username, Realm]),
            filter_and_send(ApiJObj, RegJObj, Queue);
        {error, not_found} ->
            ?LOG_END("no registration for ~s@~s", [Username, Realm])
    end.

-spec filter_and_send/3 :: (ApiJObj, RegJObj, Queue) -> ok when
      ApiJObj :: json_object(),
      RegJObj :: json_object(),
      Queue :: json_object().
filter_and_send(ApiJObj, RegJObj, Queue) ->
    RespFields = case wh_json:get_value(<<"Fields">>, ApiJObj) of
                     [] ->
                         wh_json:delete_key(<<"_id">>, wh_json:delete_key(<<"_rev">>, RegJObj));
                     Fields ->
                         wh_json:from_list(lists:foldl(fun(F, Acc) ->
                                                               [ {F, wh_json:get_value(F, RegJObj)} | Acc]
                                                       end, [], Fields))
                 end,

    {ok, Payload} = wh_api:reg_query_resp([ {<<"Fields">>, RespFields}
                                            | wh_api:default_headers(Queue
                                                                     ,<<"directory">>
                                                                     ,<<"reg_query_resp">>
                                                                     ,?APP_NAME
                                                                     ,?APP_VERSION)
                                          ]),

    RespServer = wh_json:get_value(<<"Server-ID">>, ApiJObj),
    reg_util:send_resp(Payload, RespServer),
    ?LOG_END("sent reply for AOR: ~s", [wh_json:get_value(<<"Contact">>, RegJObj)]).
