%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Various utilities specific to ecallmgr. More general utilities go
%%% in whistle_util.erl
%%% @end
%%% Created : 15 Nov 2010 by James Aimonetti <james@2600hz.org>

-module(ecallmgr_util).

-export([get_sip_to/1, get_sip_from/1, get_sip_request/1, get_orig_ip/1, custom_channel_vars/1]).
-export([eventstr_to_proplist/1, get_setting/1, get_setting/2]).

-include("ecallmgr.hrl").

%% retrieves the sip address for the 'to' field
-spec get_sip_to/1 :: (Prop) -> binary() when
      Prop :: proplist().
get_sip_to(Prop) ->
    list_to_binary([props:get_value(<<"sip_to_user">>, Prop, props:get_value(<<"variable_sip_to_user">>, Prop, "nouser"))
		    , "@"
		    , props:get_value(<<"sip_to_host">>, Prop, props:get_value(<<"variable_sip_to_host">>, Prop, "nodomain"))
		   ]).

%% retrieves the sip address for the 'from' field
-spec get_sip_from/1 :: (Prop) -> binary() when
      Prop :: proplist().
get_sip_from(Prop) ->
    list_to_binary([
		    props:get_value(<<"sip_from_user">>, Prop, props:get_value(<<"variable_sip_from_user">>, Prop, "nouser"))
		    ,"@"
		    , props:get_value(<<"sip_from_host">>, Prop, props:get_value(<<"variable_sip_from_host">>, Prop, "nodomain"))
		   ]).

%% retrieves the sip address for the 'request' field
-spec get_sip_request/1 :: (Prop) -> binary() when
      Prop :: proplist().
get_sip_request(Prop) ->
    list_to_binary([
		    props:get_value(<<"Caller-Destination-Number">>, Prop, props:get_value(<<"variable_sip_req_user">>, Prop, "nouser"))
		    ,"@"
                    ,props:get_value(<<"variable_sip_req_host">>, Prop
                               ,props:get_value( list_to_binary(["variable_", ?CHANNEL_VAR_PREFIX, "Realm"]), Prop, "nodomain"))
		   ]).

-spec get_orig_ip/1 :: (Prop) -> binary() when
      Prop :: proplist().
get_orig_ip(Prop) ->
    props:get_value(<<"X-AUTH-IP">>, Prop, props:get_value(<<"ip">>, Prop)).

%% Extract custom channel variables to include in the event
-spec custom_channel_vars/1 :: (Prop) -> proplist() when
      Prop :: proplist().
custom_channel_vars(Prop) ->
    lists:foldl(fun({<<"variable_", ?CHANNEL_VAR_PREFIX, Key/binary>>, V}, Acc) -> [{Key, V} | Acc];
		   ({<<?CHANNEL_VAR_PREFIX, Key/binary>>, V}, Acc) -> [{Key, V} | Acc];
		   (_, Acc) -> Acc
		end, [], Prop).

%% convert a raw FS string of headers to a proplist
%% "Event-Name: NAME\nEvent-Timestamp: 1234\n" -> [{<<"Event-Name">>, <<"NAME">>}, {<<"Event-Timestamp">>, <<"1234">>}]
-spec eventstr_to_proplist/1 :: (EvtStr) -> proplist() when
      EvtStr :: string().
eventstr_to_proplist(EvtStr) ->
    [begin
	 [K, V] = string:tokens(X, ": "),
	 [{V1,[]}] = mochiweb_util:parse_qs(V),
	 {wh_util:to_binary(K), wh_util:to_binary(V1)}
     end || X <- string:tokens(wh_util:to_list(EvtStr), "\n")].

-spec get_setting/1 :: (Setting) -> {ok, term()} when
      Setting :: atom().
-spec get_setting/2 :: (Setting, Default) -> {ok, term()} when
      Setting :: atom(),
      Default :: term().
get_setting(Setting) ->
    get_setting(Setting, undefined).
get_setting(Setting, Default) ->
    case wh_cache:fetch({ecallmgr_setting, Setting}) of
        {ok, _}=Success -> Success;
        {error, _} ->
            case file:consult(?SETTINGS_FILE) of
                {ok, Settings} ->
                    Value = props:get_value(Setting, Settings, Default),
                    wh_cache:store({ecallmgr_setting, Setting}, Value),
                    {ok, Value};
                {error, _} ->
                    wh_cache:store({ecallmgr_setting, Setting}, Default),
                    {ok, Default}
            end
    end.
